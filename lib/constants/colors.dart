import 'package:flutter/material.dart';

import '../theme/app_theme_controller.dart';

class AppColors {
  static const background = Colors.white;
  static const primary = Colors.black;
  static const secondary = Colors.grey;

  static const accentLight = Color(0xFF39FF14);
  static const accentStrongLight = Color(0xFF149B00);
  static const accentSoftLight = Color(0xFFEFFFF0);
  static const accentBorderLight = Color(0xFF8DFF79);
  static const onAccentLight = Color(0xFF08261C);

  static const accentDark = Color(0xFF7C5CFF);
  static const accentStrongDark = Color(0xFF5B3DF5);
  static const accentSoftDark = Color(0xFF241B4A);
  static const accentBorderDark = Color(0xFF4D3DB2);
  static const accentTextDark = Color(0xFFD8D1FF);
  static const onAccentDark = Color(0xFFF8F7FF);

  static bool get _isDark => AppThemeController.instance.isDarkMode;

  static Color get accent => _isDark ? accentDark : accentLight;
  static Color get accentStrong => _isDark ? accentStrongDark : accentStrongLight;
  static Color get accentSoft => _isDark ? accentSoftDark : accentSoftLight;
  static Color get accentBorder => _isDark ? accentBorderDark : accentBorderLight;
  static Color get onAccent => _isDark ? onAccentDark : onAccentLight;
}
