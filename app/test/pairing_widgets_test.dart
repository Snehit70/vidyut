import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vidyut/src/design/theme.dart';
import 'package:vidyut/src/pairing/pairing_widgets.dart';

void main() {
  testWidgets('puts host required on the host field', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildVidyutTheme(),
        home: Scaffold(
          body: ManualPairingForm(
            hostController: TextEditingController(),
            portController: TextEditingController(),
            secretController: TextEditingController(),
            error: 'Host is required.',
            onScanQr: () {},
            onPair: () {},
          ),
        ),
      ),
    );

    final host = tester.widget<TextField>(find.byType(TextField).at(0));
    expect(host.decoration?.errorText, 'Host is required.');
    expect(find.byIcon(Icons.error_outline), findsNothing);
  });

  testWidgets('keeps non-field pairing errors in the banner', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildVidyutTheme(),
        home: Scaffold(
          body: ManualPairingForm(
            hostController: TextEditingController(),
            portController: TextEditingController(),
            secretController: TextEditingController(),
            error: 'QR code is not a valid Vidyut pairing code.',
            onScanQr: () {},
            onPair: () {},
          ),
        ),
      ),
    );

    expect(
      find.text('QR code is not a valid Vidyut pairing code.'),
      findsOneWidget,
    );
    final host = tester.widget<TextField>(find.byType(TextField).at(0));
    expect(host.decoration?.errorText, isNull);
  });
}
