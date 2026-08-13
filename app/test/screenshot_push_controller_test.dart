import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screenshot_observer/screenshot_observer.dart';

import 'package:vidyut/src/pairing/pairing_code.dart';
import 'package:vidyut/src/activity/last_activity.dart';
import 'package:vidyut/src/push/screenshot_push_controller.dart';
import 'package:vidyut/src/shared/payload_crypto.dart';
import 'package:vidyut/src/shared/relay_connection.dart';

void main() {
  test(
    'publishes a screenshot end to end and clears the slot on ack',
    () async {
      final harness = _Harness();
      await harness.connect();

      harness.controller.handleEvent(_event(id: 7, detectedAt: 1000));
      await _waitUntil(() => harness.published.length == 1);

      final frame = harness.published.single;
      expect(frame['type'], 'image');
      expect(frame['mime'], 'image/png');
      expect(frame['origin'], 'phone');
      expect(frame['ts'], 1000);

      expect(harness.logs, contains(startsWith('screenshot_read id=7 ')));
      expect(harness.logs.join('\n'), contains('attempts=1'));
      expect(
        harness.logs,
        contains(
          allOf(startsWith('screenshot_encrypted '), contains('ts=1000')),
        ),
      );
      expect(
        harness.logs,
        contains(allOf(startsWith('screenshot_publish '), contains('ts=1000'))),
      );

      harness.transport.receive({'v': 1, 'kind': 'ack', 'ts': 1000});
      await _waitUntil(
        () => harness.logs.any((l) => l.startsWith('screenshot_acked ')),
      );
      expect(harness.logs, contains(startsWith('screenshot_acked ts=1000 ')));

      // Slot cleared: a reconnect must not republish.
      await harness.reconnect();
      await _drain();
      expect(harness.published, hasLength(1));
      expect(
        harness.logs.where((l) => l.startsWith('screenshot_republished')),
        isEmpty,
      );
    },
  );

  test(
    'holds while disconnected and republishes verbatim on connect',
    () async {
      final harness = _Harness();
      harness.attach(); // attached but never authenticated

      harness.controller.handleEvent(_event(id: 3, detectedAt: 500));
      await _waitUntil(
        () => harness.logs.any((l) => l.startsWith('screenshot_held ')),
      );
      expect(harness.published, isEmpty);

      harness.transport.receive({'v': 1, 'kind': 'auth_ok'});
      await _waitUntil(() => harness.published.length == 1);
      expect(
        harness.logs,
        contains(
          allOf(startsWith('screenshot_republished '), contains('ts=500')),
        ),
      );
    },
  );

  test('re-sends an unacked frame verbatim after a reconnect', () async {
    final harness = _Harness();
    await harness.connect();

    harness.controller.handleEvent(_event(id: 9, detectedAt: 2000));
    await _waitUntil(() => harness.published.length == 1);
    final first = harness.published.single;

    // No ack arrives; the session is torn down and rebuilt.
    await harness.reconnect();
    await _waitUntil(() => harness.published.length == 2);

    expect(harness.published.last, first); // same nonce, same ciphertext
    expect(harness.logs, contains(startsWith('screenshot_republished ')));

    harness.transport.receive({'v': 1, 'kind': 'ack', 'ts': 2000});
    await _waitUntil(
      () => harness.logs.any((l) => l.startsWith('screenshot_acked ')),
    );
  });

  test('retries reads and succeeds within three attempts', () async {
    var calls = 0;
    final harness = _Harness(
      readImage: (id) async {
        calls++;
        if (calls < 3) {
          throw PlatformException(code: 'not-found');
        }
        return _bytes();
      },
    );
    await harness.connect();

    harness.controller.handleEvent(_event(id: 4, detectedAt: 100));
    await _waitUntil(() => harness.published.length == 1);

    expect(calls, 3);
    expect(harness.logs.join('\n'), contains('attempts=3'));
  });

  test('skips with read_failed after three failed attempts', () async {
    final harness = _Harness(
      readImage: (id) async => throw PlatformException(code: 'io-error'),
    );
    await harness.connect();

    harness.controller.handleEvent(_event(id: 5, detectedAt: 100));
    await _waitUntil(
      () => harness.logs.contains('screenshot_skipped id=5 reason=read_failed'),
    );
    expect(harness.published, isEmpty);
    expect(harness.activities, hasLength(1));
    expect(harness.activities.single.outcome, ActivityOutcome.failed);
  });

  test('skips an oversized screenshot before reading it', () async {
    var reads = 0;
    final harness = _Harness(
      readImage: (id) async {
        reads++;
        return _bytes();
      },
    );
    await harness.connect();

    harness.controller.handleEvent(
      _event(id: 6, detectedAt: 100, sizeBytes: 26 * 1024 * 1024),
    );
    await _drain();

    expect(reads, 0);
    expect(harness.logs, contains('screenshot_skipped id=6 reason=too_large'));
    expect(harness.activities.single.outcome, ActivityOutcome.failed);
  });

  test('re-checks the actual byte length against the hello cap', () async {
    final harness = _Harness(readImage: (id) async => _bytes(length: 200));
    await harness.connect(maxPayloadBytes: 100);

    // sizeBytes 0: MIUI still indexing, so the pre-check passes and the
    // post-read check must catch it.
    harness.controller.handleEvent(
      _event(id: 8, detectedAt: 100, sizeBytes: 0),
    );
    await _waitUntil(
      () => harness.logs.contains('screenshot_skipped id=8 reason=too_large'),
    );
    expect(harness.published, isEmpty);
    expect(harness.activities.single.outcome, ActivityOutcome.failed);
  });

  test(
    'burst resolves latest-wins: newest publishes, rest are superseded',
    () async {
      final gates = <int, Completer<void>>{};
      final harness = _Harness(
        readImage: (id) async {
          final gate = gates.putIfAbsent(id, Completer.new);
          await gate.future;
          return _bytes();
        },
      );
      await harness.connect();

      harness.controller.handleEvent(_event(id: 1, detectedAt: 100));
      await _drain();
      harness.controller.handleEvent(_event(id: 2, detectedAt: 200));
      harness.controller.handleEvent(_event(id: 3, detectedAt: 300));
      await _drain();

      // 2 was displaced from the waiting slot by 3 before ever starting.
      expect(
        harness.logs,
        contains('screenshot_skipped id=2 reason=superseded'),
      );

      gates[1]!.complete();
      await _waitUntil(
        () =>
            harness.logs.contains('screenshot_skipped id=1 reason=superseded'),
      );
      // 1 finished encrypting but a newer event was waiting: not published.
      expect(harness.published, isEmpty);

      gates[3]!.complete();
      await _waitUntil(() => harness.published.length == 1);
      expect(harness.published.single['ts'], 300);
    },
  );

  test('bumps a non-increasing detection ts by one millisecond', () async {
    final harness = _Harness();
    await harness.connect();

    harness.controller.handleEvent(_event(id: 1, detectedAt: 1000));
    await _waitUntil(() => harness.published.length == 1);
    harness.transport.receive({'v': 1, 'kind': 'ack', 'ts': 1000});
    await _drain();

    harness.controller.handleEvent(_event(id: 2, detectedAt: 1000));
    await _waitUntil(() => harness.published.length == 2);

    expect(harness.published.last['ts'], 1001);
  });

  test('drops the pending frame on a payload_too_large rejection', () async {
    final harness = _Harness();
    await harness.connect(maxPayloadBytes: 1024);

    harness.controller.handleEvent(_event(id: 11, detectedAt: 100));
    await _waitUntil(() => harness.published.length == 1);

    // Cap lowered relay-side between hold and publish: the relay rejects.
    harness.transport.receive({
      'v': 1,
      'kind': 'error',
      'code': 'payload_too_large',
      'message': 'Payload exceeds 10 bytes.',
    });
    await _waitUntil(
      () => harness.logs.contains('screenshot_skipped id=11 reason=too_large'),
    );

    // Not republished on the next connect: the loop is broken.
    await harness.reconnect();
    await _drain();
    expect(harness.published, hasLength(1));
    expect(harness.activities.single.outcome, ActivityOutcome.failed);
  });

  test('clearPending drops a held frame so toggle-off stays silent', () async {
    final harness = _Harness();
    harness.attach();

    harness.controller.handleEvent(_event(id: 12, detectedAt: 100));
    await _waitUntil(
      () => harness.logs.any((l) => l.startsWith('screenshot_held ')),
    );

    harness.controller.clearPending();
    harness.transport.receive({'v': 1, 'kind': 'auth_ok'});
    await _drain();

    expect(harness.published, isEmpty);
  });

  test('drops events arriving before any session attached a secret', () async {
    final harness = _Harness();

    harness.controller.handleEvent(_event(id: 13, detectedAt: 100));
    await _drain();

    expect(harness.published, isEmpty);
    expect(harness.logs, contains(contains('no pairing attached yet')));
  });
}

