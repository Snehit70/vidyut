import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vidyut_files/vidyut_files.dart';

import '../design/palette.dart';
import 'phone_transfer_sender.dart';
import 'transfer_history.dart';

class TransferFilesScreen extends StatefulWidget {
  const TransferFilesScreen({
    super.key,
    required this.history,
    required this.sender,
    this.onOpenSettings,
    this.onOpenFile,
    this.onShareFile,
    this.onSendAgain,
    this.canUseFileAction,
  });

  final TransferHistoryRepository history;
  final PhoneTransferSender sender;
  final VoidCallback? onOpenSettings;
  final Future<void> Function(PhoneTransferFile file)? onOpenFile;
  final Future<void> Function(PhoneTransferFile file)? onShareFile;
  final Future<void> Function(PhoneTransferFile file)? onSendAgain;
  final bool Function(PhoneTransferFile file)? canUseFileAction;

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
      if (mounted) setState(() => _liveProgress = progress);
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
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Selection failed: $error')));
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
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Transfer failed: $error')));
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
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Retry failed: $error')));
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

  Iterable<PhoneTransferBatch> get _visible {
    final query = _search.text.trim().toLowerCase();
    return _batches.where((batch) {
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
          batch.files.any(
            (file) => file.filename.toLowerCase().contains(query),
          );
    });
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
    return Scaffold(
      appBar: _buildAppBar(selectionMode),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: selectionMode || _sending ? null : _chooseFiles,
        icon: const Icon(Icons.add, size: 28),
        label: const Text('Send files'),
      ),
      bottomNavigationBar: selectionMode ? _buildSelectionBar() : null,
      body: _loading
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
                  if (_liveProgress != null)
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
                              onTap: selectionMode
                                  ? () => _toggleSelection(batch)
                                  : () => _showBatchDetails(batch),
                              onLongPress: () => _toggleSelection(batch),
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
            ),
    );
  }

  Widget _buildFilters() => SingleChildScrollView(
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
          dotColor: Palette.active,
          onTap: () => setState(() => _filter = _FilesFilter.active),
        ),
        const SizedBox(width: 10),
        _FilterButton(
          label: 'Needs attention',
          selected: _filter == _FilesFilter.needsAttention,
          dotColor: Palette.error,
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
            side: const BorderSide(color: Palette.hairline, width: 1.5),
            foregroundColor: Palette.ink,
          ),
        ),
      ],
    ),
  );

  Future<void> _showDirectionFilter() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
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
                        ? Palette.raspberry
                        : Palette.muted,
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
                        ? Palette.raspberry
                        : Palette.muted,
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
                        ? Palette.raspberry
                        : Palette.muted,
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
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(color: Palette.muted),
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
      ),
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
    return _isActiveBatch(batch)
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

enum _FilesFilter { all, active, needsAttention }

enum _DateFilter { all, today, yesterday, earlier }

bool _isActiveBatch(PhoneTransferBatch batch) => switch (batch.status) {
  PhoneTransferStatus.preparing ||
  PhoneTransferStatus.queued ||
  PhoneTransferStatus.active ||
  PhoneTransferStatus.paused => true,
  _ => false,
};

bool _canCancelLive(PhoneTransferProgress progress) {
  if (progress.transferId == null) return false;
  return switch (progress.stage) {
    PhoneTransferProgressStage.completed ||
    PhoneTransferProgressStage.failed => false,
    _ => true,
  };
}

bool _needsAttention(PhoneTransferBatch batch) => switch (batch.status) {
  PhoneTransferStatus.failed ||
  PhoneTransferStatus.completedWithIssues ||
  PhoneTransferStatus.waitingForSource ||
  PhoneTransferStatus.expired => true,
  _ => false,
};

Map<String, List<PhoneTransferBatch>> _groupByDate(
  Iterable<PhoneTransferBatch> batches,
) {
  final grouped = <String, List<PhoneTransferBatch>>{};
  for (final batch in batches) {
    grouped.putIfAbsent(_dateGroup(batch.createdAtMs), () => []).add(batch);
  }
  return grouped;
}

String _dateGroup(int timestampMs) {
  final date = DateTime.fromMillisecondsSinceEpoch(timestampMs).toLocal();
  final days = _calendarDayDifference(DateTime.now(), date);
  if (days == 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days > 1 && days < 7) return 'Earlier this week';
  return 'Earlier';
}

