import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as hashes;
import 'package:path_provider/path_provider.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:vidyut_files/vidyut_files.dart';

import '../pairing/pairing_code.dart';
import '../shared/relay_connection.dart';
import '../shared/transfer_crypto.dart';
import '../shared/transfer_http_auth.dart';
import '../shared/wire.dart';
import 'transfer_chunk_policy.dart';
import 'transfer_history.dart';

class PhoneTransferReceiver {
  PhoneTransferReceiver({
    required this.history,
    TransferCrypto? crypto,
    this.maxFileBytes = 1024 * 1024 * 1024,
    this.chunkBytes = TransferChunkPolicy.preferredBytes,
    this.rootDirectory,
    this.onEvent,
    this.receiveEnabled,
    this.maximumFileBytes,
    this.publisher,
    this.notifier,
    this.alertsEnabled,
    this.networkAllowed,
    this.destinationAvailable,
    HttpClient? httpClient,
  }) : crypto = crypto ?? TransferCrypto(),
       _httpClient = httpClient ?? HttpClient();

  final TransferHistoryRepository history;
  final TransferCrypto crypto;
  final int maxFileBytes;
  final int chunkBytes;
  final Future<Directory> Function()? rootDirectory;
  final void Function(String message, {bool isError})? onEvent;
  final Future<bool> Function()? receiveEnabled;
  final Future<int> Function()? maximumFileBytes;
  final ReceivedFilePublisher? publisher;
  final TransferNotifier? notifier;
  final Future<bool> Function()? alertsEnabled;
  final Future<bool> Function()? networkAllowed;
  final Future<bool> Function()? destinationAvailable;
  final HttpClient _httpClient;
  StreamSubscription<Map<String, Object?>>? _subscription;
  Future<void> _serial = Future.value();
  bool _disposed = false;

  void start(RelayConnection connection, PairingCode pairing) {
    if (_disposed) {
      throw StateError('PhoneTransferReceiver has been disposed.');
    }
    _subscription = connection.transferControls.listen((message) {
      if (_disposed) return;
      if (message['kind'] != 'transfer_offer') return;
      _serial = _serial.then((_) async {
        try {
          await _receiveOffer(connection, pairing, message['offer']);
        } on _TransferCancelled {
          // Teardown intentionally aborts the active receive without
          // publishing a stale failure for the retired relay session.
        } on Object catch (error) {
          if (!_disposed) {
            onEvent?.call('File transfer failed: $error', isError: true);
          }
        }
      });
    });
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final subscription = _subscription;
    _subscription = null;
    // Close before awaiting [_serial] so an in-flight HTTP request is
    // interrupted immediately instead of holding reconnect teardown until its
    // request timeout expires.
    _httpClient.close(force: true);
    await subscription?.cancel();
    await _serial;
  }

