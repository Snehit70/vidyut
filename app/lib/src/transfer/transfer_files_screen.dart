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
  });

  final TransferHistoryRepository history;
  final PhoneTransferSender sender;

  @override
  State<TransferFilesScreen> createState() => _TransferFilesScreenState();
}

class _TransferFilesScreenState extends State<TransferFilesScreen> {
  final _search = TextEditingController();
  List<PhoneTransferBatch> _batches = const [];
  PhoneTransferDirection? _direction;
  bool _failedOnly = false;
  bool _loading = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _search.addListener(_refreshView);
    unawaited(_load());
  }

  @override
  void dispose() {
    _search
      ..removeListener(_refreshView)
      ..dispose();
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
                filename: file.filename,
                mime: file.mime,
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
      if (mounted) setState(() => _sending = false);
      await _load();
    }
  }

  Future<void> _retry(PhoneTransferBatch batch) async {
    try {
      await widget.sender.retry(batch);
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Retry failed: $error')));
      }
    }
    await _load();
  }

  Future<void> _remove(PhoneTransferBatch batch) async {
    await widget.history.remove(batch.transferId);
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
    await widget.history.clear();
    await _load();
  }

  Iterable<PhoneTransferBatch> get _visible {
    final query = _search.text.trim().toLowerCase();
    return _batches.where((batch) {
      if (_direction != null && batch.direction != _direction) return false;
      if (_failedOnly &&
          batch.status != PhoneTransferStatus.failed &&
          batch.status != PhoneTransferStatus.completedWithIssues) {
        return false;
      }
      return query.isEmpty ||
          batch.files.any(
            (file) => file.filename.toLowerCase().contains(query),
          );
    });
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible.toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Files'),
        actions: [
          if (_batches.isNotEmpty)
            IconButton(
              tooltip: 'Clear history',
              onPressed: _clear,
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _sending ? null : _chooseFiles,
        icon: _sending
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add),
        label: Text(_sending ? 'Sending…' : 'Send files'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: TextField(
                    controller: _search,
                    decoration: const InputDecoration(
                      hintText: 'Search filenames',
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                ),
                SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      FilterChip(
                        label: const Text('Sent'),
                        selected: _direction == PhoneTransferDirection.sent,
                        onSelected: (selected) => setState(
                          () => _direction = selected
                              ? PhoneTransferDirection.sent
                              : null,
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilterChip(
                        label: const Text('Received'),
                        selected: _direction == PhoneTransferDirection.received,
                        onSelected: (selected) => setState(
                          () => _direction = selected
                              ? PhoneTransferDirection.received
                              : null,
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilterChip(
                        label: const Text('Failed'),
                        selected: _failedOnly,
                        onSelected: (selected) =>
                            setState(() => _failedOnly = selected),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: visible.isEmpty
                      ? const _EmptyFiles()
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                          itemCount: visible.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 10),
                          itemBuilder: (_, index) {
                            final batch = visible[index];
                            return _BatchCard(
                              batch: batch,
                              onRetry:
                                  batch.status == PhoneTransferStatus.failed ||
                                      batch.status ==
                                          PhoneTransferStatus
                                              .completedWithIssues
                                  ? () => _retry(batch)
                                  : null,
                              onRemove: () => _remove(batch),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

class _BatchCard extends StatelessWidget {
  const _BatchCard({required this.batch, required this.onRemove, this.onRetry});

  final PhoneTransferBatch batch;
  final VoidCallback onRemove;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final total = batch.files.fold<int>(0, (sum, file) => sum + file.size);
    final confirmed = batch.files.fold<int>(
      0,
      (sum, file) => sum + file.confirmedOffset,
    );
    final progress = total == 0 ? 1.0 : confirmed / total;
    final title = batch.files.length == 1
        ? batch.files.single.filename
        : '${batch.files.length} files';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Palette.mist,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  batch.direction == PhoneTransferDirection.sent
                      ? Icons.upload_file
                      : Icons.download,
                  color: Palette.raspberry,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'retry') onRetry?.call();
                    if (value == 'remove') onRemove();
                  },
                  itemBuilder: (_) => [
                    if (onRetry != null)
                      const PopupMenuItem(
                        value: 'retry',
                        child: Text('Retry failed'),
                      ),
                    const PopupMenuItem(
                      value: 'remove',
                      child: Text('Remove from history'),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(_statusLabel(batch.status)),
            if (batch.status == PhoneTransferStatus.active ||
                batch.status == PhoneTransferStatus.queued) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(value: progress.clamp(0, 1)),
              const SizedBox(height: 5),
              Text('${_bytes(confirmed)} of ${_bytes(total)}'),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyFiles extends StatelessWidget {
  const _EmptyFiles();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'Files you send and receive will appear here.',
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.bodyLarge?.copyWith(color: Palette.muted),
        ),
      ),
    );
  }
}

String _statusLabel(PhoneTransferStatus status) {
  return switch (status) {
    PhoneTransferStatus.queued => 'Queued',
    PhoneTransferStatus.active => 'Transferring',
    PhoneTransferStatus.paused => 'Paused',
    PhoneTransferStatus.completed => 'Completed',
    PhoneTransferStatus.completedWithIssues => 'Completed with issues',
    PhoneTransferStatus.failed => 'Failed',
    PhoneTransferStatus.cancelled => 'Cancelled',
    PhoneTransferStatus.expired => 'Expired',
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
