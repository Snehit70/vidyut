import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../shared/file_kind.dart';
import 'laptop_file_browser.dart';

/// Fetches pictures of laptop files for the browser (ADR 0027), a few at a
/// time, and keeps the ones it has in memory. A row asks as it scrolls into
/// view and says when it is gone, so a fast scroll does not queue a request
/// for every row it passed.
class LaptopThumbnailLoader {
  LaptopThumbnailLoader(
    this._files, {
    this.concurrent = 4,
    this.memoryBudgetBytes = 16 * 1024 * 1024,
  });

  final LaptopFiles _files;
  final int concurrent;
  final int memoryBudgetBytes;

  // Insertion order is recency: a hit moves its entry to the end.
  final _have = <String, Uint8List?>{};
  var _haveBytes = 0;
  final _waiting = <_Want>[];
  var _running = 0;

  /// The picture if it is already here. A null entry means the laptop has none.
  bool has(String root, String path, {bool large = false}) =>
      _have.containsKey(_key(root, path, large));

  Uint8List? peek(String root, String path, {bool large = false}) {
    final key = _key(root, path, large);
    if (!_have.containsKey(key)) return null;
    final bytes = _have.remove(key);
    _have[key] = bytes;
    return bytes;
  }

  /// Resolves with the picture, or null when there is none or [wanted] turned
  /// false before its turn came (nothing is remembered then).
  Future<Uint8List?> load(
    String root,
    String path, {
    bool large = false,
    bool Function()? wanted,
  }) {
    if (has(root, path, large: large)) {
      return Future.value(peek(root, path, large: large));
    }
    final want = _Want(root, path, large, wanted);
    _waiting.add(want);
    _pump();
    return want.done.future;
  }

  void _pump() {
    while (_running < concurrent && _waiting.isNotEmpty) {
      // Newest first: what is on screen now beats what was scrolled past.
      final want = _waiting.removeLast();
      if (want.wanted?.call() == false) {
        want.done.complete(null);
        continue;
      }
      _running += 1;
      unawaited(_run(want));
    }
  }

  Future<void> _run(_Want want) async {
    try {
      final thumbnail = await _files.thumbnail(
        want.root,
        want.path,
        large: want.large,
      );
      _remember(_key(want.root, want.path, want.large), thumbnail?.bytes);
      want.done.complete(thumbnail?.bytes);
    } on BrowseFailure {
      // Offline or timed out: show the icon now and ask again next time.
      want.done.complete(null);
    } finally {
      _running -= 1;
      _pump();
    }
  }

  void _remember(String key, Uint8List? bytes) {
    _have[key] = bytes;
    _haveBytes += bytes?.length ?? 0;
    while (_haveBytes > memoryBudgetBytes && _have.length > 1) {
      final oldest = _have.keys.first;
      _haveBytes -= _have.remove(oldest)?.length ?? 0;
    }
  }

  static String _key(String root, String path, bool large) =>
      '${large ? 'L' : 'S'}\u0000$root\u0000$path';
}

class _Want {
  _Want(this.root, this.path, this.large, this.wanted);

  final String root;
  final String path;
  final bool large;
  final bool Function()? wanted;
  final done = Completer<Uint8List?>();
}

/// A square picture of a laptop file, or the icon for its kind while there is
/// none, or when the laptop cannot draw one.
class LaptopThumb extends StatefulWidget {
  const LaptopThumb({
    super.key,
    required this.loader,
    required this.root,
    required this.path,
    required this.name,
    this.size,
    this.radius = 12,
    this.bordered = true,
  });

  final LaptopThumbnailLoader loader;
  final String root;
  final String path;
  final String name;

  /// Side length; null fills the space it is given.
  final double? size;
  final double radius;
  final bool bordered;

  @override
  State<LaptopThumb> createState() => _LaptopThumbState();
}

class _LaptopThumbState extends State<LaptopThumb> {
  Uint8List? _bytes;
  var _gone = false;

  FileKind get _kind => fileKindOf(widget.name);

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(LaptopThumb old) {
    super.didUpdateWidget(old);
    if (old.root != widget.root || old.path != widget.path) {
      _bytes = null;
      _fetch();
    }
  }

  @override
  void dispose() {
    _gone = true;
    super.dispose();
  }

  void _fetch() {
    if (!_kind.hasPicture) return;
    final loader = widget.loader;
    if (loader.has(widget.root, widget.path)) {
      _bytes = loader.peek(widget.root, widget.path);
      return;
    }
    final root = widget.root;
    final path = widget.path;
    unawaited(
      loader
          .load(
            root,
            path,
            wanted: () => !_gone && widget.root == root && widget.path == path,
          )
          .then((bytes) {
            if (_gone || widget.root != root || widget.path != path) return;
            if (bytes != null) setState(() => _bytes = bytes);
          }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bytes = _bytes;
    final radius = BorderRadius.circular(widget.radius);
    final iconSize = (widget.size ?? 72) * 0.5;
    final picture = ClipRRect(
      borderRadius: radius,
      child: bytes == null
          ? Icon(_kind.icon, color: scheme.primary, size: iconSize)
          : Stack(
              fit: StackFit.expand,
              children: [
                Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  excludeFromSemantics: true,
                  errorBuilder: (_, _, _) =>
                      Icon(_kind.icon, color: scheme.primary, size: iconSize),
                ),
                if (_kind == FileKind.video)
                  const Center(
                    child: Icon(
                      Icons.play_circle_fill,
                      color: Colors.white70,
                      size: 28,
                    ),
                  ),
              ],
            ),
    );
    final size = widget.size;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: radius,
        border: widget.bordered
            ? Border.all(color: scheme.outlineVariant)
            : null,
      ),
      child: size == null
          ? SizedBox.expand(child: picture)
          : SizedBox.square(dimension: size, child: picture),
    );
  }
}