  Future<void> _receiveOffer(
    RelayConnection connection,
    PairingCode pairing,
    Object? rawOffer,
  ) async {
    _throwIfDisposed();
    TransferOffer offer;
    try {
      offer = TransferOffer.fromJson(rawOffer);
      if (offer.direction != TransferDirection.laptopToPhone) return;
    } on Object catch (error) {
      onEvent?.call('Rejected invalid file offer: $error', isError: true);
      return;
    }
    if (receiveEnabled != null && !await receiveEnabled!()) {
      _throwIfDisposed();
      for (final file in offer.files) {
        connection.sendTransferControl({
          'v': 1,
          'kind': 'transfer_pause',
          'transferId': offer.transferId,
          'fileId': file.fileId,
        });
      }
      return;
    }
    if (networkAllowed != null && !await networkAllowed!()) {
      _throwIfDisposed();
      for (final file in offer.files) {
        connection.sendTransferControl({
          'v': 1,
          'kind': 'transfer_pause',
          'transferId': offer.transferId,
          'fileId': file.fileId,
        });
      }
      onEvent?.call('File transfer paused on a metered network.');
      return;
    }
    if (destinationAvailable != null && !await destinationAvailable!()) {
      _throwIfDisposed();
      for (final file in offer.files) {
        connection.sendTransferControl({
          'v': 1,
          'kind': 'transfer_pause',
          'transferId': offer.transferId,
          'fileId': file.fileId,
        });
      }
      onEvent?.call(
        'File transfer paused. Choose an available receive folder.',
        isError: true,
      );
      return;
    }
    final effectiveMax = maximumFileBytes == null
        ? maxFileBytes
        : await maximumFileBytes!();
    _throwIfDisposed();
    final root = await (rootDirectory ?? _defaultRoot)();
    _throwIfDisposed();
    await root.create(recursive: true);
    var batch = await _existingOrCreate(offer);
    for (var index = 0; index < offer.files.length; index++) {
      final offeredFile = offer.files[index];
      if (offeredFile.size > effectiveMax) {
        _throwIfDisposed();
        connection.sendTransferControl({
          'v': 1,
          'kind': 'transfer_file_failed',
          'transferId': offer.transferId,
          'fileId': offeredFile.fileId,
          'code': 'file_too_large',
          'actualBytes': offeredFile.size,
          'limitBytes': effectiveMax,
        });
        batch = await _failFile(
          batch,
          index,
          'file_too_large',
          errorOrigin: 'local',
          errorCategory: 'local_preparation',
          errorDetail: 'The file exceeds the phone receive limit.',
          errorContext: {
            'actualBytes': offeredFile.size,
            'limitBytes': effectiveMax,
          },
        );
        continue;
      }
      var record = batch.files[index];
      final partial = File('${root.path}/.${offeredFile.fileId}.vidyut-part');
      var offset = await partial.exists() ? await partial.length() : 0;
      if (offset > offeredFile.size) {
        await partial.delete();
        offset = 0;
      }
      record = record.copyWith(
        status: PhoneTransferStatus.active,
        confirmedOffset: offset,
      );
      batch = await _replaceFile(batch, index, record);
      _throwIfDisposed();
      connection.sendTransferControl({
        'v': 1,
        'kind': 'transfer_accept',
        'transferId': offer.transferId,
        'fileId': offeredFile.fileId,
        'confirmedOffset': offset,
        'maxChunkBytes': chunkBytes,
      });

      try {
        var lastOffset = offset;
        final sink = await partial.open(mode: FileMode.writeOnlyAppend);
        try {
          while (offset < offeredFile.size || offeredFile.size == 0) {
            _throwIfDisposed();
            final response = await _getChunk(
              pairing: pairing,
              transferId: offer.transferId,
              fileId: offeredFile.fileId,
              offset: offset,
            );
            _throwIfDisposed();
            final plaintext = await crypto.decrypt(
              chunk: response.chunk,
              pairingSecret: pairing.secret,
            );
            _throwIfDisposed();
            await sink.writeFrom(plaintext);
            await sink.flush();
            _throwIfDisposed();
            offset += plaintext.length;
            if (offset <= lastOffset && !response.eof) {
              throw const FormatException('chunk_made_no_progress');
            }
            lastOffset = offset;
            record = record.copyWith(confirmedOffset: offset);
            batch = await _replaceFile(batch, index, record);
            _throwIfDisposed();
            connection.sendTransferControl({
              'v': 1,
              'kind': 'transfer_progress',
              'transferId': offer.transferId,
              'fileId': offeredFile.fileId,
              'confirmedOffset': offset,
            });
            if (response.eof) break;
          }
        } finally {
          await sink.close();
        }
        _throwIfDisposed();
        final digest = (await hashes.sha256.bind(partial.openRead()).first)
            .toString();
        _throwIfDisposed();
        if (digest != offeredFile.sha256 || offset != offeredFile.size) {
          if (await partial.exists()) await partial.delete();
          throw const FormatException('hash_mismatch');
        }
        final privateDestination = await _finalize(
          partial,
          root,
          offeredFile.filename,
        );
        await privateDestination.setLastModified(
          DateTime.fromMillisecondsSinceEpoch(offeredFile.lastModifiedMs),
        );
        final destination = publisher == null
            ? privateDestination.path
            : await publisher!.publish(
                sourcePath: privateDestination.path,
                filename: offeredFile.filename,
                mime: offeredFile.mime,
                lastModifiedMs: offeredFile.lastModifiedMs,
              );
        _throwIfDisposed();
        record = record.copyWith(
          status: PhoneTransferStatus.completed,
          confirmedOffset: offeredFile.size,
          destinationPath: destination,
        );
        batch = await _replaceFile(batch, index, record);
        _throwIfDisposed();
        connection.sendTransferControl({
          'v': 1,
          'kind': 'transfer_file_complete',
          'transferId': offer.transferId,
          'fileId': offeredFile.fileId,
          'sha256': digest,
        });
        onEvent?.call('Received ${offeredFile.filename}');
      } on _TransferCancelled {
        return;
      } on Object catch (error) {
        if (_disposed) return;
        final code = error.toString().contains('hash_mismatch')
            ? 'hash_mismatch'
            : 'receive_failed';
        batch = await _failFile(
          batch,
          index,
          code,
          errorOrigin: 'local',
          errorCategory: code == 'hash_mismatch' ? 'integrity' : 'internal',
          errorDetail: 'Phone could not receive ${offeredFile.filename}.',
        );
        connection.sendTransferControl({
          'v': 1,
          'kind': 'transfer_file_failed',
          'transferId': offer.transferId,
          'fileId': offeredFile.fileId,
          'code': code,
        });
        onEvent?.call(
          'Could not receive ${offeredFile.filename}: $error',
          isError: true,
        );
      }
    }
    final failed = batch.files.any(
      (file) => file.status == PhoneTransferStatus.failed,
    );
    batch = batch.copyWith(
      status: failed
          ? PhoneTransferStatus.completedWithIssues
          : PhoneTransferStatus.completed,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    await history.upsert(batch);
    if (notifier != null && (alertsEnabled == null || await alertsEnabled!())) {
      _throwIfDisposed();
      await notifier!.showBatchResult(
        filenames: batch.files.map((file) => file.filename).toList(),
        failed: failed,
      );
    }
  }

  void _throwIfDisposed() {
    if (_disposed) throw const _TransferCancelled();
  }

  Future<_DownloadChunk> _getChunk({
    required PairingCode pairing,
    required String transferId,
    required String fileId,
    required int offset,
  }) async {
    final path = '/transfer/v1/$transferId/$fileId?offset=$offset';
    final auth = await createTransferHttpAuth(
      pairingSecret: pairing.secret,
      method: 'GET',
      pathAndQuery: path,
    );
    final request = await _httpClient.getUrl(
      Uri.parse('http://${pairing.host}:${pairing.port}$path'),
    );
    auth.headers.forEach(request.headers.set);
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      final body = await utf8.decodeStream(
        response.timeout(const Duration(seconds: 30)),
      );
      throw StateError(body);
    }
    final nonce = response.headers.value('x-vidyut-nonce');
    final responseOffset = int.tryParse(
      response.headers.value('x-vidyut-offset') ?? '',
    );
    final plaintextBytes = int.tryParse(
      response.headers.value('x-vidyut-plaintext-bytes') ?? '',
    );
    if (nonce == null ||
        responseOffset != offset ||
        plaintextBytes == null ||
        plaintextBytes < 0 ||
        plaintextBytes > chunkBytes) {
      throw const FormatException('Invalid encrypted chunk headers.');
    }
    final ciphertext = await response
        .timeout(const Duration(seconds: 30))
        .fold<List<int>>(<int>[], (bytes, chunk) => bytes..addAll(chunk));
    return _DownloadChunk(
      chunk: EncryptedTransferChunk(
        transferId: transferId,
        fileId: fileId,
        offset: offset,
        plaintextBytes: plaintextBytes,
        nonce: nonce,
        ciphertext: ciphertext,
      ),
      eof: response.headers.value('x-vidyut-eof') == 'true',
    );
  }

