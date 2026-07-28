import 'dart:async';

import 'package:flutter/services.dart';

/// Dart face of the opt-in READ_LOGS auto-text watcher (read-logs-auto-text D2).
///
/// The native side registers a process-wide watcher from application context via
/// a [FlutterPlugin], so the headless foreground-service engine drives a single
/// logcat subprocess regardless of which engine attaches. The service isolate is
/// the intended consumer.
abstract interface class ClipboardAutoSendWatcher {
  /// Opens the native transparent clipboard reader and returns the current
  /// text. This follows an explicit notification tap, so READ_LOGS is not
  /// required.
  Future<String?> readText();

  /// Whether `READ_LOGS` is granted (`checkSelfPermission`). Grantable only via
  /// the one-time adb block (D6); re-checked on each return-to-foreground since
  /// the grant is external. Safe from any isolate — touches no watcher state.
  Future<bool> hasReadLogsPermission();

  /// Registers the trip-wire clip-change listener and, on Q+, spawns the
  /// ClipboardService-denial logcat subprocess. Idempotent.
  Future<void> start();

  /// Destroys the subprocess, joins the reader thread, and unregisters the
  /// listener. A no-op if not watching.
  Future<void> stop();

  /// Auto-read clipboard text, forwarded from the invisible read activity (Q+)
  /// or the direct listener (legacy). The service isolate applies the echo guard
  /// and publishes (D3/D4).
  Stream<String> get texts;

  /// The watcher's per-stage debug lines (spec "Instrumentation"): started with
  /// the chosen filter + API level, denial matched (redacted), read N chars.
  /// Fed into the in-app debug log so the fragile pieces stay diagnosable.
  Stream<String> get diagnostics;
}

/// [ClipboardAutoSendWatcher] backed by the `vidyut/clipboard_autosend`
/// method channel and the `vidyut/clipboard_autosend_events` event channel.
class ChannelClipboardAutoSendWatcher implements ClipboardAutoSendWatcher {
  ChannelClipboardAutoSendWatcher({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  }) : _methodChannel = methodChannel ?? defaultMethodChannel,
       _eventChannel = eventChannel ?? defaultEventChannel;

  static const defaultMethodChannel = MethodChannel(
    'vidyut/clipboard_autosend',
  );
  static const defaultEventChannel = EventChannel(
    'vidyut/clipboard_autosend_events',
  );

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;

  @override
  Future<String?> readText() => _methodChannel.invokeMethod<String>('readText');

  /// One native subscription, split into [texts] and [diagnostics] below. The
  /// native side tags every emission with `type`: `"text"` carries a read
  /// payload, `"log"` carries a debug line.
  late final Stream<Map<Object?, Object?>> _raw = _eventChannel
      .receiveBroadcastStream()
      .cast<Map<Object?, Object?>>();

  @override
  Future<bool> hasReadLogsPermission() async {
    return await _methodChannel.invokeMethod<bool>('hasReadLogsPermission') ??
        false;
  }

  @override
  Future<void> start() => _methodChannel.invokeMethod<void>('start');

  @override
  Future<void> stop() => _methodChannel.invokeMethod<void>('stop');

  @override
  Stream<String> get texts => _raw
      .where((event) => event['type'] == 'text')
      .map((event) => event['text'] as String? ?? '')
      .where((text) => text.isNotEmpty);

  @override
  Stream<String> get diagnostics => _raw
      .where((event) => event['type'] == 'log')
      .map((event) => event['message'] as String? ?? '');
}
