import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/transfer/transfer_history.dart';

void main() {
  PhoneTransferBatch batch(String suffix) => PhoneTransferBatch(
    transferId: 'transfer_${suffix}000000000000',
    batchId: 'batch_${suffix}000000000000',
    direction: PhoneTransferDirection.sent,
    createdAtMs: suffix.codeUnitAt(0),
    updatedAtMs: 10,
    status: PhoneTransferStatus.queued,
    files: [
      PhoneTransferFile(
        fileId: 'file_${suffix}000000000000',
        filename: '$suffix.pdf',
        mime: 'application/pdf',
        size: 1,
        lastModifiedMs: 9,
        sha256: List.filled(64, 'a').join(),
        status: PhoneTransferStatus.queued,
        confirmedOffset: 0,
      ),
    ],
  );

  test('serializes mutations across repository instances', () async {
    final storage = MemoryTransferHistoryStorage();
    final first = TransferHistoryRepository(storage);
    final second = TransferHistoryRepository(storage);

    await Future.wait([first.upsert(batch('a')), second.upsert(batch('b'))]);

    expect((await first.load()).map((item) => item.transferId), hasLength(2));
  });

  test('persists unlimited transfer metadata without file contents', () async {
    final storage = MemoryTransferHistoryStorage();
    final repository = TransferHistoryRepository(storage);
    final batch = PhoneTransferBatch(
      transferId: 'transfer_1234567890',
      batchId: 'batch_123456789012',
      direction: PhoneTransferDirection.sent,
      createdAtMs: 10,
      updatedAtMs: 10,
      status: PhoneTransferStatus.queued,
      files: const [
        PhoneTransferFile(
          fileId: 'file_1234567890123',
          filename: 'report.pdf',
          mime: 'application/pdf',
          size: 42,
          lastModifiedMs: 9,
          sha256:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          status: PhoneTransferStatus.queued,
          confirmedOffset: 0,
          sourcePath: '/source/report.pdf',
        ),
      ],
    );

    await repository.upsert(batch);
    final loaded = await repository.load();

    expect(loaded.single.toJson(), batch.toJson());
    expect(storage.value, isNot(contains('file contents')));
    await repository.clear();
    expect(await repository.load(), isEmpty);
  });

  test('round-trips compact timing without changing transfer metadata', () {
    final file = PhoneTransferFile(
      fileId: 'file_timing_123456',
      filename: 'timed.bin',
      mime: 'application/octet-stream',
      size: 4,
      lastModifiedMs: 9,
      sha256: List.filled(64, 'a').join(),
      status: PhoneTransferStatus.completed,
      confirmedOffset: 4,
      timing: const TransferTimingSummary(
        wallAnchorMs: 1_800_000_000_000,
        attempts: [
          TransferAttemptTiming(
            attempt: 0,
            stages: {
              TransferTimingStage.sourceHash: (startMs: 3, endMs: 18),
              TransferTimingStage.durableCompletion: (startMs: 22, endMs: 24),
            },
          ),
        ],
      ),
    );

    final decoded = PhoneTransferFile.fromJson(file.toJson());

    expect(decoded.toJson(), file.toJson());
    expect(decoded.status, PhoneTransferStatus.completed);
    expect(decoded.confirmedOffset, 4);
  });

  test('round-trips structured failure context', () {
    final file = PhoneTransferFile(
      fileId: 'file_1234567890123',
      filename: 'large.mp4',
      mime: 'video/mp4',
      size: 4 * 1024 * 1024 * 1024,
      lastModifiedMs: 9,
      sha256: List.filled(64, 'a').join(),
      status: PhoneTransferStatus.failed,
      confirmedOffset: 0,
      errorCode: 'file_too_large',
      errorOrigin: 'remote',
      errorCategory: 'remote_rejection',
      errorDetail: 'Receiver rejected the file.',
      errorContext: const {
        'actualBytes': 4 * 1024 * 1024 * 1024,
        'limitBytes': 1024 * 1024 * 1024,
      },
    );

    final decoded = PhoneTransferFile.fromJson(file.toJson());

    expect(decoded.errorCode, 'file_too_large');
    expect(decoded.errorOrigin, 'remote');
    expect(decoded.errorCategory, 'remote_rejection');
    expect(decoded.errorDetail, 'Receiver rejected the file.');
    expect(decoded.errorContext, {
      'actualBytes': 4 * 1024 * 1024 * 1024,
      'limitBytes': 1024 * 1024 * 1024,
    });
  });

  test('round-trips durable URI sources without native handles', () {
    final file = PhoneTransferFile(
      fileId: 'file_uri_123456',
      filename: 'cloud.pdf',
      mime: 'application/pdf',
      size: 42,
      lastModifiedMs: 0,
      lastModifiedKnown: false,
      sha256: List.filled(64, 'b').join(),
      status: PhoneTransferStatus.preparing,
      confirmedOffset: 0,
      sourceReference: const PhoneTransferSourceReference(
        kind: PhoneTransferSourceKind.androidDocumentUri,
        reference: 'content://provider/document/42',
        ownership: PhoneTransferSourceOwnership.external,
      ),
    );

    final decoded = PhoneTransferFile.fromJson(file.toJson());

    expect(decoded.sourcePath, isNull);
    expect(
      decoded.sourceReference?.kind,
      PhoneTransferSourceKind.androidDocumentUri,
    );
    expect(
      decoded.sourceReference?.reference,
      'content://provider/document/42',
    );
    expect(decoded.lastModifiedKnown, isFalse);
    expect(decoded.toJson(), file.toJson());
  });
}
