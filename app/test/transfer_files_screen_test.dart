import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/design/theme.dart';
import 'package:vidyut/src/pairing/pairing_repository.dart';
import 'package:vidyut/src/transfer/phone_transfer_sender.dart';
import 'package:vidyut/src/transfer/transfer_files_screen.dart';
import 'package:vidyut/src/transfer/transfer_history.dart';
import 'package:vidyut_files/vidyut_files.dart';

void main() {
  group('TransferFilesScreen', () {
    testWidgets('renders the transfer summary and date-grouped history', (
      tester,
    ) async {
      final history = MemoryTransferHistoryStorage();
      await _seed(history, [
        _batch(
          filename: 'today.pdf',
          status: PhoneTransferStatus.completed,
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
        _batch(
          filename: 'yesterday.csv',
          status: PhoneTransferStatus.completed,
          createdAtMs: DateTime.now()
              .subtract(const Duration(days: 1))
              .millisecondsSinceEpoch,
        ),
      ]);

      await tester.pumpWidget(_screen(history));
      await tester.pumpAndSettle();

      expect(find.text('0 active'), findsOneWidget);
      expect(find.text('2 transfers'), findsOneWidget);
      expect(find.text('0 need attention'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Yesterday'), findsOneWidget);
      expect(find.text('today.pdf'), findsOneWidget);
      expect(find.text('yesterday.csv'), findsOneWidget);
    });

    testWidgets('active filter excludes waiting-for-source batches', (
      tester,
    ) async {
      final history = MemoryTransferHistoryStorage();
      await _seed(history, [
        _batch(
          filename: 'sending.zip',
          status: PhoneTransferStatus.active,
          createdAtMs: 2,
        ),
        _batch(
          filename: 'missing-source.zip',
          status: PhoneTransferStatus.waitingForSource,
          createdAtMs: 1,
        ),
      ]);

      await tester.pumpWidget(_screen(history));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Active'));
      await tester.pumpAndSettle();

      expect(find.text('sending.zip'), findsOneWidget);
      expect(find.text('missing-source.zip'), findsNothing);
    });

    testWidgets('offers cancellation for active history rows', (tester) async {
      final history = MemoryTransferHistoryStorage();
      await _seed(history, [
        _batch(
          filename: 'queued.zip',
          status: PhoneTransferStatus.queued,
          createdAtMs: 1,
        ),
      ]);

      await tester.pumpWidget(_screen(history));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Transfer actions'));
      await tester.pumpAndSettle();

      expect(find.text('Cancel transfer'), findsOneWidget);
      await tester.tap(find.text('Cancel transfer'));
      await tester.pumpAndSettle();

      final rows = await TransferHistoryRepository(history).load();
      expect(rows.single.status, PhoneTransferStatus.cancelled);
    });

    testWidgets('offers cancellation for waiting-for-source history rows', (
      tester,
    ) async {
      final history = MemoryTransferHistoryStorage();
      await _seed(history, [
        _batch(
          filename: 'blocked.zip',
          status: PhoneTransferStatus.waitingForSource,
          createdAtMs: 1,
        ),
      ]);

      await tester.pumpWidget(_screen(history));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Transfer actions'));
      await tester.pumpAndSettle();

      expect(find.text('Cancel transfer'), findsOneWidget);
      await tester.tap(find.text('Cancel transfer'));
      await tester.pumpAndSettle();

      final rows = await TransferHistoryRepository(history).load();
      expect(rows.single.status, PhoneTransferStatus.cancelled);
    });

    testWidgets('does not select waiting-for-source rows for bulk removal', (
      tester,
    ) async {
      final history = MemoryTransferHistoryStorage();
      await _seed(history, [
        _batch(
          filename: 'blocked.zip',
          status: PhoneTransferStatus.waitingForSource,
          createdAtMs: 1,
        ),
      ]);

      await tester.pumpWidget(_screen(history));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('blocked.zip'));
      await tester.pumpAndSettle();

      expect(find.text('1 selected'), findsNothing);
      expect(find.text('Remove from history (1)'), findsNothing);
    });

    testWidgets('does not offer cancellation for mixed-result batches', (
      tester,
    ) async {
      final history = MemoryTransferHistoryStorage();
      await _seed(history, [_mixedBatch()]);

      await tester.pumpWidget(_screen(history));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Transfer actions'));
      await tester.pumpAndSettle();

      expect(find.text('Cancel transfer'), findsNothing);
    });

    testWidgets('keeps other active rows visible beside live progress', (
      tester,
    ) async {
      final history = MemoryTransferHistoryStorage();
      await _seed(history, [
        _batch(
          filename: 'queued.zip',
          status: PhoneTransferStatus.queued,
          createdAtMs: 1,
        ),
      ]);
      final reader = _BlockingTransferSourceReader();
      final sender = PhoneTransferSender(
        pairingRepository: PairingRepository(MemoryPairingStorage()),
        connectionFactory: (_) => throw UnimplementedError(),
        history: TransferHistoryRepository(history),
        sourceReader: reader,
      );

      await tester.pumpWidget(_screen(history, sender: sender));
      await tester.pumpAndSettle();
      await sender.enqueue([
        const PhoneTransferSource(
          uri: 'content://provider/live-progress',
          filename: 'live.pdf',
          mime: 'application/pdf',
        ),
      ]);
      await tester.pump();

      expect(find.text('live.pdf'), findsWidgets);
      expect(find.text('queued.zip'), findsOneWidget);
      expect(find.text('Active'), findsWidgets);

      reader.releaseProbe();
      await tester.pump(const Duration(milliseconds: 20));
    });

    testWidgets(
      'live card shows preparation progress from preparation bytes',
      (tester) async {
        final history = MemoryTransferHistoryStorage();
        await _seed(history, [
          _batch(
            filename: 'previous.pdf',
            status: PhoneTransferStatus.completed,
            createdAtMs: 1,
          ),
        ]);
        final sender = _ProgressControlledSender(
          history: TransferHistoryRepository(history),
        );
        await tester.pumpWidget(_screen(history, sender: sender));
        await tester.pump();

        sender.emit(
          PhoneTransferProgress(
            stage: PhoneTransferProgressStage.hashing,
            fileCount: 1,
            totalBytes: 1000,
            transferredBytes: 0,
            currentFileIndex: 0,
            currentFilename: 'photo.jpg',
            preparedBytes: 25,
            preparationTotalBytes: 100,
            preparationStartedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        await tester.pump();

        expect(find.text('25%'), findsOneWidget);
        expect(find.text('25 B of 100 B'), findsOneWidget);
        expect(find.text('0 B of 1000 B'), findsNothing);
      },
    );

    testWidgets('opens completed batch details from its history row', (
      tester,
    ) async {      final history = MemoryTransferHistoryStorage();
      final opened = <PhoneTransferFile>[];
      final shared = <PhoneTransferFile>[];
      final resent = <PhoneTransferFile>[];
      await _seed(history, [
        _batch(
          filename: 'report.pdf',
          status: PhoneTransferStatus.completed,
          createdAtMs: 1,
          sourcePath: '/source',
        ),
      ]);

      await tester.pumpWidget(
        _screen(
          history,
          onOpenFile: (file) async => opened.add(file),
          onShareFile: (file) async => shared.add(file),
          onSendAgain: (file) async => resent.add(file),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('report.pdf'));
      await tester.pumpAndSettle();

      expect(find.text('Saved on your laptop'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);
      expect(find.text('Send again'), findsOneWidget);
      expect(find.text('Remove from history'), findsOneWidget);

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(opened.single.filename, 'report.pdf');
      expect(shared, isEmpty);
      expect(resent, isEmpty);
    });

    testWidgets('hides file actions for non-completed batches', (tester) async {
      final history = MemoryTransferHistoryStorage();
      await _seed(history, [
        _batch(
          filename: 'failed.pdf',
          status: PhoneTransferStatus.failed,
          createdAtMs: 1,
          sourcePath: '/source',
        ),
      ]);

      await tester.pumpWidget(
        _screen(
          history,
          onOpenFile: (_) async {},
          onShareFile: (_) async {},
          onSendAgain: (_) async {},
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('failed.pdf'));
      await tester.pumpAndSettle();

      expect(find.text('Open'), findsNothing);
      expect(find.text('Share'), findsNothing);
      expect(find.text('Send again'), findsNothing);
    });

    testWidgets(
      'reports file action failures after closing the details sheet',
      (tester) async {
        final history = MemoryTransferHistoryStorage();
        await _seed(history, [
          _batch(
            filename: 'broken.pdf',
            status: PhoneTransferStatus.completed,
            createdAtMs: 1,
            sourcePath: '/source',
          ),
        ]);

        await tester.pumpWidget(
          _screen(
            history,
            onOpenFile: (_) async => throw StateError('open failed'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('broken.pdf'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();

        expect(find.text('Open failed.'), findsOneWidget);
      },
    );

    testWidgets('exposes actions for every file in a completed batch', (
      tester,
    ) async {
      final history = MemoryTransferHistoryStorage();
      final shared = <PhoneTransferFile>[];
      await _seed(history, [
        _batch(
          filename: 'one.pdf',
          additionalFilenames: const ['two.pdf'],
          status: PhoneTransferStatus.completed,
          createdAtMs: 1,
          sourcePath: '/source',
        ),
      ]);

      await tester.pumpWidget(
        _screen(
          history,
          onOpenFile: (_) async {},
          onShareFile: (file) async => shared.add(file),
          onSendAgain: (_) async {},
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('2 files'));
      await tester.pumpAndSettle();

      expect(find.text('one.pdf'), findsOneWidget);
      expect(find.text('two.pdf'), findsOneWidget);
      expect(find.text('Open'), findsNWidgets(2));
      expect(find.text('Share'), findsNWidgets(2));
      expect(find.text('Send again'), findsNWidgets(2));

      await tester.tap(find.text('Share').last);
      await tester.pumpAndSettle();
      expect(shared.single.filename, 'two.pdf');
    });

    testWidgets('keeps completed files actionable in a mixed-result batch', (
      tester,
    ) async {
      final history = MemoryTransferHistoryStorage();
      await _seed(history, [_mixedBatch()]);

      await tester.pumpWidget(
        _screen(
          history,
          onOpenFile: (_) async {},
          onShareFile: (_) async {},
          onSendAgain: (_) async {},
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('2 files'));
      await tester.pumpAndSettle();

      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);
      expect(find.text('Send again'), findsOneWidget);
    });

    testWidgets('includes mixed-result batches in bulk history cleanup', (
      tester,
    ) async {
      final history = MemoryTransferHistoryStorage();
      await _seed(history, [_mixedBatch()]);

      await tester.pumpWidget(_screen(history));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('2 files'));
      await tester.pumpAndSettle();

      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(find.text('Remove from history (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();

      expect(find.text('2 files'), findsNothing);
    });

    testWidgets('hides ETA and speed after live transfer completion', (
      tester,
    ) async {
      final history = MemoryTransferHistoryStorage();
      final sender = _ProgressControlledSender(
        history: TransferHistoryRepository(history),
      );
      final live = _batch(
        filename: 'live.pdf',
        status: PhoneTransferStatus.queued,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      await _seed(history, [live]);

      await tester.pumpWidget(_screen(history, sender: sender));
      await tester.pumpAndSettle();
      sender.emitBatch(live);
      await tester.pump();
      sender.emit(
        const PhoneTransferProgress(
          stage: PhoneTransferProgressStage.completed,
          fileCount: 1,
          totalBytes: 1024,
          transferredBytes: 1024,
          currentFilename: 'live.pdf',
          transferId: 'transfer-live.pdf',
        ),
      );
      await tester.pump();

      expect(find.text('Transfer complete'), findsOneWidget);
      expect(find.text('Calculating time left'), findsNothing);
      expect(find.text('Measuring speed'), findsNothing);
    });

    testWidgets('hides live progress that does not match the active filter', (
      tester,
    ) async {
      final history = MemoryTransferHistoryStorage();
      final now = DateTime.now();
      final earlier = now.subtract(const Duration(days: 3));
      await _seed(history, [
        _batch(
          filename: 'older.pdf',
          status: PhoneTransferStatus.completed,
          createdAtMs: earlier.millisecondsSinceEpoch,
        ),
      ]);
      final sender = _ProgressControlledSender(
        history: TransferHistoryRepository(history),
      );
      await tester.pumpWidget(_screen(history, sender: sender));
      await tester.pumpAndSettle();

      final live = _batch(
        filename: 'live.pdf',
        status: PhoneTransferStatus.queued,
        createdAtMs: now.millisecondsSinceEpoch,
      );
      sender.emitBatch(live);
      await tester.pump();
      sender.emit(
        PhoneTransferProgress(
          stage: PhoneTransferProgressStage.preparing,
          fileCount: 1,
          totalBytes: 1000,
          transferredBytes: 0,
          currentFileIndex: 0,
          currentFilename: 'live.pdf',
          transferId: live.transferId,
          preparedBytes: 500,
          preparationTotalBytes: 1000,
        ),
      );
      await tester.pump();

      expect(find.text('older.pdf'), findsOneWidget);
      expect(find.text('Sending to your laptop'), findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Filter'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Earlier').last,
        100,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('Earlier').last);
      await tester.pumpAndSettle();

      expect(find.text('older.pdf'), findsOneWidget);
      expect(find.text('Sending to your laptop'), findsNothing);
    });

    testWidgets('supports multi-select history cleanup mode', (tester) async {
      final history = MemoryTransferHistoryStorage();
      await _seed(history, [
        _batch(
          filename: 'one.pdf',
          status: PhoneTransferStatus.completed,
          createdAtMs: 2,
        ),
        _batch(
          filename: 'two.pdf',
          status: PhoneTransferStatus.completed,
          createdAtMs: 1,
        ),
      ]);

      await tester.pumpWidget(_screen(history));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('one.pdf'));
      await tester.pumpAndSettle();

      expect(find.text('1 selected'), findsOneWidget);
      expect(find.text('Remove from history (1)'), findsOneWidget);

      await tester.tap(find.text('Remove from history (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Remove 1 transfer?'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();

      expect(find.text('one.pdf'), findsNothing);
      expect(find.text('two.pdf'), findsOneWidget);
    });

    testWidgets('offers date filters from the filter sheet', (tester) async {
      final history = MemoryTransferHistoryStorage();
      await _seed(history, [
        _batch(
          filename: 'today.pdf',
          status: PhoneTransferStatus.completed,
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      ]);

      await tester.pumpWidget(_screen(history));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Filter'));
      await tester.pumpAndSettle();

      expect(find.text('Today'), findsWidgets);
      expect(find.text('Yesterday'), findsOneWidget);
      expect(find.text('Earlier'), findsOneWidget);
    });
  });
}

Widget _screen(
  MemoryTransferHistoryStorage storage, {
  PhoneTransferSender? sender,
  Future<void> Function(PhoneTransferFile file)? onOpenFile,
  Future<void> Function(PhoneTransferFile file)? onShareFile,
  Future<void> Function(PhoneTransferFile file)? onSendAgain,
}) {
  return MaterialApp(
    theme: buildVidyutTheme(),
    home: TransferFilesScreen(
      history: TransferHistoryRepository(storage),
      sender:
          sender ??
          PhoneTransferSender(
            pairingRepository: PairingRepository(MemoryPairingStorage()),
            connectionFactory: (_) => throw UnimplementedError(),
            history: TransferHistoryRepository(storage),
          ),
      onOpenFile: onOpenFile,
      onShareFile: onShareFile,
      onSendAgain: onSendAgain,
    ),
  );
}

Future<void> _seed(
  MemoryTransferHistoryStorage storage,
  List<PhoneTransferBatch> batches,
) async {
  final repository = TransferHistoryRepository(storage);
  for (final batch in batches) {
    await repository.upsert(batch);
  }
}

PhoneTransferBatch _batch({
  required String filename,
  required PhoneTransferStatus status,
  required int createdAtMs,
  PhoneTransferDirection direction = PhoneTransferDirection.sent,
  String? sourcePath,
  List<String> additionalFilenames = const [],
}) {
  final filenames = [filename, ...additionalFilenames];
  return PhoneTransferBatch(
    transferId: 'transfer-$filename',
    batchId: 'batch-$filename',
    direction: direction,
    createdAtMs: createdAtMs,
    updatedAtMs: createdAtMs,
    status: status,
    files: filenames
        .map(
          (name) => PhoneTransferFile(
            fileId: 'file-$name',
            filename: name,
            mime: name.endsWith('.pdf') ? 'application/pdf' : 'text/csv',
            size: 1024,
            lastModifiedMs: createdAtMs,
            sha256: List.filled(64, 'a').join(),
            status: status,
            confirmedOffset: status == PhoneTransferStatus.completed ? 1024 : 0,
            sourcePath: sourcePath == null ? null : '$sourcePath/$name',
          ),
        )
        .toList(),
  );
}

PhoneTransferBatch _mixedBatch() {
  const createdAtMs = 1;
  return PhoneTransferBatch(
    transferId: 'transfer-mixed',
    batchId: 'batch-mixed',
    direction: PhoneTransferDirection.sent,
    createdAtMs: createdAtMs,
    updatedAtMs: createdAtMs,
    status: PhoneTransferStatus.completedWithIssues,
    files: [
      PhoneTransferFile(
        fileId: 'file-complete',
        filename: 'complete.pdf',
        mime: 'application/pdf',
        size: 1024,
        lastModifiedMs: createdAtMs,
        sha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        status: PhoneTransferStatus.completed,
        confirmedOffset: 1024,
        sourcePath: '/source/complete.pdf',
      ),
      PhoneTransferFile(
        fileId: 'file-failed',
        filename: 'failed.pdf',
        mime: 'application/pdf',
        size: 1024,
        lastModifiedMs: createdAtMs,
        sha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        status: PhoneTransferStatus.failed,
        confirmedOffset: 0,
      ),
    ],
  );
}

class _BlockingTransferSourceReader implements PhoneTransferSourceReader {
  final _probeReady = Completer<void>();

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
    await _probeReady.future;
    return const VidyutSourceProbe(seekable: true, size: 42, sizeKnown: true);
  }

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

class _ProgressControlledSender extends PhoneTransferSender {
  _ProgressControlledSender({required super.history})
    : super(
        pairingRepository: PairingRepository(MemoryPairingStorage()),
        connectionFactory: (_) => throw UnimplementedError(),
      );

  final _progressController =
      StreamController<PhoneTransferProgress>.broadcast();
  final _batchController = StreamController<PhoneTransferBatch>.broadcast();

  void emit(PhoneTransferProgress progress) =>
      _progressController.add(progress);

  void emitBatch(PhoneTransferBatch batch) => _batchController.add(batch);

  @override
  Stream<PhoneTransferProgress> get progress => _progressController.stream;

  @override
  Stream<PhoneTransferBatch> get batchesCreated => _batchController.stream;
}
