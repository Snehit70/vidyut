import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:vidyut_clipboard/vidyut_clipboard.dart';

import '../shared/payload_crypto.dart';
import '../shared/wire.dart';
import 'received_image_repository.dart';
import 'received_text_repository.dart';

/// Notification payload marking "tap to copy the latest received text".
const copyLatestTextNotificationPayload = 'vidyut.copy-latest-text';

/// Notification payload marking "tap to copy the latest received image".
const copyLatestImageNotificationPayload = 'vidyut.copy-latest-image';

/// Notification payload marking "open the clipboard permission settings"
/// (the one-time MIUI hint).
const openClipboardPermissionNotificationPayload =
    'vidyut.open-clipboard-permission';

/// How a direct clipboard write resolved (zero-tap-receive D3).
enum ClipboardWriteOutcome {
  /// The channel returned success; on AOSP this is trustworthy.
  confirmed,

  /// `SecurityException` from `setPrimaryClip` — MIUI's privacy layer.
  blocked,

  /// `MissingPluginException` — the plugin didn't register in this isolate.
  /// A regression, not device policy.
  wiringBug,

  /// Any other write error (missing file, provider rejection, ...).
  failed,
}

abstract interface class AndroidClipboard {
  Future<void> writeText(String text);
}

/// Writes text through the `vidyut/clipboard` channel. The plugin hosts
/// the channel from application context, so this works in the UI isolate and
/// the foreground-service isolate alike (unlike `Clipboard.setData`, whose
/// Android handler only attaches to activity-backed engines).
class FlutterAndroidClipboard implements AndroidClipboard {
  const FlutterAndroidClipboard([this._clipboard = const VidyutClipboard()]);

  final VidyutClipboard _clipboard;

  @override
  Future<void> writeText(String text) => _clipboard.writeText(text);
}

abstract interface class AndroidImageClipboard {
  Future<void> writeImage(ReceivedImage image);
}

/// Writes an image to the Android clipboard through the `vidyut/clipboard`
/// channel: the Kotlin side wraps the file in a FileProvider content URI and
/// sets it as ClipData. Hosted by the vidyut_clipboard plugin, so it works
/// from both engines.
class ChannelAndroidImageClipboard implements AndroidImageClipboard {
  const ChannelAndroidImageClipboard([
    this._clipboard = const VidyutClipboard(),
  ]);

  final VidyutClipboard _clipboard;

  @override
  Future<void> writeImage(ReceivedImage image) {
    return _clipboard.writeImage(path: image.path, mime: image.mime);
  }
}

abstract interface class PayloadNotifier {
  Future<void> showTextReceipt(String preview, {required bool copied});

  Future<void> showImageReceipt(String mime, {required bool copied});

  /// Normal-importance, one-time hint that MIUI blocked the write; its tap
  /// opens the clipboard permission settings.
  Future<void> showMiuiClipboardHint();
}

class LocalPayloadNotifier implements PayloadNotifier {
  LocalPayloadNotifier({
    FlutterLocalNotificationsPlugin? plugin,
    this.showSuccessReceipts = true,
    this.requestPermissionOnInit = true,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  /// The `showReceiveNotifications` setting. Suppresses success receipts
  /// only — failure receipts always show, because when the direct write
  /// fails the notification tap is the only delivery path.
  final bool showSuccessReceipts;

  /// The foreground service isolate has no activity to anchor a permission
  /// prompt; the UI requests notification permission before starting it.
  final bool requestPermissionOnInit;
  bool _initialized = false;

  /// Fixed ids: receipts replace in place so a burst of payloads doesn't
  /// stack (only the latest payload is copyable from the repository anyway);
  /// the MIUI hint gets its own slot.
  static const receiptNotificationId = 4201;
  static const miuiHintNotificationId = 4202;

  /// Quiet receipts (zero-tap-receive D4): no sound, no heads-up. Channel
  /// importance is fixed at creation, so the quiet behavior needs this new
  /// channel; the old alerting `vidyut_payloads` channel is deleted on
  /// upgrade in [_ensureInitialized].
  static const _receiptDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      'vidyut_receipts',
      'Vidyut receipts',
      channelDescription:
          'Quiet receipts for payloads received from the laptop',
      importance: Importance.low,
      priority: Priority.low,
    ),
  );

