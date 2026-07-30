import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/pairing/pairing_code.dart';
import 'package:vidyut/src/pairing/pairing_repository.dart';
import 'package:vidyut/src/shared/relay_connection.dart';
import 'package:vidyut/src/transfer/transfer_chunk_policy.dart';
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
    final progress = <PhoneTransferProgress>[];
    final progressSubscription = sender.progress.listen(progress.add);

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
    await Future<void>.delayed(Duration.zero);
    expect(
      progress.map((event) => event.stage),
      containsAllInOrder([
        PhoneTransferProgressStage.preparing,
        PhoneTransferProgressStage.connecting,
        PhoneTransferProgressStage.waitingForLaptop,
        PhoneTransferProgressStage.transferring,
        PhoneTransferProgressStage.completed,
      ]),
    );
    expect(
      progress
          .where(
            (event) => event.stage == PhoneTransferProgressStage.transferring,
          )
          .last
          .transferredBytes,
      3,
    );
    await progressSubscription.cancel();
    await server.close(force: true);
    await serving.cancel();
    await directory.delete(recursive: true);
  });

  test(
    'accepts verified completion without re-uploading an empty file',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requestCount = 0;
      final serving = server.listen((request) async {
        requestCount += 1;
        await request.drain<void>();
        request.response.statusCode = 500;
        await request.response.close();
      });
      final directory = await Directory.systemTemp.createTemp(
        'vidyut-phone-empty-resume-',
      );
      try {
        final source = File('${directory.path}/empty.bin');
        await source.writeAsBytes([]);
        final pairingRepository = PairingRepository(MemoryPairingStorage());
        await pairingRepository.save(
          PairingCode(
            host: '127.0.0.1',
            port: server.port,
            secret: 'pairing-secret',
          ),
        );
        final sender = PhoneTransferSender(
          pairingRepository: pairingRepository,
          connectionFactory: (pairing) => RelayConnection(
            pairing: pairing,
            deviceId: 'phone',
            transport: _CompletedTransferTransport(),
          ),
          history: TransferHistoryRepository(MemoryTransferHistoryStorage()),
        );

        final result = await sender.enqueue([
          PhoneTransferSource(
            path: source.path,
            filename: 'empty.bin',
            mime: 'application/octet-stream',
          ),
        ]);

        expect(result.status, PhoneTransferStatus.completed);
        expect(result.files.single.confirmedOffset, 0);
        expect(requestCount, 0);
      } finally {
        await server.close(force: true);
        await serving.cancel();
        await directory.delete(recursive: true);
      }
    },
  );

  test('accepts verified completion after the source is removed', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requestCount = 0;
    final serving = server.listen((request) async {
      requestCount += 1;
      await request.drain<void>();
      request.response.statusCode = 500;
      await request.response.close();
    });
    final directory = await Directory.systemTemp.createTemp(
      'vidyut-phone-complete-no-source-',
    );
    try {
      final source = File('${directory.path}/moved.bin');
      await source.writeAsBytes([1, 2, 3]);
      final pairingRepository = PairingRepository(MemoryPairingStorage());
      await pairingRepository.save(
        PairingCode(
          host: '127.0.0.1',
          port: server.port,
          secret: 'pairing-secret',
        ),
      );
      final sender = PhoneTransferSender(
        pairingRepository: pairingRepository,
        connectionFactory: (pairing) => RelayConnection(
          pairing: pairing,
          deviceId: 'phone',
          transport: _CompletedTransferTransport(
            onOffer: () async {
              await source.delete();
            },
          ),
        ),
        history: TransferHistoryRepository(MemoryTransferHistoryStorage()),
      );

      final result = await sender.enqueue([
        PhoneTransferSource(
          path: source.path,
          filename: 'moved.bin',
          mime: 'application/octet-stream',
        ),
      ]);

      expect(result.status, PhoneTransferStatus.completed);
      expect(await source.exists(), isFalse);
      expect(requestCount, 0);
    } finally {
      await server.close(force: true);
      await serving.cancel();
      await directory.delete(recursive: true);
    }
  });

  test('fails immediately when the laptop rejects an offered file', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requestCount = 0;
    final serving = server.listen((request) async {
      requestCount += 1;
      await request.drain<void>();
      request.response.statusCode = 500;
      await request.response.close();
    });
    final directory = await Directory.systemTemp.createTemp(
      'vidyut-phone-rejected-',
    );
    try {
      final source = File('${directory.path}/rejected.bin');
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
      final sender = PhoneTransferSender(
        pairingRepository: pairingRepository,
        connectionFactory: (pairing) => RelayConnection(
          pairing: pairing,
          deviceId: 'phone',
          transport: _RejectedTransferTransport('insufficient_storage'),
        ),
        history: history,
      );

      await expectLater(
        sender.enqueue([
          PhoneTransferSource(
            path: source.path,
            filename: 'rejected.bin',
            mime: 'application/octet-stream',
          ),
        ]),
        throwsA(
          predicate(
            (error) => error.toString().contains('insufficient_storage'),
          ),
        ),
      );

      expect(requestCount, 0);
      expect(
        (await history.load()).single.files.single.errorCode,
        'insufficient_storage',
      );
    } finally {
      await server.close(force: true);
      await serving.cancel();
      await directory.delete(recursive: true);
    }
  });

  test('retries HTTP 503 responses through a fresh session', () async {
    var requestCount = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serving = server.listen((request) async {
      requestCount += 1;
      await request.drain<void>();
      request.response.headers.contentType = ContentType.json;
      if (requestCount == 1) {
        request.response
          ..statusCode = 503
          ..write(jsonEncode({'code': 'relay_restarting'}));
      } else {
        request.response
          ..statusCode = 200
          ..write(jsonEncode({'confirmedOffset': 3, 'complete': true}));
      }
      await request.response.close();
    });
    final directory = await Directory.systemTemp.createTemp(
      'vidyut-phone-http-retry-',
    );
    try {
      final source = File('${directory.path}/retry.bin');
      await source.writeAsBytes([1, 2, 3]);
      final pairingRepository = PairingRepository(MemoryPairingStorage());
      await pairingRepository.save(
        PairingCode(
          host: '127.0.0.1',
          port: server.port,
          secret: 'pairing-secret',
        ),
      );
      var connectionCount = 0;
      final sender = PhoneTransferSender(
        pairingRepository: pairingRepository,
        connectionFactory: (pairing) {
          connectionCount += 1;
          return RelayConnection(
            pairing: pairing,
            deviceId: 'phone',
            transport: _ScriptedTransferTransport(),
          );
        },
        history: TransferHistoryRepository(MemoryTransferHistoryStorage()),
        chunkBytes: 3,
        reconnectBackoff: const [Duration.zero],
      );

      final result = await sender.enqueue([
        PhoneTransferSource(
          path: source.path,
          filename: 'retry.bin',
          mime: 'application/octet-stream',
        ),
      ]);

      expect(result.status, PhoneTransferStatus.completed);
      expect(requestCount, 2);
      expect(connectionCount, 2);
    } finally {
      await server.close(force: true);
      await serving.cancel();
      await directory.delete(recursive: true);
    }
  });

  test('rejects a non-advancing offset conflict without looping', () async {
    var requestCount = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serving = server.listen((request) async {
      requestCount += 1;
      await request.drain<void>();
      request.response
        ..statusCode = 409
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({'code': 'offset_not_confirmed', 'confirmedOffset': 0}),
        );
      await request.response.close();
    });
    final directory = await Directory.systemTemp.createTemp(
      'vidyut-phone-offset-stall-',
    );
    try {
      final source = File('${directory.path}/offset.bin');
      await source.writeAsBytes([1, 2, 3]);
      final pairingRepository = PairingRepository(MemoryPairingStorage());
      await pairingRepository.save(
        PairingCode(
          host: '127.0.0.1',
          port: server.port,
          secret: 'pairing-secret',
        ),
      );
      final sender = PhoneTransferSender(
        pairingRepository: pairingRepository,
        connectionFactory: (pairing) => RelayConnection(
          pairing: pairing,
          deviceId: 'phone',
          transport: _ScriptedTransferTransport(),
        ),
        history: TransferHistoryRepository(MemoryTransferHistoryStorage()),
        chunkBytes: 3,
      );

      await expectLater(
        sender.enqueue([
          PhoneTransferSource(
            path: source.path,
            filename: 'offset.bin',
            mime: 'application/octet-stream',
          ),
        ]),
        throwsA(isA<StateError>()),
      );

      expect(requestCount, 1);
    } finally {
      await server.close(force: true);
      await serving.cancel();
      await directory.delete(recursive: true);
    }
  });

  test('waits for verification after a full-size offset conflict', () async {
    var requestCount = 0;
    late _FinalizingTransferTransport transport;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serving = server.listen((request) async {
      requestCount += 1;
      await request.drain<void>();
      request.response
        ..statusCode = 409
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({'code': 'offset_not_confirmed', 'confirmedOffset': 3}),
        );
      await request.response.close();
      scheduleMicrotask(transport.complete);
    });
    final directory = await Directory.systemTemp.createTemp(
      'vidyut-phone-finalizing-',
    );
    try {
      final source = File('${directory.path}/finalizing.bin');
      await source.writeAsBytes([1, 2, 3]);
      final pairingRepository = PairingRepository(MemoryPairingStorage());
      await pairingRepository.save(
        PairingCode(
          host: '127.0.0.1',
          port: server.port,
          secret: 'pairing-secret',
        ),
      );
      final sender = PhoneTransferSender(
        pairingRepository: pairingRepository,
        connectionFactory: (pairing) {
          transport = _FinalizingTransferTransport();
          return RelayConnection(
            pairing: pairing,
            deviceId: 'phone',
            transport: transport,
          );
        },
        history: TransferHistoryRepository(MemoryTransferHistoryStorage()),
        chunkBytes: 3,
      );

      final result = await sender.enqueue([
        PhoneTransferSource(
          path: source.path,
          filename: 'finalizing.bin',
          mime: 'application/octet-stream',
        ),
      ]);

      expect(result.status, PhoneTransferStatus.completed);
      expect(requestCount, 1);
    } finally {
      await server.close(force: true);
      await serving.cancel();
      await directory.delete(recursive: true);
    }
  });

  test(
    'falls back to legacy chunks when the relay omits negotiation',
    () async {
      final chunks = await _sendChunkedFile(advertisedChunkBytes: null);

      expect(chunks, [TransferChunkPolicy.legacyBytes, 44 * 1024]);
    },
  );

  test('uses the larger chunk advertised by an upgraded relay', () async {
    final chunks = await _sendChunkedFile(
      advertisedChunkBytes: TransferChunkPolicy.preferredBytes,
    );

    expect(chunks, [300 * 1024]);
  });

  test('reconnects and resumes after a transient HTTP interruption', () async {
    var confirmedOffset = 0;
    var requestCount = 0;
    final requestOffsets = <int>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serving = server.listen((request) async {
      requestCount += 1;
      final offset = int.parse(request.uri.queryParameters['offset']!);
      final plaintextBytes = int.parse(
        request.headers.value('x-vidyut-plaintext-bytes')!,
      );
      requestOffsets.add(offset);
      await request.drain<void>();
      if (offset != confirmedOffset) {
        request.response
          ..statusCode = 409
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'code': 'offset_not_confirmed',
              'confirmedOffset': confirmedOffset,
            }),
          );
        await request.response.close();
        return;
      }
      if (requestCount == 2) {
        confirmedOffset = offset + plaintextBytes;
        final socket = await request.response.detachSocket();
        socket.destroy();
        return;
      }
      confirmedOffset = offset + plaintextBytes;
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'confirmedOffset': confirmedOffset,
            'complete': confirmedOffset == 9,
          }),
        );
      await request.response.close();
    });
    final directory = await Directory.systemTemp.createTemp(
      'vidyut-phone-resume-',
    );
    try {
      final source = File('${directory.path}/resume.bin');
      await source.writeAsBytes(List<int>.filled(9, 7));
      final pairingRepository = PairingRepository(MemoryPairingStorage());
      await pairingRepository.save(
        PairingCode(
          host: '127.0.0.1',
          port: server.port,
          secret: 'pairing-secret',
        ),
      );
      final transports = <_ScriptedTransferTransport>[];
      final sender = PhoneTransferSender(
        pairingRepository: pairingRepository,
        connectionFactory: (pairing) {
          final acceptedOffset = transports.isEmpty ? 0 : 3;
          final transport = _ScriptedTransferTransport(
            confirmedOffset: () => acceptedOffset,
          );
          transports.add(transport);
          return RelayConnection(
            pairing: pairing,
            deviceId: 'phone',
            transport: transport,
          );
        },
        history: TransferHistoryRepository(MemoryTransferHistoryStorage()),
        chunkBytes: 3,
        reconnectBackoff: const [Duration.zero],
      );

      final result = await sender.enqueue([
        PhoneTransferSource(
          path: source.path,
          filename: 'resume.bin',
          mime: 'application/octet-stream',
        ),
      ]);

      expect(result.status, PhoneTransferStatus.completed);
      expect(result.files.single.confirmedOffset, 9);
      expect(transports, hasLength(2));
      expect(requestOffsets, [0, 3, 3, 6]);
    } finally {
      await server.close(force: true);
      await serving.cancel();
      await directory.delete(recursive: true);
    }
  });

  test('reconnects when the relay drops before initial acceptance', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serving = server.listen((request) async {
      await request.drain<void>();
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'confirmedOffset': 3, 'complete': true}));
      await request.response.close();
    });
    final directory = await Directory.systemTemp.createTemp(
      'vidyut-phone-accept-resume-',
    );
    try {
      final source = File('${directory.path}/accept.bin');
      await source.writeAsBytes([1, 2, 3]);
      final pairingRepository = PairingRepository(MemoryPairingStorage());
      await pairingRepository.save(
        PairingCode(
          host: '127.0.0.1',
          port: server.port,
          secret: 'pairing-secret',
        ),
      );
      var connectionCount = 0;
      final sender = PhoneTransferSender(
        pairingRepository: pairingRepository,
        connectionFactory: (pairing) {
          connectionCount += 1;
          return RelayConnection(
            pairing: pairing,
            deviceId: 'phone',
            transport: connectionCount == 1
                ? _DisconnectBeforeAcceptanceTransport()
                : _ScriptedTransferTransport(),
          );
        },
        history: TransferHistoryRepository(MemoryTransferHistoryStorage()),
        chunkBytes: 3,
        reconnectBackoff: const [Duration.zero],
      );

      final result = await sender.enqueue([
        PhoneTransferSource(
          path: source.path,
          filename: 'accept.bin',
          mime: 'application/octet-stream',
        ),
      ]);

      expect(result.status, PhoneTransferStatus.completed);
      expect(connectionCount, 2);
    } finally {
      await server.close(force: true);
      await serving.cancel();
      await directory.delete(recursive: true);
    }
  });
}

