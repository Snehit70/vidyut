import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A single debug event: connection state, auth result, payload event, error.
@immutable
class DebugLogEntry {
  const DebugLogEntry({
    required this.timestamp,
    required this.category,
    required this.message,
    this.isError = false,
  });

  final DateTime timestamp;
  final String category;
  final String message;
  final bool isError;
}

/// In-memory ring buffer of debug events for the in-app debug view.
///
/// Lives in the UI isolate: service-isolate events arrive over the task data
/// channel and are appended here by the UI. Nothing is persisted — the log
/// exists to debug the live session.
class DebugLog extends ChangeNotifier {
  DebugLog({this.capacity = 200, DateTime Function()? clock})
    : clock = clock ?? DateTime.now;

  final int capacity;
  final DateTime Function() clock;
  final _entries = ListQueue<DebugLogEntry>();
  bool _loaded = false;
  static const _storageKey = 'vidyut.debug.log.v1';

  /// Entries oldest-first.
  List<DebugLogEntry> get entries => List.unmodifiable(_entries);

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final preferences = await SharedPreferences.getInstance();
    final rows = preferences.getStringList(_storageKey) ?? const [];
    for (final row in rows) {
      try {
        final json = jsonDecode(row);
        if (json is! Map) continue;
        final timestamp = DateTime.tryParse(json['timestamp'] as String? ?? '');
        final category = json['category'];
        final message = json['message'];
        if (timestamp == null || category is! String || message is! String) {
          continue;
        }
        _entries.addLast(
          DebugLogEntry(
            timestamp: timestamp,
            category: category,
            message: message,
            isError: json['isError'] == true,
          ),
        );
      } on FormatException {
        // Ignore a damaged row and retain the rest of the support trail.
      }
    }
    _trim();
    notifyListeners();
  }

  void add(String category, String message, {bool isError = false}) {
    _entries.addLast(
      DebugLogEntry(
        timestamp: clock(),
        category: category,
        message: message,
        isError: isError,
      ),
    );
    _trim();
    notifyListeners();
    _persist();
  }

  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
    _persist();
  }

  String exportText() {
    final buffer = StringBuffer('Vidyut diagnostics\n');
    for (final entry in _entries) {
      buffer.writeln(
        '${entry.timestamp.toIso8601String()} '
        '[${entry.category}]${entry.isError ? ' ERROR' : ''} ${entry.message}',
      );
    }
    return buffer.toString();
  }

  void _trim() {
    while (_entries.length > capacity) {
      _entries.removeFirst();
    }
  }

  void _persist() {
    final rows = _entries
        .map(
          (entry) => jsonEncode({
            'timestamp': entry.timestamp.toIso8601String(),
            'category': entry.category,
            'message': entry.message,
            'isError': entry.isError,
          }),
        )
        .toList();
    SharedPreferences.getInstance().then(
      (preferences) => preferences.setStringList(_storageKey, rows),
    );
  }
}

/// App-wide log shared by every screen; injectable copies are for tests.
final sharedDebugLog = DebugLog();
