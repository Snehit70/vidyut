import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as hashes;
import 'package:convert/convert.dart';
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

  Future<VidyutStagedSource> stage(
    String uri, {
    required int maximumBytes,
    String? operationId,
  });

  Future<void> cancelStage(String operationId) async {}

  Future<List<int>> readAt(
    String uri, {
    required int offset,
    required int length,
  });

  Future<void> release(String reference) async {}

  Future<void> retain(String reference) async {}

  Future<void> discard(String reference) async {}
}

class VidyutFilesSourceReader implements PhoneTransferSourceReader {
  const VidyutFilesSourceReader([this.files = const VidyutFiles()]);

  final VidyutFiles files;

  @override
  Future<VidyutSourceProbe> probe(String uri) => files.probeSource(uri);

  @override
  Future<String> hashSha256(String uri) => files.hashSource(uri);

  @override
  Future<VidyutStagedSource> stage(
    String uri, {
    required int maximumBytes,
    String? operationId,
  }) => files.stageSource(
    uri,
    maximumBytes: maximumBytes,
    operationId: operationId,
  );

  @override
  Future<void> cancelStage(String operationId) =>
      files.cancelStage(operationId);

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

  @override
  Future<void> discard(String reference) => files.discardSource(reference);
}

class PreparationCancelled implements Exception {
  const PreparationCancelled();

  @override
  String toString() => 'Preparation was cancelled.';
}

class _PreparationToken {
  bool cancelled = false;
  Future<void> Function(String operationId)? _cancelStage;
  String? _operationId;

  void registerStageCancellation(
    String operationId,
    Future<void> Function(String operationId) cancelStage,
  ) {
    _cancelStage = (id) => cancelStage(id);
    _operationId = operationId;
    if (cancelled) unawaited(_cancelStage!(operationId));
  }

  void cancel() {
    cancelled = true;
    final cancelStage = _cancelStage;
    final operationId = _operationId;
    if (cancelStage != null && operationId != null) {
      unawaited(cancelStage(operationId));
    }
  }

  void check() {
    if (cancelled) throw const PreparationCancelled();
  }
}

typedef TransferRelayConnectionFactory =
    RelayConnection Function(PairingCode pairing);

