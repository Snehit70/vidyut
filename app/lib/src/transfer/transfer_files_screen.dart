import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vidyut_files/vidyut_files.dart';

import '../debug/debug_log.dart';
import '../design/palette.dart';
import 'phone_transfer_sender.dart';
import 'transfer_history.dart';

part 'transfer_files_widgets.dart';

class TransferFilesScreen extends StatefulWidget {
  const TransferFilesScreen({
    super.key,
    required this.history,
    required this.sender,
    this.onOpenSettings,
    this.onOpenHome,
    this.onOpenFile,
    this.onShareFile,
    this.onSendAgain,
    this.canUseFileAction,
    this.onBrowseLaptop,
  });

  final TransferHistoryRepository history;
  final PhoneTransferSender sender;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onOpenHome;
  final Future<void> Function(PhoneTransferFile file)? onOpenFile;
  final Future<void> Function(PhoneTransferFile file)? onShareFile;
  final Future<void> Function(PhoneTransferFile file)? onSendAgain;
  final bool Function(PhoneTransferFile file)? canUseFileAction;

  /// Opens the laptop's shared folders to pull files from (ADR 0026).
  final VoidCallback? onBrowseLaptop;

  @override
  State<TransferFilesScreen> createState() => _TransferFilesScreenState();
}

class _TransferFilesScreenState extends State<TransferFilesScreen> {
  final _search = TextEditingController();
  List<PhoneTransferBatch> _batches = const [];
  PhoneTransferDirection? _direction;
  _FilesFilter _filter = _FilesFilter.all;
  _DateFilter _dateFilter = _DateFilter.all;
  final _selectedTransferIds = <String>{};
  bool _loading = true;
  bool _sending = false;
  PhoneTransferProgress? _liveProgress;
  StreamSubscription<PhoneTransferProgress>? _progressSubscription;
  StreamSubscription<PhoneTransferBatch>? _batchSubscription;
  StreamSubscription<PhoneTransferBatch>? _snapshotSubscription;

