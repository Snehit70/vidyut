String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// The other device on an activity event. Empty or missing names stay the
/// generic token used before the relay hostname is known.
String activityCounterpart(String? deviceName) {
  final name = deviceName?.trim();
  if (name == null || name.isEmpty) return 'laptop';
  return name;
}

String mimeShortLabel(String mime) {
  final trimmed = mime.trim();
  final slash = trimmed.indexOf('/');
  if (slash < 0 || slash == trimmed.length - 1) return trimmed;
  return switch (trimmed.toLowerCase()) {
    'image/png' => 'PNG',
    'image/jpeg' || 'image/jpg' => 'JPEG',
    'image/webp' => 'WEBP',
    'image/gif' => 'GIF',
    'image/bmp' => 'BMP',
    _ => trimmed.substring(slash + 1).toUpperCase(),
  };
}

/// Size, MIME, and pixel size joined only when those facts are known.
String formatMediaDetail({
  required int bytes,
  String? mime,
  int? width,
  int? height,
}) {
  final parts = <String>[formatBytes(bytes)];
  final mimeLabel = mime == null || mime.trim().isEmpty
      ? null
      : mimeShortLabel(mime);
  if (mimeLabel != null && mimeLabel.isNotEmpty) parts.add(mimeLabel);
  if (width != null && height != null) parts.add('$width × $height');
  return parts.join('  •  ');
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
