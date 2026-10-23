import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/io.dart';

import '../pairing/pairing_code.dart';
import 'pairing_auth.dart';
import 'session_seal.dart';
import 'wire.dart';

enum ConnectionStatus { searching, connected, offline }

/// A protocol-level event worth surfacing in the debug log: auth handshake
/// results, relay errors, socket lifecycle.
class RelayEvent {
  const RelayEvent(this.message, {this.isError = false, this.code});

  final String message;
  final bool isError;

  /// The relay's machine-readable error code (`payload_too_large`,
  /// `auth_failed`, ...) when this event wraps a relay `error` message;
  /// null for every other event.
  final String? code;
}

class RelayHealth {
  const RelayHealth({
    required this.status,
    required this.relayName,
    required this.clipboardStatus,
    this.clipboardError,
    this.clipboardPaused = false,
    this.clipboardPausedUntil,
  });

  final String status;
  final String relayName;
  final String? clipboardStatus;
  final String? clipboardError;

  /// Clipboard sync is paused on the laptop. Files still move.
  final bool clipboardPaused;

  /// When the laptop's pause lifts, on the laptop's clock; null while paused
  /// until resumed there.
  final DateTime? clipboardPausedUntil;

  bool get degraded => status == 'degraded' || clipboardStatus == 'degraded';

  static RelayHealth? fromJson(Object? value) {
    if (value is! Map) return null;
    final json = value.cast<Object?, Object?>();
    final status = json['status'];
    final relayName = json['relayName'];
    if (status is! String || relayName is! String) return null;
    final clipboard = json['clipboard'];
    final clipboardStatus = clipboard is Map ? clipboard['status'] : null;
    final clipboardError = clipboard is Map ? clipboard['error'] : null;
    final paused = clipboard is Map && clipboard['paused'] == true;
    final pausedUntil = clipboard is Map ? clipboard['pausedUntil'] : null;
    return RelayHealth(
      status: status,
      relayName: relayName,
      clipboardStatus: clipboardStatus is String ? clipboardStatus : null,
      clipboardError: clipboardError is String ? clipboardError : null,
      clipboardPaused: paused,
      clipboardPausedUntil: paused && pausedUntil is int
          ? DateTime.fromMillisecondsSinceEpoch(pausedUntil)
          : null,
    );
  }
}

abstract interface class RelayTransport {
  Stream<Object?> get messages;

  /// WebSocket close code/reason once [messages] is done; null before the
  /// socket closes (or on transports without the concept).
  int? get closeCode;

  String? get closeReason;

  void send(Map<String, Object?> message);

  Future<void> close();
}

abstract interface class RelaySession {
  Stream<ConnectionStatus> get status;

  Future<void> start();

  void publish(PayloadFrame frame);

  Future<void> close();
}

class WebSocketRelayTransport implements RelayTransport {
  WebSocketRelayTransport._(this._channel);

  final IOWebSocketChannel _channel;

  /// Keepalive cadence mirroring the relay's 30s heartbeat: an unanswered
  /// ping closes the socket (1001), so one knob buys both path warmth and
  /// phone-side dead-path detection (keepalive spec D1/D2).
  static const pingInterval = Duration(seconds: 30);

  /// Fails a connect into a black hole (laptop asleep, wrong network) into
  /// the backoff loop instead of hanging on OS SYN retries (D3).
  static const connectTimeout = Duration(seconds: 5);

  static WebSocketRelayTransport connect(PairingCode pairing) {
    return WebSocketRelayTransport._(
      IOWebSocketChannel.connect(
        Uri.parse('ws://${pairing.host}:${pairing.port}'),
        pingInterval: pingInterval,
        connectTimeout: connectTimeout,
      ),
    );
  }

  @override
  Stream<Object?> get messages => _channel.stream;

  @override
  int? get closeCode => _channel.closeCode;

  @override
  String? get closeReason => _channel.closeReason;

  @override
  void send(Map<String, Object?> message) {
    _channel.sink.add(jsonEncode(message));
  }

  @override
  Future<void> close() => _channel.sink.close();
}

/// Relay protocol feature: telemetry flows only after the phone asks for it.
const telemetrySubscribeFeature = 'telemetry_subscribe';

/// The laptop shares folders the phone can browse and pull from (ADR 0026).
const browseFilesFeature = 'browse_files';

class RelayConnection implements RelaySession {
  RelayConnection({
    required this.pairing,
    required this.deviceId,
    required this.transport,
    this.closeTimeout = defaultCloseTimeout,
    this.clock = DateTime.now,
    Random? random,
  }) : _random = random ?? Random.secure();

