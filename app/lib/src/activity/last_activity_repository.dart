import 'dart:convert';
import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'last_activity.dart';

abstract interface class LastActivityStorage {
  Future<String?> read(String key);

  Future<void> write(String key, String value);
}

class SecureLastActivityStorage implements LastActivityStorage {
  const SecureLastActivityStorage([
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

class MemoryLastActivityStorage implements LastActivityStorage {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }
}

/// Latest-write-wins store for the newest sync event, read by the home
/// dashboard (ADR 0004). Persisted so "last activity" survives an app
/// restart; only ever holds one entry.
class LastActivityRepository {
  LastActivityRepository(this._storage);

  static const _key = 'vidyut.activity.last';
  static const _historyKey = 'vidyut.activity.history';
  static const _maxEntries = 30;

  final LastActivityStorage _storage;
  final _changes = StreamController<List<LastActivity>>.broadcast();
  Future<void> _writeTail = Future<void>.value();

  /// Emits the current timeline after a write in this isolate. Consumers that
  /// were backgrounded should still call [loadAll] on resume because the
  /// foreground service may have written through another isolate.
  Stream<List<LastActivity>> get changes => _changes.stream;

  Future<LastActivity?> load() async {
    return (await loadAll()).firstOrNull;
  }

  Future<List<LastActivity>> loadAll() async {
    final raw = await _storage.read(_historyKey);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          return decoded
              .whereType<String>()
              .map(LastActivity.decode)
              .whereType<LastActivity>()
              .toList(growable: false);
        }
      } on FormatException {
        // Fall through to the legacy single-entry value.
      }
    }
    final legacy = LastActivity.decode(await _storage.read(_key));
    return legacy == null ? const [] : [legacy];
  }

  Future<void> record(LastActivity activity) {
    final next = _writeTail.then((_) async {
      final history = await loadAll();
      final updated = [
        activity,
        ...history.where(
          (entry) =>
              activity.payloadId == null ||
              entry.payloadId != activity.payloadId,
        ),
      ].take(_maxEntries).toList(growable: false);
      await _storage.write(
        _historyKey,
        jsonEncode(updated.map((entry) => entry.encode()).toList()),
      );
      await _storage.write(_key, activity.encode());
      if (!_changes.isClosed) _changes.add(updated);
    });
    _writeTail = next.catchError((_) {});
    return next;
  }
}
