import 'dart:async';

import 'package:flutter/material.dart';

import 'last_activity.dart';

class RecentActivityScreen extends StatefulWidget {
  const RecentActivityScreen({
    super.key,
    required this.activities,
    required this.onCopy,
    this.activityChanges,
    this.loadActivities,
  });

  final List<LastActivity> activities;
  final Future<void> Function(LastActivity activity) onCopy;
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
    // Relative labels are intentionally low-frequency; this is feedback, not
    // a constantly moving dashboard.
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
    return Scaffold(
      appBar: AppBar(title: const Text('Recent activity')),
      body: _activities.isEmpty
          ? const Center(child: Text('No shared items yet.'))
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              itemCount: _activities.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final activity = _activities[index];
                final received =
                    activity.direction == ActivityDirection.received;
                final failed = activity.outcome == ActivityOutcome.failed;
                final copyable =
                    received &&
                    !failed &&
                    (activity.summary.startsWith('text') ||
                        activity.summary.startsWith('image'));
                final direction = failed
                    ? 'Failed'
                    : received
                    ? 'Received from'
                    : 'Sent to';
                final scheme = Theme.of(context).colorScheme;
                return Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: failed
                              ? scheme.errorContainer
                              : received
                              ? scheme.primaryContainer
                              : scheme.surface,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          failed
                              ? Icons.error_outline
                              : received
                              ? Icons.south_west
                              : Icons.north_east,
                          color: failed
                              ? scheme.error
                              : received
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              activity.summary,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '$direction ${activity.counterpart} · ${activity.describe().split('· ').last}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      if (copyable)
                        IconButton(
                          tooltip: 'Copy item',
                          onPressed: () => widget.onCopy(activity),
                          icon: const Icon(Icons.content_copy_outlined),
                        ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
