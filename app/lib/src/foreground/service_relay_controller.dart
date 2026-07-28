import 'dart:async';

import 'package:clipboard_autosend/clipboard_autosend.dart';
import 'package:flutter/services.dart';
import 'package:screenshot_observer/screenshot_observer.dart';

import '../pairing/pairing_code.dart';
import '../push/screenshot_push_controller.dart';
import '../receive/payload_receiver.dart';
import '../settings/app_settings.dart';
import '../share/share_payload.dart';
import '../share/share_publisher.dart';
import '../shared/relay_connection.dart';
import '../shared/wire.dart';

const serviceSyncCommand = {'kind': 'sync'};

typedef ServicePairingLoader = Future<PairingCode?> Function();
typedef ServiceSettingsLoader = Future<AppSettings> Function();
typedef ServiceConnectionFactory =
    RelayConnection Function(PairingCode pairing);
typedef ServiceReceiverFactory = PayloadReceiver Function(AppSettings settings);
typedef ServiceEmit = void Function(Map<String, Object?> message);
typedef ServiceNotificationUpdate =
    Future<void> Function(String title, String text);

/// Publishes an auto-read clipboard payload through the one existing send path
/// (read-logs-auto-text D3): the manual `SharePublisher.publish`, so auto and
/// manual sends are indistinguishable on the wire.
typedef ServiceAutoSendPublish =
    Future<SharePublishResult> Function(SharePayload payload);

/// Reconnect delays after successive drops; stays at the last entry.
/// Capped at 32s (keepalive spec D4): steady-state drops are rare after the
/// MIUI toggles, so the cap only bounds screen-on staleness during outages.
const defaultReconnectBackoff = [
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 16),
  Duration(seconds: 32),
];

/// Bounds each preparatory await in the sync pass (teardown, settings and
/// pairing loads, permission probes): after a process freeze a
/// platform-channel reply can be dropped outright, leaving a future that
/// never completes, and an unbounded await there wedges every later recovery
/// attempt (#35).
const defaultSyncStepTimeout = Duration(seconds: 10);

/// A sync pass still in flight after this long is presumed wedged on a
/// poisoned await; the watchdog abandons it and starts a fresh one (#35).
const defaultSyncStallTimeout = Duration(seconds: 45);

/// Cadence of the service-isolate watchdog — the last-resort recovery lever
/// for when every event-driven path (backoff timer, screen-on trigger, sync
/// command) has been lost to a freeze (#35).
const defaultWatchdogInterval = Duration(minutes: 1);

/// Owns the relay connection inside the foreground service isolate.
///
/// The UI never holds the receive socket: it observes `emit`ed messages
/// (`{'kind': 'status'}` / `{'kind': 'receive'}`) and asks for reconnection
/// by sending [serviceSyncCommand] to the task.
///
/// When the socket drops (WiFi loss, relay restart) the controller
/// reconnects on its own with [reconnectBackoff]; a successful connection
/// resets the backoff. The relay re-sends the current pool payload on every
/// auth, so the frame last handled is deduplicated across reconnects.
///
/// Sync passes are serialized and every await in them is bounded, and a
/// periodic watchdog abandons a stalled pass and revives a disconnected
/// controller whose timers were lost — a MIUI process freeze can drop a
/// platform-channel reply or a socket-death event, and without these guards
/// one poisoned future wedged reconnection permanently (#35).
class ServiceRelayController {
  ServiceRelayController({
    required this.loadPairing,
    required this.loadSettings,
    required this.connectionFactory,
    required this.receiverFactory,
    required this.emit,
    required this.updateNotification,
    this.screenshotWatcher,
    this.pushController,
    this.screenOnEvents,
    this.clipboardAutoSendWatcher,
    this.autoSendPublish,
    this.deviceId = 'phone',
    this.reconnectBackoff = defaultReconnectBackoff,
    this.syncStepTimeout = defaultSyncStepTimeout,
    this.syncStallTimeout = defaultSyncStallTimeout,
    this.watchdogInterval = defaultWatchdogInterval,
  });

