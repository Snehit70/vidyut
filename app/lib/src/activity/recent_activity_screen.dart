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
    final visibleActivities = _activities
        .where((activity) => !_isTransfer(activity))
        .toList(growable: false);
    final todayCount = visibleActivities.where((activity) {
      return DateUtils.isSameDay(activity.timestamp, DateTime.now());
    }).length;

    return Scaffold(
      appBar: AppBar(title: const Text('Recent activity')),
      body: visibleActivities.isEmpty
          ? const Center(child: Text('No shared items yet.'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 8, 0, 28),
                  child: Text(
                    '$todayCount shared today',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                for (final group in _groupByDay(visibleActivities)) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      group.label,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  for (final activity in group.activities)
                    _ActivityListItem(
                      activity: activity,
                      deviceName: widget.deviceName,
                      onCopy: widget.onCopy,
                      onRetry: widget.onRetry,
                      onPreview: () => _showPreview(context, activity),
                    ),
                  const SizedBox(height: 28),
                ],
              ],
            ),
    );
  }

  Future<void> _showPreview(BuildContext context, LastActivity activity) {
    final path = activity.previewPath;
    if (path == null) return Future<void>.value();
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (context) => _PreviewViewer(activity: activity, path: path),
    );
  }
}

class _ActivityListItem extends StatelessWidget {
  const _ActivityListItem({
    required this.activity,
    required this.deviceName,
    required this.onCopy,
    required this.onRetry,
    required this.onPreview,
  });

  final LastActivity activity;
  final String deviceName;
  final Future<void> Function(LastActivity activity) onCopy;
  final Future<void> Function(LastActivity activity)? onRetry;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final received = activity.direction == ActivityDirection.received;
    final failed = activity.outcome == ActivityOutcome.failed;
    final copyable = received && !failed && _isCopyable(activity);
    final previewable = activity.previewPath != null && !failed;
    final retryable = failed && activity.retryable && onRetry != null;
    final counterpart = activity.counterpart == 'laptop'
        ? deviceName
        : activity.counterpart;
    final title = activity.title ?? _titleFromSummary(activity.summary);
    final status = failed
        ? received
              ? 'Failed from $counterpart'
              : 'Failed to $counterpart'
        : received
        ? 'Received from $counterpart'
        : 'Sent to $counterpart';

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60,
            child: Text(
              clockTime(activity.timestamp),
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
          _DirectionIcon(received: received, failed: failed),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        status,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: failed ? colors.error : colors.primary,
                        ),
                      ),
                    ),
                    if (previewable)
                      _PreviewThumbnail(
                        path: activity.previewPath!,
                        onTap: onPreview,
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  title,
                  maxLines: 2,
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
                if (activity.detail != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    activity.detail!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
                if (failed) ...[
                  const SizedBox(height: 8),
                  Text(
                    'This share could not be completed.',
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: colors.error),
                  ),
                ],
                if (copyable || previewable || retryable) ...[
                  const SizedBox(height: 12),
                  if (copyable)
                    _ActivityAction(
                      label: activity.summary.toLowerCase().startsWith('image')
                          ? 'Copy image'
                          : 'Copy text',
                      icon: Icons.content_copy_outlined,
                      onPressed: () => onCopy(activity),
                    )
                  else if (previewable)
                    _ActivityAction(
                      label: 'View preview',
                      icon: Icons.open_in_new_rounded,
                      onPressed: onPreview,
                    )
                  else if (retryable)
                    _ActivityAction(
                      label: 'Try again',
                      icon: Icons.refresh_rounded,
                      onPressed: () => onRetry!(activity),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActivityAction extends StatelessWidget {
  const _ActivityAction({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 20),
        label: Align(alignment: Alignment.centerLeft, child: Text(label)),
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
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: failed ? colors.errorContainer : colors.primaryContainer,
        shape: BoxShape.circle,
      ),
      child: Icon(
        failed
            ? Icons.warning_amber_rounded
            : received
            ? Icons.south_west
            : Icons.north_east,
        size: 20,
        color: failed ? colors.error : colors.primary,
      ),
    );
  }
}

class _PreviewThumbnail extends StatelessWidget {
  const _PreviewThumbnail({required this.path, required this.onTap});

  final String path;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'View image preview',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Ink(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(11),
            child: Image.file(
              File(path),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const _MediaPlaceholder(),
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewViewer extends StatelessWidget {
  const _PreviewViewer({required this.activity, required this.path});

  final LastActivity activity;
  final String path;

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: SafeArea(
        child: Stack(
          children: [
            InteractiveViewer(
              minScale: 0.5,
              maxScale: 4,
              child: Center(
                child: Image.file(
                  File(path),
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const _ViewerPlaceholder(),
                ),
              ),
            ),
            Positioned(
              top: 8,
              left: 8,
              child: IconButton.filledTonal(
                tooltip: 'Close preview',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
            Positioned(
              left: 20,
              right: 20,
              bottom: 16,
              child: Text(
                activity.title ?? 'Image preview',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MediaPlaceholder extends StatelessWidget {
  const _MediaPlaceholder();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.image_not_supported_outlined,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _ViewerPlaceholder extends StatelessWidget {
  const _ViewerPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(24),
      child: Text('Preview unavailable', style: TextStyle(color: Colors.white)),
    );
  }
}

class _ActivityGroup {
  const _ActivityGroup(this.label, this.activities);

  final String label;
  final List<LastActivity> activities;
}

List<_ActivityGroup> _groupByDay(List<LastActivity> activities) {
  final groups = <String, List<LastActivity>>{};
  for (final activity in activities) {
    final label = _dayLabel(activity.timestamp);
    groups.putIfAbsent(label, () => []).add(activity);
  }
  return [
    for (final entry in groups.entries) _ActivityGroup(entry.key, entry.value),
  ];
}

String _dayLabel(DateTime timestamp) {
  final now = DateTime.now();
  if (DateUtils.isSameDay(timestamp, now)) return 'Today';
  if (DateUtils.isSameDay(timestamp, now.subtract(const Duration(days: 1)))) {
    return 'Yesterday';
  }
  return '${timestamp.day}/${timestamp.month}/${timestamp.year}';
}

bool _isTransfer(LastActivity activity) {
  final summary = activity.summary.trim().toLowerCase();
  return summary == 'file' ||
      summary.endsWith(' file') ||
      summary.endsWith(' files') ||
      summary.contains(' file (') ||
      summary.contains(' files (');
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