  /// Mirrors the relay's `defaultMaxPayloadBytes` (25MiB); the fallback until
  /// the hello advertises the actual cap.
  static const defaultMaxPayloadBytes = 25 * 1024 * 1024;

  /// Bounds every await in [close]: a half-open socket (peer vanished during
  /// a process freeze) can leave cancel/close futures that never complete,
  /// and one poisoned future must not wedge the controller's teardown — and
  /// with it every later reconnect — forever (#35).
  static const defaultCloseTimeout = Duration(seconds: 3);

  final PairingCode pairing;
  final String deviceId;
  final RelayTransport transport;
  final Duration closeTimeout;

  /// Stamps `sentAt` on each publish so the relay can map `frame.ts` onto its
  /// own clock before ordering (a phone clock that drifts must not decide
  /// which copy wins).
  final DateTime Function() clock;

  final _status = StreamController<ConnectionStatus>.broadcast();
  final _payloads = StreamController<PayloadFrame>.broadcast();
  final _events = StreamController<RelayEvent>.broadcast();
  final _acks = StreamController<int>.broadcast();
  final _health = StreamController<RelayHealth>.broadcast();
  final _telemetry = StreamController<LaptopTelemetry>.broadcast();
  final _transferControls = StreamController<Map<String, Object?>>.broadcast();
  final _browseResults = StreamController<Map<String, Object?>>.broadcast();
  StreamSubscription<Object?>? _subscription;
  int? _maxPayloadBytes;
  Set<String> _relayFeatures = const {};
  bool _authenticated = false;
  bool _telemetryWanted = false;
  final Random _random;
  String? _challenge;
  String? _clientChallenge;
  bool _relayVerified = false;
  SessionSealer? _sealer;
  // Opening and sealing are async; these keep both directions in wire order,
  // which the sealed counters depend on.
  Future<void> _inbound = Future.value();
  Future<void> _outbound = Future.value();

  @override
  Stream<ConnectionStatus> get status => _status.stream;

  Stream<PayloadFrame> get payloads => _payloads.stream;

  Stream<RelayEvent> get events => _events.stream;

  /// Acked `ts` values — the relay answers every accepted publish with
  /// `{kind: "ack", ts}`; the push pipeline clears its pending slot on these.
  Stream<int> get acks => _acks.stream;
  Stream<RelayHealth> get health => _health.stream;
  Stream<LaptopTelemetry> get telemetry => _telemetry.stream;
  Stream<Map<String, Object?>> get transferControls => _transferControls.stream;
  Stream<Map<String, Object?>> get browseResults => _browseResults.stream;

  /// Whether this session can browse the laptop's shared folders: the relay
  /// shares some, and the session is sealed, since listings carry filenames.
  bool get canBrowse =>
      _sealer != null && _relayFeatures.contains(browseFilesFeature);

  /// The cap advertised by the relay hello, measured on the decoded
  /// ciphertext (plaintext + 16-byte GCM tag); [defaultMaxPayloadBytes]
  /// until the hello arrives.
  int get maxPayloadBytes => _maxPayloadBytes ?? defaultMaxPayloadBytes;

  /// Whether laptop telemetry should flow on this session. The relay starts
  /// a phone that advertised `telemetry_subscribe` unsubscribed, so nothing is
  /// sampled or sent while no screen shows the numbers. Set before the
  /// handshake, the value is sent once auth succeeds. A relay that predates
  /// the feature never gets the message: it would answer with an error, and
  /// it streams telemetry regardless.
  set telemetryWanted(bool wanted) {
    if (_telemetryWanted == wanted) return;
    _telemetryWanted = wanted;
    if (_authenticated) _sendTelemetrySubscription();
  }

  bool get telemetryWanted => _telemetryWanted;

  /// The relay proved this session that it holds the pairing secret.
  bool get relayVerified => _relayVerified;

  void _sendTelemetrySubscription() {
    if (!_relayFeatures.contains(telemetrySubscribeFeature)) return;
    _send({'v': 1, 'kind': 'telemetry_subscribe', 'active': _telemetryWanted});
  }

