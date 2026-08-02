import 'dart:async';

import 'package:clipboard_autosend/clipboard_autosend.dart';
import 'package:cryptography/cryptography.dart' show Cryptography;
import 'package:cryptography_flutter/cryptography_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vidyut_files/vidyut_files.dart';

import 'src/activity/last_activity.dart';
import 'src/activity/last_activity_repository.dart';
import 'src/debug/debug_log.dart';
import 'src/design/palette.dart';
import 'src/design/theme.dart';
import 'src/design/widgets.dart';
import 'src/foreground/foreground_service_client.dart';
import 'src/foreground/foreground_service_coordinator.dart';
import 'src/foreground/vidyut_foreground_service.dart';
import 'src/foreground/send_clipboard_screen.dart';
import 'src/onboarding/onboarding_wizard.dart';
import 'src/onboarding/setup_actions.dart';
import 'src/onboarding/setup_checklist_screen.dart';
import 'src/onboarding/setup_status.dart';
import 'src/pairing/pairing_code.dart';
import 'src/pairing/pairing_repository.dart';
import 'src/pairing/pairing_widgets.dart';
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
import 'src/settings/settings_screen.dart';
import 'src/share/share_source.dart';
import 'src/shared/payload_crypto.dart';
import 'src/shared/relay_connection.dart';
import 'src/transfer/phone_transfer_sender.dart';
import 'src/transfer/transfer_files_screen.dart';
import 'src/transfer/transfer_history.dart';
import 'src/update/github_update_checker.dart';

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
      lastActivityRepository: const LastActivityRepository(
        SecureLastActivityStorage(),
      ),
      foregroundServiceClient: VidyutForegroundServiceClient(),
      pairingRepository: PairingRepository(const SecurePairingStorage()),
      relayDiscovery: RelayDiscovery(lock: const ChannelMulticastLock()),
      shareSource: const ReceiveSharingIntentSource(),
      receiveNotificationTapHandler: ReceiveNotificationTapHandler(
        repository: const ReceivedTextRepository(
          SecureReceivedPayloadStorage(),
        ),
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

class VidyutApp extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vidyut',
      theme: buildVidyutTheme(),
      debugShowCheckedModeBanner: false,
      onGenerateRoute: (settings) {
        final connectionFactory =
            relayConnectionFactory ?? _defaultRelayConnection;
        final log = debugLog ?? sharedDebugLog;
        if (settings.name == sendClipboardRoute) {
          return MaterialPageRoute(
            builder: (_) => SendClipboardScreen(
              clipboardReader: const FlutterClipboardReader(),
              publisher: SharePublisherAdapter(
                SharePublisher(
                  pairingRepository: pairingRepository,
                  relaySessionFactory: connectionFactory,
                  crypto: PayloadCrypto(),
                  fileReader: const LocalShareFileReader(),
                ),
              ),
              lastActivityRepository: lastActivityRepository,
              debugLog: log,
            ),
            settings: settings,
          );
        }
        return MaterialPageRoute(
          builder: (_) => PairingScreen(
            appSettingsRepository: appSettingsRepository,
            lastActivityRepository: lastActivityRepository,
            foregroundServiceClient: foregroundServiceClient,
            pairingRepository: pairingRepository,
            relayConnectionFactory: connectionFactory,
            relayDiscovery: relayDiscovery,
            shareSource: shareSource,
            receiveNotificationTapHandler: receiveNotificationTapHandler,
            debugLog: log,
            setupActions: setupActions,
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

class PairingScreen extends StatefulWidget {
  const PairingScreen({
    super.key,
    required this.appSettingsRepository,
    required this.lastActivityRepository,
    required this.foregroundServiceClient,
    required this.pairingRepository,
    required this.relayConnectionFactory,
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
  final RelayConnectionFactory relayConnectionFactory;
  final RelayDiscovery? relayDiscovery;
  final ShareSource? shareSource;
  final ReceiveNotificationTapHandler? receiveNotificationTapHandler;
  final DebugLog? debugLog;
  final SetupActions? setupActions;

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen>
    with WidgetsBindingObserver {
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '17321');
  final _secretController = TextEditingController();

  PairingCode? _pairing;
  List<DiscoveredRelay> _nearbyRelays = const [];
  DiscoveredRelay? _selectedRelay;
  bool _discovering = false;
  ShareIntakeController? _shareIntakeController;
  AppSettings _settings = const AppSettings();
  late final ForegroundServiceCoordinator _foregroundServiceCoordinator =
      ForegroundServiceCoordinator(widget.foregroundServiceClient);
  ConnectionStatus _connectionStatus = ConnectionStatus.offline;
  String? _error;
  LastActivity? _lastActivity;
  bool _loading = true;
  late final DebugLog _debugLog = widget.debugLog ?? sharedDebugLog;
  late final TransferHistoryRepository _transferHistory =
      TransferHistoryRepository(SharedPreferencesTransferHistoryStorage());
  late final PhoneTransferSender _transferSender = PhoneTransferSender(
    pairingRepository: widget.pairingRepository,
    connectionFactory: widget.relayConnectionFactory,
    history: _transferHistory,
    maximumFileBytes: () async =>
        (await widget.appSettingsRepository.load()).maxTransferFileBytes,
    networkAllowed: () async {
      final settings = await widget.appSettingsRepository.load();
      return settings.allowMeteredFileTransfers ||
          !await const VidyutFiles().isNetworkMetered();
    },
  );

  /// Live "connected" flag mirrored into the wizard's finale (D2).
  final _connectedNotifier = ValueNotifier<bool>(false);
  SetupStatus? _setupStatus;
  RelayHealth? _relayHealth;
  String? _connectionDetail;
  String? _discoveryError;

  /// D6 loader shared by the banner, the checklist, and the Settings chip.
  late final SetupStatusLoader? _setupLoader = widget.setupActions == null
      ? null
      : SetupStatusLoader(
          actions: widget.setupActions!,
          settingsRepository: widget.appSettingsRepository,
          pairingRepository: widget.pairingRepository,
        );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.foregroundServiceClient.addTaskDataCallback(_onServiceData);
    final tapHandler = widget.receiveNotificationTapHandler;
    unawaited(_debugLog.load());
    if (tapHandler != null) {
      tapHandler.onCopied = (message) {
        _debugLog.add('clipboard', message);
        if (mounted) _showSnack(message);
      };
      unawaited(tapHandler.init());
    }
    _loadPairing();
  }

  /// Recompute the D6 snapshot on resume so the home banner tracks external
  /// changes (revoking photos in system settings).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refreshSetupStatus());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectedNotifier.dispose();
    widget.foregroundServiceClient.removeTaskDataCallback(_onServiceData);
    _shareIntakeController?.dispose();
    _hostController.dispose();
    _portController.dispose();
    _secretController.dispose();
    super.dispose();
  }

  void _onServiceData(Object data) {
    if (data is! Map || !mounted) return;
    switch (data['kind']) {
      case 'status':
        final status = ConnectionStatus.values
            .where((value) => value.name == data['status'])
            .firstOrNull;
        if (status != null) {
          _debugLog.add(
            'connection',
            'Status: ${status.name}',
            isError: status == ConnectionStatus.offline,
          );
          _connectedNotifier.value = status == ConnectionStatus.connected;
          setState(() {
            _connectionStatus = status;
            if (status == ConnectionStatus.connected) {
              _connectionDetail = null;
            }
          });
        }
      case 'health':
        final status = data['status'];
        final relayName = data['relayName'];
        if (status is String && relayName is String) {
          setState(() {
            _relayHealth = RelayHealth(
              status: status,
              relayName: relayName,
              clipboardStatus: data['clipboardStatus'] as String?,
              clipboardError: data['clipboardError'] as String?,
            );
          });
        }
      case 'receive':
        final message = data['message'];
        if (message is String) {
          final failed = data['received'] == false;
          _debugLog.add(
            'receive',
            _describeReceive(data, message),
            isError: failed,
          );
          if (failed) {
            _showSnack(message);
          } else {
            unawaited(_recordReceived(data, message));
          }
        }
      case 'log':
        final message = data['message'];
        if (message is String) {
          _debugLog.add('service', message, isError: data['error'] == true);
          if (data['error'] == true) {
            setState(
              () => _connectionDetail = _friendlyConnectionError(message),
            );
          }
        }
      case 'sendClipboard':
        unawaited(_openSendClipboard());
      case 'transfer':
        final message = data['message'];
        if (message is String) {
          final failed = data['error'] == true;
          _debugLog.add('transfer', message, isError: failed);
          _showSnack(message);
        }
    }
  }

  /// The clipboard-send screen records its own success into the activity
  /// store; reload it when the route returns so the dashboard reflects it.
  Future<void> _openSendClipboard() async {
    await Navigator.of(context).pushNamed(sendClipboardRoute);
    await _loadLastActivity();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _loadLastActivity() async {
    final activity = await widget.lastActivityRepository.load();
    if (mounted) setState(() => _lastActivity = activity);
  }

  Future<void> _copyLastReceived() async {
    final activity = _lastActivity;
    final handler = widget.receiveNotificationTapHandler;
    if (activity == null ||
        activity.direction != ActivityDirection.received ||
        handler == null) {
      return;
    }
    await handler.copyLatest(image: activity.summary.startsWith('image'));
  }

  Future<void> _recordReceived(Map<Object?, Object?> data, String message) {
    final type = data['type'];
    final size = data['size'];
    final origin = data['origin'];
    final summary = (type is String && size is int)
        ? '$type (${_formatBytes(size)})'
        : message;
    return _record(
      LastActivity(
        direction: ActivityDirection.received,
        summary: summary,
        counterpart: origin is String ? origin : 'laptop',
        timestamp: DateTime.now(),
      ),
    );
  }

  Future<void> _recordSent(SharePayload payload) {
    final summary = switch (payload.type) {
      SharePayloadType.text => 'text (${payload.text?.length ?? 0} chars)',
      SharePayloadType.image => 'image',
      SharePayloadType.file => 'file',
    };
    return _record(
      LastActivity(
        direction: ActivityDirection.sent,
        summary: summary,
        counterpart: 'laptop',
        timestamp: DateTime.now(),
      ),
    );
  }

  Future<void> _record(LastActivity activity) async {
    await widget.lastActivityRepository.record(activity);
    if (mounted) setState(() => _lastActivity = activity);
  }

  String _describeReceive(Map<Object?, Object?> data, String message) {
    final type = data['type'];
    final size = data['size'];
    final origin = data['origin'];
    if (type is! String || size is! int || origin is! String) return message;
    return '$type (${_formatBytes(size)}) from $origin — $message';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _loadPairing() async {
    final results = await Future.wait<Object?>([
      widget.pairingRepository.load(),
      widget.appSettingsRepository.load(),
    ]);
    final pairing = results[0] as PairingCode?;
    final settings = results[1] as AppSettings;
    if (!mounted) return;
    setState(() {
      _pairing = pairing;
      _settings = settings;
      _loading = false;
      if (pairing != null) _connectionStatus = ConnectionStatus.searching;
    });
    await _syncForegroundService();
    await _startShareIntake();
    await _loadLastActivity();
    await _refreshSetupStatus();
    if (_setupLoader != null &&
        !(await widget.appSettingsRepository.onboardingComplete())) {
      // First run: the wizard is the whole surface until finished or skipped
      // through; gated by onboardingComplete, never force-re-shown (D1).
      if (mounted) await _openWizard();
      return;
    }
    if (pairing == null) await _discoverRelays();
  }

  Future<void> _refreshSetupStatus() async {
    final loader = _setupLoader;
    if (loader == null) return;
    final status = await loader.load();
    if (mounted) setState(() => _setupStatus = status);
  }

  Future<void> _openWizard() async {
    final actions = widget.setupActions;
    if (actions == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OnboardingWizard(
          actions: actions,
          settingsRepository: widget.appSettingsRepository,
          relayDiscovery: widget.relayDiscovery,
          connectionStatus: _connectedNotifier,
          onScanQr: () => Navigator.of(context).push<String>(
            MaterialPageRoute(builder: (_) => const QrPairingScreen()),
          ),
          savePairing: (pairing) async {
            await widget.pairingRepository.save(pairing);
            if (mounted) {
              setState(() {
                _pairing = pairing;
                _error = null;
                _connectionStatus = ConnectionStatus.searching;
              });
            }
            await _syncForegroundService();
            return null;
          },
        ),
      ),
    );
    await _refreshSetupStatus();
    if (_pairing == null) await _discoverRelays();
  }

  Future<void> _openChecklist() async {
    final loader = _setupLoader;
    if (loader == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SetupChecklistScreen(loader: loader)),
    );
    await _refreshSetupStatus();
  }

  Future<void> _discoverRelays() async {
    final discovery = widget.relayDiscovery;
    if (discovery == null || _discovering) return;
    setState(() => _discovering = true);
    List<DiscoveredRelay>? relays;
    try {
      relays = await discovery.discover();
    } on Exception catch (error) {
      _debugLog.add('discovery', 'Nearby search failed: $error', isError: true);
      _discoveryError = 'Nearby search failed. Check Wi-Fi, then try again.';
    }
    if (!mounted) return;
    setState(() {
      _discovering = false;
      if (relays != null) {
        _nearbyRelays = relays;
        _discoveryError = null;
      }
    });
  }

  void _selectNearbyRelay(DiscoveredRelay relay) {
    _hostController.text = relay.host;
    _portController.text = relay.port.toString();
    setState(() => _selectedRelay = relay);
  }

  Future<void> _saveManualPairing() async {
    try {
      final pairing = PairingCode.parseManual(
        host: _hostController.text,
        port: _portController.text,
        secret: _secretController.text,
      );
      await widget.pairingRepository.save(pairing);
      if (!mounted) return;
      setState(() {
        _pairing = pairing;
        _error = null;
        _connectionStatus = ConnectionStatus.searching;
      });
      await _syncForegroundService();
    } on PairingCodeException catch (error) {
      setState(() => _error = error.message);
    }
  }

  Future<void> _openQrScanner() async {
    final rawCode = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const QrPairingScreen()));
    if (rawCode == null) return;
    try {
      final pairing = PairingCode.parse(rawCode);
      await widget.pairingRepository.save(pairing);
      if (!mounted) return;
      setState(() {
        _pairing = pairing;
        _error = null;
        _connectionStatus = ConnectionStatus.searching;
      });
      await _syncForegroundService();
    } on PairingCodeException catch (error) {
      setState(() => _error = error.message);
    } on FormatException {
      setState(() => _error = 'QR code is not a valid Vidyut pairing code.');
    }
  }

  /// Deletes the saved pairing so the phone forgets the laptop (ADR 0005).
  /// Triggered from Settings behind a confirmation, never from home.
  Future<void> _forgetPairing() async {
    await widget.pairingRepository.reset();
    if (!mounted) return;
    setState(() {
      _connectionStatus = ConnectionStatus.offline;
      _pairing = null;
      _error = null;
      _selectedRelay = null;
    });
    await _syncForegroundService();
    await _discoverRelays();
  }

  Future<void> _startShareIntake() async {
    final source = widget.shareSource;
    if (source == null) return;
    await _shareIntakeController?.dispose();
    final controller = ShareIntakeController(
      source: source,
      publisher: SharePublisher(
        pairingRepository: widget.pairingRepository,
        relaySessionFactory: widget.relayConnectionFactory,
        crypto: PayloadCrypto(),
        fileReader: const LocalShareFileReader(),
      ),
      transferSender: _transferSender,
      onTransferResult: (result, {isError = false}) {
        if (isError) {
          _debugLog.add('transfer', '$result', isError: true);
          if (mounted) _showSnack('File transfer failed: $result');
          return;
        }
        final batch = result as PhoneTransferBatch;
        _debugLog.add('transfer', 'Sent ${batch.files.length} file(s).');
        if (mounted) _showSnack('Sent ${batch.files.length} file(s).');
      },
      onResult: (payload, result) {
        _debugLog.add('send', result.message, isError: !result.published);
        if (!mounted) return;
        if (result.published) {
          unawaited(_recordSent(payload));
        } else {
          _showSnack(result.message);
        }
      },
    );
    _shareIntakeController = controller;
    await controller.start();
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          settings: _settings,
          onChanged: _updateSettings,
          setupLoader: _setupLoader,
          clipboardAutoSendWatcher: ChannelClipboardAutoSendWatcher(),
          debugLog: _debugLog,
          paired: _pairing != null,
          onForgetPairing: _forgetPairing,
          updateChecker: GithubUpdateChecker(owner: 'Snehit70', repo: 'vidyut'),
          files: const VidyutFiles(),
        ),
      ),
    );
    await _refreshSetupStatus();
  }

  Future<void> _openFiles() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TransferFilesScreen(
          history: _transferHistory,
          sender: _transferSender,
          onOpenSettings: _openSettings,
        ),
      ),
    );
  }

  Future<void> _updateSettings(AppSettings settings) async {
    await widget.appSettingsRepository.save(settings);
    if (!mounted) return;
    setState(() => _settings = settings);
    await _syncForegroundService();
  }

  Future<void> _syncForegroundService() {
    return _foregroundServiceCoordinator.sync(
      settings: _settings,
      pairing: _pairing,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final paired = _pairing != null;
    final statusLabel = switch (_connectionStatus) {
      ConnectionStatus.connected =>
        _relayHealth?.degraded == true ? 'Needs attention' : 'Ready',
      ConnectionStatus.searching => 'Searching',
      ConnectionStatus.offline => paired ? 'Offline' : 'Unpaired',
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text('Vidyut'),
        actions: [
          if (paired)
            _AppBarAction(
              tooltip: 'Files',
              icon: Icons.folder_outlined,
              onPressed: _openFiles,
            ),
          _AppBarAction(
            tooltip: 'Settings',
            icon: Icons.settings_outlined,
            onPressed: _openSettings,
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _StatusHero(
              label: statusLabel,
              description: paired
                  ? switch (_connectionStatus) {
                      ConnectionStatus.connected =>
                        _relayHealth?.degraded == true
                            ? 'Connected, but the laptop clipboard watcher is not working.'
                            : 'Your laptop and phone share one clipboard.',
                      ConnectionStatus.searching =>
                        'Looking for your laptop on the network.',
                      ConnectionStatus.offline =>
                        "Can't reach your laptop right now.",
                    }
                  : 'Pair with the laptop relay to join the clipboard pool.',
              icon: switch (_connectionStatus) {
                ConnectionStatus.connected => Icons.link,
                ConnectionStatus.searching => Icons.wifi_find,
                ConnectionStatus.offline =>
                  paired ? Icons.cloud_off : Icons.qr_code_scanner,
              },
              searching: _connectionStatus == ConnectionStatus.searching,
              onTap: paired ? _showConnectionHelp : null,
            ).entrance(0),
            if (paired) ...[
              if (_lastActivity != null) ...[
                const SizedBox(height: 24),
                _DashboardRow(
                  icon: Icons.history,
                  title: 'Last activity',
                  subtitle: _lastActivity!.describe(),
                  onTap: _lastActivity!.direction == ActivityDirection.received
                      ? () => unawaited(_copyLastReceived())
                      : null,
                ).entrance(1),
              ],
              const SizedBox(height: 12),
              _DashboardRow(
                icon: Icons.dns_outlined,
                title: _relayHealth?.relayName ?? _pairing!.name ?? 'Laptop',
                subtitle: '${_pairing!.host}:${_pairing!.port}',
              ).entrance(2),
              if (_setupStatus != null) ...[
                const SizedBox(height: 12),
                _SetupHealthRow(
                  status: _setupStatus!,
                  settings: _settings,
                  onTap: () => unawaited(
                    _setupStatus!.onboardingComplete
                        ? _openChecklist()
                        : _openWizard(),
                  ),
                ).entrance(3),
              ],
            ] else ...[
              if (_setupStatus?.bannerNeeded(_settings) ?? false) ...[
                const SizedBox(height: 16),
                _SetupBanner(
                  label: _setupStatus!.bannerLabel(_settings),
                  onTap: () => unawaited(
                    _setupStatus!.onboardingComplete
                        ? _openChecklist()
                        : _openWizard(),
                  ),
                ).entrance(1),
              ],
              const SizedBox(height: 28),
              if (widget.relayDiscovery != null) ...[
                NearbyRelaysCard(
                  relays: _nearbyRelays,
                  selected: _selectedRelay,
                  discovering: _discovering,
                  onRefresh: _discoverRelays,
                  onSelect: _selectNearbyRelay,
                  error: _discoveryError,
                ).entrance(2),
                const SizedBox(height: 28),
              ],
              ManualPairingForm(
                hostController: _hostController,
                portController: _portController,
                secretController: _secretController,
                error: _error,
                onScanQr: _openQrScanner,
                onPair: _saveManualPairing,
              ).entrance(3),
            ],
          ],
        ),
      ),
    );
  }

  String _friendlyConnectionError(String message) {
    if (message.contains('auth') || message.contains('proof')) {
      return 'The laptop rejected this pairing. Pair again to continue.';
    }
    if (message.contains('timed out') || message.contains('socket')) {
      return 'The laptop did not respond. Check Wi-Fi and wake the laptop.';
    }
    return 'Vidyut will keep retrying automatically.';
  }

  Future<void> _showConnectionHelp() async {
    final degraded = _relayHealth?.degraded == true;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                degraded
                    ? 'Laptop clipboard needs attention'
                    : 'Connection help',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              Text(
                degraded
                    ? (_relayHealth?.clipboardError ??
                          'Restart the laptop relay and check wl-clipboard.')
                    : (_connectionDetail ??
                          'Vidyut is connected. If sync feels stuck, wake the laptop and retry now.'),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  unawaited(_syncForegroundService());
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Retry now'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  unawaited(_openSettings());
                },
                child: const Text('Open setup and diagnostics'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppBarAction extends StatelessWidget {
  const _AppBarAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: PressableScale(
        child: IconButton(
          tooltip: tooltip,
          icon: Icon(icon, size: 20, color: Palette.ink),
          style: IconButton.styleFrom(
            backgroundColor: Palette.mist,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          onPressed: onPressed,
        ),
      ),
    );
  }
}

class _StatusHero extends StatelessWidget {
  const _StatusHero({
    required this.label,
    required this.description,
    required this.icon,
    required this.searching,
    this.onTap,
  });

  final String label;
  final String description;
  final IconData icon;
  final bool searching;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    final content = Column(
      children: [
        const SizedBox(height: 16),
        MorphingBlob(
          size: 180,
          child: Container(
            width: 72,
            height: 72,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 32, color: Palette.raspberry),
          ),
        ),
        const SizedBox(height: 22),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (searching) ...[const PulsingDot(), const SizedBox(width: 6)],
            Text(label, style: textTheme.titleLarge),
          ],
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            description,
            textAlign: TextAlign.center,
            style: textTheme.bodyMedium?.copyWith(color: Palette.muted),
          ),
        ),
      ],
    );
    if (onTap == null) return content;
    return Semantics(
      button: true,
      label: 'Connection details',
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: content,
      ),
    );
  }
}

