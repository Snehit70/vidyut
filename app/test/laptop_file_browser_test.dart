import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/browse/laptop_file_browser.dart';
import 'package:vidyut/src/pairing/pairing_code.dart';
import 'package:vidyut/src/shared/relay_connection.dart';
import 'package:vidyut/src/shared/session_seal.dart';

const _secret = 'pairing-secret';
const _pairing = PairingCode(host: '127.0.0.1', port: 17321, secret: _secret);

void main() {
  late List<_FakeLaptop> laptops;

  LaptopFileBrowser browser(
    FutureOr<Map<String, Object?>?> Function(Map<String, Object?> request)
    answer, {
    bool sharesFolders = true,
    Duration requestTimeout = const Duration(seconds: 5),
  }) {
    laptops = [];
    return LaptopFileBrowser(
      pairing: _pairing,
      connectionFactory: (pairing) {
        final laptop = _FakeLaptop(answer, sharesFolders: sharesFolders);
        laptops.add(laptop);
        return RelayConnection(
          pairing: pairing,
          deviceId: 'phone',
          transport: laptop,
        );
      },
      requestTimeout: requestTimeout,
    );
  }

  test('lists roots and a folder over a sealed session', () async {
    final requests = <Map<String, Object?>>[];
    final files = browser((request) {
      requests.add(request);
      return request['root'] == null
          ? {
              'ok': true,
              'roots': [
                {'id': '0', 'name': 'Downloads'},
              ],
            }
          : {
              'ok': true,
              'entries': [
                {'name': 'Trip', 'kind': 'folder', 'modifiedMs': 1000},
                {
                  'name': 'report.pdf',
                  'kind': 'file',
                  'size': 3,
                  'modifiedMs': 2000,
                },
              ],
              'truncated': true,
            };
    });

    final roots = await files.roots();
    final listing = await files.list('0', 'Trip/Day 1');

    expect(roots.single.name, 'Downloads');
    expect(listing.truncated, isTrue);
    expect(listing.entries.map((entry) => entry.name), ['Trip', 'report.pdf']);
    expect(listing.entries.first.isFolder, isTrue);
    expect(listing.entries.last.size, 3);
    expect(requests.last['path'], 'Trip/Day 1');
    expect(
      requests.map((request) => request['requestId']).toSet(),
      hasLength(2),
    );
    expect(laptops, hasLength(1), reason: 'requests share one session');
    expect(laptops.single.sawUnsealedControl, isFalse);
    await files.close();
  });

  test('pulls paths and reports what the laptop queued', () async {
    final files = browser(
      (request) => {
        'ok': true,
        'queued': {'files': 12, 'bytes': 4096},
      },
    );

    final queued = await files.pull('0', ['Trip', 'report.pdf']);

    expect(queued.files, 12);
    expect(queued.bytes, 4096);
    await files.close();
  });

  test('turns a refusal into a failure with the laptop code', () async {
    final files = browser(
      (request) => {
        'ok': false,
        'code': 'too_many_files',
        'message': 'Pull at most 1000 files at a time.',
      },
    );

    await expectLater(
      files.pull('0', ['']),
      throwsA(
        isA<BrowseFailure>()
            .having((failure) => failure.code, 'code', 'too_many_files')
            .having(
              (failure) => failure.message,
              'message',
              'Pull at most 1000 files at a time.',
            ),
      ),
    );
    await files.close();
  });

  test('says when the laptop does not share folders', () async {
    final files = browser((request) => null, sharesFolders: false);

    await expectLater(
      files.roots(),
      throwsA(
        isA<BrowseFailure>().having(
          (failure) => failure.code,
          'code',
          'browse_unavailable',
        ),
      ),
    );
    await files.close();
  });

  test('times out an unanswered request and keeps the session', () async {
    final files = browser(
      (request) => request['root'] == null ? null : {'ok': true, 'entries': []},
      requestTimeout: const Duration(milliseconds: 50),
    );

    await expectLater(
      files.roots(),
      throwsA(
        isA<BrowseFailure>().having(
          (failure) => failure.code,
          'code',
          'timeout',
        ),
      ),
    );
    expect((await files.list('0', '')).entries, isEmpty);
    expect(laptops, hasLength(1));
    await files.close();
  });

  test(
    'fails a waiting request when the laptop drops, then reconnects',
    () async {
      final files = browser(
        (request) => request['root'] == null
            ? null
            : {'ok': true, 'roots': <Object?>[], 'entries': <Object?>[]},
      );

      final waiting = files.roots();
      await pumpEventQueue();
      await laptops.single.disconnect();

      await expectLater(
        waiting,
        throwsA(
          isA<BrowseFailure>().having(
            (failure) => failure.code,
            'code',
            'offline',
          ),
        ),
      );
      expect((await files.list('0', '')).entries, isEmpty);
      expect(laptops, hasLength(2));
      await files.close();
    },
  );
}

/// Plays a laptop relay: proves itself, seals the session, and answers browse
/// requests with [answer]. A null answer is never sent.
class _FakeLaptop implements RelayTransport {
  _FakeLaptop(this.answer, {required this.sharesFolders}) {
    scheduleMicrotask(
      () => _deliver({
        'v': 1,
        'kind': 'hello',
        'challenge': _challenge,
        'maxPayloadBytes': 4096,
        'features': [
          'relay_proof',
          'sealed_control',
          if (sharesFolders) 'browse_files',
        ],
      }),
    );
  }

  static const _challenge = 'cmVsYXktY2hhbGxlbmdlLWJ5dGVz';

  final FutureOr<Map<String, Object?>?> Function(Map<String, Object?>) answer;
  final bool sharesFolders;
  final _incoming = StreamController<Object?>();
  SessionSealer? _sealer;
  bool sawUnsealedControl = false;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  Stream<Object?> get messages => _incoming.stream;

  @override
  void send(Map<String, Object?> message) {
    unawaited(_handle(message));
  }

  Future<void> _handle(Map<String, Object?> message) async {
    if (message['kind'] == 'auth') {
      final clientChallenge = message['clientChallenge']! as String;
      const features = ['sealed_control'];
      _deliver({
        'v': 1,
        'kind': 'auth_ok',
        'relayProof': await createRelayProof(
          pairingSecret: _secret,
          challenge: _challenge,
          clientChallenge: clientChallenge,
          sessionFeatures: features,
          deviceId: 'phone',
        ),
        'features': features,
      });
      _sealer = SessionSealer(
        await deriveSessionKey(
          pairingSecret: _secret,
          challenge: _challenge,
          clientChallenge: clientChallenge,
          deviceId: 'phone',
        ),
        SealDirection.relayToPhone,
      );
      return;
    }
    final sealer = _sealer!;
    if (message['kind'] != 'sealed') {
      sawUnsealedControl = true;
      return;
    }
    final request = await sealer.open(message);
    final reply = await answer(request);
    if (reply == null) return;
    _deliver(
      await sealer.seal({
        'v': 1,
        'kind': 'browse_result',
        'requestId': request['requestId'],
        ...reply,
      }),
    );
  }

  void _deliver(Map<String, Object?> message) {
    if (!_incoming.isClosed) _incoming.add(jsonEncode(message));
  }

  Future<void> disconnect() => _incoming.close();

  @override
  Future<void> close() async {
    if (!_incoming.isClosed) await _incoming.close();
  }
}
