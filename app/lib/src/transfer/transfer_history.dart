import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum PhoneTransferDirection { sent, received }

enum PhoneTransferStatus {
  preparing,
  waitingForSource,
  queued,
  active,
  paused,
  completed,
  completedWithIssues,
  failed,
  cancelled,
  expired,
}

enum PhoneTransferPreparationPhase {
  readingSelection,
  staging,
  hashing,
  policyCheck,
  connecting,
}

enum PhoneTransferSourceKind { externalPath, androidDocumentUri, managedStage }

enum PhoneTransferSourceOwnership { external, managed }

typedef MonotonicClock = int Function();

abstract final class TransferTimingStage {
  static const pickerCallback = 'picker_callback';
  static const durableQueueCard = 'durable_queue_card';
  static const firstVisiblePublication = 'first_visible_publication';
  static const sourceOpenProbe = 'source_open_probe';
  static const fallbackStage = 'fallback_stage';
  static const sourceHash = 'source_hash';
  static const offerSent = 'offer_sent';
  static const acceptReceived = 'accept_received';
  static const firstPayloadByte = 'first_payload_byte';
  static const lastPayloadByte = 'last_payload_byte';
  static const receiverVerification = 'receiver_verification';
  static const publishFinalization = 'publish_finalization';
  static const durableCompletion = 'durable_completion';
}

/// Privacy-safe timing for one file attempt. Values are elapsed milliseconds
/// from [wallAnchorMs]; the process-local monotonic origin is never persisted.
class TransferAttemptTiming {
  const TransferAttemptTiming({required this.attempt, required this.stages});

  final int attempt;
  final Map<String, ({int startMs, int? endMs})> stages;

  TransferAttemptTiming mark(String stage, int elapsedMs, {bool end = false}) {
    final current = stages[stage];
    final startMs = current?.startMs ?? elapsedMs;
    return TransferAttemptTiming(
      attempt: attempt,
      stages: {
        ...stages,
        stage: (
          startMs: startMs,
          endMs: end
              ? (elapsedMs < startMs ? startMs : elapsedMs)
              : current?.endMs,
        ),
      },
    );
  }

  Map<String, Object?> toJson() => {
    'attempt': attempt,
    'stages': stages.map(
      (name, span) => MapEntry(name, {
        'startMs': span.startMs,
        if (span.endMs != null) 'endMs': span.endMs,
      }),
    ),
  };

  static TransferAttemptTiming? fromJson(Object? value) {
    if (value is! Map || value['attempt'] is! int || value['stages'] is! Map) {
      return null;
    }
    final stages = <String, ({int startMs, int? endMs})>{};
    for (final entry in (value['stages'] as Map).entries) {
      final span = entry.value;
      if (entry.key is String && span is Map && span['startMs'] is int) {
        stages[entry.key as String] = (
          startMs: span['startMs'] as int,
          endMs: span['endMs'] as int?,
        );
      }
    }
    return TransferAttemptTiming(
      attempt: value['attempt'] as int,
      stages: stages,
    );
  }
}

class TransferTimingSummary {
  const TransferTimingSummary({
    required this.wallAnchorMs,
    required this.attempts,
    this.offerWallMs,
    this.acceptWallMs,
  });

  final int wallAnchorMs;
  final int? offerWallMs;
  final int? acceptWallMs;
  final List<TransferAttemptTiming> attempts;

  TransferTimingSummary mark(
    int attempt,
    String stage,
    int elapsedMs, {
    bool end = false,
  }) {
    final items = [...attempts];
    final index = items.indexWhere((item) => item.attempt == attempt);
    final item =
        (index < 0
                ? TransferAttemptTiming(attempt: attempt, stages: const {})
                : items[index])
            .mark(stage, elapsedMs, end: end);
    if (index < 0) {
      items.add(item);
    } else {
      items[index] = item;
    }
    return TransferTimingSummary(
      wallAnchorMs: wallAnchorMs,
      offerWallMs: offerWallMs,
      acceptWallMs: acceptWallMs,
      attempts: items.length <= 4 ? items : items.sublist(items.length - 4),
    );
  }

  TransferTimingSummary withWallEvents({int? offerWallMs, int? acceptWallMs}) =>
      TransferTimingSummary(
        wallAnchorMs: wallAnchorMs,
        offerWallMs: offerWallMs ?? this.offerWallMs,
        acceptWallMs: acceptWallMs ?? this.acceptWallMs,
        attempts: attempts,
      );