  final ServicePairingLoader loadPairing;
  final ServiceSettingsLoader loadSettings;
  final ServiceConnectionFactory connectionFactory;
  final ServiceReceiverFactory receiverFactory;
  final ServiceEmit emit;
  final ServiceNotificationUpdate updateNotification;

  /// Optional collaborator (injected like [connectionFactory] to keep this
  /// class testable). When present, [_sync] starts it while
  /// [AppSettings.autoPushScreenshots] is on and photo access is `full`, and
  /// pauses otherwise. Its lifetime spans reconnects — only [stop] tears it
  /// down. Screenshots it emits are the push pipeline's input (#28).
  final ScreenshotWatcher? screenshotWatcher;

  /// The auto-push pipeline (#28). Long-lived across reconnects: [_sync]
  /// re-attaches it to each fresh connection and [_teardown] detaches it, so
  /// its pending frame survives every connection swap (the offline hold).
  final ScreenshotPushController? pushController;

  /// Screen-on broadcasts from the native side (keepalive spec D5). An event
  /// while disconnected resets the backoff and reconnects immediately — the
  /// user who wakes the phone to screenshot must not wait out a 32s retry.
  /// A no-op while connected. Subscribed for the controller's whole lifetime;
  /// only [stop] cancels it.
  final Stream<void>? screenOnEvents;

  /// Opt-in READ_LOGS auto-text watcher (read-logs-auto-text D2). When present,
  /// [_sync] starts it while [AppSettings.enableClipboardAutoSend] is on **and**
  /// `READ_LOGS` is granted, and stops it otherwise. Its lifetime spans
  /// reconnects — only [stop] tears it down. Reads it emits are echo-guarded
  /// (D4) and published through [autoSendPublish] (D3).
  final ClipboardAutoSendWatcher? clipboardAutoSendWatcher;

  /// The one publish path for auto-read text (D3). Left null when the auto-send
  /// watcher is absent (tests, no plugin).
  final ServiceAutoSendPublish? autoSendPublish;

  final String deviceId;
  final List<Duration> reconnectBackoff;
  final Duration syncStepTimeout;
  final Duration syncStallTimeout;
  final Duration watchdogInterval;

  RelayConnection? _connection;
  PayloadReceiveController? _receiveController;
  StreamSubscription<ConnectionStatus>? _statusSubscription;
  StreamSubscription<RelayEvent>? _eventSubscription;
  StreamSubscription<RelayHealth>? _healthSubscription;
  StreamSubscription<ScreenshotEvent>? _screenshotEventsSubscription;
  StreamSubscription<String>? _screenshotDiagnosticsSubscription;
  StreamSubscription<void>? _screenOnSubscription;
  StreamSubscription<ManualClipboardReadResult>? _manualReadSubscription;
  StreamSubscription<String>? _autoSendTextsSubscription;
  StreamSubscription<String>? _autoSendDiagnosticsSubscription;
  ConnectionStatus _lastStatus = ConnectionStatus.offline;
  bool _screenshotWatching = false;
  bool _screenshotPaused = false;
  bool _autoSendWatching = false;
  bool _autoSendInertLogged = false;
  bool _manualSendInFlight = false;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _stopped = false;
  Timer? _watchdogTimer;
  bool _syncing = false;
  bool _resyncRequested = false;
  DateTime? _syncStartedAt;
  int _syncGeneration = 0;

  /// The last sync pass found no stored pairing. Unpaired-offline is a
  /// deliberate resting state (recovery is the UI's sync command after a
  /// save), so the watchdog must not churn syncs — and flood the debug log —
  /// against it.
  bool _unpaired = false;
  ({String origin, int ts})? _lastHandledFrame;

  /// The exact text last written to the clipboard on behalf of a received
  /// payload (D4). An auto-read equal to it is dropped before publish, then the
  /// record is cleared so a genuine re-copy of the same text still sends.
  String? _lastReceivedClipboardWrite;

