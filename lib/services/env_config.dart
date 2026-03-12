import 'package:flutter_dotenv/flutter_dotenv.dart';

class EnvConfig {
  static bool _initialized = false;
  
  static Future<void> load() async {
    if (_initialized) return;
    try {
      await dotenv.load(fileName: '.env');
      _initialized = true;
      print('✅ .env file loaded successfully');
    } catch (e) {
      print('⚠️  .env file not found or could not be loaded: $e');
      // Continue anyway - we'll try environment variables or fallback
      _initialized = true;
    }
  }

  static String get youtubeApiKey {
    // Try .env file first
    try {
      final envFileKey = dotenv.env['YOUTUBE_API_KEY'];
      if (envFileKey != null && envFileKey.isNotEmpty) {
        return envFileKey;
      }
    } catch (e) {
      print('⚠️  Error reading from .env: $e');
    }
    
    // Try environment variables (for GitHub Actions)
    final envVarKey = const String.fromEnvironment('YOUTUBE_API_KEY');
    if (envVarKey.isNotEmpty) {
      return envVarKey;
    }
    
    // Fallback (for build compatibility)
    throw Exception(
      'YOUTUBE_API_KEY not found. '
      'Set in .env file locally or as YOUTUBE_API_KEY environment variable'
    );
  }
}
