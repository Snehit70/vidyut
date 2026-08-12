import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'palette.dart';

/// Flat Raspberry Pink theme: white grounds, flat mist/petal surfaces,
/// 20px radii, rounded-squircle controls, Plus Jakarta Sans with weight-driven hierarchy.
ThemeData buildVidyutTheme() {
  const scheme = ColorScheme.light(
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
    error: Palette.error,
    onError: Colors.white,
    outline: Palette.muted,
    outlineVariant: Palette.hairline,
  );

  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  final jakarta = GoogleFonts.plusJakartaSansTextTheme(base.textTheme);

  TextStyle style(
    double size,
    FontWeight weight, {
    Color color = Palette.ink,
    double? tracking,
  }) => GoogleFonts.plusJakartaSans(
    fontSize: size,
    fontWeight: weight,
    color: color,
    letterSpacing: tracking ?? 0,
    height: 1.3,
  );

  final textTheme = jakarta.copyWith(
    // Display: weight 800 with tight tracking (-0.03em).
    displaySmall: style(26, FontWeight.w800, tracking: -0.78),
    headlineMedium: style(26, FontWeight.w800, tracking: -0.78),
    titleLarge: style(26, FontWeight.w800, tracking: -0.78),
    titleMedium: style(16, FontWeight.w600),
    titleSmall: style(14, FontWeight.w600),
    bodyLarge: style(16, FontWeight.w500),
    bodyMedium: style(14, FontWeight.w500),
    bodySmall: style(12, FontWeight.w500),
    labelLarge: style(14, FontWeight.w600),
    labelMedium: style(12, FontWeight.w600),
    labelSmall: style(12, FontWeight.w600, color: Palette.muted),
  );

  return base.copyWith(
    scaffoldBackgroundColor: Palette.ground,
    textTheme: textTheme,
    iconTheme: const IconThemeData(color: Palette.ink),
    dividerTheme: const DividerThemeData(color: Palette.hairline, thickness: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: Palette.ground,
      foregroundColor: Palette.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: style(20, FontWeight.w800, tracking: -0.6),
    ),
    cardTheme: const CardThemeData(
      color: Palette.mist,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(20)),
      ),
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Palette.raspberry,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(54),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        textStyle: style(15, FontWeight.w600, color: Colors.white),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Palette.raspberry,
        minimumSize: const Size.fromHeight(54),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        side: const BorderSide(color: Palette.petal, width: 1.5),
        textStyle: style(15, FontWeight.w600, color: Palette.raspberry),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: Palette.raspberry,
        textStyle: style(14, FontWeight.w600, color: Palette.raspberry),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Palette.mist,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Palette.hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Palette.hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Palette.raspberry, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Palette.error),
      ),
      labelStyle: style(14, FontWeight.w500, color: Palette.muted),
      floatingLabelStyle: style(12, FontWeight.w600, color: Palette.raspberry),
      prefixIconColor: Palette.muted,
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      side: const BorderSide(color: Palette.petal, width: 1.5),
      backgroundColor: Palette.ground,
      selectedColor: Palette.petal,
      labelStyle: style(14, FontWeight.w600),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.white
            : Palette.muted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Palette.raspberry
            : Palette.mist,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.transparent
            : Palette.hairline,
      ),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: Palette.raspberry,
      textColor: Palette.ink,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Palette.raspberry,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: Palette.ink,
      contentTextStyle: style(14, FontWeight.w500, color: Colors.white),
      behavior: SnackBarBehavior.floating,
      shape: const StadiumBorder(),
    ),
  );
}
