import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/pairing/pairing_code.dart';
import 'package:vidyut/src/shared/relay_connection.dart';
import 'package:vidyut/src/shared/transfer_crypto.dart';
import 'package:vidyut/src/transfer/phone_transfer_receiver.dart';
import 'package:vidyut/src/transfer/transfer_history.dart';

void main() {
  test('downloads, verifies and records a laptop file', () async {
    final bytes = [1, 2, 3];
    final crypto = TransferCrypto(random: Random(7));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serving = server.listen((request) async {
      final segments = request.uri.pathSegments;
      final transferId = segments[2];
      final fileId = segments[3];
      final offset = int.parse(request.uri.queryParameters['offset']!);
      final encrypted = await crypto.encrypt(
        metadata: TransferChunkMetadata(
          transferId: transferId,
          fileId: fileId,
          offset: offset,
          plaintextBytes: bytes.length,
        ),
        plaintext: bytes,
        pairingSecret: 'pairing-secret',
      );
      request.response.headers
        ..set('x-vidyut-nonce', encrypted.nonce)
        ..set('x-vidyut-offset', '$offset')
        ..set('x-vidyut-plaintext-bytes', '${bytes.length}')
        ..set('x-vidyut-eof', 'true');
      request.response.add(encrypted.ciphertext);
      await request.response.close();
    });
    final root = await Directory.systemTemp.createTemp('vidyut-phone-receive-');
    final history = TransferHistoryRepository(MemoryTransferHistoryStorage());
    final transport = _ReceiverTransport();
    final pairing = PairingCode(
      host: '127.0.0.1',
      port: server.port,
      secret: 'pairing-secret',
    );
    final connection = RelayConnection(
      pairing: pairing,
      deviceId: 'phone',
      transport: transport,
    );
    final receiver = PhoneTransferReceiver(
      history: history,
      crypto: crypto,
      rootDirectory: () async => root,
    );
    receiver.start(connection, pairing);
    await connection.start();
    transport.receive({
      'v': 1,
      'kind': 'transfer_offer',
      'offer': {
        'transferId': 'transfer_1234567890',
        'batchId': 'batch_123456789012',
        'origin': 'laptop',
        'direction': 'laptop_to_phone',
        'createdAtMs': 1753689600000,
        'files': [
          {
            'fileId': 'file_1234567890123',
            'filename': 'report.bin',
            'mime': 'application/octet-stream',
            'size': bytes.length,
            'lastModifiedMs': 1753689500000,
            'sha256':
                '039058c6f2c0cb492c533b0a4d14ef77'
                'cc0f78abccced5287d84a1a2011cfb81',
          },
        ],
      },
    });

    await _waitUntil(() async {
      final batches = await history.load();
      return batches.isNotEmpty &&
          batches.single.status == PhoneTransferStatus.completed;
    });

    expect(await File('${root.path}/report.bin').readAsBytes(), bytes);
    expect(
      transport.sent.map((message) => message['kind']),
      containsAll([
        'transfer_accept',
        'transfer_progress',
        'transfer_file_complete',
      ]),
    );
    await receiver.dispose();
    await connection.close();
    await server.close(force: true);
    await serving.cancel();
    await root.delete(recursive: true);
  });
}

class _ReceiverTransport implements RelayTransport {
  final _incoming = StreamController<Object?>();
  final sent = <Map<String, Object?>>[];

  void receive(Map<String, Object?> message) => _incoming.add(message);

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  Stream<Object?> get messages => _incoming.stream;

  @override
  void send(Map<String, Object?> message) => sent.add(message);

  @override
  Future<void> close() => _incoming.close();
}

Future<void> _waitUntil(Future<bool> Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw TimeoutException('Receiver did not finish.');
}
