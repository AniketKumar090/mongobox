// YouTube Data API search for mobile (same API key as web).

import 'dart:convert';
import 'package:http/http.dart' as http;

/// Reuse the same key as web jukebox for consistency.
const String youtubeApiKey = 'AIzaSyBJzIb7YbZPPL2XuOGlncntEPwkc0JQpmY';

class YoutubeMobileService {
  final http.Client _client = http.Client();

  /// Search YouTube by query (e.g. "trackName artistName"). Returns first video id or null.
  Future<String?> searchFirstVideoId(String query) async {
    if (query.trim().isEmpty) return null;

    final uri = Uri.parse(
      'https://www.googleapis.com/youtube/v3/search'
      '?part=snippet&maxResults=5&type=video&key=$youtubeApiKey'
      '&q=${Uri.encodeQueryComponent(query.trim())}',
    );
    final response = await _client.get(uri);

    if (response.statusCode != 200) return null;

    final data = json.decode(response.body) as Map<String, dynamic>?;
    final items = data?['items'] as List<dynamic>?;
    if (items == null || items.isEmpty) return null;

    final first = items.first as Map<String, dynamic>?;
    final id = first?['id'] as Map<String, dynamic>?;
    return id?['videoId'] as String?;
  }

  /// Search YouTube by query (any language). Returns list of songs for suggestions/queue.
  /// Same API as web; works for Hindi, English, Spanish, etc.
  Future<List<Map<String, dynamic>>> searchSongs(String query) async {
    print('🔍 [DEBUG] Original query: "$query"');
    final trimmedQuery = query.trim();
    if (trimmedQuery.isEmpty) {
      print('❌ [DEBUG] Query is empty after trim');
      return [];
    }

    // Use the same API key as the web version
    const webApiKey = 'AIzaSyBJzIb7YbZPPL2XuOGlncntEPwkc0JQpmY';
    final uri = Uri.parse(
      'https://www.googleapis.com/youtube/v3/search?part=snippet&maxResults=10&q=${Uri.encodeQueryComponent(trimmedQuery)}&type=video&key=$webApiKey',
    );
    print('🔍 [DEBUG] YouTube search URL: $uri');
    final response = await _client.get(uri);
    print('🔍 [DEBUG] Response status: ${response.statusCode}');
    print('🔍 [DEBUG] Response body: ${response.body}');

    if (response.statusCode != 200) {
      print('❌ [DEBUG] Non-200 response: ${response.statusCode}');
      return [];
    }

    final data = json.decode(response.body) as Map<String, dynamic>?;
    final items = data?['items'] as List<dynamic>?;
    if (items == null || items.isEmpty) {
      print('❌ [DEBUG] No items found in response');
      return [];
    }

    final results = items.map((item) {
      return {
        'id': item['id']['videoId'],
        'title': item['snippet']['title'],
        'thumbnail': item['snippet']['thumbnails']['default']['url'],
        'artist': item['snippet']['channelTitle'],
      };
    }).toList();
    print('✅ [DEBUG] Results found: ${results.length}');
    return results;
  }
}
