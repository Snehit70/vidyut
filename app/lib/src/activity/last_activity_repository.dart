import 'dart:convert';
import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'last_activity.dart';

abstract interface class LastActivityStorage {
  Future<String?> read(String key);

  Future<Map<String, String>> readAll();

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
  Future<Map<String, String>> readAll() => _storage.readAll();

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
  Future<Map<String, String>> readAll() async => Map.of(_values);

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
  static const _eventPrefix = 'vidyut.activity.event.';
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
    final values = await _storage.readAll();
    final activities = <LastActivity>[];
    for (final entry in values.entries.where(
      (entry) => entry.key.startsWith(_eventPrefix),
    )) {
      final activity = LastActivity.decode(entry.value);
      if (activity != null) activities.add(activity);
    }

    final legacyHistory = values[_historyKey];
    if (legacyHistory != null) {
      try {
        final decoded = jsonDecode(legacyHistory);
        if (decoded is List) {
          activities.addAll(
            decoded.whereType<String>().map(LastActivity.decode).whereType(),
          );
        }
      } on FormatException {
        // Fall through to the legacy single-entry value.
      }
    }
    final legacy = LastActivity.decode(values[_key]);
    if (legacy != null) activities.add(legacy);

    activities.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final seen = <String>{};
    return activities
        .where((activity) {
          final identity = activity.payloadId == null
              ? '${activity.direction.name}|${activity.summary}|'
                    '${activity.counterpart}|${activity.timestamp.microsecondsSinceEpoch}'
              : 'payload:${activity.payloadId}';
          return seen.add(identity);
        })
        .take(_maxEntries)
        .toList(growable: false);
  }

  Future<void> record(LastActivity activity) {
    final next = _writeTail.then((_) async {
      final eventId =
          '${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(Object())}';
      await _storage.write('$_eventPrefix$eventId', activity.encode());
      await _storage.write(_key, activity.encode());
      if (!_changes.isClosed) _changes.add(await loadAll());
    });
    _writeTail = next.catchError((_) {});
    return next;
  }
}