  @override
  Future<void> start() async {
    _status.add(ConnectionStatus.searching);
    _subscription = transport.messages.listen(
      (message) {
        _inbound = _inbound.then((_) => _handleMessage(message)).catchError((
          Object error,
        ) {
          if (_events.isClosed) return;
          _events.add(RelayEvent('Ignored a malformed relay message: $error'));
        });
      },
      onDone: () {
        // Close code tells a 1001 ping-timeout apart from a relay-initiated
        // close in the debug log (keepalive spec D7).
        final code = transport.closeCode;
        final reason = transport.closeReason;
        _events.add(
          RelayEvent(
            'Relay socket closed '
            '(code: ${code ?? 'none'}'
            '${reason != null && reason.isNotEmpty ? ', reason: $reason' : ''}).',
          ),
        );
        _status.add(ConnectionStatus.offline);
      },
      onError: (Object error) {
        _events.add(RelayEvent('Relay socket error: $error', isError: true));
        _status.add(ConnectionStatus.offline);
      },
    );
  }

  @override
  void publish(PayloadFrame frame) {
    _send({
      'v': 1,
      'kind': 'publish',
      'frame': frame.toJson(),
      'sentAt': clock().millisecondsSinceEpoch,
    });
  }

  void sendTransferControl(Map<String, Object?> message) {
    final kind = message['kind'];
    if (message['v'] != 1 || kind is! String || !kind.startsWith('transfer_')) {
      throw const FormatException('Invalid transfer control message.');
    }
    _send(message);
  }

  /// Sends a `browse_list` or `browse_pull` request. Only on a sealed session
  /// whose relay advertised [browseFilesFeature]; see [canBrowse].
  void sendBrowse(Map<String, Object?> message) {
    final kind = message['kind'];
    if (message['v'] != 1 || kind is! String || !kind.startsWith('browse_')) {
      throw const FormatException('Invalid browse message.');
    }
    if (!canBrowse) {
      throw StateError('This session cannot browse the laptop.');
    }
    _send(message);
  }

  /// Sends [message], sealed when the session negotiated sealed control and
  /// the message is not a payload frame.
  void _send(Map<String, Object?> message) {
    final sealer = _sealer;
    if (sealer == null) {
      transport.send(message);
      return;
    }
    _outbound = _outbound
        .then((_) async {
          transport.send(
            travelsUnsealed(message['kind'] as String?)
                ? message
                : await sealer.seal(message),
          );
        })
        .catchError((Object error) {
          if (_events.isClosed) return;
          _events.add(
            RelayEvent('Could not send to relay: $error', isError: true),
          );
        });
  }

  /// Ends a session whose relay could not be trusted. Offline makes the
  /// controller tear it down and retry, as it does for a relay error.
  void _refuseRelay(String message, String code) {
    _events.add(RelayEvent(message, isError: true, code: code));
    _status.add(ConnectionStatus.offline);
  }

  @override
  Future<void> close() async {
    await _guardedClose(_subscription?.cancel());
    await _guardedClose(transport.close());
    await _guardedClose(_status.close());
    await _guardedClose(_payloads.close());
    await _guardedClose(_events.close());
    await _guardedClose(_acks.close());
    await _guardedClose(_health.close());
    await _guardedClose(_telemetry.close());
    await _guardedClose(_transferControls.close());
    await _guardedClose(_browseResults.close());
  }

  Future<void> _guardedClose(Future<void>? step) async {
    if (step == null) return;
    try {
      await step.timeout(closeTimeout);
    } on Object {
      // A transport that never finished connecting can throw on close, and a
      // dead one can hang past [closeTimeout]; the connection is being
      // discarded either way.
    }
  }