  Map<String, Object?> toJson() => {
    'v': 1,
    'wallAnchorMs': wallAnchorMs,
    if (offerWallMs != null) 'offerWallMs': offerWallMs,
    if (acceptWallMs != null) 'acceptWallMs': acceptWallMs,
    'attempts': attempts.map((item) => item.toJson()).toList(),
  };

  static TransferTimingSummary? fromJson(Object? value) {
    if (value is! Map || value['v'] != 1 || value['wallAnchorMs'] is! int) {
      return null;
    }
    final attempts =
        (value['attempts'] is List ? value['attempts'] as List : const [])
            .map(TransferAttemptTiming.fromJson)
            .whereType<TransferAttemptTiming>()
            .toList();
    return TransferTimingSummary(
      wallAnchorMs: value['wallAnchorMs'] as int,
      offerWallMs: value['offerWallMs'] as int?,
      acceptWallMs: value['acceptWallMs'] as int?,
      attempts: attempts.length <= 4
          ? attempts
          : attempts.sublist(attempts.length - 4),
    );
  }
}

/// Durable locator for the bytes behind a logical transfer file.
///
/// Native handles are deliberately absent: a URI or managed-stage key can be
/// reopened after process death and reboot, while a descriptor cannot.
class PhoneTransferSourceReference {
  const PhoneTransferSourceReference({
    required this.kind,
    required this.reference,
    required this.ownership,
    this.persisted = false,
  });

  final PhoneTransferSourceKind kind;
  final String reference;
  final PhoneTransferSourceOwnership ownership;

  /// Whether an Android document URI has a persistable read grant.
  ///
  /// Missing fields in older history rows decode as false so reconstructed
  /// document sources are conservatively staged before retry.
  final bool persisted;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'reference': reference,
    'ownership': ownership.name,
    'persisted': persisted,
  };

  static PhoneTransferSourceReference? fromJson(Object? value) {
    if (value is! Map) return null;
    final kind = value['kind'];
    final reference = value['reference'];
    final ownership = value['ownership'];
    if (kind is! String || reference is! String || ownership is! String) {
      return null;
    }
    try {
      return PhoneTransferSourceReference(
        kind: PhoneTransferSourceKind.values.byName(kind),
        reference: reference,
        ownership: PhoneTransferSourceOwnership.values.byName(ownership),
        persisted: value['persisted'] == true,
      );
    } on ArgumentError {
      return null;
    }
  }
}

class PhoneTransferFile {
  const PhoneTransferFile({
    required this.fileId,
    required this.filename,
    required this.mime,
    required this.size,
    required this.lastModifiedMs,
    this.lastModifiedKnown = true,
    required this.sha256,
    required this.status,
    required this.confirmedOffset,
    this.sourceReference,
    this.sourcePath,
    this.destinationPath,
    this.errorCode,
    this.errorOrigin,
    this.errorCategory,
    this.errorDetail,
    this.errorContext,
    this.preparationPhase,
    this.preparedBytes = 0,
    this.preparationTotalBytes,
    this.preparationStartedAt,
    this.preparationAttempt = 0,
    this.cancellationRequestedAt,
    this.timing,
  });

  final String fileId;
  final String filename;
  final String mime;
  final int size;
  final int lastModifiedMs;
  final bool lastModifiedKnown;
  final String sha256;
  final PhoneTransferStatus status;
  final int confirmedOffset;
  final PhoneTransferSourceReference? sourceReference;
  @Deprecated('Use sourceReference for new records.')
  final String? sourcePath;
  final String? destinationPath;
  final String? errorCode;
  final String? errorOrigin;
  final String? errorCategory;
  final String? errorDetail;
  final Map<String, Object?>? errorContext;
  final PhoneTransferPreparationPhase? preparationPhase;
  final int preparedBytes;
  final int? preparationTotalBytes;
  final int? preparationStartedAt;
  final int preparationAttempt;
  final int? cancellationRequestedAt;
  final TransferTimingSummary? timing;

  Duration? get preparationElapsed {
    final started = preparationStartedAt;
    if (started == null) return null;
    return Duration(
      milliseconds: DateTime.now().millisecondsSinceEpoch - started,
    );
  }

