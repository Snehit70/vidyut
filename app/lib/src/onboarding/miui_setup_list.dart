import 'package:flutter/material.dart';

import '../design/palette.dart';
import '../settings/app_settings.dart';
import 'setup_actions.dart';

/// The four self-reported MIUI items (onboarding spec D5), shared by the
/// wizard's Xiaomi step and the checklist's MIUI section: an action button
/// per item plus an "I did this" checkbox the app persists but cannot verify.
class MiuiSetupList extends StatelessWidget {
  const MiuiSetupList({
    super.key,
    required this.actions,
    required this.flags,
    required this.onFlagChanged,
  });

  final SetupActions actions;
  final Map<MiuiSetupFlag, bool> flags;
  final void Function(MiuiSetupFlag flag, bool value) onFlagChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MiuiItem(
          flag: MiuiSetupFlag.autostart,
          title: 'Autostart',
          description: 'Let Vidyut start itself after MIUI kills it.',
          actionLabel: 'Open autostart manager',
          onAction: actions.openAutostartSettings,
          done: flags[MiuiSetupFlag.autostart] ?? false,
          onDone: onFlagChanged,
        ),
        _MiuiItem(
          flag: MiuiSetupFlag.battery,
          title: 'Battery: No restrictions',
          description: 'Pick "No restrictions" on the battery saver page.',
          actionLabel: 'Open battery settings',
          onAction: actions.openBatterySaverSettings,
          done: flags[MiuiSetupFlag.battery] ?? false,
          onDone: onFlagChanged,
        ),
        _MiuiItem(
          flag: MiuiSetupFlag.lockInRecents,
          title: 'Lock in recents',
          // No deep link exists (D5) — "How?" expands this instruction.
          expandableHow:
              'Open recents, pull down (or long-press) the Vidyut card, '
              'then tap the lock icon.',
          done: flags[MiuiSetupFlag.lockInRecents] ?? false,
          onDone: onFlagChanged,
        ),
        _MiuiItem(
          flag: MiuiSetupFlag.clipboard,
          title: 'Clipboard permission',
          description:
              'Allow clipboard access so received text lands without a tap.',
          actionLabel: 'Open permission editor',
          onAction: actions.openClipboardPermissionSettings,
          done: flags[MiuiSetupFlag.clipboard] ?? false,
          onDone: onFlagChanged,
        ),
      ],
    );
  }
}

class _MiuiItem extends StatefulWidget {
  const _MiuiItem({
    required this.flag,
    required this.title,
    this.description,
    this.actionLabel,
    this.onAction,
    this.expandableHow,
    required this.done,
    required this.onDone,
  });

  final MiuiSetupFlag flag;
  final String title;
  final String? description;
  final String? actionLabel;
  final Future<void> Function()? onAction;
  final String? expandableHow;
  final bool done;
  final void Function(MiuiSetupFlag flag, bool value) onDone;

  @override
  State<_MiuiItem> createState() => _MiuiItemState();
}

class _MiuiItemState extends State<_MiuiItem> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.title, style: textTheme.titleSmall),
                  if (widget.description != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      widget.description!,
                      style: textTheme.bodySmall?.copyWith(
                        color: Palette.muted,
                      ),
                    ),
                  ],
                  if (widget.actionLabel != null)
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () => widget.onAction?.call(),
                      child: Text(widget.actionLabel!),
                    ),
                  if (widget.expandableHow != null) ...[
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () => setState(() => _expanded = !_expanded),
                      child: Text(_expanded ? 'Hide' : 'How?'),
                    ),
                    if (_expanded)
                      Text(
                        widget.expandableHow!,
                        style: textTheme.bodySmall?.copyWith(
                          color: Palette.muted,
                        ),
                      ),
                  ],
                ],
              ),
            ),
            Checkbox(
              value: widget.done,
              activeColor: Palette.raspberry,
              onChanged: (value) => widget.onDone(widget.flag, value ?? false),
            ),
          ],
        ),
      ),
    );
  }
}
