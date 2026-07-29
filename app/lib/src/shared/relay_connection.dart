import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/io.dart';

import '../pairing/pairing_code.dart';
import 'pairing_auth.dart';
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
  });

  final String status;
  final String relayName;
  final String? clipboardStatus;
  final String? clipboardError;

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
    return RelayHealth(
      status: status,
      relayName: relayName,
      clipboardStatus: clipboardStatus is String ? clipboardStatus : null,
      clipboardError: clipboardError is String ? clipboardError : null,
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

class RelayConnection implements RelaySession {
  RelayConnection({
    required this.pairing,
    required this.deviceId,
    required this.transport,
    this.closeTimeout = defaultCloseTimeout,
  });

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

  final _status = StreamController<ConnectionStatus>.broadcast();
  final _payloads = StreamController<PayloadFrame>.broadcast();
  final _events = StreamController<RelayEvent>.broadcast();
  final _acks = StreamController<int>.broadcast();
  final _health = StreamController<RelayHealth>.broadcast();
  final _transferControls = StreamController<Map<String, Object?>>.broadcast();
  StreamSubscription<Object?>? _subscription;
  int? _maxPayloadBytes;

  @override
  Stream<ConnectionStatus> get status => _status.stream;

  Stream<PayloadFrame> get payloads => _payloads.stream;

  Stream<RelayEvent> get events => _events.stream;

  /// Acked `ts` values — the relay answers every accepted publish with
  /// `{kind: "ack", ts}`; the push pipeline clears its pending slot on these.
  Stream<int> get acks => _acks.stream;
  Stream<RelayHealth> get health => _health.stream;
  Stream<Map<String, Object?>> get transferControls => _transferControls.stream;

  /// The cap advertised by the relay hello, measured on the decoded
  /// ciphertext (plaintext + 16-byte GCM tag); [defaultMaxPayloadBytes]
  /// until the hello arrives.
  int get maxPayloadBytes => _maxPayloadBytes ?? defaultMaxPayloadBytes;

  @override
  Future<void> start() async {
    _status.add(ConnectionStatus.searching);
    _subscription = transport.messages.listen(
      (message) {
        unawaited(_handleMessage(message));
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
    transport.send({'v': 1, 'kind': 'publish', 'frame': frame.toJson()});
  }

  void sendTransferControl(Map<String, Object?> message) {
    final kind = message['kind'];
    if (message['v'] != 1 || kind is! String || !kind.startsWith('transfer_')) {
      throw const FormatException('Invalid transfer control message.');
    }
    transport.send(message);
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
    await _guardedClose(_transferControls.close());
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
    final message = _decodeMessage(rawMessage);
    switch (message['kind']) {
      case 'hello':
        final challenge = _stringField(message, 'challenge');
        final cap = message['maxPayloadBytes'];
        if (cap is int && cap > 0) _maxPayloadBytes = cap;
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
        });
      case 'auth_ok':
        final health = RelayHealth.fromJson(message['health']);
        if (health != null) _health.add(health);
        _events.add(const RelayEvent('Auth accepted by relay.'));
        _status.add(ConnectionStatus.connected);
      case 'health':
        final health = RelayHealth.fromJson(message['health']);
        if (health != null) _health.add(health);
      case 'payload':
        _payloads.add(PayloadFrame.fromJson(message['frame']));
      case 'ack':
        final ts = message['ts'];
        if (ts is int) _acks.add(ts);
      case String kind when kind.startsWith('transfer_'):
        _transferControls.add(message);
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
