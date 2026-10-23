import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'wire.dart';

class PayloadCrypto {
  PayloadCrypto({Random? random}) : _random = random ?? Random.secure();

  static final _algorithm = AesGcm.with256bits();
  static final _kdf = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 200000,
    bits: 256,
  );
  static final _salt = utf8.encode('vidyut-v1-pairing-secret');

  final Random _random;

  /// PBKDF2 at 200k iterations per call is pure waste when the pairing secret
  /// is fixed — cache the derived key per secret (push spec §4). Keyed rather
  /// than single-slot so a re-pair mid-session can't serve a stale key.
  final _derivedKeys = <String, Future<SecretKey>>{};

  Future<PayloadFrame> encrypt({
    required PayloadMetadata metadata,
    required List<int> plaintext,
    required String pairingSecret,
  }) async {
    final nonce = _randomBytes(12);
    final nonceBase64 = base64Encode(nonce);
    final frameMetadata = PayloadFrame(
      type: metadata.type,
      mime: metadata.mime,
      origin: metadata.origin,
      ts: metadata.ts,
      nonce: nonceBase64,
      payload: '',
    );
    final key = await _deriveKey(pairingSecret);
    final secretBox = await _algorithm.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
      aad: utf8.encode(frameMetadata.associatedData()),
    );

    return frameMetadata.copyWith(
      payload: base64Encode([...secretBox.cipherText, ...secretBox.mac.bytes]),
    );
  }

  Future<List<int>> decrypt({
    required PayloadFrame frame,
    required String pairingSecret,
  }) async {
    final encrypted = base64Decode(frame.payload);
    if (encrypted.length < 16) {
      throw const FormatException('Payload ciphertext is too short.');
    }
    final key = await _deriveKey(pairingSecret);
    final macOffset = encrypted.length - 16;
    final box = SecretBox(
      encrypted.sublist(0, macOffset),
      nonce: base64Decode(frame.nonce),
      mac: Mac(encrypted.sublist(macOffset)),
    );
    return _algorithm.decrypt(
      box,
      secretKey: key,
      aad: utf8.encode(frame.associatedData()),
    );
  }

  /// Seals a richer rendering of [frame]'s content. The associated data names
  /// the frame's nonce, so the alternative cannot be moved onto another frame.
  Future<PayloadAlternative> encryptAlternative({
    required PayloadFrame frame,
    required String mime,
    required List<int> plaintext,
    required String pairingSecret,
  }) async {
    final nonce = _randomBytes(12);
    final nonceBase64 = base64Encode(nonce);
    final key = await _deriveKey(pairingSecret);
    final secretBox = await _algorithm.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
      aad: _alternativeAssociatedData(frame, mime, nonceBase64),
    );
    return PayloadAlternative(
      mime: mime,
      nonce: nonceBase64,
      payload: base64Encode([...secretBox.cipherText, ...secretBox.mac.bytes]),
    );
  }

  Future<List<int>> decryptAlternative({
    required PayloadFrame frame,
    required PayloadAlternative alternative,
    required String pairingSecret,
  }) async {
    final encrypted = base64Decode(alternative.payload);
    if (encrypted.length < 16) {
      throw const FormatException('Alternative ciphertext is too short.');
    }
    final key = await _deriveKey(pairingSecret);
    final macOffset = encrypted.length - 16;
    final box = SecretBox(
      encrypted.sublist(0, macOffset),
      nonce: base64Decode(alternative.nonce),
      mac: Mac(encrypted.sublist(macOffset)),
    );
    return _algorithm.decrypt(
      box,
      secretKey: key,
      aad: _alternativeAssociatedData(
        frame,
        alternative.mime,
        alternative.nonce,
      ),
    );
  }

  /// Matches `alternativeAssociatedData` in src/shared/crypto.ts, key order
  /// included.
  List<int> _alternativeAssociatedData(
    PayloadFrame frame,
    String mime,
    String nonce,
  ) {
    return utf8.encode(
      jsonEncode({
        'v': 1,
        'kind': 'alt',
        'mime': mime,
        'nonce': nonce,
        'frameNonce': frame.nonce,
      }),
    );
  }

  Future<SecretKey> _deriveKey(String pairingSecret) {
    return _derivedKeys.putIfAbsent(pairingSecret, () {
      return _kdf.deriveKey(
        secretKey: SecretKey(utf8.encode(pairingSecret)),
        nonce: _salt,
      );
    });
  }

  List<int> _randomBytes(int length) {
    return List<int>.generate(length, (_) => _random.nextInt(256));
  }
}
