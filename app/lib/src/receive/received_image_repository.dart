import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'received_text_repository.dart';

/// The newest image payload received from the laptop, persisted as a file in
/// app-private storage so the UI isolate can hand it to the platform
/// clipboard channel.
class ReceivedImage {
  const ReceivedImage({required this.path, required this.mime});

  final String path;
  final String mime;
}

typedef ReceiveDirectoryProvider = Future<Directory> Function();

/// Must stay under the app files dir subtree served by the manifest's
/// FileProvider (`vidyut_received/`), or the clipboard content URI
/// cannot be built.
Future<Directory> _defaultReceiveDirectory() async {
  final support = await getApplicationSupportDirectory();
  return Directory('${support.path}/vidyut_received');
}

/// Latest-write-wins store for the newest image payload: bytes go to a file,
/// path and mime to secure storage. The foreground service isolate writes;
/// the UI isolate reads on notification tap.
class ReceivedImageRepository {
  ReceivedImageRepository(
    this._storage, {
    ReceiveDirectoryProvider? directoryProvider,
  }) : _directoryProvider = directoryProvider ?? _defaultReceiveDirectory;

  static const _latestImagePathKey = 'vidyut.receive.latestImagePath';
  static const _latestImageMimeKey = 'vidyut.receive.latestImageMime';

  final ReceivedPayloadStorage _storage;
  final ReceiveDirectoryProvider _directoryProvider;

  Future<ReceivedImage> saveLatest(List<int> bytes, String mime) async {
    return save(bytes, mime, id: null);
  }

  Future<ReceivedImage> save(
    List<int> bytes,
    String mime, {
    required String? id,
  }) async {
    final directory = await _directoryProvider();
    await directory.create(recursive: true);
    final file = File(
      '${directory.path}/${id ?? 'latest'}.${_extensionFor(mime)}',
    );
    await file.writeAsBytes(bytes, flush: true);
    if (id == null) {
      await for (final entry in directory.list()) {
        if (entry is File && entry.path != file.path) await entry.delete();
      }
    }
    await _storage.write(_latestImagePathKey, file.path);
    await _storage.write(_latestImageMimeKey, mime);
    return ReceivedImage(path: file.path, mime: mime);
  }

  Future<ReceivedImage?> loadById(String id) async {
    final directory = await _directoryProvider();
    if (!await directory.exists()) return null;
    final file = directory
        .listSync()
        .whereType<File>()
        .where((entry) => entry.path.split('/').last.startsWith('$id.'))
        .firstOrNull;
    if (file == null) return null;
    return ReceivedImage(path: file.path, mime: _mimeFor(file.path));
  }

  Future<ReceivedImage?> loadLatest() async {
    final path = await _storage.read(_latestImagePathKey);
    final mime = await _storage.read(_latestImageMimeKey);
    if (path == null || mime == null) return null;
    if (!await File(path).exists()) return null;
    return ReceivedImage(path: path, mime: mime);
  }

  String _extensionFor(String mime) {
    return switch (mime) {
      'image/png' => 'png',
      'image/jpeg' => 'jpg',
      'image/gif' => 'gif',
      'image/webp' => 'webp',
      'image/bmp' => 'bmp',
      _ => 'img',
    };
  }

  String _mimeFor(String path) => switch (path.split('.').last) {
    'png' => 'image/png',
    'jpg' => 'image/jpeg',
    'webp' => 'image/webp',
    _ => 'image/*',
  };
}
