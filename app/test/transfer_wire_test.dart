import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/shared/wire.dart';

void main() {
  final file = <String, Object?>{
    'fileId': 'file_1234567890123',
    'filename': 'report.pdf',
    'mime': 'application/pdf',
    'size': 42,
    'lastModifiedMs': 1753689500000,
    'sha256': List.filled(64, 'a').join(),
  };
  final offer = <String, Object?>{
    'transferId': 'transfer_1234567890',
    'batchId': 'batch_123456789012',
    'origin': 'laptop',
    'direction': 'laptop_to_phone',
    'createdAtMs': 1753689600000,
    'files': [file],
  };

  group('transfer wire contract', () {
    test('round-trips a valid offer', () {
      final parsed = TransferOffer.fromJson(offer);

      expect(parsed.direction, TransferDirection.laptopToPhone);
      expect(parsed.files.single.filename, 'report.pdf');
      expect(parsed.toJson(), offer);
    });

    test('accepts empty files', () {
      final parsed = TransferOffer.fromJson({
        ...offer,
        'files': [
          {...file, 'size': 0},
        ],
      });

      expect(parsed.files.single.size, 0);
    });

    test('rejects traversal and duplicate ids', () {
      expect(
        () => TransferOffer.fromJson({
          ...offer,
          'files': [
            {...file, 'filename': '../secret'},
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => TransferOffer.fromJson({
          ...offer,
          'files': [
            {...file, 'filename': 'unsafe\u0000name.pdf'},
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => TransferOffer.fromJson({
          ...offer,
          'files': [
            {...file, 'filename': List.filled(128, 'é').join()},
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => TransferOffer.fromJson({
          ...offer,
          'files': [
            file,
            {...file, 'filename': 'copy.pdf'},
          ],
        }),
        throwsFormatException,
      );
    });

    test('rejects negative sizes and malformed hashes', () {
      expect(
        () => TransferOffer.fromJson({
          ...offer,
          'files': [
            {...file, 'size': -1},
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => TransferOffer.fromJson({
          ...offer,
          'files': [
            {...file, 'sha256': 'ABC'},
          ],
        }),
        throwsFormatException,
      );
    });
  });
}
