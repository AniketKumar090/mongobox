import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../constants/colors.dart';

// ─────────────────────────────────────────────────────────────────────────────
// PIXEL ART COLOR PALETTE
// ─────────────────────────────────────────────────────────────────────────────
class PixelColors {
  PixelColors._();

  static const bg = Color(0xFF0D0D1A); // deep navy — main background
  static const card = Color(0xFF12122A); // slightly lighter — card surface
  static const card2 = Color(0xFF1C1C3A); // elevated card / input fills
  static const green = AppColors.accentDark; // primary accent
  static const greenDim = AppColors.accentStrongDark; // pressed accent
  static const yellow = Color(0xFFFFE600); // tip / warning accent
  static const red = Color(0xFFFF3D5A); // error / recording accent
  static const blue = Color(0xFF4DA6FF); // karaoke / info accent
  static const purple = AppColors.accentDark; // header card / reference accent
  static const purpleDim = AppColors.accentStrongDark; // accent shadow
  static const muted = Color(0xFF8E8EBA); // inactive text / borders
  static const textPrimary = Color(0xFFE8E8FF); // near-white body text
  static const textSecondary = Color(0xFFC2C2E8); // secondary labels
}

// ─────────────────────────────────────────────────────────────────────────────
// TYPOGRAPHY  —  Press Start 2P (labels/buttons) + VT323 (lyric/body text)
// ─────────────────────────────────────────────────────────────────────────────
class PixelFonts {
  PixelFonts._();

  /// Use for ALL UI labels, buttons, titles, headers.
  static TextStyle pressStart({
    double size = 7,
    Color color = PixelColors.textPrimary,
    double letterSpacing = 0.5,
    FontWeight weight = FontWeight.w400,
  }) => GoogleFonts.pressStart2p(
    fontSize: size,
    color: color,
    letterSpacing: letterSpacing,
    fontWeight: weight,
  );

  /// Use for lyric lines, karaoke words, body-style reading text.
  static TextStyle vt323({
    double size = 16,
    Color color = PixelColors.textPrimary,
    double letterSpacing = 0.5,
    double height = 1.4,
  }) => GoogleFonts.vt323(
    fontSize: size,
    color: color,
    letterSpacing: letterSpacing,
    height: height,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// THEME
// ─────────────────────────────────────────────────────────────────────────────
class PixelTheme {
  PixelTheme._();

  static ThemeData get theme => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: _colorScheme,
    scaffoldBackgroundColor: PixelColors.bg,
    textTheme: _textTheme,
    appBarTheme: _appBarTheme,
    filledButtonTheme: _filledButtonTheme,
    outlinedButtonTheme: _outlinedButtonTheme,
    cardTheme: _cardTheme,
    snackBarTheme: _snackBarTheme,
    dialogTheme: _dialogTheme,
    inputDecorationTheme: _inputDecorationTheme,
    dividerTheme: const DividerThemeData(
      color: PixelColors.card2,
      thickness: 2,
      space: 0,
    ),
  );

  // ── ColorScheme ────────────────────────────────────────────────────────────
  static const _colorScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: PixelColors.green,
    onPrimary: PixelColors.bg,
    primaryContainer: PixelColors.card,
    onPrimaryContainer: PixelColors.textPrimary,
    secondary: PixelColors.purple,
    onSecondary: PixelColors.bg,
    secondaryContainer: PixelColors.card2,
    onSecondaryContainer: PixelColors.textPrimary,
    tertiary: PixelColors.blue,
    onTertiary: PixelColors.bg,
    tertiaryContainer: PixelColors.card2,
    onTertiaryContainer: PixelColors.textPrimary,
    error: PixelColors.red,
    onError: PixelColors.bg,
    errorContainer: Color(0xFF2A0D12),
    onErrorContainer: PixelColors.red,
    surface: PixelColors.bg,
    onSurface: PixelColors.textPrimary,
    surfaceContainerHighest: PixelColors.card2,
    onSurfaceVariant: PixelColors.textSecondary,
    outline: PixelColors.muted,
    inverseSurface: PixelColors.card,
    onInverseSurface: PixelColors.textPrimary,
  );

  // ── TextTheme  (maps Flutter's named styles → pixel fonts) ────────────────
  static TextTheme get _textTheme => TextTheme(
    // Titles → Press Start 2P
    titleLarge: PixelFonts.pressStart(size: 11),
    titleMedium: PixelFonts.pressStart(size: 9),
    titleSmall: PixelFonts.pressStart(size: 8),
    // Labels → Press Start 2P (small pixel labels)
    labelLarge: PixelFonts.pressStart(size: 8),
    labelMedium: PixelFonts.pressStart(size: 7),
    labelSmall: PixelFonts.pressStart(size: 6),
    // Body → VT323 (lyric / reading text)
    bodyLarge: PixelFonts.vt323(size: 19),
    bodyMedium: PixelFonts.vt323(size: 16),
    bodySmall: PixelFonts.vt323(size: 14, color: PixelColors.textSecondary),
    // Display (unused in this screen, fallback)
    displaySmall: PixelFonts.pressStart(size: 13),
  );

  // ── AppBar ─────────────────────────────────────────────────────────────────
  static const _appBarTheme = AppBarTheme(
    backgroundColor: PixelColors.card,
    foregroundColor: PixelColors.textPrimary,
    elevation: 0,
    scrolledUnderElevation: 0,
    centerTitle: true,
    shape: Border(bottom: BorderSide(color: PixelColors.green, width: 2)),
  );

