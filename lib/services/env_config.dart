import 'package:flutter_dotenv/flutter_dotenv.dart';

class EnvConfig {
  static bool _initialized = false;

  static String _clean(String? value) {
    var v = (value ?? '').trim();
    if (v.length >= 2) {
      final first = v[0];
      final last = v[v.length - 1];
      if ((first == '"' && last == '"') || (first == '\'' && last == '\'')) {
        v = v.substring(1, v.length - 1).trim();
      }
    }
    return v;
  }
  
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

  static String get anthropicApiKey {
    // Try .env file first
    try {
      final envFileKey = _clean(dotenv.env['ANTHROPIC_API_KEY']);
      if (envFileKey.isNotEmpty) {
        return envFileKey;
      }
    } catch (e) {
      print('⚠️  Error reading ANTHROPIC_API_KEY from .env: $e');
    }

    // Try compile-time environment (e.g. `--dart-define=ANTHROPIC_API_KEY=...`)
    final envVarKey = _clean(const String.fromEnvironment('ANTHROPIC_API_KEY'));
    if (envVarKey.isNotEmpty) {
      return envVarKey;
    }

    throw Exception(
      'ANTHROPIC_API_KEY not found. '
      'Set in .env locally or pass via --dart-define=ANTHROPIC_API_KEY=...'
    );
  }
}
