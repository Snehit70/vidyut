import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/design/widgets.dart';
import 'package:vidyut/src/design/theme.dart';
import 'package:vidyut/src/debug/debug_log.dart';
import 'package:vidyut/src/settings/app_settings.dart';
import 'package:vidyut/src/settings/settings_screen.dart';

void main() {
  testWidgets('renders settings content without an entrance delay', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildVidyutTheme(),
        home: SettingsScreen(
          settings: const AppSettings(),
          onChanged: (_) async {},
          debugLog: DebugLog(),
          paired: true,
          pairedDeviceName: 'Desk laptop',
          pairedDeviceAddress: '192.168.1.5:17321',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Theme'), findsOneWidget);
    expect(find.text('Sync with laptop'), findsOneWidget);
    expect(find.text('Connection'), findsOneWidget);
    expect(find.text('Clipboard & screenshots'), findsOneWidget);
    expect(find.text('Desk laptop'), findsOneWidget);
    expect(find.text('192.168.1.5:17321'), findsOneWidget);
    expect(find.byType(Card), findsNothing);
    expect(find.byType(Entrance), findsNothing);

    await tester.scrollUntilVisible(
      find.text('Troubleshooting'),
      500,
      scrollable: find.byType(Scrollable),
    );
    expect(find.text('Troubleshooting'), findsOneWidget);
  });

  testWidgets('shared entrance and press motion respect reduced motion', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildVidyutTheme(),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Column(
            children: [
              Entrance(index: 8, child: const Text('Entrance content')),
              PressableScale(child: const Text('Press content')),
              const PulsingDot(),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Entrance content'), findsOneWidget);
    expect(find.text('Press content'), findsOneWidget);
    expect(find.byType(Entrance), findsOneWidget);
    expect(find.byType(AnimatedScale), findsNothing);
  });
}