Future<void> _drain() => pumpEventQueue(times: 200);

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for condition.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Uint8List _bytes({int length = 64}) =>
    Uint8List.fromList(List.filled(length, 7));

ScreenshotEvent _event({
  required int id,
  required int detectedAt,
  int sizeBytes = 64,
}) {
  return ScreenshotEvent(
    id: id,
    uri: 'content://media/external/images/media/$id',
    displayName: 'Screenshot_$id.png',
    mimeType: 'image/png',
    sizeBytes: sizeBytes,
    dateAddedEpochSeconds: detectedAt ~/ 1000,
    detectedAtEpochMillis: detectedAt,
  );
}

class _Harness {
  _Harness({ScreenshotImageReader? readImage}) {
    controller = ScreenshotPushController(
      readImage: readImage ?? (id) async => _bytes(),
      crypto: PayloadCrypto(),
      emit: (message) {
        if (message['kind'] == 'log') logs.add(message['message'] as String);
      },
      onActivity: activities.add,
      // Fast retries keep the read_failed test quick.
      readRetryDelay: const Duration(milliseconds: 5),
    );
  }

  static const pairing = PairingCode(
    host: '127.0.0.1',
    port: 17321,
    secret: 'pairing-secret',
  );

  late final ScreenshotPushController controller;
  final logs = <String>[];
  final activities = <LastActivity>[];

