import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'screens/web/home_screen_web.dart' if (dart.library.io) 'screens/home_screen_stub.dart' as jukebox;
import 'screens/mobile_lyric_app.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'services/env_config.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
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
 options: DefaultFirebaseOptions.currentPlatform);
    print('✅ Firebase initialized fresh');
  } else {
    print('✅ Using existing Firebase app (apps count: ${Firebase.apps.length})');
  }
  
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MongoBox',
      theme: ThemeData(
        useMaterial3: true,
        primarySwatch: Colors.blue,
        fontFamily: 'Inter',
        textTheme: const TextTheme(
          displayLarge: TextStyle(color: Colors.black87),
          bodyLarge: TextStyle(color: Colors.black87),
        ),
      ),
      darkTheme: kIsWeb ? null : ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        fontFamily: 'Inter',
      ),
      themeMode: kIsWeb ? ThemeMode.light : ThemeMode.system,
      home: kIsWeb ? const jukebox.HomeScreen() : const MobileLyricApp(),
    );
  }
}