  @override
  void initState() {
    super.initState();
    _search.addListener(_refreshView);
    _progressSubscription = widget.sender.progress.listen((progress) {
      if (!mounted) return;
      setState(() {
        final historyPublished = _batches.any(
          (batch) =>
              batch.transferId == progress.transferId &&
              _canRemoveFromHistory(batch),
        );
        _liveProgress = historyPublished && _isTerminalProgress(progress)
            ? null
            : progress;
      });
    });
    _batchSubscription = widget.sender.batchesCreated.listen((batch) {
      if (!mounted) return;
      setState(() {
        _batches = [
          batch,
          ..._batches.where((item) => item.transferId != batch.transferId),
        ];
      });
    });
    _snapshotSubscription = widget.sender.snapshots.listen((batch) {
      if (!mounted) return;
      setState(() {
        if (_liveProgress?.transferId == batch.transferId &&
            _canRemoveFromHistory(batch)) {
          _liveProgress = null;
        }
        _batches = [
          batch,
          ..._batches.where((item) => item.transferId != batch.transferId),
        ];
      });
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _search
      ..removeListener(_refreshView)
      ..dispose();
    unawaited(_progressSubscription?.cancel());
    unawaited(_batchSubscription?.cancel());
    unawaited(_snapshotSubscription?.cancel());
    super.dispose();
  }

  void _refreshView() => setState(() {});

  Future<void> _load() async {
    final batches = await widget.history.load();
    if (!mounted) return;
    setState(() {
      _batches = batches;
      _loading = false;
    });
  }

  Future<void> _chooseFiles() async {
    if (_sending) return;
    final List<VidyutPickedFile> selected;
    try {
      selected = await const VidyutFiles().pickFiles();
    } on Object catch (error) {
      sharedDebugLog.add('files', 'Selection failed: $error', isError: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't select files. Try again.")),
        );
      }
      return;
    }
    if (!mounted || selected.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.sender.enqueue(
        selected
            .map(
              (file) => PhoneTransferSource(
                path: file.path,
                uri: file.uri,
                filename: file.filename,
                mime: file.mime,
                size: file.size,
                lastModifiedMs: file.lastModifiedMs,
                persisted: file.persisted,
                grantAlreadyRetained: file.persisted,
              ),
            )
            .toList(),
      );
    } on Object catch (error) {
      sharedDebugLog.add('files', 'Transfer failed: $error', isError: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Couldn't start the transfer. Try again."),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _liveProgress = null;
        });
      }
      await _load();
    }
  }

  Future<void> _retry(PhoneTransferBatch batch) async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      await widget.sender.retry(batch);
    } on Object catch (error) {
      sharedDebugLog.add('files', 'Retry failed: $error', isError: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Couldn't retry the transfer. Try again."),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _liveProgress = null;
        });
      }
    }
    await _load();
  }

  Future<void> _remove(PhoneTransferBatch batch) async {
    await widget.sender.removeHistory(batch);
    await _load();
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear transfer history?'),
        content: const Text(
          'This removes transfer records only. Sent and received files remain untouched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear history'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.sender.clearHistory();
    await _load();
  }

  Iterable<PhoneTransferBatch> get _visible => _batches.where(_isVisible);

  bool get _liveProgressIsVisible {
    final progress = _liveProgress;
    if (progress == null) return false;
    final matching = _batches.where(
      (batch) => batch.transferId == progress.transferId,
    );
    if (matching.isEmpty) return true;
    return matching.any(_isVisible);
  }

  bool _isVisible(PhoneTransferBatch batch) {
    final query = _search.text.trim().toLowerCase();
    if (_direction != null && batch.direction != _direction) return false;
    if (!_matchesDateFilter(batch)) return false;
    switch (_filter) {
      case _FilesFilter.all:
        break;
      case _FilesFilter.active:
        if (!_isActiveBatch(batch)) return false;
      case _FilesFilter.needsAttention:
        if (!_needsAttention(batch)) return false;
    }
    return query.isEmpty ||
        batch.files.any((file) => file.filename.toLowerCase().contains(query));
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible.toList()
      ..sort((left, right) => right.createdAtMs.compareTo(left.createdAtMs));
    final active = visible
        .where(
          (batch) =>
              _isActiveBatch(batch) &&
              batch.transferId != _liveProgress?.transferId,
        )
        .toList();
    final history = visible.where((batch) => !_isActiveBatch(batch)).toList();
    final groupedHistory = _groupByDate(history);
    final showEmpty = !_loading && _batches.isEmpty;
    final showNoResults = !_loading && _batches.isNotEmpty && visible.isEmpty;
    final selectionMode = _selectedTransferIds.isNotEmpty;
    final content = _loading
        ? const Center(child: CircularProgressIndicator())
        : CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                sliver: SliverToBoxAdapter(
                  child: _SummaryStrip(batches: _batches),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                sliver: SliverToBoxAdapter(
                  child: TextField(
                    controller: _search,
                    decoration: const InputDecoration(
                      hintText: 'Search filenames',
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                sliver: SliverToBoxAdapter(child: _buildFilters()),
              ),
              if (showEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _EmptyFiles(onSend: _chooseFiles),
                )
              else if (showNoResults)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _NoResults(onClear: _clearFilters),
                )
              else ...[
                if (_liveProgress != null && _liveProgressIsVisible)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
                    sliver: SliverToBoxAdapter(
                      child: _LiveTransferCard(
                        progress: _liveProgress!,
                        onCancel: _canCancelLive(_liveProgress!)
                            ? () => widget.sender.cancelBatch(
                                _liveProgress!.transferId!,
                              )
                            : null,
                      ),
                    ),
                  ),
                if (active.isNotEmpty) ...[
                  _sectionHeader('Active'),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                    sliver: SliverList.builder(
                      itemCount: active.length,
                      itemBuilder: (_, index) => Padding(
                        padding: EdgeInsets.only(
                          bottom: index == active.length - 1 ? 0 : 10,
                        ),
                        child: _TransferRow(
                          batch: active[index],
                          onRetry: null,
                          onCancel: _cancelCallback(active[index]),
                          onRemove: () => _remove(active[index]),
                          onTap: () => _showBatchDetails(active[index]),
                        ),
                      ),
                    ),
                  ),
                ],
                for (final entry in groupedHistory.entries) ...[
                  _sectionHeader(entry.key),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                    sliver: SliverList.builder(
                      itemCount: entry.value.length,
                      itemBuilder: (_, index) {
                        final batch = entry.value[index];
                        final canSelect = _canRemoveFromHistory(batch);
                        return Padding(
                          padding: EdgeInsets.only(
                            bottom: index == entry.value.length - 1 ? 0 : 10,
                          ),
                          child: _TransferRow(
                            batch: batch,
                            onRetry: _retryCallback(batch),
                            onCancel: _cancelCallback(batch),
                            onRemove: () => _remove(batch),
                            onOpenSettings: widget.onOpenSettings,
                            onTap: selectionMode && canSelect
                                ? () => _toggleSelection(batch)
                                : () => _showBatchDetails(batch),
                            onLongPress: canSelect
                                ? () => _toggleSelection(batch)
                                : null,
                            selected: _selectedTransferIds.contains(
                              batch.transferId,
                            ),
                            selectionMode: selectionMode,
                          ),
                        );
                      },
                    ),
                  ),
                ],
                const SliverPadding(padding: EdgeInsets.only(bottom: 112)),
              ],
            ],
          );
    return Scaffold(
      appBar: _buildAppBar(selectionMode),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: selectionMode || _sending ? null : _chooseFiles,
        icon: const Icon(Icons.add, size: 28),
        label: const Text('Send files'),
      ),
      bottomNavigationBar: selectionMode ? _buildSelectionBar() : null,
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 600) return content;
          return Row(
            children: [
              NavigationRail(
                selectedIndex: 1,
                onDestinationSelected: (index) {
                  if (index == 0) widget.onOpenHome?.call();
                },
                labelType: NavigationRailLabelType.all,
                groupAlignment: -0.8,
                destinations: const [
                  NavigationRailDestination(
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home),
                    label: Text('Home'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.folder_outlined),
                    selectedIcon: Icon(Icons.folder),
                    label: Text('Files'),
                  ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 800),
                    child: content,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildFilters() {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _FilterButton(
            label: 'All',
            selected: _filter == _FilesFilter.all,
            onTap: () => setState(() => _filter = _FilesFilter.all),
          ),
          const SizedBox(width: 10),
          _FilterButton(
            label: 'Active',
            selected: _filter == _FilesFilter.active,
            dotColor: VidyutStatusColors.of(context).active,
            onTap: () => setState(() => _filter = _FilesFilter.active),
          ),
          const SizedBox(width: 10),
          _FilterButton(
            label: 'Needs attention',
            selected: _filter == _FilesFilter.needsAttention,
            dotColor: scheme.error,
            onTap: () => setState(() => _filter = _FilesFilter.needsAttention),
          ),
          const SizedBox(width: 10),
          OutlinedButton.icon(
            onPressed: _showDirectionFilter,
            icon: const Icon(Icons.tune_outlined, size: 18),
            label: Text(
              _direction == null
                  ? 'Filter'
                  : _direction == PhoneTransferDirection.sent
                  ? 'Sent'
                  : 'Received',
            ),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 48),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              side: BorderSide(color: scheme.outlineVariant),
              foregroundColor: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showDirectionFilter() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Filter transfers',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  ListTile(
                    leading: Icon(
                      _direction == null
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      color: _direction == null
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                    title: const Text('All directions'),
                    onTap: () {
                      setState(() => _direction = null);
                      Navigator.pop(context);
                    },
                  ),
                  ListTile(
                    leading: Icon(
                      _direction == PhoneTransferDirection.sent
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      color: _direction == PhoneTransferDirection.sent
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                    title: const Text('Sent'),
                    onTap: () {
                      setState(() => _direction = PhoneTransferDirection.sent);
                      Navigator.pop(context);
                    },
                  ),
                  ListTile(
                    leading: Icon(
                      _direction == PhoneTransferDirection.received
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      color: _direction == PhoneTransferDirection.received
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                    title: const Text('Received'),
                    onTap: () {
                      setState(
                        () => _direction = PhoneTransferDirection.received,
                      );
                      Navigator.pop(context);
                    },
                  ),
                  const Divider(height: 24),
                  Text(
                    'Date',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  _DateFilterTile(
                    label: 'All dates',
                    selected: _dateFilter == _DateFilter.all,
                    onTap: () {
                      setState(() => _dateFilter = _DateFilter.all);
                      Navigator.pop(context);
                    },
                  ),
                  _DateFilterTile(
                    label: 'Today',
                    selected: _dateFilter == _DateFilter.today,
                    onTap: () {
                      setState(() => _dateFilter = _DateFilter.today);
                      Navigator.pop(context);
                    },
                  ),
                  _DateFilterTile(
                    label: 'Yesterday',
                    selected: _dateFilter == _DateFilter.yesterday,
                    onTap: () {
                      setState(() => _dateFilter = _DateFilter.yesterday);
                      Navigator.pop(context);
                    },
                  ),
                  _DateFilterTile(
                    label: 'Earlier',
                    selected: _dateFilter == _DateFilter.earlier,
                    onTap: () {
                      setState(() => _dateFilter = _DateFilter.earlier);
                      Navigator.pop(context);
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _clearFilters() {
    _search.clear();
    setState(() {
      _filter = _FilesFilter.all;
      _direction = null;
      _dateFilter = _DateFilter.all;
    });
  }

  bool _matchesDateFilter(PhoneTransferBatch batch) {
    final date = DateTime.fromMillisecondsSinceEpoch(
      batch.createdAtMs,
    ).toLocal();
    final days = _calendarDayDifference(DateTime.now(), date);
    return switch (_dateFilter) {
      _DateFilter.all => true,
      _DateFilter.today => days == 0,
      _DateFilter.yesterday => days == 1,
      _DateFilter.earlier => days > 1,
    };
  }

  PreferredSizeWidget _buildAppBar(bool selectionMode) {
    if (selectionMode) {
      return AppBar(
        leading: IconButton(
          tooltip: 'Cancel selection',
          onPressed: _clearSelection,
          icon: const Icon(Icons.close),
        ),
        title: Text('${_selectedTransferIds.length} selected'),
        actions: [
          IconButton(
            tooltip: 'Remove selected from history',
            onPressed: _removeSelected,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      );
    }
    return AppBar(
      title: const Text('Files'),
      actions: [
        if (widget.onBrowseLaptop != null)
          IconButton(
            tooltip: 'Browse laptop',
            onPressed: widget.onBrowseLaptop,
            icon: const Icon(Icons.laptop_outlined),
          ),
        if (_batches.isNotEmpty)
          IconButton(
            tooltip: 'Clear history',
            onPressed: _clear,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
      ],
    );
  }

  Widget _buildSelectionBar() => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: FilledButton.icon(
        onPressed: _removeSelected,
        icon: const Icon(Icons.delete_outline),
        label: Text('Remove from history (${_selectedTransferIds.length})'),
      ),
    ),
  );

  void _toggleSelection(PhoneTransferBatch batch) {
    setState(() {
      if (!_selectedTransferIds.add(batch.transferId)) {
        _selectedTransferIds.remove(batch.transferId);
      }
    });
  }

  void _clearSelection() => setState(_selectedTransferIds.clear);

  Future<void> _removeSelected() async {
    if (_selectedTransferIds.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Remove ${_selectedTransferIds.length} '
          '${_selectedTransferIds.length == 1 ? 'transfer' : 'transfers'}?',
        ),
        content: const Text(
          'This removes history only. Files on your devices are not deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final selected = _selectedTransferIds.toSet();
    for (final batch
        in _batches
            .where((item) => selected.contains(item.transferId))
            .toList()) {
      await widget.sender.removeHistory(batch);
    }
    _selectedTransferIds.clear();
    await _load();
  }

  Future<void> _showBatchDetails(PhoneTransferBatch batch) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _BatchDetailsSheet(
        batch: batch,
        onOpenFile: widget.onOpenFile,
        onShareFile: widget.onShareFile,
        onSendAgain: widget.onSendAgain,
        canSendAgain: widget.sender.canSendAgain,
        canUseFileAction: widget.canUseFileAction,
        onRetry: _retryCallback(batch),
        onRemove: () async {
          Navigator.pop(context);
          await _remove(batch);
        },
        onOpenSettings: widget.onOpenSettings,
      ),
    );
  }

  VoidCallback? _retryCallback(PhoneTransferBatch batch) {
    final retryable =
        batch.status == PhoneTransferStatus.failed ||
        batch.status == PhoneTransferStatus.completedWithIssues ||
        batch.status == PhoneTransferStatus.cancelled ||
        batch.status == PhoneTransferStatus.waitingForSource;
    return retryable ? () => _retry(batch) : null;
  }

  VoidCallback? _cancelCallback(PhoneTransferBatch batch) {
    return _canCancelBatch(batch)
        ? () => widget.sender.cancelBatch(batch.transferId)
        : null;
  }

  SliverToBoxAdapter _sectionHeader(String title) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    ),
  );
}
