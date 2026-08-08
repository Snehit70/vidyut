// ignore_for_file: deprecated_member_use_from_same_package

import 'package:flutter/services.dart';

import 'transfer_history.dart';

abstract interface class TransferFileActions {
  Future<void> open(PhoneTransferFile file);

  Future<void> share(PhoneTransferFile file);
}

class AndroidTransferFileActions implements TransferFileActions {
  const AndroidTransferFileActions({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('vidyut/transfer_files');

  final MethodChannel _channel;

  @override
  Future<void> open(PhoneTransferFile file) => _invoke('open', file);

  @override
  Future<void> share(PhoneTransferFile file) => _invoke('share', file);

  Future<void> _invoke(String method, PhoneTransferFile file) {
    final target = transferFileActionTarget(file);
    return _channel.invokeMethod<void>(method, target);
  }
}

Map<String, Object?> transferFileActionTarget(PhoneTransferFile file) {
  final source = file.sourceReference;
  final destination = file.destinationPath;
  final destinationUri = destination == null ? null : Uri.tryParse(destination);
  final uri = destinationUri?.scheme == 'content'
      ? destination
      : destination == null &&
            source?.kind == PhoneTransferSourceKind.androidDocumentUri
      ? source?.reference
      : null;
  final path = destinationUri?.scheme == 'content'
      ? null
      : destination ??
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
