import 'dart:async';

import 'package:clipboard_autosend/clipboard_autosend.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/palette.dart';
import '../design/widgets.dart';
import 'app_settings.dart';
import 'settings_screen.dart';

/// The exact one-time adb block from read-logs-auto-text D6, for the app's
/// `applicationId`. `READ_LOGS` is grantable only via adb (not a runtime
/// dialog), so these commands are the whole flow — there is no in-app request
/// button. `force-stop` makes the app re-read its now-granted permission.
const clipboardAutoSendAdbCommands =
    'adb -d shell pm grant dev.snehit.vidyut.vidyut android.permission.READ_LOGS\n'
    'adb -d shell appops set dev.snehit.vidyut.vidyut SYSTEM_ALERT_WINDOW allow\n'
    'adb -d shell am force-stop dev.snehit.vidyut.vidyut';

/// Advanced → Clipboard auto-send (read-logs-auto-text D6). Gated behind the
/// "advanced" affordance in Settings so a normal user never lands on adb
/// instructions. Shows the honest description, the toggle, the live grant
/// state, the copy-paste adb block, and the MIUI caveat.
class ClipboardAutoSendScreen extends StatefulWidget {
  const ClipboardAutoSendScreen({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.watcher,
  });

  final AppSettings settings;
  final AppSettingsChanged onChanged;

  /// Source of the live `READ_LOGS` grant state. Re-checked on each
  /// return-to-foreground since the grant is applied externally by adb.
  final ClipboardAutoSendWatcher watcher;

  @override
  State<ClipboardAutoSendScreen> createState() =>
      _ClipboardAutoSendScreenState();
}

class _ClipboardAutoSendScreenState extends State<ClipboardAutoSendScreen>
    with WidgetsBindingObserver {
  late AppSettings _settings = widget.settings;
  bool? _granted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshGrant());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The adb block runs on the computer while the app is backgrounded; re-check
    // when the user comes back so the grant line reflects it (D6).
    if (state == AppLifecycleState.resumed) unawaited(_refreshGrant());
  }

  Future<void> _refreshGrant() async {
    final granted = await widget.watcher.hasReadLogsPermission();
    if (mounted) setState(() => _granted = granted);
  }

  Future<void> _updateSettings(AppSettings next) async {
    setState(() => _settings = next);
    await widget.onChanged(next);
  }

  Future<void> _copyCommands() async {
    await Clipboard.setData(
      const ClipboardData(text: clipboardAutoSendAdbCommands),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Commands copied.')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Clipboard auto-send')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'Automatic send-on-copy for text. Requires a one-time computer '
                'setup and does not work on every phone.',
              ),
            ),
          ).entrance(0),
          const SizedBox(height: 14),
          Card(
            child: SwitchListTile(
              contentPadding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
              value: _settings.enableClipboardAutoSend,
              title: const Text('Auto-send copied text'),
              subtitle: const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'Send text to the laptop the instant you copy it. Needs the '
                  'setup below.',
                ),
              ),
              onChanged: (value) => _updateSettings(
                _settings.copyWith(enableClipboardAutoSend: value),
              ),
            ),
          ).entrance(1),
          const SizedBox(height: 14),
          _GrantStateCard(granted: _granted).entrance(2),
          const SizedBox(height: 14),
          _AdbBlockCard(onCopy: _copyCommands).entrance(3),
          const SizedBox(height: 14),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'On Xiaomi (MIUI/HyperOS) this may still not work until you also '
                'enable "Display pop-up windows while running in the background" '
                'for Vidyut in the app\'s permission settings.',
                style: TextStyle(color: Palette.muted),
              ),
            ),
          ).entrance(4),
        ],
      ),
    );
  }
}

/// Live grant line (D6): the single source of truth for whether auto-send can
/// actually work. No path throws a user-visible error for a missing grant.
class _GrantStateCard extends StatelessWidget {
  const _GrantStateCard({required this.granted});

  final bool? granted;

  @override
  Widget build(BuildContext context) {
    final granted = this.granted;
    final (icon, color, text) = switch (granted) {
      null => (Icons.hourglass_empty, Palette.muted, 'Checking permission...'),
      true => (
        Icons.check_circle,
        Palette.raspberry,
        'READ_LOGS granted — auto-send can run.',
      ),
      false => (
        Icons.error_outline,
        Palette.error,
        'READ_LOGS not granted — run the setup below.',
      ),
    };
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(20, 4, 16, 4),
        leading: Icon(icon, color: color),
        title: Text(text),
      ),
    );
  }
}

class _AdbBlockCard extends StatelessWidget {
  const _AdbBlockCard({required this.onCopy});

  final Future<void> Function() onCopy;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'One-time setup',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                TextButton.icon(
                  onPressed: () => onCopy(),
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Connect the phone by USB with debugging on, then run these on the '
              'computer:',
              style: TextStyle(color: Palette.muted),
            ),
            const SizedBox(height: 12),
            DecoratedBox(
              decoration: BoxDecoration(
                color: Palette.mist,
                borderRadius: const BorderRadius.all(Radius.circular(12)),
                border: Border.all(color: Palette.hairline),
              ),
              child: const Padding(
                padding: EdgeInsets.all(14),
                child: SelectableText(
                  clipboardAutoSendAdbCommands,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 12.5),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
