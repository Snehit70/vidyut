import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vidyut_clipboard/vidyut_clipboard.dart';

import '../design/widgets.dart';
import 'app_settings.dart';
import 'settings_screen.dart';

/// Settings → Verification codes (ADR 0025). The switch alone does nothing
/// until Android's notification access is granted, so the screen shows the
/// live access state and a button to the system switch.
class VerificationCodesScreen extends StatefulWidget {
  const VerificationCodesScreen({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.notifications,
  });

  final AppSettings settings;
  final AppSettingsChanged onChanged;

  /// Source of the live access state. Re-checked on each return to the app,
  /// since access is granted in system settings.
  final PostedNotifications notifications;

  @override
  State<VerificationCodesScreen> createState() =>
      _VerificationCodesScreenState();
}

class _VerificationCodesScreenState extends State<VerificationCodesScreen>
    with WidgetsBindingObserver {
  late AppSettings _settings = widget.settings;
  bool? _access;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshAccess());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refreshAccess());
  }

  Future<void> _refreshAccess() async {
    final access = await widget.notifications.hasAccess();
    if (!mounted) return;
    final granted = access && _access == false;
    setState(() => _access = access);
    // The service checks access only when it syncs; resave so it starts
    // listening now instead of on the next reconnect.
    if (granted && _settings.forwardVerificationCodes) {
      await widget.onChanged(_settings);
    }
  }

  Future<void> _updateSettings(AppSettings next) async {
    setState(() => _settings = next);
    await widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Verification codes')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'When a notification on this phone carries a one-time code, '
                'Vidyut copies the code to the laptop clipboard so you can '
                'paste it straight into the login page.',
              ),
            ),
          ).entrance(0),
          const SizedBox(height: 14),
          Card(
            child: SwitchListTile(
              contentPadding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
              value: _settings.forwardVerificationCodes,
              title: const Text('Send codes to the laptop'),
              subtitle: const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('Needs notification access.'),
              ),
              onChanged: (value) => _updateSettings(
                _settings.copyWith(forwardVerificationCodes: value),
              ),
            ),
          ).entrance(1),
          const SizedBox(height: 14),
          _AccessCard(
            access: _access,
            onAllow: widget.notifications.openAccessSettings,
          ).entrance(2),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                'Vidyut checks only notifications that contain a number, and '
                'only while this is on. It sends the code alone, encrypted, '
                'and keeps no copy of the notification. Codes are spotted by '
                'English words such as "code", "OTP" or "verify". Pausing '
                'clipboard sync holds codes too.',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          ).entrance(3),
        ],
      ),
    );
  }
}

class _AccessCard extends StatelessWidget {
  const _AccessCard({required this.access, required this.onAllow});

  final bool? access;
  final Future<void> Function() onAllow;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color, text) = switch (access) {
      null => (
        Icons.hourglass_empty,
        scheme.onSurfaceVariant,
        'Checking notification access...',
      ),
      true => (
        Icons.check_circle,
        scheme.primary,
        'Notification access allowed.',
      ),
      false => (
        Icons.error_outline,
        scheme.error,
        'Notification access is off.',
      ),
    };
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(20, 4, 16, 4),
        leading: Icon(icon, color: color),
        title: Text(text),
        trailing: access == false
            ? TextButton(
                onPressed: () => unawaited(onAllow()),
                child: const Text('Allow'),
              )
            : null,
      ),
    );
  }
}
