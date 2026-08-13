import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:screenshot_observer/screenshot_observer.dart';

import '../design/widgets.dart';
import '../pairing/pairing_code.dart';
import '../pairing/pairing_widgets.dart';
import '../pairing/relay_discovery.dart';
import '../settings/app_settings.dart';
import '../settings/app_settings_repository.dart';
import 'miui_setup_list.dart';
import 'setup_actions.dart';

/// One wizard step's identity, in D2 order. The Xiaomi step is included only
/// on MIUI devices (D4).
enum WizardStep { notifications, photos, battery, xiaomi, pairing }

typedef WizardPairingSave = Future<String?> Function(PairingCode pairing);

/// The one-time first-run flow (onboarding spec D1–D5, D7): full-screen
/// sequential steps, every one skippable, pairing as the finale. Never
/// force-re-shown once [AppSettingsRepository.markOnboardingComplete] runs.
class OnboardingWizard extends StatefulWidget {
  const OnboardingWizard({
    super.key,
    required this.actions,
    required this.settingsRepository,
    required this.savePairing,
    required this.connectionStatus,
    this.relayDiscovery,
    this.onScanQr,
    this.onFinished,
  });

  final SetupActions actions;
  final AppSettingsRepository settingsRepository;

  /// Persists a pairing code and kicks the service; returns an error message
  /// or null on success. Owned by the host screen so pairing behavior stays
  /// identical to the home flow (D3: no behavioral change to pairing).
  final WizardPairingSave savePairing;

  /// Live connection state from the host screen — drives the step-5
  /// "Connected" confirmation (D2).
  final ValueListenable<bool> connectionStatus;

  final RelayDiscovery? relayDiscovery;

  /// Opens the QR scanner and returns the raw code, or null when cancelled.
  final Future<String?> Function()? onScanQr;

  final VoidCallback? onFinished;

  @override
  State<OnboardingWizard> createState() => _OnboardingWizardState();
}

