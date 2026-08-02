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

enum PhoneTransferSourceKind { externalPath, androidDocumentUri, managedStage }

enum PhoneTransferSourceOwnership { external, managed }

/// Durable locator for the bytes behind a logical transfer file.
///
/// Native handles are deliberately absent: a URI or managed-stage key can be
/// reopened after process death and reboot, while a descriptor cannot.
class PhoneTransferSourceReference {
  const PhoneTransferSourceReference({
    required this.kind,
    required this.reference,
    required this.ownership,
  });

  final PhoneTransferSourceKind kind;
  final String reference;
  final PhoneTransferSourceOwnership ownership;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'reference': reference,
    'ownership': ownership.name,
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

  PhoneTransferFile copyWith({
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
  }) {
    return PhoneTransferFile(
      fileId: fileId,
      filename: filename,
      mime: mime,
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
  };

  static PhoneTransferFile fromJson(Map<Object?, Object?> json) {
    return PhoneTransferFile(
      fileId: json['fileId']! as String,
      filename: json['filename']! as String,
      mime: json['mime']! as String,
      size: json['size']! as int,
      lastModifiedMs: json['lastModifiedMs']! as int,
      lastModifiedKnown: json['lastModifiedKnown'] != false,
      sha256: json['sha256']! as String,
      status: PhoneTransferStatus.values.byName(json['status']! as String),
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
    );
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
    return PhoneTransferBatch(
      transferId: json['transferId']! as String,
      batchId: json['batchId']! as String,
      direction: PhoneTransferDirection.values.byName(
        json['direction']! as String,
      ),
      createdAtMs: json['createdAtMs']! as int,
      updatedAtMs: json['updatedAtMs']! as int,
      status: PhoneTransferStatus.values.byName(json['status']! as String),
      files: (json['files']! as List)
          .map(
            (file) => PhoneTransferFile.fromJson(
              (file as Map).cast<Object?, Object?>(),
            ),
          )
          .toList(),
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

  Future<List<PhoneTransferBatch>> load() async {
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

  Future<void> upsert(PhoneTransferBatch batch) =>
      _storage.writeBatch(batch.transferId, jsonEncode(batch.toJson()));

  Future<void> remove(String transferId) => _storage.removeBatch(transferId);

  Future<void> clear() => _storage.clear();
}
