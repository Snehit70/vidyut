import 'dart:convert';

/// Which way the most recent payload moved through the pool.
enum ActivityDirection { sent, received }

/// Whether the user-visible operation completed or needs attention.
enum ActivityOutcome { completed, failed }

/// The single most recent sync event, persisted so the home dashboard can
/// answer "when did this last work?" after an app restart (ADR 0004). Only
/// the newest event is kept — latest-write-wins, like the pool itself.
class LastActivity {
  const LastActivity({
    required this.direction,
    required this.summary,
    required this.counterpart,
    required this.timestamp,
    this.payloadId,
    this.outcome = ActivityOutcome.completed,
  });

  /// Whether the phone sent this payload or received it.
  final ActivityDirection direction;

  /// Human payload descriptor, e.g. "text (14 chars)" or "screenshot (1.2 MB)".
  final String summary;

  /// The other device — "laptop" today; kept explicit for when the pool grows.
  final String counterpart;

  final DateTime timestamp;

  final String? payloadId;

  final ActivityOutcome outcome;

  /// One line for the dashboard row, e.g. "text (14 chars) to laptop · 2m ago".
  String describe({DateTime? now}) {
    final preposition = direction == ActivityDirection.sent ? 'to' : 'from';
    return '$summary $preposition $counterpart · ${_relative(now ?? DateTime.now())}';
  }

  String _relative(DateTime now) {
    final delta = now.difference(timestamp);
    if (delta.inSeconds < 45) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
    if (delta.inHours < 24) return '${delta.inHours}h ago';
    return '${delta.inDays}d ago';
  }

  Map<String, Object?> toJson() => {
    'direction': direction.name,
    'summary': summary,
    'counterpart': counterpart,
    'ts': timestamp.millisecondsSinceEpoch,
    'outcome': outcome.name,
    if (payloadId != null) 'payloadId': payloadId,
  };

  static LastActivity? fromJson(Map<String, Object?> json) {
    final direction = ActivityDirection.values
        .where((value) => value.name == json['direction'])
        .firstOrNull;
    final summary = json['summary'];
    final counterpart = json['counterpart'];
    final ts = json['ts'];
    final payloadId = json['payloadId'];
    final outcomeName = json['outcome'];
    final outcome = ActivityOutcome.values
        .where((value) => value.name == outcomeName)
        .firstOrNull;
    if (direction == null ||
        summary is! String ||
        counterpart is! String ||
        ts is! int) {
      return null;
    }
    return LastActivity(
      direction: direction,
      summary: summary,
      counterpart: counterpart,
      timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
      payloadId: payloadId is String ? payloadId : null,
      outcome: outcome ?? ActivityOutcome.completed,
    );
  }

  String encode() => jsonEncode(toJson());

  static LastActivity? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return fromJson(decoded.cast<String, Object?>());
    } on FormatException {
      return null;
    }
  }
}
