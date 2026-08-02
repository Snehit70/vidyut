import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as hashes;
import 'package:vidyut_files/vidyut_files.dart';

import '../pairing/pairing_code.dart';
import '../pairing/pairing_repository.dart';
import '../shared/relay_connection.dart';
import '../shared/transfer_crypto.dart';
import '../shared/transfer_http_auth.dart';
import 'transfer_chunk_policy.dart';
import 'transfer_history.dart';

class PhoneTransferSource {
  const PhoneTransferSource({
    this.path,
    this.uri,
    required this.filename,
    required this.mime,
    this.size,
    this.lastModifiedMs,
    this.persisted = false,
  }) : assert(path != null || uri != null);

  final String? path;
  final String? uri;
  final String filename;
  final String mime;
  final int? size;
  final int? lastModifiedMs;
  final bool persisted;

  PhoneTransferSourceReference get reference => PhoneTransferSourceReference(
    kind: uri == null
        ? PhoneTransferSourceKind.externalPath
        : PhoneTransferSourceKind.androidDocumentUri,
    reference: uri ?? path!,
    ownership: PhoneTransferSourceOwnership.external,
  );
}

abstract interface class PhoneTransferSourceReader {
  Future<VidyutSourceProbe> probe(String uri);

  Future<String> hashSha256(String uri);

  Future<VidyutStagedSource> stage(String uri, {required int maximumBytes});

  Future<List<int>> readAt(
    String uri, {
    required int offset,
    required int length,
  });

  Future<void> release(String reference) async {}

  Future<void> retain(String reference) async {}
}

class VidyutFilesSourceReader implements PhoneTransferSourceReader {
  const VidyutFilesSourceReader([this.files = const VidyutFiles()]);

  final VidyutFiles files;

  @override
  Future<VidyutSourceProbe> probe(String uri) => files.probeSource(uri);

  @override
  Future<String> hashSha256(String uri) => files.hashSource(uri);

  @override
  Future<VidyutStagedSource> stage(String uri, {required int maximumBytes}) =>
      files.stageSource(uri, maximumBytes: maximumBytes);

  @override
  Future<List<int>> readAt(
    String uri, {
    required int offset,
    required int length,
  }) async => (await files.readSourceAt(uri, offset: offset, length: length));

  @override
  Future<void> release(String reference) => files.releaseSource(reference);

