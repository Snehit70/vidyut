import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/pairing/pairing_code.dart';
import 'package:vidyut/src/shared/relay_connection.dart';
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
      emits({'v': 1, 'kind': 'publish', 'frame': frame.toJson()}),
    );
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
