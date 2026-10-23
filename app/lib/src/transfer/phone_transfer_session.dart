part of 'phone_transfer_sender.dart';

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
    this.sha256,
  });

  final int confirmedOffset;
  final Object? maxChunkBytes;
  final bool complete;
  final String? sha256;
}

class _PreparedChunk {
  const _PreparedChunk({required this.encrypted, required this.plaintext});

  final EncryptedTransferChunk encrypted;
  final List<int> plaintext;
}

class _RunningSha256 {
  _RunningSha256() {
    reset();
  }

  late AccumulatorSink<hashes.Digest> _sink;
  late ByteConversionSink _digest;
  int hashedThrough = 0;
  bool closed = false;

  void reset() {
    _sink = AccumulatorSink<hashes.Digest>();
    _digest = hashes.sha256.startChunkedConversion(_sink);
    hashedThrough = 0;
    closed = false;
  }

  void add(List<int> bytes) {
    _digest.add(bytes);
    hashedThrough += bytes.length;
  }

  String close() {
    _digest.close();
    closed = true;
    return _sink.events.single.toString();
  }
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
