import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/shared/transfer_crypto.dart';

void main() {
  const metadata = TransferChunkMetadata(
    transferId: 'transfer_1234567890',
    fileId: 'file_1234567890123',
    offset: 4096,
    plaintextBytes: 5,
  );

  group('transfer chunk crypto', () {
    test('round-trips an independently authenticated chunk', () async {
      final crypto = TransferCrypto(random: Random(7));
      final chunk = await crypto.encrypt(
        metadata: metadata,
        plaintext: [1, 2, 3, 4, 5],
        pairingSecret: 'pairing-secret',
      );

      expect(
        await crypto.decrypt(chunk: chunk, pairingSecret: 'pairing-secret'),
        [1, 2, 3, 4, 5],
      );
    });

    test('binds ciphertext to its offset', () async {
      final crypto = TransferCrypto(random: Random(7));
      final chunk = await crypto.encrypt(
        metadata: metadata,
        plaintext: [1, 2, 3, 4, 5],
        pairingSecret: 'pairing-secret',
      );
      final tampered = EncryptedTransferChunk(
        transferId: chunk.transferId,
        fileId: chunk.fileId,
        offset: 0,
        plaintextBytes: chunk.plaintextBytes,
        nonce: chunk.nonce,
        ciphertext: chunk.ciphertext,
      );

      expect(
        () => crypto.decrypt(chunk: tampered, pairingSecret: 'pairing-secret'),
        throwsA(isA<Object>()),
      );
    });

    test('rejects mismatched plaintext size before encryption', () {
      final crypto = TransferCrypto();

      expect(
        () => crypto.encrypt(
          metadata: metadata,
          plaintext: [1, 2],
          pairingSecret: 'pairing-secret',
        ),
        throwsFormatException,
      );
    });

    test('produces a lowercase whole-file SHA-256', () async {
      final hash = await TransferCrypto().sha256Hex([97, 98, 99]);

      expect(
        hash,
        'ba7816bf8f01cfea414140de5dae2223'
        'b00361a396177a9cb410ff61f20015ad',
      );
    });
  });
}
