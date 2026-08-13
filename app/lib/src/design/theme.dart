import 'package:flutter/material.dart';

import 'palette.dart';

final ThemeData _lightTheme = _buildVidyutTheme(Brightness.light);
final ThemeData _darkTheme = _buildVidyutTheme(Brightness.dark);

ThemeData buildVidyutTheme() => _lightTheme;

ThemeData buildVidyutDarkTheme() => _darkTheme;

ThemeData _buildVidyutTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = dark
      ? const ColorScheme.dark(
          primary: Palette.darkRaspberry,
          onPrimary: Palette.darkGround,
          secondary: Palette.darkPetal,
          onSecondary: Palette.darkInk,
          primaryContainer: Palette.darkPetal,
          onPrimaryContainer: Palette.darkInk,
          secondaryContainer: Palette.darkMist,
          onSecondaryContainer: Palette.darkInk,
          surface: Palette.darkGround,
          onSurface: Palette.darkInk,
          onSurfaceVariant: Palette.darkMuted,
          error: Palette.darkError,
          onError: Palette.darkGround,
          errorContainer: Palette.darkMist,
          outline: Palette.darkMuted,
          outlineVariant: Palette.darkHairline,
        )
      : const ColorScheme.light(
          primary: Palette.raspberry,
          onPrimary: Colors.white,
          secondary: Palette.petal,
          onSecondary: Palette.ink,
          primaryContainer: Palette.petal,
          onPrimaryContainer: Palette.ink,
          secondaryContainer: Palette.mist,
          onSecondaryContainer: Palette.ink,
          surface: Palette.ground,
          onSurface: Palette.ink,
          onSurfaceVariant: Palette.muted,
          error: Palette.error,
          onError: Colors.white,
          errorContainer: Palette.mist,
          outline: Palette.muted,
          outlineVariant: Palette.hairline,
        );

  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    brightness: brightness,
  );
  final manrope = base.textTheme.apply(fontFamily: 'Manrope');
  final ink = dark ? Palette.darkInk : Palette.ink;
  final muted = dark ? Palette.darkMuted : Palette.muted;

  TextStyle style(
    double size,
    FontWeight weight, {
    Color? color,
    double? tracking,
  }) => TextStyle(
    fontFamily: 'Manrope',
    fontSize: size,
    fontWeight: weight,
    color: color ?? ink,
    letterSpacing: tracking ?? 0,
    height: 1.35,
  );

  final textTheme = manrope.copyWith(
    displaySmall: style(28, FontWeight.w700, tracking: -0.56),
    headlineMedium: style(24, FontWeight.w700, tracking: -0.48),
    titleLarge: style(18, FontWeight.w700),
    titleMedium: style(16, FontWeight.w700),
    titleSmall: style(14, FontWeight.w700),
    bodyLarge: style(16, FontWeight.w500),
    bodyMedium: style(14, FontWeight.w500),
    bodySmall: style(12, FontWeight.w500),
    labelLarge: style(14, FontWeight.w600),
    labelMedium: style(12, FontWeight.w600),
    labelSmall: style(11, FontWeight.w600, color: muted),
  );

  final surfaceContainer = dark ? Palette.darkMist : Palette.mist;
  final outline = dark ? Palette.darkHairline : Palette.hairline;
  final statusColors = VidyutStatusColors(
    success: dark ? Palette.darkSuccess : Palette.success,
    successContainer: dark ? Palette.darkMist : Palette.successMist,
    warning: dark ? Palette.darkWarning : Palette.warning,
    warningContainer: dark ? Palette.darkMist : Palette.warningMist,
    active: dark ? Palette.darkWarning : Palette.active,
    activeContainer: dark ? Palette.darkMist : Palette.activeMist,
  );

  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    extensions: [statusColors],
    textTheme: textTheme,
    iconTheme: IconThemeData(color: ink),
    dividerTheme: DividerThemeData(color: outline, thickness: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: style(20, FontWeight.w700, tracking: -0.2),
    ),
    cardTheme: CardThemeData(
      color: surfaceContainer,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: style(14, FontWeight.w600, color: scheme.onPrimary),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.primary,
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: BorderSide(color: scheme.outlineVariant, width: 1),
        textStyle: style(14, FontWeight.w600, color: scheme.primary),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: scheme.primary,
        minimumSize: const Size(48, 48),
        textStyle: style(14, FontWeight.w600, color: scheme.primary),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surfaceContainer,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.error),
      ),
      labelStyle: style(14, FontWeight.w500, color: muted),
      floatingLabelStyle: style(12, FontWeight.w600, color: scheme.primary),
      prefixIconColor: muted,
    ),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      side: BorderSide(color: outline),
      backgroundColor: scheme.surface,
      selectedColor: scheme.primaryContainer,
      labelStyle: style(12, FontWeight.w600),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? scheme.onPrimary : muted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : surfaceContainer,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.transparent
            : outline,
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.primary,
      textColor: ink,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: dark ? Palette.darkMist : Palette.ink,
      contentTextStyle: style(
        14,
        FontWeight.w500,
        color: dark ? Palette.darkInk : Colors.white,
      ),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}
