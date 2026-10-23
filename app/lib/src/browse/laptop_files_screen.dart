import 'dart:async';

import 'package:flutter/material.dart';

import '../shared/file_kind.dart';
import '../shared/format.dart';
import 'laptop_file_browser.dart';
import 'laptop_file_preview.dart';
import 'laptop_thumbnails.dart';

/// The shortest search the laptop accepts (`minSearchQueryLength` in the wire
/// protocol).
const _minSearchLength = 2;

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
  late final _loader = LaptopThumbnailLoader(widget.files);

  // Null picks by what the folder holds; the toggle overrides it.
  bool? _gridChoice;

  bool _searching = false;
  final _searchField = TextEditingController();
  BrowseSearchResult? _everywhere;
  String _everywhereFor = '';
  bool _searchingAll = false;

  // A slow listing must not land after the user has moved on.
  int _generation = 0;
  int _searchGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _searchField.dispose();
    unawaited(widget.files.close());
    super.dispose();
  }

  String get _query => _searchField.text.trim();

  List<String> get _words => _query.toLowerCase().split(RegExp(r'\s+'));

  bool _matches(String name) {
    if (_query.isEmpty) return true;
    final lower = name.toLowerCase();
    return _words.every(lower.contains);
  }

  bool _useGrid(BrowseListing listing) {
    final choice = _gridChoice;
    if (choice != null) return choice;
    final files = listing.entries.where((entry) => !entry.isFolder).toList();
    final pictures = files
        .where(
          (entry) => switch (fileKindOf(entry.name)) {
            FileKind.image || FileKind.video => true,
            _ => false,
          },
        )
        .length;
    return files.length >= 4 && pictures * 2 >= files.length;
  }

  void _openSearch() => setState(() => _searching = true);

  void _closeSearch() {
    _searchGeneration++;
    setState(() {
      _searching = false;
      _searchField.clear();
      _everywhere = null;
      _searchingAll = false;
    });
  }

  void _onQueryChanged(String _) {
    // Results belong to the words they were found for.
    setState(() {
      if (_query != _everywhereFor) _everywhere = null;
    });
  }

  Future<void> _searchEverywhere() async {
    final query = _query;
    if (query.length < _minSearchLength) return;
    final generation = ++_searchGeneration;
    setState(() {
      _searchingAll = true;
      _everywhere = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await widget.files.search(query);
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _everywhere = result;
        _everywhereFor = query;
      });
    } on BrowseFailure catch (failure) {
      if (mounted && generation == _searchGeneration) {
        messenger.showSnackBar(SnackBar(content: Text(failure.message)));
      }
    } finally {
      if (mounted && generation == _searchGeneration) {
        setState(() => _searchingAll = false);
      }
    }
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
    if (root == null) return;
    await _pullFrom(
      root.id,
      names.isEmpty
          ? [_pathString]
          : [
              for (final name in names) [..._path, name].join('/'),
            ],
    );
  }

  Future<void> _pullFrom(String rootId, List<String> paths) async {
    if (_pulling) return;
    setState(() => _pulling = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final queued = await widget.files.pull(rootId, paths);
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

  void _preview({
    required String root,
    required String path,
    required BrowseEntry entry,
    String? location,
  }) {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => LaptopFilePreview(
            loader: _loader,
            root: root,
            path: path,
            name: entry.name,
            size: entry.size,
            modified: entry.modified,
            location: location,
            onDownload: () => _pullFrom(root, [path]),
          ),
        ),
      ),
    );
  }

  void _onEntryTap(BrowseEntry entry) {
    if (_selected.isNotEmpty) return _toggle(entry.name);
    if (entry.isFolder) return _openFolder(entry.name);
    _preview(
      root: _root!.id,
      path: [..._path, entry.name].join('/'),
      entry: entry,
    );
  }

  String _rootName(String id) {
    for (final root in _roots ?? const <BrowseRoot>[]) {
      if (root.id == id) return root.name;
    }
    return 'Laptop';
  }

  /// Where a search hit lives, as "Documents › Taxes".
  String _location(BrowseMatch match) {
    final parent = match.parent;
    return [
      _rootName(match.root),
      if (parent.isNotEmpty) ...parent.split('/'),
    ].join(' › ');
  }

  void _onMatchTap(BrowseMatch match) {
    if (!match.isFolder) {
      return _preview(
        root: match.root,
        path: match.path,
        entry: match,
        location: _location(match),
      );
    }
    BrowseRoot? root;
    for (final candidate in _roots ?? const <BrowseRoot>[]) {
      if (candidate.id == match.root) root = candidate;
    }
    if (root == null) return;
    _closeSearch();
    _root = root;
    _path = match.path.split('/');
    _listing = null;
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final inRoot = _root != null;
    return PopScope(
      canPop: !inRoot && _selected.isEmpty && !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selected.isNotEmpty) {
          setState(_selected.clear);
        } else if (_searching) {
          _closeSearch();
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
            if (inRoot && !_searching) _buildBreadcrumb(),
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
    if (_searching) {
      return AppBar(
        leading: IconButton(
          tooltip: 'Close search',
          onPressed: _closeSearch,
          icon: const Icon(Icons.arrow_back),
        ),
        title: TextField(
          controller: _searchField,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: _onQueryChanged,
          onSubmitted: (_) => unawaited(_searchEverywhere()),
          decoration: InputDecoration(
            hintText: _root == null ? 'Search shared folders' : 'Search names',
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
          ),
        ),
        actions: [
          if (_query.isNotEmpty)
            IconButton(
              tooltip: 'Clear search',
              onPressed: () => setState(() {
                _searchField.clear();
                _everywhere = null;
              }),
              icon: const Icon(Icons.close),
            ),
        ],
      );
    }
    final root = _root;
    final listing = _listing;
    final hasEntries =
        root != null && listing != null && listing.entries.isNotEmpty;
    return AppBar(
      title: Text(
        root == null ? 'Laptop' : (_path.isEmpty ? root.name : _path.last),
      ),
      actions: [
        IconButton(
          tooltip: 'Search',
          onPressed: _openSearch,
          icon: const Icon(Icons.search),
        ),
        if (hasEntries)
          IconButton(
            tooltip: _useGrid(listing) ? 'Show as list' : 'Show as grid',
            onPressed: () => setState(() => _gridChoice = !_useGrid(listing)),
            icon: Icon(
              _useGrid(listing)
                  ? Icons.view_list_outlined
                  : Icons.grid_view_outlined,
            ),
          ),
        if (hasEntries)
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

  static const _listPadding = EdgeInsets.fromLTRB(16, 8, 16, 24);

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
    final everywhere = _everywhere;
    if (_searching && everywhere != null) return _buildEverywhere(everywhere);
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
      final shown = roots.where((root) => _matches(root.name)).toList();
      return CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          ..._searchHeader(hasLocalMatches: shown.isNotEmpty),
          SliverPadding(
            padding: _listPadding,
            sliver: SliverList.separated(
              itemCount: shown.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final root = shown[index];
                return _EntryRow(
                  leading: const _IconChip(Icons.folder_shared_outlined),
                  title: root.name,
                  subtitle: 'Shared folder',
                  onTap: () {
                    if (_searching) _closeSearch();
                    _openRoot(root);
                  },
                  trailing: const Icon(Icons.chevron_right),
                );
              },
            ),
          ),
        ],
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
    final entries = listing.entries
        .where((entry) => _matches(entry.name))
        .toList();
    final localizations = MaterialLocalizations.of(context);
    final grid = _useGrid(listing);
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        ..._searchHeader(hasLocalMatches: entries.isNotEmpty),
        if (grid)
          SliverPadding(
            padding: _listPadding,
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 140,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 0.82,
              ),
              itemCount: entries.length,
              itemBuilder: (context, index) => _entryTile(entries[index]),
            ),
          )
        else
          SliverPadding(
            padding: _listPadding,
            sliver: SliverList.separated(
              itemCount: entries.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) =>
                  _entryRow(entries[index], localizations),
            ),
          ),
        if (listing.truncated)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: Text(
                'Only the first ${listing.entries.length} items are shown.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// What sits above the list while searching: the offer to look in every
  /// shared folder, and a note when the open folder has no match.
  List<Widget> _searchHeader({required bool hasLocalMatches}) {
    if (!_searching || _query.isEmpty) return const [];
    final scheme = Theme.of(context).colorScheme;
    final canSearchAll = _query.length >= _minSearchLength;
    return [
      if (canSearchAll)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _EntryRow(
              leading: _searchingAll
                  ? const SizedBox(
                      width: 48,
                      height: 48,
                      child: Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        ),
                      ),
                    )
                  : const _IconChip(Icons.travel_explore_outlined),
              title: 'Search all shared folders',
              subtitle: 'For "$_query"',
              onTap: _searchingAll ? () {} : () => _searchEverywhere(),
            ),
          ),
        ),
      if (!hasLocalMatches)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Text(
              _root == null
                  ? 'No shared folder has that name.'
                  : 'Nothing in this folder has that name.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ),
    ];
  }

  Widget _buildEverywhere(BrowseSearchResult result) {
    final scheme = Theme.of(context).colorScheme;
    final localizations = MaterialLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final count = result.matches.length;
    final headline = count == 0
        ? 'Nothing found for "$_everywhereFor"'
        : '${result.truncated ? 'First ' : ''}'
              '$count ${count == 1 ? 'result' : 'results'} '
              'for "$_everywhereFor"';
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Text(
              headline,
              style: textTheme.labelLarge?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        SliverPadding(
          padding: _listPadding,
          sliver: SliverList.separated(
            itemCount: count,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final match = result.matches[index];
              final date = localizations.formatMediumDate(match.modified);
              return _EntryRow(
                leading: _leadingFor(match, root: match.root, path: match.path),
                title: match.name,
                subtitle:
                    '${match.isFolder ? 'Folder' : formatBytes(match.size ?? 0)}'
                    ' · $date\n${_location(match)}',
                onTap: () => _onMatchTap(match),
                trailing: IconButton(
                  tooltip: 'Download ${match.name}',
                  onPressed: _pulling
                      ? null
                      : () => _pullFrom(match.root, [match.path]),
                  icon: const Icon(Icons.download_outlined),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _leadingFor(
    BrowseEntry entry, {
    required String root,
    required String path,
  }) => entry.isFolder
      ? const _IconChip(Icons.folder_outlined)
      : LaptopThumb(
          loader: _loader,
          root: root,
          path: path,
          name: entry.name,
          size: 48,
        );

  Widget _entryRow(BrowseEntry entry, MaterialLocalizations localizations) {
    final date = localizations.formatMediumDate(entry.modified);
    final selecting = _selected.isNotEmpty;
    return _EntryRow(
      leading: _leadingFor(
        entry,
        root: _root!.id,
        path: [..._path, entry.name].join('/'),
      ),
      title: entry.name,
      subtitle: entry.isFolder
          ? 'Folder · $date'
          : '${formatBytes(entry.size ?? 0)} · $date',
      selected: _selected.contains(entry.name),
      selecting: selecting,
      onTap: () => _onEntryTap(entry),
      onLongPress: () => _toggle(entry.name),
      trailing: selecting
          ? null
          : IconButton(
              tooltip: 'Download ${entry.name}',
              onPressed: _pulling ? null : () => _pull([entry.name]),
              icon: const Icon(Icons.download_outlined),
            ),
    );
  }

  Widget _entryTile(BrowseEntry entry) {
    final scheme = Theme.of(context).colorScheme;
    return _GridTile(
      title: entry.name,
      selected: _selected.contains(entry.name),
      selecting: _selected.isNotEmpty,
      onTap: () => _onEntryTap(entry),
      onLongPress: () => _toggle(entry.name),
      picture: entry.isFolder
          ? ColoredBox(
              color: scheme.surfaceContainerHighest,
              child: Icon(
                Icons.folder_outlined,
                color: scheme.primary,
                size: 44,
              ),
            )
          : LaptopThumb(
              loader: _loader,
              root: _root!.id,
              path: [..._path, entry.name].join('/'),
              name: entry.name,
              radius: 0,
              bordered: false,
            ),
    );
  }
}

class _IconChip extends StatelessWidget {
  const _IconChip(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
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
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.onLongPress,
    this.trailing,
    this.selected = false,
    this.selecting = false,
  });

  final Widget leading;
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
              if (selecting) ...[
                Checkbox(value: selected, onChanged: (_) => onTap()),
                const SizedBox(width: 4),
              ],
              leading,
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
                      maxLines: 2,
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

class _GridTile extends StatelessWidget {
  const _GridTile({
    required this.picture,
    required this.title,
    required this.onTap,
    required this.onLongPress,
    required this.selected,
    required this.selecting,
  });

  final Widget picture;
  final String title;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  picture,
                  if (selecting)
                    Positioned(
                      top: 6,
                      left: 6,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.surface,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          selected ? Icons.check_circle : Icons.circle_outlined,
                          color: scheme.primary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
          ],
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