  Future<void> start() {
    _screenOnSubscription ??= screenOnEvents?.listen((_) => _onScreenOn());
    _manualReadSubscription ??= clipboardAutoSendWatcher?.manualResults.listen(
      (result) => unawaited(_onManualClipboardResult(result)),
    );
    // Armed before the first sync pass so even a wedged initial pass gets
    // abandoned and retried.
    _watchdogTimer ??= Timer.periodic(watchdogInterval, (_) => _watchdogTick());
    return _sync();
  }

  /// Screen-on trigger (keepalive spec D5): reconnect immediately if not
  /// connected, no-op when connected. The debug-log line is the phone-side
  /// timestamp for the ≤2s screen-on → auth_ok measurement (E2E §11).
  void _onScreenOn() {
    if (_stopped) return;
    _abandonStalledSync();
    if (_lastStatus == ConnectionStatus.connected) return;
    _log('Screen on while disconnected; reconnecting now.');
    _reconnectAttempt = 0;
    unawaited(_sync());
  }

  void _watchdogTick() {
    if (_stopped) return;
    if (_abandonStalledSync()) {
      _reconnectAttempt = 0;
      unawaited(_sync());
      return;
    }
    if (_lastStatus != ConnectionStatus.connected &&
        !_unpaired &&
        !_syncing &&
        _reconnectTimer == null) {
      // Disconnected with nothing scheduled to fix it: every event-driven
      // recovery path has been lost (e.g. a socket-death event dropped
      // during a freeze).
      _log(
        'Watchdog: disconnected with no pending reconnect; reconnecting now.',
      );
      _reconnectAttempt = 0;
      unawaited(_sync());
    }
  }

  /// Retires a sync pass that has been in flight past [syncStallTimeout], so
  /// its late completions become no-ops and a fresh pass can take over.
  /// Returns whether a pass was abandoned.
  bool _abandonStalledSync() {
    final startedAt = _syncStartedAt;
    if (startedAt == null ||
        DateTime.now().difference(startedAt) <= syncStallTimeout) {
      return false;
    }
    _log(
      'Watchdog: sync stalled; abandoning it and reconnecting.',
      isError: true,
    );
    _syncGeneration += 1;
    _syncing = false;
    _syncStartedAt = null;
    return true;
  }

  Future<void> handleTaskData(Object? data) async {
    if (data is! Map) return;
    switch (data['kind']) {
      case 'sync':
        _reconnectAttempt = 0;
        await _sync();
        return;
    }
  }

  Future<void> _onManualClipboardResult(
    ManualClipboardReadResult result,
  ) async {
    if (_stopped) return;
    final publish = autoSendPublish;
    if (publish == null) {
      await updateNotification(
        'Vidyut could not send',
        'Clipboard publisher is unavailable.',
      );
      return;
    }
    switch (result.status) {
      case ManualClipboardReadStatus.empty:
        _log('Manual clipboard send stopped: clipboard is empty.');
        await updateNotification(
          'Vidyut could not send',
          'The clipboard has no text.',
        );
        return;
      case ManualClipboardReadStatus.unreadable:
        _log('Manual clipboard read failed.', isError: true);
        await updateNotification(
          'Vidyut could not send',
          'Clipboard text could not be read.',
        );
        return;
      case ManualClipboardReadStatus.focusTimeout:
        _log('Manual clipboard read timed out.', isError: true);
        await updateNotification(
          'Vidyut could not send',
          'Clipboard access timed out. Tap to try again.',
        );
        return;
      case ManualClipboardReadStatus.busy:
        _log('Manual clipboard send ignored: another read is active.');
        await updateNotification(
          'Vidyut is already sending',
          'Wait for the current send to finish.',
        );
        return;
      case ManualClipboardReadStatus.text:
        break;
    }
    if (_manualSendInFlight) {
      _log('Manual clipboard send ignored: publish already in progress.');
      await updateNotification(
        'Vidyut is already sending',
        'Wait for the current send to finish.',
      );
      return;
    }
    final text = result.text;
    if (text == null || text.trim().isEmpty) {
      _log('Manual clipboard result had no text.', isError: true);
      await updateNotification(
        'Vidyut could not send',
        'Clipboard text could not be read.',
      );
      return;
    }
    _manualSendInFlight = true;
    try {
      final publishResult = await publish(SharePayload.text(text));
      _log(
        'Manual clipboard send: ${publishResult.message}',
        isError: !publishResult.published,
      );
      await updateNotification(
        publishResult.published
            ? 'Vidyut sent to laptop'
            : 'Vidyut could not send',
        publishResult.published ? 'Copied text sent.' : publishResult.message,
      );
      emit({
        'kind': 'send',
        'sent': publishResult.published,
        'message': publishResult.message,
        'type': 'text',
        'size': text.length,
      });
    } catch (error) {
      _log('Manual clipboard send failed: $error', isError: true);
      await updateNotification('Vidyut could not send', 'Tap to try again.');
    } finally {
      _manualSendInFlight = false;
    }
  }