  PhoneTransferFile copyWith({
    String? filename,
    String? mime,
    int? size,
    int? lastModifiedMs,
    bool? lastModifiedKnown,
    String? sha256,
    PhoneTransferStatus? status,
    int? confirmedOffset,
    String? destinationPath,
    String? errorCode,
    String? errorOrigin,
    String? errorCategory,
    String? errorDetail,
    Map<String, Object?>? errorContext,
    PhoneTransferSourceReference? sourceReference,
    bool clearSourceReference = false,
    bool clearError = false,
    PhoneTransferPreparationPhase? preparationPhase,
    bool clearPreparationPhase = false,
    int? preparedBytes,
    int? preparationTotalBytes,
    bool clearPreparationTotalBytes = false,
    int? preparationStartedAt,
    bool clearPreparationStartedAt = false,
    int? preparationAttempt,
    int? cancellationRequestedAt,
    bool clearCancellationRequestedAt = false,
    TransferTimingSummary? timing,
  }) {
    return PhoneTransferFile(
      fileId: fileId,
      filename: filename ?? this.filename,
      mime: mime ?? this.mime,
      size: size ?? this.size,
      lastModifiedMs: lastModifiedMs ?? this.lastModifiedMs,
      lastModifiedKnown: lastModifiedKnown ?? this.lastModifiedKnown,
      sha256: sha256 ?? this.sha256,
      status: status ?? this.status,
      confirmedOffset: confirmedOffset ?? this.confirmedOffset,
      sourceReference: clearSourceReference
          ? null
          : sourceReference ?? this.sourceReference,
      sourcePath: sourcePath,
      destinationPath: destinationPath ?? this.destinationPath,
      errorCode: clearError ? null : errorCode ?? this.errorCode,
      errorOrigin: clearError ? null : errorOrigin ?? this.errorOrigin,
      errorCategory: clearError ? null : errorCategory ?? this.errorCategory,
      errorDetail: clearError ? null : errorDetail ?? this.errorDetail,
      errorContext: clearError ? null : errorContext ?? this.errorContext,
      preparationPhase: clearPreparationPhase
          ? null
          : preparationPhase ?? this.preparationPhase,
      preparedBytes: preparedBytes ?? this.preparedBytes,
      preparationTotalBytes: clearPreparationTotalBytes
          ? null
          : preparationTotalBytes ?? this.preparationTotalBytes,
      preparationStartedAt: clearPreparationStartedAt
          ? null
          : preparationStartedAt ?? this.preparationStartedAt,
      preparationAttempt: preparationAttempt ?? this.preparationAttempt,
      cancellationRequestedAt: clearCancellationRequestedAt
          ? null
          : cancellationRequestedAt ?? this.cancellationRequestedAt,
      timing: timing ?? this.timing,
    );
  }

  Map<String, Object?> toJson() => {
    'fileId': fileId,
    'filename': filename,
    'mime': mime,
    'size': size,
    'lastModifiedMs': lastModifiedMs,
    if (!lastModifiedKnown) 'lastModifiedKnown': false,
    'sha256': sha256,
    'status': status.name,
    'confirmedOffset': confirmedOffset,
    if (sourcePath != null) 'sourcePath': sourcePath,
    if (sourceReference != null &&
        (sourcePath == null ||
            sourceReference!.reference != sourcePath ||
            sourceReference!.kind != PhoneTransferSourceKind.externalPath))
      'source': sourceReference!.toJson(),
    if (destinationPath != null) 'destinationPath': destinationPath,
    if (errorCode != null) 'errorCode': errorCode,
    if (errorOrigin != null) 'errorOrigin': errorOrigin,
    if (errorCategory != null) 'errorCategory': errorCategory,
    if (errorDetail != null) 'errorDetail': errorDetail,
    if (errorContext != null) 'errorContext': errorContext,
    if (preparationPhase != null && !_implicitLegacyPreparation)
      'preparationPhase': preparationPhase!.name,
    if ((preparationPhase != null && !_implicitLegacyPreparation) ||
        preparedBytes != 0)
      'preparedBytes': preparedBytes,
    if (preparationTotalBytes != null)
      'preparationTotalBytes': preparationTotalBytes,
    if (preparationStartedAt != null)
      'preparationStartedAt': preparationStartedAt,
    if ((preparationPhase != null && !_implicitLegacyPreparation) ||
        preparationAttempt != 0)
      'preparationAttempt': preparationAttempt,
    if (cancellationRequestedAt != null)
      'cancellationRequestedAt': cancellationRequestedAt,
    if (timing != null) 'timing': timing!.toJson(),
  };

  bool get _implicitLegacyPreparation =>
      status == PhoneTransferStatus.preparing &&
      preparationPhase == PhoneTransferPreparationPhase.readingSelection &&
      preparedBytes == 0 &&
      preparationTotalBytes == null &&
      preparationStartedAt == null &&
      preparationAttempt == 0 &&
      cancellationRequestedAt == null;

