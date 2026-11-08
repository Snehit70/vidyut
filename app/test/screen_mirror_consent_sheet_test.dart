import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/design/theme.dart';
import 'package:vidyut/src/mirror/screen_mirror_consent_sheet.dart';

void main() {
  // The app theme gives FilledButton a full-width minimum size. In a Row that
  // left Continue with no width, so the sheet showed only "Not now". These
  // tests render the sheet under the real theme so that cannot come back.
  Future<Future<bool>> openSheet(WidgetTester tester) async {
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildVidyutTheme(),
        home: Builder(
          builder: (context) {
            captured = context;
            return const Scaffold();
          },
        ),
      ),
    );
    final result = showScreenMirrorConsent(captured);
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('Continue is visible and resolves true', (tester) async {
    final result = await openSheet(tester);

    expect(tester.takeException(), isNull);
    final continueButton = find.widgetWithText(FilledButton, 'Continue');
    expect(continueButton, findsOneWidget);
    expect(tester.getSize(continueButton).width, greaterThan(100));

    await tester.tap(continueButton);
    await tester.pumpAndSettle();
    expect(await result, isTrue);
  });

  testWidgets('Not now resolves false', (tester) async {
    final result = await openSheet(tester);

    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(await result, isFalse);
  });
}