int _calendarDayDifference(DateTime now, DateTime candidate) {
  final today = DateTime.utc(now.year, now.month, now.day);
  final date = DateTime.utc(candidate.year, candidate.month, candidate.day);
  return today.difference(date).inDays;
}

String _timeLabel(BuildContext context, int timestampMs) {
  final date = DateTime.fromMillisecondsSinceEpoch(timestampMs).toLocal();
  return MaterialLocalizations.of(context).formatTimeOfDay(
    TimeOfDay.fromDateTime(date),
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
}

class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({required this.batches});

  final List<PhoneTransferBatch> batches;

  @override
  Widget build(BuildContext context) {
    final active = batches.where(_isActiveBatch).length;
    final attention = batches.where(_needsAttention).length;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Palette.mist,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Palette.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: _SummaryMetric(
                icon: Icons.sync_outlined,
                color: Palette.active,
                value: '$active',
                label: 'active',
              ),
            ),
            const _SummaryDivider(),
            Expanded(
              child: _SummaryMetric(
                icon: Icons.file_upload_outlined,
                color: Palette.raspberry,
                value: '${batches.length}',
                label: 'transfers',
              ),
            ),
            const _SummaryDivider(),
            Expanded(
              child: _SummaryMetric(
                icon: Icons.error_outline,
                color: attention == 0 ? Palette.muted : Palette.error,
                value: '$attention',
                label: 'need attention',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryMetric extends StatelessWidget {
  const _SummaryMetric({
    required this.icon,
    required this.color,
    required this.value,
    required this.label,
  });

  final IconData icon;
  final Color color;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Icon(icon, color: color, size: 22),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
          '$value $label',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelLarge,
        ),
      ),
    ],
  );
}

class _SummaryDivider extends StatelessWidget {
  const _SummaryDivider();

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 24,
    color: Palette.hairline,
    margin: const EdgeInsets.symmetric(horizontal: 6),
  );
}

class _FilterButton extends StatelessWidget {
  const _FilterButton({
    required this.label,
    required this.selected,
    required this.onTap,
    this.dotColor,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? dotColor;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    onPressed: onTap,
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(0, 48),
      padding: const EdgeInsets.symmetric(horizontal: 18),
      backgroundColor: selected ? Palette.petal : Colors.transparent,
      foregroundColor: Palette.ink,
      side: BorderSide(
        color: selected ? Palette.petal : Palette.hairline,
        width: 1.5,
      ),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        if (dotColor != null) ...[
          const SizedBox(width: 8),
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
        ],
      ],
    ),
  );
}

class _DateFilterTile extends StatelessWidget {
  const _DateFilterTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(
      selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
      color: selected ? Palette.raspberry : Palette.muted,
    ),
    title: Text(label),
    onTap: onTap,
  );
}

class _TransferRow extends StatelessWidget {
  const _TransferRow({
    required this.batch,
    required this.onRemove,
    required this.onTap,
    this.onRetry,
    this.onCancel,
    this.onOpenSettings,
    this.onLongPress,
    this.selected = false,
    this.selectionMode = false,
  });

  final PhoneTransferBatch batch;
  final VoidCallback onRemove;
  final VoidCallback onTap;
  final VoidCallback? onRetry;
  final VoidCallback? onCancel;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onLongPress;
  final bool selected;
  final bool selectionMode;

