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
          deviceName: 'laptop',
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
          deviceName: 'laptop',
          onCopy: (_) async => copied = true,
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('IMG_1421.jpg'), findsOneWidget);
    expect(find.text('Received from laptop'), findsOneWidget);
    await tester.tap(find.text('Copy image'));
    expect(copied, isTrue);
  });

  testWidgets('keeps file transfers out of recent activity', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildVidyutTheme(),
        home: RecentActivityScreen(
          activities: [
            LastActivity(
              direction: ActivityDirection.sent,
              summary: '2 files (with issues)',
              counterpart: 'laptop',
              timestamp: DateTime.now(),
              payloadId: 'transfer-1',
              outcome: ActivityOutcome.failed,
              retryable: true,
            ),
          ],
          deviceName: 'laptop',
          onCopy: (_) async {},
        ),
      ),
    );

    expect(find.text('No shared items yet.'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('opens image previews from the thumbnail action', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildVidyutTheme(),
        home: RecentActivityScreen(
          activities: [
            LastActivity(
              direction: ActivityDirection.sent,
              summary: 'screenshot (342.9 KB)',
              title: 'Screenshot.jpg',
              counterpart: 'laptop',
              timestamp: DateTime.now(),
              previewPath: '/tmp/missing-preview.jpg',
            ),
          ],
          deviceName: 'laptop',
          onCopy: (_) async {},
        ),
      ),
    );

    await tester.tap(find.text('View preview'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Close preview'), findsOneWidget);
    expect(find.text('Screenshot.jpg'), findsNWidgets(2));
  });

  testWidgets(
    'substitutes the screen device name for the generic laptop token',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildVidyutTheme(),
          home: RecentActivityScreen(
            activities: [
              LastActivity(
                direction: ActivityDirection.received,
                summary: 'text (4 chars)',
                counterpart: 'laptop',
                timestamp: DateTime.now(),
              ),
            ],
            deviceName: 'fedora',
            onCopy: (_) async {},
          ),
        ),
      );

      expect(find.text('Received from fedora'), findsOneWidget);
    },
  );

  testWidgets('keeps a real hostname even when the screen name differs', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildVidyutTheme(),
        home: RecentActivityScreen(
          activities: [
            LastActivity(
              direction: ActivityDirection.received,
              summary: 'text (4 chars)',
              counterpart: 'desk',
              timestamp: DateTime.now(),
            ),
          ],
          deviceName: 'fedora',
          onCopy: (_) async {},
        ),
      ),
    );

    expect(find.text('Received from desk'), findsOneWidget);
    expect(find.text('Received from fedora'), findsNothing);
  });
}
