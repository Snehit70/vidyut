import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/receive/payload_receiver.dart';
import 'package:vidyut/src/receive/receive_notification_tap_handler.dart';
import 'package:vidyut/src/receive/received_image_repository.dart';
import 'package:vidyut/src/receive/received_text_repository.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('vidyut_tap_test');
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

  ReceiveNotificationTapHandler handler(
    ReceivedPayloadStorage storage, {
    required _FakeClipboard clipboard,
    required _FakeImageClipboard imageClipboard,
  }) {
    return ReceiveNotificationTapHandler(
      repository: ReceivedTextRepository(storage),
      imageRepository: imageRepository(storage),
      clipboard: clipboard,
      imageClipboard: imageClipboard,
    );
  }

  test(
    'copies the latest received text when the notification is tapped',
    () async {
      final storage = MemoryReceivedPayloadStorage();
      await ReceivedTextRepository(storage).saveLatest('laptop text');
      final clipboard = _FakeClipboard();
      final messages = <String>[];
      final tapHandler = handler(
        storage,
        clipboard: clipboard,
        imageClipboard: _FakeImageClipboard(),
      )..onCopied = messages.add;

      await tapHandler.handleResponse(
        const NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotification,
          payload: copyLatestTextNotificationPayload,
        ),
      );

      expect(clipboard.text, 'laptop text');
      expect(messages.single, 'Text copied from laptop.');
    },
  );

  test(
    'copies the latest received image when the notification is tapped',
    () async {
      final storage = MemoryReceivedPayloadStorage();
      await imageRepository(storage).saveLatest([1, 2, 3], 'image/png');
      final imageClipboard = _FakeImageClipboard();
      final messages = <String>[];
      final tapHandler = handler(
        storage,
        clipboard: _FakeClipboard(),
        imageClipboard: imageClipboard,
      )..onCopied = messages.add;

      await tapHandler.handleResponse(
        const NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotification,
          payload: copyLatestImageNotificationPayload,
        ),
      );

      final written = imageClipboard.images.single;
      expect(written.mime, 'image/png');
      expect(await File(written.path).readAsBytes(), [1, 2, 3]);
      expect(messages.single, 'Image copied from laptop.');
    },
  );

  test('ignores notification taps without a copy payload', () async {
    final storage = MemoryReceivedPayloadStorage();
    await ReceivedTextRepository(storage).saveLatest('laptop text');
    final clipboard = _FakeClipboard();
    final imageClipboard = _FakeImageClipboard();
    final tapHandler = handler(
      storage,
      clipboard: clipboard,
      imageClipboard: imageClipboard,
    );

    await tapHandler.handleResponse(
      const NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotification,
      ),
    );

    expect(clipboard.text, isNull);
    expect(imageClipboard.images, isEmpty);
  });

  test('reports when no received text is stored yet', () async {
    final clipboard = _FakeClipboard();
    final messages = <String>[];
    final tapHandler = handler(
      MemoryReceivedPayloadStorage(),
      clipboard: clipboard,
      imageClipboard: _FakeImageClipboard(),
    )..onCopied = messages.add;

    await tapHandler.handleResponse(
      const NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotification,
        payload: copyLatestTextNotificationPayload,
      ),
    );

    expect(clipboard.text, isNull);
    expect(messages.single, 'No received text to copy.');
  });

  test('reports when no received image is stored yet', () async {
    final imageClipboard = _FakeImageClipboard();
    final messages = <String>[];
    final tapHandler = handler(
      MemoryReceivedPayloadStorage(),
      clipboard: _FakeClipboard(),
      imageClipboard: imageClipboard,
    )..onCopied = messages.add;

    await tapHandler.handleResponse(
      const NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotification,
        payload: copyLatestImageNotificationPayload,
      ),
    );

    expect(imageClipboard.images, isEmpty);
    expect(messages.single, 'No received image to copy.');
  });

  test(
    'opens the clipboard permission settings from the MIUI hint tap',
    () async {
      final opener = _FakePermissionSettingsOpener();
      final tapHandler = ReceiveNotificationTapHandler(
        repository: ReceivedTextRepository(MemoryReceivedPayloadStorage()),
        imageRepository: imageRepository(MemoryReceivedPayloadStorage()),
        clipboard: _FakeClipboard(),
        imageClipboard: _FakeImageClipboard(),
        permissionSettingsOpener: opener,
      );

      await tapHandler.handleResponse(
        const NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotification,
          payload: openClipboardPermissionNotificationPayload,
        ),
      );

      expect(opener.openCount, 1);
    },
  );

  test(
    'surfaces a failure to open the clipboard permission settings',
    () async {
      final messages = <String>[];
      final tapHandler = ReceiveNotificationTapHandler(
        repository: ReceivedTextRepository(MemoryReceivedPayloadStorage()),
        imageRepository: imageRepository(MemoryReceivedPayloadStorage()),
        clipboard: _FakeClipboard(),
        imageClipboard: _FakeImageClipboard(),
        permissionSettingsOpener: _ThrowingPermissionSettingsOpener(),
      )..onCopied = messages.add;

      await tapHandler.handleResponse(
        const NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotification,
          payload: openClipboardPermissionNotificationPayload,
        ),
      );

      expect(messages.single, startsWith('Could not open clipboard settings:'));
    },
  );

  test('surfaces image clipboard write failures instead of throwing', () async {
    final storage = MemoryReceivedPayloadStorage();
    await imageRepository(storage).saveLatest([1], 'image/png');
    final messages = <String>[];
    final tapHandler = ReceiveNotificationTapHandler(
      repository: ReceivedTextRepository(storage),
      imageRepository: imageRepository(storage),
      clipboard: _FakeClipboard(),
      imageClipboard: _ThrowingImageClipboard(),
    )..onCopied = messages.add;

    await tapHandler.handleResponse(
      const NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotification,
        payload: copyLatestImageNotificationPayload,
      ),
    );

    expect(messages.single, startsWith('Image clipboard write failed:'));
  });
}

class _FakeClipboard implements AndroidClipboard {
  String? text;

  @override
  Future<void> writeText(String text) async {
    this.text = text;
  }
}

class _FakeImageClipboard implements AndroidImageClipboard {
  final images = <ReceivedImage>[];

  @override
  Future<void> writeImage(ReceivedImage image) async {
    images.add(image);
  }
}

class _ThrowingImageClipboard implements AndroidImageClipboard {
  @override
  Future<void> writeImage(ReceivedImage image) async {
    throw StateError('FileProvider rejected the path.');
  }
}

class _FakePermissionSettingsOpener
    implements ClipboardPermissionSettingsOpener {
  int openCount = 0;

  @override
  Future<void> open() async {
    openCount += 1;
  }
}

class _ThrowingPermissionSettingsOpener
    implements ClipboardPermissionSettingsOpener {
  @override
  Future<void> open() async {
    throw StateError('No settings activity resolved.');
  }
}
