import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screenshot_observer/screenshot_observer.dart';

import 'package:vidyut/src/design/motion.dart';
import 'package:vidyut/src/onboarding/onboarding_wizard.dart';
import 'package:vidyut/src/onboarding/setup_actions.dart';
import 'package:vidyut/src/onboarding/setup_checklist_screen.dart';
import 'package:vidyut/src/onboarding/setup_status.dart';
import 'package:vidyut/src/pairing/pairing_code.dart';
import 'package:vidyut/src/pairing/pairing_repository.dart';
import 'package:vidyut/src/settings/app_settings.dart';
import 'package:vidyut/src/settings/app_settings_repository.dart';

class FakeSetupActions implements SetupActions {
  bool notifications = false;
  ScreenshotAccessLevel photos = ScreenshotAccessLevel.denied;
  bool battery = false;
  bool miui = false;
  ScreenshotAccessLevel photosAfterRequest = ScreenshotAccessLevel.full;
  final opened = <String>[];

  @override
  Future<bool> notificationsGranted() async => notifications;

  @override
  Future<void> requestNotifications() async => notifications = true;

  @override
  Future<ScreenshotAccessLevel> photosAccess() async => photos;

  @override
  Future<void> requestPhotos() async => photos = photosAfterRequest;

  @override
  Future<bool> batteryExempt() async => battery;

  @override
  Future<void> requestBatteryExemption() async => battery = true;

  @override
  Future<void> openAppSettings() async => opened.add('app-settings');

  @override
  Future<bool> isMiui() async => miui;

  @override
  Future<void> openAutostartSettings() async => opened.add('autostart');

  @override
  Future<void> openBatterySaverSettings() async => opened.add('battery');

  @override
  Future<void> openClipboardPermissionSettings() async =>
      opened.add('clipboard');
}

SetupStatus statusWith({
  bool notifications = true,
  ScreenshotAccessLevel photos = ScreenshotAccessLevel.full,
  bool battery = true,
  bool isMiui = false,
  Map<MiuiSetupFlag, bool> miuiFlags = const {},
  bool paired = true,
  bool onboardingComplete = true,
}) {
  return SetupStatus(
    notificationsGranted: notifications,
    photosAccess: photos,
    batteryExempt: battery,
    isMiui: isMiui,
    miuiFlags: miuiFlags,
    paired: paired,
    onboardingComplete: onboardingComplete,
  );
}

