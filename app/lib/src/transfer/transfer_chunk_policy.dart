import 'dart:math';

abstract final class TransferChunkPolicy {
  static const legacyBytes = 256 * 1024;
  static const preferredBytes = 1024 * 1024;

  static int negotiate(Object? advertisedBytes, {required int localMaximum}) {
    if (advertisedBytes is! int || advertisedBytes <= 0) {
      return min(localMaximum, legacyBytes);
    }
    return min(localMaximum, advertisedBytes);
  }
}
