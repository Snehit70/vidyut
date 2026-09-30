import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/design/widgets.dart';
import 'package:vidyut/src/design/theme.dart';
import 'package:vidyut/src/debug/debug_log.dart';
import 'package:vidyut/src/settings/app_settings.dart';
import 'package:vidyut/src/settings/settings_screen.dart';
import 'package:vidyut/src/update/github_update_checker.dart';

/// A checker that answers with a fixed outcome and counts calls, so a test can
/// assert both what About says and that the check ran without a tap.
class _StubUpdateChecker extends GithubUpdateChecker {
  _StubUpdateChecker(this.result) : super(owner: 'Snehit70', repo: 'vidyut');

  final UpdateCheckResult result;
  int calls = 0;

  @override
  Future<UpdateCheckResult> check(String currentVersion) async {
    calls++;
    return result;
  }
}

const _newerRelease = UpdateAvailable(
  version: SemVer(1, 14, 0),
  tagName: 'v1.14.0',
  releaseNotes: 'Telemetry rows regrouped.',
  downloadUrl: 'https://example.invalid/vidyut.apk',
  assetName: 'vidyut.apk',
  sha256Url: 'https://example.invalid/vidyut.apk.sha256',
);

Future<void> _openSettings(
  WidgetTester tester,
  GithubUpdateChecker checker,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildVidyutTheme(),
      home: SettingsScreen(
        settings: const AppSettings(),
        onChanged: (_) async {},
        updateChecker: checker,
      ),
    ),
  );
  // Two pumps rather than pumpAndSettle. The masthead's progress spinner
  // animates forever, so settling would never terminate if a check were still
  // in flight. Both the version lookup and the stub check resolve in
  // microtasks, so these two pumps are enough to reach a settled state.
  await tester.pump();
  await tester.pump();
}

void main() {
  // Settings reads its own version through package_info_plus, and the About
  // release row will not resolve until it has one. Mock the channel so the
  // installed build is a known value instead of whatever the host reports.
  const packageInfo = MethodChannel('dev.fluttercommunity.plus/package_info');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(packageInfo, (call) async {
          if (call.method != 'getAll') return null;
          return <String, Object?>{
            'appName': 'Vidyut',
            'packageName': 'dev.snehit.vidyut',
            'version': '1.13.0',
            'buildNumber': '113',
            'buildSignature': '',
            'installerStore': null,
            'installTime': null,
            'updateTime': null,
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(packageInfo, null);
  });

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
    expect(
      find.descendant(
        of: find.byType(PulsingDot),
        matching: find.byType(AnimatedBuilder),
      ),
      findsNothing,
    );
    expect(tester.getSize(find.byType(PulsingDot)), const Size(26, 26));
  });

  testWidgets('about states the running build and reports the check on open', (
    tester,
  ) async {
    final checker = _StubUpdateChecker(const UpToDate());
    await _openSettings(tester, checker);

    await tester.scrollUntilVisible(
      find.text('About'),
      500,
      scrollable: find.byType(Scrollable),
    );

    // The check runs when Settings opens, not when someone taps Check. About is
    // meant to be readable before anyone touches it.
    expect(checker.calls, 1);

    // "Installed" separates the running build from the latest published one,
    // which the release row may contradict.
    expect(find.text('Installed 1.13.0'), findsOneWidget);

    // Up to date is a sentence, not a bare version number.
    expect(find.text('Up to date'), findsOneWidget);
    expect(find.textContaining('latest published build'), findsOneWidget);

    // The install action is absent when there is nothing to install. A button
    // that is always there and usually inert never says which state we are in.
    expect(find.text('Download and install'), findsNothing);

    // Check stays available as a retry.
    expect(find.widgetWithText(TextButton, 'Check'), findsOneWidget);
  });

  testWidgets('about offers the install action only when a release is newer', (
    tester,
  ) async {
    await _openSettings(tester, _StubUpdateChecker(_newerRelease));

    await tester.scrollUntilVisible(
      find.text('About'),
      500,
      scrollable: find.byType(Scrollable),
    );

    expect(find.text('Update available'), findsOneWidget);
    expect(find.text('1.14.0'), findsOneWidget);
    expect(find.text('Telemetry rows regrouped.'), findsOneWidget);
    // Found by text, not by type: FilledButton.tonal builds a private
    // subclass, so an exact-type finder would miss it.
    expect(find.text('Download and install'), findsOneWidget);
    expect(find.text('Up to date'), findsNothing);
  });

  testWidgets('about explains a failed check instead of reporting a version', (
    tester,
  ) async {
    await _openSettings(
      tester,
      _StubUpdateChecker(const UpdateCheckOffline('no route')),
    );

    await tester.scrollUntilVisible(
      find.text('About'),
      500,
      scrollable: find.byType(Scrollable),
    );

    // A failure must not read like a version comparison.
    expect(find.text('Cannot check right now'), findsOneWidget);
    expect(find.textContaining('could not reach GitHub'), findsOneWidget);
    expect(find.text('Up to date'), findsNothing);
    expect(find.text('Update available'), findsNothing);
  });

  testWidgets("about offers what's new once the build is current", (
    tester,
  ) async {
    // Up to date used to discard the release notes, which left nothing to read
    // in the common case. It now carries the notes for the running build.
    await _openSettings(
      tester,
      _StubUpdateChecker(
        const UpToDate(
          version: SemVer(1, 13, 0),
          releaseNotes: '* fix(shell): keep the brand mark by @snehit',
        ),
      ),
    );

    await tester.scrollUntilVisible(
      find.text('About'),
      500,
      scrollable: find.byType(Scrollable),
    );

    expect(find.text("What's new"), findsOneWidget);
    // The row is labelled with the release the notes describe, not the raw
    // installed string, so the two can be compared at a glance.
    expect(find.text('1.13.0'), findsOneWidget);

    await tester.tap(find.text("What's new"));
    await tester.pumpAndSettle();

    expect(find.text('Vidyut 1.13.0'), findsOneWidget);
    expect(find.text('fix(shell): keep the brand mark by @snehit'), findsOneWidget);
  });

  testWidgets('about hides what\'s new when the release carried no notes', (
    tester,
  ) async {
    await _openSettings(tester, _StubUpdateChecker(const UpToDate()));

    await tester.scrollUntilVisible(
      find.text('About'),
      500,
      scrollable: find.byType(Scrollable),
    );

    // A row leading to an empty screen is worse than no row.
    expect(find.text("What's new"), findsNothing);
  });
}