void main() {
  setUp(() => Motion.loopsEnabled = false);
  tearDown(() => Motion.loopsEnabled = true);

  group('SetupStatus', () {
    test('counts issues including MIUI self-reports', () {
      expect(statusWith().issueCount, 0);
      expect(
        statusWith(
          notifications: false,
          photos: ScreenshotAccessLevel.partial,
          paired: false,
        ).issueCount,
        3,
      );
      expect(
        statusWith(
          isMiui: true,
          miuiFlags: {
            MiuiSetupFlag.autostart: true,
            MiuiSetupFlag.battery: true,
          },
        ).issueCount,
        2, // lockInRecents + clipboard unchecked
      );
    });

    test('banner shows until onboarding completes', () {
      expect(
        statusWith(onboardingComplete: false).bannerNeeded(const AppSettings()),
        isTrue,
      );
      expect(statusWith().bannerNeeded(const AppSettings()), isFalse);
    });

    test('banner flags partial photos while auto-push is on', () {
      final status = statusWith(photos: ScreenshotAccessLevel.partial);
      expect(status.bannerNeeded(const AppSettings()), isTrue);
      expect(
        status.bannerLabel(const AppSettings()),
        'Auto-push paused — allow all photos',
      );
      expect(
        status.bannerNeeded(const AppSettings(autoPushScreenshots: false)),
        isFalse,
      );
    });

    test('MIUI self-reports never trigger the banner', () {
      expect(
        statusWith(isMiui: true).bannerNeeded(const AppSettings()),
        isFalse,
      );
    });
  });

  group('AppSettingsRepository onboarding storage', () {
    test('onboardingComplete defaults false and persists', () async {
      final storage = MemoryAppSettingsStorage();
      final repository = AppSettingsRepository(storage);
      expect(await repository.onboardingComplete(), isFalse);
      await repository.markOnboardingComplete();
      expect(await AppSettingsRepository(storage).onboardingComplete(), isTrue);
    });

    test('MIUI setup flags persist per item', () async {
      final storage = MemoryAppSettingsStorage();
      final repository = AppSettingsRepository(storage);
      expect(
        (await repository.loadMiuiSetupFlags()).values.any((v) => v),
        isFalse,
      );
      await repository.saveMiuiSetupFlag(MiuiSetupFlag.clipboard, true);
      final flags = await AppSettingsRepository(storage).loadMiuiSetupFlags();
      expect(flags[MiuiSetupFlag.clipboard], isTrue);
      expect(flags[MiuiSetupFlag.autostart], isFalse);
    });
  });

  group('OnboardingWizard', () {
    late FakeSetupActions actions;
    late AppSettingsRepository settingsRepository;
    late ValueNotifier<bool> connected;
    late List<PairingCode> savedPairings;

    setUp(() {
      actions = FakeSetupActions();
      settingsRepository = AppSettingsRepository(MemoryAppSettingsStorage());
      connected = ValueNotifier(false);
      savedPairings = [];
    });

    Widget wizard() {
      return MaterialApp(
        home: OnboardingWizard(
          actions: actions,
          settingsRepository: settingsRepository,
          connectionStatus: connected,
          savePairing: (pairing) async {
            savedPairings.add(pairing);
            return null;
          },
        ),
      );
    }

    testWidgets('walks the D2 order and skipping reaches pairing', (
      tester,
    ) async {
      await tester.pumpWidget(wizard());
      await tester.pumpAndSettle();

      expect(find.text('Stay in the loop'), findsOneWidget);
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      expect(find.text('Spot your screenshots'), findsOneWidget);
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      expect(find.text('Keep the link alive'), findsOneWidget);
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      // Non-MIUI device: no Xiaomi step (D4).
      expect(find.text('Connect to your laptop'), findsOneWidget);
    });

    testWidgets('Xiaomi step appears on MIUI devices', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      actions.miui = true;
      await tester.pumpWidget(wizard());
      await tester.pumpAndSettle();

      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('Skip'));
        await tester.pumpAndSettle();
      }
      expect(find.text('Xiaomi needs a little extra'), findsOneWidget);
      await tester.ensureVisible(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Connect to your laptop'), findsOneWidget);
    });

    testWidgets('granting advances each step', (tester) async {
      await tester.pumpWidget(wizard());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Allow'));
      await tester.pumpAndSettle();
      expect(find.text('Spot your screenshots'), findsOneWidget);
      await tester.tap(find.text('Allow access'));
      await tester.pumpAndSettle();
      expect(find.text('Keep the link alive'), findsOneWidget);
      await tester.tap(find.text('Allow'));
      await tester.pumpAndSettle();
      expect(find.text('Connect to your laptop'), findsOneWidget);
    });

    testWidgets('partial photos grant flips to the recovery state (D3)', (
      tester,
    ) async {
      actions.photosAfterRequest = ScreenshotAccessLevel.partial;
      await tester.pumpWidget(wizard());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Allow access'));
      await tester.pumpAndSettle();

      expect(find.text('Almost — one change needed'), findsOneWidget);
      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();
      expect(actions.opened, contains('app-settings'));
    });

    testWidgets(
      'pairing finale shows live Connected and Done completes onboarding',
      (tester) async {
        await tester.pumpWidget(wizard());
        await tester.pumpAndSettle();
        for (var i = 0; i < 3; i++) {
          await tester.tap(find.text('Skip'));
          await tester.pumpAndSettle();
        }

        await tester.enterText(
          find.widgetWithText(TextField, 'Relay IP'),
          '192.168.1.9',
        );
        await tester.enterText(find.widgetWithText(TextField, 'Port'), '17321');
        await tester.enterText(
          find.widgetWithText(TextField, 'Pairing secret'),
          'secret',
        );
        await tester.ensureVisible(find.text('Pair manually'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Pair manually'));
        await tester.pumpAndSettle();

        expect(savedPairings, hasLength(1));
        expect(find.text('Connecting…'), findsOneWidget);

        connected.value = true;
        await tester.pumpAndSettle();
        expect(find.text('Connected'), findsOneWidget);

        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
        expect(await settingsRepository.onboardingComplete(), isTrue);
      },
    );
  });

  group('SetupChecklistScreen', () {
    testWidgets('shows live rows and the MIUI section', (tester) async {
      final actions = FakeSetupActions()
        ..miui = true
        ..notifications = true
        ..photos = ScreenshotAccessLevel.partial;
      final loader = SetupStatusLoader(
        actions: actions,
        settingsRepository: AppSettingsRepository(MemoryAppSettingsStorage()),
        pairingRepository: PairingRepository(MemoryPairingStorage()),
      );
      await tester.pumpWidget(
        MaterialApp(home: SetupChecklistScreen(loader: loader)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Notifications'), findsOneWidget);
      expect(find.textContaining('Only selected photos'), findsOneWidget);
      expect(find.text('Xiaomi setup'), findsOneWidget);
      expect(find.text('Autostart'), findsOneWidget);
      expect(find.text('Lock in recents'), findsOneWidget);
      expect(find.text('Clipboard permission'), findsOneWidget);
    });

    testWidgets('checking a MIUI item persists the self-report', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final actions = FakeSetupActions()..miui = true;
      final settingsRepository = AppSettingsRepository(
        MemoryAppSettingsStorage(),
      );
      final loader = SetupStatusLoader(
        actions: actions,
        settingsRepository: settingsRepository,
        pairingRepository: PairingRepository(MemoryPairingStorage()),
      );
      await tester.pumpWidget(
        MaterialApp(home: SetupChecklistScreen(loader: loader)),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byType(Checkbox).first);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();

      final flags = await settingsRepository.loadMiuiSetupFlags();
      expect(flags[MiuiSetupFlag.autostart], isTrue);
    });
  });
}
