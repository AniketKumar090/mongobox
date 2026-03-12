import 'package:flutter_dotenv/flutter_dotenv.dart';

class EnvConfig {
  static Future<void> load() async {
    try {
      await dotenv.load(fileName: '.env');
    } catch (e) {
      print('⚠️  .env file not found. Using environment variables or defaults.');
    }
  }

  static String get youtubeApiKey {
    // Try .env file first
    final envFileKey = dotenv.env['YOUTUBE_API_KEY'];
    if (envFileKey != null && envFileKey.isNotEmpty) {
      return envFileKey;
    }
    
    // Fallback to hardcoded or throw error
    // In production, this should come from GitHub Secrets via environment variable
    throw Exception(
      'YOUTUBE_API_KEY not found. '
      'Set in .env file locally or as environment variable in CI/CD'
    );
  }
}
