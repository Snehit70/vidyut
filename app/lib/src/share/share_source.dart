import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'share_payload.dart';

abstract interface class ShareSource {
  Future<List<SharePayload>> initialPayloads();

  Stream<List<SharePayload>> payloadStream();

  Future<void> reset();
}

class ReceiveSharingIntentSource implements ShareSource {
  const ReceiveSharingIntentSource();

  @override
  Future<List<SharePayload>> initialPayloads() async {
    return _mapFiles(await ReceiveSharingIntent.instance.getInitialMedia());
  }

  @override
  Stream<List<SharePayload>> payloadStream() {
    return ReceiveSharingIntent.instance.getMediaStream().map(_mapFiles);
  }

  @override
  Future<void> reset() => ReceiveSharingIntent.instance.reset();
}

List<SharePayload> _mapFiles(List<SharedMediaFile> files) {
  return files.map(_mapFile).nonNulls.toList(growable: false);
}

SharePayload? _mapFile(SharedMediaFile file) {
  final mime = file.mimeType ?? _defaultMime(file);
  return switch (file.type) {
    SharedMediaType.text ||
    SharedMediaType.url => SharePayload.text(file.path, mime: mime),
    SharedMediaType.image => SharePayload.image(path: file.path, mime: mime),
    SharedMediaType.file when mime.startsWith('image/') => SharePayload.image(
      path: file.path,
      mime: mime,
    ),
    SharedMediaType.file => SharePayload.file(
      path: file.path,
      mime: mime,
      filename: _filename(file.path),
    ),
    _ => SharePayload.file(
      path: file.path,
      mime: mime,
      filename: _filename(file.path),
    ),
  };
}

String _filename(String path) {
  final normalized = path.replaceAll(r'\', '/');
  return normalized.split('/').last;
}

String _defaultMime(SharedMediaFile file) {
  return switch (file.type) {
    SharedMediaType.text || SharedMediaType.url => 'text/plain',
    SharedMediaType.image => 'image/jpeg',
    _ => 'application/octet-stream',
  };
}
