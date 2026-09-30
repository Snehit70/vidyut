import 'dart:async';

import 'package:clipboard_autosend/clipboard_autosend.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:vidyut_files/vidyut_files.dart';

import '../debug/debug_log.dart';
import '../debug/debug_log_screen.dart';
import '../onboarding/setup_actions.dart';
import '../onboarding/setup_checklist_screen.dart';
import '../update/github_update_checker.dart';
import '../update/apk_installer.dart';
import 'app_settings.dart';
import 'clipboard_autosend_screen.dart';

typedef AppSettingsChanged = Future<void> Function(AppSettings settings);

const _rowPadding = EdgeInsets.fromLTRB(16, 8, 12, 8);

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.onChanged,
    this.setupLoader,
    this.clipboardAutoSendWatcher,
    this.debugLog,
    this.paired = false,
    this.onForgetPairing,
    this.updateChecker,
    this.apkInstaller,
    this.files,
    this.pairedDeviceName,
    this.pairedDeviceAddress,
  });

  final AppSettings settings;
  final AppSettingsChanged onChanged;

  /// Feeds the "Setup status" row and its summary chip (onboarding spec D8);
  /// the row is hidden when null (widget tests without platform channels).
  final SetupStatusLoader? setupLoader;

  /// Backs the Advanced → Clipboard auto-send screen (read-logs-auto-text D6);
  /// the advanced row is hidden when null (widget tests without channels).
  final ClipboardAutoSendWatcher? clipboardAutoSendWatcher;

  /// The in-app debug log, opened from the Setup section (ADR 0004); the row
  /// is hidden when null.
  final DebugLog? debugLog;

  /// Whether a pairing exists — gates the "Forget this laptop" danger row
  /// (ADR 0005).
  final bool paired;

  /// Deletes the saved pairing; run behind a confirmation in the danger zone.
  final Future<void> Function()? onForgetPairing;

  /// Backs the About → "Check for updates" row; the row is hidden when null
  /// (widget tests without network access).
  final GithubUpdateChecker? updateChecker;

  /// Installs verified updates; injectable so widget tests can avoid platform
  /// channels and network access.
  final ApkInstaller? apkInstaller;
  final VidyutFiles? files;

  /// Display name for the paired laptop in the Connection section. The
  /// section omits this row when [paired] is false.
  final String? pairedDeviceName;

  /// Host and port for the paired laptop in the Connection section. The
  /// section omits this row when [paired] is false.
  final String? pairedDeviceAddress;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppSettings _settings = widget.settings;
  int? _issueCount;
  String? _appVersion;
  bool _checkingForUpdates = false;

  /// Held rather than shown once in a dialog, so the About section can state
  /// what the check found the moment the screen opens.
  UpdateCheckResult? _updateState;
  String _filesDestination = 'Downloads/Vidyut';
  late final ApkInstaller _apkInstaller = widget.apkInstaller ?? ApkInstaller();

  @override
  void initState() {
    super.initState();
    unawaited(_loadIssueCount());
    unawaited(_loadAppVersion());
    unawaited(_loadFilesDestination());
  }

  Future<void> _loadFilesDestination() async {
    final files = widget.files;
    if (files == null) return;
    final label = await files.destinationLabel();
    if (mounted) setState(() => _filesDestination = label);
  }

  Future<void> _chooseFilesDestination() async {
    final label = await widget.files?.chooseDestination();
    if (label != null && mounted) setState(() => _filesDestination = label);
  }

  Future<void> _loadAppVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() => _appVersion = info.version);
    // About reports update state whether or not anyone asks, so the check runs
    // on open. The trailing Check action is a retry, not the first source.
    await _refreshUpdateState();
  }

  Future<void> _loadIssueCount() async {
    final loader = widget.setupLoader;
    if (loader == null) return;
    final status = await loader.load();
    if (mounted) setState(() => _issueCount = status.issueCount);
  }

  Future<void> _openChecklist() async {
    final loader = widget.setupLoader;
    if (loader == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SetupChecklistScreen(loader: loader)),
    );
    await _loadIssueCount();
  }

  Future<void> _openClipboardAutoSend() async {
    final watcher = widget.clipboardAutoSendWatcher;
    if (watcher == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ClipboardAutoSendScreen(
          settings: _settings,
          onChanged: _updateSettings,
          watcher: watcher,
        ),
      ),
    );
  }

  Future<void> _openDebugLog() async {
    final log = widget.debugLog;
    if (log == null) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => DebugLogScreen(log: log)));
  }

  Future<void> _chooseMaxTransferSize() async {
    const options = <int, String>{
      100 * 1024 * 1024: '100 MB',
      500 * 1024 * 1024: '500 MB',
      1024 * 1024 * 1024: '1 GB',
      5 * 1024 * 1024 * 1024: '5 GB',
    };
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: RadioGroup<int>(
          groupValue: _settings.maxTransferFileBytes,
          onChanged: (value) => Navigator.pop(context, value),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final option in options.entries)
                RadioListTile<int>(
                  value: option.key,
                  title: Text(option.value),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected != null) {
      await _updateSettings(_settings.copyWith(maxTransferFileBytes: selected));
    }
  }

  Future<void> _chooseThemeMode() async {
    final selected = await showModalBottomSheet<AppThemeMode>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: RadioGroup<AppThemeMode>(
          groupValue: _settings.themeMode,
          onChanged: (value) => Navigator.pop(context, value),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final mode in AppThemeMode.values)
                RadioListTile<AppThemeMode>(
                  value: mode,
                  title: Text(mode.label),
                  subtitle: Text(mode.description),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected != null) {
      await _updateSettings(_settings.copyWith(themeMode: selected));
    }
  }

  Future<void> _confirmForget() async {
    final onForget = widget.onForgetPairing;
    if (onForget == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forget this laptop?'),
        content: const Text(
          "Vidyut will delete this pairing. You'll need to pair again — "
          'by QR or manually — to sync with your laptop.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await onForget();
    if (mounted) Navigator.of(context).pop();
  }

  /// Resolves the update check and keeps the outcome in [_updateState], which
  /// the About section renders in place. There is no result dialog any more:
  /// the answer belongs on the surface that asked the question, where it stays
  /// readable, rather than in a modal the reader dismisses and forgets.
  Future<void> _refreshUpdateState() async {
    final checker = widget.updateChecker;
    final currentVersion = _appVersion;
    if (checker == null || currentVersion == null || _checkingForUpdates) {
      return;
    }
    setState(() => _checkingForUpdates = true);
    final result = await checker.check(currentVersion);
    if (!mounted) return;
    setState(() {
      _updateState = result;
      _checkingForUpdates = false;
    });
  }

  Future<void> _downloadAndInstall(UpdateAvailable update) async {
    if (!await _apkInstaller.canInstall()) {
      if (!mounted) return;
      final open = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Allow Vidyut to install updates'),
          content: const Text(
            'Android needs a one-time permission before Vidyut can open its '
            'verified APK in the system installer.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Install later'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Open permission settings'),
            ),
          ],
        ),
      );
      if (open == true) await _apkInstaller.openInstallSettings();
      return;
    }

    final progress = ValueNotifier<double>(0);
    if (!mounted) return;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => PopScope(
          canPop: false,
          child: AlertDialog(
            title: Text('Downloading Vidyut ${update.version}'),
            content: ValueListenableBuilder<double>(
              valueListenable: progress,
              builder: (context, value, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LinearProgressIndicator(value: value == 0 ? null : value),
                  const SizedBox(height: 12),
                  Text(
                    value == 0
                        ? 'Starting download…'
                        : '${(value * 100).round()}%',
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'The APK will be verified before Android opens it.',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final result = await _apkInstaller.download(
      update,
      onProgress: (value) => progress.value = value,
    );
    progress.dispose();
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    switch (result) {
      case ApkReady():
        try {
          await _apkInstaller.install(result.path);
        } on Object catch (error) {
          if (!mounted) return;
          await _showInstallError(error.toString());
        }
      case ApkDownloadFailed():
        await _showInstallError(result.message);
    }
  }

  Future<void> _showInstallError(String message) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Update could not be installed'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pairedDevice = widget.paired
        ? ListTile(
            contentPadding: _rowPadding,
            leading: const Icon(Icons.laptop_mac_outlined),
            title: Text(widget.pairedDeviceName ?? 'Paired laptop'),
            subtitle: Text(widget.pairedDeviceAddress ?? 'Connected locally'),
          )
        : null;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _SettingsSection(
            title: 'Appearance',
            children: [
              ListTile(
                contentPadding: _rowPadding,
                leading: Icon(switch (_settings.themeMode) {
                  AppThemeMode.system => Icons.brightness_auto_outlined,
                  AppThemeMode.light => Icons.light_mode_outlined,
                  AppThemeMode.dark => Icons.dark_mode_outlined,
                }),
                title: const Text('Theme'),
                subtitle: Text(_settings.themeMode.label),
                trailing: const Icon(Icons.chevron_right),
                onTap: _chooseThemeMode,
              ),
            ],
          ),
          _SettingsSection(
            title: 'Connection',
            children: [
              // Master switch: it governs all syncing (ADR 0006).
              SwitchListTile(
                contentPadding: _rowPadding,
                value: _settings.showPersistentSendNotification,
                title: const Text('Sync with laptop'),
                subtitle: const Text(
                  'Keeps clipboard, screenshot, and receive sync active.',
                ),
                onChanged: (value) => _updateSettings(
                  _settings.copyWith(showPersistentSendNotification: value),
                ),
              ),
              ?pairedDevice,
            ],
          ),
          _SettingsSection(
            title: 'Clipboard & screenshots',
            children: [
              SwitchListTile(
                contentPadding: _rowPadding,
                value: _settings.autoPushScreenshots,
                title: const Text('Auto-send screenshots'),
                subtitle: const Text(
                  'Send new screenshots to the laptop automatically.',
                ),
                onChanged: (value) => _updateSettings(
                  _settings.copyWith(autoPushScreenshots: value),
                ),
              ),
              if (widget.clipboardAutoSendWatcher != null)
                ListTile(
                  contentPadding: _rowPadding,
                  title: const Text('Clipboard auto-send'),
                  subtitle: const Text(
                    'Optional one-time computer setup for automatic text sharing.',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => unawaited(_openClipboardAutoSend()),
                ),
            ],
          ),
          _SettingsSection(
            title: 'Files',
            children: [
              SwitchListTile(
                contentPadding: _rowPadding,
                value: _settings.receiveFiles,
                title: const Text('Receive files'),
                subtitle: const Text(
                  'Automatically accept files from your paired laptop.',
                ),
                onChanged: (value) =>
                    _updateSettings(_settings.copyWith(receiveFiles: value)),
              ),
              ListTile(
                contentPadding: _rowPadding,
                title: const Text('Save received files to'),
                subtitle: Text(_filesDestination),
                trailing: const Icon(Icons.folder_outlined),
                onTap: widget.files == null
                    ? null
                    : () => unawaited(_chooseFilesDestination()),
              ),
              ListTile(
                contentPadding: _rowPadding,
                title: const Text('Maximum file size'),
                subtitle: Text(_transferSize(_settings.maxTransferFileBytes)),
                trailing: const Icon(Icons.chevron_right),
                onTap: _chooseMaxTransferSize,
              ),
              SwitchListTile(
                contentPadding: _rowPadding,
                value: _settings.allowMeteredFileTransfers,
                title: const Text('Allow metered Wi-Fi'),
                subtitle: const Text(
                  'Transfer files on hotspots and metered Wi-Fi.',
                ),
                onChanged: (value) => _updateSettings(
                  _settings.copyWith(allowMeteredFileTransfers: value),
                ),
              ),
              SwitchListTile(
                contentPadding: _rowPadding,
                value: _settings.fileTransferAlerts,
                title: const Text('File transfer alerts'),
                subtitle: const Text(
                  'Show completion and failure alerts for file batches.',
                ),
                onChanged: (value) => _updateSettings(
                  _settings.copyWith(fileTransferAlerts: value),
                ),
              ),
            ],
          ),
          _SettingsSection(
            title: 'Notifications',
            children: [
              SwitchListTile(
                contentPadding: _rowPadding,
                value: _settings.showReceiveNotifications,
                title: const Text('Notify when laptop payloads arrive'),
                subtitle: const Text(
                  'Show a receipt when something arrives from the laptop.',
                ),
                onChanged: (value) => _updateSettings(
                  _settings.copyWith(showReceiveNotifications: value),
                ),
              ),
            ],
          ),
          _SettingsSection(
            title: 'Troubleshooting',
            children: [
              if (widget.setupLoader != null)
                ListTile(
                  contentPadding: _rowPadding,
                  title: const Text('Setup status'),
                  subtitle: const Text(
                    'Permissions, battery, and Xiaomi switches.',
                  ),
                  trailing: _SummaryChip(issueCount: _issueCount),
                  onTap: () => unawaited(_openChecklist()),
                ),
              if (widget.debugLog != null)
                ListTile(
                  contentPadding: _rowPadding,
                  title: const Text('Debug log'),
                  subtitle: const Text(
                    'Timestamped connection and payload events.',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => unawaited(_openDebugLog()),
                ),
            ],
          ),
          if (widget.updateChecker != null)
            _SettingsSection(
              title: 'About',
              children: [
                _AboutMasthead(
                  installedVersion: _appVersion,
                  checking: _checkingForUpdates,
                  onCheck: () => unawaited(_refreshUpdateState()),
                ),
                // The outcome only appears once there is one, so the section is
                // never split by a divider above an empty row.
                if (_updateState case final state?)
                  _AboutRelease(
                    state: state,
                    installedVersion: _appVersion,
                    onInstall: (update) =>
                        unawaited(_downloadAndInstall(update)),
                  ),
              ],
            ),
          if (widget.paired && widget.onForgetPairing != null)
            _SettingsSection(
              title: 'Danger zone',
              children: [
                ListTile(
                  contentPadding: _rowPadding,
                  leading: Icon(
                    Icons.link_off,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  title: Text(
                    'Forget this laptop',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  subtitle: const Text('Delete this pairing and stop syncing.'),
                  onTap: () => unawaited(_confirmForget()),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _updateSettings(AppSettings next) async {
    setState(() => _settings = next);
    await widget.onChanged(next);
  }
}

String _transferSize(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${bytes ~/ (1024 * 1024 * 1024)} GB';
  }
  return '${bytes ~/ (1024 * 1024)} MB';
}

/// About masthead: who this is and which build is running, with the check
/// demoted to a quiet trailing action.
///
/// The arrangement puts identity above state on purpose. A lone "Check for
/// updates" row tells the reader nothing until it is tapped, and once tapped it
/// answers in a dialog they dismiss and forget. Here the section is already
/// worth reading on open, and Check is a retry rather than the only way in.
class _AboutMasthead extends StatelessWidget {
  const _AboutMasthead({
    required this.installedVersion,
    required this.checking,
    required this.onCheck,
  });

  final String? installedVersion;
  final bool checking;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Padding(
              padding: const EdgeInsets.all(7),
              child: Icon(
                Icons.swap_horiz,
                size: 18,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Vidyut', style: theme.textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(
                  // "Installed" separates the running build from the latest
                  // published one, which the release row below may contradict.
                  installedVersion == null
                      ? 'Installed build unavailable'
                      : 'Installed $installedVersion',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (checking)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            TextButton(onPressed: onCheck, child: const Text('Check')),
        ],
      ),
    );
  }
}

/// One row stating what the update check found.
///
/// Every outcome gets a sentence. A bare version number does not say whether
/// the reader has to do anything, and colour alone does not reach everyone, so
/// the consequence is written out and the action appears only when there is
/// something to act on.
class _AboutRelease extends StatelessWidget {
  const _AboutRelease({
    required this.state,
    required this.installedVersion,
    required this.onInstall,
  });

  final UpdateCheckResult state;
  final String? installedVersion;
  final ValueChanged<UpdateAvailable> onInstall;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return switch (state) {
      UpToDate() => _sentence(
        context,
        icon: Icons.check_circle_outline,
        color: theme.colorScheme.primary,
        title: 'Up to date',
        detail: installedVersion == null
            ? 'Vidyut is on the latest published build.'
            : 'Vidyut $installedVersion is the latest published build.',
      ),
      final UpdateAvailable update => _available(context, update),
      MissingAsset(:final tagName) => _sentence(
        context,
        icon: Icons.info_outline,
        color: theme.colorScheme.onSurfaceVariant,
        title: 'Latest release $tagName',
        detail:
            'That release has no installable file attached yet, so Vidyut '
            'cannot offer it. Use Check to try again.',
      ),
      NoReleaseFound() => _sentence(
        context,
        icon: Icons.info_outline,
        color: theme.colorScheme.onSurfaceVariant,
        title: 'No releases yet',
        detail: 'Vidyut has not published a GitHub release yet.',
      ),
      RateLimited() => _sentence(
        context,
        icon: Icons.cloud_off_outlined,
        color: theme.colorScheme.onSurfaceVariant,
        title: 'Cannot check right now',
        detail:
            "GitHub's rate limit was reached. Use Check to try again in a few "
            'minutes.',
      ),
      UpdateCheckOffline() => _sentence(
        context,
        icon: Icons.wifi_off_outlined,
        color: theme.colorScheme.onSurfaceVariant,
        title: 'Cannot check right now',
        detail:
            'Vidyut could not reach GitHub. Check the connection, then use '
            'Check to try again.',
      ),
      MalformedMetadata() => _sentence(
        context,
        icon: Icons.help_outline,
        color: theme.colorScheme.onSurfaceVariant,
        title: 'Cannot check right now',
        detail:
            'GitHub returned release data Vidyut did not expect. Use Check to '
            'try again later.',
      ),
    };
  }

  Widget _sentence(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String title,
    required String detail,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // The install action is here because an update was found, not because the row
  // exists. A button that is always present and usually inert is worse than no
  // button, because it never says which state Vidyut is actually in.
  Widget _available(BuildContext context, UpdateAvailable update) {
    final theme = Theme.of(context);
    final notes = update.releaseNotes.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.upgrade, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Update available',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              Text(
                update.version.toString(),
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Vidyut ${update.version} is available.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              notes,
              // Release notes are unbounded. Clamp so one long changelog cannot
              // push the rest of Settings off the screen.
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonal(
              onPressed: () => onInstall(update),
              child: const Text('Download and install'),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(title),
        Material(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var index = 0; index < children.length; index++) ...[
                if (index > 0)
                  Divider(
                    height: 1,
                    thickness: 1,
                    indent: 16,
                    endIndent: 16,
                    color: scheme.outlineVariant,
                  ),
                children[index],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Muted section label that establishes hierarchy without becoming another
/// container.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 12),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Green check when all-clear, "N issues" pill otherwise (D8).
class _SummaryChip extends StatelessWidget {
  const _SummaryChip({required this.issueCount});

  final int? issueCount;

  @override
  Widget build(BuildContext context) {
    final count = issueCount;
    if (count == null) return const SizedBox.shrink();
    if (count == 0) {
      return Icon(
        Icons.check_circle,
        color: Theme.of(context).colorScheme.primary,
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.all(Radius.circular(999)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(
          count == 1 ? '1 issue' : '$count issues',
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        ),
      ),
    );
  }
}
