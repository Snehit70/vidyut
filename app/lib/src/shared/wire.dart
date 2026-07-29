import 'dart:convert';

enum PayloadType {
  image('image'),
  text('text');

  const PayloadType(this.wireName);

  final String wireName;

  static PayloadType parse(String value) {
    return PayloadType.values.firstWhere(
      (type) => type.wireName == value,
      orElse: () => throw FormatException('Unsupported payload type: $value'),
    );
  }
}

class PayloadMetadata {
  const PayloadMetadata({
    required this.type,
    required this.mime,
    required this.origin,
    required this.ts,
  });

  final PayloadType type;
  final String mime;
  final String origin;
  final int ts;
}

class PayloadFrame {
  const PayloadFrame({
    required this.type,
    required this.mime,
    required this.origin,
    required this.ts,
    required this.nonce,
    required this.payload,
    this.v = 1,
  });

  final int v;
  final PayloadType type;
  final String mime;
  final String origin;
  final int ts;
  final String nonce;
  final String payload;

  @override
  bool operator ==(Object other) {
    return other is PayloadFrame &&
        other.v == v &&
        other.type == type &&
        other.mime == mime &&
        other.origin == origin &&
        other.ts == ts &&
        other.nonce == nonce &&
        other.payload == payload;
  }

  @override
  int get hashCode => Object.hash(v, type, mime, origin, ts, nonce, payload);

  Map<String, Object?> toJson() => {
    'v': v,
    'type': type.wireName,
    'mime': mime,
    'origin': origin,
    'ts': ts,
    'nonce': nonce,
    'payload': payload,
  };

  Map<String, Object?> associatedDataJson() => {
    'v': v,
    'type': type.wireName,
    'mime': mime,
    'origin': origin,
    'ts': ts,
    'nonce': nonce,
  };

  String associatedData() => jsonEncode(associatedDataJson());

  PayloadFrame copyWith({
    int? v,
    PayloadType? type,
    String? mime,
    String? origin,
    int? ts,
    String? nonce,
    String? payload,
  }) {
    return PayloadFrame(
      v: v ?? this.v,
      type: type ?? this.type,
      mime: mime ?? this.mime,
      origin: origin ?? this.origin,
      ts: ts ?? this.ts,
      nonce: nonce ?? this.nonce,
      payload: payload ?? this.payload,
    );
  }

  static PayloadFrame fromJson(Object? value) {
    if (value is! Map<String, Object?>) {
      throw const FormatException('Payload frame must be an object.');
    }
    return PayloadFrame(
      v: _intField(value, 'v'),
      type: PayloadType.parse(_stringField(value, 'type')),
      mime: _stringField(value, 'mime'),
      origin: _stringField(value, 'origin'),
      ts: _intField(value, 'ts'),
      nonce: _stringField(value, 'nonce'),
      payload: _stringField(value, 'payload'),
    );
  }
}

enum TransferDirection {
  laptopToPhone('laptop_to_phone'),
  phoneToLaptop('phone_to_laptop');

  const TransferDirection(this.wireName);

  final String wireName;

  static TransferDirection parse(String value) {
    return TransferDirection.values.firstWhere(
      (direction) => direction.wireName == value,
      orElse: () =>
          throw FormatException('Unsupported transfer direction: $value'),
    );
  }
}

class TransferFileOffer {
  const TransferFileOffer({
    required this.fileId,
    required this.filename,
    required this.mime,
    required this.size,
    required this.lastModifiedMs,
    required this.sha256,
  });

  final String fileId;
  final String filename;
  final String mime;
  final int size;
  final int lastModifiedMs;
  final String sha256;

  Map<String, Object?> toJson() => {
    'fileId': fileId,
    'filename': filename,
    'mime': mime,
    'size': size,
    'lastModifiedMs': lastModifiedMs,
    'sha256': sha256,
  };

  static TransferFileOffer fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('Transfer file offer must be an object.');
    }
    final json = value.cast<Object?, Object?>();
    final fileId = _transferIdField(json, 'fileId');
    final filename = _stringField(json, 'filename');
    if (filename.length > 255 ||
        filename == '.' ||
        filename == '..' ||
        filename.contains('/') ||
        filename.contains(r'\')) {
      throw const FormatException('filename must be a safe basename.');
    }
    final size = _nonNegativeIntField(json, 'size');
    final lastModifiedMs = _nonNegativeIntField(json, 'lastModifiedMs');
    final sha256 = _stringField(json, 'sha256');
    if (!_sha256Pattern.hasMatch(sha256)) {
      throw const FormatException('sha256 must be lowercase hexadecimal.');
    }
    return TransferFileOffer(
      fileId: fileId,
      filename: filename,
      mime: _stringField(json, 'mime'),
      size: size,
      lastModifiedMs: lastModifiedMs,
      sha256: sha256,
    );
  }
}

class TransferOffer {
  const TransferOffer({
    required this.transferId,
    required this.batchId,
    required this.origin,
    required this.direction,
    required this.createdAtMs,
    required this.files,
  });

  final String transferId;
  final String batchId;
  final String origin;
  final TransferDirection direction;
  final int createdAtMs;
  final List<TransferFileOffer> files;

  Map<String, Object?> toJson() => {
    'transferId': transferId,
    'batchId': batchId,
    'origin': origin,
    'direction': direction.wireName,
    'createdAtMs': createdAtMs,
    'files': files.map((file) => file.toJson()).toList(),
  };

  static TransferOffer fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('Transfer offer must be an object.');
    }
    final json = value.cast<Object?, Object?>();
    final rawFiles = json['files'];
    if (rawFiles is! List || rawFiles.isEmpty) {
      throw const FormatException('files must be a non-empty list.');
    }
    final files = rawFiles.map(TransferFileOffer.fromJson).toList();
    if (files.map((file) => file.fileId).toSet().length != files.length) {
      throw const FormatException('fileId must be unique within a transfer.');
    }
    return TransferOffer(
      transferId: _transferIdField(json, 'transferId'),
      batchId: _transferIdField(json, 'batchId'),
      origin: _stringField(json, 'origin'),
      direction: TransferDirection.parse(_stringField(json, 'direction')),
      createdAtMs: _nonNegativeIntField(json, 'createdAtMs'),
      files: files,
    );
  }
}

final _transferIdPattern = RegExp(r'^[A-Za-z0-9_-]{16,128}$');
final _sha256Pattern = RegExp(r'^[a-f0-9]{64}$');

String _transferIdField(Map<Object?, Object?> json, String field) {
  final value = _stringField(json, field);
  if (!_transferIdPattern.hasMatch(value)) {
    throw FormatException('$field must be a valid transfer identifier.');
  }
  return value;
}

int _nonNegativeIntField(Map<Object?, Object?> json, String field) {
  final value = json[field];
  if (value is! int || value < 0) {
    throw FormatException('$field must be a non-negative integer.');
  }
  return value;
}

int _intField(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! int) throw FormatException('$field must be an integer.');
  return value;
}

String _stringField(Map<Object?, Object?> json, String field) {
  final value = json[field];
  if (value is! String || value.isEmpty) {
    throw FormatException('$field must be a string.');
  }
  return value;
}
