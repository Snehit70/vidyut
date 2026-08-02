import 'package:flutter/services.dart';

class VidyutSourceProbe {
  const VidyutSourceProbe({
    required this.seekable,
    required this.size,
    required this.sizeKnown,
  });

  final bool seekable;
  final int size;
  final bool sizeKnown;

  factory VidyutSourceProbe.fromMap(Map<Object?, Object?> value) {
    final seekable = value['seekable'];
    final size = value['size'];
    final sizeKnown = value['sizeKnown'];
    if (seekable is! bool || size is! int || sizeKnown is! bool) {
      throw const FormatException('Android returned an invalid source probe.');
    }
    return VidyutSourceProbe(
      seekable: seekable,
      size: size,
      sizeKnown: sizeKnown,
    );
  }
}

class VidyutStagedSource {
  const VidyutStagedSource({
    required this.reference,
    required this.size,
    required this.sha256,
    this.lastModifiedMs,
  });

  final String reference;
  final int size;
  final String sha256;
  final int? lastModifiedMs;

  factory VidyutStagedSource.fromMap(Map<Object?, Object?> value) {
    final reference = value['reference'];
    final size = value['size'];
    final sha256 = value['sha256'];
    if (reference is! String || size is! int || sha256 is! String) {
      throw const FormatException('Android returned an invalid staged source.');
    }
    return VidyutStagedSource(
      reference: reference,
      size: size,
      sha256: sha256,
      lastModifiedMs: value['lastModifiedMs'] is int
          ? value['lastModifiedMs'] as int
          : null,
    );
  }
}

class VidyutPickedFile {
  const VidyutPickedFile({
    this.path,
    this.uri,
    required this.filename,
    required this.mime,
    this.size,
    this.lastModifiedMs,
    this.persisted = false,
  }) : assert(path != null || uri != null);

  /// Kept for local/share-intake compatibility. Picker selections use [uri].
  final String? path;
  final String? uri;
  final String filename;
  final String mime;
  final int? size;
  final int? lastModifiedMs;
  final bool persisted;

  factory VidyutPickedFile.fromMap(Map<Object?, Object?> value) {
    final path = value['path'];
    final uri = value['uri'] ?? value['sourceReference'];
    final filename = value['filename'];
    final mime = value['mime'];
    if ((path is! String && uri is! String) ||
        filename is! String ||
        mime is! String) {
      throw const FormatException(
        'Android returned an invalid file selection.',
      );
    }
    return VidyutPickedFile(
      path: path is String ? path : null,
      uri: uri is String ? uri : null,
      filename: filename,
      mime: mime,
      size: value['size'] is int ? value['size'] as int : null,
      lastModifiedMs: value['lastModifiedMs'] is int
          ? value['lastModifiedMs'] as int
          : null,
      persisted: value['persisted'] == true,
    );
  }
}

class VidyutFiles {
  const VidyutFiles();

  static const MethodChannel _channel = MethodChannel('vidyut/files');

  Future<String?> chooseDestination() {
    return _channel.invokeMethod<String>('chooseDestination');
  }

  /// Opens Android's document picker and returns durable URI references. No
  /// source bytes are copied before the transfer row exists.
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

  Future<VidyutSourceProbe> probeSource(String uri) async {
    final raw = await _channel.invokeMethod<Object?>('probeSource', {
      'uri': uri,
    });
    if (raw is! Map) {
      throw const FormatException('Android returned an invalid source probe.');
    }
    return VidyutSourceProbe.fromMap(Map<Object?, Object?>.from(raw));
  }

  Future<String> hashSource(String uri) async {
    final hash = await _channel.invokeMethod<String>('hashSource', {
      'uri': uri,
    });
    if (hash == null || !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw const FormatException('Android returned an invalid source hash.');
    }
    return hash;
  }

  Future<VidyutStagedSource> stageSource(
    String uri, {
    int? maximumBytes,
  }) async {
    final raw = await _channel.invokeMethod<Object?>('stageSource', {
      'uri': uri,
      ...?maximumBytes == null ? null : {'maximumBytes': maximumBytes},
    });
    if (raw is! Map) {
      throw const FormatException('Android returned an invalid staged source.');
    }
    return VidyutStagedSource.fromMap(Map<Object?, Object?>.from(raw));
  }

  Future<Uint8List> readSourceAt(
    String uri, {
    required int offset,
    required int length,
  }) async {
    final bytes = await _channel.invokeMethod<Uint8List>('readSourceAt', {
      'uri': uri,
      'offset': offset,
      'length': length,
    });
    if (bytes == null || bytes.length > length) {
      throw const FormatException('Android returned invalid source bytes.');
    }
    return bytes;
  }

  Future<void> releaseSource(String uri) async {
    await _channel.invokeMethod<void>('releaseSource', {'uri': uri});
  }

  Future<void> retainSource(String uri) async {
    await _channel.invokeMethod<void>('retainSource', {'uri': uri});
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
