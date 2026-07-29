import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as hashes;

import '../pairing/pairing_code.dart';
import '../pairing/pairing_repository.dart';
import '../shared/relay_connection.dart';
import '../shared/transfer_crypto.dart';
import '../shared/transfer_http_auth.dart';
import 'transfer_history.dart';

class PhoneTransferSource {
  const PhoneTransferSource({
    required this.path,
    required this.filename,
    required this.mime,
  });

  final String path;
  final String filename;
  final String mime;
}

typedef TransferRelayConnectionFactory =
    RelayConnection Function(PairingCode pairing);

class PhoneTransferSender {
  PhoneTransferSender({
    required this.pairingRepository,
    required this.connectionFactory,
    required this.history,
    TransferCrypto? crypto,
    Random? random,
    this.chunkBytes = 256 * 1024,
    this.maximumFileBytes,
    this.networkAllowed,
  }) : crypto = crypto ?? TransferCrypto(),
       _random = random ?? Random.secure();

  final PairingRepository pairingRepository;
  final TransferRelayConnectionFactory connectionFactory;
  final TransferHistoryRepository history;
  final TransferCrypto crypto;
  final Random _random;
  final int chunkBytes;
  final Future<int> Function()? maximumFileBytes;
  final Future<bool> Function()? networkAllowed;

