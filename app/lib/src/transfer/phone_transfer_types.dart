part of 'phone_transfer_sender.dart';

class PhoneTransferSource {
  const PhoneTransferSource({
    this.path,
    this.uri,
    required this.filename,
    required this.mime,
    this.size,
    this.lastModifiedMs,
    this.persisted = false,
    this.kind,
    this.ownership = PhoneTransferSourceOwnership.external,
    this.grantAlreadyRetained = false,
  }) : assert(path != null || uri != null);

  final String? path;
  final String? uri;
  final String filename;
  final String mime;
  final int? size;
  final int? lastModifiedMs;
  final bool persisted;
  final PhoneTransferSourceKind? kind;
  final PhoneTransferSourceOwnership ownership;

  /// Whether the picker/native source layer already owns one persisted grant
  /// that this history row is taking ownership of.
  final bool grantAlreadyRetained;

  PhoneTransferSourceReference get reference => PhoneTransferSourceReference(
    kind:
        kind ??
        (uri == null
            ? PhoneTransferSourceKind.externalPath
            : PhoneTransferSourceKind.androidDocumentUri),
    reference: uri ?? path!,
    ownership: ownership,
    persisted: persisted,
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

abstract interface class PhoneTransferCancellableSourceReader {
  Future<String> hashSha256Cancellable(
    String uri, {
    required String operationId,
  });

  Future<void> cancelHash(String operationId);
}

class VidyutFilesSourceReader
    implements PhoneTransferSourceReader, PhoneTransferCancellableSourceReader {
  const VidyutFilesSourceReader([this.files = const VidyutFiles()]);

  final VidyutFiles files;

  @override
  Future<VidyutSourceProbe> probe(String uri) => files.probeSource(uri);

  @override
  Future<String> hashSha256(String uri) => files.hashSource(uri);

  @override
  Future<String> hashSha256Cancellable(
    String uri, {
    required String operationId,
  }) => files.hashSource(uri, operationId: operationId);

  @override
  Future<void> cancelHash(String operationId) => files.cancelHash(operationId);

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

  void registerOperationCancellation(
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
