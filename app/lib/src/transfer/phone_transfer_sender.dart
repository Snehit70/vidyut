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
import 'transfer_chunk_policy.dart';
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

enum PhoneTransferProgressStage {
  preparing,
  connecting,
  waitingForLaptop,
  transferring,
  completed,
  failed,
}

class PhoneTransferProgress {
  const PhoneTransferProgress({
    required this.stage,
    required this.fileCount,
    required this.totalBytes,
    required this.transferredBytes,
    this.currentFileIndex,
    this.currentFilename,
    this.bytesPerSecond,
    this.transferId,
  });

  final PhoneTransferProgressStage stage;
  final int fileCount;
  final int totalBytes;
  final int transferredBytes;
  final int? currentFileIndex;
  final String? currentFilename;
  final double? bytesPerSecond;
  final String? transferId;

  double get fraction =>
      totalBytes == 0 ? 0 : (transferredBytes / totalBytes).clamp(0.0, 1.0);

  Duration? get remaining {
    final speed = bytesPerSecond;
    if (speed == null || speed <= 0 || totalBytes <= transferredBytes) {
      return null;
    }
    return Duration(
      milliseconds: ((totalBytes - transferredBytes) / speed * 1000).round(),
    );
  }
}

class PhoneTransferSender {
  PhoneTransferSender({
    required this.pairingRepository,
    required this.connectionFactory,
    required this.history,
    TransferCrypto? crypto,
    Random? random,
    this.chunkBytes = TransferChunkPolicy.preferredBytes,
    this.maximumFileBytes,
    this.networkAllowed,
    this.reconnectBackoff = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ],
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
  final List<Duration> reconnectBackoff;
  final _progressController =
      StreamController<PhoneTransferProgress>.broadcast();

  Stream<PhoneTransferProgress> get progress => _progressController.stream;

  Future<PhoneTransferBatch> enqueue(List<PhoneTransferSource> sources) async {
    if (sources.isEmpty) {
      throw const FormatException('Select at least one file.');
    }
    _publish(
      PhoneTransferProgress(
        stage: PhoneTransferProgressStage.preparing,
        fileCount: sources.length,
        totalBytes: 0,
        transferredBytes: 0,
      ),
    );
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
    final prepared = <({PhoneTransferSource source, FileStat info})>[];
    for (var index = 0; index < sources.length; index++) {
      final source = sources[index];
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
      prepared.add((source: source, info: info));
      _publish(
        PhoneTransferProgress(
          stage: PhoneTransferProgressStage.preparing,
          fileCount: sources.length,
          totalBytes: prepared.fold(0, (sum, value) => sum + value.info.size),
          transferredBytes: 0,
          currentFileIndex: index,
          currentFilename: source.filename,
        ),
      );
    }
    final totalBytes = prepared.fold(0, (sum, value) => sum + value.info.size);
    for (var index = 0; index < prepared.length; index++) {
      final entry = prepared[index];
      final source = entry.source;
      final info = entry.info;
      _publish(
        PhoneTransferProgress(
          stage: PhoneTransferProgressStage.preparing,
          fileCount: sources.length,
          totalBytes: totalBytes,
          transferredBytes: 0,
          currentFileIndex: index,
          currentFilename: source.filename,
        ),
      );
      files.add(
        PhoneTransferFile(
          fileId: _id('file'),
          filename: _safeBasename(source.filename),
          mime: source.mime,
          size: info.size,
          lastModifiedMs: info.modified.millisecondsSinceEpoch,
          sha256: await _hashFile(File(source.path)),
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
    _publish(
      PhoneTransferProgress(
        stage: PhoneTransferProgressStage.connecting,
        fileCount: files.length,
        totalBytes: totalBytes,
        transferredBytes: 0,
        transferId: batch.transferId,
      ),
    );
    return _send(pairing, batch);
  }

  Future<PhoneTransferBatch> retry(PhoneTransferBatch batch) async {
    if (networkAllowed != null && !await networkAllowed!()) {
      throw StateError('File transfers are disabled on this metered network.');
    }
    final maxBytes = maximumFileBytes == null
        ? 1024 * 1024 * 1024
        : await maximumFileBytes!();
    if (batch.files.any((file) => file.size > maxBytes)) {
      throw StateError('A file exceeds the configured maximum file size.');
    }
    for (final transferFile in batch.files.where(
      (file) => file.status != PhoneTransferStatus.completed,
    )) {
      final sourcePath = transferFile.sourcePath;
      if (sourcePath == null) {
        throw StateError('${transferFile.filename} is no longer available.');
      }
      final source = await File(sourcePath).stat();
      if (source.type != FileSystemEntityType.file ||
          source.size != transferFile.size ||
          source.modified.millisecondsSinceEpoch !=
              transferFile.lastModifiedMs) {
        throw StateError('${transferFile.filename} changed after selection.');
      }
    }
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
    _TransferSession? session;
    final stopwatch = Stopwatch();
    try {
      final openedSession = await _openSession(pairing, batch);
      session = openedSession;
      var activeSession = openedSession;

      for (var index = 0; index < batch.files.length; index++) {
        var transferFile = batch.files[index];
        if (transferFile.status == PhoneTransferStatus.completed) continue;
        _publishBatch(
          batch,
          stage: PhoneTransferProgressStage.waitingForLaptop,
          currentFileIndex: index,
          currentFilename: transferFile.filename,
        );
        var accepted = await _waitForAcceptance(
          activeSession.inbox,
          batch,
          transferFile,
          timeout: const Duration(minutes: 5),
        );
        var offset = accepted.confirmedOffset;
        var effectiveChunkBytes = TransferChunkPolicy.negotiate(
          accepted.maxChunkBytes,
          localMaximum: chunkBytes,
        );
        var lastPersistedOffset = offset;
        transferFile = transferFile.copyWith(
          status: PhoneTransferStatus.active,
          confirmedOffset: offset,
        );
        batch = await _replaceFile(batch, index, transferFile);
        if (!stopwatch.isRunning) stopwatch.start();
        _publishBatch(
          batch,
          stage: PhoneTransferProgressStage.transferring,
          currentFileIndex: index,
          currentFilename: transferFile.filename,
          bytesPerSecond: _bytesPerSecond(batch, stopwatch),
        );

        final sourcePath = transferFile.sourcePath;
        if (sourcePath == null) throw StateError('Source file is unavailable.');
        final source = await File(sourcePath).open();
        try {
          while (offset < transferFile.size || transferFile.size == 0) {
            await source.setPosition(offset);
            final remaining = transferFile.size - offset;
            final count = transferFile.size == 0
                ? 0
                : min(effectiveChunkBytes, remaining);
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
            _ChunkResult result;
            try {
              result = await _putChunk(
                pairing: pairing,
                chunk: encrypted,
                client: activeSession.client,
              );
            } catch (error) {
              if (!_isTransientTransferError(error) ||
                  reconnectBackoff.isEmpty) {
                rethrow;
              }
              _publishBatch(
                batch,
                stage: PhoneTransferProgressStage.connecting,
                currentFileIndex: index,
                currentFilename: transferFile.filename,
              );
              Object? reconnectError;
              _TransferSession? replacement;
              await activeSession.close();
              for (final delay in reconnectBackoff) {
                if (delay > Duration.zero) await Future<void>.delayed(delay);
                try {
                  replacement = await _openSession(pairing, batch);
                  accepted = await _waitForAcceptance(
                    replacement.inbox,
                    batch,
                    transferFile,
                    timeout: const Duration(seconds: 15),
                  );
                  reconnectError = null;
                  break;
                } catch (candidate) {
                  reconnectError = candidate;
                  await replacement?.close();
                  replacement = null;
                }
              }
              if (replacement == null) {
                throw reconnectError ?? error;
              }
              session = replacement;
              activeSession = replacement;
              offset = accepted.confirmedOffset;
              effectiveChunkBytes = TransferChunkPolicy.negotiate(
                accepted.maxChunkBytes,
                localMaximum: chunkBytes,
              );
              lastPersistedOffset = offset;
              transferFile = transferFile.copyWith(
                status: PhoneTransferStatus.active,
                confirmedOffset: offset,
              );
              batch = await _replaceFile(batch, index, transferFile);
              _publishBatch(
                batch,
                stage: PhoneTransferProgressStage.transferring,
                currentFileIndex: index,
                currentFilename: transferFile.filename,
                bytesPerSecond: _bytesPerSecond(batch, stopwatch),
              );
              continue;
            }
            if (result.confirmedOffset > transferFile.size ||
                result.confirmedOffset > offset + plaintext.length ||
                (result.complete &&
                    result.confirmedOffset != transferFile.size)) {
              throw StateError('Laptop returned invalid transfer progress.');
            }
            if (result.confirmedOffset <= offset && !result.complete) {
              throw StateError('Laptop did not advance transfer progress.');
            }
            offset = result.confirmedOffset;
            transferFile = transferFile.copyWith(confirmedOffset: offset);
            final shouldPersist =
                result.complete ||
                offset == transferFile.size ||
                offset - lastPersistedOffset >= 4 * 1024 * 1024;
            batch = await _replaceFile(
              batch,
              index,
              transferFile,
              persist: shouldPersist,
            );
            if (shouldPersist) lastPersistedOffset = offset;
            _publishBatch(
              batch,
              stage: PhoneTransferProgressStage.transferring,
              currentFileIndex: index,
              currentFilename: transferFile.filename,
              bytesPerSecond: _bytesPerSecond(batch, stopwatch),
            );
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
        _publishBatch(
          batch,
          stage: PhoneTransferProgressStage.transferring,
          currentFileIndex: index,
          currentFilename: transferFile.filename,
          bytesPerSecond: _bytesPerSecond(batch, stopwatch),
        );
      }
      batch = batch.copyWith(
        status: PhoneTransferStatus.completed,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      await history.upsert(batch);
      _publishBatch(batch, stage: PhoneTransferProgressStage.completed);
      return batch;
    } catch (error) {
      batch = batch.copyWith(
        status: PhoneTransferStatus.failed,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        files: batch.files
            .map(
              (file) =>
                  file.status != PhoneTransferStatus.completed &&
                      file.status != PhoneTransferStatus.cancelled
                  ? file.copyWith(
                      status: PhoneTransferStatus.failed,
                      errorCode: _errorCode(error),
                    )
                  : file,
            )
            .toList(),
      );
      await history.upsert(batch);
      _publishBatch(batch, stage: PhoneTransferProgressStage.failed);
      rethrow;
    } finally {
      await session?.close();
    }
  }

  Future<_TransferSession> _openSession(
    PairingCode pairing,
    PhoneTransferBatch batch,
  ) async {
    final connection = connectionFactory(pairing);
    final inbox = _TransferControlInbox(connection.transferControls);
    final session = _TransferSession(
      connection: connection,
      inbox: inbox,
      client: HttpClient(),
    );
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
      return session;
    } catch (_) {
      await session.close();
      rethrow;
    }
  }

  Future<_AcceptedTransfer> _waitForAcceptance(
    _TransferControlInbox inbox,
    PhoneTransferBatch batch,
    PhoneTransferFile transferFile, {
    required Duration timeout,
  }) async {
    final accepted = await inbox.nextWhere(
      (message) =>
          message['kind'] == 'transfer_accept' &&
          message['transferId'] == batch.transferId &&
          message['fileId'] == transferFile.fileId,
      timeout: timeout,
    );
    final rawOffset = accepted['confirmedOffset'];
    if (rawOffset is! int || rawOffset < 0 || rawOffset > transferFile.size) {
      throw const FormatException('Laptop returned an invalid resume offset.');
    }
    return _AcceptedTransfer(
      confirmedOffset: rawOffset,
      maxChunkBytes: accepted['maxChunkBytes'],
    );
  }

  Future<_ChunkResult> _putChunk({
    required PairingCode pairing,
    required EncryptedTransferChunk chunk,
    required HttpClient client,
  }) async {
    final path =
        '/transfer/v1/${chunk.transferId}/${chunk.fileId}?offset=${chunk.offset}';
    final auth = await createTransferHttpAuth(
      pairingSecret: pairing.secret,
      method: 'PUT',
      pathAndQuery: path,
    );
    final request = await client.putUrl(
      Uri.parse('http://${pairing.host}:${pairing.port}$path'),
    );
    auth.headers.forEach(request.headers.set);
    request.headers
      ..set('x-vidyut-nonce', chunk.nonce)
      ..set('x-vidyut-plaintext-bytes', chunk.plaintextBytes.toString())
      ..contentLength = chunk.ciphertext.length;
    request.add(chunk.ciphertext);
    final response = await request.close().timeout(const Duration(seconds: 30));
    final body = await utf8.decodeStream(
      response.timeout(const Duration(seconds: 30)),
    );
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
  }

  Future<PhoneTransferBatch> _replaceFile(
    PhoneTransferBatch batch,
    int index,
    PhoneTransferFile file, {
    bool persist = true,
  }) async {
    final files = [...batch.files]..[index] = file;
    final updated = batch.copyWith(
      files: files,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    if (persist) await history.upsert(updated);
    return updated;
  }

  void _publish(PhoneTransferProgress value) {
    if (!_progressController.isClosed) _progressController.add(value);
  }

  void _publishBatch(
    PhoneTransferBatch batch, {
    required PhoneTransferProgressStage stage,
    int? currentFileIndex,
    String? currentFilename,
    double? bytesPerSecond,
  }) {
    _publish(
      PhoneTransferProgress(
        stage: stage,
        fileCount: batch.files.length,
        totalBytes: batch.files.fold(0, (sum, file) => sum + file.size),
        transferredBytes: batch.files.fold(
          0,
          (sum, file) => sum + file.confirmedOffset,
        ),
        currentFileIndex: currentFileIndex,
        currentFilename: currentFilename,
        bytesPerSecond: bytesPerSecond,
        transferId: batch.transferId,
      ),
    );
  }

  double? _bytesPerSecond(PhoneTransferBatch batch, Stopwatch stopwatch) {
    if (stopwatch.elapsedMilliseconds == 0) return null;
    final transferred = batch.files.fold(
      0,
      (sum, file) => sum + file.confirmedOffset,
    );
    return transferred / (stopwatch.elapsedMilliseconds / 1000);
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

class _AcceptedTransfer {
  const _AcceptedTransfer({
    required this.confirmedOffset,
    required this.maxChunkBytes,
  });

  final int confirmedOffset;
  final Object? maxChunkBytes;
}

class _TransferSession {
  _TransferSession({
    required this.connection,
    required this.inbox,
    required this.client,
  });

  final RelayConnection connection;
  final _TransferControlInbox inbox;
  final HttpClient client;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    client.close(force: true);
    await inbox.close();
    await connection.close();
  }
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

bool _isTransientTransferError(Object error) =>
    error is SocketException ||
    error is HttpException ||
    error is TimeoutException;
