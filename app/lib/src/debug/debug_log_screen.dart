import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/widgets.dart';
import 'debug_log.dart';

class DebugLogScreen extends StatefulWidget {
  const DebugLogScreen({super.key, required this.log});

  final DebugLog log;

  @override
  State<DebugLogScreen> createState() => _DebugLogScreenState();
}

class _DebugLogScreenState extends State<DebugLogScreen> {
  /// null = all categories.
  String? _category;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug log'),
        actions: [
          IconButton(
            tooltip: 'Copy diagnostics',
            icon: const Icon(Icons.copy_all_outlined, size: 20),
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(text: widget.log.exportText()),
              );
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Diagnostics copied.')),
              );
            },
          ),
          IconButton(
            tooltip: 'Clear log',
            icon: const Icon(Icons.delete_sweep, size: 20),
            style: IconButton.styleFrom(
              backgroundColor: scheme.secondaryContainer,
              foregroundColor: scheme.onSecondaryContainer,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onPressed: () => _confirmClear(context),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: widget.log,
          builder: (context, _) {
            final all = widget.log.entries.reversed.toList();
            final categories = <String>{for (final e in all) e.category};
            // The active filter may vanish when the log is cleared or trimmed.
            final active = _category != null && categories.contains(_category)
                ? _category
                : null;
            final entries = active == null
                ? all
                : all.where((e) => e.category == active).toList();

            if (all.isEmpty) return const _EmptyState();

            return Column(
              children: [
                _CategoryFilter(
                  categories: categories.toList()..sort(),
                  selected: active,
                  onSelect: (value) => setState(() => _category = value),
                ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: entries.length,
                    itemBuilder: (context, index) =>
                        _DebugLogTile(entry: entries[index]),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final clear = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear diagnostics?'),
        content: const Text(
          'This removes the saved support trail from this phone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep diagnostics'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear diagnostics'),
          ),
        ],
      ),
    );
    if (clear == true) widget.log.clear();
  }
}

class _CategoryFilter extends StatelessWidget {
  const _CategoryFilter({
    required this.categories,
    required this.selected,
    required this.onSelect,
  });

  final List<String> categories;
  final String? selected;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          _FilterPill(
            label: 'All',
            active: selected == null,
            onTap: () => onSelect(null),
          ),
          for (final category in categories)
            _FilterPill(
              label: category,
              active: selected == category,
              onTap: () => onSelect(category),
            ),
        ],
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: PressableScale(
        child: Material(
          color: active ? scheme.primary : scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(999),
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: active
                      ? scheme.onPrimary
                      : scheme.onSecondaryContainer,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.bug_report_outlined, color: scheme.primary),
          ),
          const SizedBox(height: 16),
          const Text('No debug events yet.'),
        ],
      ),
    );
  }
}

class _DebugLogTile extends StatelessWidget {
  const _DebugLogTile({required this.entry});

  final DebugLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final time = entry.timestamp;
    final timeLabel =
        '${_pad(time.hour)}:${_pad(time.minute)}:${_pad(time.second)}';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            timeLabel,
            style: textTheme.labelSmall?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.category,
                  style: textTheme.labelSmall?.copyWith(
                    color: entry.isError ? scheme.error : scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  entry.message,
                  style: textTheme.bodySmall?.copyWith(
                    color: entry.isError ? scheme.error : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _pad(int value) => value.toString().padLeft(2, '0');
}