  static const _hintDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      'vidyut_hints',
      'Vidyut permission hints',
      channelDescription:
          'Action-needed hints, e.g. clipboard access blocked by the device',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    ),
  );

  @override
  Future<void> showTextReceipt(String preview, {required bool copied}) {
    return _showReceipt(
      copied: copied,
      description: preview.isEmpty ? 'Text' : preview,
      payload: copyLatestTextNotificationPayload,
    );
  }

  @override
  Future<void> showImageReceipt(String mime, {required bool copied}) {
    return _showReceipt(
      copied: copied,
      description: 'Image ($mime)',
      payload: copyLatestImageNotificationPayload,
    );
  }

  @override
  Future<void> showMiuiClipboardHint() async {
    await _ensureInitialized();
    await _plugin.show(
      id: miuiHintNotificationId,
      title: 'Allow clipboard access for Vidyut',
      body:
          'The device blocked a background clipboard write. Tap to open '
          'settings and enable the Clipboard permission.',
      payload: openClipboardPermissionNotificationPayload,
      notificationDetails: _hintDetails,
    );
  }

  /// D4 carve-out: the receive-notifications toggle suppresses success
  /// receipts only; a failure receipt is the payload's delivery path.
  @visibleForTesting
  static bool shouldShowReceipt({
    required bool copied,
    required bool showSuccessReceipts,
  }) {
    return !copied || showSuccessReceipts;
  }

  Future<void> _showReceipt({
    required bool copied,
    required String description,
    required String payload,
  }) async {
    if (!shouldShowReceipt(
      copied: copied,
      showSuccessReceipts: showSuccessReceipts,
    )) {
      return;
    }
    await _ensureInitialized();
    await _plugin.show(
      id: receiptNotificationId,
      title: copied ? 'Copied from laptop' : 'Received from laptop',
      body: copied ? description : 'Tap to copy — $description',
      payload: payload,
      notificationDetails: _receiptDetails,
    );
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    // Pre-receipt installs created this high-importance channel; Android
    // won't lower a channel's importance, so it has to go.
    await android?.deleteNotificationChannel(channelId: 'vidyut_payloads');
    if (requestPermissionOnInit) {
      await android?.requestNotificationsPermission();
    }
    _initialized = true;
  }
}

class PayloadReceiveResult {
  const PayloadReceiveResult._(this.received, this.message);

  const PayloadReceiveResult.received(String message) : this._(true, message);

  const PayloadReceiveResult.failed(String message) : this._(false, message);

  final bool received;
  final String message;
}

typedef PayloadReceiverLog = void Function(String message, {bool isError});

class PayloadReceiver {
  const PayloadReceiver({
    required this.crypto,
    required this.clipboard,
    required this.imageClipboard,
    required this.notifier,
    required this.receivedTextRepository,
    required this.receivedImageRepository,
    this.hasShownMiuiClipboardHint,
    this.markMiuiClipboardHintShown,
    this.onClipboardBlocked,
    this.log,
  });

  final PayloadCrypto crypto;
  final AndroidClipboard clipboard;
  final AndroidImageClipboard imageClipboard;
  final PayloadNotifier notifier;
  final ReceivedTextRepository receivedTextRepository;
  final ReceivedImageRepository receivedImageRepository;

  /// Persisted "hint already shown" flag; when these are left null the
  /// one-time MIUI hint is disabled.
  final Future<bool> Function()? hasShownMiuiClipboardHint;
  final Future<void> Function()? markMiuiClipboardHintShown;

  /// Fired on every blocked clipboard write (not just the first): the
  /// onboarding checklist un-checks its self-reported MIUI Clipboard item so
  /// it re-flags ⚠ (onboarding spec D5 feedback loop).
  final Future<void> Function()? onClipboardBlocked;

  /// Debug-log sink; the wiring-bug outcome logs loudly through this.
  final PayloadReceiverLog? log;

