import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/settings/app_settings.dart';
import 'package:vidyut/src/settings/app_settings_repository.dart';

void main() {
  test('loads the default notification settings on first run', () async {
    final repository = AppSettingsRepository(MemoryAppSettingsStorage());

    expect(
      await repository.load(),
      const AppSettings(
        showReceiveNotifications: true,
        showPersistentSendNotification: true,
        autoPushScreenshots: true,
        // Opt-in READ_LOGS auto-text mode is default off (D1).
        enableClipboardAutoSend: false,
      ),
    );
  });

  test('persists updated notification settings', () async {
    final storage = MemoryAppSettingsStorage();
    final repository = AppSettingsRepository(storage);
    const settings = AppSettings(
      showReceiveNotifications: false,
      showPersistentSendNotification: false,
      autoPushScreenshots: false,
      enableClipboardAutoSend: true,
    );

    await repository.save(settings);

    expect(await AppSettingsRepository(storage).load(), settings);
  });

  test('persists the selected theme mode', () async {
    final storage = MemoryAppSettingsStorage();
    final repository = AppSettingsRepository(storage);

    await repository.save(const AppSettings(themeMode: AppThemeMode.dark));

    expect(
      (await AppSettingsRepository(storage).load()).themeMode,
      AppThemeMode.dark,
    );
  });

  test('tracks the one-time MIUI clipboard hint flag', () async {
    final storage = MemoryAppSettingsStorage();
    final repository = AppSettingsRepository(storage);

    expect(await repository.miuiClipboardHintShown(), isFalse);

    await repository.markMiuiClipboardHintShown();

    expect(await repository.miuiClipboardHintShown(), isTrue);
    expect(
      await AppSettingsRepository(storage).miuiClipboardHintShown(),
      isTrue,
    );
  });
}
