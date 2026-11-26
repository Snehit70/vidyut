import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/pairing/pairing_code.dart';
import 'package:vidyut/src/pairing/pairing_repository.dart';
import 'package:vidyut/src/share/share_payload.dart';
import 'package:vidyut/src/share/share_publisher.dart';
import 'package:vidyut/src/shared/payload_crypto.dart';
import 'package:vidyut/src/shared/relay_connection.dart';
import 'package:vidyut/src/shared/wire.dart';

void main() {
  test('fails clearly when the phone is not paired', () async {
    final publisher = SharePublisher(
      pairingRepository: PairingRepository(MemoryPairingStorage()),
      relaySessionFactory: (_) => FakeRelaySession(),
      crypto: PayloadCrypto(),
      fileReader: FakeFileReader(),
    );

    final result = await publisher.publish(const SharePayload.text('hello'));

    expect(result.published, isFalse);
    expect(result.message, contains('Pair with the laptop relay'));
  });

  test('publishes an encrypted text share after connecting', () async {
    final storage = MemoryPairingStorage();
    final pairingRepository = PairingRepository(storage);
    await pairingRepository.save(
      const PairingCode(
        host: '127.0.0.1',
        port: 17321,
        secret: 'pairing-secret',
      ),
    );
    final session = FakeRelaySession();
    final publisher = SharePublisher(
      pairingRepository: pairingRepository,
      relaySessionFactory: (_) => session,
      crypto: PayloadCrypto(),
      fileReader: FakeFileReader(),
      clock: () => DateTime.fromMillisecondsSinceEpoch(1800000300000),
    );

    final resultFuture = publisher.publish(
      const SharePayload.text('hello laptop'),
    );
    await Future<void>.delayed(Duration.zero);
    session.connect();
    final result = await resultFuture;

    expect(result.published, isTrue);
    expect(session.published.single.type, PayloadType.text);
    expect(session.published.single.mime, 'text/plain');
    expect(session.published.single.origin, 'phone');
    expect(session.published.single.ts, 1800000300000);
    expect(
      utf8.decode(
        await PayloadCrypto().decrypt(
          frame: session.published.single,
          pairingSecret: 'pairing-secret',
        ),
      ),
      'hello laptop',
    );
  });

  for (final (opens, expected) in [
    (true, PayloadType.link),
    (false, PayloadType.text),
  ]) {
    test('a link goes as ${expected.name} when link opening is '
        '${opens ? 'on' : 'off'}', () async {
      final pairingRepository = PairingRepository(MemoryPairingStorage());
      await pairingRepository.save(
        const PairingCode(
          host: '127.0.0.1',
          port: 17321,
          secret: 'pairing-secret',
        ),
      );
      final session = FakeRelaySession();
      final publisher = SharePublisher(
        pairingRepository: pairingRepository,
        relaySessionFactory: (_) => session,
        crypto: PayloadCrypto(),
        fileReader: FakeFileReader(),
        openLinksOnLaptop: () async => opens,
      );

      final resultFuture = publisher.publish(
        const SharePayload.link('https://example.com'),
      );
      await Future<void>.delayed(Duration.zero);
      session.connect();
      final result = await resultFuture;

      expect(result.published, isTrue);
      expect(session.published.single.type, expected);
      expect(
        utf8.decode(
          await PayloadCrypto().decrypt(
            frame: session.published.single,
            pairingSecret: 'pairing-secret',
          ),
        ),
        'https://example.com',
      );
    });
  }

  test('publishes image file bytes with the source mime type', () async {
    final storage = MemoryPairingStorage();
    final pairingRepository = PairingRepository(storage);
    await pairingRepository.save(
      const PairingCode(
        host: '127.0.0.1',
        port: 17321,
        secret: 'pairing-secret',
      ),
    );
    final session = FakeRelaySession();
    final publisher = SharePublisher(
      pairingRepository: pairingRepository,
      relaySessionFactory: (_) => session,
      crypto: PayloadCrypto(),
      fileReader: FakeFileReader({
        '/tmp/photo.png': [1, 2, 3, 4],
      }),
      clock: () => DateTime.fromMillisecondsSinceEpoch(1800000300001),
    );

    final resultFuture = publisher.publish(
      const SharePayload.image(path: '/tmp/photo.png', mime: 'image/png'),
    );
    await Future<void>.delayed(Duration.zero);
    session.connect();
    final result = await resultFuture;

    expect(result.published, isTrue);
    expect(session.published.single.type, PayloadType.image);
    expect(session.published.single.mime, 'image/png');
    expect(
      await PayloadCrypto().decrypt(
        frame: session.published.single,
        pairingSecret: 'pairing-secret',
      ),
      [1, 2, 3, 4],
    );
  });

  test('returns an offline result if the relay cannot connect', () async {
    final storage = MemoryPairingStorage();
    final pairingRepository = PairingRepository(storage);
    await pairingRepository.save(
      const PairingCode(
        host: '127.0.0.1',
        port: 17321,
        secret: 'pairing-secret',
      ),
    );
    final session = FakeRelaySession();
    final publisher = SharePublisher(
      pairingRepository: pairingRepository,
      relaySessionFactory: (_) => session,
      crypto: PayloadCrypto(),
      fileReader: FakeFileReader(),
    );

    final resultFuture = publisher.publish(const SharePayload.text('hello'));
    await Future<void>.delayed(Duration.zero);
    session.disconnect();
    final result = await resultFuture;

    expect(result.published, isFalse);
    expect(result.message, 'Relay is offline.');
    expect(session.published, isEmpty);
  });
}

class FakeRelaySession implements RelaySession {
  final _status = StreamController<ConnectionStatus>.broadcast();
  final List<PayloadFrame> published = [];

  void connect() {
    _status.add(ConnectionStatus.connected);
  }

  void disconnect() {
    _status.add(ConnectionStatus.offline);
  }

  @override
  Stream<ConnectionStatus> get status => _status.stream;

  @override
  Future<void> start() async {}

  @override
  void publish(PayloadFrame frame) {
    published.add(frame);
  }

  @override
  Future<void> close() async {
    await _status.close();
  }
}

class FakeFileReader implements ShareFileReader {
  FakeFileReader([this.files = const {}]);

  final Map<String, List<int>> files;

  @override
  Future<List<int>> readBytes(String path) async {
    return files[path] ?? (throw StateError('Missing fixture for $path'));
  }
}
