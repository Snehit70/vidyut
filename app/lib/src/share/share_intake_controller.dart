import 'dart:async';

import 'share_payload.dart';
import 'share_publisher.dart';
import 'share_source.dart';
import '../transfer/phone_transfer_sender.dart';

typedef ShareStatusListener =
    void Function(SharePayload payload, SharePublishResult result);

class ShareIntakeController {
  ShareIntakeController({
    required this.source,
    required this.publisher,
    this.onResult,
    this.transferSender,
    this.onTransferResult,
  });

  final ShareSource source;
  final SharePublisher publisher;
  final ShareStatusListener? onResult;
  final PhoneTransferSender? transferSender;
  final void Function(Object result, {bool isError})? onTransferResult;
  StreamSubscription<List<SharePayload>>? _subscription;

  Future<void> start() async {
    await _publishAll(await source.initialPayloads());
    await source.reset();
    _subscription = source.payloadStream().listen((payloads) {
      unawaited(_publishAll(payloads));
    });
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
  }

  Future<void> _publishAll(List<SharePayload> payloads) async {
    final files = payloads
        .where((payload) => payload.type == SharePayloadType.file)
        .toList();
    for (final payload in payloads.where(
      (payload) => payload.type != SharePayloadType.file,
    )) {
      onResult?.call(payload, await publisher.publish(payload));
    }
    final sender = transferSender;
    if (files.isEmpty) return;
    if (sender == null) {
      onTransferResult?.call(
        StateError('File transfer is unavailable.'),
        isError: true,
      );
      return;
    }
    try {
      final result = await sender.enqueue(
        files
            .map(
              (payload) => PhoneTransferSource(
                path: payload.path!,
                filename: payload.filename!,
                mime: payload.mime,
              ),
            )
            .toList(),
      );
      onTransferResult?.call(result);
    } on Object catch (error) {
      onTransferResult?.call(error, isError: true);
    }
  }
}