/// A flat dashboard row: leading chip icon, title, muted subtitle, optional
/// trailing chevron when tappable. Emphasis swaps the mist fill for petal to
/// flag something that wants attention (ADR 0004).
class _DashboardRow extends StatelessWidget {
  const _DashboardRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.emphasis = false,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool emphasis;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final surface = emphasis ? Palette.petal : Palette.mist;
    final chip = emphasis ? Palette.ground : Palette.petal;

    final row = Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: chip,
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(icon, size: 20, color: Palette.raspberry),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: textTheme.bodySmall?.copyWith(color: Palette.muted),
                ),
              ],
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right, size: 20, color: Palette.raspberry),
          ],
        ],
      ),
    );

    if (onTap == null) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(20),
        ),
        child: row,
      );
    }
    return PressableScale(
      child: Material(
        color: surface,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: row,
        ),
      ),
    );
  }
}

/// The persistent setup-health row on the paired dashboard (ADR 0004):
/// "All clear" with a check when healthy, "N issues" on petal otherwise.
class _SetupHealthRow extends StatelessWidget {
  const _SetupHealthRow({
    required this.status,
    required this.settings,
    required this.onTap,
  });

  final SetupStatus status;
  final AppSettings settings;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final issues = status.issueCount;
    final healthy = issues == 0;
    return _DashboardRow(
      icon: healthy ? Icons.check_circle : Icons.tune,
      title: 'Setup',
      subtitle: healthy
          ? 'All clear'
          : issues == 1
          ? '1 issue needs attention'
          : '$issues issues need attention',
      emphasis: !healthy,
      onTap: onTap,
    );
  }
}