  Future<void> stop() async {
    _stopped = true;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    await _screenOnSubscription?.cancel();
    _screenOnSubscription = null;
    await _manualReadSubscription?.cancel();
    _manualReadSubscription = null;
    await _stopScreenshotWatcher();
    await _stopClipboardAutoSendWatcher();
    await _teardown();
  }

  /// Records the text just written to the clipboard for a received payload, so
  /// the echo guard (D4) can drop the auto-read it provokes. Called from the
  /// composition's receive-clipboard wrapper after a successful write.
  void recordReceivedClipboardText(String text) {
    _lastReceivedClipboardWrite = text;
  }

  Future<void> _sync() async {
    if (_syncing) {
      // A pass is already in flight; run another when it finishes so a
      // just-changed setting or pairing is never missed.
      _resyncRequested = true;
      return;
    }
    _syncing = true;
    _syncStartedAt = DateTime.now();
    final generation = ++_syncGeneration;
    try {
      await _syncOnce(generation);
    } on TimeoutException catch (error) {
      if (generation != _syncGeneration) return;
      _log('Sync step timed out (${error.message}); retrying.', isError: true);
      _scheduleReconnect();
    } finally {
      // An abandoned pass (generation retired by the watchdog) must not
      // clear state the fresh pass now owns.
      if (generation == _syncGeneration) {
        _syncing = false;
        _syncStartedAt = null;
        if (_resyncRequested) {
          _resyncRequested = false;
          unawaited(_sync());
        }
      }
    }
  }

  /// Bounds a preparatory await in [_syncOnce]; see [syncStepTimeout].
  Future<T> _bounded<T>(Future<T> step, String label) {
    return step.timeout(
      syncStepTimeout,
      onTimeout: () => throw TimeoutException(label, syncStepTimeout),
    );
  }

