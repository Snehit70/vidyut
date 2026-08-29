import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/shared/format.dart';

void main() {
  group('activityCounterpart', () {
    test('returns a trimmed hostname', () {
      expect(activityCounterpart('fedora'), 'fedora');
      expect(activityCounterpart(' fedora '), 'fedora');
    });

    test('falls back to laptop when the name is missing', () {
      expect(activityCounterpart(null), 'laptop');
      expect(activityCounterpart(''), 'laptop');
      expect(activityCounterpart('   '), 'laptop');
    });
  });

  group('mimeShortLabel', () {
    test('maps common image types', () {
      expect(mimeShortLabel('image/png'), 'PNG');
      expect(mimeShortLabel('image/jpeg'), 'JPEG');
      expect(mimeShortLabel('image/jpg'), 'JPEG');
      expect(mimeShortLabel('image/webp'), 'WEBP');
      expect(mimeShortLabel('image/gif'), 'GIF');
      expect(mimeShortLabel('image/bmp'), 'BMP');
    });

    test('uppercases an unknown subtype or keeps the raw type', () {
      expect(mimeShortLabel('image/svg+xml'), 'SVG+XML');
      expect(mimeShortLabel('octet-stream'), 'octet-stream');
    });
  });

  group('formatMediaDetail', () {
    test('joins size, mime, and dimensions when they are known', () {
      expect(
        formatMediaDetail(
          bytes: 327782,
          mime: 'image/png',
          width: 1080,
          height: 2400,
        ),
        '320.1 KB  •  PNG  •  1080 × 2400',
      );
    });

    test('omits unknown mime and dimensions', () {
      expect(formatMediaDetail(bytes: 327782), '320.1 KB');
      expect(
        formatMediaDetail(bytes: 327782, mime: 'image/png'),
        '320.1 KB  •  PNG',
      );
      expect(
        formatMediaDetail(bytes: 327782, width: 1080, height: 2400),
        '320.1 KB  •  1080 × 2400',
      );
    });
  });
}
