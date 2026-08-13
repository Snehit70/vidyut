import 'dart:async';

import 'package:clipboard_autosend/clipboard_autosend.dart';
import 'package:cryptography/cryptography.dart' show Cryptography;
import 'package:cryptography_flutter/cryptography_flutter.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:vidyut_clipboard/vidyut_clipboard.dart';
import 'package:vidyut_files/vidyut_files.dart';
import 'package:screenshot_observer/screenshot_observer.dart';

import '../activity/last_activity.dart';
import '../activity/last_activity_repository.dart';
import '../pairing/pairing_repository.dart';
import '../push/screenshot_push_controller.dart';
import '../receive/payload_receiver.dart';
import '../receive/received_image_repository.dart';
import '../receive/received_text_repository.dart';
import '../settings/app_settings.dart';
import '../settings/app_settings_repository.dart';
import '../share/share_publisher.dart';
import '../shared/payload_crypto.dart';
import '../shared/relay_connection.dart';
import '../transfer/phone_transfer_receiver.dart';
import '../transfer/transfer_history.dart';
import 'foreground_service_client.dart';
import 'service_relay_controller.dart';

const sendClipboardRoute = '/send-clipboard';
const foregroundNotificationId = 17321;
const foregroundNotificationChannelId = 'vidyut_foreground';

String _transferActivitySummary(int fileCount) {
  final noun = fileCount == 1 ? 'file' : 'files';
  return '$fileCount $noun';
}

@pragma('vm:entry-point')
void startForegroundCallback() {
  // Native AES-GCM/PBKDF2 in the headless engine too, set explicitly rather
  // than trusting the Dart plugin registrant to have run in this entrypoint;
  // the screenshot_encrypted.encryptMs log verifies the native path holds
  // (push spec §4).
  Cryptography.instance = FlutterCryptography.defaultInstance;
  FlutterForegroundTask.setTaskHandler(VidyutForegroundTaskHandler());
}

class VidyutForegroundTaskHandler extends TaskHandler {
  VidyutForegroundTaskHandler({ServiceRelayController? controller})
    : _controller = controller ?? _relayController();

  final ServiceRelayController _controller;

  static ServiceRelayController _relayController() {
    final pairingRepository = PairingRepository(const SecurePairingStorage());
    final settingsRepository = AppSettingsRepository(
      const SecureAppSettingsStorage(),
    );
    final screenshotWatcher = ChannelScreenshotWatcher();
    final autoSendWatcher = ChannelClipboardAutoSendWatcher();
    // One crypto for push and receive so the memoized PBKDF2 key is shared.
    final crypto = PayloadCrypto();
    final activityRepository = LastActivityRepository(
      SecureLastActivityStorage(),
    );
    // The auto-send path reuses the manual sender verbatim (D3): auto and manual
    // text sends are indistinguishable on the wire, with one failure taxonomy.
    final sharePublisher = SharePublisher(
      pairingRepository: pairingRepository,
      relaySessionFactory: (pairing) => RelayConnection(
        pairing: pairing,
        deviceId: 'phone',
        transport: WebSocketRelayTransport.connect(pairing),
      ),
      crypto: crypto,
      fileReader: const LocalShareFileReader(),
    );
    // `late` so the receive-clipboard wrapper can call back into the controller's
    // echo-guard record (D4) — the closure runs long after construction.
    late final ServiceRelayController controller;
    controller = ServiceRelayController(
      loadPairing: pairingRepository.load,
      loadSettings: settingsRepository.load,
      screenshotWatcher: screenshotWatcher,
      pushController: ScreenshotPushController(
        readImage: screenshotWatcher.readImage,
        crypto: crypto,
        emit: FlutterForegroundTask.sendDataToMain,
        onActivity: (activity) => controller.recordActivity(activity),
      ),
      screenOnEvents: ScreenOnEvents().events,
      clipboardAutoSendWatcher: autoSendWatcher,
      autoSendPublish: sharePublisher.publish,
      transferReceiverFactory: (_) => PhoneTransferReceiver(
        history: TransferHistoryRepository(
          SharedPreferencesTransferHistoryStorage(),
        ),
        publisher: const AndroidReceivedFilePublisher(),
        notifier: LocalTransferNotifier(),
        onEvent: (message, {isError = false}) {
          FlutterForegroundTask.sendDataToMain({
            'kind': 'transfer',
            'message': message,
            'error': isError,
          });
        },
        onBatchResult: (batch) => controller.recordActivity(
          LastActivity(
            direction: batch.direction == PhoneTransferDirection.received
                ? ActivityDirection.received
                : ActivityDirection.sent,
            summary: _transferActivitySummary(batch.files.length),
            counterpart: 'laptop',
            timestamp: DateTime.fromMillisecondsSinceEpoch(batch.updatedAtMs),
            payloadId: batch.transferId,
            outcome:
                batch.files.any(
                  (file) => file.status == PhoneTransferStatus.failed,
                )
                ? ActivityOutcome.failed
                : ActivityOutcome.completed,
          ),
        ),
        receiveEnabled: () async =>
            (await settingsRepository.load()).receiveFiles,
        maximumFileBytes: () async =>
            (await settingsRepository.load()).maxTransferFileBytes,
        alertsEnabled: () async =>
            (await settingsRepository.load()).fileTransferAlerts,
        networkAllowed: () async {
          final settings = await settingsRepository.load();
          return settings.allowMeteredFileTransfers ||
              !await const VidyutFiles().isNetworkMetered();
        },
        destinationAvailable: const VidyutFiles().isDestinationAvailable,
      ),
      connectionFactory: (pairing) => RelayConnection(
        pairing: pairing,
        deviceId: 'phone',
        transport: WebSocketRelayTransport.connect(pairing),
      ),
      receiverFactory: (settings) => PayloadReceiver(
        crypto: crypto,
        // Every received-text write is recorded so the auto-send echo guard can
        // drop the read it provokes (D4).
        clipboard: _EchoGuardClipboard(
          const FlutterAndroidClipboard(),
          controller.recordReceivedClipboardText,
        ),
        imageClipboard: const ChannelAndroidImageClipboard(),
        receivedTextRepository: ReceivedTextRepository(
          SecureReceivedPayloadStorage(),
        ),
        receivedImageRepository: ReceivedImageRepository(
          const SecureReceivedPayloadStorage(),
        ),
        notifier: LocalPayloadNotifier(
          showSuccessReceipts: settings.showReceiveNotifications,
          requestPermissionOnInit: false,
        ),
        hasShownMiuiClipboardHint: settingsRepository.miuiClipboardHintShown,
        markMiuiClipboardHintShown:
            settingsRepository.markMiuiClipboardHintShown,
        // D5 feedback loop: a blocked write proves the MIUI clipboard toggle
        // is off, so the self-reported checklist item re-flags ⚠.
        onClipboardBlocked: () => settingsRepository.saveMiuiSetupFlag(
          MiuiSetupFlag.clipboard,
          false,
        ),
        log: (message, {isError = false}) =>
            FlutterForegroundTask.sendDataToMain({
              'kind': 'log',
              'message': message,
              'error': isError,
            }),
      ),
      emit: FlutterForegroundTask.sendDataToMain,
      activityRecorder: activityRepository.record,
      updateNotification: (title, text) async {
        await FlutterForegroundTask.updateService(
          notificationTitle: title,
          notificationText: text,
          notificationButtons: const [],
          notificationInitialRoute: '/',
        );
        try {
          // Best effort: updateService already refreshed the required
          // foreground notification; this only attaches the direct action.
          await autoSendWatcher.updateNotification(
            notificationId: foregroundNotificationId,
            channelId: foregroundNotificationChannelId,
            title: title,
            text: text,
          );
        } catch (error) {
          FlutterForegroundTask.sendDataToMain({
            'kind': 'log',
            'message': 'Notification action refresh failed: $error',
            'error': true,
          });
        }
      },
    );
    return controller;
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) {
    return _controller.start();
  }

