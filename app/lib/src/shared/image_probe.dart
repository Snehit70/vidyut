import 'dart:io';
import 'dart:math' as math;

/// Width and height parsed from PNG IHDR or JPEG SOF0/SOF2.
///
/// Unknown dimensions stay null. Garbage input never throws.
class ImageProbe {
  const ImageProbe({this.width, this.height});

  final int? width;
  final int? height;

  factory ImageProbe.fromBytes(List<int> bytes) {
    try {
      if (_isPng(bytes)) return _parsePng(bytes);
      if (_isJpeg(bytes)) return _parseJpeg(bytes);
      return const ImageProbe();
    } on Object {
      return const ImageProbe();
    }
  }

  factory ImageProbe.fromFile(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return const ImageProbe();
      final length = file.lengthSync();
      if (length <= 0) return const ImageProbe();
      final raf = file.openSync();
      try {
        final toRead = math.min(length, 512 * 1024);
        return ImageProbe.fromBytes(raf.readSync(toRead));
      } finally {
        raf.closeSync();
      }
    } on Object {
      return const ImageProbe();
    }
  }

  static bool _isPng(List<int> bytes) {
    const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    if (bytes.length < signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) return false;
    }
    return true;
  }

  static bool _isJpeg(List<int> bytes) {
    return bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;
  }

  static ImageProbe _parsePng(List<int> bytes) {
    var offset = 8;
    while (offset + 8 <= bytes.length) {
      final length = _be32(bytes, offset);
      if (length == null) return const ImageProbe();
      final typeEnd = offset + 8;
      if (typeEnd > bytes.length) return const ImageProbe();
      final type = String.fromCharCodes(bytes.sublist(offset + 4, typeEnd));
      final dataStart = typeEnd;
      if (type == 'IHDR') {
        if (length != 13) {
          return const ImageProbe();
        }
        if (dataStart + length + 4 > bytes.length) {
          return const ImageProbe();
        }
        final width = _be32(bytes, dataStart);
        final height = _be32(bytes, dataStart + 4);
        if (width == null || height == null || width <= 0 || height <= 0) {
          return const ImageProbe();
        }
        return ImageProbe(width: width, height: height);
      }
      if (dataStart + length + 4 > bytes.length) {
        return const ImageProbe();
      }
      final next = dataStart + length + 4;
      if (next <= offset) return const ImageProbe();
      offset = next;
    }
    return const ImageProbe();
  }

  static ImageProbe _parseJpeg(List<int> bytes) {
    var offset = 2;
    while (offset + 1 < bytes.length) {
      if (bytes[offset] != 0xFF) {
        offset++;
        continue;
      }
      while (offset < bytes.length && bytes[offset] == 0xFF) {
        offset++;
      }
      if (offset >= bytes.length) return const ImageProbe();
      final marker = bytes[offset];
      offset++;
      if (marker == 0xD8) continue;
      if (marker == 0xD9 || marker == 0xDA) return const ImageProbe();
      if (marker >= 0xD0 && marker <= 0xD7) continue;
      if (marker == 0x01) continue;
      if (offset + 1 >= bytes.length) return const ImageProbe();
      final segmentLength = _be16(bytes, offset);
      if (segmentLength == null || segmentLength < 2) return const ImageProbe();
      if (offset + segmentLength > bytes.length) return const ImageProbe();
      final dataStart = offset + 2;
      if (marker == 0xC0 || marker == 0xC2) {
        if (segmentLength < 8) return const ImageProbe();
        if (dataStart + 5 > offset + segmentLength) return const ImageProbe();
        if (dataStart + 5 > bytes.length) return const ImageProbe();
        final height = _be16(bytes, dataStart + 1);
        final width = _be16(bytes, dataStart + 3);
        if (width == null || height == null || width <= 0 || height <= 0) {
          return const ImageProbe();
        }
        return ImageProbe(width: width, height: height);
      }
      offset += segmentLength;
    }
    return const ImageProbe();
  }

  static int? _be16(List<int> bytes, int offset) {
    if (offset + 1 >= bytes.length) return null;
    return ((bytes[offset] & 0xFF) << 8) | (bytes[offset + 1] & 0xFF);
  }

  static int? _be32(List<int> bytes, int offset) {
    if (offset + 3 >= bytes.length) return null;
    return ((bytes[offset] & 0xFF) << 24) |
        ((bytes[offset + 1] & 0xFF) << 16) |
        ((bytes[offset + 2] & 0xFF) << 8) |
        (bytes[offset + 3] & 0xFF);
  }
}
