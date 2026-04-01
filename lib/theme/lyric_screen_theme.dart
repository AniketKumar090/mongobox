import 'package:flutter/material.dart';

@immutable
class LyricScreenPalette {
  const LyricScreenPalette._({
    required this.brightness,
    required this.background,
    required this.surface,
    required this.mutedSurface,
    required this.ink,
    required this.accent,
    required this.accentSoft,
    required this.outline,
    required this.mutedText,
    required this.error,
    required this.errorSoft,
    required this.warning,
  });

  final Brightness brightness;
  final Color background;
  final Color surface;
  final Color mutedSurface;
  final Color ink;
  final Color accent;
  final Color accentSoft;
  final Color outline;
  final Color mutedText;
  final Color error;
  final Color errorSoft;
  final Color warning;

  bool get isDark => brightness == Brightness.dark;

  ColorScheme get colorScheme => ColorScheme(
    brightness: brightness,
    primary: ink,
    onPrimary: surface,
    primaryContainer: surface,
    onPrimaryContainer: ink,
    secondary: accent,
    onSecondary: isDark ? const Color(0xFF0D1511) : ink,
    secondaryContainer: accentSoft,
    onSecondaryContainer: isDark ? const Color(0xFFBDF8DE) : ink,
    tertiary: mutedSurface,
    onTertiary: ink,
    tertiaryContainer: surface,
    onTertiaryContainer: ink,
    error: error,
    onError: surface,
    errorContainer: errorSoft,
    onErrorContainer: ink,
    surface: background,
    onSurface: ink,
    surfaceContainerHighest: mutedSurface,
    onSurfaceVariant: mutedText,
    outline: outline,
    inverseSurface: surface,
    onInverseSurface: ink,
  );

  static const light = LyricScreenPalette._(
    brightness: Brightness.light,
    background: Color(0xFFF5F3EF),
    surface: Color(0xFFF8F4EE),
    mutedSurface: Color(0xFFEDE8E0),
    ink: Color(0xFF111111),
    accent: Color(0xFF11F08A),
    accentSoft: Color(0xFFDDFBEF),
    outline: Color(0xFFD7D0C6),
    mutedText: Color(0xFF666666),
    error: Color(0xFFB05A49),
    errorSoft: Color(0xFFF2DFD8),
    warning: Color(0xFFD8A53A),
  );

  static const dark = LyricScreenPalette._(
    brightness: Brightness.dark,
    background: Color(0xFF101316),
    surface: Color(0xFF171B20),
    mutedSurface: Color(0xFF242A31),
    ink: Color(0xFFF4EFE7),
    accent: Color(0xFF11F08A),
    accentSoft: Color(0xFF143626),
    outline: Color(0xFF39424B),
    mutedText: Color(0xFFA3ACB7),
    error: Color(0xFFFF8A7A),
    errorSoft: Color(0xFF402724),
    warning: Color(0xFFE0B75A),
  );

  static LyricScreenPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

ThemeData lyricScreenTheme(BuildContext context) {
  final base = Theme.of(context);
  final palette = LyricScreenPalette.of(context);

  return base.copyWith(
    brightness: palette.brightness,
    scaffoldBackgroundColor: palette.background,
    colorScheme: palette.colorScheme,
    textTheme: base.textTheme.apply(
      fontFamily: 'Inter',
      bodyColor: palette.ink,
      displayColor: palette.ink,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: palette.background,
      foregroundColor: palette.ink,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        fontFamily: 'Inter',
        fontSize: 18,
        fontWeight: FontWeight.w800,
        color: palette.ink,
      ),
    ),
    cardTheme: CardThemeData(
      color: palette.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: palette.ink,
      contentTextStyle: TextStyle(
        fontFamily: 'Inter',
        color: palette.surface,
        fontWeight: FontWeight.w600,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      behavior: SnackBarBehavior.floating,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: palette.ink,
        foregroundColor: palette.surface,
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
        foregroundColor: palette.ink,
        side: BorderSide(color: palette.outline),
        backgroundColor: palette.surface,
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
