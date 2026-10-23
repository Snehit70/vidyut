import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../shared/file_kind.dart';
import '../shared/format.dart';
import 'laptop_thumbnails.dart';

/// A laptop file at a glance: a bigger picture where the laptop can draw one,
/// the details, and a way to download it (ADR 0027). Nothing is transferred
/// until the user taps Download.
class LaptopFilePreview extends StatefulWidget {
  const LaptopFilePreview({
    super.key,
    required this.loader,
    required this.root,
    required this.path,
    required this.name,
    required this.size,
    required this.modified,
    required this.onDownload,
    this.location,
  });

  final LaptopThumbnailLoader loader;
  final String root;
  final String path;
  final String name;
  final int? size;
  final DateTime modified;

  /// Where the file lives, shown under its name; null leaves it out.
  final String? location;

  /// Starts the download; resolves when the laptop has accepted it.
  final Future<void> Function() onDownload;

  @override
  State<LaptopFilePreview> createState() => _LaptopFilePreviewState();
}

class _LaptopFilePreviewState extends State<LaptopFilePreview> {
  Uint8List? _bytes;
  var _loading = false;
  var _downloading = false;
  var _gone = false;

  FileKind get _kind => fileKindOf(widget.name);

  @override
  void initState() {
    super.initState();
    if (_kind.hasPicture) {
      _loading = true;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _gone = true;
    super.dispose();
  }

  Future<void> _load() async {
    final bytes = await widget.loader.load(
      widget.root,
      widget.path,
      large: true,
      wanted: () => !_gone,
    );
    if (_gone) return;
    setState(() {
      _bytes = bytes;
      _loading = false;
    });
  }

  Future<void> _download() async {
    setState(() => _downloading = true);
    try {
      await widget.onDownload();
    } finally {
      if (!_gone) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final date = MaterialLocalizations.of(
      context,
    ).formatMediumDate(widget.modified);
    final size = widget.size;
    final details = [
      if (size != null) formatBytes(size),
      date,
      if (_kind == FileKind.pdf && _bytes != null) 'First page',
      if (_kind == FileKind.video && _bytes != null) 'Still from the video',
    ].join(' · ');
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: Column(
        children: [
          Expanded(child: _buildPicture(scheme)),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleSmall,
                ),
                const SizedBox(height: 3),
                Text(
                  details,
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (widget.location != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    widget.location!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _downloading ? null : _download,
                  icon: const Icon(Icons.download_outlined),
                  label: Text(_downloading ? 'Asking the laptop…' : 'Download'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPicture(ColorScheme scheme) {
    final bytes = _bytes;
    if (bytes != null) {
      return InteractiveViewer(
        maxScale: 5,
        child: Center(
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _placeholder(scheme),
          ),
        ),
      );
    }
    if (_loading) return const Center(child: CircularProgressIndicator());
    return _placeholder(scheme);
  }

  Widget _placeholder(ColorScheme scheme) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(_kind.icon, size: 72, color: scheme.primary),
        const SizedBox(height: 12),
        Text(
          _kind.hasPicture
              ? 'No preview available'
              : 'No preview for this type',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    ),
  );
}
