import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/browse/laptop_file_browser.dart';
import 'package:vidyut/src/browse/laptop_files_screen.dart';

void main() {
  Future<_FakeLaptopFiles> open(
    WidgetTester tester, {
    _FakeLaptopFiles? files,
  }) async {
    final fake = files ?? _FakeLaptopFiles();
    await tester.pumpWidget(MaterialApp(home: LaptopFilesScreen(files: fake)));
    await tester.pumpAndSettle();
    return fake;
  }

  testWidgets('walks from a shared folder into a subfolder and back', (
    tester,
  ) async {
    final files = await open(tester);

    expect(find.text('Downloads'), findsOneWidget);
    await tester.tap(find.text('Downloads'));
    await tester.pumpAndSettle();
    expect(find.text('Trip'), findsOneWidget);
    expect(find.text('report.pdf'), findsOneWidget);

    await tester.tap(find.text('Trip'));
    await tester.pumpAndSettle();
    expect(files.listed.last, ('0', 'Trip'));
    expect(find.text('a.jpg'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Downloads'));
    await tester.pumpAndSettle();
    expect(files.listed.last, ('0', ''));
    expect(find.text('report.pdf'), findsOneWidget);
  });

  testWidgets('pulls a whole folder from its row and says what is coming', (
    tester,
  ) async {
    final files = await open(tester);
    await tester.tap(find.text('Downloads'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Download Trip'));
    await tester.pumpAndSettle();

    expect(files.pulled.single.$1, '0');
    expect(files.pulled.single.$2, ['Trip']);
    expect(
      find.text('Downloading 12 files (4.0 KB). Track them in Files.'),
      findsOneWidget,
    );
  });

  testWidgets('pulls the open folder and a multi-selection', (tester) async {
    final files = await open(tester);
    await tester.tap(find.text('Downloads'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Trip'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Download this folder'));
    await tester.pumpAndSettle();
    expect(files.pulled.last.$2, ['Trip']);

    await tester.longPress(find.text('a.jpg'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Day 1'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tap(find.text('Download (2)'));
    await tester.pumpAndSettle();

    expect(files.pulled.last.$1, '0');
    expect(files.pulled.last.$2, unorderedEquals(['Trip/a.jpg', 'Trip/Day 1']));
    expect(find.text('2 selected'), findsNothing);
  });

  testWidgets('tapping a file previews it and Download pulls it', (
    tester,
  ) async {
    final files = await open(tester);
    await tester.tap(find.text('Downloads'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Trip'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('a.jpg'));
    await tester.pumpAndSettle();

    expect(files.pulled, isEmpty, reason: 'a tap previews, it does not pull');
    expect(files.thumbRequests, contains(('0', 'Trip/a.jpg', true)));
    expect(find.byType(Image), findsWidgets);
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(files.pulled.single.$1, '0');
    expect(files.pulled.single.$2, ['Trip/a.jpg']);
  });

  testWidgets('asks for pictures only for files that can have one', (
    tester,
  ) async {
    final files = await open(tester);
    await tester.tap(find.text('Downloads'));
    await tester.pumpAndSettle();

    final asked = files.thumbRequests.map((request) => request.$2);
    expect(asked, ['report.pdf']);
  });

  testWidgets('filters the open folder as you type', (tester) async {
    await open(tester);
    await tester.tap(find.text('Downloads'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'rep');
    await tester.pumpAndSettle();

    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('Trip'), findsNothing);
    expect(find.text('Search all shared folders'), findsOneWidget);
  });

  testWidgets('searches every shared folder and opens a result folder', (
    tester,
  ) async {
    final files = await open(tester);
    await tester.tap(find.text('Downloads'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'beach');
    await tester.pumpAndSettle();
    expect(find.text('Nothing in this folder has that name.'), findsOneWidget);
    await tester.tap(find.text('Search all shared folders'));
    await tester.pumpAndSettle();

    expect(files.searched.single, 'beach');
    expect(find.text('1 result for "beach"'), findsOneWidget);
    expect(find.text('beach.jpg'), findsOneWidget);
    expect(find.textContaining('Downloads › Trip'), findsOneWidget);

    await tester.tap(find.byTooltip('Download beach.jpg'));
    await tester.pumpAndSettle();
    expect(files.pulled.last.$1, '0');
    expect(files.pulled.last.$2, ['Trip/beach.jpg']);
  });

  testWidgets('shows a refusal and retries', (tester) async {
    final files = _FakeLaptopFiles()
      ..failure = const BrowseFailure(
        'browse_unavailable',
        'The laptop is not sharing folders.',
      );
    await open(tester, files: files);

    expect(find.text('The laptop is not sharing folders.'), findsOneWidget);
    files.failure = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Downloads'), findsOneWidget);
  });

  testWidgets('closes the browser when the screen goes', (tester) async {
    final files = await open(tester);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));

    expect(files.closed, isTrue);
  });
}

class _FakeLaptopFiles implements LaptopFiles {
  BrowseFailure? failure;
  final listed = <(String, String)>[];
  final pulled = <(String, List<String>)>[];
  bool closed = false;
  final thumbRequests = <(String, String, bool)>[];
  final searched = <String>[];

  final _folders = <String, List<BrowseEntry>>{
    '': [
      BrowseEntry(name: 'Trip', isFolder: true, modified: DateTime(2026, 10)),
      BrowseEntry(
        name: 'report.pdf',
        isFolder: false,
        size: 2048,
        modified: DateTime(2026, 10, 2),
      ),
    ],
    'Trip': [
      BrowseEntry(name: 'Day 1', isFolder: true, modified: DateTime(2026, 10)),
      BrowseEntry(
        name: 'a.jpg',
        isFolder: false,
        size: 1024,
        modified: DateTime(2026, 10, 3),
      ),
    ],
  };

  @override
  Future<List<BrowseRoot>> roots() async {
    if (failure case final failure?) throw failure;
    return const [BrowseRoot(id: '0', name: 'Downloads')];
  }

  @override
  Future<BrowseListing> list(String root, String path) async {
    if (failure case final failure?) throw failure;
    listed.add((root, path));
    return BrowseListing(entries: _folders[path] ?? const [], truncated: false);
  }

  @override
  Future<BrowseThumbnail?> thumbnail(
    String root,
    String path, {
    bool large = false,
  }) async {
    thumbRequests.add((root, path, large));
    return BrowseThumbnail(Uint8List.fromList(_onePixelPng));
  }

  @override
  Future<BrowseSearchResult> search(
    String query, {
    String? root,
    String? path,
  }) async {
    searched.add(query);
    return BrowseSearchResult(
      truncated: false,
      matches: [
        BrowseMatch(
          name: 'beach.jpg',
          isFolder: false,
          size: 10,
          modified: DateTime(2026, 10, 4),
          root: '0',
          path: 'Trip/beach.jpg',
        ),
      ],
    );
  }

  @override
  Future<BrowseQueued> pull(String root, List<String> paths) async {
    pulled.add((root, paths));
    return const BrowseQueued(files: 12, bytes: 4096);
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

final _onePixelPng = base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);
