import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/receive/received_image_repository.dart';
import 'package:vidyut/src/receive/received_text_repository.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('vidyut_repo_test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  ReceivedImageRepository repository(ReceivedPayloadStorage storage) {
    return ReceivedImageRepository(
      storage,
      directoryProvider: () async => tempDir,
    );
  }

  test('saves image bytes to a file and loads them back', () async {
    final storage = MemoryReceivedPayloadStorage();
    final repo = repository(storage);

    final saved = await repo.saveLatest([1, 2, 3, 4], 'image/png');

    expect(saved.path, endsWith('latest.png'));
    expect(saved.mime, 'image/png');
    expect(await File(saved.path).readAsBytes(), [1, 2, 3, 4]);

    final loaded = await repo.loadLatest();
    expect(loaded?.path, saved.path);
    expect(loaded?.mime, 'image/png');
  });

  test('latest write wins and stale files are removed', () async {
    final storage = MemoryReceivedPayloadStorage();
    final repo = repository(storage);

    await repo.saveLatest([1, 2, 3], 'image/png');
    final second = await repo.saveLatest([9, 9], 'image/jpeg');

    expect(second.path, endsWith('latest.jpg'));
    final files = await tempDir.list().toList();
    expect(files.map((entry) => entry.path), [second.path]);

    final loaded = await repo.loadLatest();
    expect(loaded?.mime, 'image/jpeg');
    expect(await File(loaded!.path).readAsBytes(), [9, 9]);
  });

  test('returns null when nothing has been received', () async {
    final repo = repository(MemoryReceivedPayloadStorage());
    expect(await repo.loadLatest(), isNull);
  });

  test('returns null when the stored file has disappeared', () async {
    final storage = MemoryReceivedPayloadStorage();
    final repo = repository(storage);
    final saved = await repo.saveLatest([1], 'image/png');
    await File(saved.path).delete();

    expect(await repo.loadLatest(), isNull);
  });

  test('falls back to a generic extension for unknown mime types', () async {
    final repo = repository(MemoryReceivedPayloadStorage());
    final saved = await repo.saveLatest([1], 'image/x-obscure');
    expect(saved.path, endsWith('latest.img'));
  });

  test('encodes payload IDs before using them as filenames', () async {
    final repo = repository(MemoryReceivedPayloadStorage());

    final saved = await repo.save([1, 2], 'image/png', id: 'nonce/with/slash');

    expect(saved.path, isNot(contains('/nonce/')));
    expect(await repo.loadById('nonce/with/slash'), isNotNull);
    expect(await File(saved.path).readAsBytes(), [1, 2]);
  });
}
