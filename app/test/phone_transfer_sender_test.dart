import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/pairing/pairing_code.dart';
import 'package:vidyut/src/pairing/pairing_repository.dart';
import 'package:vidyut/src/shared/relay_connection.dart';
import 'package:vidyut/src/transfer/phone_transfer_sender.dart';
import 'package:vidyut/src/transfer/transfer_history.dart';

void main() {
  test('rejects sending when the active network policy disallows it', () async {
    final sender = PhoneTransferSender(
      pairingRepository: PairingRepository(MemoryPairingStorage()),
      connectionFactory: (_) => throw UnimplementedError(),
      history: TransferHistoryRepository(MemoryTransferHistoryStorage()),
      networkAllowed: () async => false,
    );

    await expectLater(
      sender.enqueue([
        const PhoneTransferSource(
          path: '/unused',
          filename: 'report.bin',
          mime: 'application/octet-stream',
        ),
      ]),
      throwsA(isA<StateError>()),
    );
  });

  test('offers and uploads a file while persisting progress history', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <HttpRequest>[];
    final serving = server.listen((request) async {
      requests.add(request);
      await request.drain<void>();
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'confirmedOffset': 3, 'complete': true}));
      await request.response.close();
    });
    final directory = await Directory.systemTemp.createTemp(
      'vidyut-phone-send-',
    );
    final source = File('${directory.path}/report.bin');
    await source.writeAsBytes([1, 2, 3]);
    final pairingRepository = PairingRepository(MemoryPairingStorage());
    await pairingRepository.save(
      PairingCode(
        host: '127.0.0.1',
        port: server.port,
        secret: 'pairing-secret',
      ),
    );
    final history = TransferHistoryRepository(MemoryTransferHistoryStorage());
    final transports = <_ScriptedTransferTransport>[];
    final sender = PhoneTransferSender(
      pairingRepository: pairingRepository,
      connectionFactory: (pairing) {
        final transport = _ScriptedTransferTransport();
        transports.add(transport);
        return RelayConnection(
          pairing: pairing,
          deviceId: 'phone',
          transport: transport,
        );
      },
      history: history,
      chunkBytes: 4,
    );

    final result = await sender.enqueue([
      PhoneTransferSource(
        path: source.path,
        filename: 'report.bin',
        mime: 'application/octet-stream',
      ),
    ]);

    expect(result.status, PhoneTransferStatus.completed);
    expect(result.files.single.confirmedOffset, 3);
    expect((await history.load()).single.status, PhoneTransferStatus.completed);
    expect(requests, hasLength(1));
    expect(requests.single.method, 'PUT');
    expect(
      requests.single.headers.value('authorization'),
      startsWith('Vidyut '),
    );
    expect(
      transports.single.sent.any(
        (message) => message['kind'] == 'transfer_offer',
      ),
      isTrue,
    );
    await server.close(force: true);
    await serving.cancel();
    await directory.delete(recursive: true);
  });
}

class _ScriptedTransferTransport implements RelayTransport {
  _ScriptedTransferTransport() {
    scheduleMicrotask(() => _incoming.add({'v': 1, 'kind': 'auth_ok'}));
  }

  final _incoming = StreamController<Object?>();
  final sent = <Map<String, Object?>>[];

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  Stream<Object?> get messages => _incoming.stream;

  @override
  void send(Map<String, Object?> message) {
    sent.add(message);
    if (message['kind'] != 'transfer_offer') return;
    final offer = (message['offer']! as Map).cast<String, Object?>();
    final file = ((offer['files']! as List).first as Map)
        .cast<String, Object?>();
    scheduleMicrotask(
      () => _incoming.add({
        'v': 1,
        'kind': 'transfer_accept',
        'transferId': offer['transferId'],
        'fileId': file['fileId'],
        'confirmedOffset': 0,
      }),
    );
  }

  @override
  Future<void> close() => _incoming.close();
}
