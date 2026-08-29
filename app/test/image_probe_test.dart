import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/shared/image_probe.dart';

// Signature + IHDR for a 1×1 PNG. CRC is present so the chunk is well-formed.
const _png1x1 = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE,
];

const _jpeg1x1 = <int>[
  0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, //
  0x01, 0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xD9,
];

void main() {
  test('reads a 1x1 PNG IHDR', () {
    final probe = ImageProbe.fromBytes(_png1x1);
    expect(probe.width, 1);
    expect(probe.height, 1);
  });

  test('reads a 1x1 JPEG SOF0', () {
    final probe = ImageProbe.fromBytes(_jpeg1x1);
    expect(probe.width, 1);
    expect(probe.height, 1);
  });

  test('leaves garbage bytes without dimensions', () {
    final probe = ImageProbe.fromBytes([1, 2, 3, 4]);
    expect(probe.width, isNull);
    expect(probe.height, isNull);
  });

  test('fromFile returns an empty probe when the path is missing', () {
    final probe = ImageProbe.fromFile('/no/such/vidyut-preview.png');
    expect(probe.width, isNull);
    expect(probe.height, isNull);
  });

  test('fromFile reads enough bytes to parse a PNG', () async {
    final file = File(
      '${Directory.systemTemp.path}/vidyut_probe_${DateTime.now().microsecondsSinceEpoch}.png',
    );
    await file.writeAsBytes(_png1x1);
    addTearDown(() async {
      if (await file.exists()) await file.delete();
    });

    final probe = ImageProbe.fromFile(file.path);
    expect(probe.width, 1);
    expect(probe.height, 1);
  });
}
