enum SharePayloadType { text, image, file, link }

class SharePayload {
  const SharePayload.text(this.text, {this.mime = 'text/plain'})
    : type = SharePayloadType.text,
      path = null,
      filename = null;

  /// A single URL. Encodes as [PayloadType.link] so the laptop puts it in the
  /// clipboard and opens it, rather than only pasting it later.
  const SharePayload.link(this.text)
    : type = SharePayloadType.link,
      mime = 'text/plain',
      path = null,
      filename = null;

  const SharePayload.image({required this.path, required this.mime})
    : type = SharePayloadType.image,
      text = null,
      filename = null;

  const SharePayload.file({
    required this.path,
    required this.mime,
    required this.filename,
  }) : type = SharePayloadType.file,
       text = null;

  final SharePayloadType type;
  final String mime;
  final String? text;
  final String? path;
  final String? filename;
}