  Future<void> _syncOnce(int generation) async {
    await _bounded(_teardown(), 'teardown');
    // The observer's lifetime tracks the setting and photo grant, not the relay
    // connection (§6: always-on while the service runs), so reconcile it before
    // the pairing check — it must keep watching even while unpaired/offline.
    final settings = await _bounded(loadSettings(), 'load settings');
    if (generation != _syncGeneration) return;
    await _bounded(_reconcileScreenshotWatcher(settings), 'screenshot watcher');
    await _bounded(
      _reconcileClipboardAutoSendWatcher(settings),
      'auto-send watcher',
    );
    final pairing = await _bounded(loadPairing(), 'load pairing');
    if (generation != _syncGeneration) return;
    _unpaired = pairing == null;
    if (pairing == null) {
      _log('No pairing stored; staying offline.');
      await _bounded(
        _publishStatus(ConnectionStatus.offline),
        'publish status',
      );
      return;
    }
    _log('Connecting to relay at ${pairing.host}:${pairing.port}.');
    final connection = connectionFactory(pairing);
    _connection = connection;
    // Attach before start() so the pipeline sees this session's `connected`
    // transition and republishes any frame held while offline.
    pushController?.attachSession(connection, pairingSecret: pairing.secret);
    _statusSubscription = connection.status.listen((status) {
      if (status == ConnectionStatus.connected) {
        _reconnectAttempt = 0;
      }
      if (status == ConnectionStatus.offline) {
        _scheduleReconnect();
      }
      unawaited(_publishStatus(status));
    });
    _eventSubscription = connection.events.listen((event) {
      _log(event.message, isError: event.isError);
    });
    _healthSubscription = connection.health.listen((health) {
      emit({
        'kind': 'health',
        'status': health.status,
        'relayName': health.relayName,
        'clipboardStatus': health.clipboardStatus,
        'clipboardError': health.clipboardError,
      });
      if (health.degraded) {
        _log(
          'Laptop clipboard needs attention: '
          '${health.clipboardError ?? health.clipboardStatus ?? 'degraded'}.',
          isError: true,
        );
      }
    });
    _receiveController = PayloadReceiveController(
      frames: connection.payloads.where(_shouldHandleFrame),
      pairingSecret: pairing.secret,
      receiver: receiverFactory(settings),
      onResult: (frame, result) {
        emit({
          'kind': 'receive',
          'received': result.received,
          'message': result.message,
          'type': frame.type.wireName,
          'size': _payloadSizeBytes(frame.payload),
          'origin': frame.origin,
        });
      },
    )..start();
    await connection.start();
  }

  /// Drops the phone's own frames and the pool re-send that follows every
  /// reconnect: the relay pushes its current payload after each auth, so a
  /// frame with the same origin and timestamp has already been handled.
  bool _shouldHandleFrame(PayloadFrame frame) {
    if (frame.origin == deviceId) return false;
    final last = _lastHandledFrame;
    if (last != null && last.origin == frame.origin && last.ts == frame.ts) {
      return false;
    }
    _lastHandledFrame = (origin: frame.origin, ts: frame.ts);
    return true;
  }

  /// Brings the observer in line with the current settings and photo grant.
  /// Idempotent and safe to call on every [_sync] (including reconnects): a
  /// watcher already in the right state is left untouched, so the native
  /// observer isn't churned — and its start watermark isn't reset — on a
  /// reconnect.
  Future<void> _reconcileScreenshotWatcher(AppSettings settings) async {
    final watcher = screenshotWatcher;
    if (watcher == null) return;

    if (!settings.autoPushScreenshots) {
      await _stopScreenshotWatcher();
      // Toggle off clears the hold too (§7): a held frame must not surface
      // minutes later when the user has said stop.
      pushController?.clearPending();
      _setScreenshotPaused(false);
      return;
    }

    final access = await watcher.accessLevel();
    if (access == ScreenshotAccessLevel.full) {
      await _startScreenshotWatcher(watcher);
    } else {
      // Setting on but access isn't full: the observer can't work (§5). Stop it
      // and surface the paused state; recovery is a Settings deep-link in the UI.
      await _stopScreenshotWatcher();
      _setScreenshotPaused(true, access: access);
    }
  }

  Future<void> _startScreenshotWatcher(ScreenshotWatcher watcher) async {
    if (_screenshotWatching) {
      _setScreenshotPaused(false);
      return;
    }
    _screenshotEventsSubscription = watcher.events.listen(_onScreenshotEvent);
    _screenshotDiagnosticsSubscription = watcher.diagnostics.listen(_log);
    try {
      await watcher.start();
      _screenshotWatching = true;
      _setScreenshotPaused(false);
      _log('Screenshot observer started.');
    } on PlatformException catch (error) {
      // Access downgraded between the check and start(); treat as paused.
      await _cancelScreenshotSubscriptions();
      _log(
        'Screenshot observer refused to start: ${error.code} '
        '(${error.message}).',
        isError: true,
      );
      _setScreenshotPaused(true);
    }
  }

