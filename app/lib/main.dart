import 'dart:async';
import 'dart:io';

import 'package:clipboard_autosend/clipboard_autosend.dart';
import 'package:cryptography/cryptography.dart' show Cryptography;
import 'package:cryptography_flutter/cryptography_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:vidyut_clipboard/vidyut_clipboard.dart';
import 'package:vidyut_files/vidyut_files.dart';

import 'src/activity/last_activity.dart';
import 'src/activity/last_activity_repository.dart';
import 'src/activity/recent_activity_screen.dart';
import 'src/browse/laptop_file_browser.dart';
import 'src/browse/laptop_files_screen.dart';
import 'src/debug/debug_log.dart';
import 'src/design/theme.dart';
import 'src/design/widgets.dart';
import 'src/foreground/foreground_service_client.dart';
import 'src/foreground/foreground_service_coordinator.dart';
import 'src/foreground/vidyut_foreground_service.dart';
import 'src/foreground/send_clipboard_screen.dart';
import 'src/foreground/service_relay_controller.dart'
    show serviceClipboardPauseCommand, serviceTelemetryCommand;
import 'src/home/home_screen.dart';
import 'src/onboarding/onboarding_wizard.dart';
import 'src/onboarding/setup_actions.dart';
import 'src/onboarding/setup_checklist_screen.dart';
import 'src/onboarding/setup_status.dart';
import 'src/pairing/pairing_code.dart';
import 'src/pairing/pairing_repository.dart';
import 'src/pairing/pairing_widgets.dart';
import 'src/pairing/qr_pairing_screen.dart';
import 'src/pairing/relay_discovery.dart';
import 'src/receive/payload_receiver.dart';
import 'src/receive/receive_notification_tap_handler.dart';
import 'src/receive/received_image_repository.dart';
import 'src/receive/received_text_repository.dart';
import 'src/share/share_intake_controller.dart';
import 'src/share/share_payload.dart';
import 'src/share/share_publisher.dart';
import 'src/settings/app_settings.dart';
import 'src/settings/app_settings_repository.dart';
import 'src/settings/clipboard_pause.dart';
import 'src/settings/settings_screen.dart';
import 'src/share/share_source.dart';
import 'src/shared/payload_crypto.dart';
import 'src/shared/format.dart';
import 'src/shared/image_probe.dart';
import 'src/shared/relay_connection.dart';
import 'src/shared/wire.dart';
import 'src/transfer/phone_transfer_sender.dart';
import 'src/transfer/transfer_file_actions.dart';
import 'src/transfer/transfer_files_screen.dart';
import 'src/transfer/transfer_history.dart';
import 'src/update/github_update_checker.dart';

part 'pairing_screen.dart';

typedef RelayConnectionFactory = RelayConnection Function(PairingCode pairing);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await sharedDebugLog.load();
  // Delegate AES-GCM/PBKDF2 to platform crypto (push spec §4); the package
  // silently falls back to pure Dart where the plugin channel is missing.
  Cryptography.instance = FlutterCryptography.defaultInstance;
  FlutterForegroundTask.initCommunicationPort();
  runApp(
    VidyutApp(
      appSettingsRepository: AppSettingsRepository(
        const SecureAppSettingsStorage(),
      ),
      lastActivityRepository: LastActivityRepository(
        SecureLastActivityStorage(),
      ),
      foregroundServiceClient: VidyutForegroundServiceClient(),
      pairingRepository: PairingRepository(const SecurePairingStorage()),
      relayDiscovery: RelayDiscovery(lock: const ChannelMulticastLock()),
      shareSource: const ReceiveSharingIntentSource(),
      receiveNotificationTapHandler: ReceiveNotificationTapHandler(
        repository: ReceivedTextRepository(SecureReceivedPayloadStorage()),
        imageRepository: ReceivedImageRepository(
          const SecureReceivedPayloadStorage(),
        ),
        clipboard: const FlutterAndroidClipboard(),
        imageClipboard: const ChannelAndroidImageClipboard(),
      ),
      setupActions: PlatformSetupActions(),
    ),
  );
}

class VidyutApp extends StatefulWidget {
  const VidyutApp({
    super.key,
    required this.appSettingsRepository,
    required this.lastActivityRepository,
    required this.foregroundServiceClient,
    required this.pairingRepository,
    this.relayConnectionFactory,
    this.relayDiscovery,
    this.shareSource,
    this.receiveNotificationTapHandler,
    this.debugLog,
    this.setupActions,
  });

