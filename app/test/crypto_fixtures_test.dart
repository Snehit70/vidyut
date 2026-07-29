import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/shared/pairing_auth.dart';
import 'package:vidyut/src/shared/payload_crypto.dart';
import 'package:vidyut/src/shared/wire.dart';

/// Replays fixture nonce bytes so encrypt reproduces the vector exactly.
class FixedRandom implements Random {
  FixedRandom(this._bytes);

  final List<int> _bytes;
  int _index = 0;

  @override
  int nextInt(int max) => _bytes[_index++] % max;

  @override
  bool nextBool() =>
      throw UnsupportedError('FixedRandom only supports nextInt');

  @override
  double nextDouble() =>
      throw UnsupportedError('FixedRandom only supports nextInt');
}

void main() {
  final fixtures =
      jsonDecode(
            File('../tests/fixtures/crypto-fixtures.json').readAsStringSync(),
          )
          as Map<String, Object?>;
  final payloadVectors = (fixtures['payloadVectors'] as List<Object?>)
      .cast<Map<String, Object?>>();
  final proofVectors = (fixtures['pairingProofVectors'] as List<Object?>)
      .cast<Map<String, Object?>>();

  for (final vector in payloadVectors) {
    final name = vector['name'] as String;
    final pairingSecret = vector['pairingSecret'] as String;
    final plaintext = base64Decode(vector['plaintextBase64'] as String);
    final frame = PayloadFrame.fromJson(vector['frame']);

    test('decrypts payload vector $name', () async {
      final decrypted = await PayloadCrypto().decrypt(
        frame: frame,
        pairingSecret: pairingSecret,
      );

      expect(base64Encode(decrypted), vector['plaintextBase64']);
    });

    test('re-encrypts payload vector $name byte-for-byte', () async {
      final crypto = PayloadCrypto(
        random: FixedRandom(base64Decode(frame.nonce)),
      );

      final encrypted = await crypto.encrypt(
        metadata: PayloadMetadata(
          type: frame.type,
          mime: frame.mime,
          origin: frame.origin,
          ts: frame.ts,
        ),
        plaintext: plaintext,
        pairingSecret: pairingSecret,
      );

      expect(encrypted, frame);
    });
  }

  test('rejects a fixture frame with the wrong pairing secret', () async {
    final frame = PayloadFrame.fromJson(payloadVectors.first['frame']);

    await expectLater(
      PayloadCrypto().decrypt(frame: frame, pairingSecret: 'wrong-secret'),
      throwsA(anything),
    );
  });

  test('rejects a fixture frame with tampered metadata', () async {
    final vector = payloadVectors.first;
    final frame = PayloadFrame.fromJson(vector['frame']);

    await expectLater(
      PayloadCrypto().decrypt(
        frame: frame.copyWith(ts: frame.ts + 1),
        pairingSecret: vector['pairingSecret'] as String,
      ),
      throwsA(anything),
    );
  });

  test('rejects a fixture frame with tampered ciphertext', () async {
    final vector = payloadVectors.first;
    final frame = PayloadFrame.fromJson(vector['frame']);
    final bytes = base64Decode(frame.payload);
    bytes[0] ^= 0xff;

    await expectLater(
      PayloadCrypto().decrypt(
        frame: frame.copyWith(payload: base64Encode(bytes)),
        pairingSecret: vector['pairingSecret'] as String,
      ),
      throwsA(anything),
    );
  });

  for (final vector in proofVectors) {
    test('reproduces pairing proof vector ${vector['name']}', () async {
      final proof = await createPairingProof(
        pairingSecret: vector['pairingSecret'] as String,
        challenge: vector['challenge'] as String,
        deviceId: vector['deviceId'] as String,
      );

      expect(proof, vector['proofBase64']);
    });
  }
}
