import 'package:flutter/services.dart';

/// Dart face of the `vidyut/clipboard` MethodChannel.
///
/// The native side registers from application context via a [FlutterPlugin],
/// so these calls work in every isolate — the UI isolate and the headless
/// foreground-service isolate alike.
class VidyutClipboard {
  const VidyutClipboard();

  static const MethodChannel channel = MethodChannel('vidyut/clipboard');

  /// [PlatformException.code] when the OS rejected the write with a
  /// SecurityException — MIUI's privacy layer blocking background clipboard
  /// access, not a wiring bug.
  static const blockedErrorCode = 'clipboard-blocked';

  /// With [html], the clip carries formatting for apps that paste it.
  Future<void> writeText(String text, {String? html}) {
    return channel.invokeMethod<void>('writeText', {
      'text': text,
      if (html != null) 'html': html,
    });
  }

  Future<void> writeImage({required String path, required String mime}) {
    return channel.invokeMethod<void>('writeImage', {
      'path': path,
      'mime': mime,
    });
  }

  /// Opens the MIUI permission editor for this app, falling back to the
  /// standard app-details settings screen where that intent doesn't resolve.
  Future<void> openClipboardPermissionSettings() {
    return channel.invokeMethod<void>('openClipboardPermissionSettings');
  }

  /// `Build.MANUFACTURER`, lowercased. `xiaomi` covers Xiaomi/Redmi/Poco
  /// (onboarding spec D4) — sufficient for the target devices, no `ro.miui.*`
  /// sysprop reading.
  Future<String> manufacturer() async {
    final value = await channel.invokeMethod<String>('manufacturer');
    return (value ?? '').toLowerCase();
  }

  /// Whether the Xiaomi setup step and checklist section apply (D4).
  Future<bool> isMiui() async => await manufacturer() == 'xiaomi';

  /// Opens the MIUI autostart manager, falling back to app-details where the
  /// community-sourced intents don't resolve (D5).
  Future<void> openAutostartSettings() {
    return channel.invokeMethod<void>('openAutostartSettings');
  }

  /// Opens the MIUI per-app battery-saver page, with the same fallback (D5).
  Future<void> openBatterySaverSettings() {
    return channel.invokeMethod<void>('openBatterySaverSettings');
  }
}

/// Screen-on broadcasts from the native `ACTION_SCREEN_ON` receiver
/// (keepalive spec D5). Subscribing registers the receiver; cancelling the
/// last subscription unregisters it. Works in every isolate like the
/// clipboard channel; the foreground-service isolate is the intended consumer.
class ScreenOnEvents {
  ScreenOnEvents({EventChannel? channel})
    : _channel = channel ?? defaultChannel;

  static const defaultChannel = EventChannel('vidyut/screen_on');

  final EventChannel _channel;

  Stream<void> get events =>
      _channel.receiveBroadcastStream().map((_) {});
}

/// One notification another app posted, as the native listener saw it. Only
/// notifications with a digit in the title or text are delivered.
class PostedNotification {
  const PostedNotification({
    required this.packageName,
    required this.title,
    required this.text,
  });

  final String packageName;
  final String title;
  final String text;
}

/// Notifications from the native `CodeNotificationListener`, which Android
/// runs only after the user grants notification access. Nothing is delivered
/// until something listens; the foreground-service isolate is the consumer.
class PostedNotifications {
  PostedNotifications({EventChannel? channel, MethodChannel? methods})
    : _channel = channel ?? defaultChannel,
      _methods = methods ?? VidyutClipboard.channel;

  static const defaultChannel = EventChannel('vidyut/posted_notifications');

  final EventChannel _channel;
  final MethodChannel _methods;

  Stream<PostedNotification> get notifications =>
      _channel.receiveBroadcastStream().map((event) {
        final map = (event as Map<Object?, Object?>).cast<String, Object?>();
        return PostedNotification(
          packageName: map['packageName'] as String? ?? '',
          title: map['title'] as String? ?? '',
          text: map['text'] as String? ?? '',
        );
      });

  Future<bool> hasAccess() async =>
      await _methods.invokeMethod<bool>('hasNotificationAccess') ?? false;

  /// Opens Vidyut's notification-access switch, or the list of apps with
  /// access where Android has no per-app page.
  Future<void> openAccessSettings() {
    return _methods.invokeMethod<void>('openNotificationAccessSettings');
  }
}
