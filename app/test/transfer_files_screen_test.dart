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
      await _seed(history, [
        _batch(
          filename: 'report.pdf',
          status: PhoneTransferStatus.completed,
          createdAtMs: 1,
        ),
      ]);

      await tester.pumpWidget(_screen(history));
      await tester.pumpAndSettle();
      await tester.tap(find.text('report.pdf'));
      await tester.pumpAndSettle();

      expect(find.text('Saved on your laptop'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Show in folder'), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);
      expect(find.text('Send again'), findsOneWidget);
      expect(find.text('Remove from history'), findsOneWidget);
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

Widget _screen(MemoryTransferHistoryStorage storage) {
  return MaterialApp(
    theme: buildVidyutTheme(),
    home: TransferFilesScreen(
      history: TransferHistoryRepository(storage),
      sender: PhoneTransferSender(
        pairingRepository: PairingRepository(MemoryPairingStorage()),
        connectionFactory: (_) => throw UnimplementedError(),
        history: TransferHistoryRepository(storage),
      ),
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
}) {
  return PhoneTransferBatch(
    transferId: 'transfer-$filename',
    batchId: 'batch-$filename',
    direction: direction,
    createdAtMs: createdAtMs,
    updatedAtMs: createdAtMs,
    status: status,
    files: [
      PhoneTransferFile(
        fileId: 'file-$filename',
        filename: filename,
        mime: filename.endsWith('.pdf') ? 'application/pdf' : 'text/csv',
        size: 1024,
        lastModifiedMs: createdAtMs,
        sha256: List.filled(64, 'a').join(),
        status: status,
        confirmedOffset: status == PhoneTransferStatus.completed ? 1024 : 0,
      ),
    ],
  );
}
