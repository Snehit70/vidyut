import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../pairing/pairing_code.dart';
import '../shared/relay_connection.dart';
import '../transfer/phone_transfer_sender.dart';

/// A shared folder on the laptop. [id] is what requests name it by.
class BrowseRoot {
  const BrowseRoot({required this.id, required this.name});

  final String id;
  final String name;
}

class BrowseEntry {
  const BrowseEntry({
    required this.name,
    required this.isFolder,
    this.size,
    required this.modified,
  });

  final String name;
  final bool isFolder;

  /// Bytes, for files only.
  final int? size;
  final DateTime modified;
}

class BrowseListing {
  const BrowseListing({required this.entries, required this.truncated});

  final List<BrowseEntry> entries;

  /// The laptop stopped listing at its cap; the folder holds more.
  final bool truncated;
}

/// What a pull put in the laptop's send queue.
class BrowseQueued {
  const BrowseQueued({required this.files, required this.bytes});

  final int files;
  final int bytes;
}

class BrowseFailure implements Exception {
  const BrowseFailure(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// The laptop's shared folders as the browse screen sees them.
abstract interface class LaptopFiles {
  Future<List<BrowseRoot>> roots();

  /// [path] is "/"-separated and relative to [root]; empty is the root.
  Future<BrowseListing> list(String root, String path);

  /// Asks the laptop to send [paths] under [root]. A folder brings everything
  /// under it, subfolders kept; an empty path is the whole root.
  Future<BrowseQueued> pull(String root, List<String> paths);

  Future<void> close();
}

/// Reads the laptop's shared folders and asks it to send files or whole
/// folders (ADR 0026). Pulled files arrive like any laptop send, through the
/// background receiver, so this only lists and asks.
class LaptopFileBrowser implements LaptopFiles {
  LaptopFileBrowser({
    required this.pairing,
    required this.connectionFactory,
    Random? random,
    this.connectTimeout = const Duration(seconds: 10),
    this.requestTimeout = const Duration(seconds: 30),
  }) : _random = random ?? Random.secure();

  final PairingCode pairing;
  final TransferRelayConnectionFactory connectionFactory;
  final Duration connectTimeout;
  final Duration requestTimeout;
  final Random _random;

  final _pending = <String, Completer<Map<String, Object?>>>{};
  Future<RelayConnection>? _connecting;
  RelayConnection? _connection;
  final _subscriptions = <StreamSubscription<Object?>>[];
  bool _closed = false;

  @override
  Future<List<BrowseRoot>> roots() async {
    final reply = await _request({'kind': 'browse_list'});
    return _list(reply['roots']).map((root) {
      final id = root['id'];
      final name = root['name'];
      if (id is! String || name is! String) throw _malformed;
      return BrowseRoot(id: id, name: name);
    }).toList();
  }

  @override
  Future<BrowseListing> list(String root, String path) async {
    final reply = await _request({
      'kind': 'browse_list',
      'root': root,
      if (path.isNotEmpty) 'path': path,
    });
    final entries = _list(reply['entries']).map((entry) {
      final name = entry['name'];
      final kind = entry['kind'];
      final size = entry['size'];
      final modified = entry['modifiedMs'];
      if (name is! String ||
          (kind != 'file' && kind != 'folder') ||
          modified is! int ||
          (size != null && size is! int)) {
        throw _malformed;
      }
      return BrowseEntry(
        name: name,
        isFolder: kind == 'folder',
        size: size as int?,
        modified: DateTime.fromMillisecondsSinceEpoch(modified),
      );
    }).toList();
    return BrowseListing(
      entries: entries,
      truncated: reply['truncated'] == true,
    );
  }

  @override
  Future<BrowseQueued> pull(String root, List<String> paths) async {
    final reply = await _request({
      'kind': 'browse_pull',
      'root': root,
      'paths': paths,
    });
    final queued = reply['queued'];
    if (queued is! Map) throw _malformed;
    final files = queued['files'];
    final bytes = queued['bytes'];
    if (files is! int || bytes is! int) throw _malformed;
    return BrowseQueued(files: files, bytes: bytes);
  }

  @override
  Future<void> close() async {
    _closed = true;
    final connection = _connection;
    _drop(const BrowseFailure('closed', 'Browsing was closed.'));
    await connection?.close();
  }

  Future<Map<String, Object?>> _request(Map<String, Object?> body) async {
    final connection = await _connect();
    final requestId = _requestId();
    final reply = Completer<Map<String, Object?>>();
    _pending[requestId] = reply;
    try {
      connection.sendBrowse({'v': 1, ...body, 'requestId': requestId});
      final message = await reply.future.timeout(
        requestTimeout,
        onTimeout: () =>
            throw const BrowseFailure('timeout', 'The laptop did not answer.'),
      );
      if (message['ok'] != true) {
        final code = message['code'];
        final detail = message['message'];
        throw BrowseFailure(
          code is String ? code : 'failed',
          detail is String ? detail : 'The laptop refused that.',
        );
      }
      return message;
    } finally {
      _pending.remove(requestId);
    }
  }

  Future<RelayConnection> _connect() async {
    if (_closed) throw const BrowseFailure('closed', 'Browsing was closed.');
    final existing = _connecting;
    if (existing != null) return existing;
    final opening = _open();
    _connecting = opening;
    try {
      return await opening;
    } catch (_) {
      if (identical(_connecting, opening)) _connecting = null;
      rethrow;
    }
  }

  Future<RelayConnection> _open() async {
    final connection = connectionFactory(pairing);
    final settled = Completer<bool>();
    _subscriptions
      ..add(
        connection.status.listen((status) {
          if (status == ConnectionStatus.searching) return;
          if (!settled.isCompleted) {
            settled.complete(status == ConnectionStatus.connected);
          } else if (status == ConnectionStatus.offline) {
            _drop(_offline);
          }
        }),
      )
      ..add(
        connection.browseResults.listen((message) {
          final pending = _pending[message['requestId']];
          if (pending != null && !pending.isCompleted) {
            pending.complete(message);
          }
        }),
      );
    try {
      await connection.start();
      final connected = await settled.future.timeout(
        connectTimeout,
        onTimeout: () => false,
      );
      if (!connected) throw _offline;
      if (!connection.canBrowse) {
        throw const BrowseFailure(
          'browse_unavailable',
          'The laptop is not sharing folders. Update Vidyut there, or add '
              'folders to sharedFolders in its config.',
        );
      }
      _connection = connection;
      return connection;
    } catch (_) {
      for (final subscription in _subscriptions) {
        unawaited(subscription.cancel());
      }
      _subscriptions.clear();
      unawaited(connection.close());
      rethrow;
    }
  }

  /// Forgets the session and fails what was waiting on it; the next request
  /// connects again.
  void _drop(BrowseFailure failure) {
    final connection = _connection;
    _connection = null;
    _connecting = null;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(failure);
    }
    if (connection != null && !_closed) unawaited(connection.close());
  }

  String _requestId() => base64Url
      .encode(List<int>.generate(16, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  static Iterable<Map<Object?, Object?>> _list(Object? value) {
    if (value is! List) throw _malformed;
    return value.map((item) => item is Map ? item : throw _malformed);
  }

  static const _offline = BrowseFailure(
    'offline',
    "Can't reach the laptop. Check that both devices are on the same Wi-Fi.",
  );
  static const _malformed = BrowseFailure(
    'malformed',
    'The laptop sent a reply this app does not understand.',
  );
}
