import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vidyut/src/activity/last_activity.dart';
import 'package:vidyut/src/design/theme.dart';
import 'package:vidyut/src/home/home_screen.dart';
import 'package:vidyut/src/shared/relay_connection.dart';

void main() {
  testWidgets('prioritizes sync, sending files, and latest activity', (
    tester,
  ) async {
    var filesOpened = false;
    var settingsOpened = false;
    var activityOpened = false;
    var detailsOpened = false;
    var sendFilesPressed = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildVidyutTheme(),
        home: HomeScreen(
          connectionStatus: ConnectionStatus.connected,
          relayHealth: const RelayHealth(
            status: 'ok',
            relayName: 'Desk laptop',
            clipboardStatus: 'ok',
          ),
          lastActivity: LastActivity(
            direction: ActivityDirection.received,
            summary: 'text (42 chars)',
            counterpart: 'laptop',
            timestamp: DateTime.now(),
          ),
          onOpenFiles: () => filesOpened = true,
          onOpenSettings: () => settingsOpened = true,
          onOpenRecentActivity: () => activityOpened = true,
          onOpenConnectionDetails: () => detailsOpened = true,
          onSendFiles: () => sendFilesPressed = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Ready'), findsOneWidget);
    expect(find.text('Send files'), findsOneWidget);
    expect(find.text('Latest activity'), findsOneWidget);
    expect(find.text('text (42 chars) from laptop · just now'), findsOneWidget);
    expect(find.text('Setup'), findsNothing);
    expect(find.text('Desk laptop'), findsNothing);
    expect(find.text('192.168.1.20:17321'), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);

    await tester.tap(find.text('Send files'));
    await tester.tap(find.byTooltip('Files'));
    await tester.tap(find.byTooltip('Settings'));
    await tester.tap(find.text('Latest activity'));
    await tester.tap(find.text('Ready'));

    expect(sendFilesPressed, isTrue);
    expect(filesOpened, isTrue);
    expect(settingsOpened, isTrue);
    expect(activityOpened, isTrue);
    expect(detailsOpened, isTrue);
  });

  testWidgets('labels a connected but degraded clipboard path precisely', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildVidyutTheme(),
        home: HomeScreen(
          connectionStatus: ConnectionStatus.connected,
          relayHealth: const RelayHealth(
            status: 'degraded',
            relayName: 'Desk laptop',
            clipboardStatus: 'degraded',
            clipboardError: 'Clipboard watcher is unavailable.',
          ),
          onOpenFiles: () {},
          onOpenSettings: () {},
          onOpenRecentActivity: () {},
          onOpenConnectionDetails: () {},
          onSendFiles: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sync needs attention'), findsOneWidget);
    expect(find.text('Needs attention'), findsNothing);
    expect(
      find.text('Connected, but automatic clipboard sync needs recovery.'),
      findsOneWidget,
    );
  });
}