  final AppSettingsRepository appSettingsRepository;
  final LastActivityRepository lastActivityRepository;
  final ForegroundServiceClient foregroundServiceClient;
  final PairingRepository pairingRepository;
  final RelayConnectionFactory? relayConnectionFactory;
  final RelayDiscovery? relayDiscovery;
  final ShareSource? shareSource;
  final ReceiveNotificationTapHandler? receiveNotificationTapHandler;
  final DebugLog? debugLog;

  /// Platform probes behind onboarding and the setup checklist. When null
  /// (widget tests without platform channels) the wizard, banner, and
  /// Setup-status row are disabled.
  final SetupActions? setupActions;

  @override
  State<VidyutApp> createState() => _VidyutAppState();
}

class _VidyutAppState extends State<VidyutApp> {
  AppThemeMode _themeMode = AppThemeMode.system;
  var _themeModeRevision = 0;
  String? _pairingName;

  @override
  void initState() {
    super.initState();
    unawaited(_loadThemeMode());
    unawaited(_loadPairingName());
  }

  Future<void> _loadPairingName() async {
    final pairing = await widget.pairingRepository.load();
    if (!mounted) return;
    setState(() => _pairingName = pairing?.name);
  }

  void _onPairingNameChanged(String? name) {
    if (!mounted) return;
    setState(() => _pairingName = name);
  }

  Future<void> _loadThemeMode() async {
    final revision = _themeModeRevision;
    final settings = await widget.appSettingsRepository.load();
    if (mounted && revision == _themeModeRevision) {
      setState(() => _themeMode = settings.themeMode);
    }
  }

  void _setThemeMode(AppThemeMode mode) {
    _themeModeRevision++;
    if (mounted) setState(() => _themeMode = mode);
  }

  ThemeMode get _materialThemeMode => switch (_themeMode) {
    AppThemeMode.system => ThemeMode.system,
    AppThemeMode.light => ThemeMode.light,
    AppThemeMode.dark => ThemeMode.dark,
  };

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vidyut',
      navigatorObservers: [_pageRouteObserver],
      theme: buildVidyutTheme(),
      darkTheme: buildVidyutDarkTheme(),
      themeMode: _materialThemeMode,
      debugShowCheckedModeBanner: false,
      onGenerateRoute: (settings) {
        final connectionFactory =
            widget.relayConnectionFactory ?? _defaultRelayConnection;
        final log = widget.debugLog ?? sharedDebugLog;
        if (settings.name == sendClipboardRoute) {
          return MaterialPageRoute(
            builder: (_) => SendClipboardScreen(
              clipboardReader: const FlutterClipboardReader(),
              publisher: SharePublisherAdapter(
                SharePublisher(
                  pairingRepository: widget.pairingRepository,
                  relaySessionFactory: connectionFactory,
                  crypto: PayloadCrypto(),
                  fileReader: const LocalShareFileReader(),
                ),
              ),
              lastActivityRepository: widget.lastActivityRepository,
              counterpart: _pairingName,
              debugLog: log,
            ),
            settings: settings,
          );
        }
        return MaterialPageRoute(
          builder: (_) => PairingScreen(
            appSettingsRepository: widget.appSettingsRepository,
            lastActivityRepository: widget.lastActivityRepository,
            foregroundServiceClient: widget.foregroundServiceClient,
            pairingRepository: widget.pairingRepository,
            relayConnectionFactory: connectionFactory,
            relayDiscovery: widget.relayDiscovery,
            shareSource: widget.shareSource,
            receiveNotificationTapHandler: widget.receiveNotificationTapHandler,
            debugLog: log,
            setupActions: widget.setupActions,
            onThemeModeChanged: _setThemeMode,
            onPairingChanged: _onPairingNameChanged,
          ),
          settings: settings,
        );
      },
    );
  }
}

RelayConnection _defaultRelayConnection(PairingCode pairing) {
  return RelayConnection(
    pairing: pairing,
    deviceId: 'phone',
    transport: WebSocketRelayTransport.connect(pairing),
  );
}

/// Lets the home screen tell when another page covers it, so laptop
/// telemetry is only requested while it is on screen.
final _pageRouteObserver = RouteObserver<PageRoute<dynamic>>();
