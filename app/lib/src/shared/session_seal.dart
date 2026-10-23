import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Mutual auth and sealed control for one relay session (ADR 0023). Mirrors
/// `src/shared/session-seal.ts`; `tests/fixtures/crypto-fixtures.json` keeps
/// the two byte-for-byte equal.

/// Relay feature: `auth_ok` carries a proof that the relay holds the secret.
const relayProofFeature = 'relay_proof';

/// Session feature: control messages travel sealed under the session key.
const sealedControlFeature = 'sealed_control';

final _hmac = Hmac.sha256();

/// The challenges are base64 and the features come from a fixed set, so none
/// contains `:`; deviceId goes last so its own colons cannot shift a field.
Future<String> createRelayProof({
  required String pairingSecret,
  required String challenge,
  required String clientChallenge,
  required List<String> sessionFeatures,
  required String deviceId,
}) async {
  final mac = await _hmac.calculateMac(
    utf8.encode(
      'vidyut-relay-proof-v1:$challenge:$clientChallenge:'
      '${sessionFeatures.join(',')}:$deviceId',
    ),
    secretKey: SecretKey(utf8.encode(pairingSecret)),
  );
  return base64Encode(mac.bytes);
}

Future<bool> verifyRelayProof({
  required String pairingSecret,
  required String challenge,
  required String clientChallenge,
  required List<String> sessionFeatures,
  required String deviceId,
  required String proof,
}) async {
  final expected = utf8.encode(
    await createRelayProof(
      pairingSecret: pairingSecret,
      challenge: challenge,
      clientChallenge: clientChallenge,
      sessionFeatures: sessionFeatures,
      deviceId: deviceId,
    ),
  );
  final actual = utf8.encode(proof);
  if (expected.length != actual.length) return false;
  var difference = 0;
  for (var i = 0; i < expected.length; i++) {
    difference |= expected[i] ^ actual[i];
  }
  return difference == 0;
}

Future<List<int>> deriveSessionKey({
  required String pairingSecret,
  required String challenge,
  required String clientChallenge,
  required String deviceId,
}) async {
  final mac = await _hmac.calculateMac(
    utf8.encode('vidyut-session-v1:$challenge:$clientChallenge:$deviceId'),
    secretKey: SecretKey(utf8.encode(pairingSecret)),
  );
  return mac.bytes;
}

enum SealDirection {
  relayToPhone(0),
  phoneToRelay(1);

  const SealDirection(this.byte);

  final int byte;
}

/// Kinds that stay in the clear on a sealed session: their frames carry
/// their own end-to-end encryption.
bool travelsUnsealed(String? kind) => kind == 'publish' || kind == 'payload';

/// One direction pair of a sealed session. Nonces are the direction byte,
/// three zero bytes, then a 64-bit big-endian counter, so a nonce never
/// repeats under a key and a dropped, replayed, reordered or reflected message
/// fails to open.
///
/// Both calls are async, so callers keep the order: one [open] at a time in
/// arrival order, and each sealed message sent before the next is sealed.
class SessionSealer {
  SessionSealer(List<int> key, this.sendDirection)
    : _key = SecretKey(key),
      receiveDirection = sendDirection == SealDirection.relayToPhone
          ? SealDirection.phoneToRelay
          : SealDirection.relayToPhone;

  static final _algorithm = AesGcm.with256bits();

  final SecretKey _key;
  final SealDirection sendDirection;
  final SealDirection receiveDirection;
  int _sent = 0;
  int _received = 0;

  Future<Map<String, Object?>> seal(Map<String, Object?> message) async {
    final nonce = sealNonce(sendDirection, _sent++);
    final box = await _algorithm.encrypt(
      utf8.encode(jsonEncode(message)),
      secretKey: _key,
      nonce: nonce,
    );
    return {
      'v': 1,
      'kind': 'sealed',
      'nonce': base64Encode(nonce),
      'payload': base64Encode([...box.cipherText, ...box.mac.bytes]),
    };
  }

  /// Throws when [sealed] is not the next message from the peer, or was
  /// altered.
  Future<Map<String, Object?>> open(Map<String, Object?> sealed) async {
    final nonce = sealed['nonce'];
    final payload = sealed['payload'];
    if (nonce is! String || payload is! String) {
      throw const FormatException('Sealed message is malformed.');
    }
    final expected = sealNonce(receiveDirection, _received);
    final actual = base64Decode(nonce);
    if (!_bytesEqual(actual, expected)) {
      throw const FormatException('Sealed message is out of sequence.');
    }
    final bytes = base64Decode(payload);
    if (bytes.length < 16) {
      throw const FormatException('Sealed message is too short.');
    }
    final macOffset = bytes.length - 16;
    final plaintext = await _algorithm.decrypt(
      SecretBox(
        bytes.sublist(0, macOffset),
        nonce: expected,
        mac: Mac(bytes.sublist(macOffset)),
      ),
      secretKey: _key,
    );
    _received++;
    final decoded = jsonDecode(utf8.decode(plaintext));
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Sealed message must hold a JSON object.');
    }
    return decoded;
  }
}

Uint8List sealNonce(SealDirection direction, int counter) {
  final nonce = Uint8List(12);
  nonce[0] = direction.byte;
  ByteData.sublistView(nonce).setUint64(4, counter);
  return nonce;
}

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}