  Future<void> _stopScreenshotWatcher() async {
    await _cancelScreenshotSubscriptions();
    if (!_screenshotWatching) return;
    _screenshotWatching = false;
    try {
      await screenshotWatcher?.stop();
    } catch (error) {
      _log('Screenshot observer stop failed: $error', isError: true);
    }
    _log('Screenshot observer stopped.');
  }

  Future<void> _cancelScreenshotSubscriptions() async {
    await _screenshotEventsSubscription?.cancel();
    _screenshotEventsSubscription = null;
    await _screenshotDiagnosticsSubscription?.cancel();
    _screenshotDiagnosticsSubscription = null;
  }

  /// Logs the "event emitted" stage (§7) — the observer spec's scope ends at a
  /// screenshot delivered to this isolate — then hands the event to the push
  /// pipeline (#28).
  void _onScreenshotEvent(ScreenshotEvent event) {
    _log(
      'Screenshot emitted: id=${event.id} name=${event.displayName} '
      'size=${event.sizeBytes} detectedAt=${event.detectedAtEpochMillis}',
    );
    pushController?.handleEvent(event);
  }

  /// Brings the auto-send watcher in line with the setting and the READ_LOGS
  /// grant (D2/D-Degrade). Idempotent and safe on every [_sync]: a watcher
  /// already in the right state is untouched, so reconnects don't churn the
  /// logcat subprocess. The watcher stays inert (never spawned) unless both the
  /// setting is on and the grant is present.
  Future<void> _reconcileClipboardAutoSendWatcher(AppSettings settings) async {
    final watcher = clipboardAutoSendWatcher;
    if (watcher == null) return;

    if (!settings.enableClipboardAutoSend) {
      await _stopClipboardAutoSendWatcher();
      _autoSendInertLogged = false;
      return;
    }

    final granted = await watcher.hasReadLogsPermission();
    if (granted) {
      await _startClipboardAutoSendWatcher(watcher);
    } else {
      // Setting on but READ_LOGS absent: the watcher would be inert (logcat
      // sees no system tag), so don't spawn it. The advanced screen's grant
      // line is the single source of truth; log once, not on every reconnect.
      await _stopClipboardAutoSendWatcher();
      if (!_autoSendInertLogged) {
        _autoSendInertLogged = true;
        _log(
          'Clipboard auto-send enabled but READ_LOGS not granted; watcher '
          'inert. Run the adb setup in Advanced.',
        );
      }
    }
  }

  Future<void> _startClipboardAutoSendWatcher(
    ClipboardAutoSendWatcher watcher,
  ) async {
    _autoSendInertLogged = false;
    if (_autoSendWatching) return;
    _autoSendTextsSubscription = watcher.texts.listen(_onAutoReadText);
    _autoSendDiagnosticsSubscription = watcher.diagnostics.listen(_log);
    try {
      await watcher.start();
      _autoSendWatching = true;
    } on PlatformException catch (error) {
      await _cancelAutoSendSubscriptions();
      _log(
        'Clipboard auto-send watcher refused to start: ${error.code} '
        '(${error.message}).',
        isError: true,
      );
    }
  }

  Future<void> _stopClipboardAutoSendWatcher() async {
    await _cancelAutoSendSubscriptions();
    if (!_autoSendWatching) return;
    _autoSendWatching = false;
    try {
      await clipboardAutoSendWatcher?.stop();
    } catch (error) {
      _log('Clipboard auto-send watcher stop failed: $error', isError: true);
    }
  }

  Future<void> _cancelAutoSendSubscriptions() async {
    await _autoSendTextsSubscription?.cancel();
    _autoSendTextsSubscription = null;
    await _autoSendDiagnosticsSubscription?.cancel();
    _autoSendDiagnosticsSubscription = null;
  }

