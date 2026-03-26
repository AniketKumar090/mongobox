import 'package:flutter/material.dart';

class LyricScreenPalette {
  LyricScreenPalette._();

  static const background = Color(0xFFF5F3EF);
  static const surface = Color(0xFFF8F4EE);
  static const mutedSurface = Color(0xFFEDE8E0);
  static const ink = Color(0xFF111111);
  static const accent = Color(0xFF11F08A);
  static const accentSoft = Color(0xFFDDFBEF);
  static const outline = Color(0xFFD7D0C6);
  static const mutedText = Color(0xFF666666);
  static const error = Color(0xFFB05A49);
  static const errorSoft = Color(0xFFF2DFD8);
  static const warning = Color(0xFFD8A53A);
}

ThemeData lyricScreenTheme(BuildContext context) {
  final base = Theme.of(context);
  const scheme = ColorScheme(
    brightness: Brightness.light,
    primary: LyricScreenPalette.ink,
    onPrimary: LyricScreenPalette.surface,
    primaryContainer: LyricScreenPalette.surface,
    onPrimaryContainer: LyricScreenPalette.ink,
    secondary: LyricScreenPalette.accent,
    onSecondary: LyricScreenPalette.ink,
    secondaryContainer: LyricScreenPalette.accentSoft,
    onSecondaryContainer: LyricScreenPalette.ink,
    tertiary: LyricScreenPalette.mutedSurface,
    onTertiary: LyricScreenPalette.ink,
    tertiaryContainer: LyricScreenPalette.surface,
    onTertiaryContainer: LyricScreenPalette.ink,
    error: LyricScreenPalette.error,
    onError: LyricScreenPalette.surface,
    errorContainer: LyricScreenPalette.errorSoft,
    onErrorContainer: LyricScreenPalette.ink,
    surface: LyricScreenPalette.background,
    onSurface: LyricScreenPalette.ink,
    surfaceContainerHighest: LyricScreenPalette.mutedSurface,
    onSurfaceVariant: LyricScreenPalette.mutedText,
    outline: LyricScreenPalette.outline,
    inverseSurface: LyricScreenPalette.surface,
    onInverseSurface: LyricScreenPalette.ink,
  );

  return base.copyWith(
    scaffoldBackgroundColor: LyricScreenPalette.background,
    colorScheme: scheme,
    textTheme: base.textTheme.apply(
      fontFamily: 'Inter',
      bodyColor: LyricScreenPalette.ink,
      displayColor: LyricScreenPalette.ink,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: LyricScreenPalette.background,
      foregroundColor: LyricScreenPalette.ink,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        fontFamily: 'Inter',
        fontSize: 18,
        fontWeight: FontWeight.w800,
        color: LyricScreenPalette.ink,
      ),
    ),
    cardTheme: CardThemeData(
      color: LyricScreenPalette.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: LyricScreenPalette.ink,
      contentTextStyle: const TextStyle(
        fontFamily: 'Inter',
        color: LyricScreenPalette.surface,
        fontWeight: FontWeight.w600,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      behavior: SnackBarBehavior.floating,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: LyricScreenPalette.ink,
        foregroundColor: LyricScreenPalette.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        elevation: 0,
        textStyle: const TextStyle(
          fontFamily: 'Inter',
          fontWeight: FontWeight.w800,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: LyricScreenPalette.ink,
        side: const BorderSide(color: LyricScreenPalette.outline),
        backgroundColor: LyricScreenPalette.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        textStyle: const TextStyle(
          fontFamily: 'Inter',
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );
}