  @override
  Future<void> retain(String reference) => files.retainSource(reference);
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
    this.acceptanceTimeout = const Duration(minutes: 5),
    PhoneTransferSourceReader? sourceReader,
    this.onBatchCreated,
    this.reconnectBackoff = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ],
  }) : crypto = crypto ?? TransferCrypto(),
       _random = random ?? Random.secure(),
       sourceReader = sourceReader ?? const VidyutFilesSourceReader();

  final PairingRepository pairingRepository;
  final TransferRelayConnectionFactory connectionFactory;
  final TransferHistoryRepository history;
  final TransferCrypto crypto;
  final Random _random;
  final int chunkBytes;
  final Future<int> Function()? maximumFileBytes;
  final Future<bool> Function()? networkAllowed;
  final Duration acceptanceTimeout;
  final PhoneTransferSourceReader sourceReader;
  final FutureOr<void> Function(PhoneTransferBatch batch)? onBatchCreated;
  final List<Duration> reconnectBackoff;
  final _progressController =
      StreamController<PhoneTransferProgress>.broadcast();
  final _batchCreatedController =
      StreamController<PhoneTransferBatch>.broadcast();

  Stream<PhoneTransferProgress> get progress => _progressController.stream;
  Stream<PhoneTransferBatch> get batchesCreated =>
      _batchCreatedController.stream;

  /// Reopens durable sources after an isolate/process restart. Native source
  /// sessions are intentionally not reused; each URI or managed stage is
  /// probed again before an unfinished offer resumes.
  Future<void> resumePending() async {
    final pairing = await pairingRepository.load();
    if (pairing == null) return;
    final maximum = maximumFileBytes == null
        ? 1024 * 1024 * 1024
        : await maximumFileBytes!();
    for (var batch in await history.load()) {
      if (batch.direction != PhoneTransferDirection.sent ||
          (batch.status != PhoneTransferStatus.preparing &&
              batch.status != PhoneTransferStatus.queued &&
              batch.status != PhoneTransferStatus.active)) {
        continue;
      }
      try {
        for (var index = 0; index < batch.files.length; index++) {
          final file = batch.files[index];
          if (file.status != PhoneTransferStatus.preparing &&
              file.sha256 != _unknownSha256) {
            continue;
          }
          final source = _sourceForFile(file);
          final prepared = await _prepareSource(source, maximum);
          batch = await _replaceFile(
            batch,
            index,
            file.copyWith(
              size: prepared.size,
              lastModifiedMs: prepared.lastModifiedMs,
              lastModifiedKnown: prepared.lastModifiedKnown,
              sha256: prepared.sha256,
              status: PhoneTransferStatus.queued,
              sourceReference: prepared.reference,
            ),
          );
        }
        batch = batch.copyWith(status: PhoneTransferStatus.queued);
        await history.upsert(batch);
        await _send(pairing, batch);
      } on Object catch (error) {
        batch = batch.copyWith(
          status: PhoneTransferStatus.failed,
          files: batch.files
              .map(
                (file) => file.status == PhoneTransferStatus.completed
                    ? file
                    : file.copyWith(
                        status: PhoneTransferStatus.failed,
                        errorCode: _errorCode(error),
                        errorOrigin: _errorOrigin(error),
                        errorCategory: _errorCategory(error),
                        errorDetail: _errorDetail(error),
                        errorContext: _errorContext(error),
                      ),
              )
              .toList(growable: false),
        );
        await history.upsert(batch);
      }
    }
  }

  Future<PhoneTransferBatch> enqueue(List<PhoneTransferSource> sources) async {
    if (sources.isEmpty) {
      throw const FormatException('Select at least one file.');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    var batch = PhoneTransferBatch(
      transferId: _id('transfer'),
      batchId: _id('batch'),
      direction: PhoneTransferDirection.sent,
      createdAtMs: now,
      updatedAtMs: now,
      status: PhoneTransferStatus.preparing,
      files: sources
          .map(
            (source) => PhoneTransferFile(
              fileId: _id('file'),
              filename: _safeBasename(source.filename),
              mime: source.mime,
              size: source.size ?? 0,
              lastModifiedMs: source.lastModifiedMs ?? 0,
              lastModifiedKnown: source.lastModifiedMs != null,
              sha256: _unknownSha256,
              status: PhoneTransferStatus.preparing,
              confirmedOffset: 0,
              sourceReference: source.reference,
              sourcePath: source.path,
            ),
          )
          .toList(growable: false),
    );
    // Persist before provider metadata, probing, hashing, policy, pairing, or
    // relay work. This is the durable boundary used by restart recovery.
    await history.upsert(batch);
    _batchCreatedController.add(batch);
    await onBatchCreated?.call(batch);
    final retainedUris = <String>[];
    for (final source in sources) {
      if (source.uri != null && source.persisted) {
        await sourceReader.retain(source.uri!);
        retainedUris.add(source.uri!);
      }
    }
    _publish(
      PhoneTransferProgress(
        stage: PhoneTransferProgressStage.preparing,
        fileCount: sources.length,
        totalBytes: 0,
        transferredBytes: 0,
      ),
    );
    late PairingCode pairing;
    try {
      if (networkAllowed != null && !await networkAllowed!()) {
        throw StateError(
          'File transfers are disabled on this metered network.',
        );
      }
      final maxBytes = maximumFileBytes == null
          ? 1024 * 1024 * 1024
          : await maximumFileBytes!();
      for (var index = 0; index < sources.length; index++) {
        final source = sources[index];
        final prepared = await _prepareSource(source, maxBytes);
        _publish(
          PhoneTransferProgress(
            stage: PhoneTransferProgressStage.preparing,
            fileCount: sources.length,
            totalBytes: batch.files.fold(
              prepared.size,
              (sum, value) => sum + value.size,
            ),
            transferredBytes: 0,
            currentFileIndex: index,
            currentFilename: source.filename,
          ),
        );
        final preparedFile = batch.files[index].copyWith(
          size: prepared.size,
          lastModifiedMs: prepared.lastModifiedMs,
          lastModifiedKnown: prepared.lastModifiedKnown,
          sha256: prepared.sha256,
          status: PhoneTransferStatus.queued,
          sourceReference: prepared.reference,
        );
        batch = await _replaceFile(batch, index, preparedFile);
      }
      batch = batch.copyWith(
        status: PhoneTransferStatus.queued,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      await history.upsert(batch);
      final loadedPairing = await pairingRepository.load();
      if (loadedPairing == null) {
        throw StateError('Pair with a laptop before sending files.');
      }
      pairing = loadedPairing;
    } catch (error) {
      for (final uri in retainedUris) {
        await sourceReader.release(uri);
      }
      batch = batch.copyWith(
        status: PhoneTransferStatus.failed,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        files: batch.files
            .map(
              (file) => file.status == PhoneTransferStatus.completed
                  ? file
                  : file.copyWith(
                      status: PhoneTransferStatus.failed,
                      errorCode: _errorCode(error),
                      errorOrigin: _errorOrigin(error),
                      errorCategory: _errorCategory(error),
                      errorDetail: _errorDetail(error),
                      errorContext: _errorContext(error),
                    ),
            )
            .toList(growable: false),
      );
      await history.upsert(batch);
      _publishBatch(batch, stage: PhoneTransferProgressStage.failed);
      rethrow;
    }
    final totalBytes = batch.files.fold(0, (sum, file) => sum + file.size);
    _publish(
      PhoneTransferProgress(
        stage: PhoneTransferProgressStage.connecting,
        fileCount: batch.files.length,
        totalBytes: totalBytes,
        transferredBytes: 0,
        transferId: batch.transferId,
      ),
    );
    return _send(pairing, batch);
  }

  Future<
    ({
      int size,
      int lastModifiedMs,
      bool lastModifiedKnown,
      String sha256,
      PhoneTransferSourceReference? reference,
    })
  >
  _prepareSource(PhoneTransferSource source, int maxBytes) async {
    if (source.path case final path?) {
      final file = File(path);
      final info = await file.stat();
      if (info.type != FileSystemEntityType.file) {
        throw FormatException('Only regular files can be sent: $path');
      }
      if (info.size > maxBytes) {
        throw FormatException(
          '${source.filename} exceeds the configured maximum file size.',
        );
      }
      return (
        size: info.size,
        lastModifiedMs: info.modified.millisecondsSinceEpoch,
        lastModifiedKnown: true,
        sha256: await _hashFile(file),
        reference: null,
      );
    }
    final uri = source.uri!;
    final probe = await sourceReader.probe(uri);
    if (!source.persisted ||
        !probe.seekable ||
        !probe.sizeKnown ||
        probe.size < 0) {
      final staged = await sourceReader.stage(uri, maximumBytes: maxBytes);
      return (
        size: staged.size,
        lastModifiedMs: staged.lastModifiedMs ?? source.lastModifiedMs ?? 0,
        lastModifiedKnown:
            staged.lastModifiedMs != null || source.lastModifiedMs != null,
        sha256: staged.sha256,
        reference: PhoneTransferSourceReference(
          kind: PhoneTransferSourceKind.managedStage,
          reference: staged.reference,
          ownership: PhoneTransferSourceOwnership.managed,
        ),
      );
    }
    if (probe.size > maxBytes) {
      throw FormatException(
        '${source.filename} exceeds the configured maximum file size.',
      );
    }
    return (
      size: probe.size,
      lastModifiedMs: source.lastModifiedMs ?? 0,
      lastModifiedKnown: source.lastModifiedMs != null,
      sha256: await sourceReader.hashSha256(uri),
      reference: null,
    );
  }

  PhoneTransferSource _sourceForFile(PhoneTransferFile file) {
    final reference = file.sourceReference;
    final path =
        file.sourcePath ??
        (reference?.kind == PhoneTransferSourceKind.externalPath
            ? reference?.reference
            : null);
    final uri =
        reference?.kind == PhoneTransferSourceKind.androidDocumentUri ||
            reference?.kind == PhoneTransferSourceKind.managedStage
        ? reference?.reference
        : null;
    if (path == null && uri == null) {
      throw StateError('${file.filename} is no longer available.');
    }
    return PhoneTransferSource(
      path: path,
      uri: uri,
      filename: file.filename,
      mime: file.mime,
      size: file.size,
      lastModifiedMs: file.lastModifiedKnown ? file.lastModifiedMs : null,
      persisted: uri != null,
    );
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
      final sourceUri =
          transferFile.sourceReference?.kind ==
                  PhoneTransferSourceKind.androidDocumentUri ||
              transferFile.sourceReference?.kind ==
                  PhoneTransferSourceKind.managedStage
          ? transferFile.sourceReference?.reference
          : null;
      if (sourceUri != null) {
        final probe = await sourceReader.probe(sourceUri);
        if (!probe.seekable ||
            !probe.sizeKnown ||
            probe.size != transferFile.size) {
          throw StateError('${transferFile.filename} is no longer available.');
        }
        if (await sourceReader.hashSha256(sourceUri) != transferFile.sha256) {
          throw StateError('${transferFile.filename} changed after selection.');
        }
      } else {
        final path =
            sourcePath ??
            (transferFile.sourceReference?.kind ==
                    PhoneTransferSourceKind.externalPath
                ? transferFile.sourceReference?.reference
                : null);
        if (path == null) {
          throw StateError('${transferFile.filename} is no longer available.');
        }
        final source = await File(path).stat();
        if (source.type != FileSystemEntityType.file ||
            source.size != transferFile.size ||
            source.modified.millisecondsSinceEpoch !=
                transferFile.lastModifiedMs ||
            await _hashFile(File(path)) != transferFile.sha256) {
          throw StateError('${transferFile.filename} changed after selection.');
        }
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
        var acceptedSession = await _acceptWithReconnect(
          pairing: pairing,
          batch: batch,
          transferFile: transferFile,
          currentSession: activeSession,
          timeout: acceptanceTimeout,
        );
        session = acceptedSession.session;
        activeSession = acceptedSession.session;
        var accepted = acceptedSession.accepted;
        if (!stopwatch.isRunning) stopwatch.start();
        var applied = await _applyAcceptance(
          batch: batch,
          index: index,
          transferFile: transferFile,
          accepted: accepted,
          stopwatch: stopwatch,
        );
        batch = applied.batch;
        transferFile = applied.transferFile;
        var offset = applied.offset;
        var effectiveChunkBytes = applied.effectiveChunkBytes;
        var lastPersistedOffset = offset;
        var remainingPutRetries = reconnectBackoff.length;

        if (!accepted.complete) {
          final sourcePath =
              transferFile.sourcePath ??
              (transferFile.sourceReference?.kind ==
                      PhoneTransferSourceKind.externalPath
                  ? transferFile.sourceReference?.reference
                  : null);
          final sourceUri =
              transferFile.sourceReference?.kind ==
                      PhoneTransferSourceKind.androidDocumentUri ||
                  transferFile.sourceReference?.kind ==
                      PhoneTransferSourceKind.managedStage
              ? transferFile.sourceReference?.reference
              : null;
          if (sourcePath == null && sourceUri == null) {
            throw StateError('Source file is unavailable.');
          }
          final source = sourcePath == null
              ? null
              : await File(sourcePath).open();
          try {
            while (!accepted.complete &&
                (offset < transferFile.size || transferFile.size == 0)) {
              if (source != null) await source.setPosition(offset);
              final remaining = transferFile.size - offset;
              final count = transferFile.size == 0
                  ? 0
                  : min(effectiveChunkBytes, remaining);
              final plaintext = count == 0
                  ? <int>[]
                  : sourceUri != null
                  ? await sourceReader.readAt(
                      sourceUri,
                      offset: offset,
                      length: count,
                    )
                  : await source!.read(count);
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
                if (error case _TransferOffsetConflict(
                  :final confirmedOffset,
                )) {
                  if (confirmedOffset < 0 ||
                      confirmedOffset > transferFile.size) {
                    throw const FormatException(
                      'Laptop returned an invalid resume offset.',
                    );
                  }
                  if (confirmedOffset <= offset) {
                    throw StateError(
                      'Laptop returned a non-advancing resume offset.',
                    );
                  }
                  if (confirmedOffset == transferFile.size) {
                    acceptedSession = await _acceptWithReconnect(
                      pairing: pairing,
                      batch: batch,
                      transferFile: transferFile,
                      currentSession: activeSession,
                      timeout: acceptanceTimeout,
                      terminalOnly: true,
                    );
                    session = acceptedSession.session;
                    activeSession = acceptedSession.session;
                    accepted = acceptedSession.accepted;
                    applied = await _applyAcceptance(
                      batch: batch,
                      index: index,
                      transferFile: transferFile,
                      accepted: accepted,
                      stopwatch: stopwatch,
                    );
                    batch = applied.batch;
                    transferFile = applied.transferFile;
                    offset = applied.offset;
                    effectiveChunkBytes = applied.effectiveChunkBytes;
                    lastPersistedOffset = offset;
                    remainingPutRetries = reconnectBackoff.length;
                    continue;
                  }
                  accepted = _AcceptedTransfer(
                    confirmedOffset: confirmedOffset,
                    maxChunkBytes: effectiveChunkBytes,
                    complete: false,
                  );
                  applied = await _applyAcceptance(
                    batch: batch,
                    index: index,
                    transferFile: transferFile,
                    accepted: accepted,
                    stopwatch: stopwatch,
                  );
                  batch = applied.batch;
                  transferFile = applied.transferFile;
                  offset = applied.offset;
                  effectiveChunkBytes = applied.effectiveChunkBytes;
                  lastPersistedOffset = offset;
                  remainingPutRetries = reconnectBackoff.length;
                  continue;
                }
                if (!_isTransientTransferError(error) ||
                    reconnectBackoff.isEmpty ||
                    remainingPutRetries <= 0) {
                  rethrow;
                }
                remainingPutRetries -= 1;
                _publishBatch(
                  batch,
                  stage: PhoneTransferProgressStage.connecting,
                  currentFileIndex: index,
                  currentFilename: transferFile.filename,
                );
                acceptedSession = await _acceptWithReconnect(
                  pairing: pairing,
                  batch: batch,
                  transferFile: transferFile,
                  currentSession: activeSession,
                  timeout: const Duration(seconds: 15),
                  forceReconnect: true,
                  cause: error,
                );
                session = acceptedSession.session;
                activeSession = acceptedSession.session;
                accepted = acceptedSession.accepted;
                final previousOffset = offset;
                applied = await _applyAcceptance(
                  batch: batch,
                  index: index,
                  transferFile: transferFile,
                  accepted: accepted,
                  stopwatch: stopwatch,
                );
                batch = applied.batch;
                transferFile = applied.transferFile;
                offset = applied.offset;
                effectiveChunkBytes = applied.effectiveChunkBytes;
                lastPersistedOffset = offset;
                if (offset > previousOffset) {
                  remainingPutRetries = reconnectBackoff.length;
                }
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
              remainingPutRetries = reconnectBackoff.length;
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
            await source?.close();
          }
        }
        transferFile = transferFile.copyWith(
          status: PhoneTransferStatus.completed,
          confirmedOffset: transferFile.size,
        );
        batch = await _replaceFile(batch, index, transferFile);
        final reference = transferFile.sourceReference;
        if (reference?.ownership == PhoneTransferSourceOwnership.managed) {
          await sourceReader.release(reference!.reference);
          transferFile = transferFile.copyWith(clearSourceReference: true);
          batch = await _replaceFile(batch, index, transferFile);
        } else if (reference?.kind ==
            PhoneTransferSourceKind.androidDocumentUri) {
          await sourceReader.release(reference!.reference);
        }
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
                      errorOrigin: _errorOrigin(error),
                      errorCategory: _errorCategory(error),
                      errorDetail: _errorDetail(error),
                      errorContext: _errorContext(error),
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

  Future<_AcceptedSession> _acceptWithReconnect({
    required PairingCode pairing,
    required PhoneTransferBatch batch,
    required PhoneTransferFile transferFile,
    required _TransferSession currentSession,
    required Duration timeout,
    bool terminalOnly = false,
    bool forceReconnect = false,
    Object? cause,
  }) async {
    Object? reconnectError = cause;
    if (!forceReconnect) {
      try {
        return _AcceptedSession(
          session: currentSession,
          accepted: await currentSession.untilDisconnected(
            _waitForAcceptance(
              currentSession.inbox,
              batch,
              transferFile,
              timeout: timeout,
              terminalOnly: terminalOnly,
            ),
          ),
        );
      } catch (error) {
        if (!_isTransientTransferError(error) || reconnectBackoff.isEmpty) {
          rethrow;
        }
        reconnectError = error;
      }
    }
    await currentSession.close();
    for (final delay in reconnectBackoff) {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      _TransferSession? replacement;
      try {
        replacement = await _openSession(pairing, batch);
        return _AcceptedSession(
          session: replacement,
          accepted: await replacement.untilDisconnected(
            _waitForAcceptance(
              replacement.inbox,
              batch,
              transferFile,
              timeout: timeout,
              terminalOnly: terminalOnly,
            ),
          ),
        );
      } catch (candidate) {
        reconnectError = candidate;
        await replacement?.close();
        if (!_isTransientTransferError(candidate)) rethrow;
      }
    }
    throw reconnectError ?? StateError('Transfer reconnect failed.');
  }

  Future<_AppliedAcceptance> _applyAcceptance({
    required PhoneTransferBatch batch,
    required int index,
    required PhoneTransferFile transferFile,
    required _AcceptedTransfer accepted,
    required Stopwatch stopwatch,
  }) async {
    final effectiveChunkBytes = TransferChunkPolicy.negotiate(
      accepted.maxChunkBytes,
      localMaximum: chunkBytes,
    );
    final updatedFile = transferFile.copyWith(
      status: PhoneTransferStatus.active,
      confirmedOffset: accepted.confirmedOffset,
    );
    final updatedBatch = await _replaceFile(batch, index, updatedFile);
    _publishBatch(
      updatedBatch,
      stage: PhoneTransferProgressStage.transferring,
      currentFileIndex: index,
      currentFilename: updatedFile.filename,
      bytesPerSecond: _bytesPerSecond(updatedBatch, stopwatch),
    );
    return _AppliedAcceptance(
      batch: updatedBatch,
      transferFile: updatedFile,
      offset: accepted.confirmedOffset,
      effectiveChunkBytes: effectiveChunkBytes,
    );
  }

  Future<_AcceptedTransfer> _waitForAcceptance(
    _TransferControlInbox inbox,
    PhoneTransferBatch batch,
    PhoneTransferFile transferFile, {
    required Duration timeout,
    bool terminalOnly = false,
  }) async {
    final accepted = await inbox.nextWhere(
      (message) =>
          ((!terminalOnly && message['kind'] == 'transfer_accept') ||
              message['kind'] == 'transfer_file_complete' ||
              message['kind'] == 'transfer_file_failed') &&
          message['transferId'] == batch.transferId &&
          message['fileId'] == transferFile.fileId,
      timeout: timeout,
    );
    if (accepted['kind'] == 'transfer_file_failed') {
      throw _TransferRejected(
        accepted['code'] is String
            ? accepted['code']! as String
            : 'transfer_rejected',
        context: _messageErrorContext(accepted),
      );
    }
    if (accepted['kind'] == 'transfer_file_complete') {
      if (accepted['sha256'] != transferFile.sha256) {
        throw const FormatException(
          'Laptop returned an invalid completion digest.',
        );
      }
      return _AcceptedTransfer(
        confirmedOffset: transferFile.size,
        maxChunkBytes: null,
        complete: true,
      );
    }
    final rawOffset = accepted['confirmedOffset'];
    if (rawOffset is! int || rawOffset < 0 || rawOffset > transferFile.size) {
      throw const FormatException('Laptop returned an invalid resume offset.');
    }
    return _AcceptedTransfer(
      confirmedOffset: rawOffset,
      maxChunkBytes: accepted['maxChunkBytes'],
      complete: false,
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
    final uri = Uri.parse('http://${pairing.host}:${pairing.port}$path');
    final request = await client.putUrl(uri);
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
    Map<String, Object?> json = {};
    if (body.isNotEmpty) {
      try {
        final decoded = jsonDecode(body);
        if (decoded is! Map) {
          throw const FormatException('Transfer response must be an object.');
        }
        json = decoded.cast<String, Object?>();
      } catch (_) {
        if (response.statusCode >= 200 && response.statusCode < 300) rethrow;
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (json['code'] == 'offset_not_confirmed' &&
          json['confirmedOffset'] is int) {
        throw _TransferOffsetConflict(json['confirmedOffset']! as int);
      }
      if (response.statusCode == 429 || response.statusCode >= 500) {
        throw HttpException(
          (json['code'] as String?) ?? 'HTTP ${response.statusCode}',
          uri: uri,
        );
      }
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
            if (!file.lastModifiedKnown) 'lastModifiedKnown': false,
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

const _unknownSha256 =
    '0000000000000000000000000000000000000000000000000000000000000000';

class _ChunkResult {
  const _ChunkResult({required this.confirmedOffset, required this.complete});

  final int confirmedOffset;
  final bool complete;
}

class _AcceptedTransfer {
  const _AcceptedTransfer({
    required this.confirmedOffset,
    required this.maxChunkBytes,
    required this.complete,
  });

  final int confirmedOffset;
  final Object? maxChunkBytes;
  final bool complete;
}

class _AcceptedSession {
  const _AcceptedSession({required this.session, required this.accepted});

  final _TransferSession session;
  final _AcceptedTransfer accepted;
}

class _AppliedAcceptance {
  const _AppliedAcceptance({
    required this.batch,
    required this.transferFile,
    required this.offset,
    required this.effectiveChunkBytes,
  });

  final PhoneTransferBatch batch;
  final PhoneTransferFile transferFile;
  final int offset;
  final int effectiveChunkBytes;
}

class _TransferOffsetConflict implements Exception {
  const _TransferOffsetConflict(this.confirmedOffset);

  final int confirmedOffset;
}

class _TransferRejected implements Exception {
  const _TransferRejected(this.code, {this.context});

  final String code;
  final Map<String, Object?>? context;

  @override
  String toString() => 'Transfer rejected: $code';
}

class _TransferSession {
  _TransferSession({
    required this.connection,
    required this.inbox,
    required this.client,
  }) {
    _statusSubscription = connection.status.listen((status) {
      if (status == ConnectionStatus.offline && !_disconnected.isCompleted) {
        _disconnected.complete();
      }
    });
  }

  final RelayConnection connection;
  final _TransferControlInbox inbox;
  final HttpClient client;
  final _disconnected = Completer<void>();
  late final StreamSubscription<ConnectionStatus> _statusSubscription;
  bool _closed = false;

  Future<T> untilDisconnected<T>(Future<T> operation) {
    return Future.any([
      operation,
      _disconnected.future.then<T>(
        (_) =>
            throw const SocketException('Relay transfer control disconnected.'),
      ),
    ]);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    client.close(force: true);
    await _statusSubscription.cancel();
    await inbox.close();
    await connection.close();
  }
}

class _TransferControlInbox {
  _TransferControlInbox(Stream<Map<String, Object?>> stream) {
    _subscription = stream.listen(
      _receive,
      onDone: () => _failPending(
        const SocketException('Relay transfer control disconnected.'),
      ),
      onError: (Object error, StackTrace stackTrace) {
        _failPending(error, stackTrace);
      },
    );
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

  void _failPending(Object error, [StackTrace? stackTrace]) {
    final waiters = [..._waiters];
    _waiters.clear();
    for (final waiter in waiters) {
      waiter.completer.completeError(error, stackTrace);
    }
  }

  Future<void> close() async {
    _failPending(const SocketException('Relay transfer control closed.'));
    await _subscription.cancel();
  }
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
  if (error case _TransferRejected(:final code)) return code;
  final message = error.toString().toLowerCase();
  if (message.contains('timeout')) return 'timeout';
  if (message.contains('source')) return 'source_unavailable';
  if (message.contains('size') || message.contains('large')) {
    return 'file_too_large';
  }
  return 'transfer_failed';
}

String _errorOrigin(Object error) {
  return error is _TransferRejected ? 'remote' : 'local';
}

String _errorCategory(Object error) {
  final code = _errorCode(error);
  if (error is _TransferRejected) return 'remote_rejection';
  if (code == 'file_too_large') return 'local_preparation';
  if (code == 'timeout' || _isTransientTransferError(error)) {
    return 'network_policy';
  }
  if (code == 'source_unavailable') return 'source_access';
  if (code == 'hash_mismatch') return 'integrity';
  return 'internal';
}

String _errorDetail(Object error) {
  if (error is _TransferRejected) {
    return 'Receiver rejected the file with code ${error.code}.';
  }
  final message = error.toString();
  final sanitized = message.replaceAll(RegExp(r'\s+'), ' ').trim();
  return sanitized.length > 240 ? sanitized.substring(0, 240) : sanitized;
}

Map<String, Object?>? _errorContext(Object error) {
  if (error case _TransferRejected(:final context)) return context;
  return null;
}

Map<String, Object?>? _messageErrorContext(Map<String, Object?> message) {
  final context = <String, Object?>{};
  for (final key in ['actualBytes', 'limitBytes', 'phase', 'retryable']) {
    final value = message[key];
    if (value is int || value is String || value is bool) {
      context[key] = value;
    }
  }
  return context.isEmpty ? null : context;
}

bool _isTransientTransferError(Object error) =>
    error is SocketException ||
    error is HttpException ||
    error is TimeoutException;
