import 'dart:convert';
import 'package:http/http.dart' as http;
import 'env_config.dart';

class YouTubeService {
  static late String _apiKey;
  static bool _initialized = false;
  static const _baseUrl = 'https://www.googleapis.com/youtube/v3';

  static String _getApiKey() {
    if (!_initialized) {
      try {
        _apiKey = EnvConfig.youtubeApiKey;
        _initialized = true;
        print('✅ YouTube Service initialized');
      } catch (e) {
        print('⚠️  YouTube Service: API key not available');
        _apiKey = '';
        _initialized = true;
      }
    }
    return _apiKey;
  }

  static void initialize() {
    _getApiKey();
  }

  Future<List<Map<String, dynamic>>> searchSongs(String query) async {
    final response = await http.get(
      Uri.parse(
        '$_baseUrl/search?part=snippet&maxResults=10&q=${Uri.encodeQueryComponent(query)}&type=video&key=${_getApiKey()}',
      ),
    );

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return (data['items'] as List).map((item) {
        return {
          'id': item['id']['videoId'],
          'title': item['snippet']['title'],
          'thumbnail': item['snippet']['thumbnails']['default']['url'],
          'channel': item['snippet']['channelTitle'],
        };
      }).toList();
    } else {
      throw Exception('Failed to load songs');
    }
  }
}