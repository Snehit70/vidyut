import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/transfer/transfer_file_actions.dart';
import 'package:vidyut/src/transfer/transfer_history.dart';

void main() {
  test('prefers the finalized destination for received files', () {
    final file = _file(
      filename: 'report.pdf',
      sourcePath: '/app/cache/report.partial',
      destinationPath: '/app/files/vidyut_received/report.pdf',
    );

    expect(transferFileActionTarget(file), {
      'path': '/app/files/vidyut_received/report.pdf',
      'filename': 'report.pdf',
      'mime': 'application/pdf',
    });
  });

  test('preserves durable document URIs for Android actions', () {
    final file = _file(
      filename: 'cloud.pdf',
      sourceReference: const PhoneTransferSourceReference(
        kind: PhoneTransferSourceKind.androidDocumentUri,
        reference: 'content://provider/document/42',
        ownership: PhoneTransferSourceOwnership.external,
        persisted: true,
      ),
    );

    expect(transferFileActionTarget(file), {
      'uri': 'content://provider/document/42',
      'filename': 'cloud.pdf',
      'mime': 'application/pdf',
    });
  });

  test('uses a received content destination as the action URI', () {
    final file = _file(
      filename: 'received.pdf',
      destinationPath: 'content://media/external/downloads/42',
      sourceReference: const PhoneTransferSourceReference(
        kind: PhoneTransferSourceKind.androidDocumentUri,
        reference: 'content://tree/source/document/17',
        ownership: PhoneTransferSourceOwnership.external,
        persisted: true,
      ),
    );

    expect(transferFileActionTarget(file), {
      'uri': 'content://media/external/downloads/42',
      'filename': 'received.pdf',
      'mime': 'application/pdf',
    });
  });

  test('accepts arbitrary shared-intake paths for provider staging', () {
    final file = _file(
      filename: 'shared.pdf',
      sourcePath: '/storage/emulated/0/Download/shared.pdf',
    );

    expect(transferFileActionAvailable(file), isTrue);
  });
}

PhoneTransferFile _file({
  required String filename,
  String? sourcePath,
  String? destinationPath,
  PhoneTransferSourceReference? sourceReference,
}) {
  return PhoneTransferFile(
    fileId: 'file-1',
    filename: filename,
    mime: 'application/pdf',
    size: 42,
    lastModifiedMs: 1,
    sha256: List.filled(64, 'a').join(),
    status: PhoneTransferStatus.completed,
    confirmedOffset: 42,
    sourcePath: sourcePath,
    destinationPath: destinationPath,
    sourceReference: sourceReference,
  );
}
