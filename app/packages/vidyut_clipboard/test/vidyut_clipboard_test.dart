import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut_clipboard/vidyut_clipboard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];
  Object? Function(MethodCall call)? nativeHandler;

  setUp(() {
    calls.clear();
    nativeHandler = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(VidyutClipboard.channel, (call) async {
          calls.add(call);
          return nativeHandler?.call(call);
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(VidyutClipboard.channel, null);
  });

  test('writeText invokes the channel with the text argument', () async {
    await const VidyutClipboard().writeText('hello');

    expect(calls.single.method, 'writeText');
    expect(calls.single.arguments, {'text': 'hello'});
  });

  test('writeText passes formatting when given html', () async {
    await const VidyutClipboard().writeText('bold', html: '<b>bold</b>');

    expect(calls.single.arguments, {'text': 'bold', 'html': '<b>bold</b>'});
  });

  test('writeImage invokes the channel with path and mime', () async {
    await const VidyutClipboard().writeImage(
      path: '/data/img.png',
      mime: 'image/png',
    );

    expect(calls.single.method, 'writeImage');
    expect(calls.single.arguments, {'path': '/data/img.png', 'mime': 'image/png'});
  });

  test('openClipboardPermissionSettings invokes the channel', () async {
    await const VidyutClipboard().openClipboardPermissionSettings();

    expect(calls.single.method, 'openClipboardPermissionSettings');
  });

  test('a blocked write surfaces as a PlatformException with the blocked code',
      () async {
    nativeHandler = (call) => throw PlatformException(
      code: VidyutClipboard.blockedErrorCode,
      message: 'denied',
    );

    await expectLater(
      const VidyutClipboard().writeText('hello'),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          VidyutClipboard.blockedErrorCode,
        ),
      ),
    );
  });

  test('screen-on events surface each native broadcast', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          ScreenOnEvents.defaultChannel,
          MockStreamHandler.inline(
            onListen: (arguments, events) {
              events.success(null);
              events.success(null);
            },
          ),
        );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(ScreenOnEvents.defaultChannel, null);
    });

    expect(await ScreenOnEvents().events.take(2).length, 2);
  });
}
