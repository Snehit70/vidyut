import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vidyut/main.dart';
import 'package:vidyut/src/activity/last_activity_repository.dart';
import 'package:vidyut/src/design/motion.dart';
import 'package:vidyut/src/foreground/foreground_service_client.dart';
import 'package:vidyut/src/pairing/pairing_code.dart';
import 'package:vidyut/src/pairing/pairing_repository.dart';
import 'package:vidyut/src/pairing/relay_discovery.dart';
import 'package:vidyut/src/settings/app_settings.dart';
import 'package:vidyut/src/settings/app_settings_repository.dart';
import 'package:vidyut/src/shared/relay_connection.dart';

void main() {
  // Looping animations (blob morph, pulsing dots) never settle; disable them
  // so pumpAndSettle terminates.
  setUp(() => Motion.loopsEnabled = false);
  tearDown(() => Motion.loopsEnabled = true);

  testWidgets('shows manual pairing when no relay is paired', (tester) async {
    await tester.pumpWidget(
      VidyutApp(
        appSettingsRepository: AppSettingsRepository(
          MemoryAppSettingsStorage(),
        ),
        lastActivityRepository: LastActivityRepository(
          MemoryLastActivityStorage(),
        ),
        foregroundServiceClient: FakeForegroundServiceClient(),
        pairingRepository: PairingRepository(MemoryPairingStorage()),
        relayConnectionFactory: fakeConnection,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Unpaired'), findsOneWidget);
    expect(find.text('Relay IP'), findsOneWidget);
    expect(find.text('Pair manually'), findsOneWidget);
    expect(find.text('Scan QR'), findsOneWidget);
  });

  testWidgets('saves manual pairing and shows searching state', (tester) async {
    await tester.pumpWidget(
      VidyutApp(
        appSettingsRepository: AppSettingsRepository(
          MemoryAppSettingsStorage(),
        ),
        lastActivityRepository: LastActivityRepository(
          MemoryLastActivityStorage(),
        ),
        foregroundServiceClient: FakeForegroundServiceClient(),
        pairingRepository: PairingRepository(MemoryPairingStorage()),
        relayConnectionFactory: fakeConnection,
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Relay IP'),
      '192.168.1.10',
    );
    await tester.enterText(find.widgetWithText(TextField, 'Port'), '17321');
    await tester.enterText(
      find.widgetWithText(TextField, 'Pairing secret'),
      'secret',
    );
    await tester.ensureVisible(find.text('Pair manually'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pair manually'));
    await tester.pumpAndSettle();

    expect(find.text('Searching'), findsOneWidget);
    expect(find.textContaining('192.168.1.10:17321'), findsOneWidget);
  });

  testWidgets('loads existing pairing from storage', (tester) async {
    final storage = MemoryPairingStorage();
    await PairingRepository(storage).save(
      const PairingCode(host: '192.168.1.20', port: 17321, secret: 'secret'),
    );

    await tester.pumpWidget(
      VidyutApp(
        appSettingsRepository: AppSettingsRepository(
          MemoryAppSettingsStorage(),
        ),
        lastActivityRepository: LastActivityRepository(
          MemoryLastActivityStorage(),
        ),
        foregroundServiceClient: FakeForegroundServiceClient(),
        pairingRepository: PairingRepository(storage),
        relayConnectionFactory: fakeConnection,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Searching'), findsOneWidget);
    expect(find.textContaining('192.168.1.20:17321'), findsOneWidget);
  });

  testWidgets('lists nearby relays and selecting one fills host and port', (
    tester,
  ) async {
    await tester.pumpWidget(
      VidyutApp(
        appSettingsRepository: AppSettingsRepository(
          MemoryAppSettingsStorage(),
        ),
        lastActivityRepository: LastActivityRepository(
          MemoryLastActivityStorage(),
        ),
        foregroundServiceClient: FakeForegroundServiceClient(),
        pairingRepository: PairingRepository(MemoryPairingStorage()),
        relayConnectionFactory: fakeConnection,
        relayDiscovery: FakeRelayDiscovery(const [
          DiscoveredRelay(
            name: 'Vidyut Relay',
            host: '192.168.1.5',
            port: 17321,
          ),
        ]),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Nearby relays'), findsOneWidget);
    expect(find.text('Vidyut Relay'), findsOneWidget);
    expect(find.text('192.168.1.5:17321'), findsOneWidget);

    await tester.tap(find.text('Vidyut Relay'));
    await tester.pumpAndSettle();

    final hostField = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Relay IP'),
    );
    final portField = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Port'),
    );
    expect(hostField.controller!.text, '192.168.1.5');
    expect(portField.controller!.text, '17321');

    await tester.enterText(
      find.widgetWithText(TextField, 'Pairing secret'),
      'secret',
    );
    // The finder matches while the button is still in the ListView cache
    // extent, so scrollUntilVisible would stop before it is tappable.
    await tester.ensureVisible(find.text('Pair manually'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pair manually'));
    await tester.pumpAndSettle();

    expect(find.text('Searching'), findsOneWidget);
    expect(find.textContaining('192.168.1.5:17321'), findsOneWidget);
  });

  testWidgets('shows guidance when no relays are discovered', (tester) async {
    await tester.pumpWidget(
      VidyutApp(
        appSettingsRepository: AppSettingsRepository(
          MemoryAppSettingsStorage(),
        ),
        lastActivityRepository: LastActivityRepository(
          MemoryLastActivityStorage(),
        ),
        foregroundServiceClient: FakeForegroundServiceClient(),
        pairingRepository: PairingRepository(MemoryPairingStorage()),
        relayConnectionFactory: fakeConnection,
        relayDiscovery: FakeRelayDiscovery(const []),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Nearby relays'), findsOneWidget);
    expect(find.textContaining('No laptop found'), findsOneWidget);
    expect(find.text('Pair manually'), findsOneWidget);
  });

  testWidgets('opens settings and persists notification toggles', (
    tester,
  ) async {
    final settingsStorage = MemoryAppSettingsStorage();

    await tester.pumpWidget(
      VidyutApp(
        appSettingsRepository: AppSettingsRepository(settingsStorage),
        lastActivityRepository: LastActivityRepository(
          MemoryLastActivityStorage(),
        ),
        foregroundServiceClient: FakeForegroundServiceClient(),
        pairingRepository: PairingRepository(MemoryPairingStorage()),
        relayConnectionFactory: fakeConnection,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Notify when laptop payloads arrive'), findsOneWidget);
    expect(find.text('Sync with laptop'), findsOneWidget);

    await tester.tap(
      find.widgetWithText(SwitchListTile, 'Notify when laptop payloads arrive'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, 'Sync with laptop'));
    await tester.pumpAndSettle();

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(
      await AppSettingsRepository(settingsStorage).load(),
      const AppSettings(
        showReceiveNotifications: false,
        showPersistentSendNotification: false,
      ),
    );
  });

  testWidgets('forget this laptop unpairs only after confirmation', (
    tester,
  ) async {
    final pairingStorage = MemoryPairingStorage();
    await PairingRepository(pairingStorage).save(
      const PairingCode(host: '192.168.1.30', port: 17321, secret: 'secret'),
    );

    await tester.pumpWidget(
      VidyutApp(
        appSettingsRepository: AppSettingsRepository(
          MemoryAppSettingsStorage(),
        ),
        lastActivityRepository: LastActivityRepository(
          MemoryLastActivityStorage(),
        ),
        foregroundServiceClient: FakeForegroundServiceClient(),
        pairingRepository: PairingRepository(pairingStorage),
        relayConnectionFactory: fakeConnection,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Searching'), findsOneWidget);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('Forget this laptop'), 200);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forget this laptop'));
    await tester.pumpAndSettle();

    // Dialog is up; cancelling leaves the pairing intact.
    expect(find.text('Forget this laptop?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await PairingRepository(pairingStorage).load(), isNotNull);

    // Confirming deletes the pairing and returns home unpaired.
    await tester.tap(find.text('Forget this laptop'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forget'));
    await tester.pumpAndSettle();

    expect(await PairingRepository(pairingStorage).load(), isNull);
    expect(find.text('Unpaired'), findsOneWidget);
  });
}

RelayConnection fakeConnection(PairingCode pairing) {
  return RelayConnection(
    pairing: pairing,
    deviceId: 'phone',
    transport: _QuietRelayTransport(),
  );
}

class _QuietRelayTransport implements RelayTransport {
  final _messages = StreamController<Object?>();

  @override
  Stream<Object?> get messages => _messages.stream;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  void send(Map<String, Object?> message) {}

  @override
  Future<void> close() => _messages.close();
}

class FakeRelayDiscovery implements RelayDiscovery {
  FakeRelayDiscovery(this.relays);

  final List<DiscoveredRelay> relays;

  @override
  Future<List<DiscoveredRelay>> discover({
    Duration timeout = const Duration(seconds: 3),
  }) async => relays;
}

class FakeForegroundServiceClient implements ForegroundServiceClient {
  @override
  Future<void> initialize() async {}

  @override
  Future<bool> get isRunning async => false;

  @override
  Future<void> requestPermissions() async {}

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> update() async {}

  @override
  void addTaskDataCallback(TaskDataCallback callback) {}

  @override
  void removeTaskDataCallback(TaskDataCallback callback) {}

  @override
  Future<void> sendToTask(Object data) async {}
}
