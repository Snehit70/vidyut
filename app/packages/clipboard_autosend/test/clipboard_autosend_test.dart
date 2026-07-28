import 'package:clipboard_autosend/clipboard_autosend.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('vidyut/clipboard_autosend');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
  });

  test('hasReadLogsPermission forwards the native bool', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          calls.add(call.method);
          return true;
        });

    final watcher = ChannelClipboardAutoSendWatcher();

    expect(await watcher.hasReadLogsPermission(), isTrue);
    expect(calls, ['hasReadLogsPermission']);
  });

  test(
    'hasReadLogsPermission defaults to false when native returns null',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async => null);

      final watcher = ChannelClipboardAutoSendWatcher();

      expect(await watcher.hasReadLogsPermission(), isFalse);
    },
  );

  test('updateNotification forwards content to the native builder', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          calls.add(call);
          return null;
        });

    final watcher = ChannelClipboardAutoSendWatcher();
    await watcher.updateNotification(
      notificationId: 17321,
      channelId: 'vidyut_foreground',
      title: 'Vidyut connected',
      text: 'Synced with laptop.',
    );

    expect(calls.single.method, 'updateNotification');
    expect(calls.single.arguments, {
      'notificationId': 17321,
      'channelId': 'vidyut_foreground',
      'title': 'Vidyut connected',
      'text': 'Synced with laptop.',
    });
  });

  test('start and stop invoke their channel methods', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          calls.add(call.method);
          return null;
        });

    final watcher = ChannelClipboardAutoSendWatcher();
    await watcher.start();
    await watcher.stop();

    expect(calls, ['start', 'stop']);
  });

  test('event stream splits text, manual results, and diagnostics', () async {
    final watcher = ChannelClipboardAutoSendWatcher(
      eventChannel: const EventChannel('test/clipboard_autosend_events'),
    );

    // The split logic is what matters; exercise it directly by pushing through
    // the raw mapping the channel would deliver.
    final texts = <String>[];
    final manualResults = <ManualClipboardReadResult>[];
    final logs = <String>[];
    final textSub = watcher.texts.listen(texts.add);
    final manualSub = watcher.manualResults.listen(manualResults.add);
    final logSub = watcher.diagnostics.listen(logs.add);
    addTearDown(textSub.cancel);
    addTearDown(manualSub.cancel);
    addTearDown(logSub.cancel);

    await _emit('test/clipboard_autosend_events', {
      'type': 'log',
      'message': 'started',
    });
    await _emit('test/clipboard_autosend_events', {
      'type': 'text',
      'text': 'copied words',
    });
    await _emit('test/clipboard_autosend_events', {'type': 'text', 'text': ''});
    await _emit('test/clipboard_autosend_events', {
      'type': 'manualResult',
      'requestId': 7,
      'status': 'text',
      'text': 'manual words',
    });
    await _emit('test/clipboard_autosend_events', {
      'type': 'manualResult',
      'requestId': 8,
      'status': 'futureStatus',
    });
    await Future<void>.delayed(Duration.zero);

    expect(texts, ['copied words']);
    expect(manualResults, hasLength(2));
    expect(manualResults.first.requestId, 7);
    expect(manualResults.first.status, ManualClipboardReadStatus.text);
    expect(manualResults.first.text, 'manual words');
    expect(manualResults.last.requestId, 8);
    expect(manualResults.last.status, ManualClipboardReadStatus.unreadable);
    expect(logs, ['started']);
  });
}

Future<void> _emit(String channelName, Map<String, Object?> event) async {
  const codec = StandardMethodCodec();
  final message = codec.encodeSuccessEnvelope(event);
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(channelName, message, (_) {});
}