/// Home banner (onboarding spec D1): "Finish setup" while onboarding is
/// incomplete, or the most actionable degradation afterwards. Tapping opens
/// the wizard resp. the checklist.
class _SetupBanner extends StatelessWidget {
  const _SetupBanner({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      child: Material(
        color: Palette.petal,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                const Icon(Icons.tune, size: 20, color: Palette.raspberry),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                const Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: Palette.raspberry,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class QrPairingScreen extends StatefulWidget {
  const QrPairingScreen({super.key});

  @override
  State<QrPairingScreen> createState() => _QrPairingScreenState();
}

class _QrPairingScreenState extends State<QrPairingScreen> {
  bool _handled = false;
  bool _cameraReady = false;
  String? _cameraError;

  @override
  void initState() {
    super.initState();
    unawaited(_prepareCamera());
  }

  Future<void> _prepareCamera() async {
    try {
      final status = await Permission.camera.request();
      if (!mounted) return;
      setState(() {
        if (status.isGranted) {
          _cameraReady = true;
        } else {
          _cameraError =
              'Camera permission is required to scan a pairing QR code.';
        }
      });
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() => _cameraError = 'Could not start the camera: $error');
    }
  }

  void _handleCameraError(Object error, StackTrace stackTrace) {
    if (!mounted) return;
    setState(
      () => _cameraError = 'Could not start the camera. Use manual pairing.',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR')),
      body: Stack(
        children: [
          if (_cameraReady && _cameraError == null)
            MobileScanner(
              onDetectError: _handleCameraError,
              errorBuilder: (context, error) => _CameraErrorView(
                message: error.errorDetails?.message ?? error.errorCode.message,
              ),
              onDetect: (capture) {
                if (_handled) return;
                final rawValue = capture.barcodes.firstOrNull?.rawValue;
                if (rawValue == null || rawValue.isEmpty) return;
                _handled = true;
                Navigator.of(context).pop(rawValue);
              },
            )
          else if (_cameraError != null)
            _CameraErrorView(message: _cameraError!)
          else
            const Center(child: CircularProgressIndicator()),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  color: Palette.petal,
                  borderRadius: BorderRadius.all(Radius.circular(999)),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 10,
                  ),
                  child: Text(
                    'Point at the QR code on the laptop',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraErrorView extends StatelessWidget {
  const _CameraErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '$message\n\nGo back and use Pair manually.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white),
          ),
        ),
      ),
    );
  }
}
