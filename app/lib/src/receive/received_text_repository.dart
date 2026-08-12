import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class ReceivedPayloadStorage {
  Future<String?> read(String key);

  Future<void> write(String key, String value);
}

class SecureReceivedPayloadStorage implements ReceivedPayloadStorage {
  const SecureReceivedPayloadStorage([
    this._storage = const FlutterSecureStorage(),
  ]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) {
    return _storage.write(key: key, value: value);
  }
}

class MemoryReceivedPayloadStorage implements ReceivedPayloadStorage {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }
}

/// Latest-write-wins store for the newest text payload received from the
/// laptop, shared between the foreground service isolate (writer) and the
/// UI isolate (reader, on notification tap).
class ReceivedTextRepository {
  const ReceivedTextRepository(this._storage);

  static const _latestTextKey = 'vidyut.receive.latestText';
  static const _historyKey = 'vidyut.receive.textHistory';

  final ReceivedPayloadStorage _storage;

  Future<void> saveLatest(String text, {String? id}) async {
    await _storage.write(_latestTextKey, text);
    if (id == null) return;
    final history = _decodeHistory(await _storage.read(_historyKey));
    history.removeWhere((entry) => entry['id'] == id);
    history.insert(0, {'id': id, 'text': text});
    await _storage.write(_historyKey, jsonEncode(history.take(30).toList()));
  }

  Future<String?> loadLatest() => _storage.read(_latestTextKey);

  Future<String?> loadById(String id) async {
    for (final entry in _decodeHistory(await _storage.read(_historyKey))) {
      if (entry['id'] == id) return entry['text'];
    }
    return null;
  }

  List<Map<String, String>> _decodeHistory(String? raw) {
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((entry) => {'id': '${entry['id']}', 'text': '${entry['text']}'})
          .toList();
    } on FormatException {
      return [];
    }
  }
}
