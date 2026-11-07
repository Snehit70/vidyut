import 'dart:async';

import 'package:flutter/services.dart';

/// What the native mirror reports while it runs (ADR 0030).
sealed class ScreenMirrorState {
  const ScreenMirrorState();

  static ScreenMirrorState? fromEvent(Object? event) {
    if (event is! Map) return null;
    return switch (event['state']) {
      'streaming' => ScreenMirrorStreaming(
        width: event['width'] as int? ?? 0,
        height: event['height'] as int? ?? 0,
      ),
      'stopped' => ScreenMirrorStopped(event['reason'] as String? ?? 'stopped'),
      'failed' => ScreenMirrorFailed(
        event['message'] as String? ?? 'The screen mirror stopped.',
      ),
      _ => null,
    };
  }
}

class ScreenMirrorStreaming extends ScreenMirrorState {
  const ScreenMirrorStreaming({required this.width, required this.height});

  final int width;
  final int height;
}

/// The mirror ended. [reason] is `phone_stopped`, `window_closed`,
/// `capture_revoked`, `connection_lost` or another close reason the laptop
/// sent.
class ScreenMirrorStopped extends ScreenMirrorState {
  const ScreenMirrorStopped(this.reason);

  final String reason;
}

class ScreenMirrorFailed extends ScreenMirrorState {
  const ScreenMirrorFailed(this.message);

  final String message;
}

/// Size the phone will encode its screen at.
class ScreenMirrorSize {
  const ScreenMirrorSize(this.width, this.height);

  final int width;
  final int height;
}

/// Captures the phone screen and streams sealed H.264 to the laptop.
class ScreenMirror {
  ScreenMirror({MethodChannel? methods, EventChannel? events})
    : _methods = methods ?? const MethodChannel('vidyut/screen_mirror'),
      _events = events ?? const EventChannel('vidyut/screen_mirror/state');

  final MethodChannel _methods;
  final EventChannel _events;

  Stream<ScreenMirrorState>? _states;

  /// State changes from the native service.
  Stream<ScreenMirrorState> get states => _states ??= _events
      .receiveBroadcastStream()
      .map(ScreenMirrorState.fromEvent)
      .where((state) => state != null)
      .cast<ScreenMirrorState>();

  /// Shows Android's capture prompt. True when the user allowed it.
  Future<bool> requestConsent() async {
    return await _methods.invokeMethod<bool>('requestConsent') ?? false;
  }

  Future<ScreenMirrorSize> encoderSize() async {
    final size = await _methods.invokeMapMethod<String, Object?>('encoderSize');
    return ScreenMirrorSize(
      size?['width'] as int? ?? 0,
      size?['height'] as int? ?? 0,
    );
  }

  Future<bool> isRunning() async {
    return await _methods.invokeMethod<bool>('isRunning') ?? false;
  }

  /// Starts the stream to [url] sealed with [key] (base64, 32 bytes). Needs
  /// a fresh [requestConsent] grant.
  Future<void> start({required String url, required String key}) {
    return _methods.invokeMethod<void>('start', {'url': url, 'key': key});
  }

  Future<void> stop() => _methods.invokeMethod<void>('stop');
}
