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

    expect(find.text('Failed from laptop'), findsOneWidget);
    expect(find.byTooltip('Retry transfer'), findsNothing);
  });

  testWidgets('shows factual presentation data and copy affordance', (
    tester,
  ) async {
    var copied = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildVidyutTheme(),
        home: RecentActivityScreen(
          activities: [
            LastActivity(
              direction: ActivityDirection.received,
              summary: 'image (1.2 MB)',
              title: 'IMG_1421.jpg',
              detail: '1.2 MB  •  image/jpeg',
              counterpart: 'laptop',
              timestamp: DateTime.now(),
            ),
          ],
          onCopy: (_) async => copied = true,
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('IMG_1421.jpg'), findsOneWidget);
    expect(find.text('Received from laptop'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy item'));
    expect(copied, isTrue);
  });

  testWidgets(
    'only exposes retry when a retry callback and transfer id exist',
    (tester) async {
      var retried = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildVidyutTheme(),
          home: RecentActivityScreen(
            activities: [
              LastActivity(
                direction: ActivityDirection.sent,
                summary: '1 file (with issues)',
                counterpart: 'laptop',
                timestamp: DateTime.now(),
                payloadId: 'transfer-1',
                outcome: ActivityOutcome.failed,
                retryable: true,
              ),
            ],
            onCopy: (_) async {},
            onRetry: (_) async => retried = true,
          ),
        ),
      );

      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Retry transfer'));
      expect(retried, isTrue);
    },
  );
}
