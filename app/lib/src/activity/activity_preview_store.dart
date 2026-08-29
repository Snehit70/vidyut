import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

typedef ActivityPreviewDirectoryProvider = Future<Directory> Function();

Future<Directory> _defaultPreviewDirectory() async {
  final support = await getApplicationSupportDirectory();
  return Directory('${support.path}/vidyut_activity_previews');
}

/// Persists screenshot bytes so activity cards can render [Image.file].
class ActivityPreviewStore {
  ActivityPreviewStore({ActivityPreviewDirectoryProvider? directoryProvider})
    : _directoryProvider = directoryProvider ?? _defaultPreviewDirectory;

  final ActivityPreviewDirectoryProvider _directoryProvider;

  Future<String> save({
    required List<int> bytes,
    required String mime,
    required String id,
  }) async {
    final directory = await _directoryProvider();
    await directory.create(recursive: true);
    final file = File(
      '${directory.path}/${_storageId(id)}.${_extensionFor(mime)}',
    );
    await file.writeAsBytes(bytes, flush: true);
    await _prune(directory);
    return file.path;
  }

  Future<void> _prune(Directory directory) async {
    final files = directory.listSync().whereType<File>().toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    for (final file in files.skip(30)) {
      await file.delete();
    }
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

  String _storageId(String id) => base64Url.encode(utf8.encode(id));
}
