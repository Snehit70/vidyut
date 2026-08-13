import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/design/widgets.dart';
import 'package:vidyut/src/design/theme.dart';
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
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Theme'), findsOneWidget);
    expect(find.text('Sync with laptop'), findsOneWidget);
    expect(find.byType(Entrance), findsNothing);
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
