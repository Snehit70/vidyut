import 'dart:async';

import 'package:flutter/material.dart';

import 'last_activity.dart';

class RecentActivityScreen extends StatefulWidget {
  const RecentActivityScreen({
    super.key,
    required this.activities,
    required this.onCopy,
    this.activityChanges,
  });

  final List<LastActivity> activities;
  final Future<void> Function(LastActivity activity) onCopy;
  final Stream<List<LastActivity>>? activityChanges;

  @override
  State<RecentActivityScreen> createState() => _RecentActivityScreenState();
}

class _RecentActivityScreenState extends State<RecentActivityScreen> {
  late List<LastActivity> _activities = widget.activities;
  StreamSubscription<List<LastActivity>>? _activitySubscription;
  Timer? _relativeTimeTimer;

  @override
  void initState() {
    super.initState();
    _activitySubscription = widget.activityChanges?.listen((activities) {
      if (mounted) setState(() => _activities = activities);
    });
    // Relative labels are intentionally low-frequency; this is feedback, not
    // a constantly moving dashboard.
    _relativeTimeTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
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
                      if (received && !failed)
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
