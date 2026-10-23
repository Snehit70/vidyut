import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'pairing_code.dart';

abstract interface class PairingStorage {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

class SecurePairingStorage implements PairingStorage {
  const SecurePairingStorage([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) {
    return _storage.write(key: key, value: value);
  }

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class MemoryPairingStorage implements PairingStorage {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

class PairingRepository {
  const PairingRepository(this._storage);

  static const _hostKey = 'vidyut.pairing.host';
  static const _portKey = 'vidyut.pairing.port';
  static const _secretKey = 'vidyut.pairing.secret';
  static const _relayVerifiedKey = 'vidyut.pairing.relayVerified';

  final PairingStorage _storage;

  Future<PairingCode?> load() async {
    final host = await _storage.read(_hostKey);
    final port = await _storage.read(_portKey);
    final secret = await _storage.read(_secretKey);
    if (host == null || port == null || secret == null) return null;
    return PairingCode.parseManual(
      host: host,
      port: port,
      secret: secret,
      relayVerified: await _storage.read(_relayVerifiedKey) == 'true',
    );
  }

  Future<void> save(PairingCode pairing) async {
    await Future.wait([
      _storage.write(_hostKey, pairing.host),
      _storage.write(_portKey, pairing.port.toString()),
      _storage.write(_secretKey, pairing.secret),
      if (pairing.relayVerified)
        _storage.write(_relayVerifiedKey, 'true')
      else
        _storage.delete(_relayVerifiedKey),
    ]);
  }

  /// Records that the laptop holding [secret] proved itself. Skipped when the
  /// stored pairing has changed since that session started, so a re-pair is
  /// never pinned on the old laptop's word.
  Future<void> markRelayVerified(String secret) async {
    if (await _storage.read(_secretKey) != secret) return;
    await _storage.write(_relayVerifiedKey, 'true');
  }

  Future<void> reset() async {
    await Future.wait([
      _storage.delete(_hostKey),
      _storage.delete(_portKey),
      _storage.delete(_secretKey),
      _storage.delete(_relayVerifiedKey),
    ]);
  }
}
