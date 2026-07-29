import 'dart:async';

import 'package:flutter/services.dart';
import 'package:screenshot_observer/screenshot_observer.dart';

import '../shared/payload_crypto.dart';
import '../shared/relay_connection.dart';
import '../shared/wire.dart';

/// Opens a MediaStore image row's bytes; throws [PlatformException] with code
/// `not-found` or `io-error` on a failed attempt ([ScreenshotWatcher.readImage]).
typedef ScreenshotImageReader = Future<Uint8List> Function(int id);

typedef PushEmit = void Function(Map<String, Object?> message);

/// GCM tag appended to every ciphertext; the relay measures its cap on
/// plaintext + tag (push spec §3).
const _gcmTagBytes = 16;

/// The encrypted frame occupying the single pending slot (push spec §5/§6).
class _PendingFrame {
  _PendingFrame({
    required this.frame,
    required this.id,
    required this.plaintextBytes,
    required this.detectedAtMs,
    required this.queuedAtMs,
  });

  final PayloadFrame frame;
  final int id;
  final int plaintextBytes;
  final int detectedAtMs;

  /// When the frame entered the slot — the held-since mark for `heldForMs`.
  final int queuedAtMs;

  /// Last time the frame went out on a socket; null while only held.
  int? sentAtMs;
}

