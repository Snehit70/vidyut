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
import 'src/activity/recent_activity_screen.dart';
import 'src/debug/debug_log.dart';
import 'src/design/theme.dart';
import 'src/design/widgets.dart';
import 'src/foreground/foreground_service_client.dart';
import 'src/foreground/foreground_service_coordinator.dart';
import 'src/foreground/vidyut_foreground_service.dart';
import 'src/foreground/send_clipboard_screen.dart';
import 'src/home/home_screen.dart';
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
import 'src/shared/format.dart';
import 'src/shared/relay_connection.dart';
import 'src/shared/wire.dart';
import 'src/transfer/phone_transfer_sender.dart';
import 'src/transfer/transfer_file_actions.dart';
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

  @override
  void initState() {
    super.initState();
    unawaited(_loadThemeMode());
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
    this.onThemeModeChanged,
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
  final ValueChanged<AppThemeMode>? onThemeModeChanged;

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
  List<LastActivity> _activities = const [];
  var _activityRevision = 0;
  var _activityLoadGeneration = 0;
  bool _loading = true;
  late final DebugLog _debugLog = widget.debugLog ?? sharedDebugLog;
  late final TransferHistoryRepository _transferHistory =
      TransferHistoryRepository(SharedPreferencesTransferHistoryStorage());
  final _transferFileActions = const AndroidTransferFileActions();
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
    onBatchTerminal: _recordTransferResult,
  );

  /// Live "connected" flag mirrored into the wizard's finale (D2).
  final _connectedNotifier = ValueNotifier<bool>(false);
  StreamSubscription<List<LastActivity>>? _activitySubscription;
  Timer? _relativeTimeTimer;
  SetupStatus? _setupStatus;
  RelayHealth? _relayHealth;
  LaptopTelemetry? _laptopTelemetry;
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
    _activitySubscription = widget.lastActivityRepository.changes.listen((
      activities,
    ) {
      _activityRevision++;
      _activityLoadGeneration++;
      if (mounted) setState(() => _activities = activities);
    });
    _relativeTimeTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(() {});
    });
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
    if (state == AppLifecycleState.resumed) {
      unawaited(_loadLastActivity());
      unawaited(_refreshSetupStatus());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _activitySubscription?.cancel();
    _relativeTimeTimer?.cancel();
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
            if (status == ConnectionStatus.offline) _laptopTelemetry = null;
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
      case 'telemetry':
        final telemetry = LaptopTelemetry.fromJson(data);
        if (telemetry != null) setState(() => _laptopTelemetry = telemetry);
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
          } else if (data['activityHandled'] != true) {
            unawaited(_recordReceived(data, message));
          }
        }
      case 'activity':
        final activity = _decodeActivity(data);
        if (activity != null) {
          if (data['persisted'] == true) {
            unawaited(_loadLastActivity());
          } else {
            unawaited(_record(activity));
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
    final generation = ++_activityLoadGeneration;
    final revision = _activityRevision;
    final activities = await widget.lastActivityRepository.loadAll();
    if (!mounted ||
        generation != _activityLoadGeneration ||
        revision != _activityRevision) {
      return;
    }
    setState(() => _activities = activities);
  }

  LastActivity? get _lastActivity => _activities.firstOrNull;

  Future<void> _openRecentActivity() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RecentActivityScreen(
          activities: _activities,
          deviceName:
              _relayHealth?.relayName ?? _pairing?.name ?? 'Laptop (Linux)',
          activityChanges: widget.lastActivityRepository.changes,
          loadActivities: widget.lastActivityRepository.loadAll,
          onCopy: (activity) async {
            if (activity.direction != ActivityDirection.received) return;
            await widget.receiveNotificationTapHandler?.copyActivity(activity);
          },
          onRetry: (activity) async {
            if (activity.direction != ActivityDirection.sent ||
                activity.payloadId == null) {
              return;
            }
            final batch = (await _transferHistory.load())
                .where((item) => item.transferId == activity.payloadId)
                .firstOrNull;
            if (batch == null) return;
            await _runTransferFileAction(
              'Retry transfer',
              () => _transferSender.retry(batch),
            );
          },
        ),
      ),
    );
    await _loadLastActivity();
  }

  Future<void> _recordReceived(Map<Object?, Object?> data, String message) {
    final type = data['type'];
    final size = data['size'];
    final origin = data['origin'];
    final summary = (type is String && size is int)
        ? '$type (${formatBytes(size)})'
        : message;
    return _record(
      LastActivity(
        direction: ActivityDirection.received,
        summary: summary,
        counterpart: origin is String ? origin : 'laptop',
        timestamp: DateTime.now(),
        payloadId: data['payloadId'] is String
            ? data['payloadId'] as String
            : null,
        previewPath: data['previewPath'] is String
            ? data['previewPath'] as String
            : null,
        excerpt: data['excerpt'] is String ? data['excerpt'] as String : null,
      ),
    );
  }

  Future<void> _recordSent(
    SharePayload payload, {
    required ActivityOutcome outcome,
  }) {
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
        outcome: outcome,
      ),
    );
  }

  Future<void> _record(LastActivity activity) async {
    await widget.lastActivityRepository.record(activity);
    _activityRevision++;
    _activityLoadGeneration++;
    final activities = await widget.lastActivityRepository.loadAll();
    if (mounted) {
      setState(() => _activities = activities);
    }
  }

  Future<void> _recordTransferResult(PhoneTransferBatch batch) async {
    final failed = batch.files.any(
      (file) => switch (file.status) {
        PhoneTransferStatus.failed ||
        PhoneTransferStatus.cancelled ||
        PhoneTransferStatus.expired => true,
        _ => false,
      },
    );
    final noun = batch.files.length == 1 ? 'file' : 'files';
    await _record(
      LastActivity(
        direction: ActivityDirection.sent,
        summary: '${batch.files.length} $noun${failed ? ' (with issues)' : ''}',
        counterpart: 'laptop',
        timestamp: DateTime.fromMillisecondsSinceEpoch(batch.updatedAtMs),
        payloadId: batch.transferId,
        outcome: failed ? ActivityOutcome.failed : ActivityOutcome.completed,
        retryable: failed,
        title: batch.files.length == 1 ? batch.files.single.filename : null,
        detail: batch.files.length == 1
            ? '${formatBytes(batch.files.single.size)}  •  ${batch.files.single.mime}'
            : null,
        previewPath: batch.files.length == 1
            ? transferSourcePreviewPath(batch.files.single)
            : null,
      ),
    );
  }

  LastActivity? _decodeActivity(Map<Object?, Object?> data) {
    try {
      return LastActivity.fromJson(data.cast<String, Object?>());
    } on Object {
      return null;
    }
  }

  String _describeReceive(Map<Object?, Object?> data, String message) {
    final type = data['type'];
    final size = data['size'];
    final origin = data['origin'];
    if (type is! String || size is! int || origin is! String) return message;
    return '$type (${formatBytes(size)}) from $origin: $message';
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
    if (pairing != null) unawaited(_transferSender.resumePending());
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
        if (mounted) _showSnack('Sending ${batch.files.length} file(s)…');
      },
      onResult: (payload, result) {
        _debugLog.add('send', result.message, isError: !result.published);
        unawaited(
          _recordSent(
            payload,
            outcome: result.published
                ? ActivityOutcome.completed
                : ActivityOutcome.failed,
          ),
        );
        if (!result.published && mounted) {
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
          pairedDeviceName: _relayHealth?.relayName ?? _pairing?.name,
          pairedDeviceAddress: _pairing == null
              ? null
              : '${_pairing!.host}:${_pairing!.port}',
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
          onOpenHome: () => Navigator.of(context).pop(),
          onOpenSettings: _openSettings,
          onOpenFile: (file) => _runTransferFileAction(
            'Open file',
            () => _transferFileActions.open(file),
          ),
          onShareFile: (file) => _runTransferFileAction(
            'Share file',
            () => _transferFileActions.share(file),
          ),
          canUseFileAction: _transferFileActions.canUse,
          onSendAgain: (file) => _runTransferFileAction(
            'Send again',
            () => _transferSender.sendAgain(file),
          ),
        ),
      ),
    );
  }

  Future<void> _runTransferFileAction(
    String label,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (error) {
      _debugLog.add('transfer', '$label failed: $error', isError: true);
      if (mounted) _showSnack('$label failed.');
    }
  }

  Future<void> _updateSettings(AppSettings settings) async {
    await widget.appSettingsRepository.save(settings);
    if (!mounted) return;
    setState(() => _settings = settings);
    widget.onThemeModeChanged?.call(settings.themeMode);
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
    if (paired) {
      final setupNeedsAttention = _setupStatus?.bannerNeeded(_settings) == true;
      return HomeScreen(
        connectionStatus: _connectionStatus,
        relayHealth: _relayHealth,
        laptopTelemetry: _laptopTelemetry,
        lastActivity: _lastActivity,
        onOpenFiles: () => unawaited(_openFiles()),
        onOpenSettings: () => unawaited(_openSettings()),
        onOpenRecentActivity: () => unawaited(_openRecentActivity()),
        onOpenConnectionDetails: () => unawaited(_showConnectionHelp()),
        onSendFiles: () => unawaited(_openFiles()),
        setupBannerLabel: setupNeedsAttention
            ? _setupStatus!.bannerLabel(_settings)
            : null,
        onOpenSetup: setupNeedsAttention
            ? () => unawaited(
                _setupStatus!.onboardingComplete
                    ? _openChecklist()
                    : _openWizard(),
              )
            : null,
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Image.asset(
              'assets/icon/icon-legacy.png',
              width: 32,
              height: 32,
              fit: BoxFit.contain,
            ),
            const SizedBox(width: 10),
            const Text('Vidyut'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
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
              label: 'Unpaired',
              description:
                  'Pair with the laptop relay to join the clipboard pool.',
              icon: Icons.qr_code_scanner,
              searching: false,
            ).entrance(0),
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
    final pairing = _pairing;
    final relayName = _relayHealth?.relayName ?? pairing?.name;
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
              if (relayName != null || pairing != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.primaryContainer,
                    foregroundColor: Theme.of(
                      context,
                    ).colorScheme.onPrimaryContainer,
                    child: const Icon(Icons.laptop_mac_outlined),
                  ),
                  title: Text(relayName ?? 'Paired laptop'),
                  subtitle: pairing == null
                      ? null
                      : Text('${pairing.host}:${pairing.port}'),
                ),
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

class _StatusHero extends StatelessWidget {
  const _StatusHero({
    required this.label,
    required this.description,
    required this.icon,
    required this.searching,
  });

  final String label;
  final String description;
  final IconData icon;
  final bool searching;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    final content = Column(
      children: [
        const SizedBox(height: 16),
        Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(icon, size: 36, color: scheme.primary),
        ),
        const SizedBox(height: 22),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (searching) ...[
              PulsingDot(color: scheme.primary, size: 8),
              const SizedBox(width: 6),
            ],
            Text(label, style: textTheme.titleLarge),
          ],
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            description,
            textAlign: TextAlign.center,
            style: textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
    return content;
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
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Icon(
                  Icons.tune,
                  size: 20,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: Theme.of(context).colorScheme.primary,
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
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.all(Radius.circular(999)),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 10,
                  ),
                  child: Text(
                    'Point at the QR code on the laptop',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
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
