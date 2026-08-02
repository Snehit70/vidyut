import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/pairing/pairing_repository.dart';
import 'package:vidyut/src/transfer/phone_transfer_sender.dart';
import 'package:vidyut/src/transfer/transfer_history.dart';
import 'package:vidyut_files/vidyut_files.dart';

void main() {
  test('persists a preparation row before source work starts', () async {
    final reader = _BlockingSourceReader();
    final history = TransferHistoryRepository(MemoryTransferHistoryStorage());
    final sender = PhoneTransferSender(
      pairingRepository: PairingRepository(MemoryPairingStorage()),
      connectionFactory: (_) => throw UnimplementedError(),
      history: history,
      sourceReader: reader,
    );

    final admitted = await sender.enqueue([
      const PhoneTransferSource(
        uri: 'content://provider/item/1',
        filename: 'photo.jpg',
        mime: 'image/jpeg',
        persisted: true,
      ),
    ]);

    expect(admitted.status, PhoneTransferStatus.preparing);
    final saved = (await history.load()).single;
    expect(
      saved.files.single.preparationPhase,
      PhoneTransferPreparationPhase.readingSelection,
    );
    expect(saved.files.single.preparedBytes, 0);
    await Future<void>.delayed(Duration.zero);
    expect(reader.probeStarted, isTrue);

    reader.releaseProbe();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });

  test(
    'publishes phase and byte progress from sender-owned preparation',
    () async {
      final reader = _ImmediateSourceReader();
      final history = TransferHistoryRepository(MemoryTransferHistoryStorage());
      final sender = PhoneTransferSender(
        pairingRepository: PairingRepository(MemoryPairingStorage()),
        connectionFactory: (_) => throw UnimplementedError(),
        history: history,
        sourceReader: reader,
      );
      final events = <PhoneTransferProgress>[];
      final subscription = sender.progress.listen(events.add);

      await sender.enqueue([
        const PhoneTransferSource(
          uri: 'content://provider/item/2',
          filename: 'photo.jpg',
          mime: 'image/jpeg',
          persisted: true,
        ),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        events.map((event) => event.stage),
        contains(PhoneTransferProgressStage.hashing),
      );
      final hashing = events.where(
        (event) => event.stage == PhoneTransferProgressStage.hashing,
      );
      expect(hashing.last.preparedBytes, 42);
      await subscription.cancel();
    },
  );

  test(
    'cancellation persists before a blocked source operation returns',
    () async {
      final reader = _BlockingSourceReader();
      final history = TransferHistoryRepository(MemoryTransferHistoryStorage());
      final sender = PhoneTransferSender(
        pairingRepository: PairingRepository(MemoryPairingStorage()),
        connectionFactory: (_) => throw UnimplementedError(),
        history: history,
        sourceReader: reader,
      );
      final admitted = await sender.enqueue([
        const PhoneTransferSource(
          uri: 'content://provider/item/3',
          filename: 'photo.jpg',
          mime: 'image/jpeg',
          persisted: true,
        ),
      ]);
      await Future<void>.delayed(Duration.zero);
      await sender.cancelFile(
        admitted.transferId,
        admitted.files.single.fileId,
      );

      expect(
        (await history.load()).single.files.single.status,
        PhoneTransferStatus.cancelled,
      );
      reader.releaseProbe();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(
        (await history.load()).single.files.single.status,
        PhoneTransferStatus.cancelled,
      );
    },
  );
}

class _BlockingSourceReader implements PhoneTransferSourceReader {
  final _probeReady = Completer<void>();
  bool probeStarted = false;

  void releaseProbe() => _probeReady.complete();

  @override
  Future<void> discard(String reference) async {}

  @override
  Future<void> release(String reference) async {}

  @override
  Future<void> retain(String reference) async {}

  @override
  Future<VidyutSourceProbe> probe(String uri) async {
    probeStarted = true;
    await _probeReady.future;
    return const VidyutSourceProbe(seekable: true, size: 1, sizeKnown: true);
  }

  @override
  Future<String> hashSha256(String uri) async => List.filled(64, 'a').join();

  @override
  Future<VidyutStagedSource> stage(String uri, {required int maximumBytes}) =>
      throw UnimplementedError();

  @override
  Future<List<int>> readAt(
    String uri, {
    required int offset,
    required int length,
  }) => throw UnimplementedError();
}

class _ImmediateSourceReader implements PhoneTransferSourceReader {
  @override
  Future<void> discard(String reference) async {}

  @override
  Future<void> release(String reference) async {}

  @override
  Future<void> retain(String reference) async {}

  @override
  Future<VidyutSourceProbe> probe(String uri) async =>
      const VidyutSourceProbe(seekable: true, size: 42, sizeKnown: true);

  @override
  Future<String> hashSha256(String uri) async => List.filled(64, 'b').join();

  @override
  Future<VidyutStagedSource> stage(String uri, {required int maximumBytes}) =>
      throw UnimplementedError();

  @override
  Future<List<int>> readAt(
    String uri, {
    required int offset,
    required int length,
  }) => throw UnimplementedError();
}