  static PhoneTransferFile fromJson(Map<Object?, Object?> json) {
    final status = PhoneTransferStatus.values.byName(json['status']! as String);
    final phase = _preparationPhase(json['preparationPhase']);
    return PhoneTransferFile(
      fileId: json['fileId']! as String,
      filename: json['filename']! as String,
      mime: json['mime']! as String,
      size: json['size']! as int,
      lastModifiedMs: json['lastModifiedMs']! as int,
      lastModifiedKnown: json['lastModifiedKnown'] != false,
      sha256: json['sha256']! as String,
      status: status,
      confirmedOffset: json['confirmedOffset']! as int,
      sourceReference:
          PhoneTransferSourceReference.fromJson(json['source']) ??
          _legacySourceReference(json['sourcePath'] as String?),
      sourcePath: json['sourcePath'] as String?,
      destinationPath: json['destinationPath'] as String?,
      errorCode: json['errorCode'] as String?,
      errorOrigin: json['errorOrigin'] as String?,
      errorCategory: json['errorCategory'] as String?,
      errorDetail: json['errorDetail'] as String?,
      errorContext: _errorContext(json['errorContext']),
      preparationPhase:
          phase ??
          (status == PhoneTransferStatus.preparing
              ? PhoneTransferPreparationPhase.readingSelection
              : null),
      preparedBytes: json['preparedBytes'] is int
          ? json['preparedBytes']! as int
          : 0,
      preparationTotalBytes: json['preparationTotalBytes'] is int
          ? json['preparationTotalBytes']! as int
          : null,
      preparationStartedAt: json['preparationStartedAt'] is int
          ? json['preparationStartedAt']! as int
          : (status == PhoneTransferStatus.preparing
                ? json['createdAtMs'] as int?
                : null),
      preparationAttempt: json['preparationAttempt'] is int
          ? json['preparationAttempt']! as int
          : 0,
      cancellationRequestedAt: json['cancellationRequestedAt'] is int
          ? json['cancellationRequestedAt']! as int
          : null,
      timing: TransferTimingSummary.fromJson(json['timing']),
    );
  }
}

String? transferSourcePreviewPath(PhoneTransferFile file) {
  if (!file.mime.toLowerCase().startsWith('image/')) return null;
  final source = file.sourceReference;
  if (source?.kind == PhoneTransferSourceKind.externalPath) {
    return source!.reference;
  }
  return file.sourcePath;
}

String? transferDestinationPreviewPath(PhoneTransferFile file) {
  if (!file.mime.toLowerCase().startsWith('image/')) return null;
  return file.destinationPath;
}

PhoneTransferPreparationPhase? _preparationPhase(Object? value) {
  if (value is! String) return null;
  try {
    return PhoneTransferPreparationPhase.values.byName(value);
  } on ArgumentError {
    return null;
  }
}

PhoneTransferSourceReference? _legacySourceReference(String? path) {
  if (path == null) return null;
  final normalized = path.replaceAll('\\', '/');
  final managed =
      normalized.contains('/cache/vidyut-picker/') ||
      normalized.contains('/cache/vidyut-stage/');
  return PhoneTransferSourceReference(
    kind: managed
        ? PhoneTransferSourceKind.managedStage
        : PhoneTransferSourceKind.externalPath,
    reference: path,
    ownership: managed
        ? PhoneTransferSourceOwnership.managed
        : PhoneTransferSourceOwnership.external,
  );
}

Map<String, Object?>? _errorContext(Object? value) {
  if (value is! Map) return null;
  return value.map<String, Object?>((key, value) => MapEntry('$key', value));
}

class PhoneTransferBatch {
  const PhoneTransferBatch({
    required this.transferId,
    required this.batchId,
    required this.direction,
    required this.createdAtMs,
    required this.updatedAtMs,
    required this.status,
    required this.files,
  });

  final String transferId;
  final String batchId;
  final PhoneTransferDirection direction;
  final int createdAtMs;
  final int updatedAtMs;
  final PhoneTransferStatus status;
  final List<PhoneTransferFile> files;

  PhoneTransferBatch copyWith({
    PhoneTransferStatus? status,
    int? updatedAtMs,
    List<PhoneTransferFile>? files,
  }) {
    return PhoneTransferBatch(
      transferId: transferId,
      batchId: batchId,
      direction: direction,
      createdAtMs: createdAtMs,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      status: status ?? this.status,
      files: files ?? this.files,
    );
  }

  Map<String, Object?> toJson() => {
    'transferId': transferId,
    'batchId': batchId,
    'direction': direction.name,
    'createdAtMs': createdAtMs,
    'updatedAtMs': updatedAtMs,
    'status': status.name,
    'files': files.map((file) => file.toJson()).toList(),
  };