  Future<PhoneTransferBatch> _existingOrCreate(TransferOffer offer) async {
    final existing = (await history.load()).where(
      (batch) => batch.transferId == offer.transferId,
    );
    if (existing.isNotEmpty) return existing.first;
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = PhoneTransferBatch(
      transferId: offer.transferId,
      batchId: offer.batchId,
      direction: PhoneTransferDirection.received,
      createdAtMs: offer.createdAtMs,
      updatedAtMs: now,
      status: PhoneTransferStatus.queued,
      files: offer.files
          .map(
            (file) => PhoneTransferFile(
              fileId: file.fileId,
              filename: file.filename,
              mime: file.mime,
              size: file.size,
              lastModifiedMs: file.lastModifiedMs,
              sha256: file.sha256,
              status: PhoneTransferStatus.queued,
              confirmedOffset: 0,
            ),
          )
          .toList(),
    );
    await history.upsert(batch);
    return batch;
  }

  Future<PhoneTransferBatch> _replaceFile(
    PhoneTransferBatch batch,
    int index,
    PhoneTransferFile file,
  ) async {
    final files = [...batch.files]..[index] = file;
    final updated = batch.copyWith(
      files: files,
      status: PhoneTransferStatus.active,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    await history.upsert(updated);
    return updated;
  }

  Future<PhoneTransferBatch> _failFile(
    PhoneTransferBatch batch,
    int index,
    String code, {
    String? errorOrigin,
    String? errorCategory,
    String? errorDetail,
    Map<String, Object?>? errorContext,
  }) {
    return _replaceFile(
      batch,
      index,
      batch.files[index].copyWith(
        status: PhoneTransferStatus.failed,
        errorCode: code,
        errorOrigin: errorOrigin,
        errorCategory: errorCategory,
        errorDetail: errorDetail,
        errorContext: errorContext,
      ),
    );
  }

  Future<Directory> _defaultRoot() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/vidyut_received_files');
  }
}

