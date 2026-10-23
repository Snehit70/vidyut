part of 'main.dart';

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
    this.onPairingChanged,
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
  final ValueChanged<String?>? onPairingChanged;

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen>
    with WidgetsBindingObserver, RouteAware {
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
  PhoneClipboardPause _clipboardPause = const PhoneClipboardPause.off();
  LaptopTelemetry? _laptopTelemetry;
  bool _appVisible = true;
  bool _homeCovered = false;
  bool? _telemetryRequested;
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
    unawaited(_loadClipboardPause());
  }

  Future<void> _loadClipboardPause() async {
    final pause = await widget.appSettingsRepository.loadClipboardPause();
    if (mounted) setState(() => _clipboardPause = pause);
  }

  Future<void> _setClipboardPause(PhoneClipboardPause pause) async {
    setState(() => _clipboardPause = pause);
    await widget.appSettingsRepository.saveClipboardPause(pause);
    await widget.foregroundServiceClient.sendToTask(
      serviceClipboardPauseCommand,
    );
  }

  /// Recompute the D6 snapshot on resume so the home banner tracks external
  /// changes (revoking photos in system settings).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_loadLastActivity());
      unawaited(_refreshSetupStatus());
    }
    // Inactive still shows the app (notification shade, split screen).
    _appVisible =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    _updateTelemetryRequest();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic>) {
      _pageRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPushNext() {
    _homeCovered = true;
    _updateTelemetryRequest();
  }

  @override
  void didPopNext() {
    _homeCovered = false;
    _updateTelemetryRequest();
  }

  /// Laptop telemetry costs a /proc sample on the laptop and a radio wake
  /// here every five seconds, so the service only asks for it while the home
  /// screen is in front of someone. [resend] repeats the current answer for a
  /// service that has just (re)connected and may not have heard it.
  void _updateTelemetryRequest({bool resend = false}) {
    final wanted = _pairing != null && _appVisible && !_homeCovered;
    if (!resend && wanted == _telemetryRequested) return;
    _telemetryRequested = wanted;
    unawaited(
      widget.foregroundServiceClient.sendToTask(
        serviceTelemetryCommand(active: wanted),
      ),
    );
  }

  @override
  void dispose() {
    _pageRouteObserver.unsubscribe(this);
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
          if (status == ConnectionStatus.connected) {
            _updateTelemetryRequest(resend: true);
          }
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
              clipboardPaused: data['clipboardPaused'] == true,
              clipboardPausedUntil: switch (data['clipboardPausedUntilMs']) {
                final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
                _ => null,
              },
            );
          });
        }
      case 'clipboardPause':
        final pause = data['pause'];
        if (pause is String) {
          setState(() => _clipboardPause = PhoneClipboardPause.decode(pause));
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

  String get _knownCounterpart =>
      activityCounterpart(_relayHealth?.relayName ?? _pairing?.name);

  String _counterpartForOrigin(Object? origin) {
    if (origin is String && origin.isNotEmpty && origin != 'laptop') {
      return origin;
    }
    return _knownCounterpart;
  }

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
    final byteSize = data['byteSize'];
    final mime = data['mime'];
    final width = data['width'];
    final height = data['height'];
    return _record(
      LastActivity(
        direction: ActivityDirection.received,
        summary: summary,
        counterpart: _counterpartForOrigin(origin),
        timestamp: DateTime.now(),
        payloadId: data['payloadId'] is String
            ? data['payloadId'] as String
            : null,
        previewPath: data['previewPath'] is String
            ? data['previewPath'] as String
            : null,
        excerpt: data['excerpt'] is String ? data['excerpt'] as String : null,
        detail: byteSize is int
            ? formatMediaDetail(
                bytes: byteSize,
                mime: mime is String ? mime : null,
                width: width is int ? width : null,
                height: height is int ? height : null,
              )
            : null,
      ),
    );
  }

  Future<void> _recordSent(
    SharePayload payload, {
    required ActivityOutcome outcome,
  }) {
    final summary = switch (payload.type) {
      SharePayloadType.text => 'text (${payload.text?.length ?? 0} chars)',
      SharePayloadType.link => 'link',
      SharePayloadType.image => 'image',
      SharePayloadType.file => 'file',
    };
    String? previewPath;
    String? detail;
    if (payload.type == SharePayloadType.image) {
      final path = payload.path;
      if (path != null && File(path).existsSync()) {
        previewPath = path;
        final probe = ImageProbe.fromFile(path);
        detail = formatMediaDetail(
          bytes: File(path).lengthSync(),
          mime: payload.mime.isEmpty ? null : payload.mime,
          width: probe.width,
          height: probe.height,
        );
      }
    }
    return _record(
      LastActivity(
        direction: ActivityDirection.sent,
        summary: summary,
        counterpart: _knownCounterpart,
        timestamp: DateTime.now(),
        outcome: outcome,
        excerpt: payload.type == SharePayloadType.text ||
                payload.type == SharePayloadType.link
            ? payload.text
            : null,
        previewPath: previewPath,
        detail: detail,
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
        counterpart: _knownCounterpart,
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
            widget.onPairingChanged?.call(pairing.name);
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
      widget.onPairingChanged?.call(pairing.name);
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
      widget.onPairingChanged?.call(pairing.name);
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
    widget.onPairingChanged?.call(null);
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
          verificationCodes: PostedNotifications(),
          debugLog: _debugLog,
          paired: _pairing != null,
          pairedDeviceName: _relayHealth?.relayName ?? _pairing?.name,
          pairedDeviceAddress: _pairing == null
              ? null
              : '${_pairing!.host}:${_pairing!.port}',
          onForgetPairing: _forgetPairing,
          updateChecker: GithubUpdateChecker(owner: 'Snehit70', repo: 'vidyut'),
          files: const VidyutFiles(),
          onBrowseLaptop: () => unawaited(_openLaptopFiles()),
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
          onBrowseLaptop: () => unawaited(_openLaptopFiles()),
        ),
      ),
    );
  }

  Future<void> _openLaptopFiles() async {
    // The stored pairing carries the relay-proof pin; the screen's copy can
    // predate it.
    final pairing = await widget.pairingRepository.load();
    if (pairing == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LaptopFilesScreen(
          files: LaptopFileBrowser(
            pairing: pairing,
            connectionFactory: widget.relayConnectionFactory,
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
    _updateTelemetryRequest();
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
        clipboardPause: _clipboardPause,
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
      // The pause controls make this taller than the default sheet cap on a
      // small phone, so it sizes to its content and scrolls past that.
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
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
              const SizedBox(height: 20),
              _ClipboardPauseControls(
                pause: _clipboardPause,
                laptopPaused: _relayHealth?.clipboardPaused == true,
                onChanged: (pause) {
                  Navigator.of(context).pop();
                  unawaited(_setClipboardPause(pause));
                },
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

/// Pause and resume for this phone's side of clipboard sync. The laptop's
/// pause is its own and is lifted from the laptop.
class _ClipboardPauseControls extends StatelessWidget {
  const _ClipboardPauseControls({
    required this.pause,
    required this.laptopPaused,
    required this.onChanged,
  });

  final PhoneClipboardPause pause;
  final bool laptopPaused;
  final ValueChanged<PhoneClipboardPause> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final paused = pause.activeAt(DateTime.now());
    PhoneClipboardPause after(Duration duration) =>
        PhoneClipboardPause.until(DateTime.now().add(duration));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Clipboard sync', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          paused
              ? 'Paused on this phone. Laptop copies are not written here, '
                    'and screenshots and copied text are not sent. Sharing '
                    'and files still work.'
              : 'Pause to keep this phone’s clipboard to itself for a while. '
                    'Sharing and files still work.',
          style: theme.textTheme.bodyMedium,
        ),
        if (laptopPaused) ...[
          const SizedBox(height: 4),
          Text(
            'The laptop has paused sync too. Resume it from the laptop.',
            style: theme.textTheme.bodyMedium,
          ),
        ],
        const SizedBox(height: 8),
        if (paused)
          OutlinedButton.icon(
            onPressed: () => onChanged(const PhoneClipboardPause.off()),
            icon: const Icon(Icons.play_arrow_outlined),
            label: const Text('Resume sync'),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: () => onChanged(after(const Duration(minutes: 15))),
                child: const Text('15 min'),
              ),
              OutlinedButton(
                onPressed: () => onChanged(after(const Duration(hours: 1))),
                child: const Text('1 hour'),
              ),
              OutlinedButton(
                onPressed: () =>
                    onChanged(const PhoneClipboardPause.untilResumed()),
                child: const Text('Until I resume'),
              ),
            ],
          ),
      ],
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