  Future<void> _handleMessage(Object? rawMessage) async {
    var message = _decodeMessage(rawMessage);
    final sealer = _sealer;
    if (sealer != null) {
      final kind = message['kind'];
      if (kind == 'sealed') {
        try {
          message = await sealer.open(message);
        } on Object catch (error) {
          // A lost or forged message leaves the counters out of step for good.
          _refuseRelay(
            'Relay sent a control message that failed to open: $error',
            'seal_failed',
          );
          return;
        }
      } else if (!travelsUnsealed(kind as String?)) {
        _events.add(
          RelayEvent('Dropped an unsealed $kind message on a sealed session.'),
        );
        return;
      }
    }
    switch (message['kind']) {
      case 'hello':
        final challenge = _stringField(message, 'challenge');
        _challenge = challenge;
        final clientChallenge = base64Encode(
          List<int>.generate(24, (_) => _random.nextInt(256)),
        );
        _clientChallenge = clientChallenge;
        final cap = message['maxPayloadBytes'];
        if (cap is int && cap > 0) _maxPayloadBytes = cap;
        final features = message['features'];
        _relayFeatures = features is List
            ? features.whereType<String>().toSet()
            : const {};
        _events.add(const RelayEvent('Challenge received, sending proof.'));
        transport.send({
          'v': 1,
          'kind': 'auth',
          'deviceId': deviceId,
          'proof': await createPairingProof(
            pairingSecret: pairing.secret,
            challenge: challenge,
            deviceId: deviceId,
          ),
          'clientChallenge': clientChallenge,
          'features': const [telemetrySubscribeFeature, sealedControlFeature],
        });
      case 'auth_ok':
        if (!await _verifyRelay(message)) return;
        final health = RelayHealth.fromJson(message['health']);
        if (health != null) _health.add(health);
        _events.add(const RelayEvent('Auth accepted by relay.'));
        _authenticated = true;
        // The relay starts this session unsubscribed; only an active wish
        // needs saying.
        if (_telemetryWanted) _sendTelemetrySubscription();
        _status.add(ConnectionStatus.connected);
      case 'health':
        final health = RelayHealth.fromJson(message['health']);
        if (health != null) _health.add(health);
      case 'telemetry':
        final telemetry = LaptopTelemetry.fromJson(message);
        if (telemetry != null) _telemetry.add(telemetry);
      case 'payload':
        _payloads.add(PayloadFrame.fromJson(message['frame']));
      case 'ack':
        final ts = message['ts'];
        if (message['stale'] == true) {
          // Still an ack: the relay has the frame and a retry would lose the
          // same race, so pending sends clear as usual.
          _events.add(
            const RelayEvent(
              'Laptop already had a newer clipboard; this copy was not applied.',
              code: 'stale',
            ),
          );
        }
        if (ts is int) _acks.add(ts);
      case String kind when kind.startsWith('transfer_'):
        _transferControls.add(message);
      case 'browse_result':
        _browseResults.add(message);
      case 'error':
        final code = message['code'];
        final detail = message['message'];
        _events.add(
          RelayEvent(
            'Relay error${code is String ? ' [$code]' : ''}: '
            '${detail is String ? detail : 'unknown'}',
            isError: true,
            code: code is String ? code : null,
          ),
        );
        _status.add(ConnectionStatus.offline);
      default:
        break;
    }
  }

  /// Checks the relay's half of the handshake (ADR 0023) and, when sealed
  /// control was agreed, starts sealing. False ends the session.
  Future<bool> _verifyRelay(Map<String, Object?> authOk) async {
    final proof = authOk['relayProof'];
    final challenge = _challenge;
    final clientChallenge = _clientChallenge;
    if (proof is! String || challenge == null || clientChallenge == null) {
      // A relay from before mutual auth. Accepted until this pairing has seen
      // the laptop prove itself; after that, a missing proof is an impostor
      // or someone stripping it.
      if (!pairing.relayVerified) return true;
      _refuseRelay(
        'Laptop did not prove it holds the pairing secret.',
        'relay_unverified',
      );
      return false;
    }
    final rawFeatures = authOk['features'];
    final sessionFeatures = rawFeatures is List
        ? rawFeatures.whereType<String>().toList()
        : const <String>[];
    final verified = await verifyRelayProof(
      pairingSecret: pairing.secret,
      challenge: challenge,
      clientChallenge: clientChallenge,
      sessionFeatures: sessionFeatures,
      deviceId: deviceId,
      proof: proof,
    );
    if (!verified) {
      _refuseRelay(
        'Laptop could not prove it holds the pairing secret.',
        'relay_unverified',
      );
      return false;
    }
    final sealed = sessionFeatures.contains(sealedControlFeature);
    if (!sealed && pairing.relayVerified) {
      // This phone always asks to seal, and a laptop that proves itself
      // always agrees, so a proof without it means our ask was altered.
      _refuseRelay(
        'Laptop session was not sealed; refusing a possible downgrade.',
        'relay_unverified',
      );
      return false;
    }
    _relayVerified = true;
    if (sealed) {
      _sealer = SessionSealer(
        await deriveSessionKey(
          pairingSecret: pairing.secret,
          challenge: challenge,
          clientChallenge: clientChallenge,
          deviceId: deviceId,
        ),
        SealDirection.phoneToRelay,
      );
    }
    return true;
  }

  Map<String, Object?> _decodeMessage(Object? rawMessage) {
    if (rawMessage is String) {
      final decoded = jsonDecode(rawMessage);
      if (decoded is Map<String, Object?>) return decoded;
    }
    if (rawMessage is Map<String, Object?>) return rawMessage;
    throw const FormatException('Relay message must be a JSON object.');
  }
}

String _stringField(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! String || value.isEmpty) {
    throw FormatException('$field must be a string.');
  }
  return value;
}
