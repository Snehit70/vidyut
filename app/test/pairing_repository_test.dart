import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/pairing/pairing_code.dart';
import 'package:vidyut/src/pairing/pairing_repository.dart';

void main() {
  test('persists pairing so it survives app restarts', () async {
    final storage = MemoryPairingStorage();
    final repository = PairingRepository(storage);
    const pairing = PairingCode(
      host: '192.168.1.10',
      port: 17321,
      secret: 'pairing-secret',
    );

    await repository.save(pairing);
    final restarted = PairingRepository(storage);

    expect(await restarted.load(), pairing);
  });

  test('resets pairing so a new relay can be paired', () async {
    final repository = PairingRepository(MemoryPairingStorage());
    await repository.save(
      const PairingCode(
        host: '192.168.1.10',
        port: 17321,
        secret: 'pairing-secret',
      ),
    );

    await repository.reset();

    expect(await repository.load(), isNull);
  });

  test('pins a verified relay until the phone is paired again', () async {
    final repository = PairingRepository(MemoryPairingStorage());
    const pairing = PairingCode(
      host: '192.168.1.10',
      port: 17321,
      secret: 'pairing-secret',
    );
    await repository.save(pairing);

    await repository.markRelayVerified('stale-secret');
    expect((await repository.load())!.relayVerified, isFalse);

    await repository.markRelayVerified('pairing-secret');
    expect((await repository.load())!.relayVerified, isTrue);

    await repository.save(pairing);
    expect((await repository.load())!.relayVerified, isFalse);
  });
}
