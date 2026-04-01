import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform, kIsWeb;
import 'package:audio_service/audio_service.dart';
import 'screens/web/home_screen_web.dart'
    if (dart.library.io) 'screens/home_screen_stub.dart'
    as jukebox;
import 'screens/mobile_lyric_app.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'services/env_config.dart';
import 'services/audio_session_service.dart';
import 'services/lyric_audio_registry.dart';
import 'services/lyric_background_audio_handler.dart';
import 'theme/app_theme_controller.dart';

bool get _isIosOrAndroid =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android);

class _InstantPageTransitionsBuilder extends PageTransitionsBuilder {
  const _InstantPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}

const PageTransitionsTheme _noTransitionsTheme = PageTransitionsTheme(
  builders: {
    TargetPlatform.android: _InstantPageTransitionsBuilder(),
    TargetPlatform.iOS: _InstantPageTransitionsBuilder(),
    TargetPlatform.macOS: _InstantPageTransitionsBuilder(),
    TargetPlatform.windows: _InstantPageTransitionsBuilder(),
    TargetPlatform.linux: _InstantPageTransitionsBuilder(),
    TargetPlatform.fuchsia: _InstantPageTransitionsBuilder(),
  },
);

ThemeData _withNoTransitions(ThemeData theme) =>
    theme.copyWith(pageTransitionsTheme: _noTransitionsTheme);

ThemeData _buildAppTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: isDark ? const Color(0xFFF4EFE7) : const Color(0xFF111111),
    onPrimary: isDark ? const Color(0xFF111111) : const Color(0xFFF8F4EE),
    primaryContainer:
        isDark ? const Color(0xFF20242A) : const Color(0xFFF8F4EE),
    onPrimaryContainer:
        isDark ? const Color(0xFFF4EFE7) : const Color(0xFF111111),
    secondary: const Color(0xFF11F08A),
    onSecondary: const Color(0xFF0D1511),
    secondaryContainer:
        isDark ? const Color(0xFF123427) : const Color(0xFFDDFBEF),
    onSecondaryContainer:
        isDark ? const Color(0xFFBDF8DE) : const Color(0xFF111111),
    tertiary: isDark ? const Color(0xFF262C33) : const Color(0xFFEDE8E0),
    onTertiary: isDark ? const Color(0xFFF4EFE7) : const Color(0xFF111111),
    tertiaryContainer:
        isDark ? const Color(0xFF171B20) : const Color(0xFFF8F4EE),
    onTertiaryContainer:
        isDark ? const Color(0xFFF4EFE7) : const Color(0xFF111111),
    error: isDark ? const Color(0xFFFF8A7A) : const Color(0xFFB05A49),
    onError: isDark ? const Color(0xFF2A1411) : const Color(0xFFF8F4EE),
    errorContainer: isDark ? const Color(0xFF3D2420) : const Color(0xFFF2DFD8),
    onErrorContainer:
        isDark ? const Color(0xFFFFD6D0) : const Color(0xFF111111),
    surface: isDark ? const Color(0xFF111315) : const Color(0xFFF5F3EF),
    onSurface: isDark ? const Color(0xFFF4EFE7) : const Color(0xFF111111),
    surfaceContainerHighest:
        isDark ? const Color(0xFF262C33) : const Color(0xFFEDE8E0),
    onSurfaceVariant:
        isDark ? const Color(0xFFA4ADB7) : const Color(0xFF666666),
    outline: isDark ? const Color(0xFF3C454F) : const Color(0xFFD7D0C6),
    inverseSurface: isDark ? const Color(0xFFF4EFE7) : const Color(0xFF1A1A1A),
    onInverseSurface:
        isDark ? const Color(0xFF111111) : const Color(0xFFF8F4EE),
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamily: 'Inter',
    colorScheme: scheme,
  );

  return _withNoTransitions(
    base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      textTheme: base.textTheme.apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(
          fontFamily: 'Inter',
          color: scheme.onInverseSurface,
          fontWeight: FontWeight.w600,
        ),
        behavior: SnackBarBehavior.floating,
      ),
    ),
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (_isIosOrAndroid) {
    try {
      final handler = await AudioService.init(
        builder: () => LyricBackgroundAudioHandler(),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.mongobox.audio',
          androidNotificationChannelName: 'LyricQsk Playback',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
        ),
      );
      LyricAudioRegistry.register(handler);
    } catch (e, st) {
      debugPrint(
        'AudioService init failed (fallback to plain player): $e\n$st',
      );
    }
  }

  // Load environment variables from .env file (best effort)
  try {
    await EnvConfig.load();
    debugPrint('🔑 KEY LOADED: ${EnvConfig.anthropicApiKey}');
  } catch (e) {
    debugPrint('⚠️  Could not load .env file: $e');
  }

  // Initialize Firebase
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(
      name: "MongoBox",
      options: DefaultFirebaseOptions.currentPlatform,
    );
    debugPrint('✅ Firebase initialized fresh');
  } else {
    debugPrint(
      '✅ Using existing Firebase app (apps count: ${Firebase.apps.length})',
    );
  }

  // Ensure background-friendly playback audio session on mobile platforms.
  await AppAudioSessionService.ensureConfigured();
  await AppThemeController.instance.load();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppThemeController.instance,
      builder: (context, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'LyricQsk',
          theme: _buildAppTheme(Brightness.light),
          darkTheme: _buildAppTheme(Brightness.dark),
          themeMode: AppThemeController.instance.themeMode,
          home: kIsWeb ? const jukebox.HomeScreen() : const MobileLyricApp(),
        );
      },
    );
  }
}
