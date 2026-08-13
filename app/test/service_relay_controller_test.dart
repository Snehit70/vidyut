import 'dart:async';
import 'dart:io';

import 'package:clipboard_autosend/clipboard_autosend.dart';
import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screenshot_observer/screenshot_observer.dart';

import 'package:vidyut/src/foreground/service_relay_controller.dart';
import 'package:vidyut/src/pairing/pairing_code.dart';
import 'package:vidyut/src/push/screenshot_push_controller.dart';
import 'package:vidyut/src/receive/payload_receiver.dart';
import 'package:vidyut/src/receive/received_image_repository.dart';
import 'package:vidyut/src/receive/received_text_repository.dart';
import 'package:vidyut/src/settings/app_settings.dart';
import 'package:vidyut/src/share/share_publisher.dart';
import 'package:vidyut/src/shared/payload_crypto.dart';
import 'package:vidyut/src/shared/relay_connection.dart';
import 'package:vidyut/src/shared/transfer_crypto.dart';
import 'package:vidyut/src/shared/wire.dart';
import 'package:vidyut/src/transfer/phone_transfer_receiver.dart';
import 'package:vidyut/src/transfer/transfer_history.dart';

void main() {
  const pairing = PairingCode(
    host: '192.168.1.10',
    port: 17321,
    secret: 'pairing-secret',
  );

  test('reports offline and skips connecting when unpaired', () async {
    final harness = _Harness(pairing: null);

    await harness.controller.start();

    expect(harness.transports, isEmpty);
    expect(harness.emitted, [
      {
        'kind': 'log',
        'message': 'No pairing stored; staying offline.',
        'error': false,
      },
      {'kind': 'status', 'status': 'offline'},
    ]);
    expect(harness.notifications.single.title, 'Vidyut offline');
  });

  test('connects, forwards status, and updates the notification', () async {
    final harness = _Harness(pairing: pairing);

    await harness.controller.start();
    final transport = harness.transports.single;
    transport.receive({'v': 1, 'kind': 'auth_ok'});
    await _drain();

    expect(
      harness.emitted,
      contains(equals({'kind': 'status', 'status': 'connected'})),
    );
    expect(
      harness.emitted,
      containsAll([
        {
          'kind': 'log',
          'message': 'Connecting to relay at 192.168.1.10:17321.',
          'error': false,
        },
        {'kind': 'log', 'message': 'Auth accepted by relay.', 'error': false},
      ]),
    );
    expect(
      harness.notifications.map((n) => n.title),
      contains('Vidyut connected'),
    );
  });

  test('forwards relay errors as error log events', () async {
    final harness = _Harness(pairing: pairing);

    await harness.controller.start();
    final transport = harness.transports.single;
    transport.receive({
      'v': 1,
      'kind': 'error',
      'code': 'auth_failed',
      'message': 'Invalid proof.',
    });
    await _drain();

    expect(
      harness.emitted,
      contains(
        equals({
          'kind': 'log',
          'message': 'Relay error [auth_failed]: Invalid proof.',
          'error': true,
        }),
      ),
    );
    expect(harness.emitted.last, {'kind': 'status', 'status': 'offline'});
  });

  test('receives laptop payloads and forwards the result', () async {
    final harness = _Harness(pairing: pairing);

    await harness.controller.start();
    final transport = harness.transports.single;
    transport.receive({'v': 1, 'kind': 'auth_ok'});
    transport.receive({
      'v': 1,
      'kind': 'payload',
      'frame': (await _textFrame(
        'hello from laptop',
        origin: 'laptop',
      )).toJson(),
    });
    await _waitUntil(
      () => harness.emitted.any((message) => message['kind'] == 'receive'),
    );

    expect(harness.clipboard.texts, ['hello from laptop']);
    final receiveEvent = harness.emitted.firstWhere(
      (message) => message['kind'] == 'receive',
    );
    expect(receiveEvent['received'], isTrue);
    expect(receiveEvent['message'], 'Text copied from laptop.');
    expect(receiveEvent['type'], 'text');
    expect(receiveEvent['origin'], 'laptop');
    expect(receiveEvent['size'], greaterThan(0));
  });

  test('drops frames the phone itself published', () async {
    final harness = _Harness(pairing: pairing);

    await harness.controller.start();
    final transport = harness.transports.single;
    transport.receive({'v': 1, 'kind': 'auth_ok'});
    transport.receive({
      'v': 1,
      'kind': 'payload',
      'frame': (await _textFrame('echo', origin: 'phone')).toJson(),
    });
    // Give a same-origin frame ample time to (wrongly) reach the receiver.
    await Future<void>.delayed(const Duration(seconds: 3));

    expect(harness.clipboard.texts, isEmpty);
    expect(
      harness.emitted.where((message) => message['kind'] == 'receive'),
      isEmpty,
    );
  });

  test('sync command tears down and reconnects with fresh pairing', () async {
    final harness = _Harness(pairing: pairing);

    await harness.controller.start();
    expect(harness.transports, hasLength(1));

    await harness.controller.handleTaskData(const {'kind': 'sync'});

    expect(harness.transports, hasLength(2));
    expect(harness.transports.first.closed, isTrue);
    expect(harness.transports.last.closed, isFalse);
  });

  test('creates a fresh transfer receiver for each relay session', () async {
    final receivers = <PhoneTransferReceiver>[];
    final harness = _Harness(
      pairing: pairing,
      transferReceiverFactory: (_) {
        final receiver = PhoneTransferReceiver(
          history: TransferHistoryRepository(MemoryTransferHistoryStorage()),
        );
        receivers.add(receiver);
        return receiver;
      },
    );

    await harness.controller.start();
    expect(receivers, hasLength(1));

    await harness.controller.handleTaskData(const {'kind': 'sync'});

    expect(receivers, hasLength(2));
    await harness.controller.stop();
  });

  test(
    'receives a file through the replacement receiver after reconnect',
    () async {
      final bytes = [1, 2, 3];
      final crypto = TransferCrypto();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serving = server.listen((request) async {
        final segments = request.uri.pathSegments;
        final transferId = segments[2];
        final fileId = segments[3];
        final offset = int.parse(request.uri.queryParameters['offset']!);
        final encrypted = await crypto.encrypt(
          metadata: TransferChunkMetadata(
            transferId: transferId,
            fileId: fileId,
            offset: offset,
            plaintextBytes: bytes.length,
          ),
          plaintext: bytes,
          pairingSecret: 'pairing-secret',
        );
        request.response.headers
          ..set('x-vidyut-nonce', encrypted.nonce)
          ..set('x-vidyut-offset', '$offset')
          ..set('x-vidyut-plaintext-bytes', '${bytes.length}')
          ..set('x-vidyut-eof', 'true');
        request.response.add(encrypted.ciphertext);
        await request.response.close();
      });
      final root = await Directory.systemTemp.createTemp(
        'vidyut-service-reconnect-',
      );
      final history = TransferHistoryRepository(MemoryTransferHistoryStorage());
      final receivers = <PhoneTransferReceiver>[];
      final reconnectPairing = PairingCode(
        host: '127.0.0.1',
        port: server.port,
        secret: 'pairing-secret',
      );
      final harness = _Harness(
        pairing: reconnectPairing,
        reconnectBackoff: const [Duration(milliseconds: 20)],
        transferReceiverFactory: (_) {
          final receiver = PhoneTransferReceiver(
            history: history,
            crypto: crypto,
            rootDirectory: () async => root,
          );
          receivers.add(receiver);
          return receiver;
        },
      );

      try {
        await harness.controller.start();
        final first = harness.transports.single;
        first.receive({'v': 1, 'kind': 'auth_ok'});
        await _drain();

        await first.drop();
        await _waitUntil(() => harness.transports.length == 2);
        final replacement = harness.transports.last;
        replacement.receive({'v': 1, 'kind': 'auth_ok'});
        await _drain();

        replacement.receive({
          'v': 1,
          'kind': 'transfer_offer',
          'offer': {
            'transferId': 'transfer_1234567890',
            'batchId': 'batch_123456789012',
            'origin': 'laptop',
            'direction': 'laptop_to_phone',
            'createdAtMs': 1753689600000,
            'files': [
              {
                'fileId': 'file_1234567890123',
                'filename': 'reconnected.bin',
                'mime': 'application/octet-stream',
                'size': bytes.length,
                'lastModifiedMs': 1753689500000,
                'sha256': hashes.sha256.convert(bytes).toString(),
              },
            ],
          },
        });

        await _waitUntilAsync(() async {
          final batches = await history.load();
          return batches.isNotEmpty &&
              batches.single.status == PhoneTransferStatus.completed;
        });

        expect(receivers, hasLength(2));
        expect(await File('${root.path}/reconnected.bin').readAsBytes(), bytes);
        expect(
          replacement.sent.map((message) => message['kind']),
          contains('transfer_file_complete'),
        );
      } finally {
        await harness.controller.stop();
        await server.close(force: true);
        await serving.cancel();
        await root.delete(recursive: true);
      }
    },
  );

  test('sync command goes offline when pairing was reset', () async {
    final harness = _Harness(pairing: pairing);

    await harness.controller.start();
    harness.pairing = null;
    await harness.controller.handleTaskData(const {'kind': 'sync'});
    await _drain();

    expect(harness.transports.single.closed, isTrue);
    expect(harness.emitted.last, {'kind': 'status', 'status': 'offline'});
  });

  test('reconnects with backoff after the socket drops', () async {
    final harness = _Harness(
      pairing: pairing,
      reconnectBackoff: const [Duration(milliseconds: 20)],
    );

    await harness.controller.start();
    final transport = harness.transports.single;
    transport.receive({'v': 1, 'kind': 'auth_ok'});
    await _drain();

    await transport.drop();
    await _waitUntil(() => harness.transports.length == 2);
    harness.transports.last.receive({'v': 1, 'kind': 'auth_ok'});
    await _drain();

    expect(harness.emitted.last, {'kind': 'status', 'status': 'connected'});
    expect(
      harness.emitted,
      contains(
        equals({
          'kind': 'log',
          'message': 'Connection lost; retrying in 0s (attempt 1).',
          'error': false,
        }),
      ),
    );
  });

  test('successful reconnect resets the backoff schedule', () async {
    final harness = _Harness(
      pairing: pairing,
      reconnectBackoff: const [
        Duration(milliseconds: 20),
        Duration(minutes: 5),
      ],
    );

    await harness.controller.start();
    harness.transports.single.receive({'v': 1, 'kind': 'auth_ok'});
    await _drain();

    await harness.transports.single.drop();
    await _waitUntil(() => harness.transports.length == 2);
    harness.transports.last.receive({'v': 1, 'kind': 'auth_ok'});
    await _drain();

    // A second drop must start over at the first (short) delay, not
    // escalate to the five-minute entry.
    await harness.transports.last.drop();
    await _waitUntil(() => harness.transports.length == 3);

    expect(
      harness.emitted
          .where(
            (message) =>
                message['kind'] == 'log' &&
                (message['message'] as String).startsWith('Connection lost'),
          )
          .map((message) => message['message']),
      everyElement(contains('(attempt 1)')),
    );
  });

  test('stop cancels a pending reconnect', () async {
    final harness = _Harness(
      pairing: pairing,
      reconnectBackoff: const [Duration(milliseconds: 20)],
    );

    await harness.controller.start();
    harness.transports.single.receive({'v': 1, 'kind': 'auth_ok'});
    await _drain();

    await harness.transports.single.drop();
    await harness.controller.stop();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(harness.transports, hasLength(1));
  });

  test('skips the pool re-send of an already handled frame', () async {
    final harness = _Harness(
      pairing: pairing,
      reconnectBackoff: const [Duration(milliseconds: 20)],
    );
    final frame = await _textFrame('sticky payload', origin: 'laptop', ts: 7);

    await harness.controller.start();
    final transport = harness.transports.single;
    transport.receive({'v': 1, 'kind': 'auth_ok'});
    transport.receive({'v': 1, 'kind': 'payload', 'frame': frame.toJson()});
    await _waitUntil(() => harness.clipboard.texts.length == 1);

    // Drop and reconnect: the relay re-sends its current pool payload.
    await transport.drop();
    await _waitUntil(() => harness.transports.length == 2);
    final reconnected = harness.transports.last;
    reconnected.receive({'v': 1, 'kind': 'auth_ok'});
    reconnected.receive({'v': 1, 'kind': 'payload', 'frame': frame.toJson()});
    // Give the duplicate ample time to (wrongly) reach the receiver.
    await Future<void>.delayed(const Duration(seconds: 2));

    expect(harness.clipboard.texts, ['sticky payload']);

    // A genuinely new payload still comes through.
    final fresh = await _textFrame('fresh payload', origin: 'laptop', ts: 8);
    reconnected.receive({'v': 1, 'kind': 'payload', 'frame': fresh.toJson()});
    await _waitUntil(() => harness.clipboard.texts.length == 2);

    expect(harness.clipboard.texts, ['sticky payload', 'fresh payload']);
  });

  test('stop closes the connection', () async {
    final harness = _Harness(pairing: pairing);

    await harness.controller.start();
    await harness.controller.stop();

    expect(harness.transports.single.closed, isTrue);
  });

  test('default backoff caps at 32 seconds', () {
    expect(defaultReconnectBackoff.last, const Duration(seconds: 32));
    expect(defaultReconnectBackoff.map((d) => d.inSeconds), [2, 4, 8, 16, 32]);
  });

  group('screen-on trigger', () {
    test(
      'reconnects immediately and resets attempts while disconnected',
      () async {
        final harness = _Harness(
          pairing: pairing,
          // Effectively-never backoff: only the trigger can reconnect.
          reconnectBackoff: const [Duration(minutes: 5)],
        );

        await harness.controller.start();
        final transport = harness.transports.single;
        transport.receive({'v': 1, 'kind': 'auth_ok'});
        await _drain();

        await transport.drop();
        await _drain();
        expect(harness.transports, hasLength(1));

        harness.screenOn.add(null);
        await _waitUntil(() => harness.transports.length == 2);

        expect(
          harness.emitted,
          contains(
            equals({
              'kind': 'log',
              'message': 'Screen on while disconnected; reconnecting now.',
              'error': false,
            }),
          ),
        );

        // The trigger reset the attempt counter: the next scheduled retry
        // reports attempt 1 again.
        await harness.transports.last.drop();
        await _drain();
        expect(
          harness.emitted
              .where(
                (message) =>
                    message['kind'] == 'log' &&
                    (message['message'] as String).startsWith(
                      'Connection lost',
                    ),
              )
              .map((message) => message['message'])
              .last,
          contains('(attempt 1)'),
        );
      },
    );

    test('is a no-op while connected', () async {
      final harness = _Harness(pairing: pairing);

      await harness.controller.start();
      harness.transports.single.receive({'v': 1, 'kind': 'auth_ok'});
      await _drain();

      harness.screenOn.add(null);
      await _drain();

      expect(harness.transports, hasLength(1));
      expect(harness.transports.single.closed, isFalse);
    });

    test('is ignored after stop', () async {
      final harness = _Harness(pairing: pairing);

      await harness.controller.start();
      await harness.controller.stop();

      harness.screenOn.add(null);
      await _drain();

      expect(harness.transports, hasLength(1));
    });
  });

  group('wedge recovery (#35)', () {
    test(
      'sync proceeds past a transport whose close never completes',
      () async {
        final harness = _Harness(
          pairing: pairing,
          transportsHangOnClose: true,
          connectionCloseTimeout: const Duration(milliseconds: 50),
        );

        await harness.controller.start();
        harness.transports.single.receive({'v': 1, 'kind': 'auth_ok'});
        await _drain();

        await harness.controller.handleTaskData(const {'kind': 'sync'});

        expect(harness.transports, hasLength(2));
        expect(harness.transports.first.closed, isTrue);
      },
    );

    test('a timed-out sync step retries through the backoff', () async {
      var settingsLoads = 0;
      final harness = _Harness(
        pairing: pairing,
        reconnectBackoff: const [Duration(milliseconds: 20)],
        syncStepTimeout: const Duration(milliseconds: 60),
        loadSettings: () {
          settingsLoads += 1;
          if (settingsLoads == 1) return Completer<AppSettings>().future;
          return Future.value(const AppSettings());
        },
      );

      await harness.controller.start();
      await _waitUntil(() => harness.transports.length == 1);

      expect(
        harness.emitted,
        contains(
          equals({
            'kind': 'log',
            'message': 'Sync step timed out (load settings); retrying.',
            'error': true,
          }),
        ),
      );
    });

    test('watchdog abandons a stalled sync and reconnects', () async {
      var settingsLoads = 0;
      final harness = _Harness(
        pairing: pairing,
        watchdogInterval: const Duration(milliseconds: 40),
        syncStallTimeout: const Duration(milliseconds: 80),
        // Step bound out of the way: only the stall watchdog may recover.
        syncStepTimeout: const Duration(minutes: 5),
        loadSettings: () {
          settingsLoads += 1;
          if (settingsLoads == 1) return Completer<AppSettings>().future;
          return Future.value(const AppSettings());
        },
      );

      unawaited(harness.controller.start());
      await _waitUntil(() => harness.transports.length == 1);
      harness.transports.single.receive({'v': 1, 'kind': 'auth_ok'});
      await _drain();

      expect(
        harness.emitted,
        contains(
          equals({
            'kind': 'log',
            'message':
                'Watchdog: sync stalled; abandoning it and reconnecting.',
            'error': true,
          }),
        ),
      );
      expect(
        harness.emitted,
        contains(equals({'kind': 'status', 'status': 'connected'})),
      );
    });

    test('watchdog stays quiet while unpaired', () async {
      final harness = _Harness(
        pairing: null,
        watchdogInterval: const Duration(milliseconds: 30),
      );

      await harness.controller.start();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(harness.transports, isEmpty);
      expect(
        harness.emitted.where(
          (message) =>
              message['message'] == 'No pairing stored; staying offline.',
        ),
        hasLength(1),
      );
      expect(
        harness.emitted.where(
          (message) =>
              message['kind'] == 'log' &&
              (message['message'] as String).startsWith('Watchdog:'),
        ),
        isEmpty,
      );
    });

    test('overlapping sync requests coalesce into a follow-up pass', () async {
      var settingsGate = Completer<AppSettings>();
      var settingsLoads = 0;
      final harness = _Harness(
        pairing: pairing,
        loadSettings: () {
          settingsLoads += 1;
          return settingsGate.future;
        },
      );

      final first = harness.controller.start();
      // Both arrive while the first pass is parked on the settings load.
      await harness.controller.handleTaskData(const {'kind': 'sync'});
      await harness.controller.handleTaskData(const {'kind': 'sync'});
      settingsGate.complete(const AppSettings());
      settingsGate = Completer<AppSettings>()..complete(const AppSettings());
      await first;
      await _waitUntil(() => harness.transports.length == 2);

      // One in-flight pass plus exactly one coalesced follow-up — not three.
      expect(settingsLoads, 2);
      expect(harness.transports.first.closed, isTrue);
      expect(harness.transports.last.closed, isFalse);
    });
  });

  group('screenshot watcher', () {
    test(
      'starts the watcher when auto-push is on and access is full',
      () async {
        final watcher = _FakeScreenshotWatcher();
        final harness = _Harness(pairing: pairing, screenshotWatcher: watcher);

        await harness.controller.start();

        expect(watcher.starts, 1);
        expect(watcher.watching, isTrue);
        expect(
          harness.emitted,
          contains(
            equals({
              'kind': 'log',
              'message': 'Screenshot observer started.',
              'error': false,
            }),
          ),
        );
      },
    );

    test('does not start the watcher when auto-push is off', () async {
      final watcher = _FakeScreenshotWatcher();
      final harness = _Harness(
        pairing: pairing,
        settings: const AppSettings(autoPushScreenshots: false),
        screenshotWatcher: watcher,
      );

      await harness.controller.start();

      expect(watcher.starts, 0);
      expect(watcher.watching, isFalse);
    });

    test('enters the paused state on partial access', () async {
      final watcher = _FakeScreenshotWatcher(
        access: ScreenshotAccessLevel.partial,
      );
      final harness = _Harness(pairing: pairing, screenshotWatcher: watcher);

      await harness.controller.start();

      expect(watcher.starts, 0);
      expect(
        harness.emitted,
        contains(
          equals({
            'kind': 'screenshotAccess',
            'paused': true,
            'level': 'partial',
          }),
        ),
      );
      // The connected notification carries the paused text (§5).
      final transport = harness.transports.single;
      transport.receive({'v': 1, 'kind': 'auth_ok'});
      await _drain();
      expect(
        harness.notifications.map((n) => n.text),
        contains(contains('Auto-push paused')),
      );
    });

    test('logs the emitted stage for each screenshot event', () async {
      final watcher = _FakeScreenshotWatcher();
      final harness = _Harness(pairing: pairing, screenshotWatcher: watcher);

      await harness.controller.start();
      watcher.emitDiagnostic('screenshot onChange uri=content://x');
      watcher.emitEvent(_screenshotEvent(id: 42));
      await _drain();

      expect(
        harness.emitted,
        containsAll([
          {
            'kind': 'log',
            'message': 'screenshot onChange uri=content://x',
            'error': false,
          },
          {
            'kind': 'log',
            'message':
                'Screenshot emitted: id=42 name=Screenshot_42.png '
                'size=1000 detectedAt=1783608202412',
            'error': false,
          },
        ]),
      );
    });

    test('keeps the observer running across a reconnect', () async {
      final watcher = _FakeScreenshotWatcher();
      final harness = _Harness(
        pairing: pairing,
        reconnectBackoff: const [Duration(milliseconds: 20)],
        screenshotWatcher: watcher,
      );

      await harness.controller.start();
      expect(watcher.starts, 1);

      await harness.transports.single.drop();
      await _waitUntil(() => harness.transports.length == 2);

      // The reconnect re-runs _sync but must not churn the observer.
      expect(watcher.starts, 1);
      expect(watcher.stops, 0);
      expect(watcher.watching, isTrue);
    });

    test('feeds screenshot events into the push pipeline', () async {
      final watcher = _FakeScreenshotWatcher();
      final pushController = ScreenshotPushController(
        readImage: watcher.readImage,
        crypto: PayloadCrypto(),
        emit: (_) {},
      );
      final harness = _Harness(
        pairing: pairing,
        screenshotWatcher: watcher,
        pushController: pushController,
      );

      await harness.controller.start();
      final transport = harness.transports.single;
      transport.receive({'v': 1, 'kind': 'auth_ok'});
      await _drain();

      watcher.emitEvent(_screenshotEvent(id: 42));
      await _waitUntil(
        () => transport.sent.any((message) => message['kind'] == 'publish'),
      );

      final frame =
          transport.sent.firstWhere(
                (message) => message['kind'] == 'publish',
              )['frame']!
              as Map<String, Object?>;
      expect(frame['type'], 'image');
      expect(frame['origin'], 'phone');
      expect(frame['ts'], 1783608202412);
    });

    test('toggle off clears the pending pushed frame', () async {
      final watcher = _FakeScreenshotWatcher();
      final pushLogs = <Map<String, Object?>>[];
      final pushController = ScreenshotPushController(
        readImage: watcher.readImage,
        crypto: PayloadCrypto(),
        emit: pushLogs.add,
      );
      final harness = _Harness(
        pairing: pairing,
        screenshotWatcher: watcher,
        pushController: pushController,
      );

      // Offline session: the frame is encrypted and held.
      await harness.controller.start();
      watcher.emitEvent(_screenshotEvent(id: 43));
      await _waitUntil(
        () => pushLogs.any(
          (m) => (m['message'] as String).startsWith('screenshot_held'),
        ),
      );

      // Toggle flips off, UI sends sync: the hold must be cleared.
      harness.settings = const AppSettings(autoPushScreenshots: false);
      await harness.controller.handleTaskData(const {'kind': 'sync'});
      harness.transports.last.receive({'v': 1, 'kind': 'auth_ok'});
      await _drain();

      expect(
        harness.transports.last.sent.where(
          (message) => message['kind'] == 'publish',
        ),
        isEmpty,
      );
    });

    test('stop tears the watcher down', () async {
      final watcher = _FakeScreenshotWatcher();
      final harness = _Harness(pairing: pairing, screenshotWatcher: watcher);

      await harness.controller.start();
      await harness.controller.stop();

      expect(watcher.stops, 1);
      expect(watcher.watching, isFalse);
    });
  });

  group('clipboard auto-send watcher', () {
    test(
      'direct notification activity result sends without opening the app',
      () async {
        final watcher = _FakeAutoSendWatcher();
        final harness = _Harness(pairing: pairing, autoSendWatcher: watcher);

        await harness.controller.start();
        watcher.emitManual(
          const ManualClipboardReadResult(
            requestId: 1,
            status: ManualClipboardReadStatus.text,
            text: 'copied on phone',
          ),
        );
        await _waitUntil(() => harness.autoSendPublished.isNotEmpty);

        expect(harness.autoSendPublished, ['copied on phone']);
        expect(
          harness.notifications,
          contains((title: 'Vidyut sent to laptop', text: 'Copied text sent.')),
        );
      },
    );

    test('notification action reports an empty clipboard', () async {
      final watcher = _FakeAutoSendWatcher();
      final harness = _Harness(pairing: pairing, autoSendWatcher: watcher);

      await harness.controller.start();
      watcher.emitManual(
        const ManualClipboardReadResult(
          requestId: 1,
          status: ManualClipboardReadStatus.empty,
        ),
      );
      await _waitUntil(
        () => harness.notifications.any(
          (notification) =>
              notification.title == 'Vidyut could not send' &&
              notification.text == 'The clipboard has no text.',
        ),
      );

      expect(harness.autoSendPublished, isEmpty);
      expect(
        harness.notifications,
        contains((
          title: 'Vidyut could not send',
          text: 'The clipboard has no text.',
        )),
      );
    });

    test('notification action reports typed native read failures', () async {
      final cases = [
        (
          status: ManualClipboardReadStatus.unreadable,
          title: 'Vidyut could not send',
          text: 'Clipboard text could not be read.',
        ),
        (
          status: ManualClipboardReadStatus.focusTimeout,
          title: 'Vidyut could not send',
          text: 'Clipboard access timed out. Tap to try again.',
        ),
        (
          status: ManualClipboardReadStatus.busy,
          title: 'Vidyut is already sending',
          text: 'Wait for the current send to finish.',
        ),
      ];

      for (final testCase in cases) {
        final watcher = _FakeAutoSendWatcher();
        final harness = _Harness(pairing: pairing, autoSendWatcher: watcher);
        await harness.controller.start();

        watcher.emitManual(
          ManualClipboardReadResult(requestId: 1, status: testCase.status),
        );
        await _waitUntil(
          () => harness.notifications.any(
            (notification) =>
                notification.title == testCase.title &&
                notification.text == testCase.text,
          ),
        );

        expect(harness.autoSendPublished, isEmpty);
        await harness.controller.stop();
      }
    });

    test(
      'notification action rejects a second send while publishing',
      () async {
        final publishGate = Completer<SharePublishResult>();
        final watcher = _FakeAutoSendWatcher();
        final harness = _Harness(
          pairing: pairing,
          autoSendWatcher: watcher,
          autoSendGate: publishGate,
        );
        await harness.controller.start();

        const result = ManualClipboardReadResult(
          requestId: 1,
          status: ManualClipboardReadStatus.text,
          text: 'copied on phone',
        );
        watcher.emitManual(result);
        await _waitUntil(() => harness.autoSendPublished.length == 1);
        watcher.emitManual(result);
        await _waitUntil(
          () => harness.notifications.any(
            (notification) => notification.title == 'Vidyut is already sending',
          ),
        );

        expect(harness.autoSendPublished, ['copied on phone']);
        publishGate.complete(const SharePublishResult.published());
        await _waitUntil(
          () => harness.notifications.any(
            (notification) => notification.title == 'Vidyut sent to laptop',
          ),
        );
      },
    );

    test('notification action reports an unavailable publisher', () async {
      final watcher = _FakeAutoSendWatcher();
      final harness = _Harness(
        pairing: pairing,
        autoSendWatcher: watcher,
        provideAutoSendPublish: false,
      );
      await harness.controller.start();

      watcher.emitManual(
        const ManualClipboardReadResult(
          requestId: 1,
          status: ManualClipboardReadStatus.text,
          text: 'copied on phone',
        ),
      );
      await _waitUntil(
        () => harness.notifications.any(
          (notification) =>
              notification.text == 'Clipboard publisher is unavailable.',
        ),
      );

      expect(harness.autoSendPublished, isEmpty);
    });

    test('notification action records a failure when publish throws', () async {
      final watcher = _FakeAutoSendWatcher();
      final harness = _Harness(
        pairing: pairing,
        autoSendWatcher: watcher,
        autoSendError: StateError('publisher failed'),
      );
      await harness.controller.start();

      watcher.emitManual(
        const ManualClipboardReadResult(
          requestId: 1,
          status: ManualClipboardReadStatus.text,
          text: 'copied on phone',
        ),
      );
      await _waitUntil(
        () => harness.emitted.any(
          (message) =>
              message['kind'] == 'activity' && message['outcome'] == 'failed',
        ),
      );
    });

    test('stays inert when the setting is off (default)', () async {
      final watcher = _FakeAutoSendWatcher();
      final harness = _Harness(pairing: pairing, autoSendWatcher: watcher);

      await harness.controller.start();

      expect(watcher.starts, 0);
      expect(watcher.watching, isFalse);
    });

    test('starts when the setting is on and READ_LOGS is granted', () async {
      final watcher = _FakeAutoSendWatcher(granted: true);
      final harness = _Harness(
        pairing: pairing,
        settings: const AppSettings(enableClipboardAutoSend: true),
        autoSendWatcher: watcher,
      );

      await harness.controller.start();

      expect(watcher.starts, 1);
      expect(watcher.watching, isTrue);
    });

    test('stays inert when enabled but READ_LOGS is not granted', () async {
      final watcher = _FakeAutoSendWatcher(granted: false);
      final harness = _Harness(
        pairing: pairing,
        settings: const AppSettings(enableClipboardAutoSend: true),
        autoSendWatcher: watcher,
      );

      await harness.controller.start();

      expect(watcher.starts, 0);
      expect(watcher.watching, isFalse);
      expect(
        harness.emitted,
        contains(
          equals({
            'kind': 'log',
            'message':
                'Clipboard auto-send enabled but READ_LOGS not granted; '
                'watcher inert. Run the adb setup in Advanced.',
            'error': false,
          }),
        ),
      );
    });

    test('publishes an auto-read through the one send path', () async {
      final watcher = _FakeAutoSendWatcher(granted: true);
      final harness = _Harness(
        pairing: pairing,
        settings: const AppSettings(enableClipboardAutoSend: true),
        autoSendWatcher: watcher,
      );

      await harness.controller.start();
      watcher.emitText('copied on phone');
      await _waitUntil(() => harness.autoSendPublished.isNotEmpty);

      expect(harness.autoSendPublished, ['copied on phone']);
    });

    test('records a failure when automatic publish throws', () async {
      final watcher = _FakeAutoSendWatcher(granted: true);
      final harness = _Harness(
        pairing: pairing,
        settings: const AppSettings(enableClipboardAutoSend: true),
        autoSendWatcher: watcher,
        autoSendError: StateError('publisher failed'),
      );

      await harness.controller.start();
      watcher.emitText('copied on phone');
      await _waitUntil(
        () => harness.emitted.any(
          (message) =>
              message['kind'] == 'activity' && message['outcome'] == 'failed',
        ),
      );
    });

    test(
      'echo guard drops an auto-read equal to the last received write',
      () async {
        final watcher = _FakeAutoSendWatcher(granted: true);
        final harness = _Harness(
          pairing: pairing,
          settings: const AppSettings(enableClipboardAutoSend: true),
          autoSendWatcher: watcher,
        );

        await harness.controller.start();
        final transport = harness.transports.single;
        transport.receive({'v': 1, 'kind': 'auth_ok'});
        transport.receive({
          'v': 1,
          'kind': 'payload',
          'frame': (await _textFrame('from laptop', origin: 'laptop')).toJson(),
        });
        await _waitUntil(() => harness.clipboard.texts.contains('from laptop'));

        // The received write trips the watcher; the echo must be dropped.
        watcher.emitText('from laptop');
        await _drain();
        expect(harness.autoSendPublished, isEmpty);
        expect(
          harness.emitted,
          contains(
            equals({
              'kind': 'log',
              'message':
                  'Clipboard auto-send: echo guard dropped a received-payload '
                  're-read.',
              'error': false,
            }),
          ),
        );

        // Record consumed: a deliberate re-copy of the same text now sends.
        watcher.emitText('from laptop');
        await _waitUntil(() => harness.autoSendPublished.isNotEmpty);
        expect(harness.autoSendPublished, ['from laptop']);
      },
    );

    test('forwards watcher diagnostics into the debug log', () async {
      final watcher = _FakeAutoSendWatcher(granted: true);
      final harness = _Harness(
        pairing: pairing,
        settings: const AppSettings(enableClipboardAutoSend: true),
        autoSendWatcher: watcher,
      );

      await harness.controller.start();
      watcher.emitDiagnostic(
        "Clipboard auto-send watcher started: logcat filter='E ClipboardService' "
        '(API 35).',
      );
      await _drain();

      expect(
        harness.emitted,
        contains(
          equals({
            'kind': 'log',
            'message':
                "Clipboard auto-send watcher started: logcat filter='E "
                "ClipboardService' (API 35).",
            'error': false,
          }),
        ),
      );
    });

    test('stops the watcher when the setting flips off', () async {
      final watcher = _FakeAutoSendWatcher(granted: true);
      final harness = _Harness(
        pairing: pairing,
        settings: const AppSettings(enableClipboardAutoSend: true),
        autoSendWatcher: watcher,
      );

      await harness.controller.start();
      expect(watcher.watching, isTrue);

      harness.settings = const AppSettings(enableClipboardAutoSend: false);
      await harness.controller.handleTaskData(const {'kind': 'sync'});

      expect(watcher.stops, 1);
      expect(watcher.watching, isFalse);
    });

    test('keeps the watcher running across a reconnect', () async {
      final watcher = _FakeAutoSendWatcher(granted: true);
      final harness = _Harness(
        pairing: pairing,
        reconnectBackoff: const [Duration(milliseconds: 20)],
        settings: const AppSettings(enableClipboardAutoSend: true),
        autoSendWatcher: watcher,
      );

      await harness.controller.start();
      expect(watcher.starts, 1);

      await harness.transports.single.drop();
      await _waitUntil(() => harness.transports.length == 2);

      expect(watcher.starts, 1);
      expect(watcher.stops, 0);
      expect(watcher.watching, isTrue);
    });

    test('stop tears the watcher down', () async {
      final watcher = _FakeAutoSendWatcher(granted: true);
      final harness = _Harness(
        pairing: pairing,
        settings: const AppSettings(enableClipboardAutoSend: true),
        autoSendWatcher: watcher,
      );

      await harness.controller.start();
      await harness.controller.stop();

      expect(watcher.stops, 1);
      expect(watcher.watching, isFalse);
    });
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
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> _waitUntilAsync(
  Future<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for condition.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<PayloadFrame> _textFrame(
  String text, {
  required String origin,
  int ts = 1,
}) {
  return PayloadCrypto().encrypt(
    metadata: PayloadMetadata(
      type: PayloadType.text,
      mime: 'text/plain',
      origin: origin,
      ts: ts,
    ),
    plaintext: text.codeUnits,
    pairingSecret: 'pairing-secret',
  );
}

class _Harness {
  _Harness({
    required this.pairing,
    // Effectively "never" so tests without a reconnect stay deterministic.
    List<Duration> reconnectBackoff = const [Duration(minutes: 5)],
    this.settings = const AppSettings(),
    this.screenshotWatcher,
    this.autoSendWatcher,
    ScreenshotPushController? pushController,
    Duration syncStepTimeout = defaultSyncStepTimeout,
    Duration syncStallTimeout = defaultSyncStallTimeout,
    Duration watchdogInterval = defaultWatchdogInterval,
    Duration connectionCloseTimeout = RelayConnection.defaultCloseTimeout,
    bool transportsHangOnClose = false,
    bool provideAutoSendPublish = true,
    Completer<SharePublishResult>? autoSendGate,
    this.autoSendError,
    Future<AppSettings> Function()? loadSettings,
    ServiceTransferReceiverFactory? transferReceiverFactory,
  }) {
    controller = ServiceRelayController(
      reconnectBackoff: reconnectBackoff,
      syncStepTimeout: syncStepTimeout,
      syncStallTimeout: syncStallTimeout,
      watchdogInterval: watchdogInterval,
      screenshotWatcher: screenshotWatcher,
      pushController: pushController,
      clipboardAutoSendWatcher: autoSendWatcher,
      transferReceiverFactory: transferReceiverFactory,
      autoSendPublish: provideAutoSendPublish
          ? (payload) async {
              autoSendPublished.add(payload.text ?? '');
              if (autoSendError != null) throw autoSendError!;
              return autoSendGate?.future ?? autoSendResult;
            }
          : null,
      screenOnEvents: screenOn.stream,
      loadPairing: () async => pairing,
      loadSettings: loadSettings ?? () async => settings,
      connectionFactory: (pairing) {
        final transport = _FakeTransport(hangOnClose: transportsHangOnClose);
        transports.add(transport);
        return RelayConnection(
          pairing: pairing,
          deviceId: 'phone',
          transport: transport,
          closeTimeout: connectionCloseTimeout,
        );
      },
      receiverFactory: (_) => PayloadReceiver(
        crypto: PayloadCrypto(),
        clipboard: clipboard,
        imageClipboard: _SilentImageClipboard(),
        notifier: _SilentNotifier(),
        receivedTextRepository: ReceivedTextRepository(
          MemoryReceivedPayloadStorage(),
        ),
        receivedImageRepository: ReceivedImageRepository(
          MemoryReceivedPayloadStorage(),
          directoryProvider: () async =>
              Directory.systemTemp.createTemp('vidyut_relay_test'),
        ),
      ),
      emit: emitted.add,
      updateNotification: (title, text) async {
        notifications.add((title: title, text: text));
      },
    );
    // Mirror the production echo-guard clipboard wrapper: every received-text
    // write is recorded so the auto-send guard can drop the read it provokes.
    clipboard.onWrite = controller.recordReceivedClipboardText;
  }

  PairingCode? pairing;
  AppSettings settings;
  final screenOn = StreamController<void>.broadcast();
  final _FakeScreenshotWatcher? screenshotWatcher;
  final _FakeAutoSendWatcher? autoSendWatcher;
  late final ServiceRelayController controller;
  final transports = <_FakeTransport>[];
  final emitted = <Map<String, Object?>>[];
  final notifications = <({String title, String text})>[];
  final clipboard = _RecordingClipboard();
  final autoSendPublished = <String>[];
  final Object? autoSendError;
  SharePublishResult autoSendResult = const SharePublishResult.published();
}

class _FakeTransport implements RelayTransport {
  _FakeTransport({this.hangOnClose = false});

  /// Simulates a half-open socket whose close handshake never completes —
  /// the post-freeze state behind the 2026-07-12 wedge (#35).
  final bool hangOnClose;

  final _messages = StreamController<Object?>.broadcast();
  final sent = <Map<String, Object?>>[];
  bool closed = false;

  @override
  int? closeCode;

  @override
  String? closeReason;

  void receive(Map<String, Object?> message) => _messages.add(message);

  /// Simulates the peer vanishing: the message stream ends without the
  /// controller having asked for [close].
  Future<void> drop() => _messages.close();

  @override
  Stream<Object?> get messages => _messages.stream;

  @override
  void send(Map<String, Object?> message) {
    sent.add(message);
  }

  @override
  Future<void> close() async {
    closed = true;
    if (hangOnClose) return Completer<void>().future;
    await _messages.close();
  }
}

class _RecordingClipboard implements AndroidClipboard {
  final texts = <String>[];

  /// Mirrors production's `_EchoGuardClipboard`: invoked after each successful
  /// received-text write so the auto-send echo guard has a value to match.
  void Function(String text)? onWrite;

  @override
  Future<void> writeText(String text) async {
    texts.add(text);
    onWrite?.call(text);
  }
}

class _SilentImageClipboard implements AndroidImageClipboard {
  @override
  Future<void> writeImage(ReceivedImage image) async {}
}

class _SilentNotifier implements PayloadNotifier {
  @override
  Future<void> showTextReceipt(String preview, {required bool copied}) async {}

  @override
  Future<void> showImageReceipt(String mime, {required bool copied}) async {}

  @override
  Future<void> showMiuiClipboardHint() async {}
}

class _FakeScreenshotWatcher implements ScreenshotWatcher {
  _FakeScreenshotWatcher({this.access = ScreenshotAccessLevel.full});

  ScreenshotAccessLevel access;
  int starts = 0;
  int stops = 0;
  bool watching = false;
  bool failStart = false;

  final _events = StreamController<ScreenshotEvent>.broadcast();
  final _diagnostics = StreamController<String>.broadcast();

  void emitEvent(ScreenshotEvent event) => _events.add(event);

  void emitDiagnostic(String message) => _diagnostics.add(message);

  @override
  Future<ScreenshotAccessLevel> accessLevel() async => access;

  @override
  Future<void> start() async {
    starts++;
    if (failStart) {
      throw PlatformException(code: 'no-permission', message: access.name);
    }
    watching = true;
  }

  @override
  Future<void> stop() async {
    stops++;
    watching = false;
  }

  @override
  Future<Uint8List> readImage(int id) async =>
      Uint8List.fromList(List.filled(64, id % 256));

  @override
  Stream<ScreenshotEvent> get events => _events.stream;

  @override
  Stream<String> get diagnostics => _diagnostics.stream;
}

class _FakeAutoSendWatcher implements ClipboardAutoSendWatcher {
  _FakeAutoSendWatcher({this.granted = true});

  bool granted;
  int starts = 0;
  int stops = 0;
  bool watching = false;

  final _texts = StreamController<String>.broadcast();
  final _manualResults =
      StreamController<ManualClipboardReadResult>.broadcast();
  final _diagnostics = StreamController<String>.broadcast();

  void emitText(String text) => _texts.add(text);

  void emitManual(ManualClipboardReadResult result) =>
      _manualResults.add(result);

  void emitDiagnostic(String message) => _diagnostics.add(message);

  @override
  Future<void> updateNotification({
    required int notificationId,
    required String channelId,
    required String title,
    required String text,
  }) async {}

  @override
  Future<bool> hasReadLogsPermission() async => granted;

  @override
  Future<void> start() async {
    starts++;
    watching = true;
  }

  @override
  Future<void> stop() async {
    stops++;
    watching = false;
  }

  @override
  Stream<String> get texts => _texts.stream;

  @override
  Stream<ManualClipboardReadResult> get manualResults => _manualResults.stream;

  @override
  Stream<String> get diagnostics => _diagnostics.stream;
}

ScreenshotEvent _screenshotEvent({int id = 1}) {
  return ScreenshotEvent(
    id: id,
    uri: 'content://media/external/images/media/$id',
    displayName: 'Screenshot_$id.png',
    mimeType: 'image/png',
    sizeBytes: 1000,
    dateAddedEpochSeconds: 1783608202,
    detectedAtEpochMillis: 1783608202412,
  );
}
