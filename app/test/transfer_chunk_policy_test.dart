import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/transfer/transfer_chunk_policy.dart';

void main() {
  test(
    'uses the legacy chunk size when the receiver does not advertise one',
    () {
      expect(
        TransferChunkPolicy.negotiate(
          null,
          localMaximum: TransferChunkPolicy.preferredBytes,
        ),
        TransferChunkPolicy.legacyBytes,
      );
    },
  );

  test('uses the largest chunk both peers support', () {
    expect(
      TransferChunkPolicy.negotiate(
        TransferChunkPolicy.preferredBytes,
        localMaximum: TransferChunkPolicy.preferredBytes,
      ),
      TransferChunkPolicy.preferredBytes,
    );
    expect(
      TransferChunkPolicy.negotiate(
        2 * TransferChunkPolicy.preferredBytes,
        localMaximum: TransferChunkPolicy.preferredBytes,
      ),
      TransferChunkPolicy.preferredBytes,
    );
  });

  test('rejects invalid advertisements by falling back to legacy chunks', () {
    expect(
      TransferChunkPolicy.negotiate(
        0,
        localMaximum: TransferChunkPolicy.preferredBytes,
      ),
      TransferChunkPolicy.legacyBytes,
    );
  });
}
