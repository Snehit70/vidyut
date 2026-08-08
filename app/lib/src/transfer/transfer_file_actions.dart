import 'package:flutter/services.dart';

import 'transfer_history.dart';

abstract interface class TransferFileActions {
  Future<void> open(PhoneTransferFile file);

  Future<void> showFolder(PhoneTransferFile file);

  Future<void> share(PhoneTransferFile file);
}

class AndroidTransferFileActions implements TransferFileActions {
  const AndroidTransferFileActions({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('vidyut/transfer_files');

  final MethodChannel _channel;

  @override
  Future<void> open(PhoneTransferFile file) => _invoke('open', file);

  @override
  Future<void> showFolder(PhoneTransferFile file) =>
      _invoke('showFolder', file);

  @override
  Future<void> share(PhoneTransferFile file) => _invoke('share', file);

  Future<void> _invoke(String method, PhoneTransferFile file) {
    final target = transferFileActionTarget(file);
    return _channel.invokeMethod<void>(method, target);
  }
}

Map<String, Object?> transferFileActionTarget(PhoneTransferFile file) {
  final source = file.sourceReference;
  final uri = source?.kind == PhoneTransferSourceKind.androidDocumentUri
      ? source?.reference
      : null;
  final path =
      file.destinationPath ??
      file.sourcePath ??
      (source?.kind == PhoneTransferSourceKind.externalPath
          ? source?.reference
          : null);
  final target = <String, Object?>{
    'filename': file.filename,
    'mime': file.mime,
  };
  if (path != null) target['path'] = path;
  if (uri != null) target['uri'] = uri;
  return target;
}
