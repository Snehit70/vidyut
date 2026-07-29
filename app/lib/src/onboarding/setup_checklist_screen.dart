import 'dart:async';

import 'package:flutter/material.dart';
import 'package:screenshot_observer/screenshot_observer.dart';

import '../design/palette.dart';
import '../design/widgets.dart';
import '../settings/app_settings.dart';
import 'miui_setup_list.dart';
import 'setup_actions.dart';
import 'setup_status.dart';

/// The persistent "Setup status" surface (onboarding spec D1, D6): every item
/// with live state, plus the self-reported MIUI section. This is the recovery
/// screen for everything that can degrade after onboarding.
class SetupChecklistScreen extends StatefulWidget {
  const SetupChecklistScreen({super.key, required this.loader});

  final SetupStatusLoader loader;

  @override
  State<SetupChecklistScreen> createState() => _SetupChecklistScreenState();
}

class _SetupChecklistScreenState extends State<SetupChecklistScreen>
    with WidgetsBindingObserver {
  SetupStatus? _status;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_reload());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// D6: recompute the snapshot on resume so external changes (revoking
  /// photos in system settings) reflect immediately.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_reload());
  }

  Future<void> _reload() async {
    final status = await widget.loader.load();
    if (mounted) setState(() => _status = status);
  }

  Future<void> _setMiuiFlag(MiuiSetupFlag flag, bool value) async {
    await widget.loader.settingsRepository.saveMiuiSetupFlag(flag, value);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Scaffold(
      appBar: AppBar(title: const Text('Setup status')),
      body: status == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                _ChecklistRow(
                  ok: status.notificationsGranted,
                  title: 'Notifications',
                  detail: status.notificationsGranted
                      ? 'Receipts and the sync notification can show.'
                      : "You won't see receipts when the laptop sends "
                            'you things.',
                  actionLabel: status.notificationsGranted
                      ? null
                      : 'Open settings',
                  onAction: widget.loader.actions.openAppSettings,
                ).entrance(0),
                _ChecklistRow(
                  ok: status.photosAccess == ScreenshotAccessLevel.full,
                  title: 'Photos access',
                  detail: switch (status.photosAccess) {
                    ScreenshotAccessLevel.full =>
                      'Full access — screenshots send themselves.',
                    ScreenshotAccessLevel.partial =>
                      "Only selected photos — switch to 'Allow all' so new "
                          'screenshots are visible.',
                    ScreenshotAccessLevel.denied =>
                      "No access — screenshots won't send themselves.",
                  },
                  actionLabel: status.photosAccess == ScreenshotAccessLevel.full
                      ? null
                      : 'Open settings',
                  onAction: widget.loader.actions.openAppSettings,
                ).entrance(1),
                _ChecklistRow(
                  ok: status.batteryExempt,
                  title: 'Battery exemption',
                  detail: status.batteryExempt
                      ? 'Vidyut stays connected while the phone sleeps.'
                      : 'Sync may pause when the phone sleeps.',
                  actionLabel: status.batteryExempt ? null : 'Allow',
                  onAction: widget.loader.actions.requestBatteryExemption,
                  reloadAfterAction: _reload,
                ).entrance(2),
                _ChecklistRow(
                  ok: status.paired,
                  title: 'Paired with laptop',
                  detail: status.paired
                      ? 'Pairing saved.'
                      : 'Not paired yet — sync is off.',
                  actionLabel: status.paired ? null : 'Pair',
                  onAction: status.paired
                      ? null
                      : () async {
                          // Back out to home, where the pairing form lives.
                          Navigator.of(context).popUntil((r) => r.isFirst);
                        },
                ).entrance(3),
                if (status.isMiui) ...[
                  const SizedBox(height: 22),
                  Text(
                    'Xiaomi setup',
                    style: Theme.of(context).textTheme.titleMedium,
                  ).entrance(4),
                  const SizedBox(height: 4),
                  Text(
                    "We can't check these for you — tick what you've done.",
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Palette.muted),
                  ).entrance(4),
                  const SizedBox(height: 12),
                  MiuiSetupList(
                    actions: widget.loader.actions,
                    flags: status.miuiFlags,
                    onFlagChanged: (flag, value) =>
                        unawaited(_setMiuiFlag(flag, value)),
                  ).entrance(5),
                ],
              ],
            ),
    );
  }
}

/// Flat checklist card with a status glyph: raspberry check when healthy,
/// error-tinted warning otherwise (D9).
class _ChecklistRow extends StatelessWidget {
  const _ChecklistRow({
    required this.ok,
    required this.title,
    required this.detail,
    this.actionLabel,
    this.onAction,
    this.reloadAfterAction,
  });

  final bool ok;
  final String title;
  final String detail;
  final String? actionLabel;
  final Future<void> Function()? onAction;
  final Future<void> Function()? reloadAfterAction;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              ok ? Icons.check_circle : Icons.warning_amber_rounded,
              size: 22,
              color: ok ? Palette.raspberry : Palette.error,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: textTheme.bodySmall?.copyWith(color: Palette.muted),
                  ),
                  if (actionLabel != null)
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () async {
                        await onAction?.call();
                        await reloadAfterAction?.call();
                      },
                      child: Text(actionLabel!),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
