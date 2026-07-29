import 'package:flutter/services.dart';

class VidyutFiles {
  const VidyutFiles();

  static const MethodChannel _channel = MethodChannel('vidyut/files');

  Future<String?> chooseDestination() {
    return _channel.invokeMethod<String>('chooseDestination');
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
