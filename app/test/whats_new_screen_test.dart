import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/design/theme.dart';
import 'package:vidyut/src/settings/whats_new_screen.dart';

void main() {
  // The shape the release workflow actually publishes, via
  // `generate_release_notes: true`.
  const generated = '''
## What's Changed
* feat(home): group telemetry as two-up over three-up by @snehit in https://github.com/Snehit70/vidyut/pull/63
* fix(shell): keep the brand mark in the notification icon by @snehit in https://github.com/Snehit70/vidyut/pull/61

**Full Changelog**: https://github.com/Snehit70/vidyut/compare/v1.12.0...v1.13.0
''';

  test('strips headings, bullets, and pull links from generated notes', () {
    expect(readReleaseNotes(generated), [
      'feat(home): group telemetry as two-up over three-up by @snehit',
      'fix(shell): keep the brand mark in the notification icon by @snehit',
    ]);
  });

  test('keeps a hand-written line that merely mentions a url', () {
    // The " in http" tail is only dropped when a "by @" attribution confirms the
    // line is machine-generated, so a real summary survives.
    const handWritten = '* Sync now works in http://192.168.1.5:17321 on the LAN';
    expect(readReleaseNotes(handWritten), [
      'Sync now works in http://192.168.1.5:17321 on the LAN',
    ]);
  });

  test('treats blank input and decoration-only input as no entries', () {
    expect(readReleaseNotes(''), isEmpty);
    expect(readReleaseNotes('   \n\n'), isEmpty);
    expect(readReleaseNotes('## What\'s Changed\n\n**Full Changelog**: x'), isEmpty);
  });

  testWidgets('lists the notes under the release they belong to', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildVidyutTheme(),
        home: const WhatsNewScreen(version: '1.13.0', releaseNotes: generated),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text("What's new"), findsOneWidget);
    expect(find.text('Vidyut 1.13.0'), findsOneWidget);
    expect(
      find.text('feat(home): group telemetry as two-up over three-up by @snehit'),
      findsOneWidget,
    );
    // The link and heading are decoration, not content.
    expect(find.textContaining('Full Changelog'), findsNothing);
    expect(find.textContaining("What's Changed"), findsNothing);
  });

  testWidgets('says so when a release shipped without notes', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildVidyutTheme(),
        home: const WhatsNewScreen(version: '1.13.0', releaseNotes: ''),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No release notes yet'), findsOneWidget);
    expect(find.textContaining('without release notes'), findsOneWidget);
  });
}
