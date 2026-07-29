import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum PhoneTransferDirection { sent, received }

enum PhoneTransferStatus {
  queued,
  active,
  paused,
  completed,
  completedWithIssues,
  failed,
  cancelled,
  expired,
}

class PhoneTransferFile {
  const PhoneTransferFile({
    required this.fileId,
    required this.filename,
    required this.mime,
    required this.size,
    required this.lastModifiedMs,
    required this.sha256,
    required this.status,
    required this.confirmedOffset,
    this.sourcePath,
    this.destinationPath,
    this.errorCode,
  });

  final String fileId;
  final String filename;
  final String mime;
  final int size;
  final int lastModifiedMs;
  final String sha256;
  final PhoneTransferStatus status;
  final int confirmedOffset;
  final String? sourcePath;
  final String? destinationPath;
  final String? errorCode;

  PhoneTransferFile copyWith({
    PhoneTransferStatus? status,
    int? confirmedOffset,
    String? destinationPath,
    String? errorCode,
    bool clearError = false,
  }) {
    return PhoneTransferFile(
      fileId: fileId,
      filename: filename,
      mime: mime,
      size: size,
      lastModifiedMs: lastModifiedMs,
      sha256: sha256,
      status: status ?? this.status,
      confirmedOffset: confirmedOffset ?? this.confirmedOffset,
      sourcePath: sourcePath,
      destinationPath: destinationPath ?? this.destinationPath,
      errorCode: clearError ? null : errorCode ?? this.errorCode,
    );
  }

  Map<String, Object?> toJson() => {
    'fileId': fileId,
    'filename': filename,
    'mime': mime,
    'size': size,
    'lastModifiedMs': lastModifiedMs,
    'sha256': sha256,
    'status': status.name,
    'confirmedOffset': confirmedOffset,
    if (sourcePath != null) 'sourcePath': sourcePath,
    if (destinationPath != null) 'destinationPath': destinationPath,
    if (errorCode != null) 'errorCode': errorCode,
  };

  static PhoneTransferFile fromJson(Map<Object?, Object?> json) {
    return PhoneTransferFile(
      fileId: json['fileId']! as String,
      filename: json['filename']! as String,
      mime: json['mime']! as String,
      size: json['size']! as int,
      lastModifiedMs: json['lastModifiedMs']! as int,
      sha256: json['sha256']! as String,
      status: PhoneTransferStatus.values.byName(json['status']! as String),
      confirmedOffset: json['confirmedOffset']! as int,
      sourcePath: json['sourcePath'] as String?,
      destinationPath: json['destinationPath'] as String?,
      errorCode: json['errorCode'] as String?,
    );
  }
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
  Future<String?> read();

  Future<void> write(String value);
}

class SharedPreferencesTransferHistoryStorage
    implements TransferHistoryStorage {
  static const _key = 'vidyut.transfer.history.v1';

  @override
  Future<String?> read() async {
    return (await SharedPreferences.getInstance()).getString(_key);
  }

  @override
  Future<void> write(String value) async {
    await (await SharedPreferences.getInstance()).setString(_key, value);
  }
}

class MemoryTransferHistoryStorage implements TransferHistoryStorage {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async {
    this.value = value;
  }
}

class TransferHistoryRepository {
  TransferHistoryRepository(this._storage);

  final TransferHistoryStorage _storage;

  Future<List<PhoneTransferBatch>> load() async {
    final raw = await _storage.read();
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw) as List;
      return decoded
          .map(
            (batch) => PhoneTransferBatch.fromJson(
              (batch as Map).cast<Object?, Object?>(),
            ),
          )
          .toList();
    } on Object {
      return [];
    }
  }

  Future<void> upsert(PhoneTransferBatch batch) async {
    final batches = await load();
    final index = batches.indexWhere(
      (candidate) => candidate.transferId == batch.transferId,
    );
    if (index == -1) {
      batches.add(batch);
    } else {
      batches[index] = batch;
    }
    batches.sort(
      (left, right) => right.createdAtMs.compareTo(left.createdAtMs),
    );
    await _save(batches);
  }

  Future<void> remove(String transferId) async {
    final batches = await load()
      ..removeWhere((batch) => batch.transferId == transferId);
    await _save(batches);
  }

  Future<void> clear() => _save([]);

  Future<void> _save(List<PhoneTransferBatch> batches) {
    return _storage.write(
      jsonEncode(batches.map((batch) => batch.toJson()).toList()),
    );
  }
}
