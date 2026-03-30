import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform, kIsWeb;
import 'package:audio_service/audio_service.dart';
import 'screens/web/home_screen_web.dart' if (dart.library.io) 'screens/home_screen_stub.dart' as jukebox;
import 'screens/mobile_lyric_app.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'services/env_config.dart';
import 'services/audio_session_service.dart';
import 'services/lyric_audio_registry.dart';
import 'services/lyric_background_audio_handler.dart';
import 'theme/pixel_theme.dart';

bool get _isIosOrAndroid =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (_isIosOrAndroid) {
    try {
      final handler = await AudioService.init(
        builder: () => LyricBackgroundAudioHandler(),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.mongobox.audio',
          androidNotificationChannelName: 'MongoBox Playback',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
        ),
      );
      LyricAudioRegistry.register(handler);
    } catch (e, st) {
      debugPrint('AudioService init failed (fallback to plain player): $e\n$st');
    }
  }

  // Load environment variables from .env file (best effort)
  try {
    await EnvConfig.load();
    print('🔑 KEY LOADED: ${EnvConfig.anthropicApiKey}');
  } catch (e) {
    print('⚠️  Could not load .env file: $e');
  }

  // Initialize Firebase
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(
      name: "MongoBox",
      options: DefaultFirebaseOptions.currentPlatform,
    );
    print('✅ Firebase initialized fresh');
  } else {
    print('✅ Using existing Firebase app (apps count: ${Firebase.apps.length})');
  }

  // Ensure background-friendly playback audio session on mobile platforms.
  await AppAudioSessionService.ensureConfigured();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MongoBox',
      // ── Mobile: pixel art dark theme ──────────────────────────────────────
      theme: kIsWeb
          ? ThemeData(
              useMaterial3: true,
              primarySwatch: Colors.blue,
              fontFamily: 'Inter',
              textTheme: const TextTheme(
                displayLarge: TextStyle(color: Colors.black87),
                bodyLarge: TextStyle(color: Colors.black87),
              ),
            )
          : PixelTheme.theme,
      darkTheme: kIsWeb
          ? ThemeData(
              useMaterial3: true,
              brightness: Brightness.dark,
              fontFamily: 'Inter',
            )
          : PixelTheme.theme,
      themeMode: kIsWeb ? ThemeMode.light : ThemeMode.dark,
      home: kIsWeb ? const jukebox.HomeScreen() : const MobileLyricApp(),
    );
  }
}