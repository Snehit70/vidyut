import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/receive/payload_receiver.dart';
import 'package:vidyut/src/receive/received_image_repository.dart';
import 'package:vidyut/src/receive/received_text_repository.dart';
import 'package:vidyut/src/shared/payload_crypto.dart';
import 'package:vidyut/src/shared/wire.dart';
import 'package:vidyut_clipboard/vidyut_clipboard.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('vidyut_receive_test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  ReceivedImageRepository imageRepository(ReceivedPayloadStorage storage) {
    return ReceivedImageRepository(
      storage,
      directoryProvider: () async => tempDir,
    );
  }

  Future<PayloadFrame> textFrame(String text, {int ts = 1800000400000}) {
    return PayloadCrypto().encrypt(
      metadata: PayloadMetadata(
        type: PayloadType.text,
        mime: 'text/plain',
        origin: 'laptop',
        ts: ts,
      ),
      plaintext: text.codeUnits,
      pairingSecret: 'pairing-secret',
    );
  }

  Future<PayloadFrame> imageFrame(
    List<int> bytes,
    String mime, {
    int ts = 1800000400001,
  }) {
    return PayloadCrypto().encrypt(
      metadata: PayloadMetadata(
        type: PayloadType.image,
        mime: mime,
        origin: 'laptop',
        ts: ts,
      ),
      plaintext: bytes,
      pairingSecret: 'pairing-secret',
    );
  }

  test(
    'decrypts incoming text, stores it, and writes the Android clipboard',
    () async {
      final clipboard = FakeAndroidClipboard();
      final notifier = FakePayloadNotifier();
      final storage = MemoryReceivedPayloadStorage();
      final receiver = PayloadReceiver(
        crypto: PayloadCrypto(),
        clipboard: clipboard,
        imageClipboard: FakeAndroidImageClipboard(),
        notifier: notifier,
        receivedTextRepository: ReceivedTextRepository(storage),
        receivedImageRepository: imageRepository(storage),
      );

      final result = await receiver.receive(
        frame: await textFrame('hello phone'),
        pairingSecret: 'pairing-secret',
      );

      expect(result.received, isTrue);
      expect(result.message, 'Text copied from laptop.');
      expect(clipboard.text, 'hello phone');
      expect(await ReceivedTextRepository(storage).loadLatest(), 'hello phone');
      expect(notifier.textReceipts.single, (
        preview: 'hello phone',
        copied: true,
      ));
    },
  );

  test(
    'still receives when the background clipboard write fails outright',
    () async {
      final notifier = FakePayloadNotifier();
      final storage = MemoryReceivedPayloadStorage();
      final logs = <({String message, bool isError})>[];
      final receiver = PayloadReceiver(
        crypto: PayloadCrypto(),
        clipboard: ThrowingAndroidClipboard(StateError('write refused')),
        imageClipboard: FakeAndroidImageClipboard(),
        notifier: notifier,
        receivedTextRepository: ReceivedTextRepository(storage),
        receivedImageRepository: imageRepository(storage),
        log: (message, {isError = false}) =>
            logs.add((message: message, isError: isError)),
      );

      final result = await receiver.receive(
        frame: await textFrame('blocked write', ts: 1800000400004),
        pairingSecret: 'pairing-secret',
      );

      expect(result.received, isTrue);
      expect(result.message, 'Text received. Tap the notification to copy.');
      expect(
        await ReceivedTextRepository(storage).loadLatest(),
        'blocked write',
      );
      expect(notifier.textReceipts.single, (
        preview: 'blocked write',
        copied: false,
      ));
      expect(notifier.miuiHintCount, 0);
      expect(logs.single.isError, isTrue);
    },
  );

  test(
    'a SecurityException-blocked write shows the MIUI hint exactly once',
    () async {
      final notifier = FakePayloadNotifier();
      final storage = MemoryReceivedPayloadStorage();
      var hintShown = false;
      var blockedCallbacks = 0;
      final receiver = PayloadReceiver(
        crypto: PayloadCrypto(),
        clipboard: ThrowingAndroidClipboard(
          PlatformException(
            code: VidyutClipboard.blockedErrorCode,
            message: 'MIUI denied it',
          ),
        ),
        imageClipboard: FakeAndroidImageClipboard(),
        notifier: notifier,
        receivedTextRepository: ReceivedTextRepository(storage),
        receivedImageRepository: imageRepository(storage),
        hasShownMiuiClipboardHint: () async => hintShown,
        markMiuiClipboardHintShown: () async => hintShown = true,
        onClipboardBlocked: () async => blockedCallbacks += 1,
      );

      final first = await receiver.receive(
        frame: await textFrame('first', ts: 1800000400010),
        pairingSecret: 'pairing-secret',
      );
      final second = await receiver.receive(
        frame: await textFrame('second', ts: 1800000400011),
        pairingSecret: 'pairing-secret',
      );

      expect(first.received, isTrue);
      expect(
        first.message,
        'Text received — clipboard blocked by the device. '
        'Tap the notification to copy.',
      );
      expect(second.received, isTrue);
      expect(notifier.textReceipts, hasLength(2));
      expect(notifier.textReceipts.every((receipt) => !receipt.copied), isTrue);
      expect(notifier.miuiHintCount, 1);
      expect(hintShown, isTrue);
      // The un-check hook fires on every block, not just the first (D5).
      expect(blockedCallbacks, 2);
    },
  );

  test(
    'a MissingPluginException is logged loudly as a wiring bug, no MIUI hint',
    () async {
      final notifier = FakePayloadNotifier();
      final storage = MemoryReceivedPayloadStorage();
      final logs = <({String message, bool isError})>[];
      final receiver = PayloadReceiver(
        crypto: PayloadCrypto(),
        clipboard: ThrowingAndroidClipboard(
          MissingPluginException('no handler'),
        ),
        imageClipboard: FakeAndroidImageClipboard(),
        notifier: notifier,
        receivedTextRepository: ReceivedTextRepository(storage),
        receivedImageRepository: imageRepository(storage),
        hasShownMiuiClipboardHint: () async => false,
        markMiuiClipboardHintShown: () async {},
        log: (message, {isError = false}) =>
            logs.add((message: message, isError: isError)),
      );

      final result = await receiver.receive(
        frame: await textFrame('lost write', ts: 1800000400012),
        pairingSecret: 'pairing-secret',
      );

      expect(result.received, isTrue);
      expect(result.message, 'Text received. Tap the notification to copy.');
      expect(notifier.miuiHintCount, 0);
      expect(logs.single.isError, isTrue);
      expect(logs.single.message, contains('MissingPluginException'));
      expect(logs.single.message, contains('regression'));
    },
  );

  test(
    'stores an incoming image and writes it to the clipboard when allowed',
    () async {
      final imageClipboard = FakeAndroidImageClipboard();
      final notifier = FakePayloadNotifier();
      final storage = MemoryReceivedPayloadStorage();
      final receiver = PayloadReceiver(
        crypto: PayloadCrypto(),
        clipboard: FakeAndroidClipboard(),
        imageClipboard: imageClipboard,
        notifier: notifier,
        receivedTextRepository: ReceivedTextRepository(storage),
        receivedImageRepository: imageRepository(storage),
      );

      final result = await receiver.receive(
        frame: await imageFrame([1, 2, 3, 4], 'image/png'),
        pairingSecret: 'pairing-secret',
      );

      expect(result.received, isTrue);
      expect(result.message, 'Image copied from laptop.');
      expect(notifier.imageReceipts.single, (mime: 'image/png', copied: true));
      final written = imageClipboard.images.single;
      expect(written.mime, 'image/png');
      expect(await File(written.path).readAsBytes(), [1, 2, 3, 4]);
      expect(result.imagePath, written.path);
      final stored = await imageRepository(storage).loadLatest();
      expect(stored?.path, written.path);
    },
  );

  test(
    'a blocked image write shows a failure receipt and the one-time hint',
    () async {
      final notifier = FakePayloadNotifier();
      final storage = MemoryReceivedPayloadStorage();
      var hintShown = false;
      final receiver = PayloadReceiver(
        crypto: PayloadCrypto(),
        clipboard: FakeAndroidClipboard(),
        imageClipboard: ThrowingAndroidImageClipboard(
          PlatformException(code: VidyutClipboard.blockedErrorCode),
        ),
        notifier: notifier,
        receivedTextRepository: ReceivedTextRepository(storage),
        receivedImageRepository: imageRepository(storage),
        hasShownMiuiClipboardHint: () async => hintShown,
        markMiuiClipboardHintShown: () async => hintShown = true,
      );

      final result = await receiver.receive(
        frame: await imageFrame([9, 8, 7], 'image/jpeg', ts: 1800000400005),
        pairingSecret: 'pairing-secret',
      );

      expect(result.received, isTrue);
      expect(
        result.message,
        'Image received — clipboard blocked by the device. '
        'Tap the notification to copy.',
      );
      expect(notifier.imageReceipts.single, (
        mime: 'image/jpeg',
        copied: false,
      ));
      expect(notifier.miuiHintCount, 1);
      final stored = await imageRepository(storage).loadLatest();
      expect(stored?.mime, 'image/jpeg');
      expect(await File(stored!.path).readAsBytes(), [9, 8, 7]);
    },
  );

  test('reports a clear receive failure for a wrong pairing secret', () async {
    final storage = MemoryReceivedPayloadStorage();
    final receiver = PayloadReceiver(
      crypto: PayloadCrypto(),
      clipboard: FakeAndroidClipboard(),
      imageClipboard: FakeAndroidImageClipboard(),
      notifier: FakePayloadNotifier(),
      receivedTextRepository: ReceivedTextRepository(storage),
      receivedImageRepository: imageRepository(storage),
    );
    final frame = await textFrame('secret text', ts: 1800000400002);

    final result = await receiver.receive(
      frame: frame,
      pairingSecret: 'wrong-secret',
    );

    expect(result.received, isFalse);
    expect(result.message, startsWith('Receive failed:'));
  });

  test('the receive-notifications toggle suppresses success receipts only', () {
    expect(
      LocalPayloadNotifier.shouldShowReceipt(
        copied: true,
        showSuccessReceipts: false,
      ),
      isFalse,
    );
    expect(
      LocalPayloadNotifier.shouldShowReceipt(
        copied: false,
        showSuccessReceipts: false,
      ),
      isTrue,
    );
    expect(
      LocalPayloadNotifier.shouldShowReceipt(
        copied: true,
        showSuccessReceipts: true,
      ),
      isTrue,
    );
  });

  test('receive controller handles frames from the relay stream', () async {
    final frames = StreamController<PayloadFrame>();
    final results = <PayloadReceiveResult>[];
    final resultCompleter = Completer<void>();
    final clipboard = FakeAndroidClipboard();
    final storage = MemoryReceivedPayloadStorage();
    final controller = PayloadReceiveController(
      frames: frames.stream,
      pairingSecret: 'pairing-secret',
      receiver: PayloadReceiver(
        crypto: PayloadCrypto(),
        clipboard: clipboard,
        imageClipboard: FakeAndroidImageClipboard(),
        notifier: FakePayloadNotifier(),
        receivedTextRepository: ReceivedTextRepository(storage),
        receivedImageRepository: imageRepository(storage),
      ),
      onResult: (frame, result) {
        results.add(result);
        resultCompleter.complete();
      },
    );
    final frame = await textFrame('from stream', ts: 1800000400003);

    controller.start();
    frames.add(frame);
    await resultCompleter.future;

    expect(clipboard.text, 'from stream');
    expect(results.single.received, isTrue);
    await controller.dispose();
    await frames.close();
  });
}

