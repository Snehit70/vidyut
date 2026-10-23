part of 'transfer_files_screen.dart';

enum _FilesFilter { all, active, needsAttention }

enum _DateFilter { all, today, yesterday, earlier }

bool _isActiveBatch(PhoneTransferBatch batch) => switch (batch.status) {
  PhoneTransferStatus.preparing ||
  PhoneTransferStatus.queued ||
  PhoneTransferStatus.active ||
  PhoneTransferStatus.paused => true,
  _ => false,
};

bool _canCancelBatch(PhoneTransferBatch batch) => switch (batch.status) {
  PhoneTransferStatus.completed ||
  PhoneTransferStatus.completedWithIssues ||
  PhoneTransferStatus.failed ||
  PhoneTransferStatus.cancelled ||
  PhoneTransferStatus.expired => false,
  _ => true,
};

bool _canRemoveFromHistory(PhoneTransferBatch batch) => switch (batch.status) {
  PhoneTransferStatus.completed ||
  PhoneTransferStatus.completedWithIssues ||
  PhoneTransferStatus.failed ||
  PhoneTransferStatus.cancelled ||
  PhoneTransferStatus.expired => true,
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

bool _isTerminalProgress(PhoneTransferProgress progress) =>
    progress.stage == PhoneTransferProgressStage.completed ||
    progress.stage == PhoneTransferProgressStage.failed;

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
    final scheme = Theme.of(context).colorScheme;
    final statusColors = VidyutStatusColors.of(context);
    final active = batches.where(_isActiveBatch).length;
    final attention = batches.where(_needsAttention).length;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: _SummaryMetric(
                icon: Icons.sync_outlined,
                color: statusColors.active,
                value: '$active',
                label: 'active',
              ),
            ),
            const _SummaryDivider(),
            Expanded(
              child: _SummaryMetric(
                icon: Icons.file_upload_outlined,
                color: scheme.primary,
                value: '${batches.length}',
                label: 'transfers',
              ),
            ),
            const _SummaryDivider(),
            Expanded(
              child: _SummaryMetric(
                icon: Icons.error_outline,
                color: attention == 0 ? scheme.onSurfaceVariant : scheme.error,
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
    color: Theme.of(context).colorScheme.outlineVariant,
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        backgroundColor: selected ? scheme.primaryContainer : null,
        foregroundColor: selected
            ? scheme.onPrimaryContainer
            : scheme.onSurface,
        side: BorderSide(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 1.5 : 1,
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
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ],
      ),
    );
  }
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected ? scheme.primary : scheme.onSurfaceVariant,
      ),
      title: Text(label),
      onTap: onTap,
    );
  }
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
    final scheme = Theme.of(context).colorScheme;
    final first = batch.files.isEmpty ? null : batch.files.first;
    final title = batch.files.length == 1
        ? first!.filename
        : '${batch.files.length} files';
    final size = batch.files.fold<int>(0, (sum, file) => sum + file.size);
    final status = _statusVisual(context, batch.status);
    final subtitle = batch.files.length == 1
        ? '${_directionLabel(batch.direction)} · ${_timeLabel(context, batch.createdAtMs)}'
        : '${_directionLabel(batch.direction)} · ${_bytes(size)} · ${_timeLabel(context, batch.createdAtMs)}';
    final failure = batch.files
        .where((file) => file.status == PhoneTransferStatus.failed)
        .firstOrNull;
    final radius = BorderRadius.circular(16);
    return Material(
      color: selected
          ? scheme.secondaryContainer
          : _needsAttention(batch)
          ? status.background
          : scheme.surface,
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
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
          child: Row(
            children: [
              if (selectionMode)
                Checkbox(
                  value: selected,
                  onChanged: (_) => onTap(),
                  activeColor: scheme.primary,
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
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (failure != null) ...[
                      const SizedBox(height: 5),
                      Text(
                        _failureReason(failure),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: scheme.error),
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
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Icon(status.icon, color: status.color, size: 22),
                ],
              ),
              if (!selectionMode)
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
                    if (_canRemoveFromHistory(batch))
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
    final scheme = Theme.of(context).colorScheme;
    final firstFile = batch.files.isEmpty ? null : batch.files.first;
    final size = batch.files.fold<int>(0, (sum, item) => sum + item.size);
    final status = _statusVisual(context, batch.status);
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
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  foregroundColor: scheme.onPrimaryContainer,
                  child: const Icon(Icons.laptop_mac_outlined),
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
                color: scheme.primary,
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
            if (_canRemoveFromHistory(batch)) ...[
              const Divider(height: 24),
              _DetailAction(
                icon: Icons.delete_outline,
                label: 'Remove from history',
                color: scheme.error,
                onTap: onRemove,
              ),
              const SizedBox(height: 8),
              Text(
                'Removing history does not delete the file.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = color ?? scheme.onSurface;
    return ListTile(
      leading: Icon(icon, color: foreground),
      title: Text(
        label,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: color),
      ),
      onTap: onTap,
    );
  }
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
    final scheme = Theme.of(context).colorScheme;
    final statusColors = VidyutStatusColors.of(context);
    final visual = _fileVisual(
      filename,
      mime,
      direction,
      scheme.primary,
      statusColors.success,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
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
  Color primary,
  Color success,
) {
  final normalizedFilename = filename?.toLowerCase() ?? '';
  final normalizedMime = mime?.toLowerCase() ?? '';
  if (normalizedMime == 'application/pdf' ||
      normalizedFilename.endsWith('.pdf')) {
    return (icon: Icons.picture_as_pdf_outlined, color: primary);
  }
  if (normalizedMime.startsWith('image/') ||
      normalizedFilename.endsWith('.png') ||
      normalizedFilename.endsWith('.jpg') ||
      normalizedFilename.endsWith('.jpeg')) {
    return (icon: Icons.image_outlined, color: primary);
  }
  if (normalizedMime == 'text/csv' || normalizedFilename.endsWith('.csv')) {
    return (icon: Icons.table_chart_outlined, color: success);
  }
  if (normalizedFilename.endsWith('.apk') ||
      normalizedMime == 'application/vnd.android.package-archive') {
    return (icon: Icons.android_outlined, color: primary);
  }
  return (
    icon: direction == PhoneTransferDirection.sent
        ? Icons.file_upload_outlined
        : Icons.file_download_outlined,
    color: primary,
  );
}

class _StatusVisual {
  const _StatusVisual(this.icon, this.color, this.background);

  final IconData icon;
  final Color color;
  final Color background;
}

_StatusVisual _statusVisual(BuildContext context, PhoneTransferStatus status) {
  final scheme = Theme.of(context).colorScheme;
  final statusColors = VidyutStatusColors.of(context);
  return switch (status) {
    PhoneTransferStatus.completed => _StatusVisual(
      Icons.check_circle_outline,
      statusColors.success,
      statusColors.successContainer,
    ),
    PhoneTransferStatus.completedWithIssues => _StatusVisual(
      Icons.warning_amber_outlined,
      statusColors.warning,
      statusColors.warningContainer,
    ),
    PhoneTransferStatus.failed || PhoneTransferStatus.expired => _StatusVisual(
      Icons.error_outline,
      scheme.error,
      scheme.errorContainer,
    ),
    PhoneTransferStatus.waitingForSource => _StatusVisual(
      Icons.error_outline,
      statusColors.warning,
      statusColors.warningContainer,
    ),
    PhoneTransferStatus.cancelled => _StatusVisual(
      Icons.cancel_outlined,
      scheme.onSurfaceVariant,
      scheme.secondaryContainer,
    ),
    _ => _StatusVisual(
      Icons.timelapse_outlined,
      statusColors.active,
      statusColors.activeContainer,
    ),
  };
}

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
    final scheme = Theme.of(context).colorScheme;
    final statusColors = VidyutStatusColors.of(context);
    final isTransferring =
        progress.stage == PhoneTransferProgressStage.transferring;
    final isCompleted = progress.stage == PhoneTransferProgressStage.completed;
    final isTerminal =
        isCompleted || progress.stage == PhoneTransferProgressStage.failed;
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
    final preparationTotal = progress.preparationTotalBytes;
    final hasPreparationTotal =
        isPreparing && preparationTotal != null && preparationTotal > 0;
    final progressFraction = hasPreparationTotal
        ? (progress.preparedBytes / preparationTotal).clamp(0.0, 1.0)
        : fraction;
    final stageLabel = isTransferring
        ? 'Transferring'
        : isPreparing
        ? 'Preparing'
        : title;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: isTransferring
            ? statusColors.activeContainer
            : scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isTransferring ? statusColors.active : scheme.outlineVariant,
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
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                _StatusBadge(
                  label: stageLabel,
                  color: isTransferring ? statusColors.active : scheme.primary,
                  background: isTransferring
                      ? statusColors.activeContainer
                      : scheme.primaryContainer,
                ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${(progressFraction * 100).round()}%',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: isTransferring
                        ? statusColors.active
                        : scheme.primary,
                  ),
                ),
                const Spacer(),
                if (!isTerminal)
                  Text(
                    _remaining(progress.remaining),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: isPreparing && progress.preparationTotalBytes == null
                  ? null
                  : progressFraction,
              minHeight: 8,
              borderRadius: BorderRadius.circular(8),
              color: isTransferring ? statusColors.active : scheme.primary,
              backgroundColor: scheme.surface,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _ProgressDetail(
                    hasPreparationTotal
                        ? '${_bytes(progress.preparedBytes)} of ${_bytes(preparationTotal)}'
                        : '${_bytes(progress.transferredBytes)} of ${_bytes(progress.totalBytes)}',
                    align: TextAlign.start,
                  ),
                ),
                if (!isTerminal) ...[
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
                      backgroundColor: scheme.primary,
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
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    ),
  );
}

class _EmptyFiles extends StatelessWidget {
  const _EmptyFiles({required this.onSend});

  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 28, 32, 96),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Icon(
                  Icons.file_upload_outlined,
                  size: 56,
                  color: scheme.onPrimaryContainer,
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
              ).textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
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
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_off_outlined,
              size: 48,
              color: scheme.onSurfaceVariant,
            ),
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
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            TextButton(onPressed: onClear, child: const Text('Clear filters')),
          ],
        ),
      ),
    );
  }
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