class _OnboardingWizardState extends State<OnboardingWizard>
    with WidgetsBindingObserver {
  List<WizardStep> _steps = const [
    WizardStep.notifications,
    WizardStep.photos,
    WizardStep.battery,
    WizardStep.pairing,
  ];
  int _index = 0;
  ScreenshotAccessLevel? _photosAccess;
  bool _photosRequested = false;
  bool _notificationsRequested = false;
  bool _batteryRequested = false;
  Map<MiuiSetupFlag, bool> _miuiFlags = const {};

  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '17321');
  final _secretController = TextEditingController();
  List<DiscoveredRelay> _nearbyRelays = const [];
  DiscoveredRelay? _selectedRelay;
  bool _discovering = false;
  bool _paired = false;
  String? _pairingError;

  WizardStep get _step => _steps[_index];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.connectionStatus.addListener(_onConnectionChanged);
    unawaited(_detectMiui());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.connectionStatus.removeListener(_onConnectionChanged);
    _hostController.dispose();
    _portController.dispose();
    _secretController.dispose();
    super.dispose();
  }

  Future<void> _detectMiui() async {
    final isMiui = await widget.actions.isMiui();
    if (!isMiui || !mounted) return;
    final flags = await widget.settingsRepository.loadMiuiSetupFlags();
    if (!mounted) return;
    setState(() {
      _steps = const [
        WizardStep.notifications,
        WizardStep.photos,
        WizardStep.battery,
        WizardStep.xiaomi,
        WizardStep.pairing,
      ];
      _miuiFlags = flags;
    });
  }

  /// Re-check live grants when the user comes back from a system settings
  /// screen (D3: the partial-photos recovery re-checks in onResume).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(_recheckCurrentStep());
  }

  Future<void> _recheckCurrentStep() async {
    switch (_step) {
      case WizardStep.photos:
        final access = await widget.actions.photosAccess();
        if (!mounted) return;
        if (access == ScreenshotAccessLevel.full) {
          _advance();
        } else {
          setState(() => _photosAccess = access);
        }
      case WizardStep.notifications:
        if (await widget.actions.notificationsGranted() && mounted) _advance();
      case WizardStep.battery:
        if (await widget.actions.batteryExempt() && mounted) _advance();
      case WizardStep.xiaomi || WizardStep.pairing:
        break;
    }
  }

  void _onConnectionChanged() {
    if (mounted) setState(() {});
  }

  void _advance() {
    if (_index + 1 < _steps.length) {
      setState(() => _index += 1);
      if (_steps[_index] == WizardStep.pairing) unawaited(_discoverRelays());
    }
  }

  Future<void> _allowNotifications() async {
    await widget.actions.requestNotifications();
    if (!mounted) return;
    if (await widget.actions.notificationsGranted()) {
      if (mounted) _advance();
    } else {
      // Permanently denied: the dialog can't re-show, so route to settings.
      setState(() => _notificationsRequested = true);
    }
  }

  Future<void> _allowPhotos() async {
    await widget.actions.requestPhotos();
    final access = await widget.actions.photosAccess();
    if (!mounted) return;
    if (access == ScreenshotAccessLevel.full) {
      _advance();
    } else {
      setState(() {
        _photosAccess = access;
        _photosRequested = true;
      });
    }
  }

  Future<void> _allowBattery() async {
    await widget.actions.requestBatteryExemption();
    if (!mounted) return;
    if (await widget.actions.batteryExempt()) {
      if (mounted) _advance();
    } else {
      // The system dialog didn't grant it (some OEMs hard-deny): route to
      // settings, mirroring the notifications step.
      setState(() => _batteryRequested = true);
    }
  }

  void _goBack() {
    if (_index > 0) setState(() => _index -= 1);
  }

  Future<void> _discoverRelays() async {
    final discovery = widget.relayDiscovery;
    if (discovery == null || _discovering) return;
    setState(() => _discovering = true);
    List<DiscoveredRelay>? relays;
    try {
      relays = await discovery.discover();
    } on Exception {
      // Best-effort, same as the home screen.
    }
    if (!mounted) return;
    setState(() {
      _discovering = false;
      if (relays != null) _nearbyRelays = relays;
    });
  }

  Future<void> _pairManually() async {
    try {
      final pairing = PairingCode.parseManual(
        host: _hostController.text,
        port: _portController.text,
        secret: _secretController.text,
      );
      await _savePairing(pairing);
    } on PairingCodeException catch (error) {
      setState(() => _pairingError = error.message);
    }
  }

  Future<void> _scanQr() async {
    final rawCode = await widget.onScanQr?.call();
    if (rawCode == null || !mounted) return;
    try {
      await _savePairing(PairingCode.parse(rawCode));
    } on PairingCodeException catch (error) {
      setState(() => _pairingError = error.message);
    } on FormatException {
      setState(
        () => _pairingError = 'QR code is not a valid Vidyut pairing code.',
      );
    }
  }

  Future<void> _savePairing(PairingCode pairing) async {
    final error = await widget.savePairing(pairing);
    if (!mounted) return;
    setState(() {
      _pairingError = error;
      if (error == null) _paired = true;
    });
  }

  Future<void> _finish() async {
    await widget.settingsRepository.markOnboardingComplete();
    if (!mounted) return;
    widget.onFinished?.call();
    Navigator.of(context).pop();
  }

  Future<void> _setMiuiFlag(MiuiSetupFlag flag, bool value) async {
    setState(() => _miuiFlags = {..._miuiFlags, flag: value});
    await widget.settingsRepository.saveMiuiSetupFlag(flag, value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 44,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Center(
                      child: _StepDots(count: _steps.length, index: _index),
                    ),
                    if (_index > 0)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: PressableScale(
                          child: IconButton(
                            tooltip: 'Back',
                            icon: Icon(
                              Icons.chevron_left,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                            onPressed: _goBack,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Expanded(
                child: switch (_step) {
                  WizardStep.notifications => _notificationsStep(),
                  WizardStep.photos => _photosStep(),
                  WizardStep.battery => _batteryStep(),
                  WizardStep.xiaomi => _xiaomiStep(),
                  WizardStep.pairing => _pairingStep(),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Steps (copy per D7) ----

  Widget _notificationsStep() {
    return _StepScaffold(
      key: const ValueKey('step-notifications'),
      icon: Icons.notifications_active_outlined,
      title: 'Stay in the loop',
      body:
          'Vidyut shows a small ongoing notification while sync runs, and '
          'a quiet receipt when something arrives from your laptop.',
      consequence: "You won't see receipts when the laptop sends you things.",
      primaryLabel: _notificationsRequested ? 'Open settings' : 'Allow',
      onPrimary: _notificationsRequested
          ? widget.actions.openAppSettings
          : _allowNotifications,
      onSkip: _advance,
    );
  }

  Widget _photosStep() {
    final partial =
        _photosAccess == ScreenshotAccessLevel.partial ||
        (_photosRequested && _photosAccess == ScreenshotAccessLevel.denied);
    if (partial) {
      // D3 recovery state: the system dialog can no longer offer "Allow all",
      // so the only path is app settings; re-checked in onResume.
      return _StepScaffold(
        key: const ValueKey('step-photos-partial'),
        icon: Icons.photo_library_outlined,
        title: 'Almost — one change needed',
        body:
            "You picked 'Select photos', so new screenshots stay invisible "
            "to Vidyut. Switch to 'Allow all' in settings.",
        consequence:
            "Screenshots won't send themselves — you can still share "
            'manually.',
        primaryLabel: 'Open settings',
        onPrimary: widget.actions.openAppSettings,
        onSkip: _advance,
      );
    }
    return _StepScaffold(
      key: const ValueKey('step-photos'),
      icon: Icons.photo_library_outlined,
      title: 'Spot your screenshots',
      body:
          'To send screenshots automatically, Vidyut needs access to all '
          "photos. Pick Allow all — with 'Select photos' it can't see new "
          'screenshots.',
      consequence:
          "Screenshots won't send themselves — you can still share manually.",
      primaryLabel: 'Allow access',
      onPrimary: _allowPhotos,
      onSkip: _advance,
    );
  }

  Widget _batteryStep() {
    return _StepScaffold(
      key: const ValueKey('step-battery'),
      icon: Icons.battery_charging_full_outlined,
      title: 'Keep the link alive',
      body:
          'Android puts idle apps to sleep, which drops the connection to '
          'your laptop. Allow Vidyut to ignore battery optimizations so '
          'payloads arrive even when the screen is off.',
      consequence: 'Sync may pause when the phone sleeps.',
      primaryLabel: _batteryRequested ? 'Open settings' : 'Allow',
      onPrimary: _batteryRequested
          ? widget.actions.openAppSettings
          : _allowBattery,
      onSkip: _advance,
    );
  }

  Widget _xiaomiStep() {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      key: const ValueKey('step-xiaomi'),
      children: [
        Text(
          'Xiaomi needs a little extra',
          style: textTheme.titleLarge,
        ).entrance(0),
        const SizedBox(height: 10),
        Text(
          'MIUI closes background apps aggressively. These four switches keep '
          "Vidyut alive — we can't check them for you, so tick what "
          "you've done.",
          style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ).entrance(1),
        const SizedBox(height: 20),
        MiuiSetupList(
          actions: widget.actions,
          flags: _miuiFlags,
          onFlagChanged: (flag, value) => unawaited(_setMiuiFlag(flag, value)),
        ).entrance(2),
        const SizedBox(height: 8),
        Text(
          'Skipping: MIUI will likely kill sync in the background.',
          style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ).entrance(3),
        const SizedBox(height: 16),
        PressableScale(
          child: FilledButton(
            onPressed: _advance,
            child: const Text('Continue'),
          ),
        ).entrance(4),
      ],
    );
  }

  Widget _pairingStep() {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    if (_paired) {
      final connected = widget.connectionStatus.value;
      // Live confirmation (D2): completing the wizard means the app
      // demonstrably works.
      return Column(
        key: const ValueKey('step-paired'),
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: connected
                    ? scheme.primaryContainer
                    : scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                connected ? Icons.link : Icons.wifi_find,
                size: 36,
                color: connected ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ).entrance(0),
          const SizedBox(height: 24),
          Center(
            child: Text(
              connected ? 'Connected' : 'Connecting…',
              style: textTheme.titleLarge,
            ),
          ).entrance(1),
          const SizedBox(height: 8),
          Center(
            child: Text(
              connected
                  ? 'Your laptop and phone are in sync.'
                  : 'Paired — waiting for the relay.',
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ).entrance(2),
          const SizedBox(height: 32),
          PressableScale(
            child: FilledButton(onPressed: _finish, child: const Text('Done')),
          ).entrance(3),
        ],
      );
    }
    return ListView(
      key: const ValueKey('step-pairing'),
      children: [
        Text('Connect to your laptop', style: textTheme.titleLarge).entrance(0),
        const SizedBox(height: 10),
        Text(
          'Run the relay on your laptop, then pick it below or scan its QR '
          'code.',
          style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ).entrance(1),
        const SizedBox(height: 20),
        if (widget.relayDiscovery != null) ...[
          NearbyRelaysCard(
            relays: _nearbyRelays,
            selected: _selectedRelay,
            discovering: _discovering,
            onRefresh: () => unawaited(_discoverRelays()),
            onSelect: (relay) {
              _hostController.text = relay.host;
              _portController.text = relay.port.toString();
              setState(() => _selectedRelay = relay);
            },
          ).entrance(2),
          const SizedBox(height: 24),
        ],
        ManualPairingForm(
          hostController: _hostController,
          portController: _portController,
          secretController: _secretController,
          error: _pairingError,
          onScanQr: () => unawaited(_scanQr()),
          onPair: () => unawaited(_pairManually()),
        ).entrance(3),
        const SizedBox(height: 12),
        Center(
          child: TextButton(
            onPressed: _finish,
            child: const Text('Skip for now'),
          ),
        ).entrance(4),
      ],
    );
  }
}

/// Full-screen permission step: blob icon, weight-800 title, body copy,
/// raspberry pill primary CTA and muted text Skip (D9).
class _StepScaffold extends StatelessWidget {
  const _StepScaffold({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.consequence,
    required this.primaryLabel,
    required this.onPrimary,
    required this.onSkip,
  });

  final IconData icon;
  final String title;
  final String body;
  final String consequence;
  final String primaryLabel;
  final Future<void> Function() onPrimary;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Spacer(),
        Center(
          child: Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              icon,
              size: 36,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ).entrance(0),
        const SizedBox(height: 28),
        Text(
          title,
          textAlign: TextAlign.center,
          style: textTheme.titleLarge,
        ).entrance(1),
        const SizedBox(height: 12),
        Text(
          body,
          textAlign: TextAlign.center,
          style: textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ).entrance(2),
        const Spacer(),
        Text(
          'If you skip: $consequence',
          textAlign: TextAlign.center,
          style: textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ).entrance(3),
        const SizedBox(height: 14),
        PressableScale(
          child: FilledButton(
            onPressed: () => unawaited(onPrimary()),
            child: Text(primaryLabel),
          ),
        ).entrance(4),
        const SizedBox(height: 6),
        TextButton(
          onPressed: onSkip,
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          child: const Text('Skip'),
        ).entrance(5),
      ],
    );
  }
}

class _StepDots extends StatelessWidget {
  const _StepDots({required this.count, required this.index});

  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            width: i == index ? 22 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: i == index ? scheme.primary : scheme.primaryContainer,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
      ],
    );
  }
}