  /// An auto-read arrived. Drop it if it echoes the last received-payload write
  /// (D4), otherwise publish it through the one existing send path (D3).
  Future<void> _onAutoReadText(String text) async {
    if (text == _lastReceivedClipboardWrite) {
      // Consume the record so a deliberate re-copy of the same text still sends.
      _lastReceivedClipboardWrite = null;
      _log(
        'Clipboard auto-send: echo guard dropped a received-payload re-read.',
      );
      return;
    }
    final publish = autoSendPublish;
    if (publish == null) return;
    _log('Clipboard auto-send: forwarding ${text.length} chars to publish.');
    final result = await publish(SharePayload.text(text));
    _log(
      'Clipboard auto-send publish: ${result.message}',
      isError: !result.published,
    );
  }

  void _setScreenshotPaused(bool paused, {ScreenshotAccessLevel? access}) {
    if (_screenshotPaused == paused) return;
    _screenshotPaused = paused;
    emit({'kind': 'screenshotAccess', 'paused': paused, 'level': access?.name});
    if (paused) {
      _log(
        'Auto-send screenshots paused — allow all photos '
        '(access: ${access?.name ?? 'unknown'}).',
        isError: true,
      );
    }
  }

  void _scheduleReconnect() {
    if (_stopped || _reconnectTimer != null) return;
    final delay = reconnectBackoff.isEmpty
        ? Duration.zero
        : reconnectBackoff[_reconnectAttempt.clamp(
            0,
            reconnectBackoff.length - 1,
          )];
    _reconnectAttempt += 1;
    _log(
      'Connection lost; retrying in ${delay.inSeconds}s '
      '(attempt $_reconnectAttempt).',
    );
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (_stopped) return;
      unawaited(_sync());
    });
  }

  Future<void> _teardown() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    pushController?.detachSession();
    await _statusSubscription?.cancel();
    _statusSubscription = null;
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    await _healthSubscription?.cancel();
    _healthSubscription = null;
    await _receiveController?.dispose();
    _receiveController = null;
    await _connection?.close();
    _connection = null;
  }

  void _log(String message, {bool isError = false}) {
    emit({'kind': 'log', 'message': message, 'error': isError});
  }

  /// Decoded size of the base64 ciphertext — the bytes that crossed the wire.
  int _payloadSizeBytes(String base64Payload) {
    final padding = base64Payload.endsWith('==')
        ? 2
        : base64Payload.endsWith('=')
        ? 1
        : 0;
    return (base64Payload.length ~/ 4) * 3 - padding;
  }

  Future<void> _publishStatus(ConnectionStatus status) async {
    _lastStatus = status;
    emit({'kind': 'status', 'status': status.name});
    final (title, text) = _notificationCopy(status);
    await updateNotification(title, text);
  }

  (String, String) _notificationCopy(ConnectionStatus status) {
    final title = switch (status) {
      ConnectionStatus.connected => 'Vidyut connected',
      ConnectionStatus.searching => 'Vidyut connecting',
      ConnectionStatus.offline => 'Vidyut offline',
    };
    if (_screenshotPaused) {
      // The paused state is persistent and recovery-worthy (§5), so it
      // overrides the connection copy (#33 decision 3).
      final base = switch (status) {
        ConnectionStatus.connected => 'Synced with laptop.',
        ConnectionStatus.searching => 'Looking for the laptop relay...',
        ConnectionStatus.offline => 'Relay unreachable.',
      };
      return (title, '$base Auto-push paused — allow all photos.');
    }
    // Connection state only, zero-tap copy (#33 decision 3): no per-event
    // text updates.
    final text = switch (status) {
      ConnectionStatus.connected =>
        'Synced with laptop — clipboard and screenshots.',
      ConnectionStatus.searching => 'Looking for the laptop relay...',
      ConnectionStatus.offline =>
        'Relay unreachable. Open the app to reconnect.',
    };
    return (title, text);
  }
}
