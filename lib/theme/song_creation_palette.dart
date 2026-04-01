import 'package:flutter/material.dart';

import '../constants/colors.dart';
import 'app_theme_controller.dart';

@immutable
class SongCreationPalette {
  const SongCreationPalette._({
    required this.background,
    required this.card,
    required this.cardAlt,
    required this.border,
    required this.borderAlt,
    required this.black,
    required this.blackSoft,
    required this.grey1,
    required this.grey2,
    required this.grey3,
    required this.grey4,
    required this.green,
    required this.greenSoft,
    required this.greenBorder,
    required this.chip,
    required this.chipDark,
    required this.red,
    required this.redSoft,
    required this.redBorder,
    required this.onBlack,
    required this.shadow,
  });

  final Color background;
  final Color card;
  final Color cardAlt;
  final Color border;
  final Color borderAlt;
  final Color black;
  final Color blackSoft;
  final Color grey1;
  final Color grey2;
  final Color grey3;
  final Color grey4;
  final Color green;
  final Color greenSoft;
  final Color greenBorder;
  final Color chip;
  final Color chipDark;
  final Color red;
  final Color redSoft;
  final Color redBorder;
  final Color onBlack;
  final Color shadow;

  static const light = SongCreationPalette._(
    background: Color(0xFFF5F3EF),
    card: Color(0xFFF0EDE7),
    cardAlt: Color(0xFFFAF8F5),
    border: Color(0xFFD8D4CC),
    borderAlt: Color(0xFFEAE6E0),
    black: Color(0xFF111111),
    blackSoft: Color(0xFF1E1E1E),
    grey1: Color(0xFF444444),
    grey2: Color(0xFF666666),
    grey3: Color(0xFF888888),
    grey4: Color(0xFFAAAAAA),
    green: AppColors.accent,
    greenSoft: AppColors.accentSoft,
    greenBorder: AppColors.accentBorder,
    chip: Color(0xFFE8E3DC),
    chipDark: Color(0xFFD8D4CC),
    red: Color(0xFFFF3B30),
    redSoft: Color(0xFFFFF0EE),
    redBorder: Color(0xFFFFCCCC),
    onBlack: Color(0xFFF8F4EE),
    shadow: Color(0xFF111111),
  );

  static const dark = SongCreationPalette._(
    background: Color(0xFF111315),
    card: Color(0xFF171B20),
    cardAlt: Color(0xFF20242A),
    border: Color(0xFF39424B),
    borderAlt: Color(0xFF2D343C),
    black: Color(0xFFF4EFE7),
    blackSoft: Color(0xFFD9D3CB),
    grey1: Color(0xFFD6DDE5),
    grey2: Color(0xFFA4ADB7),
    grey3: Color(0xFF838D98),
    grey4: Color(0xFF616B75),
    green: AppColors.accent,
    greenSoft: AppColors.accentSoftDark,
    greenBorder: AppColors.accentBorderDark,
    chip: Color(0xFF242A31),
    chipDark: Color(0xFF2D343C),
    red: Color(0xFFFF8A7A),
    redSoft: Color(0xFF402724),
    redBorder: Color(0xFF734641),
    onBlack: Color(0xFF111315),
    shadow: Color(0xFF000000),
  );

  static SongCreationPalette get current =>
      AppThemeController.instance.isDarkMode ? dark : light;
}
