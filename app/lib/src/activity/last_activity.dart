import 'dart:convert';

/// Which way the most recent payload moved through the pool.
enum ActivityDirection { sent, received }

/// Whether the user-visible operation completed or needs attention.
enum ActivityOutcome { completed, failed }

/// A sync event persisted for the home dashboard and recent-activity timeline.
class LastActivity {
  const LastActivity({
    required this.direction,
    required this.summary,
    required this.counterpart,
    required this.timestamp,
    this.payloadId,
    this.outcome = ActivityOutcome.completed,
    this.retryable = false,
    this.title,
    this.detail,
    this.excerpt,
    this.previewPath,
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

  /// Whether the event has a supported retry action.
  final bool retryable;

  /// Optional factual display data for the activity timeline. These fields
  /// are deliberately separate from [summary] so older events remain valid.
  final String? title;
  final String? detail;
  final String? excerpt;
  final String? previewPath;

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
    if (retryable) 'retryable': true,
    if (title != null) 'title': title,
    if (detail != null) 'detail': detail,
    if (excerpt != null) 'excerpt': excerpt,
    if (previewPath != null) 'previewPath': previewPath,
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
      retryable: json['retryable'] == true,
      title: json['title'] is String ? json['title'] as String : null,
      detail: json['detail'] is String ? json['detail'] as String : null,
      excerpt: json['excerpt'] is String ? json['excerpt'] as String : null,
      previewPath: json['previewPath'] is String
          ? json['previewPath'] as String
          : null,
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