  @override
  Widget build(BuildContext context) {
    final first = batch.files.isEmpty ? null : batch.files.first;
    final title = batch.files.length == 1
        ? first!.filename
        : '${batch.files.length} files';
    final size = batch.files.fold<int>(0, (sum, file) => sum + file.size);
    final status = _statusVisual(batch.status);
    final subtitle = batch.files.length == 1
        ? '${_directionLabel(batch.direction)} · ${_timeLabel(context, batch.createdAtMs)}'
        : '${_directionLabel(batch.direction)} · ${_bytes(size)} · ${_timeLabel(context, batch.createdAtMs)}';
    final failure = batch.files
        .where((file) => file.status == PhoneTransferStatus.failed)
        .firstOrNull;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected
              ? Palette.mist
              : _needsAttention(batch)
              ? status.background
              : Palette.ground,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? Palette.raspberry : Palette.hairline,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
          child: Row(
            children: [
              if (selectionMode)
                Checkbox(
                  value: selected,
                  onChanged: (_) => onTap(),
                  activeColor: Palette.raspberry,
                )
              else
                _FileTypeIcon(
                  filename: first?.filename,
                  mime: first?.mime,
                  direction: batch.direction,
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
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: Palette.muted),
                    ),
                    if (failure != null) ...[
                      const SizedBox(height: 5),
                      Text(
                        _failureReason(failure),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: Palette.error),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _bytes(size),
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Palette.muted),
                  ),
                  const SizedBox(height: 8),
                  Icon(status.icon, color: status.color, size: 22),
                ],
              ),
              PopupMenuButton<String>(
                tooltip: 'Transfer actions',
                onSelected: (value) {
                  if (value == 'retry') onRetry?.call();
                  if (value == 'cancel') onCancel?.call();
                  if (value == 'remove') onRemove();
                  if (value == 'settings') onOpenSettings?.call();
                },
                itemBuilder: (_) => [
                  if (onRetry != null)
                    const PopupMenuItem(value: 'retry', child: Text('Retry')),
                  if (onCancel != null)
                    const PopupMenuItem(
                      value: 'cancel',
                      child: Text('Cancel transfer'),
                    ),
                  if (failure?.errorCode == 'file_too_large' &&
                      onOpenSettings != null)
                    const PopupMenuItem(
                      value: 'settings',
                      child: Text('Open transfer settings'),
                    ),
                  const PopupMenuItem(
                    value: 'remove',
                    child: Text('Remove from history'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BatchDetailsSheet extends StatelessWidget {
  const _BatchDetailsSheet({
    required this.batch,
    required this.onRemove,
    this.onOpenFile,
    this.onShareFile,
    this.onSendAgain,
    this.canSendAgain,
    this.canUseFileAction,
    this.onRetry,
    this.onOpenSettings,
  });

  final PhoneTransferBatch batch;
  final VoidCallback onRemove;
  final Future<void> Function(PhoneTransferFile file)? onOpenFile;
  final Future<void> Function(PhoneTransferFile file)? onShareFile;
  final Future<void> Function(PhoneTransferFile file)? onSendAgain;
  final bool Function(PhoneTransferFile file)? canSendAgain;
  final bool Function(PhoneTransferFile file)? canUseFileAction;
  final VoidCallback? onRetry;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final firstFile = batch.files.isEmpty ? null : batch.files.first;
    final size = batch.files.fold<int>(0, (sum, item) => sum + item.size);
    final status = _statusVisual(batch.status);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _FileTypeIcon(
                  filename: firstFile?.filename,
                  mime: firstFile?.mime,
                  direction: batch.direction,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        batch.files.length == 1
                            ? firstFile!.filename
                            : '${batch.files.length} files',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 8),
                      _StatusBadge(
                        label: _statusLabel(batch.status),
                        color: status.color,
                        background: status.background,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${_bytes(size)} · ${_directionLabel(batch.direction)} · ${_dateGroup(batch.createdAtMs)}, ${_timeLabel(context, batch.createdAtMs)}',
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: Palette.muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            DecoratedBox(
              decoration: BoxDecoration(
                color: Palette.mist,
                borderRadius: BorderRadius.circular(18),
              ),
              child: ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Palette.petal,
                  foregroundColor: Palette.ink,
                  child: Icon(Icons.laptop_mac_outlined),
                ),
                title: Text(_savedLocationLabel(batch)),
              ),
            ),
            const SizedBox(height: 12),
            if (batch.files.any(
              (file) => file.status == PhoneTransferStatus.completed,
            ))
              for (final file in batch.files.where(
                (file) => file.status == PhoneTransferStatus.completed,
              )) ...[
                if (batch.files.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 4),
                    child: Text(
                      file.filename,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                if (onOpenFile != null &&
                    (canUseFileAction?.call(file) ?? true))
                  _DetailAction(
                    icon: Icons.open_in_new,
                    label: 'Open',
                    onTap: () => unawaited(
                      _runAction(context, 'Open', onOpenFile, file),
                    ),
                  ),
                if (onShareFile != null &&
                    (canUseFileAction?.call(file) ?? true))
                  _DetailAction(
                    icon: Icons.share_outlined,
                    label: 'Share',
                    onTap: () => unawaited(
                      _runAction(context, 'Share', onShareFile, file),
                    ),
                  ),
                if (onSendAgain != null && canSendAgain?.call(file) == true)
                  _DetailAction(
                    icon: Icons.send_outlined,
                    label: 'Send again',
                    onTap: () => unawaited(
                      _runAction(context, 'Send again', onSendAgain, file),
                    ),
                  ),
              ],
            if (onRetry != null)
              _DetailAction(
                icon: Icons.refresh,
                label: 'Retry',
                onTap: () {
                  Navigator.pop(context);
                  onRetry!();
                },
                color: Palette.raspberry,
              ),
            if (batch.files.any((item) => item.errorCode == 'file_too_large') &&
                onOpenSettings != null)
              _DetailAction(
                icon: Icons.settings_outlined,
                label: 'Open transfer settings',
                onTap: () {
                  Navigator.pop(context);
                  onOpenSettings!();
                },
              ),
            const Divider(height: 24),
            _DetailAction(
              icon: Icons.delete_outline,
              label: 'Remove from history',
              color: Palette.error,
              onTap: onRemove,
            ),
            const SizedBox(height: 8),
            Text(
              'Removing history does not delete the file.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Palette.muted),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _runAction(
    BuildContext context,
    String label,
    Future<void> Function(PhoneTransferFile file)? action,
    PhoneTransferFile file,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.pop(context);
    if (action == null) return;
    try {
      await action(file);
    } catch (_) {
      messenger?.showSnackBar(SnackBar(content: Text('$label failed.')));
    }
  }
}

class _DetailAction extends StatelessWidget {
  const _DetailAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon, color: color ?? Palette.ink),
    title: Text(
      label,
      style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: color),
    ),
    onTap: onTap,
  );
}

class _FileTypeIcon extends StatelessWidget {
  const _FileTypeIcon({
    required this.filename,
    required this.mime,
    required this.direction,
  });

  final String? filename;
  final String? mime;
  final PhoneTransferDirection direction;

  @override
  Widget build(BuildContext context) {
    final visual = _fileVisual(filename, mime, direction);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Palette.ground,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Palette.hairline),
      ),
      child: SizedBox(
        width: 48,
        height: 48,
        child: Icon(visual.icon, color: visual.color, size: 28),
      ),
    );
  }
}