  Future<PayloadReceiveResult> receive({
    required PayloadFrame frame,
    required String pairingSecret,
  }) async {
    try {
      final plaintext = await crypto.decrypt(
        frame: frame,
        pairingSecret: pairingSecret,
      );
      // Repository first (source of truth): whatever happens to the write,
      // the notification tap can always re-copy from the repository.
      switch (frame.type) {
        case PayloadType.text:
          final text = utf8.decode(plaintext);
          await receivedTextRepository.saveLatest(text, id: frame.nonce);
          final outcome = await _tryWrite(() => clipboard.writeText(text));
          await notifier.showTextReceipt(
            _preview(text),
            copied: outcome == ClipboardWriteOutcome.confirmed,
          );
          await _maybeShowMiuiHint(outcome);
          return PayloadReceiveResult.received(_message('Text', outcome));
        case PayloadType.image:
          final image = await receivedImageRepository.save(
            plaintext,
            frame.mime,
            id: frame.nonce,
          );
          final outcome = await _tryWrite(
            () => imageClipboard.writeImage(image),
          );
          await notifier.showImageReceipt(
            frame.mime,
            copied: outcome == ClipboardWriteOutcome.confirmed,
          );
          await _maybeShowMiuiHint(outcome);
          return PayloadReceiveResult.received(_message('Image', outcome));
      }
    } on Object catch (error) {
      return PayloadReceiveResult.failed('Receive failed: $error');
    }
  }

  /// Resolves the direct write to the D3 taxonomy. MIUI's silent no-op is
  /// not detectable from the background (read-back needs focus), so "no
  /// exception" counts as confirmed.
  Future<ClipboardWriteOutcome> _tryWrite(Future<void> Function() write) async {
    try {
      await write();
      return ClipboardWriteOutcome.confirmed;
    } on MissingPluginException {
      log?.call(
        'Clipboard channel missing in this isolate (MissingPluginException): '
        'the vidyut_clipboard plugin failed to register. This is a wiring '
        'regression, not device policy.',
        isError: true,
      );
      return ClipboardWriteOutcome.wiringBug;
    } on PlatformException catch (error) {
      if (error.code == VidyutClipboard.blockedErrorCode) {
        log?.call('Clipboard write blocked by the device: ${error.message}');
        return ClipboardWriteOutcome.blocked;
      }
      log?.call('Clipboard write failed: $error', isError: true);
      return ClipboardWriteOutcome.failed;
    } on Object catch (error) {
      log?.call('Clipboard write failed: $error', isError: true);
      return ClipboardWriteOutcome.failed;
    }
  }

  Future<void> _maybeShowMiuiHint(ClipboardWriteOutcome outcome) async {
    if (outcome != ClipboardWriteOutcome.blocked) return;
    await onClipboardBlocked?.call();
    final hasShown = hasShownMiuiClipboardHint;
    final markShown = markMiuiClipboardHintShown;
    if (hasShown == null || markShown == null) return;
    if (await hasShown()) return;
    await markShown();
    await notifier.showMiuiClipboardHint();
  }

  String _message(String what, ClipboardWriteOutcome outcome) {
    return switch (outcome) {
      ClipboardWriteOutcome.confirmed => '$what copied from laptop.',
      ClipboardWriteOutcome.blocked =>
        '$what received — clipboard blocked by the device. '
            'Tap the notification to copy.',
      ClipboardWriteOutcome.wiringBug || ClipboardWriteOutcome.failed =>
        '$what received. Tap the notification to copy.',
    };
  }

  String _preview(String text) {
    final compact = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.length <= 80) return compact;
    return '${compact.substring(0, 77)}...';
  }
}

class PayloadReceiveController {
  PayloadReceiveController({
    required this.frames,
    required this.pairingSecret,
    required this.receiver,
    this.onResult,
  });

  final Stream<PayloadFrame> frames;
  final String pairingSecret;
  final PayloadReceiver receiver;
  final void Function(PayloadFrame frame, PayloadReceiveResult result)?
  onResult;
  StreamSubscription<PayloadFrame>? _subscription;

  void start() {
    _subscription = frames.listen((frame) {
      unawaited(_receive(frame));
    });
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
  }

  Future<void> _receive(PayloadFrame frame) async {
    final result = await receiver.receive(
      frame: frame,
      pairingSecret: pairingSecret,
    );
    onResult?.call(frame, result);
  }
}
