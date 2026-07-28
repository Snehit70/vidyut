import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:vidyut/src/debug/debug_log.dart';
import 'package:vidyut/src/debug/debug_log_screen.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('keeps entries in order and evicts the oldest past capacity', () {
    final log = DebugLog(capacity: 3);

    for (var i = 1; i <= 5; i++) {
      log.add('test', 'event $i');
    }

    expect(log.entries.map((entry) => entry.message), [
      'event 3',
      'event 4',
      'event 5',
    ]);
  });

  test('notifies listeners on add and clear', () {
    final log = DebugLog();
    var notifications = 0;
    log.addListener(() => notifications++);

    log.add('test', 'one');
    log.clear();
    log.clear(); // already empty: no notification

    expect(notifications, 2);
    expect(log.entries, isEmpty);
  });

  testWidgets('debug log screen renders entries newest first and clears', (
    tester,
  ) async {
    final log = DebugLog();
    log.add('connection', 'Status: connected');
    log.add('receive', 'text (1.2 KB) from laptop', isError: false);
    log.add('service', 'Relay socket error: refused', isError: true);

    await tester.pumpWidget(MaterialApp(home: DebugLogScreen(log: log)));

    expect(find.text('Status: connected'), findsOneWidget);
    expect(find.text('Relay socket error: refused'), findsOneWidget);
    final firstTileTop = tester.getTopLeft(
      find.text('Relay socket error: refused'),
    );
    final lastTileTop = tester.getTopLeft(find.text('Status: connected'));
    expect(firstTileTop.dy, lessThan(lastTileTop.dy));

    await tester.tap(find.byTooltip('Clear log'));
    await tester.pump();
    expect(find.text('Clear diagnostics?'), findsOneWidget);
    await tester.tap(find.text('Clear diagnostics'));
    await tester.pumpAndSettle();

    expect(find.text('No debug events yet.'), findsOneWidget);

    log.add('send', 'Published to relay.');
    await tester.pump();

    expect(find.text('Published to relay.'), findsOneWidget);
  });

  test('persists entries and exports a support report', () async {
    final first = DebugLog();
    first.add('connection', 'Status: connected');
    await Future<void>.delayed(Duration.zero);

    final restored = DebugLog();
    await restored.load();

    expect(restored.entries.single.message, 'Status: connected');
    expect(restored.exportText(), contains('[connection] Status: connected'));
  });
}
