import 'package:flutter/services.dart';

class VidyutPickedFile {
  const VidyutPickedFile({
    required this.path,
    required this.filename,
    required this.mime,
  });

  final String path;
  final String filename;
  final String mime;

  factory VidyutPickedFile.fromMap(Map<Object?, Object?> value) {
    final path = value['path'];
    final filename = value['filename'];
    final mime = value['mime'];
    if (path is! String || filename is! String || mime is! String) {
      throw const FormatException(
        'Android returned an invalid file selection.',
      );
    }
    return VidyutPickedFile(path: path, filename: filename, mime: mime);
  }
}

class VidyutFiles {
  const VidyutFiles();

  static const MethodChannel _channel = MethodChannel('vidyut/files');

  Future<String?> chooseDestination() {
    return _channel.invokeMethod<String>('chooseDestination');
  }

  /// Opens Android's document picker and streams selected content URIs into
  /// cache without loading their bytes into the app heap.
  Future<List<VidyutPickedFile>> pickFiles() async {
    final raw =
        await _channel.invokeListMethod<Object?>('pickFiles') ?? const [];
    return raw
        .map((value) {
          if (value is! Map) {
            throw const FormatException(
              'Android returned an invalid file selection.',
            );
          }
          return VidyutPickedFile.fromMap(Map<Object?, Object?>.from(value));
        })
        .toList(growable: false);
  }

  Future<String> destinationLabel() async {
    return await _channel.invokeMethod<String>('destinationLabel') ??
        'Downloads/Vidyut';
  }

  Future<bool> isNetworkMetered() async {
    return await _channel.invokeMethod<bool>('isNetworkMetered') ?? true;
  }

  Future<bool> isDestinationAvailable() async {
    return await _channel.invokeMethod<bool>('isDestinationAvailable') ?? false;
  }

  /// Copies [sourcePath] into the configured public destination and removes
  /// the private source only after the public write has completed.
  Future<String> publish({
    required String sourcePath,
    required String filename,
    required String mime,
    required int lastModifiedMs,
  }) async {
    final destination = await _channel.invokeMethod<String>('publish', {
      'sourcePath': sourcePath,
      'filename': filename,
      'mime': mime,
      'lastModifiedMs': lastModifiedMs,
    });
    if (destination == null) {
      throw PlatformException(
        code: 'publish-failed',
        message: 'Android returned no destination.',
      );
    }
    return destination;
  }
}