enum PhoneTransferProgressStage {
  preparing,
  readingSelection,
  staging,
  hashing,
  policyCheck,
  connecting,
  waitingForLaptop,
  transferring,
  cancelling,
  waitingForSource,
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
    this.preparationPhase,
    this.preparedBytes = 0,
    this.preparationTotalBytes,
    this.preparationStartedAt,
  });

  final PhoneTransferProgressStage stage;
  final int fileCount;
  final int totalBytes;
  final int transferredBytes;
  final int? currentFileIndex;
  final String? currentFilename;
  final double? bytesPerSecond;
  final String? transferId;
  final PhoneTransferPreparationPhase? preparationPhase;
  final int preparedBytes;
  final int? preparationTotalBytes;
  final int? preparationStartedAt;

  Duration? get preparationElapsed {
    final started = preparationStartedAt;
    if (started == null) return null;
    return Duration(
      milliseconds: DateTime.now().millisecondsSinceEpoch - started,
    );
  }

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
    this.monotonicClock,
    this.wallClock,
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
  final MonotonicClock? monotonicClock;
  final MonotonicClock? wallClock;
  final FutureOr<void> Function(PhoneTransferBatch batch)? onBatchCreated;
  final List<Duration> reconnectBackoff;
  final _progressController =
      StreamController<PhoneTransferProgress>.broadcast();
  final _batchCreatedController =
      StreamController<PhoneTransferBatch>.broadcast();
  late final _snapshotController =
      StreamController<PhoneTransferBatch>.broadcast(
        onListen: () => unawaited(_emitSnapshots()),
      );
  final _preparationTokens = <String, _PreparationToken>{};
  final _preparationRuns = <String, Future<void>>{};
  final _cancelledFiles = <String>{};
  final _activeTransferCancellations = <String, _ActiveTransferCancellation>{};
  final _lastPreparationPersist = <String, int>{};
  final _lastPreparationPublish = <String, int>{};
  final _timingAnchors = <String, int>{};
  final _defaultMonotonicClock = Stopwatch()..start();
  Future<void>? _resumeRun;
  Future<void> _sendTail = Future<void>.value();
  final _sendPredecessors = <String, Future<void>>{};
  final _sendTurnCompleters = <String, Completer<void>>{};

  Stream<PhoneTransferProgress> get progress => _progressController.stream;
  Stream<PhoneTransferBatch> get batchesCreated =>
      _batchCreatedController.stream;
  Stream<PhoneTransferBatch> get snapshots => _snapshotController.stream;

  int _monotonicNow() =>
      monotonicClock?.call() ?? _defaultMonotonicClock.elapsedMilliseconds;

  int _wallNow() => wallClock?.call() ?? DateTime.now().millisecondsSinceEpoch;

  TransferTimingSummary _newTiming(int wallAnchorMs) => TransferTimingSummary(
    wallAnchorMs: wallAnchorMs,
    attempts: [const TransferAttemptTiming(attempt: 0, stages: {})],
  );

  Future<void> _emitSnapshots() async {
    for (final batch in await history.load()) {
      if (!_snapshotController.isClosed) _snapshotController.add(batch);
    }
  }

  void _registerSendTurn(String transferId) {
    if (_sendTurnCompleters.containsKey(transferId)) return;
    final completer = Completer<void>();
    _sendPredecessors[transferId] = _sendTail;
    _sendTurnCompleters[transferId] = completer;
    _sendTail = completer.future;
  }

  void _completeSendTurn(String transferId) {
    final completer = _sendTurnCompleters.remove(transferId);
    _sendPredecessors.remove(transferId);
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  /// Requests cancellation without making the Files screen the owner of the
  /// work. The request is durable before the active preparation is invalidated.
  Future<void> cancelFile(String transferId, String fileId) async {
    final batch = (await history.load())
        .where((item) => item.transferId == transferId)
        .firstOrNull;
    if (batch == null) return;
    final index = batch.files.indexWhere((file) => file.fileId == fileId);
    if (index < 0) return;
    final file = batch.files[index];
    if (_isTerminal(file.status)) return;
    if (file.status == PhoneTransferStatus.active &&
        file.preparationPhase == null) {
      final key = '$transferId:$fileId';
      final active = _activeTransferCancellations[key];
      if (active == null) return;
      final requestedAt = DateTime.now().millisecondsSinceEpoch;
      final updated = await _replaceFile(
        batch,
        index,
        file.copyWith(cancellationRequestedAt: requestedAt),
      );
      _publishBatch(updated, stage: PhoneTransferProgressStage.cancelling);
      _cancelledFiles.add(key);
      await active.cancel();
      return;
    }
    final requestedAt = DateTime.now().millisecondsSinceEpoch;
    var updated = await _replaceFile(
      batch,
      index,
      file.copyWith(
        cancellationRequestedAt: requestedAt,
        status: PhoneTransferStatus.preparing,
      ),
    );
    _publishBatch(updated, stage: PhoneTransferProgressStage.cancelling);
    _cancelledFiles.add('$transferId:${file.fileId}');
    _preparationTokens['${file.fileId}:${file.preparationAttempt}']?.cancel();
    await _finishCancellation(updated, index);
  }

  Future<void> cancelBatch(String transferId) async {
    final batch = (await history.load())
        .where((item) => item.transferId == transferId)
        .firstOrNull;
    if (batch == null) return;
    for (final file in batch.files.where((file) => !_isTerminal(file.status))) {
      await cancelFile(transferId, file.fileId);
    }
  }

  Future<void> removeHistory(PhoneTransferBatch batch) async {
    for (final file in batch.files) {
      final reference = file.sourceReference;
      if (reference == null) continue;
      if (reference.ownership == PhoneTransferSourceOwnership.managed ||
          reference.kind == PhoneTransferSourceKind.androidDocumentUri) {
        await sourceReader.release(reference.reference);
      }
    }
    await history.remove(batch.transferId);
  }

  Future<void> clearHistory() async {
    for (final batch in await history.load()) {
      if (batch.direction == PhoneTransferDirection.sent) {
        for (final file in batch.files) {
          final reference = file.sourceReference;
          if (reference != null &&
              (reference.ownership == PhoneTransferSourceOwnership.managed ||
                  reference.kind ==
                      PhoneTransferSourceKind.androidDocumentUri)) {
            await sourceReader.release(reference.reference);
          }
        }
      }
    }
    await history.clear();
  }

  Future<void> _finishCancellation(PhoneTransferBatch batch, int index) async {
    final file = batch.files[index];
    final reference = file.sourceReference;
    if (reference?.ownership == PhoneTransferSourceOwnership.managed) {
      // A managed reference persisted in the row is already committed. Keep
      // it available for an explicit retry; only an uncommitted stage is
      // eligible for discard by the source reader.
    } else if (reference?.kind == PhoneTransferSourceKind.androidDocumentUri) {
      await sourceReader.release(reference!.reference);
    }
    final cancelled = await _replaceFile(
      batch,
      index,
      file.copyWith(
        status: PhoneTransferStatus.cancelled,
        clearPreparationPhase: true,
        clearCancellationRequestedAt: true,
      ),
    );
    await history.upsert(
      cancelled.copyWith(status: _deriveBatchStatus(cancelled.files)),
    );
    _publishBatch(cancelled, stage: PhoneTransferProgressStage.failed);
  }

  static bool _isTerminal(PhoneTransferStatus status) =>
      status == PhoneTransferStatus.completed ||
      status == PhoneTransferStatus.failed ||
      status == PhoneTransferStatus.cancelled ||
      status == PhoneTransferStatus.expired;

  /// Reopens durable sources after an isolate/process restart. Native source
  /// sessions are intentionally not reused; each URI or managed stage is
  /// probed again before an unfinished offer resumes.
  Future<void> resumePending() async {
    final existing = _resumeRun;
    if (existing != null) return existing;
    final run = () async {
      for (final batch in await history.load()) {
        if (batch.direction != PhoneTransferDirection.sent ||
            (batch.status != PhoneTransferStatus.preparing &&
                batch.status != PhoneTransferStatus.queued &&
                batch.status != PhoneTransferStatus.active)) {
          continue;
        }
        final sources = <PhoneTransferSource>[];
        try {
          for (final file in batch.files) {
            if (_isTerminal(file.status)) continue;
            sources.add(_sourceForFile(file));
          }
          if (sources.isNotEmpty) {
            _registerSendTurn(batch.transferId);
            await _schedulePreparation(batch, sources);
          }
        } on Object catch (error) {
          final failed = batch.copyWith(
            status: PhoneTransferStatus.failed,
            files: batch.files
                .map(
                  (file) => _isTerminal(file.status)
                      ? file
                      : file.copyWith(
                          status: PhoneTransferStatus.failed,
                          clearPreparationPhase: true,
                          errorCode: _errorCode(error),
                          errorOrigin: _errorOrigin(error),
                          errorCategory: _errorCategory(error),
                          errorDetail: _errorDetail(error),
                          errorContext: _errorContext(error),
                        ),
                )
                .toList(growable: false),
          );
          await history.upsert(failed);
        }
      }
    }();
    _resumeRun = run;
    try {
      await run;
    } finally {
      _resumeRun = null;
    }
  }

  Future<PhoneTransferBatch> enqueue(List<PhoneTransferSource> sources) async {
    if (sources.isEmpty) {
      throw const FormatException('Select at least one file.');
    }
    final now = _wallNow();
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
              preparationPhase: PhoneTransferPreparationPhase.readingSelection,
              preparationStartedAt: now,
              preparationAttempt: 0,
              timing: _newTiming(now),
            ),
          )
          .toList(growable: false),
    );
    for (var index = 0; index < batch.files.length; index++) {
      batch = _markTimingValue(
        batch,
        index,
        TransferTimingStage.pickerCallback,
        end: true,
      );
      batch = _markTimingValue(
        batch,
        index,
        TransferTimingStage.durableQueueCard,
      );
    }
    // Persist before provider metadata, probing, hashing, policy, pairing, or
    // relay work. This is the durable boundary used by restart recovery.
    await history.upsert(batch);
    _registerSendTurn(batch.transferId);
    for (var index = 0; index < batch.files.length; index++) {
      batch = _markTimingValue(
        batch,
        index,
        TransferTimingStage.durableQueueCard,
        end: true,
      );
      batch = _markTimingValue(
        batch,
        index,
        TransferTimingStage.firstVisiblePublication,
      );
    }
    _snapshotController.add(batch);
    for (var index = 0; index < batch.files.length; index++) {
      batch = _markTimingValue(
        batch,
        index,
        TransferTimingStage.firstVisiblePublication,
        end: true,
      );
    }
    await history.upsert(batch);
    _batchCreatedController.add(batch);
    await onBatchCreated?.call(batch);
    unawaited(_schedulePreparation(batch, sources));
    return batch;
  }

  /// Waits for the durable sender-owned run to reach a terminal file state.
  /// Enqueue itself intentionally returns the visible preparing card first.
  Future<PhoneTransferBatch> waitForTerminal(
    String transferId, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final batch = (await history.load())
          .where((item) => item.transferId == transferId)
          .firstOrNull;
      if (batch == null) {
        throw StateError('Transfer $transferId no longer exists.');
      }
      if (batch.files.isNotEmpty &&
          batch.files.every((file) => _isTerminal(file.status))) {
        return batch;
      }
      if (!DateTime.now().isBefore(deadline)) {
        throw TimeoutException('Timed out waiting for transfer $transferId.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<void> _schedulePreparation(
    PhoneTransferBatch initial,
    List<PhoneTransferSource> sources,
  ) {
    final existing = _preparationRuns[initial.transferId];
    if (existing != null) return existing;
    final run = _runPreparation(initial, sources);
    _preparationRuns[initial.transferId] = run;
    return run.whenComplete(() => _preparationRuns.remove(initial.transferId));
  }

  Future<void> _runPreparation(
    PhoneTransferBatch initial,
    List<PhoneTransferSource> sources,
  ) async {
    var batch = initial;
    final retainedUris = <String>[];
    final pairingFuture = pairingRepository.load();
    Future<_TransferSession?>? setupFuture;
    AsyncError? setupError;
    _TransferSession? handedOffSession;
    try {
      for (final source in sources) {
        if (source.uri != null && source.persisted) {
          await sourceReader.retain(source.uri!);
          retainedUris.add(source.uri!);
        }
      }
      _publishBatch(batch, stage: PhoneTransferProgressStage.preparing);
      final maximum = maximumFileBytes == null
          ? 1024 * 1024 * 1024
          : await maximumFileBytes!();
      if (networkAllowed != null && !await networkAllowed!()) {
        throw StateError(
          'File transfers are disabled on this metered network.',
        );
      }
      if (sources.any((source) => source.uri != null && source.persisted)) {
        // Authentication and relay setup do not depend on the source digest.
        // Keep the offer itself behind the preparation barrier.
        setupFuture = _prepareRelaySession(
          pairingFuture,
          onError: (error) => setupError = error,
        );
      }
      final fileIndexes = batch.files
          .asMap()
          .entries
          .where((entry) => !_isTerminal(entry.value.status))
          .map((entry) => entry.key)
          .toList(growable: false);
      var sourceBlocked = false;
      for (var sourceIndex = 0; sourceIndex < sources.length; sourceIndex++) {
        final index = fileIndexes[sourceIndex];
        final file = batch.files[index];
        if (_cancelledFiles.contains('${batch.transferId}:${file.fileId}')) {
          throw const PreparationCancelled();
        }
        final token = _PreparationToken();
        final key = '${file.fileId}:${file.preparationAttempt}';
        _preparationTokens[key] = token;
        try {
          batch = await _updatePreparationPhase(
            batch,
            PhoneTransferPreparationPhase.readingSelection,
            index: index,
            token: token,
          );
          final prepared = await _prepareSource(
            sources[sourceIndex],
            maximum,
            token: token,
            onPhase: (phase, bytes, total) async {
              batch = await _updatePreparationProgress(
                batch,
                index,
                phase: phase,
                preparedBytes: bytes,
                preparationTotalBytes: total,
                token: token,
              );
            },
            onTiming: (stage, end) async {
              batch = await _markTiming(batch, index, stage, end: end);
            },
          );
          token.check();
          batch = await _updatePreparationPhase(
            batch,
            PhoneTransferPreparationPhase.policyCheck,
            index: index,
            token: token,
          );
          token.check();
          batch = await _replaceFile(
            batch,
            index,
            file.copyWith(
              filename: _safeBasename(prepared.filename),
              mime: prepared.mime,
              size: prepared.size,
              lastModifiedMs: prepared.lastModifiedMs,
              lastModifiedKnown: prepared.lastModifiedKnown,
              sha256: prepared.sha256,
              status: PhoneTransferStatus.queued,
              sourceReference: prepared.reference,
              clearPreparationPhase: true,
              preparedBytes: prepared.size,
              preparationTotalBytes: prepared.size,
            ),
          );
        } on Object catch (error) {
          if (_errorCode(error) != 'source_unavailable') {
            rethrow;
          }
          sourceBlocked = true;
          batch = await _replaceFile(
            batch,
            index,
            file.copyWith(
              status: PhoneTransferStatus.waitingForSource,
              clearPreparationPhase: true,
              errorCode: 'source_unavailable',
              errorOrigin: 'local',
              errorCategory: 'source_access',
              errorDetail: _errorDetail(error),
            ),
          );
        } finally {
          _preparationTokens.remove(key);
          _cancelledFiles.remove('${batch.transferId}:${file.fileId}');
        }
      }
      if (sourceBlocked) {
        await pairingFuture;
        batch = batch.copyWith(
          status: PhoneTransferStatus.waitingForSource,
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        );
        await history.upsert(batch);
        _publishBatch(
          batch,
          stage: PhoneTransferProgressStage.waitingForSource,
        );
        return;
      }
      batch = batch.copyWith(
        status: PhoneTransferStatus.queued,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      await history.upsert(batch);
      final pairing = await pairingFuture;
      if (pairing == null) {
        throw StateError('Pair with a laptop before sending files.');
      }
      final preparedSession = setupFuture == null ? null : await setupFuture;
      if (setupError case final error?) {
        Error.throwWithStackTrace(error.error, error.stackTrace);
      }
      handedOffSession = preparedSession;
      final predecessor = _sendPredecessors[initial.transferId];
      if (predecessor != null) await predecessor;
      await _send(pairing, batch, preparedSession: preparedSession);
    } on PreparationCancelled {
      final latest = (await history.load())
          .where((item) => item.transferId == batch.transferId)
          .firstOrNull;
      if (latest != null) {
        for (var i = 0; i < latest.files.length; i++) {
          if (!_isTerminal(latest.files[i].status)) {
            await _finishCancellation(latest, i);
          }
        }
      }
    } on Object catch (error) {
      batch = batch.copyWith(
        status: PhoneTransferStatus.failed,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        files: batch.files
            .map(
              (file) => _isTerminal(file.status)
                  ? file
                  : file.copyWith(
                      status: PhoneTransferStatus.failed,
                      clearPreparationPhase: true,
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
    } finally {
      final pendingSetup = setupFuture;
      if (pendingSetup != null) {
        try {
          final prepared = await pendingSetup;
          if (prepared != null && !identical(prepared, handedOffSession)) {
            await prepared.close();
          }
        } catch (_) {
          // The preparation error already owns the durable failure state.
        }
      }
      if (setupFuture == null) {
        try {
          await pairingFuture;
        } catch (_) {
          // The preparation error already owns the durable failure state.
        }
      }
      for (final uri in retainedUris) {
        await sourceReader.release(uri);
      }
      _completeSendTurn(initial.transferId);
    }
  }

  Future<_TransferSession?> _prepareRelaySession(
    Future<PairingCode?> pairingFuture, {
    required void Function(AsyncError error) onError,
  }) async {
    try {
      final pairing = await pairingFuture;
      if (pairing == null) {
        throw StateError('Pair with a laptop before sending files.');
      }
      return await _connectSession(pairing);
    } on Object catch (error, stackTrace) {
      onError(AsyncError(error, stackTrace));
      return null;
    }
  }

  Future<
    ({
      int size,
      int lastModifiedMs,
      bool lastModifiedKnown,
      String filename,
      String mime,
      String sha256,
      PhoneTransferSourceReference? reference,
    })
  >
  _prepareSource(
    PhoneTransferSource source,
    int maxBytes, {
    required _PreparationToken token,
    required Future<void> Function(
      PhoneTransferPreparationPhase phase,
      int bytes,
      int? total,
    )
    onPhase,
    required Future<void> Function(String stage, bool end) onTiming,
  }) async {
    if (source.path case final path?) {
      final file = File(path);
      await onTiming(TransferTimingStage.sourceOpenProbe, false);
      late final FileStat info;
      try {
        info = await file.stat();
      } finally {
        await onTiming(TransferTimingStage.sourceOpenProbe, true);
      }
      token.check();
      if (info.type != FileSystemEntityType.file) {
        throw FormatException('Only regular files can be sent: $path');
      }
      if (info.size > maxBytes) {
        throw FormatException(
          '${source.filename} exceeds the configured maximum file size.',
        );
      }
      await onPhase(PhoneTransferPreparationPhase.hashing, 0, info.size);
      await onTiming(TransferTimingStage.sourceHash, false);
      late final String digest;
      try {
        digest = await _hashFile(
          file,
          token: token,
          onBytes: (bytes) =>
              onPhase(PhoneTransferPreparationPhase.hashing, bytes, info.size),
        );
      } finally {
        await onTiming(TransferTimingStage.sourceHash, true);
      }
      return (
        size: info.size,
        lastModifiedMs: info.modified.millisecondsSinceEpoch,
        lastModifiedKnown: true,
        filename: source.filename,
        mime: source.mime,
        sha256: digest,
        reference: null,
      );
    }
    final uri = source.uri!;
    token.check();
    await onTiming(TransferTimingStage.sourceOpenProbe, false);
    late final VidyutSourceProbe probe;
    try {
      probe = await sourceReader.probe(uri);
    } finally {
      await onTiming(TransferTimingStage.sourceOpenProbe, true);
    }
    token.check();
    if (!source.persisted ||
        !probe.seekable ||
        !probe.sizeKnown ||
        probe.size < 0) {
      await onPhase(PhoneTransferPreparationPhase.staging, 0, null);
      await onTiming(TransferTimingStage.fallbackStage, false);
      final operationId = _id('stage');
      token.registerStageCancellation(operationId, sourceReader.cancelStage);
      late final VidyutStagedSource staged;
      try {
        staged = await sourceReader.stage(
          uri,
          maximumBytes: maxBytes,
          operationId: operationId,
        );
      } catch (_) {
        token.check();
        rethrow;
      } finally {
        await onTiming(TransferTimingStage.fallbackStage, true);
      }
      token.check();
      await onPhase(
        PhoneTransferPreparationPhase.staging,
        staged.size,
        staged.size,
      );
      return (
        size: staged.size,
        lastModifiedMs: staged.lastModifiedMs ?? source.lastModifiedMs ?? 0,
        lastModifiedKnown:
            staged.lastModifiedMs != null || source.lastModifiedMs != null,
        filename: probe.filename ?? source.filename,
        mime: probe.mime ?? source.mime,
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
    await onPhase(PhoneTransferPreparationPhase.hashing, 0, probe.size);
    token.check();
    await onTiming(TransferTimingStage.sourceHash, false);
    late final String digest;
    try {
      digest = await sourceReader.hashSha256(uri);
    } finally {
      await onTiming(TransferTimingStage.sourceHash, true);
    }
    token.check();
    await onPhase(
      PhoneTransferPreparationPhase.hashing,
      probe.size,
      probe.size,
    );
    return (
      size: probe.size,
      lastModifiedMs: source.lastModifiedMs ?? 0,
      lastModifiedKnown: source.lastModifiedMs != null,
      filename: probe.filename ?? source.filename,
      mime: probe.mime ?? source.mime,
      sha256: digest,
      reference: null,
    );
  }

  Future<PhoneTransferBatch> _updatePreparationPhase(
    PhoneTransferBatch batch,
    PhoneTransferPreparationPhase phase, {
    int? index,
    _PreparationToken? token,
  }) async {
    token?.check();
    if (index == null) {
      final files = batch.files
          .map(
            (file) => file.status == PhoneTransferStatus.preparing
                ? file.copyWith(
                    preparationPhase: phase,
                    preparedBytes: 0,
                    preparationStartedAt:
                        file.preparationStartedAt ?? batch.createdAtMs,
                  )
                : file,
          )
          .toList(growable: false);
      final updated = batch.copyWith(files: files);
      await history.upsert(updated);
      _publishBatch(updated, stage: _progressStageForPhase(phase));
      return updated;
    }
    final file = batch.files[index];
    final updated = await _replaceFile(
      batch,
      index,
      file.copyWith(
        preparationPhase: phase,
        preparedBytes: 0,
        preparationStartedAt: file.preparationStartedAt ?? batch.createdAtMs,
      ),
    );
    _publishBatch(
      updated,
      stage: _progressStageForPhase(phase),
      currentFileIndex: index,
      currentFilename: file.filename,
    );
    return updated;
  }

  Future<PhoneTransferBatch> _updatePreparationProgress(
    PhoneTransferBatch batch,
    int index, {
    required PhoneTransferPreparationPhase phase,
    required int preparedBytes,
    required int? preparationTotalBytes,
    required _PreparationToken token,
  }) async {
    token.check();
    final file = batch.files[index];
    final safeBytes = preparedBytes < file.preparedBytes
        ? file.preparedBytes
        : preparedBytes;
    final now = DateTime.now().millisecondsSinceEpoch;
    final key = '${file.fileId}:${file.preparationAttempt}';
    final shouldPersist =
        file.preparationPhase != phase ||
        safeBytes == preparationTotalBytes ||
        now - (_lastPreparationPersist[key] ?? 0) >= 1000;
    final updated = await _replaceFile(
      batch,
      index,
      file.copyWith(
        preparationPhase: phase,
        preparedBytes: safeBytes,
        preparationTotalBytes: preparationTotalBytes,
        preparationStartedAt: file.preparationStartedAt ?? batch.createdAtMs,
      ),
      persist: shouldPersist,
    );
    if (shouldPersist) _lastPreparationPersist[key] = now;
    if (now - (_lastPreparationPublish[key] ?? 0) >= 100 ||
        safeBytes == preparationTotalBytes ||
        file.preparationPhase != phase) {
      _lastPreparationPublish[key] = now;
      _publishBatch(
        updated,
        stage: _progressStageForPhase(phase),
        currentFileIndex: index,
        currentFilename: file.filename,
      );
    }
    return updated;
  }

  PhoneTransferProgressStage _progressStageForPhase(
    PhoneTransferPreparationPhase phase,
  ) => switch (phase) {
    PhoneTransferPreparationPhase.readingSelection =>
      PhoneTransferProgressStage.readingSelection,
    PhoneTransferPreparationPhase.staging => PhoneTransferProgressStage.staging,
    PhoneTransferPreparationPhase.hashing => PhoneTransferProgressStage.hashing,
    PhoneTransferPreparationPhase.policyCheck =>
      PhoneTransferProgressStage.policyCheck,
    PhoneTransferPreparationPhase.connecting =>
      PhoneTransferProgressStage.connecting,
  };

  PhoneTransferStatus _deriveBatchStatus(List<PhoneTransferFile> files) {
    if (files.any((file) => file.status == PhoneTransferStatus.active)) {
      return PhoneTransferStatus.active;
    }
    if (files.any((file) => file.status == PhoneTransferStatus.preparing)) {
      return PhoneTransferStatus.preparing;
    }
    if (files.any(
      (file) => file.status == PhoneTransferStatus.waitingForSource,
    )) {
      return PhoneTransferStatus.waitingForSource;
    }
    if (files.any((file) => file.status == PhoneTransferStatus.queued)) {
      return PhoneTransferStatus.queued;
    }
    if (files.every((file) => file.status == PhoneTransferStatus.completed)) {
      return PhoneTransferStatus.completed;
    }
    if (files.any((file) => file.status == PhoneTransferStatus.completed)) {
      return PhoneTransferStatus.completedWithIssues;
    }
    if (files.every((file) => file.status == PhoneTransferStatus.cancelled)) {
      return PhoneTransferStatus.cancelled;
    }
    return PhoneTransferStatus.failed;
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
    final retryable = batch.files
        .where(
          (file) =>
              !_isTerminal(file.status) ||
              file.status == PhoneTransferStatus.failed ||
              file.status == PhoneTransferStatus.cancelled,
        )
        .toList(growable: false);
    final now = DateTime.now().millisecondsSinceEpoch;
    final reset = batch.copyWith(
      status: PhoneTransferStatus.preparing,
      updatedAtMs: now,
      files: batch.files
          .map(
            (file) => retryable.contains(file)
                ? file.copyWith(
                    status: PhoneTransferStatus.preparing,
                    confirmedOffset: 0,
                    clearError: true,
                    preparationPhase:
                        PhoneTransferPreparationPhase.readingSelection,
                    preparedBytes: 0,
                    clearPreparationTotalBytes: true,
                    preparationStartedAt: now,
                    preparationAttempt: file.preparationAttempt + 1,
                    clearCancellationRequestedAt: true,
                  )
                : file,
          )
          .toList(),
    );
    await history.upsert(reset);
    _registerSendTurn(reset.transferId);
    final sources = <PhoneTransferSource>[];
    for (final file in reset.files) {
      if (file.status == PhoneTransferStatus.preparing) {
        _cancelledFiles.remove('${reset.transferId}:${file.fileId}');
        sources.add(_sourceForFile(file));
      }
    }
    unawaited(_schedulePreparation(reset, sources));
    return reset;
  }

  Future<PhoneTransferBatch> _send(
    PairingCode pairing,
    PhoneTransferBatch initial, {
    _TransferSession? preparedSession,
  }) async {
    var batch = initial.copyWith(
      status: PhoneTransferStatus.active,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    await history.upsert(batch);
    if (batch.files.isNotEmpty) {
      batch = await _replaceFile(
        batch,
        0,
        batch.files.first.copyWith(
          status: PhoneTransferStatus.active,
          preparationPhase: PhoneTransferPreparationPhase.connecting,
          preparedBytes: 0,
          preparationStartedAt:
              batch.files.first.preparationStartedAt ?? batch.createdAtMs,
        ),
      );
      _publishBatch(
        batch,
        stage: PhoneTransferProgressStage.connecting,
        currentFileIndex: 0,
        currentFilename: batch.files.first.filename,
      );
    }
    _TransferSession? session;
    final stopwatch = Stopwatch();
    try {
      for (var index = 0; index < batch.files.length; index++) {
        batch = await _markTiming(batch, index, TransferTimingStage.offerSent);
      }
      final openedSession =
          preparedSession ?? await _openSession(pairing, batch);
      session = openedSession;
      var activeSession = openedSession;
      if (preparedSession != null) {
        _sendOffer(openedSession, batch);
      }
      for (var index = 0; index < batch.files.length; index++) {
        batch = await _markTiming(
          batch,
          index,
          TransferTimingStage.offerSent,
          end: true,
          wallEventMs: _wallNow(),
        );
      }

      for (var index = 0; index < batch.files.length; index++) {
        var transferFile = batch.files[index];
        if (transferFile.status == PhoneTransferStatus.completed) continue;
        if (_cancelledFiles.contains(
          '${batch.transferId}:${transferFile.fileId}',
        )) {
          throw const PreparationCancelled();
        }
        if (transferFile.status != PhoneTransferStatus.active) {
          transferFile = transferFile.copyWith(
            status: PhoneTransferStatus.active,
            preparationPhase: PhoneTransferPreparationPhase.connecting,
            preparedBytes: 0,
            preparationStartedAt:
                transferFile.preparationStartedAt ?? batch.createdAtMs,
          );
          batch = await _replaceFile(batch, index, transferFile);
        }
        final cancellationKey = '${batch.transferId}:${transferFile.fileId}';
        final cancellationTransferId = batch.transferId;
        final cancellationFileId = transferFile.fileId;
        final cancellation = _ActiveTransferCancellation(
          sendCancel: () async {
            activeSession.connection.sendTransferControl({
              'v': 1,
              'kind': 'transfer_cancel',
              'transferId': cancellationTransferId,
              'fileId': cancellationFileId,
            });
            await activeSession.close();
          },
        );
        _activeTransferCancellations[cancellationKey] = cancellation;
        _publishBatch(
          batch,
          stage: PhoneTransferProgressStage.waitingForLaptop,
          currentFileIndex: index,
          currentFilename: transferFile.filename,
        );
        if (transferFile.preparationPhase != null) {
          transferFile = transferFile.copyWith(clearPreparationPhase: true);
          batch = await _replaceFile(batch, index, transferFile);
        }
        batch = await _markTiming(
          batch,
          index,
          TransferTimingStage.acceptReceived,
        );
        late _AcceptedSession acceptedSession;
        try {
          acceptedSession = await _acceptWithReconnect(
            pairing: pairing,
            batch: batch,
            transferFile: transferFile,
            currentSession: activeSession,
            timeout: acceptanceTimeout,
          );
        } finally {
          batch = await _markTiming(
            batch,
            index,
            TransferTimingStage.acceptReceived,
            end: true,
            wallEventMs: _wallNow(),
          );
        }
        transferFile = batch.files[index];
        if (_cancelledFiles.contains(
          '${batch.transferId}:${transferFile.fileId}',
        )) {
          throw const PreparationCancelled();
        }
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
        var firstPayloadMarked = false;
        var lastPayloadMarked = false;

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
          final source = sourceUri != null || sourcePath == null
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
              if (!firstPayloadMarked) {
                batch = await _markTiming(
                  batch,
                  index,
                  TransferTimingStage.firstPayloadByte,
                );
                firstPayloadMarked = true;
              }
              if (offset + plaintext.length == transferFile.size &&
                  !lastPayloadMarked) {
                batch = await _markTiming(
                  batch,
                  index,
                  TransferTimingStage.lastPayloadByte,
                );
                lastPayloadMarked = true;
              }
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
              if (firstPayloadMarked) {
                batch = await _markTiming(
                  batch,
                  index,
                  TransferTimingStage.firstPayloadByte,
                  end: true,
                );
              }
              if (result.complete && lastPayloadMarked) {
                batch = await _markTiming(
                  batch,
                  index,
                  TransferTimingStage.lastPayloadByte,
                  end: true,
                );
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
        } else {
          batch = await _markTiming(
            batch,
            index,
            TransferTimingStage.firstPayloadByte,
            end: true,
          );
          batch = await _markTiming(
            batch,
            index,
            TransferTimingStage.lastPayloadByte,
            end: true,
          );
        }
        batch = await _markTiming(
          batch,
          index,
          TransferTimingStage.durableCompletion,
        );
        transferFile = batch.files[index];
        transferFile = transferFile.copyWith(
          status: PhoneTransferStatus.completed,
          confirmedOffset: transferFile.size,
        );
        batch = await _replaceFile(batch, index, transferFile);
        batch = await _markTiming(
          batch,
          index,
          TransferTimingStage.durableCompletion,
          end: true,
        );
        transferFile = batch.files[index];
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
        _activeTransferCancellations.remove(cancellationKey);
      }
      batch = batch.copyWith(
        status: PhoneTransferStatus.completed,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      await history.upsert(batch);
      _publishBatch(batch, stage: PhoneTransferProgressStage.completed);
      return batch;
    } catch (error) {
      if (error is PreparationCancelled ||
          batch.files.any(
            (file) =>
                _cancelledFiles.contains('${batch.transferId}:${file.fileId}'),
          )) {
        throw const PreparationCancelled();
      }
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
      _activeTransferCancellations.removeWhere(
        (key, _) => key.startsWith('${batch.transferId}:'),
      );
      await session?.close();
    }
  }

  Future<_TransferSession> _openSession(
    PairingCode pairing,
    PhoneTransferBatch batch,
  ) async {
    final session = await _connectSession(pairing);
    try {
      _sendOffer(session, batch);
      return session;
    } catch (_) {
      await session.close();
      rethrow;
    }
  }

  Future<_TransferSession> _connectSession(PairingCode pairing) async {
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
      return session;
    } catch (_) {
      await session.close();
      rethrow;
    }
  }

  void _sendOffer(_TransferSession session, PhoneTransferBatch batch) {
    session.connection.sendTransferControl({
      'v': 1,
      'kind': 'transfer_offer',
      'offer': _offerJson(batch),
    });
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
      clearPreparationPhase: true,
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
    if (persist && !_snapshotController.isClosed) {
      _snapshotController.add(updated);
    }
    return updated;
  }

  PhoneTransferBatch _markTimingValue(
    PhoneTransferBatch batch,
    int index,
    String stage, {
    bool end = false,
    int? wallEventMs,
  }) {
    final file = batch.files[index];
    final key = '${batch.transferId}:${file.fileId}';
    final anchor = _timingAnchors.putIfAbsent(key, _monotonicNow);
    final elapsed = max(0, _monotonicNow() - anchor);
    var timing = file.timing ?? _newTiming(_wallNow());
    timing = timing.mark(file.preparationAttempt, stage, elapsed, end: end);
    if (wallEventMs != null) {
      timing = stage == TransferTimingStage.offerSent
          ? timing.withWallEvents(offerWallMs: wallEventMs)
          : stage == TransferTimingStage.acceptReceived
          ? timing.withWallEvents(acceptWallMs: wallEventMs)
          : timing;
    }
    final files = [...batch.files]..[index] = file.copyWith(timing: timing);
    return batch.copyWith(files: files, updatedAtMs: _wallNow());
  }

  Future<PhoneTransferBatch> _markTiming(
    PhoneTransferBatch batch,
    int index,
    String stage, {
    bool end = false,
    int? wallEventMs,
  }) async {
    return _replaceFile(
      batch,
      index,
      _markTimingValue(
        batch,
        index,
        stage,
        end: end,
        wallEventMs: wallEventMs,
      ).files[index],
    );
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
        preparationPhase:
            currentFileIndex != null && currentFileIndex < batch.files.length
            ? batch.files[currentFileIndex].preparationPhase
            : null,
        preparedBytes:
            currentFileIndex != null && currentFileIndex < batch.files.length
            ? batch.files[currentFileIndex].preparedBytes
            : 0,
        preparationTotalBytes:
            currentFileIndex != null && currentFileIndex < batch.files.length
            ? batch.files[currentFileIndex].preparationTotalBytes
            : null,
        preparationStartedAt:
            currentFileIndex != null && currentFileIndex < batch.files.length
            ? batch.files[currentFileIndex].preparationStartedAt
            : null,
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

  Future<String> _hashFile(
    File file, {
    _PreparationToken? token,
    Future<void> Function(int bytes)? onBytes,
  }) async {
    final sink = AccumulatorSink<hashes.Digest>();
    final digest = hashes.sha256.startChunkedConversion(sink);
    var bytes = 0;
    await for (final chunk in file.openRead()) {
      token?.check();
      digest.add(chunk);
      bytes += chunk.length;
      if (onBytes != null) await onBytes(bytes);
    }
    digest.close();
    return sink.events.single.toString();
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

class _ActiveTransferCancellation {
  _ActiveTransferCancellation({required this.sendCancel});

  final Future<void> Function() sendCancel;
  bool _requested = false;

  Future<void> cancel() async {
    if (_requested) return;
    _requested = true;
    try {
      await sendCancel();
    } catch (_) {
      // Closing an already-disconnected session still completes local cancel.
    }
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
  if (error is FileSystemException ||
      message.contains('source') ||
      message.contains('no longer available') ||
      message.contains('permission denied') ||
      message.contains('content uri')) {
    return 'source_unavailable';
  }
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
