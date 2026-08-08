import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/pairing/pairing_code.dart';
import 'package:vidyut/src/pairing/pairing_repository.dart';
import 'package:vidyut/src/shared/relay_connection.dart';
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

  test('retains a persisted document grant for each history row', () async {
    const uri = 'content://provider/item/resend';
    final reader = _GrantTrackingSourceReader();
    final history = TransferHistoryRepository(MemoryTransferHistoryStorage());
    final sender = PhoneTransferSender(
      pairingRepository: PairingRepository(MemoryPairingStorage()),
      connectionFactory: (_) => throw UnimplementedError(),
      history: history,
      sourceReader: reader,
    );

    final first = await sender.enqueue([
      const PhoneTransferSource(
        uri: uri,
        filename: 'resend.pdf',
        mime: 'application/pdf',
        persisted: true,
        grantAlreadyRetained: true,
      ),
    ]);
    await sender.waitForTerminal(first.transferId);
    final firstFile = (await history.load()).single.files.single;

    final second = await sender.sendAgain(firstFile);
    await sender.waitForTerminal(second.transferId);

    expect(reader.retained, [uri, uri, uri]);
    expect(reader.released, [uri, uri]);

    await sender.clearHistory();
    expect(reader.released, [uri, uri, uri, uri]);
  });

  test(
    'records ordered queue-card and publication timing with an injected clock',
    () async {
      var monotonic = 0;
      final reader = _BlockingSourceReader();
      final sender = PhoneTransferSender(
        pairingRepository: PairingRepository(MemoryPairingStorage()),
        connectionFactory: (_) => throw UnimplementedError(),
        history: TransferHistoryRepository(MemoryTransferHistoryStorage()),
        sourceReader: reader,
        monotonicClock: () => monotonic += 5,
        wallClock: () => 1_800_000_000_000,
      );

      final admitted = await sender.enqueue([
        const PhoneTransferSource(
          uri: 'content://provider/item/timing',
          filename: 'timing.bin',
          mime: 'application/octet-stream',
          persisted: true,
        ),
      ]);
      final timing = admitted.files.single.timing!;
      final stages = timing.attempts.single.stages;

      expect(timing.wallAnchorMs, 1_800_000_000_000);
      expect(
        stages.keys,
        containsAll(<String>[
          TransferTimingStage.pickerCallback,
          TransferTimingStage.durableQueueCard,
          TransferTimingStage.firstVisiblePublication,
        ]),
      );
      for (final span in stages.values) {
        if (span.endMs != null) {
          expect(span.endMs, greaterThanOrEqualTo(span.startMs));
        }
      }
      reader.releaseProbe();
    },
  );

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

  test(
    'fallback staging reuses the digest returned by the single source pass',
    () async {
      final reader = _FallbackSourceReader();
      final history = TransferHistoryRepository(MemoryTransferHistoryStorage());
      final sender = PhoneTransferSender(
        pairingRepository: PairingRepository(MemoryPairingStorage()),
        connectionFactory: (_) => throw UnimplementedError(),
        history: history,
        sourceReader: reader,
      );

      final admitted = await sender.enqueue([
        const PhoneTransferSource(
          uri: 'content://provider/pipe/1',
          filename: 'pipe.bin',
          mime: 'application/octet-stream',
        ),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final file = (await history.load()).single.files.single;
      expect(file.fileId, admitted.files.single.fileId);
      expect(reader.stageCalls, 1);
      expect(reader.hashCalls, 0);
      expect(file.sha256, _fallbackDigest);
      expect(file.sourceReference?.kind, PhoneTransferSourceKind.managedStage);
    },
  );

  test(
    'cancelling fallback staging invalidates the native stage operation',
    () async {
      final reader = _CancellableStageReader();
      final history = TransferHistoryRepository(MemoryTransferHistoryStorage());
      final sender = PhoneTransferSender(
        pairingRepository: PairingRepository(MemoryPairingStorage()),
        connectionFactory: (_) => throw UnimplementedError(),
        history: history,
        sourceReader: reader,
      );
      final admitted = await sender.enqueue([
        const PhoneTransferSource(
          uri: 'content://provider/pipe/cancellable',
          filename: 'pipe.bin',
          mime: 'application/octet-stream',
        ),
      ]);
      for (
        var attempt = 0;
        attempt < 20 && reader.operationId == null;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      await sender.cancelFile(
        admitted.transferId,
        admitted.files.single.fileId,
      );

      expect(reader.operationId, isNotNull);
      expect(reader.cancelledOperationId, reader.operationId);
      expect(
        (await history.load()).single.files.single.status,
        PhoneTransferStatus.cancelled,
      );
    },
  );

  test(
    'overlaps direct-source hashing with relay setup but gates the offer',
    () async {
      final reader = _OverlapSourceReader();
      final transport = _OverlapTransport();
      final pairingRepository = PairingRepository(MemoryPairingStorage());
      await pairingRepository.save(
        const PairingCode(host: '127.0.0.1', port: 1, secret: 'pairing-secret'),
      );
      final history = TransferHistoryRepository(MemoryTransferHistoryStorage());
      final sender = PhoneTransferSender(
        pairingRepository: pairingRepository,
        connectionFactory: (pairing) => RelayConnection(
          pairing: pairing,
          deviceId: 'phone',
          transport: transport,
        ),
        history: history,
        sourceReader: reader,
      );

      final admitted = await sender.enqueue([
        const PhoneTransferSource(
          uri: 'content://provider/seekable/overlap',
          filename: 'overlap.bin',
          mime: 'application/octet-stream',
          persisted: true,
        ),
      ]);
      for (var attempt = 0; attempt < 20 && !reader.hashStarted; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));

      expect(reader.hashStarted, isTrue);
      expect(transport.authSent, isTrue);
      expect(transport.offerSent, isFalse);

      reader.releaseHash();
      for (
        var attempt = 0;
        attempt < 100 &&
            (await history.load()).single.files.single.status !=
                PhoneTransferStatus.completed;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }

      final completed = (await history.load()).single;
      expect(completed.transferId, admitted.transferId);
      expect(completed.files.single.status, PhoneTransferStatus.completed);
      expect(transport.offerSent, isTrue);
    },
  );
}

const _fallbackDigest =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
const _overlapDigest =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

class _OverlapSourceReader implements PhoneTransferSourceReader {
  final _hashGate = Completer<void>();
  bool hashStarted = false;

  void releaseHash() {
    if (!_hashGate.isCompleted) _hashGate.complete();
  }

  @override
  Future<void> cancelStage(String operationId) async {}

  @override
  Future<void> discard(String reference) async {}

  @override
  Future<void> release(String reference) async {}

  @override
  Future<void> retain(String reference) async {}

  @override
  Future<VidyutSourceProbe> probe(String uri) async =>
      const VidyutSourceProbe(seekable: true, size: 3, sizeKnown: true);

  @override
  Future<String> hashSha256(String uri) async {
    hashStarted = true;
    await _hashGate.future;
    return _overlapDigest;
  }

  @override
  Future<VidyutStagedSource> stage(
    String uri, {
    required int maximumBytes,
    String? operationId,
  }) => throw UnimplementedError();

  @override
  Future<List<int>> readAt(
    String uri, {
    required int offset,
    required int length,
  }) => throw UnimplementedError();
}

class _OverlapTransport implements RelayTransport {
  _OverlapTransport() {
    scheduleMicrotask(
      () => _incoming.add({
        'v': 1,
        'kind': 'hello',
        'challenge': 'challenge',
      }),
    );
  }

  final _incoming = StreamController<Object?>();
  bool authSent = false;
  bool offerSent = false;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  Stream<Object?> get messages => _incoming.stream;

  @override
  void send(Map<String, Object?> message) {
    if (message['kind'] == 'auth') {
      authSent = true;
      scheduleMicrotask(() {
        if (!_incoming.isClosed) {
          _incoming.add({'v': 1, 'kind': 'auth_ok'});
        }
      });
      return;
    }
    if (message['kind'] != 'transfer_offer') return;
    offerSent = true;
    final offer = (message['offer']! as Map).cast<String, Object?>();
    final file = ((offer['files']! as List).first as Map)
        .cast<String, Object?>();
    scheduleMicrotask(() {
      if (_incoming.isClosed) return;
      _incoming.add({
        'v': 1,
        'kind': 'transfer_file_complete',
        'transferId': offer['transferId'],
        'fileId': file['fileId'],
        'sha256': file['sha256'],
      });
    });
  }

  @override
  Future<void> close() => _incoming.close();
}

class _FallbackSourceReader implements PhoneTransferSourceReader {
  int stageCalls = 0;
  int hashCalls = 0;

  @override
  Future<void> cancelStage(String operationId) async {}

  @override
  Future<void> discard(String reference) async {}

  @override
  Future<void> release(String reference) async {}

  @override
  Future<void> retain(String reference) async {}

  @override
  Future<VidyutSourceProbe> probe(String uri) async =>
      const VidyutSourceProbe(seekable: false, size: -1, sizeKnown: false);

  @override
  Future<String> hashSha256(String uri) async {
    hashCalls++;
    return _fallbackDigest;
  }

  @override
  Future<VidyutStagedSource> stage(
    String uri, {
    required int maximumBytes,
    String? operationId,
  }) async {
    stageCalls++;
    return const VidyutStagedSource(
      reference: 'stage:fallback-1',
      size: 3,
      sha256: _fallbackDigest,
    );
  }

  @override
  Future<List<int>> readAt(
    String uri, {
    required int offset,
    required int length,
  }) => throw UnimplementedError();
}

class _CancellableStageReader implements PhoneTransferSourceReader {
  final _stageResult = Completer<VidyutStagedSource>();
  String? operationId;
  String? cancelledOperationId;

  @override
  Future<void> cancelStage(String operationId) async {
    cancelledOperationId = operationId;
    if (!_stageResult.isCompleted) {
      _stageResult.completeError(StateError('Source staging cancelled.'));
    }
  }

  @override
  Future<void> discard(String reference) async {}

  @override
  Future<void> release(String reference) async {}

  @override
  Future<void> retain(String reference) async {}

  @override
  Future<VidyutSourceProbe> probe(String uri) async =>
      const VidyutSourceProbe(seekable: false, size: -1, sizeKnown: false);

  @override
  Future<String> hashSha256(String uri) async => List.filled(64, 'a').join();

  @override
  Future<VidyutStagedSource> stage(
    String uri, {
    required int maximumBytes,
    String? operationId,
  }) {
    this.operationId = operationId;
    return _stageResult.future;
  }

  @override
  Future<List<int>> readAt(
    String uri, {
    required int offset,
    required int length,
  }) => throw UnimplementedError();
}

class _BlockingSourceReader implements PhoneTransferSourceReader {
  final _probeReady = Completer<void>();
  bool probeStarted = false;

  void releaseProbe() => _probeReady.complete();

  @override
  Future<void> cancelStage(String operationId) async {}

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
  Future<VidyutStagedSource> stage(
    String uri, {
    required int maximumBytes,
    String? operationId,
  }) => throw UnimplementedError();

  @override
  Future<List<int>> readAt(
    String uri, {
    required int offset,
    required int length,
  }) => throw UnimplementedError();
}

class _ImmediateSourceReader implements PhoneTransferSourceReader {
  @override
  Future<void> cancelStage(String operationId) async {}

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
  Future<VidyutStagedSource> stage(
    String uri, {
    required int maximumBytes,
    String? operationId,
  }) => throw UnimplementedError();

  @override
  Future<List<int>> readAt(
    String uri, {
    required int offset,
    required int length,
  }) => throw UnimplementedError();
}

class _GrantTrackingSourceReader implements PhoneTransferSourceReader {
  final retained = <String>[];
  final released = <String>[];

  @override
  Future<void> cancelStage(String operationId) async {}

  @override
  Future<void> discard(String reference) async {}

  @override
  Future<void> release(String reference) async => released.add(reference);

  @override
  Future<void> retain(String reference) async => retained.add(reference);

  @override
  Future<VidyutSourceProbe> probe(String uri) async =>
      const VidyutSourceProbe(seekable: true, size: 42, sizeKnown: true);

  @override
  Future<String> hashSha256(String uri) async => List.filled(64, 'b').join();

  @override
  Future<VidyutStagedSource> stage(
    String uri, {
    required int maximumBytes,
    String? operationId,
  }) => throw UnimplementedError();

  @override
  Future<List<int>> readAt(
    String uri, {
    required int offset,
    required int length,
  }) => throw UnimplementedError();
}