({IconData icon, Color color}) _fileVisual(
  String? filename,
  String? mime,
  PhoneTransferDirection direction,
) {
  final normalizedFilename = filename?.toLowerCase() ?? '';
  final normalizedMime = mime?.toLowerCase() ?? '';
  if (normalizedMime == 'application/pdf' ||
      normalizedFilename.endsWith('.pdf')) {
    return (icon: Icons.picture_as_pdf_outlined, color: Palette.raspberry);
  }
  if (normalizedMime.startsWith('image/') ||
      normalizedFilename.endsWith('.png') ||
      normalizedFilename.endsWith('.jpg') ||
      normalizedFilename.endsWith('.jpeg')) {
    return (icon: Icons.image_outlined, color: Palette.raspberry);
  }
  if (normalizedMime == 'text/csv' || normalizedFilename.endsWith('.csv')) {
    return (icon: Icons.table_chart_outlined, color: Palette.success);
  }
  if (normalizedFilename.endsWith('.apk') ||
      normalizedMime == 'application/vnd.android.package-archive') {
    return (icon: Icons.android_outlined, color: Palette.raspberry);
  }
  return (
    icon: direction == PhoneTransferDirection.sent
        ? Icons.file_upload_outlined
        : Icons.file_download_outlined,
    color: Palette.raspberry,
  );
}

class _StatusVisual {
  const _StatusVisual(this.icon, this.color, this.background);

  final IconData icon;
  final Color color;
  final Color background;
}

_StatusVisual _statusVisual(PhoneTransferStatus status) => switch (status) {
  PhoneTransferStatus.completed => const _StatusVisual(
    Icons.check_circle_outline,
    Palette.success,
    Palette.successMist,
  ),
  PhoneTransferStatus.completedWithIssues => const _StatusVisual(
    Icons.warning_amber_outlined,
    Palette.warning,
    Palette.warningMist,
  ),
  PhoneTransferStatus.failed || PhoneTransferStatus.expired =>
    const _StatusVisual(Icons.error_outline, Palette.error, Color(0xFFFFF2F4)),
  PhoneTransferStatus.waitingForSource => const _StatusVisual(
    Icons.error_outline,
    Palette.warning,
    Palette.warningMist,
  ),
  _ => const _StatusVisual(
    Icons.timelapse_outlined,
    Palette.active,
    Palette.activeMist,
  ),
};