  static PhoneTransferBatch fromJson(Map<Object?, Object?> json) {
    final createdAtMs = json['createdAtMs']! as int;
    final status = PhoneTransferStatus.values.byName(json['status']! as String);
    final decodedFiles = (json['files']! as List)
        .map(
          (file) => PhoneTransferFile.fromJson(
            (file as Map).cast<Object?, Object?>(),
          ),
        )
        .map(
          (file) =>
              file.status == PhoneTransferStatus.preparing &&
                  file.preparationStartedAt == null
              ? file.copyWith(preparationStartedAt: createdAtMs)
              : file,
        )
        .toList();
    return PhoneTransferBatch(
      transferId: json['transferId']! as String,
      batchId: json['batchId']! as String,
      direction: PhoneTransferDirection.values.byName(
        json['direction']! as String,
      ),
      createdAtMs: createdAtMs,
      updatedAtMs: json['updatedAtMs']! as int,
      status: status,
      files: decodedFiles,
    );
  }
}

abstract interface class TransferHistoryStorage {
  Future<Map<String, String>> readAll();

  Future<void> writeBatch(String transferId, String value);

  Future<void> removeBatch(String transferId);

  Future<void> clear();
}

class SharedPreferencesTransferHistoryStorage
    implements TransferHistoryStorage {
  static const _legacyKey = 'vidyut.transfer.history.v1';
  static const _keyPrefix = 'vidyut.transfer.batch.v1.';

  @override
  Future<Map<String, String>> readAll() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.reload();
    final legacy = preferences.getString(_legacyKey);
    if (legacy != null) {
      try {
        for (final rawBatch in jsonDecode(legacy) as List) {
          final batch = (rawBatch as Map).cast<String, Object?>();
          final transferId = batch['transferId'];
          if (transferId is String) {
            await preferences.setString(
              '$_keyPrefix$transferId',
              jsonEncode(batch),
            );
          }
        }
        await preferences.remove(_legacyKey);
      } on Object {
        // Keep malformed legacy data untouched; new per-batch records remain
        // independently readable.
      }
    }
    return {
      for (final key in preferences.getKeys())
        if (key.startsWith(_keyPrefix) && preferences.getString(key) != null)
          key.substring(_keyPrefix.length): preferences.getString(key)!,
    };
  }

  @override
  Future<void> writeBatch(String transferId, String value) async {
    await (await SharedPreferences.getInstance()).setString(
      '$_keyPrefix$transferId',
      value,
    );
  }

  @override
  Future<void> removeBatch(String transferId) async {
    await (await SharedPreferences.getInstance()).remove(
      '$_keyPrefix$transferId',
    );
  }

  @override
  Future<void> clear() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.reload();
    for (final key in preferences.getKeys().where(
      (key) => key.startsWith(_keyPrefix),
    )) {
      await preferences.remove(key);
    }
    await preferences.remove(_legacyKey);
  }
}

class MemoryTransferHistoryStorage implements TransferHistoryStorage {
  final _values = <String, String>{};
  String? get value => _values.isEmpty
      ? null
      : jsonEncode(_values.values.map(jsonDecode).toList());

  @override
  Future<Map<String, String>> readAll() async => Map.of(_values);

  @override
  Future<void> writeBatch(String transferId, String value) async =>
      _values[transferId] = value;

  @override
  Future<void> removeBatch(String transferId) async =>
      _values.remove(transferId);

  @override
  Future<void> clear() async => _values.clear();
}

class TransferHistoryRepository {
  TransferHistoryRepository(this._storage);

  final TransferHistoryStorage _storage;
  Future<void> _writeTail = Future<void>.value();

  Future<List<PhoneTransferBatch>> load() async {
    await _writeTail;
    final batches = <PhoneTransferBatch>[];
    for (final raw in (await _storage.readAll()).values) {
      try {
        batches.add(
          PhoneTransferBatch.fromJson(
            (jsonDecode(raw) as Map).cast<Object?, Object?>(),
          ),
        );
      } on Object {
        // A corrupt record must not hide independent healthy batches.
      }
    }
    batches.sort(
      (left, right) => right.createdAtMs.compareTo(left.createdAtMs),
    );
    return batches;
  }

  Future<void> upsert(PhoneTransferBatch batch) {
    final next = _writeTail.then(
      (_) => _storage.writeBatch(batch.transferId, jsonEncode(batch.toJson())),
    );
    _writeTail = next.catchError((_) {});
    return next;
  }

  Future<void> remove(String transferId) {
    final next = _writeTail.then((_) => _storage.removeBatch(transferId));
    _writeTail = next.catchError((_) {});
    return next;
  }

  Future<void> clear() {
    final next = _writeTail.then((_) => _storage.clear());
    _writeTail = next.catchError((_) {});
    return next;
  }
}
