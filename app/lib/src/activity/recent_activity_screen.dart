import 'package:flutter/material.dart';

import '../design/palette.dart';
import 'last_activity.dart';

class RecentActivityScreen extends StatelessWidget {
  const RecentActivityScreen({
    super.key,
    required this.activities,
    required this.onCopy,
  });

  final List<LastActivity> activities;
  final Future<void> Function(LastActivity activity) onCopy;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recent activity')),
      body: activities.isEmpty
          ? const Center(child: Text('No shared items yet.'))
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              itemCount: activities.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final activity = activities[index];
                final received =
                    activity.direction == ActivityDirection.received;
                final direction = received ? 'Received from' : 'Sent to';
                return Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Palette.mist,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Palette.hairline),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: received ? Palette.petal : Palette.ground,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          received ? Icons.south_west : Icons.north_east,
                          color: received ? Palette.raspberry : Palette.muted,
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
                                  ?.copyWith(color: Palette.muted),
                            ),
                          ],
                        ),
                      ),
                      if (received)
                        IconButton(
                          tooltip: 'Copy item',
                          onPressed: () => onCopy(activity),
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