class _ScriptedTransferTransport implements RelayTransport {
  _ScriptedTransferTransport({this.maxChunkBytes, this.confirmedOffset}) {
    scheduleMicrotask(() => _incoming.add({'v': 1, 'kind': 'auth_ok'}));
  }

  final int? maxChunkBytes;
  final int Function()? confirmedOffset;
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
        'confirmedOffset': confirmedOffset?.call() ?? 0,
        if (maxChunkBytes != null) 'maxChunkBytes': maxChunkBytes,
      }),
    );
  }

  @override
  Future<void> close() => _incoming.close();
}

class _CompletedTransferTransport implements RelayTransport {
  _CompletedTransferTransport({this.onOffer}) {
    scheduleMicrotask(() => _incoming.add({'v': 1, 'kind': 'auth_ok'}));
  }

  final Future<void> Function()? onOffer;
  final _incoming = StreamController<Object?>();

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  Stream<Object?> get messages => _incoming.stream;

  @override
  void send(Map<String, Object?> message) {
    if (message['kind'] != 'transfer_offer') return;
    final offer = (message['offer']! as Map).cast<String, Object?>();
    final file = ((offer['files']! as List).first as Map)
        .cast<String, Object?>();
    scheduleMicrotask(() async {
      await onOffer?.call();
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

class _FinalizingTransferTransport implements RelayTransport {
  _FinalizingTransferTransport() {
    scheduleMicrotask(() => _incoming.add({'v': 1, 'kind': 'auth_ok'}));
  }

  final _incoming = StreamController<Object?>();
  Map<String, Object?>? _offer;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  Stream<Object?> get messages => _incoming.stream;

  @override
  void send(Map<String, Object?> message) {
    if (message['kind'] != 'transfer_offer') return;
    _offer = (message['offer']! as Map).cast<String, Object?>();
    final file = ((_offer!['files']! as List).first as Map)
        .cast<String, Object?>();
    scheduleMicrotask(
      () => _incoming.add({
        'v': 1,
        'kind': 'transfer_accept',
        'transferId': _offer!['transferId'],
        'fileId': file['fileId'],
        'confirmedOffset': 0,
      }),
    );
  }

  void complete() {
    final offer = _offer!;
    final file = ((offer['files']! as List).first as Map)
        .cast<String, Object?>();
    _incoming.add({
      'v': 1,
      'kind': 'transfer_file_complete',
      'transferId': offer['transferId'],
      'fileId': file['fileId'],
      'sha256': file['sha256'],
    });
  }

  @override
  Future<void> close() => _incoming.close();
}

class _RejectedTransferTransport implements RelayTransport {
  _RejectedTransferTransport(this.code) {
    scheduleMicrotask(() => _incoming.add({'v': 1, 'kind': 'auth_ok'}));
  }

  final String code;
  final _incoming = StreamController<Object?>();

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  Stream<Object?> get messages => _incoming.stream;

  @override
  void send(Map<String, Object?> message) {
    if (message['kind'] != 'transfer_offer') return;
    final offer = (message['offer']! as Map).cast<String, Object?>();
    final file = ((offer['files']! as List).first as Map)
        .cast<String, Object?>();
    scheduleMicrotask(
      () => _incoming.add({
        'v': 1,
        'kind': 'transfer_file_failed',
        'transferId': offer['transferId'],
        'fileId': file['fileId'],
        'code': code,
      }),
    );
  }

  @override
  Future<void> close() => _incoming.close();
}

class _DisconnectBeforeAcceptanceTransport implements RelayTransport {
  _DisconnectBeforeAcceptanceTransport() {
    scheduleMicrotask(() => _incoming.add({'v': 1, 'kind': 'auth_ok'}));
  }

  final _incoming = StreamController<Object?>();
  bool _closed = false;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  Stream<Object?> get messages => _incoming.stream;

  @override
  void send(Map<String, Object?> message) {
    if (message['kind'] == 'transfer_offer') {
      scheduleMicrotask(close);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _incoming.close();
  }
}

Future<List<int>> _sendChunkedFile({required int? advertisedChunkBytes}) async {
  const fileBytes = 300 * 1024;
  final chunks = <int>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final serving = server.listen((request) async {
    final offset = int.parse(request.uri.queryParameters['offset']!);
    final plaintextBytes = int.parse(
      request.headers.value('x-vidyut-plaintext-bytes')!,
    );
    chunks.add(plaintextBytes);
    await request.drain<void>();
    final confirmedOffset = offset + plaintextBytes;
    request.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(
        jsonEncode({
          'confirmedOffset': confirmedOffset,
          'complete': confirmedOffset == fileBytes,
        }),
      );
    await request.response.close();
  });
  final directory = await Directory.systemTemp.createTemp(
    'vidyut-phone-chunks-',
  );
  try {
    final source = File('${directory.path}/large.bin');
    await source.writeAsBytes(List<int>.filled(fileBytes, 7));
    final pairingRepository = PairingRepository(MemoryPairingStorage());
    await pairingRepository.save(
      PairingCode(
        host: '127.0.0.1',
        port: server.port,
        secret: 'pairing-secret',
      ),
    );
    final sender = PhoneTransferSender(
      pairingRepository: pairingRepository,
      connectionFactory: (pairing) => RelayConnection(
        pairing: pairing,
        deviceId: 'phone',
        transport: _ScriptedTransferTransport(
          maxChunkBytes: advertisedChunkBytes,
        ),
      ),
      history: TransferHistoryRepository(MemoryTransferHistoryStorage()),
    );

    await sender.enqueue([
      PhoneTransferSource(
        path: source.path,
        filename: 'large.bin',
        mime: 'application/octet-stream',
      ),
    ]);
    return chunks;
  } finally {
    await server.close(force: true);
    await serving.cancel();
    await directory.delete(recursive: true);
  }
}