String _statusLabel(PhoneTransferStatus status) => switch (status) {
  PhoneTransferStatus.preparing => 'Preparing',
  PhoneTransferStatus.waitingForSource => 'Waiting for source',
  PhoneTransferStatus.queued => 'Queued',
  PhoneTransferStatus.active => 'Transferring',
  PhoneTransferStatus.paused => 'Paused',
  PhoneTransferStatus.completed => 'Completed',
  PhoneTransferStatus.completedWithIssues => 'Completed with issues',
  PhoneTransferStatus.failed => 'Failed',
  PhoneTransferStatus.cancelled => 'Cancelled',
  PhoneTransferStatus.expired => 'Expired',
};

String _directionLabel(PhoneTransferDirection direction) =>
    direction == PhoneTransferDirection.sent
    ? 'Sent to your laptop'
    : 'Received from your laptop';

String _savedLocationLabel(PhoneTransferBatch batch) {
  final destination = batch.direction == PhoneTransferDirection.received
      ? 'your device'
      : 'your laptop';
  return switch (batch.status) {
    PhoneTransferStatus.completed => 'Saved on $destination',
    PhoneTransferStatus.completedWithIssues =>
      'Some files saved on $destination',
    PhoneTransferStatus.preparing ||
    PhoneTransferStatus.queued ||
    PhoneTransferStatus.active ||
    PhoneTransferStatus.paused => 'Saving to $destination',
    PhoneTransferStatus.waitingForSource => 'Waiting for source',
    PhoneTransferStatus.failed => 'Nothing was saved',
    PhoneTransferStatus.cancelled => 'Transfer cancelled',
    PhoneTransferStatus.expired => 'Transfer expired',
  };
}

class _LiveTransferCard extends StatelessWidget {
  const _LiveTransferCard({required this.progress, this.onCancel});

  final PhoneTransferProgress progress;
  final Future<void> Function()? onCancel;

  @override
  Widget build(BuildContext context) {
    final isTransferring =
        progress.stage == PhoneTransferProgressStage.transferring;
    final isCompleted = progress.stage == PhoneTransferProgressStage.completed;
    final isPreparing = {
      PhoneTransferProgressStage.preparing,
      PhoneTransferProgressStage.readingSelection,
      PhoneTransferProgressStage.staging,
      PhoneTransferProgressStage.hashing,
      PhoneTransferProgressStage.policyCheck,
    }.contains(progress.stage);
    final title = switch (progress.stage) {
      PhoneTransferProgressStage.preparing => 'Preparing files',
      PhoneTransferProgressStage.readingSelection => 'Reading selection',
      PhoneTransferProgressStage.staging => 'Staging fallback',
      PhoneTransferProgressStage.hashing => 'Verifying',
      PhoneTransferProgressStage.policyCheck => 'Checking requirements',
      PhoneTransferProgressStage.connecting => 'Connecting to your laptop',
      PhoneTransferProgressStage.waitingForLaptop => 'Waiting for your laptop',
      PhoneTransferProgressStage.transferring => 'Sending to your laptop',
      PhoneTransferProgressStage.cancelling => 'Cancelling',
      PhoneTransferProgressStage.waitingForSource => 'Source unavailable',
      PhoneTransferProgressStage.completed => 'Transfer complete',
      PhoneTransferProgressStage.failed => 'Transfer needs attention',
    };
    final fraction = isCompleted ? 1.0 : progress.fraction;
    final stageLabel = isTransferring
        ? 'Transferring'
        : isPreparing
        ? 'Preparing'
        : title;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: isTransferring ? Palette.activeMist : Palette.mist,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isTransferring ? const Color(0xFFFFD2A5) : Palette.hairline,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _FileTypeIcon(
                  filename: progress.currentFilename,
                  mime: null,
                  direction: PhoneTransferDirection.sent,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        progress.currentFilename ??
                            'Getting the transfer ready',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Sending to your laptop',
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: Palette.muted),
                      ),
                    ],
                  ),
                ),
                _StatusBadge(
                  label: stageLabel,
                  color: isTransferring ? Palette.active : Palette.raspberry,
                  background: isTransferring
                      ? const Color(0xFFFFE2C1)
                      : Palette.petal,
                ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${(fraction * 100).round()}%',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: isTransferring ? Palette.active : Palette.raspberry,
                  ),
                ),
                const Spacer(),
                Text(
                  _remaining(progress.remaining),
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Palette.muted),
                ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: isPreparing && progress.preparationTotalBytes == null
                  ? null
                  : fraction,
              minHeight: 8,
              borderRadius: BorderRadius.circular(8),
              color: isTransferring ? Palette.active : Palette.raspberry,
              backgroundColor: Colors.white,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _ProgressDetail(
                    '${_bytes(progress.transferredBytes)} of ${_bytes(progress.totalBytes)}',
                    align: TextAlign.start,
                  ),
                ),
                _ProgressDetail(_rate(progress.bytesPerSecond)),
                Expanded(
                  child: _ProgressDetail(
                    isPreparing
                        ? _elapsed(progress.preparationElapsed)
                        : _remaining(progress.remaining),
                    align: TextAlign.end,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            const Divider(height: 1),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: null,
                    icon: const Icon(Icons.pause, size: 20),
                    label: const Text('Pause'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onCancel == null
                        ? null
                        : () => unawaited(onCancel!()),
                    icon: const Icon(Icons.close, size: 20),
                    label: const Text('Cancel'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Palette.raspberry,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    required this.label,
    required this.color,
    required this.background,
  });

  final String label;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color),
      ),
    ),
  );
}