/// Screenshot auto-push pipeline (push spec, #28): observer event in, acked
/// relay frame out.
///
/// Long-lived in the service isolate — it outlives every [RelayConnection],
/// which [ServiceRelayController] tears down and rebuilds on each reconnect.
/// [attachSession]/[detachSession] swap the connection; the single-slot
/// latest-wins pending frame survives the swap (it *is* the offline hold, §6)
/// and clears only on a relay ack, a `payload_too_large` rejection, being
/// superseded by a newer screenshot, or [clearPending] (toggle off, §7).
class ScreenshotPushController {
  ScreenshotPushController({
    required this.readImage,
    required this.crypto,
    required this.emit,
    this.deviceId = 'phone',
    this.readAttempts = 3,
    this.readRetryDelay = const Duration(milliseconds: 300),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final ScreenshotImageReader readImage;
  final PayloadCrypto crypto;
  final PushEmit emit;
  final String deviceId;

  /// MIUI's scanner can publish rows ahead of stable reads (spec §2): retry
  /// `not-found`/`io-error` this many times, [readRetryDelay] apart.
  final int readAttempts;
  final Duration readRetryDelay;

  final DateTime Function() _clock;

  RelayConnection? _connection;
  StreamSubscription<ConnectionStatus>? _statusSubscription;
  StreamSubscription<int>? _ackSubscription;
  StreamSubscription<RelayEvent>? _eventSubscription;
  bool _connected = false;
  String? _pairingSecret;

  _PendingFrame? _pending;
  ScreenshotEvent? _waiting;
  bool _processing = false;
  int _lastFrameTs = 0;

  /// Points the pipeline at the current connection. Called on every `_sync`,
  /// so it first detaches whatever session came before; a frame already
  /// pending stays pending and goes out on this session's `connected`
  /// transition.
  void attachSession(
    RelayConnection connection, {
    required String pairingSecret,
  }) {
    detachSession();
    _pairingSecret = pairingSecret;
    _connection = connection;
    _statusSubscription = connection.status.listen(_onStatus);
    _ackSubscription = connection.acks.listen(_onAck);
    _eventSubscription = connection.events.listen(_onRelayEvent);
  }

  /// Detaches from the session being torn down. Pending frame, pairing
  /// secret, and the monotonic ts guard survive — only the socket goes away.
  void detachSession() {
    _statusSubscription?.cancel();
    _statusSubscription = null;
    _ackSubscription?.cancel();
    _ackSubscription = null;
    _eventSubscription?.cancel();
    _eventSubscription = null;
    _connection = null;
    _connected = false;
  }

  /// Drops the held/queued work without publishing — the auto-push toggle
  /// turned off (§7): a held frame must not surface minutes later.
  void clearPending() {
    if (_pending == null && _waiting == null) return;
    _pending = null;
    _waiting = null;
    _log('Auto-push off; pending screenshot frame cleared.');
  }

  /// Entry point for observer events. Latest wins at every stage (§5): while
  /// one screenshot is being read/encrypted, a newer one waits in a depth-1
  /// slot and displaces (skips) anything already waiting.
  void handleEvent(ScreenshotEvent event) {
    // Size guard before the bytes ever cross the channel (§2). A 0 size means
    // MIUI is still indexing: read anyway, re-check after.
    if (event.sizeBytes > 0 && event.sizeBytes + _gcmTagBytes > _cap) {
      _skip(event.id, 'too_large');
      return;
    }
    if (_processing) {
      final displaced = _waiting;
      if (displaced != null) _skip(displaced.id, 'superseded');
      _waiting = event;
      return;
    }
    unawaited(_process(event));
  }

  int get _cap =>
      _connection?.maxPayloadBytes ?? RelayConnection.defaultMaxPayloadBytes;

  Future<void> _process(ScreenshotEvent event) async {
    _processing = true;
    try {
      await _readEncryptAndQueue(event);
    } finally {
      _processing = false;
      final next = _waiting;
      _waiting = null;
      if (next != null) handleEvent(next);
    }
  }

  Future<void> _readEncryptAndQueue(ScreenshotEvent event) async {
    final secret = _pairingSecret;
    if (secret == null) {
      // Never paired this service session: nothing to encrypt with. The
      // share sheet remains the fallback.
      _log(
        'Screenshot ${event.id} dropped: no pairing attached yet.',
        isError: true,
      );
      return;
    }

    final readStart = _nowMs();
    Uint8List bytes;
    var attempts = 0;
    while (true) {
      attempts += 1;
      try {
        bytes = await readImage(event.id);
        break;
      } on PlatformException catch (error) {
        if ((error.code == 'not-found' || error.code == 'io-error') &&
            attempts < readAttempts) {
          await Future<void>.delayed(readRetryDelay);
          continue;
        }
        _log(
          'Screenshot read failed after $attempts attempts: '
          '${error.code} (${error.message}).',
          isError: true,
        );
        _skip(event.id, 'read_failed');
        return;
      }
    }
    _event('screenshot_read', {
      'id': event.id,
      'bytes': bytes.length,
      'readMs': _nowMs() - readStart,
      'attempts': attempts,
    });

    // Re-check against the actual byte length (sizeBytes may have been 0).
    if (bytes.length + _gcmTagBytes > _cap) {
      _skip(event.id, 'too_large');
      return;
    }

    // Detection time, not DATE_ADDED (§4); bumped so burst rows sharing a
    // millisecond stay strictly increasing for the pool's latest-wins compare.
    var ts = event.detectedAtEpochMillis;
    if (ts <= _lastFrameTs) ts = _lastFrameTs + 1;
    _lastFrameTs = ts;

    final encryptStart = _nowMs();
    final frame = await crypto.encrypt(
      metadata: PayloadMetadata(
        type: PayloadType.image,
        mime: event.mimeType.isEmpty ? 'image/png' : event.mimeType,
        origin: deviceId,
        ts: ts,
      ),
      plaintext: bytes,
      pairingSecret: secret,
    );
    _event('screenshot_encrypted', {
      'nonce': frame.nonce,
      'ts': ts,
      'plaintextBytes': bytes.length,
      'encryptMs': _nowMs() - encryptStart,
    });

    // A newer screenshot arrived while this one encrypted: the finished frame
    // is not published (§5).
    if (_waiting != null) {
      _skip(event.id, 'superseded');
      return;
    }

    final displaced = _pending;
    if (displaced != null) _skip(displaced.id, 'superseded');
    _pending = _PendingFrame(
      frame: frame,
      id: event.id,
      plaintextBytes: bytes.length,
      detectedAtMs: event.detectedAtEpochMillis,
      queuedAtMs: _nowMs(),
    );

    if (_connected) {
      _sendPending(republish: false);
    } else {
      _event('screenshot_held', {'nonce': frame.nonce, 'ts': ts});
    }
  }

  void _sendPending({required bool republish}) {
    final pending = _pending;
    final connection = _connection;
    if (pending == null || connection == null || !_connected) return;
    final now = _nowMs();
    connection.publish(pending.frame);
    if (republish) {
      _event('screenshot_republished', {
        'nonce': pending.frame.nonce,
        'ts': pending.frame.ts,
        'heldForMs': now - pending.queuedAtMs,
      });
    } else {
      _event('screenshot_publish', {
        'nonce': pending.frame.nonce,
        'ts': pending.frame.ts,
        'bytes': pending.plaintextBytes + _gcmTagBytes,
        'sinceDetectMs': now - pending.detectedAtMs,
      });
    }
    pending.sentAtMs = now;
  }

  void _onStatus(ConnectionStatus status) {
    final wasConnected = _connected;
    _connected = status == ConnectionStatus.connected;
    if (_connected && !wasConnected && _pending != null) {
      // Verbatim re-send — same nonce and ciphertext, so no nonce reuse with
      // new plaintext, and idempotent at the pool (§6).
      _sendPending(republish: true);
    }
  }

  void _onAck(int ts) {
    final pending = _pending;
    if (pending == null || pending.frame.ts != ts) return;
    _pending = null;
    _event('screenshot_acked', {
      'ts': ts,
      'ackMs': _nowMs() - (pending.sentAtMs ?? pending.queuedAtMs),
    });
  }

  void _onRelayEvent(RelayEvent event) {
    // The §3 pre-check makes this unreachable in normal operation; if the cap
    // dropped between hold and reconnect, retrying the same frame forever
    // would loop — drop it (§6).
    if (event.code != 'payload_too_large') return;
    final pending = _pending;
    if (pending == null) return;
    _pending = null;
    _skip(pending.id, 'too_large');
  }

  void _skip(int id, String reason) {
    _event('screenshot_skipped', {'id': id, 'reason': reason});
  }

  /// Instrumentation events (§8) ride the debug log as one greppable line:
  /// `event_name key=value ...`, names exactly as specced.
  void _event(String name, Map<String, Object?> fields) {
    final rendered = fields.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join(' ');
    _log('$name $rendered');
  }

  void _log(String message, {bool isError = false}) {
    emit({'kind': 'log', 'message': message, 'error': isError});
  }

  int _nowMs() => _clock().millisecondsSinceEpoch;
}
