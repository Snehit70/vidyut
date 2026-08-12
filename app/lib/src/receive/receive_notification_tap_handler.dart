import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:vidyut_clipboard/vidyut_clipboard.dart';

import '../activity/last_activity.dart';
import 'payload_receiver.dart';
import 'received_image_repository.dart';
import 'received_text_repository.dart';

abstract interface class ClipboardPermissionSettingsOpener {
  Future<void> open();
}

/// Opens the MIUI permission editor (or the app-details fallback) through
/// the vidyut_clipboard plugin.
class ChannelClipboardPermissionSettingsOpener
    implements ClipboardPermissionSettingsOpener {
  const ChannelClipboardPermissionSettingsOpener([
    this._clipboard = const VidyutClipboard(),
  ]);

  final VidyutClipboard _clipboard;

  @override
  Future<void> open() => _clipboard.openClipboardPermissionSettings();
}

/// UI-isolate handler for taps on incoming-payload notifications.
///
/// The foreground service isolate shows the notification and stores the
/// payload; tapping it brings the app to the foreground, where the clipboard
/// write is always permitted. Handles both warm taps (app running) and
/// cold launches from a notification.
class ReceiveNotificationTapHandler {
  ReceiveNotificationTapHandler({
    required this.repository,
    required this.imageRepository,
    required this.clipboard,
    required this.imageClipboard,
    this.permissionSettingsOpener =
        const ChannelClipboardPermissionSettingsOpener(),
    FlutterLocalNotificationsPlugin? plugin,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final ReceivedTextRepository repository;
  final ReceivedImageRepository imageRepository;
  final AndroidClipboard clipboard;
  final AndroidImageClipboard imageClipboard;
  final ClipboardPermissionSettingsOpener permissionSettingsOpener;
  final FlutterLocalNotificationsPlugin _plugin;

  /// Invoked with a status message after a tap is handled.
  void Function(String message)? onCopied;

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (response) {
        unawaited(handleResponse(response));
      },
    );
    final launch = await _plugin.getNotificationAppLaunchDetails();
    final response = launch?.notificationResponse;
    if ((launch?.didNotificationLaunchApp ?? false) && response != null) {
      await handleResponse(response);
    }
  }

  Future<void> handleResponse(NotificationResponse response) async {
    switch (response.payload) {
      case copyLatestTextNotificationPayload:
        await _copyLatestText();
      case copyLatestImageNotificationPayload:
        await _copyLatestImage();
      case openClipboardPermissionNotificationPayload:
        await _openClipboardPermissionSettings();
    }
  }

  Future<void> copyLatest({required bool image}) {
    return image ? _copyLatestImage() : _copyLatestText();
  }

  Future<void> copyActivity(LastActivity activity) async {
    final id = activity.payloadId;
    if (id == null) {
      onCopied?.call('This older item is no longer available.');
      return;
    }
    if (activity.summary.startsWith('image')) {
      final image = await imageRepository.loadById(id);
      if (image == null) {
        onCopied?.call('This image is no longer available.');
        return;
      }
      try {
        await imageClipboard.writeImage(image);
        onCopied?.call('Image copied from laptop.');
      } on Object catch (error) {
        onCopied?.call('Image clipboard write failed: $error');
      }
      return;
    }
    final text = await repository.loadById(id);
    if (text == null) {
      onCopied?.call('This text is no longer available.');
      return;
    }
    try {
      await clipboard.writeText(text);
      onCopied?.call('Text copied from laptop.');
    } on Object catch (error) {
      onCopied?.call('Text clipboard write failed: $error');
    }
  }

  Future<void> _openClipboardPermissionSettings() async {
    try {
      await permissionSettingsOpener.open();
    } on Object catch (error) {
      onCopied?.call('Could not open clipboard settings: $error');
    }
  }

  Future<void> _copyLatestText() async {
    final text = await repository.loadLatest();
    if (text == null) {
      onCopied?.call('No received text to copy.');
      return;
    }
    await clipboard.writeText(text);
    onCopied?.call('Text copied from laptop.');
  }

  Future<void> _copyLatestImage() async {
    final image = await imageRepository.loadLatest();
    if (image == null) {
      onCopied?.call('No received image to copy.');
      return;
    }
    try {
      await imageClipboard.writeImage(image);
      onCopied?.call('Image copied from laptop.');
    } on Object catch (error) {
      onCopied?.call('Image clipboard write failed: $error');
    }
  }
}
