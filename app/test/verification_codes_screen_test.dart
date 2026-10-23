import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/design/theme.dart';
import 'package:vidyut/src/settings/app_settings.dart';
import 'package:vidyut/src/settings/verification_codes_screen.dart';
import 'package:vidyut_clipboard/vidyut_clipboard.dart';

class _FakeNotifications implements PostedNotifications {
  _FakeNotifications({required this.access});

  bool access;
  int opened = 0;

  @override
  Stream<PostedNotification> get notifications => const Stream.empty();

  @override
  Future<bool> hasAccess() async => access;

  @override
  Future<void> openAccessSettings() async => opened++;
}

Future<List<AppSettings>> _pump(
  WidgetTester tester,
  _FakeNotifications notifications, {
  AppSettings settings = const AppSettings(),
}) async {
  final saved = <AppSettings>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: buildVidyutTheme(),
      home: VerificationCodesScreen(
        settings: settings,
        onChanged: (next) async => saved.add(next),
        notifications: notifications,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return saved;
}

void main() {
  testWidgets('offers the system switch while access is off', (tester) async {
    final notifications = _FakeNotifications(access: false);
    final saved = await _pump(tester, notifications);

    expect(find.text('Notification access is off.'), findsOneWidget);
    await tester.tap(find.text('Allow'));
    expect(notifications.opened, 1);

    await tester.tap(find.text('Send codes to the laptop'));
    await tester.pumpAndSettle();
    expect(saved.single.forwardVerificationCodes, isTrue);
  });

  testWidgets('resaves when access arrives so the service starts listening', (
    tester,
  ) async {
    final notifications = _FakeNotifications(access: false);
    final saved = await _pump(
      tester,
      notifications,
      settings: const AppSettings(forwardVerificationCodes: true),
    );
    expect(saved, isEmpty);

    notifications.access = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.text('Notification access allowed.'), findsOneWidget);
    expect(find.text('Allow'), findsNothing);
    expect(saved.single.forwardVerificationCodes, isTrue);
  });
}
