import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

class TransferChunkMetadata {
  const TransferChunkMetadata({
    required this.transferId,
    required this.fileId,
    required this.offset,
    required this.plaintextBytes,
  });

  final String transferId;
  final String fileId;
  final int offset;
  final int plaintextBytes;
}

class EncryptedTransferChunk extends TransferChunkMetadata {
  const EncryptedTransferChunk({
    required super.transferId,
    required super.fileId,
    required super.offset,
    required super.plaintextBytes,
    required this.nonce,
    required this.ciphertext,
  });

  final String nonce;

  /// AES-GCM ciphertext followed by its 16-byte authentication tag.
  final List<int> ciphertext;
}

class TransferCrypto {
  TransferCrypto({Random? random}) : _random = random ?? Random.secure();

  static final _algorithm = AesGcm.with256bits();
  static final _kdf = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 200000,
    bits: 256,
  );
  static const _saltPrefix = 'vidyut-v1-file-transfer';

  final Random _random;
  final _derivedKeys = <String, Future<SecretKey>>{};

  Future<EncryptedTransferChunk> encrypt({
    required TransferChunkMetadata metadata,
    required List<int> plaintext,
    required String pairingSecret,
  }) async {
    if (plaintext.length != metadata.plaintextBytes) {
      throw const FormatException(
        'Chunk byte count does not match its metadata.',
      );
    }
    final nonce = _randomBytes(12);
    final nonceBase64 = base64Encode(nonce);
    final box = await _algorithm.encrypt(
      plaintext,
      secretKey: await _deriveKey(pairingSecret, metadata.transferId),
      nonce: nonce,
      aad: _associatedData(metadata, nonceBase64),
    );
    return EncryptedTransferChunk(
      transferId: metadata.transferId,
      fileId: metadata.fileId,
      offset: metadata.offset,
      plaintextBytes: metadata.plaintextBytes,
      nonce: nonceBase64,
      ciphertext: [...box.cipherText, ...box.mac.bytes],
    );
  }

  Future<List<int>> decrypt({
    required EncryptedTransferChunk chunk,
    required String pairingSecret,
  }) async {
    if (chunk.ciphertext.length < 16) {
      throw const FormatException('Transfer ciphertext is too short.');
    }
    final macOffset = chunk.ciphertext.length - 16;
    final plaintext = await _algorithm.decrypt(
      SecretBox(
        chunk.ciphertext.sublist(0, macOffset),
        nonce: base64Decode(chunk.nonce),
        mac: Mac(chunk.ciphertext.sublist(macOffset)),
      ),
      secretKey: await _deriveKey(pairingSecret, chunk.transferId),
      aad: _associatedData(chunk, chunk.nonce),
    );
    if (plaintext.length != chunk.plaintextBytes) {
      throw const FormatException(
        'Decrypted chunk byte count does not match its metadata.',
      );
    }
    return plaintext;
  }

  Future<String> sha256Hex(List<int> bytes) async {
    final hash = await Sha256().hash(bytes);
    return hash.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<SecretKey> _deriveKey(String pairingSecret, String transferId) {
    final cacheKey = '$pairingSecret\u0000$transferId';
    return _derivedKeys.putIfAbsent(cacheKey, () {
      return _kdf.deriveKey(
        secretKey: SecretKey(utf8.encode(pairingSecret)),
        nonce: utf8.encode('$_saltPrefix\u0000$transferId'),
      );
    });
  }

  List<int> _associatedData(TransferChunkMetadata metadata, String nonce) {
    return utf8.encode(
      jsonEncode({
        'v': 1,
        'transferId': metadata.transferId,
        'fileId': metadata.fileId,
        'offset': metadata.offset,
        'plaintextBytes': metadata.plaintextBytes,
        'nonce': nonce,
      }),
    );
  }

  List<int> _randomBytes(int length) {
    return List<int>.generate(length, (_) => _random.nextInt(256));
  }
}
