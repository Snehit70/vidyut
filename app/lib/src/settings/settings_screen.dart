import 'dart:async';

import 'package:clipboard_autosend/clipboard_autosend.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:vidyut_files/vidyut_files.dart';

import '../debug/debug_log.dart';
import '../debug/debug_log_screen.dart';
import '../design/palette.dart';
import '../design/widgets.dart';
import '../onboarding/setup_actions.dart';
import '../onboarding/setup_checklist_screen.dart';
import '../update/github_update_checker.dart';
import '../update/apk_installer.dart';
import 'app_settings.dart';
import 'clipboard_autosend_screen.dart';

typedef AppSettingsChanged = Future<void> Function(AppSettings settings);

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

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppSettings _settings = widget.settings;
  int? _issueCount;
  String? _appVersion;
  bool _checkingForUpdates = false;
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
    if (mounted) setState(() => _appVersion = info.version);
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
        backgroundColor: Palette.ground,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
        ),
        title: const Text('Forget this laptop?'),
        content: const Text(
          "Vidyut will delete this pairing. You'll need to pair again — "
          'by QR or manually — to sync with your laptop.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            style: TextButton.styleFrom(foregroundColor: Palette.muted),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Palette.error),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await onForget();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _checkForUpdates() async {
    final checker = widget.updateChecker;
    final currentVersion = _appVersion;
    if (checker == null || currentVersion == null || _checkingForUpdates) {
      return;
    }
    setState(() => _checkingForUpdates = true);
    final result = await checker.check(currentVersion);
    if (!mounted) return;
    setState(() => _checkingForUpdates = false);
    await _showUpdateResultDialog(result);
  }

  Future<void> _showUpdateResultDialog(UpdateCheckResult result) async {
    final String title;
    final String message;
    UpdateAvailable? update;
    switch (result) {
      case UpToDate():
        title = "You're up to date";
        message = 'Vidyut $_appVersion is the latest version.';
      case UpdateAvailable():
        title = 'Update available';
        message = result.releaseNotes.trim().isEmpty
            ? 'Vidyut ${result.version} is available.'
            : 'Vidyut ${result.version} is available.\n\n${result.releaseNotes.trim()}';
        update = result;
      case MissingAsset():
        title = 'Update available';
        message =
            'Vidyut ${result.tagName} is available, but no compatible APK was '
            'attached to the release yet.';
      case NoReleaseFound():
        title = 'No releases yet';
        message = "This app hasn't published a GitHub release yet.";
      case RateLimited():
        title = "Can't check right now";
        message = "GitHub's rate limit was hit. Try again in a few minutes.";
      case UpdateCheckOffline():
        title = "Can't check right now";
        message =
            'Vidyut could not reach GitHub. Check your connection and try again.';
      case MalformedMetadata():
        title = "Can't check right now";
        message = 'GitHub returned unexpected release data. Try again later.';
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Palette.ground,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
        ),
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(foregroundColor: Palette.muted),
            child: Text(update == null ? 'Close' : 'Install later'),
          ),
          if (update != null)
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                unawaited(_downloadAndInstall(update!));
              },
              child: const Text('Download and install'),
            ),
        ],
      ),
    );
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
    var step = 0;
    int next() => step++;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const _SectionHeader('Appearance'),
          Card(
            child: ListTile(
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
          ).entrance(next()),
          // Master switch, first and alone: it governs all syncing (ADR 0006).
          Card(
            child: SwitchListTile(
              contentPadding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
              value: _settings.showPersistentSendNotification,
              title: const Text('Sync with laptop'),
              subtitle: const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'Keeps the laptop link alive for clipboard, screenshots, '
                  'and receive — shows a persistent notification. Off '
                  'disconnects and stops all syncing.',
                ),
              ),
              onChanged: (value) => _updateSettings(
                _settings.copyWith(showPersistentSendNotification: value),
              ),
            ),
          ).entrance(next()),
          const _SectionHeader('Files'),
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: SwitchListTile(
              contentPadding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
              value: _settings.receiveFiles,
              title: const Text('Receive files'),
              subtitle: const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'Automatically accept files from your paired laptop.',
                ),
              ),
              onChanged: (value) =>
                  _updateSettings(_settings.copyWith(receiveFiles: value)),
            ),
          ).entrance(next()),
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              contentPadding: const EdgeInsets.fromLTRB(20, 4, 16, 4),
              title: const Text('Save received files to'),
              subtitle: Text(_filesDestination),
              trailing: const Icon(Icons.folder_outlined),
              onTap: widget.files == null
                  ? null
                  : () => unawaited(_chooseFilesDestination()),
            ),
          ).entrance(next()),
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              contentPadding: const EdgeInsets.fromLTRB(20, 4, 16, 4),
              title: const Text('Maximum file size'),
              subtitle: Text(_transferSize(_settings.maxTransferFileBytes)),
              trailing: const Icon(Icons.chevron_right, color: Palette.muted),
              onTap: _chooseMaxTransferSize,
            ),
          ).entrance(next()),
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: SwitchListTile(
              contentPadding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
              value: _settings.allowMeteredFileTransfers,
              title: const Text('Allow metered Wi-Fi'),
              subtitle: const Text(
                'Transfer files on hotspots and metered Wi-Fi.',
              ),
              onChanged: (value) => _updateSettings(
                _settings.copyWith(allowMeteredFileTransfers: value),
              ),
            ),
          ).entrance(next()),
          const _SectionHeader('Sync'),
          Card(
            child: SwitchListTile(
              contentPadding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
              value: _settings.autoPushScreenshots,
              title: const Text('Auto-send screenshots'),
              subtitle: const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'Push new screenshots to the laptop as you take them. '
                  'Needs full photos access.',
                ),
              ),
              onChanged: (value) => _updateSettings(
                _settings.copyWith(autoPushScreenshots: value),
              ),
            ),
          ).entrance(next()),
          Card(
            margin: const EdgeInsets.only(top: 12),
            child: SwitchListTile(
              contentPadding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
              value: _settings.fileTransferAlerts,
              title: const Text('File transfer alerts'),
              subtitle: const Text(
                'Show completion and failure alerts for file batches.',
              ),
              onChanged: (value) => _updateSettings(
                _settings.copyWith(fileTransferAlerts: value),
              ),
            ),
          ).entrance(next()),
          const _SectionHeader('Notifications'),
          Card(
            child: SwitchListTile(
              contentPadding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
              value: _settings.showReceiveNotifications,
              title: const Text('Notify when laptop payloads arrive'),
              subtitle: const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'Show a receipt when something arrives from the laptop. '
                  'Delivery-failure notices always show.',
                ),
              ),
              onChanged: (value) => _updateSettings(
                _settings.copyWith(showReceiveNotifications: value),
              ),
            ),
          ).entrance(next()),
          const _SectionHeader('Setup'),
          if (widget.setupLoader != null)
            Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: ListTile(
                contentPadding: const EdgeInsets.fromLTRB(20, 4, 16, 4),
                title: const Text('Setup status'),
                subtitle: const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text('Permissions, battery, and Xiaomi switches.'),
                ),
                trailing: _SummaryChip(issueCount: _issueCount),
                onTap: () => unawaited(_openChecklist()),
              ),
            ).entrance(next()),
          if (widget.clipboardAutoSendWatcher != null)
            Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: ListTile(
                contentPadding: const EdgeInsets.fromLTRB(20, 4, 16, 4),
                title: const Text('Advanced'),
                subtitle: const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    'Clipboard auto-send for text — one-time computer setup, '
                    'not for every phone.',
                  ),
                ),
                trailing: const Icon(Icons.chevron_right, color: Palette.muted),
                onTap: () => unawaited(_openClipboardAutoSend()),
              ),
            ).entrance(next()),
          if (widget.debugLog != null)
            Card(
              child: ListTile(
                contentPadding: const EdgeInsets.fromLTRB(20, 4, 16, 4),
                title: const Text('Debug log'),
                subtitle: const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text('Timestamped connection and payload events.'),
                ),
                trailing: const Icon(Icons.chevron_right, color: Palette.muted),
                onTap: () => unawaited(_openDebugLog()),
              ),
            ).entrance(next()),
          if (widget.updateChecker != null) ...[
            const _SectionHeader('About'),
            Card(
              child: ListTile(
                contentPadding: const EdgeInsets.fromLTRB(20, 4, 16, 4),
                title: const Text('Check for updates'),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _appVersion == null
                        ? 'Loading version…'
                        : 'Version $_appVersion',
                  ),
                ),
                trailing: _checkingForUpdates
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.chevron_right, color: Palette.muted),
                onTap: _checkingForUpdates
                    ? null
                    : () => unawaited(_checkForUpdates()),
              ),
            ).entrance(next()),
          ],
          if (widget.paired && widget.onForgetPairing != null) ...[
            const _SectionHeader('Danger zone'),
            Card(
              child: ListTile(
                contentPadding: const EdgeInsets.fromLTRB(20, 4, 16, 4),
                leading: const Icon(Icons.link_off, color: Palette.error),
                title: const Text(
                  'Forget this laptop',
                  style: TextStyle(color: Palette.error),
                ),
                subtitle: const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text('Delete this pairing and stop syncing.'),
                ),
                onTap: () => unawaited(_confirmForget()),
              ),
            ).entrance(next()),
          ],
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

/// Muted section label — the only typographic hierarchy in the flat UI
/// (ADR 0006). Kept low-key so the calm surface language holds.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 12),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.labelMedium?.copyWith(color: Palette.muted),
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
      return const Icon(Icons.check_circle, color: Palette.raspberry);
    }
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Palette.petal,
        borderRadius: BorderRadius.all(Radius.circular(999)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(
          count == 1 ? '1 issue' : '$count issues',
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(color: Palette.raspberry),
        ),
      ),
    );
  }
}
