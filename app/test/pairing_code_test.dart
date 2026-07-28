import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/pairing/pairing_code.dart';

void main() {
  test('parses the relay QR pairing code', () {
    const raw =
        '{"v":1,"service":"vidyut","host":"192.168.1.10","port":17321,"secret":"pairing-secret"}';

    final pairing = PairingCode.parse(raw);

    expect(pairing.host, '192.168.1.10');
    expect(pairing.port, 17321);
    expect(pairing.secret, 'pairing-secret');
  });

  test('parses a friendly laptop name when advertised', () {
    const raw =
        '{"v":1,"service":"vidyut","host":"192.168.1.10","port":17321,'
        '"secret":"pairing-secret","name":"framework"}';

    expect(PairingCode.parse(raw).name, 'framework');
  });

  test('parses manual host port and secret entry', () {
    final pairing = PairingCode.parseManual(
      host: '192.168.1.10',
      port: '17321',
      secret: 'pairing-secret',
    );

    expect(pairing.host, '192.168.1.10');
    expect(pairing.port, 17321);
    expect(pairing.secret, 'pairing-secret');
  });

  test('rejects pairing codes for another service', () {
    const raw =
        '{"v":1,"service":"other","host":"192.168.1.10","port":17321,"secret":"pairing-secret"}';

    expect(() => PairingCode.parse(raw), throwsA(isA<PairingCodeException>()));
  });
}
