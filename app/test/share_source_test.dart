import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/share/share_payload.dart';
import 'package:vidyut/src/share/share_source.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

void main() {
  test('maps initial text and image shares from the Android plugin', () async {
    ReceiveSharingIntent.setMockValues(
      initialMedia: [
        SharedMediaFile(
          path: 'hello relay',
          type: SharedMediaType.text,
          mimeType: 'text/plain',
        ),
        SharedMediaFile(
          path: '/cache/photo.webp',
          type: SharedMediaType.image,
          mimeType: 'image/webp',
        ),
      ],
      mediaStream: const Stream.empty(),
    );

    final payloads = await const ReceiveSharingIntentSource().initialPayloads();

    expect(payloads, hasLength(2));
    expect(payloads.first.type, SharePayloadType.text);
    expect(payloads.first.text, 'hello relay');
    expect(payloads.last.type, SharePayloadType.image);
    expect(payloads.last.path, '/cache/photo.webp');
    expect(payloads.last.mime, 'image/webp');
  });

  test('maps regular file shares into the transfer path', () async {
    ReceiveSharingIntent.setMockValues(
      initialMedia: [
        SharedMediaFile(
          path: '/cache/report.pdf',
          type: SharedMediaType.file,
          mimeType: 'application/pdf',
        ),
      ],
      mediaStream: const Stream.empty(),
    );

    final payloads = await const ReceiveSharingIntentSource().initialPayloads();
    expect(payloads.single.type, SharePayloadType.file);
    expect(payloads.single.path, '/cache/report.pdf');
    expect(payloads.single.filename, 'report.pdf');
    expect(payloads.single.mime, 'application/pdf');
  });

  test('maps stream updates', () async {
    final stream = StreamController<List<SharedMediaFile>>();
    ReceiveSharingIntent.setMockValues(
      initialMedia: const [],
      mediaStream: stream.stream,
    );

    final source = const ReceiveSharingIntentSource();
    final next = source.payloadStream().first;
    stream.add([
      SharedMediaFile(
        path: 'https://example.test/image',
        type: SharedMediaType.url,
        mimeType: 'text/plain',
      ),
    ]);

    final payloads = await next;
    expect(payloads.single.type, SharePayloadType.text);
    expect(payloads.single.text, 'https://example.test/image');
    await stream.close();
  });
}