  @override
  void onReceiveData(Object data) {
    unawaited(_controller.handleTaskData(data));
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) {
    return _controller.stop();
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp('/');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}
}

/// Wraps the real clipboard so every received-text write is recorded for the
/// auto-send echo guard (read-logs-auto-text D4). The record is taken only after
/// the underlying write completes without throwing — a blocked/failed write left
/// the clipboard unchanged, so it can't provoke an echoing auto-read.
class _EchoGuardClipboard implements AndroidClipboard {
  const _EchoGuardClipboard(this._inner, this._record);

  final AndroidClipboard _inner;
  final void Function(String text) _record;

  @override
  Future<void> writeText(String text) async {
    await _inner.writeText(text);
    _record(text);
  }
}

class VidyutForegroundServiceClient implements ForegroundServiceClient {
  bool _initialized = false;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: foregroundNotificationChannelId,
        channelName: 'Vidyut clipboard',
        channelDescription:
            'Persistent clipboard sync notification for Vidyut.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    _initialized = true;
  }

  @override
  Future<bool> get isRunning => FlutterForegroundTask.isRunningService;

  @override
  Future<void> requestPermissions() async {
    final permission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (permission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
  }

  @override
  Future<void> start() async {
    await _requireSuccess(
      await FlutterForegroundTask.startService(
        serviceId: foregroundNotificationId,
        serviceTypes: [ForegroundServiceTypes.dataSync],
        notificationTitle: 'Vidyut connecting',
        notificationText: 'Looking for the laptop relay...',
        notificationButtons: const [],
        notificationInitialRoute: '/',
        callback: startForegroundCallback,
      ),
    );
  }

  @override
  Future<void> stop() async {
    await _requireSuccess(await FlutterForegroundTask.stopService());
  }

  @override
  Future<void> update() async {
    await sendToTask(serviceSyncCommand);
  }

  @override
  void addTaskDataCallback(TaskDataCallback callback) {
    FlutterForegroundTask.addTaskDataCallback(callback);
  }

  @override
  void removeTaskDataCallback(TaskDataCallback callback) {
    FlutterForegroundTask.removeTaskDataCallback(callback);
  }

  @override
  Future<void> sendToTask(Object data) async {
    if (await FlutterForegroundTask.isRunningService) {
      FlutterForegroundTask.sendDataToTask(data);
    }
  }

  Future<void> _requireSuccess(ServiceRequestResult result) async {
    if (result case ServiceRequestFailure(:final error)) {
      throw StateError('Foreground service request failed: $error');
    }
  }
}