abstract interface class TransferNotifier {
  Future<void> showBatchResult({
    required List<String> filenames,
    required bool failed,
  });
}

class LocalTransferNotifier implements TransferNotifier {
  LocalTransferNotifier({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  @override
  Future<void> showBatchResult({
    required List<String> filenames,
    required bool failed,
  }) async {
    if (!_initialized) {
      _initialized = true;
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
    }
    final count = filenames.length;
    await _plugin.show(
      id: 4301,
      title: failed
          ? 'File transfer completed with issues'
          : count == 1
          ? 'File received'
          : '$count files received',
      body: count == 1 ? filenames.first : filenames.take(3).join(', '),
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'vidyut_file_transfers',
          'Vidyut file transfers',
          channelDescription: 'File transfer completion and failure alerts',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
      ),
    );
  }
}

abstract interface class ReceivedFilePublisher {
  Future<String> publish({
    required String sourcePath,
    required String filename,
    required String mime,
    required int lastModifiedMs,
  });
}

class AndroidReceivedFilePublisher implements ReceivedFilePublisher {
  const AndroidReceivedFilePublisher();

  final VidyutFiles _files = const VidyutFiles();

  @override
  Future<String> publish({
    required String sourcePath,
    required String filename,
    required String mime,
    required int lastModifiedMs,
  }) {
    return _files.publish(
      sourcePath: sourcePath,
      filename: filename,
      mime: mime,
      lastModifiedMs: lastModifiedMs,
    );
  }
}

class _DownloadChunk {
  const _DownloadChunk({required this.chunk, required this.eof});

  final EncryptedTransferChunk chunk;
  final bool eof;
}

class _TransferCancelled implements Exception {
  const _TransferCancelled();
}

Future<File> _finalize(File partial, Directory root, String filename) async {
  final dot = filename.lastIndexOf('.');
  final stem = dot > 0 ? filename.substring(0, dot) : filename;
  final extension = dot > 0 ? filename.substring(dot) : '';
  for (var suffix = 0; suffix < 10000; suffix++) {
    final candidate = File(
      '${root.path}/${suffix == 0 ? filename : '$stem ($suffix)$extension'}',
    );
    if (await candidate.exists()) continue;
    return partial.rename(candidate.path);
  }
  throw StateError('Could not resolve a collision-free destination.');
}
