import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vidyut/src/activity/last_activity.dart';
import 'package:vidyut/src/design/theme.dart';
import 'package:vidyut/src/home/home_screen.dart';
import 'package:vidyut/src/shared/relay_connection.dart';
import 'package:vidyut/src/shared/wire.dart';

void main() {
  testWidgets('prioritizes sync, sending files, and latest activity', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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

  testWidgets('exposes latest activity as a tappable semantics node', (
    tester,
  ) async {
    final semanticsHandle = tester.ensureSemantics();
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
          onOpenFiles: () {},
          onOpenSettings: () {},
          onOpenRecentActivity: () {},
          onOpenConnectionDetails: () {},
          onSendFiles: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final semantics = tester.getSemantics(
      find.bySemanticsLabel(
        'Latest activity. text (42 chars) from laptop · just now',
      ),
    );
    expect(
      semantics.getSemanticsData().hasAction(ui.SemanticsAction.tap),
      isTrue,
    );
    semanticsHandle.dispose();
  });

  testWidgets('uses a navigation rail on expanded widths', (tester) async {
    tester.view.physicalSize = const Size(900, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var filesOpened = false;

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
          onOpenFiles: () => filesOpened = true,
          onOpenSettings: () {},
          onOpenRecentActivity: () {},
          onOpenConnectionDetails: () {},
          onSendFiles: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Files'), findsOneWidget);
    expect(find.byTooltip('Files'), findsNothing);

    await tester.tap(find.text('Files'));
    expect(filesOpened, isTrue);
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

  testWidgets('renders searching and offline states in both themes', (
    tester,
  ) async {
    for (final theme in [buildVidyutTheme(), buildVidyutDarkTheme()]) {
      for (final entry in {
        ConnectionStatus.searching: 'Searching',
        ConnectionStatus.offline: 'Offline',
      }.entries) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: HomeScreen(
              connectionStatus: entry.key,
              onOpenFiles: () {},
              onOpenSettings: () {},
              onOpenRecentActivity: () {},
              onOpenConnectionDetails: () {},
              onSendFiles: () {},
            ),
          ),
        );
        await tester.pump();
        expect(find.text(entry.value), findsOneWidget);
      }
    }
  });

  testWidgets('keeps setup recovery visible when paired', (tester) async {
    var setupOpened = false;

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
          setupBannerLabel: 'Notifications are off',
          onOpenSetup: () => setupOpened = true,
          onOpenFiles: () {},
          onOpenSettings: () {},
          onOpenRecentActivity: () {},
          onOpenConnectionDetails: () {},
          onSendFiles: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Notifications are off'), findsOneWidget);
    await tester.tap(find.text('Notifications are off'));
    expect(setupOpened, isTrue);
  });

  testWidgets('renders live laptop telemetry when available', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

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
          laptopTelemetry: LaptopTelemetry(
            ts: DateTime.now().millisecondsSinceEpoch,
            batteryPercent: 88,
            batteryState: 'charging',
            cpuTemperatureCelsius: 65.4,
            memoryUsedBytes: 4 * 1073741824,
            memoryTotalBytes: 16 * 1073741824,
            storageUsedBytes: 250 * 1073741824,
            storageTotalBytes: 500 * 1073741824,
            cpuUsagePercent: 32.5,
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

    expect(find.text('Laptop telemetry'), findsOneWidget);
    expect(find.text('88%'), findsOneWidget);
    expect(find.text('Charging'), findsOneWidget);
    expect(find.text('65.4°C'), findsOneWidget);
    expect(find.text('Normal'), findsOneWidget);
    expect(find.text('4.0 GB / 16.0 GB'), findsOneWidget);
    expect(find.text('25% used • 12.0 GB free'), findsOneWidget);
    expect(find.text('250.0 GB / 500.0 GB'), findsOneWidget);
    expect(find.text('50% used • 250.0 GB free'), findsOneWidget);
    expect(find.text('33%'), findsOneWidget);
    expect(find.text('Low'), findsOneWidget);
  });

  testWidgets('renders stale laptop telemetry as unavailable', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

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
          laptopTelemetry: LaptopTelemetry(
            ts: DateTime.now().millisecondsSinceEpoch - 15000,
            batteryPercent: 88,
            batteryState: 'charging',
            cpuTemperatureCelsius: 65.4,
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

    expect(find.text('Laptop telemetry'), findsOneWidget);
    expect(find.text('88%'), findsNothing);
    expect(find.text('Unavailable'), findsWidgets);
    expect(find.text('Laptop disconnected'), findsNothing);
  });
}
