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

  test('maps a shared url to a link so the laptop opens it', () async {
    final stream = StreamController<List<SharedMediaFile>>();
    ReceiveSharingIntent.setMockValues(
      initialMedia: const [],
      mediaStream: stream.stream,
    );

    final source = const ReceiveSharingIntentSource();
    final next = source.payloadStream().first;
    stream.add([
      SharedMediaFile(
        path: 'https://example.test/page',
        type: SharedMediaType.url,
        mimeType: 'text/plain',
      ),
    ]);

    final payloads = await next;
    expect(payloads.single.type, SharePayloadType.link);
    expect(payloads.single.text, 'https://example.test/page');
    await stream.close();
  });

  test('keeps a url-typed share as text when it is not a URL', () async {
    final stream = StreamController<List<SharedMediaFile>>();
    ReceiveSharingIntent.setMockValues(
      initialMedia: const [],
      mediaStream: stream.stream,
    );

    final source = const ReceiveSharingIntentSource();
    final next = source.payloadStream().first;
    stream.add([
      SharedMediaFile(
        path: 'https://example.test/page and more words',
        type: SharedMediaType.url,
        mimeType: 'text/plain',
      ),
    ]);

    // The share sheet labels things url that are not addresses, so the check is
    // not taken on the declared type.
    final payloads = await next;
    expect(payloads.single.type, SharePayloadType.text);
    await stream.close();
  });
}
