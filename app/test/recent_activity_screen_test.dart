import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vidyut/src/activity/last_activity.dart';
import 'package:vidyut/src/activity/recent_activity_screen.dart';
import 'package:vidyut/src/design/theme.dart';

void main() {
  testWidgets('preserves direction in failed activity labels', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildVidyutTheme(),
        home: RecentActivityScreen(
          activities: [
            LastActivity(
              direction: ActivityDirection.received,
              summary: 'image',
              counterpart: 'laptop',
              timestamp: DateTime.now(),
              outcome: ActivityOutcome.failed,
            ),
          ],
          onCopy: (_) async {},
        ),
      ),
    );

    expect(find.text('Failed from laptop · just now'), findsOneWidget);
  });
}
