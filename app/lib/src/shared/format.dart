String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String clockTime(DateTime timestamp) {
  final hour = timestamp.hour == 0
      ? 12
      : timestamp.hour > 12
      ? timestamp.hour - 12
      : timestamp.hour;
  final minute = timestamp.minute.toString().padLeft(2, '0');
  return '$hour:$minute ${timestamp.hour >= 12 ? 'PM' : 'AM'}';
}

String relativeTime(
  DateTime timestamp, {
  DateTime? now,
  bool capitalize = false,
}) {
  final delta = (now ?? DateTime.now()).difference(timestamp);
  final label = delta.inSeconds < 45
      ? 'just now'
      : delta.inMinutes < 60
      ? '${delta.inMinutes}m ago'
      : delta.inHours < 24
      ? '${delta.inHours}h ago'
      : '${delta.inDays}d ago';
  return capitalize ? '${label[0].toUpperCase()}${label.substring(1)}' : label;
}
