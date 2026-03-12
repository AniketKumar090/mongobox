import 'package:flutter_dotenv/flutter_dotenv.dart';

class EnvConfig {
  static Future<void> load() async {
    await dotenv.load(fileName: '.env');
  }

  static String get youtubeApiKey {
    final key = dotenv.env['YOUTUBE_API_KEY'];
    if (key == null || key.isEmpty) {
      throw Exception(
        'YOUTUBE_API_KEY not found in .env file. '
        'Please create a .env file with: YOUTUBE_API_KEY=your_key'
      );
    }
    return key;
  }
}
