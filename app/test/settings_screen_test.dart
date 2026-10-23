import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/design/widgets.dart';
import 'package:vidyut/src/design/theme.dart';
import 'package:vidyut/src/debug/debug_log.dart';
import 'package:vidyut/src/onboarding/setup_actions.dart';
import 'package:vidyut/src/onboarding/setup_checklist_screen.dart';
import 'package:vidyut/src/pairing/pairing_repository.dart';
import 'package:vidyut/src/settings/app_settings.dart';
import 'package:vidyut/src/settings/app_settings_repository.dart';
import 'package:vidyut/src/settings/settings_screen.dart';
import 'package:vidyut/src/update/github_update_checker.dart';

import 'onboarding_test.dart' show FakeSetupActions;

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

    expect(find.text('Sync with laptop'), findsOneWidget);
    expect(find.text('Connection'), findsOneWidget);
    expect(find.text('Automatic sending'), findsOneWidget);
    expect(find.text('Desk laptop'), findsOneWidget);
    expect(find.text('192.168.1.5:17321'), findsOneWidget);
    expect(find.byType(Card), findsNothing);
    expect(find.byType(Entrance), findsNothing);

    await tester.scrollUntilVisible(
      find.text('Appearance'),
      500,
      scrollable: find.byType(Scrollable),
    );
    expect(find.text('Appearance'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Troubleshooting'),
      500,
      scrollable: find.byType(Scrollable),
    );
    expect(find.text('Troubleshooting'), findsOneWidget);
  });

  testWidgets('Laptop folders row opens the browser when paired', (
    tester,
  ) async {
    var opened = 0;
    Future<void> pump({required bool paired}) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildVidyutTheme(),
          home: SettingsScreen(
            settings: const AppSettings(),
            onChanged: (_) async {},
            debugLog: DebugLog(),
            paired: paired,
            onBrowseLaptop: () => opened += 1,
          ),
        ),
      );
      await tester.pump();
    }

    await pump(paired: false);
    expect(find.text('Laptop folders', skipOffstage: false), findsNothing);

    await pump(paired: true);
    await tester.scrollUntilVisible(
      find.text('Laptop folders'),
      500,
      scrollable: find.byType(Scrollable),
    );
    await tester.ensureVisible(find.text('Laptop folders'));
    await tester.pump();
    await tester.tap(find.text('Laptop folders'));
    await tester.pump();
    expect(opened, 1);
  });

  testWidgets(
    'groups settings by what they do and keeps forget with the laptop',
    (tester) async {
      tester.view.physicalSize = const Size(800, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildVidyutTheme(),
          home: SettingsScreen(
            settings: const AppSettings(),
            onChanged: (_) async {},
            debugLog: DebugLog(),
            paired: true,
            onForgetPairing: () async {},
            onBrowseLaptop: () {},
          ),
        ),
      );
      await tester.pump();

      double top(String text) => tester.getTopLeft(find.text(text)).dy;
      final headings = [
        'Connection',
        'Automatic sending',
        'Receiving files',
        'Notifications',
        'Appearance',
        'Troubleshooting',
      ];
      for (var i = 1; i < headings.length; i++) {
        expect(top(headings[i]), greaterThan(top(headings[i - 1])));
      }

      // The laptop's own rows sit together, destructive one last.
      expect(top('Sync with laptop'), lessThan(top('Laptop folders')));
      expect(top('Laptop folders'), lessThan(top('Forget this laptop')));
      expect(top('Forget this laptop'), lessThan(top('Automatic sending')));
      expect(find.text('Danger zone'), findsNothing);

      // Both alerts live under Notifications.
      for (final alert in [
        'Notify when something arrives',
        'File transfer alerts',
      ]) {
        expect(top(alert), greaterThan(top('Notifications')));
        expect(top(alert), lessThan(top('Appearance')));
      }
      expect(find.textContaining('payloads arrive'), findsNothing);
    },
  );

  testWidgets('theme is one tap on an inline choice', (tester) async {
    AppSettings? saved;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildVidyutTheme(),
        home: SettingsScreen(
          settings: const AppSettings(),
          onChanged: (next) async => saved = next,
        ),
      ),
    );
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('Dark'),
      500,
      scrollable: find.byType(Scrollable),
    );

    await tester.ensureVisible(find.text('Dark'));
    await tester.pump();
    await tester.tap(find.text('Dark'));
    await tester.pump();

    expect(saved?.themeMode, AppThemeMode.dark);
  });

  group('setup status', () {
    SetupStatusLoader loaderFor(FakeSetupActions actions) => SetupStatusLoader(
      actions: actions,
      settingsRepository: AppSettingsRepository(MemoryAppSettingsStorage()),
      pairingRepository: PairingRepository(MemoryPairingStorage()),
    );

    Future<void> pumpWith(WidgetTester tester, SetupStatusLoader loader) async {
      tester.view.physicalSize = const Size(800, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildVidyutTheme(),
          home: SettingsScreen(
            settings: const AppSettings(),
            onChanged: (_) async {},
            setupLoader: loader,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('leads the page while something needs attention', (
      tester,
    ) async {
      await pumpWith(tester, loaderFor(FakeSetupActions()));

      final banner = find.textContaining('setup items need attention');
      expect(banner, findsOneWidget);
      expect(
        tester.getTopLeft(banner).dy,
        lessThan(tester.getTopLeft(find.text('Connection')).dy),
      );

      await tester.tap(banner);
      await tester.pumpAndSettle();
      expect(find.byType(SetupChecklistScreen), findsOneWidget);
    });

    testWidgets('names Xiaomi switches only on a Xiaomi phone', (tester) async {
      await pumpWith(tester, loaderFor(FakeSetupActions()));
      expect(find.text('Permissions and battery.'), findsOneWidget);

      // A fresh tree: the screen reads the loader once, when it opens.
      await tester.pumpWidget(const SizedBox());
      await pumpWith(tester, loaderFor(FakeSetupActions()..miui = true));
      expect(
        find.text('Permissions, battery, and Xiaomi switches.'),
        findsOneWidget,
      );
    });
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
    // The version appears twice on purpose: in the release row, and again as the
    // label on the What's new row, so the two can be compared at a glance.
    expect(find.text('1.14.0'), findsNWidgets(2));
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
    expect(
      find.text('fix(shell): keep the brand mark by @snehit'),
      findsOneWidget,
    );
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
