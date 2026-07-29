import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/foreground/send_clipboard_screen.dart';
import 'package:vidyut/src/share/share_payload.dart';
import 'package:vidyut/src/share/share_publisher.dart';

void main() {
  testWidgets('publishes clipboard text immediately when opened', (
    tester,
  ) async {
    final publisher = FakeSharePublisher();

    await tester.pumpWidget(
      MaterialApp(
        home: SendClipboardScreen(
          clipboardReader: FakeClipboardReader('hello from phone'),
          publisher: publisher,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Clipboard sent to laptop.'), findsOneWidget);
    expect(publisher.published.single.text, 'hello from phone');
  });

  testWidgets('shows an empty clipboard message after retries', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SendClipboardScreen(
          clipboardReader: FakeClipboardReader(null),
          publisher: FakeSharePublisher(),
          readRetryDelay: Duration.zero,
        ),
      ),
    );
    // One pump per zero-delay retry timer, plus slack for the state change.
    for (var i = 0; i < 12; i += 1) {
      await tester.pump(Duration.zero);
    }

    expect(find.text('Clipboard is empty.'), findsOneWidget);
  });

  testWidgets('retries the read until window focus grants it', (tester) async {
    final publisher = FakeSharePublisher();

    await tester.pumpWidget(
      MaterialApp(
        home: SendClipboardScreen(
          clipboardReader: SequenceClipboardReader([null, null, 'late text']),
          publisher: publisher,
          readRetryDelay: Duration.zero,
        ),
      ),
    );
    for (var i = 0; i < 6; i += 1) {
      await tester.pump(Duration.zero);
    }

    expect(find.text('Clipboard sent to laptop.'), findsOneWidget);
    expect(publisher.published.single.text, 'late text');
  });

  testWidgets('shows a share failure message', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SendClipboardScreen(
          clipboardReader: const FakeClipboardReader('text'),
          publisher: FakeSharePublisher(
            result: const SharePublishResult.failed('Relay is offline.'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Relay is offline.'), findsOneWidget);
  });
}

class FakeSharePublisher implements ClipboardSharePublisher {
  FakeSharePublisher({this.result = const SharePublishResult.published()});

  final SharePublishResult result;
  final List<SharePayload> published = [];

  @override
  Future<SharePublishResult> publish(SharePayload payload) async {
    published.add(payload);
    return result;
  }
}

class FakeClipboardReader implements ClipboardReader {
  const FakeClipboardReader(this.value);

  final String? value;

  @override
  Future<String?> readText() async => value;
}

class SequenceClipboardReader implements ClipboardReader {
  SequenceClipboardReader(this.values);

  final List<String?> values;
  var _reads = 0;

  @override
  Future<String?> readText() async {
    final value = values[_reads.clamp(0, values.length - 1)];
    _reads += 1;
    return value;
  }
}