class FakeAndroidClipboard implements AndroidClipboard {
  String? text;

  @override
  Future<void> writeText(String text) async {
    this.text = text;
  }
}

class ThrowingAndroidClipboard implements AndroidClipboard {
  ThrowingAndroidClipboard(this.error);

  final Object error;

  @override
  Future<void> writeText(String text) async {
    throw error;
  }
}

class FakeAndroidImageClipboard implements AndroidImageClipboard {
  final images = <ReceivedImage>[];

  @override
  Future<void> writeImage(ReceivedImage image) async {
    images.add(image);
  }
}

class ThrowingAndroidImageClipboard implements AndroidImageClipboard {
  ThrowingAndroidImageClipboard(this.error);

  final Object error;

  @override
  Future<void> writeImage(ReceivedImage image) async {
    throw error;
  }
}

class FakePayloadNotifier implements PayloadNotifier {
  final textReceipts = <({String preview, bool copied})>[];
  final imageReceipts = <({String mime, bool copied})>[];
  int miuiHintCount = 0;

  @override
  Future<void> showTextReceipt(String preview, {required bool copied}) async {
    textReceipts.add((preview: preview, copied: copied));
  }

  @override
  Future<void> showImageReceipt(String mime, {required bool copied}) async {
    imageReceipts.add((mime: mime, copied: copied));
  }

  @override
  Future<void> showMiuiClipboardHint() async {
    miuiHintCount += 1;
  }
}