  // ── FilledButton  (record / primary actions) ───────────────────────────────
  static final _filledButtonTheme = FilledButtonThemeData(
    style: ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.pressed)) return PixelColors.greenDim;
        return PixelColors.green;
      }),
      foregroundColor: WidgetStatePropertyAll(PixelColors.bg),
      elevation: WidgetStatePropertyAll(0),
      shape: WidgetStatePropertyAll(
        const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      ),
      side: WidgetStatePropertyAll(
        const BorderSide(color: PixelColors.greenDim, width: 2),
      ),
      textStyle: WidgetStatePropertyAll(
        PixelFonts.pressStart(size: 7, color: PixelColors.bg),
      ),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      ),
    ),
  );

  // ── OutlinedButton  (playback / ghost actions) ─────────────────────────────
  static final _outlinedButtonTheme = OutlinedButtonThemeData(
    style: ButtonStyle(
      foregroundColor: WidgetStatePropertyAll(PixelColors.textPrimary),
      backgroundColor: WidgetStatePropertyAll(Colors.transparent),
      elevation: WidgetStatePropertyAll(0),
      side: WidgetStatePropertyAll(
        const BorderSide(color: PixelColors.muted, width: 2),
      ),
      shape: WidgetStatePropertyAll(
        const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      ),
      textStyle: WidgetStatePropertyAll(
        PixelFonts.pressStart(size: 7, color: PixelColors.textPrimary),
      ),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      ),
    ),
  );

  // ── Card ──────────────────────────────────────────────────────────────────
  static const _cardTheme = CardThemeData(
    color: PixelColors.card,
    elevation: 0,
    margin: EdgeInsets.zero,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.zero,
      side: BorderSide(color: PixelColors.muted, width: 1),
    ),
  );

  // ── SnackBar ───────────────────────────────────────────────────────────────
  static final _snackBarTheme = SnackBarThemeData(
    backgroundColor: PixelColors.card2,
    contentTextStyle: PixelFonts.vt323(size: 14),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
    behavior: SnackBarBehavior.floating,
  );

  // ── Dialog ─────────────────────────────────────────────────────────────────
  static const _dialogTheme = DialogThemeData(
    backgroundColor: PixelColors.card,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.zero,
      side: BorderSide(color: PixelColors.green, width: 2),
    ),
  );

  static final _inputDecorationTheme = InputDecorationTheme(
    filled: true,
    fillColor: PixelColors.card2,
    hintStyle: PixelFonts.vt323(size: 16, color: PixelColors.textSecondary),
    labelStyle: PixelFonts.pressStart(
      size: 7,
      color: PixelColors.textSecondary,
    ),
    prefixIconColor: PixelColors.green,
    suffixIconColor: PixelColors.textPrimary,
    border: const OutlineInputBorder(
      borderRadius: BorderRadius.zero,
      borderSide: BorderSide(color: PixelColors.muted, width: 2),
    ),
    enabledBorder: const OutlineInputBorder(
      borderRadius: BorderRadius.zero,
      borderSide: BorderSide(color: PixelColors.muted, width: 2),
    ),
    focusedBorder: const OutlineInputBorder(
      borderRadius: BorderRadius.zero,
      borderSide: BorderSide(color: PixelColors.green, width: 2),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// REUSABLE PIXEL WIDGETS
// ─────────────────────────────────────────────────────────────────────────────

/// A card with a sharp pixel border and optional accent-color left edge.
class PixelCard extends StatelessWidget {
  const PixelCard({
    super.key,
    required this.child,
    this.borderColor = PixelColors.muted,
    this.leftAccentColor,
    this.backgroundColor = PixelColors.card,
    this.padding = const EdgeInsets.all(12),
  });

  final Widget child;
  final Color borderColor;
  final Color? leftAccentColor;
  final Color backgroundColor;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: backgroundColor,
        border:
            leftAccentColor != null
                ? Border(
                  top: BorderSide(color: borderColor, width: 2),
                  right: BorderSide(color: borderColor, width: 2),
                  bottom: BorderSide(color: borderColor, width: 2),
                  left: BorderSide(color: leftAccentColor!, width: 3),
                )
                : Border.all(color: borderColor, width: 2),
      ),
      child: child,
    );
  }
}

/// Pixel-style section label (muted, uppercase, Press Start 2P).
class PixelLabel extends StatelessWidget {
  const PixelLabel(this.text, {super.key, this.color = PixelColors.muted});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      '> $text',
      style: PixelFonts.pressStart(size: 10, color: color, letterSpacing: 1),
    );
  }
}

/// A FilledButton pre-styled for the "error / recording" state.
class PixelStopButton extends StatelessWidget {
  const PixelStopButton({
    super.key,
    required this.label,
    required this.onPressed,
  });
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: PixelColors.red,
          foregroundColor: PixelColors.bg,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          side: const BorderSide(color: Color(0xFFCC2240), width: 2),
          elevation: 0,
        ),
        icon: const Icon(Icons.stop_rounded, size: 18),
        label: Text(
          label,
          style: PixelFonts.pressStart(size: 7, color: PixelColors.bg),
        ),
      ),
    );
  }
}

/// A purple FilledButton for "Use This Recording" / secondary CTAs.
class PixelPurpleButton extends StatelessWidget {
  const PixelPurpleButton({
    super.key,
    required this.label,
    required this.onPressed,
  });
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: PixelColors.purple,
          foregroundColor: PixelColors.textPrimary,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          side: const BorderSide(color: PixelColors.purpleDim, width: 2),
          elevation: 0,
        ),
        icon: const Icon(Icons.arrow_forward_rounded, size: 16),
        label: Text(
          label,
          style: PixelFonts.pressStart(size: 6, color: PixelColors.textPrimary),
        ),
      ),
    );
  }
}