  /// Frames that went out on the current transport, decoded.
  final published = <Map<String, Object?>>[];

  late _RecordingTransport transport;
  RelayConnection? _connection;

  /// Builds a fresh connection and attaches the controller, mirroring
  /// ServiceRelayController._sync.
  void attach() {
    transport = _RecordingTransport(published);
    final connection = RelayConnection(
      pairing: pairing,
      deviceId: 'phone',
      transport: transport,
    );
    _connection = connection;
    controller.attachSession(connection, pairingSecret: pairing.secret);
    unawaited(connection.start());
  }

  Future<void> connect({int? maxPayloadBytes}) async {
    attach();
    if (maxPayloadBytes != null) {
      transport.receive({
        'v': 1,
        'kind': 'hello',
        'challenge': 'relay-challenge',
        'maxPayloadBytes': maxPayloadBytes,
      });
    }
    transport.receive({'v': 1, 'kind': 'auth_ok'});
    await _drain();
  }

  /// Tears the session down and brings up a new authenticated one, the way a
  /// socket drop and backoff reconnect would.
  Future<void> reconnect() async {
    controller.detachSession();
    await _connection?.close();
    await connect();
  }
}

class _RecordingTransport implements RelayTransport {
  _RecordingTransport(this.published);

  final List<Map<String, Object?>> published;
  final _incoming = StreamController<Object?>();

  @override
  int? closeCode;

  @override
  String? closeReason;

  void receive(Map<String, Object?> message) {
    _incoming.add(jsonEncode(message));
  }

  @override
  Stream<Object?> get messages => _incoming.stream;

  @override
  void send(Map<String, Object?> message) {
    if (message['kind'] == 'publish') {
      published.add(message['frame'] as Map<String, Object?>);
    }
  }

  @override
  Future<void> close() async {
    if (!_incoming.isClosed) await _incoming.close();
  }
}
