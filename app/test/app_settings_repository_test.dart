import 'package:flutter_test/flutter_test.dart';
import 'package:vidyut/src/settings/app_settings.dart';
import 'package:vidyut/src/settings/app_settings_repository.dart';
import 'package:vidyut/src/settings/clipboard_pause.dart';

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

  test('round-trips the clipboard pause', () async {
    final storage = MemoryAppSettingsStorage();
    final repository = AppSettingsRepository(storage);
    final until = DateTime.fromMillisecondsSinceEpoch(1700000000000);

    expect(
      await repository.loadClipboardPause(),
      const PhoneClipboardPause.off(),
    );
    for (final pause in [
      PhoneClipboardPause.until(until),
      const PhoneClipboardPause.untilResumed(),
      const PhoneClipboardPause.off(),
    ]) {
      await repository.saveClipboardPause(pause);
      expect(await AppSettingsRepository(storage).loadClipboardPause(), pause);
    }
  });

  test('a timed clipboard pause is over at its deadline', () {
    final until = DateTime(2026, 10, 23, 14, 30);
    final pause = PhoneClipboardPause.until(until);

    expect(pause.activeAt(until.subtract(const Duration(seconds: 1))), isTrue);
    expect(pause.activeAt(until), isFalse);
    expect(const PhoneClipboardPause.untilResumed().activeAt(until), isTrue);
  });
}
