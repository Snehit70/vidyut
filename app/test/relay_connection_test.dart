import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/pairing/pairing_code.dart';
import 'package:vidyut/src/shared/relay_connection.dart';
import 'package:vidyut/src/shared/session_seal.dart';
import 'package:vidyut/src/shared/wire.dart';

void main() {
  test('authenticates after the relay hello challenge', () async {
    final transport = FakeRelayTransport();
    final connection = RelayConnection(
      pairing: const PairingCode(
        host: '127.0.0.1',
        port: 17321,
        secret: 'pairing-secret',
      ),
      deviceId: 'phone',
      transport: transport,
    );

    await connection.start();
    transport.receive({
      'v': 1,
      'kind': 'hello',
      'challenge': 'relay-challenge',
      'maxPayloadBytes': 1024,
    });

    await expectLater(
      transport.sent,
      emits(
        containsPair('proof', 'gFce+C2P9TQ91OoLN1X06McZlUr+nxscxhSwDrBkBh4='),
      ),
    );
  });

  test('emits connected status after auth succeeds', () async {
    final transport = FakeRelayTransport();
    final connection = RelayConnection(
      pairing: const PairingCode(
        host: '127.0.0.1',
        port: 17321,
        secret: 'pairing-secret',
      ),
      deviceId: 'phone',
      transport: transport,
    );

    await connection.start();
    transport.receive({'v': 1, 'kind': 'auth_ok'});

    await expectLater(connection.status, emits(ConnectionStatus.connected));
  });

  test('emits authenticated relay health and live health changes', () async {
    final transport = FakeRelayTransport();
    final connection = RelayConnection(
      pairing: const PairingCode(
        host: '127.0.0.1',
        port: 17321,
        secret: 'pairing-secret',
      ),
      deviceId: 'phone',
      transport: transport,
    );

    await connection.start();
    final states = connection.health.take(2).toList();
    transport.receive({
      'v': 1,
      'kind': 'auth_ok',
      'health': {
        'status': 'ok',
        'relayName': 'framework',
        'clipboard': {'enabled': true, 'status': 'healthy'},
      },
    });
    transport.receive({
      'v': 1,
      'kind': 'health',
      'health': {
        'status': 'degraded',
        'relayName': 'framework',
        'clipboard': {
          'enabled': true,
          'status': 'degraded',
          'error': 'watcher exited',
        },
      },
    });

    final health = await states;
    expect(health.first.relayName, 'framework');
    expect(health.first.degraded, isFalse);
    expect(health.last.degraded, isTrue);
    expect(health.last.clipboardError, 'watcher exited');
  });

  test('ignores malformed nested health fields', () {
    final health = RelayHealth.fromJson({
      'status': 'ok',
      'relayName': 'framework',
      'clipboard': {'status': 123, 'error': true},
    });

    expect(health, isNotNull);
    expect(health!.clipboardStatus, isNull);
    expect(health.clipboardError, isNull);
  });

  test('emits incoming payload frames', () async {
    final transport = FakeRelayTransport();
    final connection = RelayConnection(
      pairing: const PairingCode(
        host: '127.0.0.1',
        port: 17321,
        secret: 'pairing-secret',
      ),
      deviceId: 'phone',
      transport: transport,
    );
    const frame = PayloadFrame(
      type: PayloadType.text,
      mime: 'text/plain',
      origin: 'laptop',
      ts: 1800000200000,
      nonce: 'nonce',
      payload: 'payload',
    );

    await connection.start();
    transport.receive({'v': 1, 'kind': 'payload', 'frame': frame.toJson()});

    await expectLater(connection.payloads, emits(frame));
  });

  test('publishes payload frames to the relay', () async {
    final transport = FakeRelayTransport();
    final connection = RelayConnection(
      pairing: const PairingCode(
        host: '127.0.0.1',
        port: 17321,
        secret: 'pairing-secret',
      ),
      deviceId: 'phone',
      transport: transport,
      clock: () => DateTime.fromMillisecondsSinceEpoch(1800000200050),
    );
    const frame = PayloadFrame(
      type: PayloadType.text,
      mime: 'text/plain',
      origin: 'phone',
      ts: 1800000200001,
      nonce: 'nonce',
      payload: 'payload',
    );

    await connection.start();
    connection.publish(frame);

    await expectLater(
      transport.sent,
      emits({
        'v': 1,
        'kind': 'publish',
        'frame': frame.toJson(),
        'sentAt': 1800000200050,
      }),
    );
  });

  test('a stale ack still acks and explains the dropped copy', () async {
    final transport = FakeRelayTransport();
    final connection = RelayConnection(
      pairing: const PairingCode(
        host: '127.0.0.1',
        port: 17321,
        secret: 'pairing-secret',
      ),
      deviceId: 'phone',
      transport: transport,
    );

    await connection.start();
    final ack = connection.acks.first;
    final event = connection.events.first;
    transport.receive({'v': 1, 'kind': 'ack', 'ts': 42, 'stale': true});

    expect(await ack, 42);
    final dropped = await event;
    expect(dropped.code, 'stale');
    expect(dropped.isError, isFalse);
  });

  test('sends and emits typed transfer control messages', () async {
    final transport = FakeRelayTransport();
    final connection = RelayConnection(
      pairing: const PairingCode(
        host: '127.0.0.1',
        port: 17321,
        secret: 'pairing-secret',
      ),
      deviceId: 'phone',
      transport: transport,
    );
    final message = <String, Object?>{
      'v': 1,
      'kind': 'transfer_cancel',
      'transferId': 'transfer_1234567890',
    };

    await connection.start();
    connection.sendTransferControl(message);
    await expectLater(transport.sent, emits(message));

    final incoming = connection.transferControls.first;
    transport.receive(message);
    expect(await incoming, message);
  });

  test('socket-closed event carries the close code and reason', () async {
    final transport = FakeRelayTransport();
    final connection = RelayConnection(
      pairing: const PairingCode(
        host: '127.0.0.1',
        port: 17321,
        secret: 'pairing-secret',
      ),
      deviceId: 'phone',
      transport: transport,
    );

    await connection.start();
    final closedEvent = connection.events.firstWhere(
      (event) => event.message.startsWith('Relay socket closed'),
    );
    transport.closeCode = 1001;
    transport.closeReason = 'ping timeout';
    await transport.endIncoming();

    final event = await closedEvent;
    expect(
      event.message,
      'Relay socket closed (code: 1001, reason: ping timeout).',
    );
  });

  test('socket-closed event reports a missing close code', () async {
    final transport = FakeRelayTransport();
    final connection = RelayConnection(
      pairing: const PairingCode(
        host: '127.0.0.1',
        port: 17321,
        secret: 'pairing-secret',
      ),
      deviceId: 'phone',
      transport: transport,
    );

    await connection.start();
    final closedEvent = connection.events.firstWhere(
      (event) => event.message.startsWith('Relay socket closed'),
    );
    await transport.endIncoming();

    expect((await closedEvent).message, 'Relay socket closed (code: none).');
  });

  test('captures the hello-advertised payload cap', () async {
    final transport = FakeRelayTransport();
    final connection = RelayConnection(
      pairing: const PairingCode(
        host: '127.0.0.1',
        port: 17321,
        secret: 'pairing-secret',
      ),
      deviceId: 'phone',
      transport: transport,
    );

    expect(connection.maxPayloadBytes, RelayConnection.defaultMaxPayloadBytes);

    await connection.start();
    transport.receive({
      'v': 1,
      'kind': 'hello',
      'challenge': 'relay-challenge',
      'maxPayloadBytes': 4096,
    });
    // The proof send signals the hello was fully handled.
    await expectLater(transport.sent, emits(containsPair('kind', 'auth')));

    expect(connection.maxPayloadBytes, 4096);
  });

  test('asks for telemetry only while wanted on a relay that offers it', () async {
    final transport = FakeRelayTransport();
    final sent = <Map<String, Object?>>[];
    transport.sent.listen(sent.add);
    final connection = RelayConnection(
      pairing: const PairingCode(
        host: '127.0.0.1',
        port: 17321,
        secret: 'pairing-secret',
      ),
      deviceId: 'phone',
      transport: transport,
    );
    connection.telemetryWanted = true;

    await connection.start();
    transport.receive({
      'v': 1,
      'kind': 'hello',
      'challenge': 'relay-challenge',
      'maxPayloadBytes': 4096,
      'features': ['telemetry_subscribe'],
    });
    await pumpEventQueue();
    expect(sent.single['features'], contains('telemetry_subscribe'));

    transport.receive({'v': 1, 'kind': 'auth_ok'});
    await pumpEventQueue();
    connection.telemetryWanted = false;
    connection.telemetryWanted = false;
    await pumpEventQueue();

    expect(sent.skip(1), [
      {'v': 1, 'kind': 'telemetry_subscribe', 'active': true},
      {'v': 1, 'kind': 'telemetry_subscribe', 'active': false},
    ]);
  });

  test('never sends a telemetry subscription to an older relay', () async {
    final transport = FakeRelayTransport();
    final sent = <Map<String, Object?>>[];
    transport.sent.listen(sent.add);
    final connection = RelayConnection(
      pairing: const PairingCode(
        host: '127.0.0.1',
        port: 17321,
        secret: 'pairing-secret',
      ),
      deviceId: 'phone',
      transport: transport,
    );
    connection.telemetryWanted = true;

    await connection.start();
    transport.receive({
      'v': 1,
      'kind': 'hello',
      'challenge': 'relay-challenge',
      'maxPayloadBytes': 4096,
    });
    transport.receive({'v': 1, 'kind': 'auth_ok'});
    await pumpEventQueue();
    connection.telemetryWanted = false;
    connection.telemetryWanted = true;
    await pumpEventQueue();

    // An unknown kind would come back as an error and drop the session.
    expect(sent.map((message) => message['kind']), ['auth']);
  });

  test('surfaces publish acks as a stream of acked ts', () async {
    final transport = FakeRelayTransport();
    final connection = RelayConnection(
      pairing: const PairingCode(
        host: '127.0.0.1',
        port: 17321,
        secret: 'pairing-secret',
      ),
      deviceId: 'phone',
      transport: transport,
    );

    await connection.start();
    transport.receive({'v': 1, 'kind': 'ack', 'ts': 1800000200002});

    await expectLater(connection.acks, emits(1800000200002));
  });

  test('relay errors carry the machine-readable code', () async {
    final transport = FakeRelayTransport();
    final connection = RelayConnection(
      pairing: const PairingCode(
        host: '127.0.0.1',
        port: 17321,
        secret: 'pairing-secret',
      ),
      deviceId: 'phone',
      transport: transport,
    );

    await connection.start();
    final errorEvent = connection.events.firstWhere((event) => event.isError);
    transport.receive({
      'v': 1,
      'kind': 'error',
      'code': 'payload_too_large',
      'message': 'Payload exceeds 100 bytes.',
    });

    expect((await errorEvent).code, 'payload_too_large');
  });

  group('mutual auth', () {
    const secret = 'pairing-secret';
    const challenge = 'cmVsYXktY2hhbGxlbmdlLWJ5dGVz';

    late FakeRelayTransport transport;
    late List<Map<String, Object?>> sent;
    late List<ConnectionStatus> statuses;
    late List<RelayEvent> events;

    RelayConnection connect({bool pinned = false}) {
      transport = FakeRelayTransport();
      sent = [];
      statuses = [];
      events = [];
      transport.sent.listen(sent.add);
      final connection = RelayConnection(
        pairing: PairingCode(
          host: '127.0.0.1',
          port: 17321,
          secret: secret,
          relayVerified: pinned,
        ),
        deviceId: 'phone',
        transport: transport,
      );
      connection.status.listen(statuses.add);
      connection.events.listen(events.add);
      return connection;
    }

    /// Plays the relay's side of the handshake; returns the relay's sealer
    /// when the session is sealed.
    Future<SessionSealer?> handshake({
      List<String> features = const ['sealed_control'],
      String proofSecret = secret,
      bool sendProof = true,
    }) async {
      transport.receive({
        'v': 1,
        'kind': 'hello',
        'challenge': challenge,
        'maxPayloadBytes': 4096,
        'features': ['telemetry_subscribe', 'relay_proof', 'sealed_control'],
      });
      await pumpEventQueue();
      final auth = sent.single;
      expect(auth['features'], contains('sealed_control'));
      final clientChallenge = auth['clientChallenge'] as String;
      transport.receive({
        'v': 1,
        'kind': 'auth_ok',
        if (sendProof) ...{
          'relayProof': await createRelayProof(
            pairingSecret: proofSecret,
            challenge: challenge,
            clientChallenge: clientChallenge,
            sessionFeatures: features,
            deviceId: 'phone',
          ),
          'features': features,
        },
      });
      await pumpEventQueue();
      if (!features.contains('sealed_control')) return null;
      return SessionSealer(
        await deriveSessionKey(
          pairingSecret: secret,
          challenge: challenge,
          clientChallenge: clientChallenge,
          deviceId: 'phone',
        ),
        SealDirection.relayToPhone,
      );
    }

    test('seals control both ways once the relay proves itself', () async {
      final connection = connect();
      final telemetry = <LaptopTelemetry>[];
      connection.telemetry.listen(telemetry.add);
      await connection.start();
      final relay = (await handshake())!;

      expect(statuses.last, ConnectionStatus.connected);
      expect(connection.relayVerified, isTrue);

      transport.receive(
        await relay.seal({
          'v': 1,
          'kind': 'telemetry',
          'ts': 1,
          'batteryPercent': 50,
        }),
      );
      await pumpEventQueue();
      expect(telemetry, hasLength(1));

      const control = {
        'v': 1,
        'kind': 'transfer_cancel',
        'transferId': 'transfer-1',
      };
      connection.sendTransferControl(control);
      await pumpEventQueue();
      expect(sent.last['kind'], 'sealed');
      expect(await relay.open(sent.last), control);
    });

    test('drops an unsealed control message on a sealed session', () async {
      final connection = connect();
      final telemetry = <LaptopTelemetry>[];
      connection.telemetry.listen(telemetry.add);
      await connection.start();
      await handshake();

      transport.receive({
        'v': 1,
        'kind': 'telemetry',
        'ts': 1,
        'batteryPercent': 50,
      });
      await pumpEventQueue();

      expect(telemetry, isEmpty);
      expect(statuses.last, ConnectionStatus.connected);
    });

    test('goes offline when a sealed message fails to open', () async {
      final connection = connect();
      await connection.start();
      final relay = (await handshake())!;
      final message = await relay.seal({'v': 1, 'kind': 'health'});

      transport.receive(message);
      transport.receive(message);
      await pumpEventQueue();

      expect(statuses.last, ConnectionStatus.offline);
      expect(events.last.code, 'seal_failed');
    });

    test('refuses a relay whose proof does not verify', () async {
      final connection = connect();
      await connection.start();
      await handshake(proofSecret: 'someone-else');

      expect(statuses, [ConnectionStatus.searching, ConnectionStatus.offline]);
      expect(events.last.code, 'relay_unverified');
      expect(connection.relayVerified, isFalse);
    });

    test('accepts an older relay until the pairing has seen a proof', () async {
      final connection = connect();
      await connection.start();
      await handshake(sendProof: false);

      expect(statuses.last, ConnectionStatus.connected);
      expect(connection.relayVerified, isFalse);
    });

    test('refuses a missing proof once the pairing is pinned', () async {
      final connection = connect(pinned: true);
      await connection.start();
      await handshake(sendProof: false);

      expect(statuses.last, ConnectionStatus.offline);
      expect(events.last.code, 'relay_unverified');
    });

    test('refuses an unsealed session once the pairing is pinned', () async {
      final connection = connect(pinned: true);
      await connection.start();
      await handshake(features: const []);

      expect(statuses.last, ConnectionStatus.offline);
      expect(events.last.code, 'relay_unverified');
    });
  });
}

class FakeRelayTransport implements RelayTransport {
  final _incoming = StreamController<Object?>();
  final _sent = StreamController<Map<String, Object?>>();

  @override
  int? closeCode;

  @override
  String? closeReason;

  Stream<Map<String, Object?>> get sent => _sent.stream;

  void receive(Map<String, Object?> message) {
    _incoming.add(jsonEncode(message));
  }

  /// Ends the message stream as a closing socket would.
  Future<void> endIncoming() => _incoming.close();

  @override
  Stream<Object?> get messages => _incoming.stream;

  @override
  void send(Map<String, Object?> message) {
    _sent.add(message);
  }

  @override
  Future<void> close() async {
    await _incoming.close();
    await _sent.close();
  }
}
