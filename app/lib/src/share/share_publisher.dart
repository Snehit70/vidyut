import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../pairing/pairing_code.dart';
import '../pairing/pairing_repository.dart';
import '../shared/payload_crypto.dart';
import '../shared/relay_connection.dart';
import '../shared/wire.dart';
import 'share_payload.dart';

typedef RelaySessionFactory = RelaySession Function(PairingCode pairing);
typedef ShareClock = DateTime Function();

/// Reads the "Open links on the laptop" setting at send time, so a toggle
/// takes effect on the next send without rebuilding the publisher.
typedef OpenLinksSetting = Future<bool> Function();

abstract interface class ShareFileReader {
  Future<List<int>> readBytes(String path);
}

class LocalShareFileReader implements ShareFileReader {
  const LocalShareFileReader();

  @override
  Future<List<int>> readBytes(String path) => File(path).readAsBytes();
}

class SharePublishResult {
  const SharePublishResult._(this.published, this.message);

  const SharePublishResult.published() : this._(true, 'Published to relay.');

  const SharePublishResult.failed(String message) : this._(false, message);

  final bool published;
  final String message;
}

class SharePublisher {
  SharePublisher({
    required this.pairingRepository,
    required this.relaySessionFactory,
    required this.crypto,
    required this.fileReader,
    this.origin = 'phone',
    this.clock = DateTime.now,
    this.connectionTimeout = const Duration(seconds: 5),
    this.openLinksOnLaptop,
  });

  final PairingRepository pairingRepository;
  final RelaySessionFactory relaySessionFactory;
  final PayloadCrypto crypto;
  final ShareFileReader fileReader;
  final String origin;
  final ShareClock clock;
  final Duration connectionTimeout;

  /// Omitted, links always open on the laptop.
  final OpenLinksSetting? openLinksOnLaptop;

  Future<SharePublishResult> publish(SharePayload payload) async {
    if (payload.type == SharePayloadType.file) {
      return const SharePublishResult.failed(
        'Files must use the transfer sender.',
      );
    }
    final pairing = await pairingRepository.load();
    if (pairing == null) {
      return const SharePublishResult.failed(
        'Pair with the laptop relay before sharing.',
      );
    }

    // With link opening off, a link goes as plain text. The laptop keys off the
    // type, so it still lands in the clipboard and no tab opens (ADR 0022).
    final opensLinks =
        payload.type != SharePayloadType.link ||
        await (openLinksOnLaptop?.call() ?? Future.value(true));

    final session = relaySessionFactory(pairing);
    try {
      final connected = _waitForConnected(session);
      await session.start();
      final ready = await connected;
      if (!ready) return const SharePublishResult.failed('Relay is offline.');

      session.publish(
        await crypto.encrypt(
          metadata: PayloadMetadata(
            type: switch (payload.type) {
              SharePayloadType.text => PayloadType.text,
              SharePayloadType.link =>
                opensLinks ? PayloadType.link : PayloadType.text,
              SharePayloadType.image => PayloadType.image,
              SharePayloadType.file => throw StateError(
                'File reached clipboard publisher.',
              ),
            },
            mime: payload.mime,
            origin: origin,
            ts: clock().millisecondsSinceEpoch,
          ),
          plaintext: await _plaintext(payload),
          pairingSecret: pairing.secret,
        ),
      );
      return const SharePublishResult.published();
    } on TimeoutException {
      return const SharePublishResult.failed('Timed out connecting to relay.');
    } on Object catch (error) {
      return SharePublishResult.failed('Share failed: $error');
    } finally {
      await session.close();
    }
  }

  Future<List<int>> _plaintext(SharePayload payload) {
    return switch (payload.type) {
      SharePayloadType.text => Future.value(utf8.encode(payload.text ?? '')),
      SharePayloadType.link => Future.value(utf8.encode(payload.text ?? '')),
      SharePayloadType.image => fileReader.readBytes(payload.path!),
      SharePayloadType.file => Future.error(
        StateError('File reached clipboard publisher.'),
      ),
    };
  }

  Future<bool> _waitForConnected(RelaySession session) async {
    return session.status
        .firstWhere(
          (status) =>
              status == ConnectionStatus.connected ||
              status == ConnectionStatus.offline,
        )
        .then((status) => status == ConnectionStatus.connected)
        .timeout(connectionTimeout);
  }
}
