import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../activity/last_activity.dart';
import '../activity/last_activity_repository.dart';
import '../debug/debug_log.dart';
import '../design/widgets.dart';
import '../share/share_payload.dart';
import '../share/share_publisher.dart';
import '../shared/format.dart';

abstract interface class ClipboardReader {
  Future<String?> readText();
}

abstract interface class ClipboardSharePublisher {
  Future<SharePublishResult> publish(SharePayload payload);
}

class FlutterClipboardReader implements ClipboardReader {
  const FlutterClipboardReader();

  @override
  Future<String?> readText() async {
    return (await Clipboard.getData('text/plain'))?.text;
  }
}

class SharePublisherAdapter implements ClipboardSharePublisher {
  const SharePublisherAdapter(this._publisher);

  final SharePublisher _publisher;

  @override
  Future<SharePublishResult> publish(SharePayload payload) {
    return _publisher.publish(payload);
  }
}

class SendClipboardScreen extends StatefulWidget {
  const SendClipboardScreen({
    super.key,
    required this.clipboardReader,
    required this.publisher,
    this.debugLog,
    this.lastActivityRepository,
    this.counterpart,
    this.readRetryAttempts = 10,
    this.readRetryDelay = const Duration(milliseconds: 250),
  });

  final ClipboardReader clipboardReader;
  final ClipboardSharePublisher publisher;
  final DebugLog? debugLog;
  final LastActivityRepository? lastActivityRepository;
  final String? counterpart;
  final int readRetryAttempts;
  final Duration readRetryDelay;

  @override
  State<SendClipboardScreen> createState() => _SendClipboardScreenState();
}

class _SendClipboardScreenState extends State<SendClipboardScreen> {
  String _message = 'Reading clipboard...';
  bool _working = true;
  bool _sent = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sendClipboard();
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final statusIcon = _working
        ? const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          )
        : Icon(
            _sent ? Icons.check : Icons.priority_high,
            size: 32,
            color: _sent ? scheme.primary : scheme.error,
          );
    return Scaffold(
      appBar: AppBar(title: const Text('Send clipboard')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  color: _working
                      ? scheme.secondaryContainer
                      : _sent
                      ? scheme.primaryContainer
                      : scheme.errorContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Center(child: statusIcon),
              ),
              const SizedBox(height: 24),
              Text(
                _message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ).entrance(0),
              if (!_working && !_sent) ...[
                const SizedBox(height: 24),
                PressableScale(
                  child: OutlinedButton.icon(
                    onPressed: _retry,
                    icon: const Icon(Icons.refresh, size: 20),
                    label: const Text('Try again'),
                  ),
                ).entrance(1),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _retry() {
    setState(() {
      _working = true;
      _sent = false;
      _message = 'Reading clipboard...';
    });
    unawaited(_sendClipboard());
  }

  Future<void> _sendClipboard() async {
    // Android 10+ only allows clipboard reads once this window has input
    // focus, which lands a few frames after a cold launch from the
    // notification button — so an early empty read may just mean "not
    // focused yet". Retry briefly before concluding the clipboard is empty.
    var text = await widget.clipboardReader.readText();
    for (
      var attempt = 0;
      (text == null || text.trim().isEmpty) &&
          attempt < widget.readRetryAttempts;
      attempt += 1
    ) {
      await Future<void>.delayed(widget.readRetryDelay);
      if (!mounted) return;
      text = await widget.clipboardReader.readText();
    }
    if (!mounted) return;
    if (text == null || text.trim().isEmpty) {
      setState(() {
        _working = false;
        _message = 'Clipboard is empty.';
      });
      return;
    }

    final result = await widget.publisher.publish(SharePayload.text(text));
    widget.debugLog?.add(
      'send',
      result.published
          ? 'Clipboard text (${text.length} chars) sent to laptop.'
          : result.message,
      isError: !result.published,
    );
    if (result.published) {
      await widget.lastActivityRepository?.record(
        LastActivity(
          direction: ActivityDirection.sent,
          summary: 'text (${text.length} chars)',
          counterpart: activityCounterpart(widget.counterpart),
          timestamp: DateTime.now(),
          excerpt: text,
        ),
      );
    }
    if (!mounted) return;
    setState(() {
      _working = false;
      _sent = result.published;
      _message = result.published
          ? 'Clipboard sent to laptop.'
          : result.message;
    });
  }
}