  Future<PhoneTransferBatch> enqueue(List<PhoneTransferSource> sources) async {
    if (sources.isEmpty) {
      throw const FormatException('Select at least one file.');
    }
    if (networkAllowed != null && !await networkAllowed!()) {
      throw StateError('File transfers are disabled on this metered network.');
    }
    final pairing = await pairingRepository.load();
    if (pairing == null) {
      throw StateError('Pair with a laptop before sending files.');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final files = <PhoneTransferFile>[];
    final maxBytes = maximumFileBytes == null
        ? 1024 * 1024 * 1024
        : await maximumFileBytes!();
    for (final source in sources) {
      final file = File(source.path);
      final info = await file.stat();
      if (info.type != FileSystemEntityType.file) {
        throw FormatException('Only regular files can be sent: ${source.path}');
      }
      if (info.size > maxBytes) {
        throw FormatException(
          '${source.filename} exceeds the configured maximum file size.',
        );
      }
      files.add(
        PhoneTransferFile(
          fileId: _id('file'),
          filename: _safeBasename(source.filename),
          mime: source.mime,
          size: info.size,
          lastModifiedMs: info.modified.millisecondsSinceEpoch,
          sha256: await _hashFile(file),
          status: PhoneTransferStatus.queued,
          confirmedOffset: 0,
          sourcePath: source.path,
        ),
      );
    }
    final batch = PhoneTransferBatch(
      transferId: _id('transfer'),
      batchId: _id('batch'),
      direction: PhoneTransferDirection.sent,
      createdAtMs: now,
      updatedAtMs: now,
      status: PhoneTransferStatus.queued,
      files: files,
    );
    await history.upsert(batch);
    return _send(pairing, batch);
  }

  Future<PhoneTransferBatch> retry(PhoneTransferBatch batch) async {
    final pairing = await pairingRepository.load();
    if (pairing == null) {
      throw StateError('Pair with a laptop before retrying.');
    }
    final reset = batch.copyWith(
      status: PhoneTransferStatus.queued,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      files: batch.files
          .map(
            (file) => file.status == PhoneTransferStatus.failed
                ? file.copyWith(
                    status: PhoneTransferStatus.queued,
                    confirmedOffset: 0,
                    clearError: true,
                  )
                : file,
          )
          .toList(),
    );
    await history.upsert(reset);
    return _send(pairing, reset);
  }

  Future<PhoneTransferBatch> _send(
    PairingCode pairing,
    PhoneTransferBatch initial,
  ) async {
    var batch = initial.copyWith(
      status: PhoneTransferStatus.active,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    await history.upsert(batch);
    final connection = connectionFactory(pairing);
    final inbox = _TransferControlInbox(connection.transferControls);
    try {
      final connected = connection.status.firstWhere(
        (status) => status == ConnectionStatus.connected,
      );
      await connection.start();
      await connected.timeout(const Duration(seconds: 10));
      connection.sendTransferControl({
        'v': 1,
        'kind': 'transfer_offer',
        'offer': _offerJson(batch),
      });

      for (var index = 0; index < batch.files.length; index++) {
        var transferFile = batch.files[index];
        if (transferFile.status == PhoneTransferStatus.completed) continue;
        final accepted = await inbox.nextWhere(
          (message) =>
              message['kind'] == 'transfer_accept' &&
              message['transferId'] == batch.transferId &&
              message['fileId'] == transferFile.fileId,
          timeout: const Duration(minutes: 5),
        );
        final rawOffset = accepted['confirmedOffset'];
        if (rawOffset is! int ||
            rawOffset < 0 ||
            rawOffset > transferFile.size) {
          throw const FormatException(
            'Laptop returned an invalid resume offset.',
          );
        }
        var offset = rawOffset;
        transferFile = transferFile.copyWith(
          status: PhoneTransferStatus.active,
          confirmedOffset: offset,
        );
        batch = await _replaceFile(batch, index, transferFile);

        final sourcePath = transferFile.sourcePath;
        if (sourcePath == null) throw StateError('Source file is unavailable.');
        final source = await File(sourcePath).open();
        try {
          while (offset < transferFile.size || transferFile.size == 0) {
            await source.setPosition(offset);
            final remaining = transferFile.size - offset;
            final count = transferFile.size == 0
                ? 0
                : min(chunkBytes, remaining);
            final plaintext = count == 0 ? <int>[] : await source.read(count);
            if (plaintext.length != count) {
              throw StateError('Source file changed during transfer.');
            }
            final encrypted = await crypto.encrypt(
              metadata: TransferChunkMetadata(
                transferId: batch.transferId,
                fileId: transferFile.fileId,
                offset: offset,
                plaintextBytes: plaintext.length,
              ),
              plaintext: plaintext,
              pairingSecret: pairing.secret,
            );
            final result = await _putChunk(pairing: pairing, chunk: encrypted);
            offset = result.confirmedOffset;
            transferFile = transferFile.copyWith(confirmedOffset: offset);
            batch = await _replaceFile(batch, index, transferFile);
            if (result.complete) break;
          }
        } finally {
          await source.close();
        }
        transferFile = transferFile.copyWith(
          status: PhoneTransferStatus.completed,
          confirmedOffset: transferFile.size,
        );
        batch = await _replaceFile(batch, index, transferFile);
      }
      batch = batch.copyWith(
        status: PhoneTransferStatus.completed,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      await history.upsert(batch);
      return batch;
    } catch (error) {
      batch = batch.copyWith(
        status: PhoneTransferStatus.failed,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        files: batch.files
            .map(
              (file) => file.status == PhoneTransferStatus.active
                  ? file.copyWith(
                      status: PhoneTransferStatus.failed,
                      errorCode: _errorCode(error),
                    )
                  : file,
            )
            .toList(),
      );
      await history.upsert(batch);
      rethrow;
    } finally {
      await inbox.close();
      await connection.close();
    }
  }

  Future<_ChunkResult> _putChunk({
    required PairingCode pairing,
    required EncryptedTransferChunk chunk,
  }) async {
    final path =
        '/transfer/v1/${chunk.transferId}/${chunk.fileId}?offset=${chunk.offset}';
    final auth = await createTransferHttpAuth(
      pairingSecret: pairing.secret,
      method: 'PUT',
      pathAndQuery: path,
    );
    final client = HttpClient();
    try {
      final request = await client.putUrl(
        Uri.parse('http://${pairing.host}:${pairing.port}$path'),
      );
      auth.headers.forEach(request.headers.set);
      request.headers
        ..set('x-vidyut-nonce', chunk.nonce)
        ..set('x-vidyut-plaintext-bytes', chunk.plaintextBytes.toString())
        ..contentLength = chunk.ciphertext.length;
      request.add(chunk.ciphertext);
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = await utf8.decodeStream(response);
      final json = body.isEmpty
          ? <String, Object?>{}
          : (jsonDecode(body) as Map).cast<String, Object?>();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          (json['code'] as String?) ?? 'HTTP ${response.statusCode}',
        );
      }
      return _ChunkResult(
        confirmedOffset: json['confirmedOffset']! as int,
        complete: json['complete'] == true,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<PhoneTransferBatch> _replaceFile(
    PhoneTransferBatch batch,
    int index,
    PhoneTransferFile file,
  ) async {
    final files = [...batch.files]..[index] = file;
    final updated = batch.copyWith(
      files: files,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    await history.upsert(updated);
    return updated;
  }

  Map<String, Object?> _offerJson(PhoneTransferBatch batch) => {
    'transferId': batch.transferId,
    'batchId': batch.batchId,
    'origin': 'phone',
    'direction': 'phone_to_laptop',
    'createdAtMs': batch.createdAtMs,
    'files': batch.files
        .map(
          (file) => {
            'fileId': file.fileId,
            'filename': file.filename,
            'mime': file.mime,
            'size': file.size,
            'lastModifiedMs': file.lastModifiedMs,
            'sha256': file.sha256,
          },
        )
        .toList(),
  };

  Future<String> _hashFile(File file) async {
    return (await hashes.sha256.bind(file.openRead()).first).toString();
  }

  String _id(String prefix) {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${prefix}_$hex';
  }
}

class _ChunkResult {
  const _ChunkResult({required this.confirmedOffset, required this.complete});

  final int confirmedOffset;
  final bool complete;
}

class _TransferControlInbox {
  _TransferControlInbox(Stream<Map<String, Object?>> stream) {
    _subscription = stream.listen(_receive);
  }

  final _pending = <Map<String, Object?>>[];
  final _waiters = <_ControlWaiter>[];
  late final StreamSubscription<Map<String, Object?>> _subscription;

  Future<Map<String, Object?>> nextWhere(
    bool Function(Map<String, Object?> message) predicate, {
    required Duration timeout,
  }) {
    final index = _pending.indexWhere(predicate);
    if (index >= 0) return Future.value(_pending.removeAt(index));
    final completer = Completer<Map<String, Object?>>();
    final waiter = _ControlWaiter(predicate, completer);
    _waiters.add(waiter);
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _waiters.remove(waiter);
        throw TimeoutException('Timed out waiting for the laptop.');
      },
    );
  }

  void _receive(Map<String, Object?> message) {
    final index = _waiters.indexWhere((waiter) => waiter.predicate(message));
    if (index < 0) {
      _pending.add(message);
      return;
    }
    _waiters.removeAt(index).completer.complete(message);
  }

  Future<void> close() => _subscription.cancel();
}

class _ControlWaiter {
  const _ControlWaiter(this.predicate, this.completer);

  final bool Function(Map<String, Object?> message) predicate;
  final Completer<Map<String, Object?>> completer;
}

String _safeBasename(String value) {
  final normalized = value.replaceAll(r'\', '/');
  final name = normalized.split('/').last;
  if (name.isEmpty || name == '.' || name == '..') {
    throw const FormatException('File has an invalid name.');
  }
  return name;
}

String _errorCode(Object error) {
  final message = error.toString().toLowerCase();
  if (message.contains('timeout')) return 'timeout';
  if (message.contains('source')) return 'source_unavailable';
  if (message.contains('size') || message.contains('large')) {
    return 'file_too_large';
  }
  return 'transfer_failed';
}