class _ProgressDetail extends StatelessWidget {
  const _ProgressDetail(this.text, {this.align = TextAlign.center});

  final String text;
  final TextAlign align;

  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: align,
    style: Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Palette.muted,
      fontWeight: FontWeight.w600,
    ),
  );
}

class _EmptyFiles extends StatelessWidget {
  const _EmptyFiles({required this.onSend});

  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 28, 32, 96),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: Palette.mist,
                shape: BoxShape.circle,
                border: Border.all(color: Palette.hairline),
              ),
              child: const Padding(
                padding: EdgeInsets.all(28),
                child: Icon(
                  Icons.file_upload_outlined,
                  size: 56,
                  color: Palette.raspberry,
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Send files between your devices',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 10),
            Text(
              'Files you send or receive will appear here.\nTransfers stay on your local Wi-Fi.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(color: Palette.muted),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onSend,
              icon: const Icon(Icons.add),
              label: const Text('Send files'),
            ),
            const SizedBox(height: 16),
            Text(
              'You can send multiple files at once.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Palette.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoResults extends StatelessWidget {
  const _NoResults({required this.onClear});

  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.search_off_outlined, size: 48, color: Palette.muted),
          const SizedBox(height: 16),
          Text(
            'No transfers found',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'Try another filename or clear the filters.',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Palette.muted),
          ),
          const SizedBox(height: 14),
          TextButton(onPressed: onClear, child: const Text('Clear filters')),
        ],
      ),
    ),
  );
}

String _elapsed(Duration? value) {
  if (value == null) return 'starting';
  final seconds = value.inSeconds;
  if (seconds < 60) return '${seconds}s elapsed';
  return '${seconds ~/ 60}m ${seconds % 60}s elapsed';
}

String _failureReason(PhoneTransferFile file) {
  return switch (file.errorCode) {
    'insufficient_storage' => 'The receiver does not have enough storage.',
    'source_unavailable' => 'The selected source is no longer available.',
    'source_permission_denied' =>
      'Permission to read the selected source was denied.',
    'timeout' => 'The transfer timed out. Try again.',
    'hash_mismatch' => 'Integrity verification failed. Try again.',
    'transfer_failed' => file.errorDetail ?? 'The transfer failed.',
    _ => file.errorDetail ?? 'The transfer failed.',
  };
}

String _bytes(int value) {
  if (value < 1024) return '$value B';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
  if (value < 1024 * 1024 * 1024) {
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

String _rate(double? value) {
  if (value == null || value <= 0) return 'Measuring speed';
  return '${_bytes(value.round())}/s';
}

String _remaining(Duration? value) {
  if (value == null) return 'Calculating time left';
  if (value.inMinutes >= 1) {
    final seconds = value.inSeconds.remainder(60);
    return '~${value.inMinutes}m ${seconds}s left';
  }
  return '~${value.inSeconds.clamp(1, 59)} sec left';
}
