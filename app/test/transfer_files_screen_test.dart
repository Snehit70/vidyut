import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/design/theme.dart';
import 'package:vidyut/src/pairing/pairing_repository.dart';
import 'package:vidyut/src/transfer/phone_transfer_sender.dart';
import 'package:vidyut/src/transfer/transfer_files_screen.dart';
import 'package:vidyut/src/transfer/transfer_history.dart';

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

    testWidgets('opens completed batch details from its history row', (
      tester,
    ) async {
      final history = MemoryTransferHistoryStorage();
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
      expect(find.text('Remove 1 transfers?'), findsOneWidget);

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
  Future<void> Function(PhoneTransferFile file)? onOpenFile,
  Future<void> Function(PhoneTransferFile file)? onShareFile,
  Future<void> Function(PhoneTransferFile file)? onSendAgain,
}) {
  return MaterialApp(
    theme: buildVidyutTheme(),
    home: TransferFilesScreen(
      history: TransferHistoryRepository(storage),
      sender: PhoneTransferSender(
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
