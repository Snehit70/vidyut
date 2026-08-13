/// The four MIUI setup items the app cannot verify (onboarding spec D5);
/// self-reported "I did this" checkboxes persisted in settings storage.
enum MiuiSetupFlag { autostart, battery, lockInRecents, clipboard }

enum AppThemeMode { system, light, dark }

extension AppThemeModeCopy on AppThemeMode {
  String get label => switch (this) {
    AppThemeMode.system => 'System default',
    AppThemeMode.light => 'Light',
    AppThemeMode.dark => 'Dark',
  };

  String get description => switch (this) {
    AppThemeMode.system => 'Follow the phone theme',
    AppThemeMode.light => 'Use Vidyut’s light theme',
    AppThemeMode.dark => 'Use Vidyut’s dark theme',
  };
}

class AppSettings {
  const AppSettings({
    this.themeMode = AppThemeMode.system,
    this.showReceiveNotifications = true,
    this.showPersistentSendNotification = true,
    this.autoPushScreenshots = true,
    this.enableClipboardAutoSend = false,
    this.receiveFiles = true,
    this.fileTransferAlerts = true,
    this.allowMeteredFileTransfers = true,
    this.maxTransferFileBytes = 1024 * 1024 * 1024,
  });

  final AppThemeMode themeMode;
  final bool showReceiveNotifications;
  final bool showPersistentSendNotification;

  /// When on (and full photo access is granted), the service watches for new
  /// screenshots and auto-pushes them. UI to toggle this lands in WP6; the
  /// service reconciles the observer against this flag on every sync.
  final bool autoPushScreenshots;

  /// Opt-in READ_LOGS auto-text mode (read-logs-auto-text D1). Default off and
  /// *effective* only when this is on **and** `READ_LOGS` is granted; every
  /// path degrades to the manual "Send clipboard" flow otherwise. The service
  /// reconciles the auto-send watcher against this flag and the grant on every
  /// sync.
  final bool enableClipboardAutoSend;
  final bool receiveFiles;
  final bool fileTransferAlerts;
  final bool allowMeteredFileTransfers;
  final int maxTransferFileBytes;

  AppSettings copyWith({
    AppThemeMode? themeMode,
    bool? showReceiveNotifications,
    bool? showPersistentSendNotification,
    bool? autoPushScreenshots,
    bool? enableClipboardAutoSend,
    bool? receiveFiles,
    bool? fileTransferAlerts,
    bool? allowMeteredFileTransfers,
    int? maxTransferFileBytes,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      showReceiveNotifications:
          showReceiveNotifications ?? this.showReceiveNotifications,
      showPersistentSendNotification:
          showPersistentSendNotification ?? this.showPersistentSendNotification,
      autoPushScreenshots: autoPushScreenshots ?? this.autoPushScreenshots,
      enableClipboardAutoSend:
          enableClipboardAutoSend ?? this.enableClipboardAutoSend,
      receiveFiles: receiveFiles ?? this.receiveFiles,
      fileTransferAlerts: fileTransferAlerts ?? this.fileTransferAlerts,
      allowMeteredFileTransfers:
          allowMeteredFileTransfers ?? this.allowMeteredFileTransfers,
      maxTransferFileBytes: maxTransferFileBytes ?? this.maxTransferFileBytes,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AppSettings &&
        other.themeMode == themeMode &&
        other.showReceiveNotifications == showReceiveNotifications &&
        other.showPersistentSendNotification ==
            showPersistentSendNotification &&
        other.autoPushScreenshots == autoPushScreenshots &&
        other.enableClipboardAutoSend == enableClipboardAutoSend &&
        other.receiveFiles == receiveFiles &&
        other.fileTransferAlerts == fileTransferAlerts &&
        other.allowMeteredFileTransfers == allowMeteredFileTransfers &&
        other.maxTransferFileBytes == maxTransferFileBytes;
  }

  @override
  int get hashCode => Object.hash(
    themeMode,
    showReceiveNotifications,
    showPersistentSendNotification,
    autoPushScreenshots,
    enableClipboardAutoSend,
    receiveFiles,
    fileTransferAlerts,
    allowMeteredFileTransfers,
    maxTransferFileBytes,
  );
}
