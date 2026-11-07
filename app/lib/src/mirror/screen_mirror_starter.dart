import 'dart:async';

import 'package:screen_mirror/screen_mirror.dart';

import '../pairing/pairing_code.dart';
import '../shared/relay_connection.dart';
import '../transfer/phone_transfer_types.dart';

/// How a tap on "Mirror screen" ended.
sealed class ScreenMirrorOutcome {
  const ScreenMirrorOutcome();
}

class ScreenMirrorShowing extends ScreenMirrorOutcome {
  const ScreenMirrorShowing();
}

class ScreenMirrorEnded extends ScreenMirrorOutcome {
  const ScreenMirrorEnded();
}

class ScreenMirrorDeclined extends ScreenMirrorOutcome {
  const ScreenMirrorDeclined();
}

class ScreenMirrorProblem extends ScreenMirrorOutcome implements Exception {
  const ScreenMirrorProblem(this.message);

  final String message;
}

/// Starts or stops the phone screen in a laptop window (ADR 0030).
///
/// Starting asks Android for capture first, since the user may take a while
/// to answer, then asks the laptop for a stream ticket on a short sealed
/// session of its own, and hands the ticket to the native service. The
/// ticket is good for 15 seconds, which covers the rest.
class ScreenMirrorStarter {
  ScreenMirrorStarter({
    required this.pairing,
    required this.connectionFactory,
    ScreenMirror? mirror,
    this.connectTimeout = const Duration(seconds: 10),
    this.replyTimeout = const Duration(seconds: 10),
    this.startTimeout = const Duration(seconds: 15),
  }) : mirror = mirror ?? ScreenMirror();

  final PairingCode pairing;
  final TransferRelayConnectionFactory connectionFactory;
  final ScreenMirror mirror;
  final Duration connectTimeout;
  final Duration replyTimeout;
  final Duration startTimeout;

  /// Starts the mirror, or stops it when it already runs.
  Future<ScreenMirrorOutcome> toggle() async {
    if (await mirror.isRunning()) {
      await mirror.stop();
      return const ScreenMirrorEnded();
    }
    return start();
  }

  Future<ScreenMirrorOutcome> start() async {
    if (!await mirror.requestConsent()) return const ScreenMirrorDeclined();
    final size = await mirror.encoderSize();
    final Map<String, Object?> ticket;
    try {
      ticket = await _ticket(size);
    } on ScreenMirrorProblem catch (problem) {
      await mirror.stop();
      return problem;
    }
    final streamId = ticket['streamId'];
    final key = ticket['key'];
    if (streamId is! String || key is! String) {
      await mirror.stop();
      return const ScreenMirrorProblem('The laptop sent a bad mirror ticket.');
    }
    final url = Uri(
      scheme: 'ws',
      host: pairing.host,
      port: pairing.port,
      path: '/screen/v1/$streamId',
    ).toString();

    // Listen before starting so the first state is not missed.
    final first = mirror.states.first.timeout(
      startTimeout,
      onTimeout: () =>
          const ScreenMirrorFailed('The screen mirror did not start.'),
    );
    await mirror.start(url: url, key: key);
    return switch (await first) {
      ScreenMirrorStreaming() => const ScreenMirrorShowing(),
      ScreenMirrorFailed(:final message) => ScreenMirrorProblem(message),
      ScreenMirrorStopped() => const ScreenMirrorProblem(
        'The laptop closed the screen mirror.',
      ),
    };
  }

  Future<Map<String, Object?>> _ticket(ScreenMirrorSize size) async {
    final connection = connectionFactory(pairing);
    final settled = Completer<bool>();
    final statusSubscription = connection.status.listen((status) {
      if (status == ConnectionStatus.searching || settled.isCompleted) return;
      settled.complete(status == ConnectionStatus.connected);
    });
    try {
      await connection.start();
      final connected = await settled.future.timeout(
        connectTimeout,
        onTimeout: () => false,
      );
      if (!connected) {
        throw const ScreenMirrorProblem('Could not reach the laptop.');
      }
      if (!connection.canMirrorScreen) {
        throw const ScreenMirrorProblem(
          'Update Vidyut on the laptop to mirror the screen.',
        );
      }
      final reply = connection.screenReplies.first.timeout(
        replyTimeout,
        onTimeout: () =>
            throw const ScreenMirrorProblem('The laptop did not answer.'),
      );
      connection.sendScreenStart(width: size.width, height: size.height);
      final message = await reply;
      if (message['kind'] != 'screen_ready') {
        final detail = message['message'];
        throw ScreenMirrorProblem(
          detail is String ? detail : 'The laptop could not show the screen.',
        );
      }
      return message;
    } finally {
      await statusSubscription.cancel();
      await connection.close();
    }
  }
}
