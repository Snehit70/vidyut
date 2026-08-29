import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../shared/format.dart';
import 'last_activity.dart';

class RecentActivityScreen extends StatefulWidget {
  const RecentActivityScreen({
    super.key,
    required this.activities,
    required this.onCopy,
    this.deviceName = 'Laptop (Linux)',
    this.onRetry,
    this.activityChanges,
    this.loadActivities,
  });

  final List<LastActivity> activities;
  final Future<void> Function(LastActivity activity) onCopy;
  final String deviceName;
  final Future<void> Function(LastActivity activity)? onRetry;
  final Stream<List<LastActivity>>? activityChanges;
  final Future<List<LastActivity>> Function()? loadActivities;

  @override
  State<RecentActivityScreen> createState() => _RecentActivityScreenState();
}

class _RecentActivityScreenState extends State<RecentActivityScreen>
    with WidgetsBindingObserver {
  late List<LastActivity> _activities = widget.activities;
  var _activityRevision = 0;
  var _reloadGeneration = 0;
  StreamSubscription<List<LastActivity>>? _activitySubscription;
  Timer? _relativeTimeTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _activitySubscription = widget.activityChanges?.listen((activities) {
      _activityRevision++;
      _reloadGeneration++;
      if (mounted) setState(() => _activities = activities);
    });
    _relativeTimeTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant RecentActivityScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.activities, widget.activities)) {
      _activityRevision++;
      _reloadGeneration++;
      setState(() => _activities = widget.activities);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_reloadActivities());
  }

  Future<void> _reloadActivities() async {
    final load = widget.loadActivities;
    if (load == null) return;
    final request = ++_reloadGeneration;
    final revision = _activityRevision;
    final activities = await load();
    if (!mounted ||
        request != _reloadGeneration ||
        revision != _activityRevision) {
      return;
    }
    setState(() => _activities = activities);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _activitySubscription?.cancel();
    _relativeTimeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final todayCount = _activities.where((activity) {
      final timestamp = activity.timestamp;
      return timestamp.year == today.year &&
          timestamp.month == today.month &&
          timestamp.day == today.day;
    }).length;

    return Scaffold(
      appBar: AppBar(title: const Text('Recent activity')),
      body: _activities.isEmpty
          ? const Center(child: Text('No shared items yet.'))
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              itemCount: _activities.length + 1,
              separatorBuilder: (_, index) =>
                  SizedBox(height: index == 0 ? 16 : 12),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _DeviceSummary(
                    count: todayCount,
                    deviceName: widget.deviceName,
                  );
                }
                return _ActivityTimelineItem(
                  activity: _activities[index - 1],
                  deviceName: widget.deviceName,
                  onCopy: widget.onCopy,
                  onRetry: widget.onRetry,
                );
              },
            ),
    );
  }
}

class _DeviceSummary extends StatelessWidget {
  const _DeviceSummary({required this.count, required this.deviceName});

  final int count;
  final String deviceName;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Icon(
            Icons.laptop_mac_outlined,
            size: 22,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Text(deviceName, style: Theme.of(context).textTheme.titleSmall),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text('•', style: TextStyle(color: colors.onSurfaceVariant)),
          ),
          Text(
            '$count shared today',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _ActivityTimelineItem extends StatelessWidget {
  const _ActivityTimelineItem({
    required this.activity,
    required this.deviceName,
    required this.onCopy,
    required this.onRetry,
  });

  final LastActivity activity;
  final String deviceName;
  final Future<void> Function(LastActivity activity) onCopy;
  final Future<void> Function(LastActivity activity)? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final received = activity.direction == ActivityDirection.received;
    final failed = activity.outcome == ActivityOutcome.failed;
    final copyable = received && !failed && _isCopyable(activity);
    final retryable =
        failed &&
        activity.retryable &&
        onRetry != null &&
        activity.payloadId != null;
    final title = activity.title ?? _titleFromSummary(activity.summary);
    final detail = activity.detail ?? activity.summary;
    final counterpart = activity.counterpart == 'laptop'
        ? deviceName
        : activity.counterpart;
    final status = failed
        ? received
              ? 'Failed from $counterpart'
              : 'Failed to $counterpart'
        : received
        ? 'Received from $counterpart'
        : 'Sent to $counterpart';
    final dotColor = failed
        ? colors.error
        : received
        ? colors.primary
        : colors.onSurfaceVariant;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 28,
            child: CustomPaint(
              painter: _TimelineRailPainter(dotColor: dotColor),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
              decoration: BoxDecoration(
                color: failed
                    ? colors.errorContainer
                    : colors.secondaryContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  _DirectionIcon(received: received, failed: failed),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (activity.excerpt != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            '“${activity.excerpt}”',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                        const SizedBox(height: 6),
                        Text(
                          detail,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 10,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            _StatusPill(label: status, failed: failed),
                            Text(
                              '${clockTime(activity.timestamp)}  •  '
                              '${relativeTime(activity.timestamp, capitalize: true)}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: colors.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (activity.previewPath != null)
                    _Preview(path: activity.previewPath!),
                  if (copyable)
                    IconButton(
                      tooltip: 'Copy item',
                      onPressed: () => onCopy(activity),
                      icon: const Icon(Icons.content_copy_outlined),
                    )
                  else if (retryable)
                    IconButton(
                      tooltip: 'Retry transfer',
                      onPressed: () => onRetry!(activity),
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DirectionIcon extends StatelessWidget {
  const _DirectionIcon({required this.received, required this.failed});

  final bool received;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: failed
            ? colors.surface
            : received
            ? colors.primaryContainer
            : colors.surface,
        shape: BoxShape.circle,
      ),
      child: Icon(
        failed
            ? Icons.warning_amber_rounded
            : received
            ? Icons.south_west
            : Icons.north_east,
        size: 30,
        color: failed
            ? colors.error
            : received
            ? colors.primary
            : colors.onSurface,
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.failed});

  final String label;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: failed
            ? colors.error.withValues(alpha: 0.12)
            : colors.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: failed ? colors.error : colors.primary,
          ),
        ),
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.file(
        File(path),
        width: 72,
        height: 72,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const _MediaPlaceholder(),
      ),
    );
  }
}

class _MediaPlaceholder extends StatelessWidget {
  const _MediaPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 72,
      height: 72,
      color: Theme.of(context).colorScheme.surface,
      child: Icon(
        Icons.image_not_supported_outlined,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _TimelineRailPainter extends CustomPainter {
  const _TimelineRailPainter({required this.dotColor});

  final Color dotColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, 20);
    final line = Paint()
      ..color = dotColor.withValues(alpha: 0.28)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (var y = 38.0; y < size.height; y += 8) {
      canvas.drawLine(Offset(center.dx, y), Offset(center.dx, y + 4), line);
    }
    canvas.drawCircle(
      center,
      12,
      Paint()..color = dotColor.withValues(alpha: 0.12),
    );
    canvas.drawCircle(center, 5, Paint()..color = dotColor);
  }

  @override
  bool shouldRepaint(_TimelineRailPainter oldDelegate) =>
      oldDelegate.dotColor != dotColor;
}

bool _isCopyable(LastActivity activity) {
  final summary = activity.summary.toLowerCase();
  return summary.startsWith('text') || summary.startsWith('image');
}

String _titleFromSummary(String summary) {
  final lower = summary.toLowerCase();
  if (lower.startsWith('screenshot')) return 'Screenshot';
  if (lower.startsWith('text')) return 'Text';
  if (lower.startsWith('image')) return 'Image';
  return summary;
}
