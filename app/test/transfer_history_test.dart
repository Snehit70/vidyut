import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/transfer/transfer_history.dart';

void main() {
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
}
