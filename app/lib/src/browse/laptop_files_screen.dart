import 'dart:async';

import 'package:flutter/material.dart';

import '../shared/format.dart';
import 'laptop_file_browser.dart';

/// Browses the laptop's shared folders and pulls files or whole folders to
/// the phone (ADR 0026). The screen owns [files] and closes it when it goes.
class LaptopFilesScreen extends StatefulWidget {
  const LaptopFilesScreen({super.key, required this.files});

  final LaptopFiles files;

  @override
  State<LaptopFilesScreen> createState() => _LaptopFilesScreenState();
}

class _LaptopFilesScreenState extends State<LaptopFilesScreen> {
  BrowseRoot? _root;
  List<String> _path = const [];
  List<BrowseRoot>? _roots;
  BrowseListing? _listing;
  BrowseFailure? _failure;
  bool _loading = true;
  bool _pulling = false;
  final _selected = <String>{};

  // A slow listing must not land after the user has moved on.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(widget.files.close());
    super.dispose();
  }

  String get _pathString => _path.join('/');

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _failure = null;
      _selected.clear();
    });
    try {
      final root = _root;
      if (root == null) {
        final roots = await widget.files.roots();
        if (!mounted || generation != _generation) return;
        setState(() => _roots = roots);
      } else {
        final listing = await widget.files.list(root.id, _pathString);
        if (!mounted || generation != _generation) return;
        setState(() => _listing = listing);
      }
    } on BrowseFailure catch (failure) {
      if (!mounted || generation != _generation) return;
      setState(() => _failure = failure);
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  void _openRoot(BrowseRoot root) {
    _root = root;
    _path = const [];
    _listing = null;
    unawaited(_load());
  }

  void _openFolder(String name) {
    _path = [..._path, name];
    _listing = null;
    unawaited(_load());
  }

  /// Goes to [depth] folders below the root; -1 is the list of roots.
  void _goTo(int depth) {
    if (depth < 0) {
      _root = null;
      _path = const [];
    } else {
      _path = _path.sublist(0, depth);
    }
    _listing = null;
    unawaited(_load());
  }

  void _goUp() => _goTo(_path.length - 1);

  Future<void> _pull(List<String> names) async {
    final root = _root;
    if (root == null || _pulling) return;
    final paths = names.isEmpty
        ? [_pathString]
        : [
            for (final name in names) [..._path, name].join('/'),
          ];
    setState(() => _pulling = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final queued = await widget.files.pull(root.id, paths);
      if (!mounted) return;
      setState(_selected.clear);
      final files = queued.files == 1 ? '1 file' : '${queued.files} files';
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Downloading $files (${formatBytes(queued.bytes)}). '
            'Track them in Files.',
          ),
        ),
      );
    } on BrowseFailure catch (failure) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(failure.message)));
      }
    } finally {
      if (mounted) setState(() => _pulling = false);
    }
  }

  void _toggle(String name) {
    setState(() {
      if (!_selected.remove(name)) _selected.add(name);
    });
  }

  @override
  Widget build(BuildContext context) {
    final inRoot = _root != null;
    return PopScope(
      canPop: !inRoot && _selected.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selected.isNotEmpty) {
          setState(_selected.clear);
        } else {
          _goUp();
        }
      },
      child: Scaffold(
        appBar: _buildAppBar(),
        bottomNavigationBar: _selected.isEmpty ? null : _buildSelectionBar(),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (inRoot) _buildBreadcrumb(),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: RefreshIndicator(onRefresh: _load, child: _buildBody()),
            ),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    if (_selected.isNotEmpty) {
      return AppBar(
        leading: IconButton(
          tooltip: 'Cancel selection',
          onPressed: () => setState(_selected.clear),
          icon: const Icon(Icons.close),
        ),
        title: Text('${_selected.length} selected'),
      );
    }
    final root = _root;
    final listing = _listing;
    return AppBar(
      title: Text(
        root == null ? 'Laptop' : (_path.isEmpty ? root.name : _path.last),
      ),
      actions: [
        if (root != null && listing != null && listing.entries.isNotEmpty)
          IconButton(
            tooltip: 'Download this folder',
            onPressed: _pulling ? null : () => _pull(const []),
            icon: const Icon(Icons.download_outlined),
          ),
      ],
    );
  }

  Widget _buildSelectionBar() => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: FilledButton.icon(
        onPressed: _pulling ? null : () => _pull(_selected.toList()),
        icon: const Icon(Icons.download_outlined),
        label: Text('Download (${_selected.length})'),
      ),
    ),
  );

  Widget _buildBreadcrumb() {
    final scheme = Theme.of(context).colorScheme;
    final crumbs = ['Laptop', _root!.name, ..._path];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Row(
        children: [
          for (var index = 0; index < crumbs.length; index++) ...[
            if (index > 0)
              Icon(
                Icons.chevron_right,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
            TextButton(
              onPressed: index == crumbs.length - 1
                  ? null
                  : () => _goTo(index - 1),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 40),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: Text(crumbs[index]),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBody() {
    final failure = _failure;
    if (failure != null) {
      return _Message(
        icon: Icons.error_outline,
        title: "Couldn't open the laptop",
        body: failure.message,
        isError: true,
        action: OutlinedButton(onPressed: _load, child: const Text('Retry')),
      );
    }
    if (_root == null) {
      final roots = _roots;
      if (roots == null) return const _Scrollable();
      if (roots.isEmpty) {
        return const _Message(
          icon: Icons.folder_off_outlined,
          title: 'No shared folders',
          body:
              "The laptop shares none of its folders right now. Add them to "
              'sharedFolders in its Vidyut config.',
        );
      }
      return ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: roots.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final root = roots[index];
          return _EntryRow(
            icon: Icons.folder_shared_outlined,
            title: root.name,
            subtitle: 'Shared folder',
            onTap: () => _openRoot(root),
            trailing: const Icon(Icons.chevron_right),
          );
        },
      );
    }
    final listing = _listing;
    if (listing == null) return const _Scrollable();
    if (listing.entries.isEmpty) {
      return const _Message(
        icon: Icons.folder_open_outlined,
        title: 'Nothing here',
        body: "This folder is empty. Hidden files aren't shared.",
      );
    }
    final localizations = MaterialLocalizations.of(context);
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: listing.entries.length + (listing.truncated ? 1 : 0),
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index == listing.entries.length) {
          return Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              'Only the first ${listing.entries.length} items are shown.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          );
        }
        final entry = listing.entries[index];
        final date = localizations.formatMediumDate(entry.modified);
        final selecting = _selected.isNotEmpty;
        final selected = _selected.contains(entry.name);
        return _EntryRow(
          icon: entry.isFolder ? Icons.folder_outlined : _fileIcon(entry.name),
          title: entry.name,
          subtitle: entry.isFolder
              ? 'Folder · $date'
              : '${formatBytes(entry.size ?? 0)} · $date',
          selected: selected,
          selecting: selecting,
          onTap: selecting
              ? () => _toggle(entry.name)
              : entry.isFolder
              ? () => _openFolder(entry.name)
              : () => _pull([entry.name]),
          onLongPress: () => _toggle(entry.name),
          trailing: selecting
              ? null
              : IconButton(
                  tooltip: 'Download ${entry.name}',
                  onPressed: _pulling ? null : () => _pull([entry.name]),
                  icon: const Icon(Icons.download_outlined),
                ),
        );
      },
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.onLongPress,
    this.trailing,
    this.selected = false,
    this.selecting = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;
  final bool selected;
  final bool selecting;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(16);
    return Material(
      color: selected ? scheme.secondaryContainer : scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 1.6 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        customBorder: RoundedRectangleBorder(borderRadius: radius),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 4, 10),
          child: Row(
            children: [
              if (selecting)
                Checkbox(value: selected, onChanged: (_) => onTap())
              else
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: Icon(icon, color: scheme.primary, size: 26),
                  ),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    this.isError = false,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final bool isError;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Scrollable so pull-to-refresh works on an empty or failed screen.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 48,
                    color: isError ? scheme.error : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    body,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (action != null) ...[const SizedBox(height: 14), action!],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An empty scrollable, so pull-to-refresh is there while loading.
class _Scrollable extends StatelessWidget {
  const _Scrollable();

  @override
  Widget build(BuildContext context) =>
      ListView(physics: const AlwaysScrollableScrollPhysics());
}

IconData _fileIcon(String name) {
  final dot = name.lastIndexOf('.');
  final extension = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return switch (extension) {
    'pdf' => Icons.picture_as_pdf_outlined,
    'png' ||
    'jpg' ||
    'jpeg' ||
    'gif' ||
    'webp' ||
    'heic' ||
    'svg' => Icons.image_outlined,
    'mp4' || 'mkv' || 'mov' || 'webm' || 'avi' => Icons.movie_outlined,
    'mp3' ||
    'flac' ||
    'wav' ||
    'ogg' ||
    'm4a' ||
    'opus' => Icons.audiotrack_outlined,
    'zip' ||
    'tar' ||
    'gz' ||
    'xz' ||
    'zst' ||
    '7z' ||
    'rar' => Icons.folder_zip_outlined,
    'apk' => Icons.android_outlined,
    'csv' || 'xlsx' || 'ods' => Icons.table_chart_outlined,
    _ => Icons.insert_drive_file_outlined,
  };
}
