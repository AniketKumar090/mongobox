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
    if (query.trim().isEmpty) return [];

    final uri = Uri.parse(
      'https://www.googleapis.com/youtube/v3/search'
      '?part=snippet&maxResults=10&type=video&key=$youtubeApiKey'
      '&q=${Uri.encodeQueryComponent(query.trim())}',
    );
    final response = await _client.get(uri);

    if (response.statusCode != 200) return [];

    final data = json.decode(response.body) as Map<String, dynamic>?;
    final items = data?['items'] as List<dynamic>?;
    if (items == null) return [];

    return items.map((item) {
      final i = item as Map<String, dynamic>?;
      final id = i?['id'] as Map<String, dynamic>?;
      final snippet = i?['snippet'] as Map<String, dynamic>?;
      final thumbnails = snippet?['thumbnails'] as Map<String, dynamic>?;
      final def = thumbnails?['default'] as Map<String, dynamic>?;
      return {
        'id': id?['videoId'] as String? ?? '',
        'title': snippet?['title'] as String? ?? 'Unknown',
        'thumbnail': def?['url'] as String? ?? 'https://via.placeholder.com/60x60',
        'channel': snippet?['channelTitle'] as String? ?? 'Unknown',
      };
    }).where((m) => (m['id'] as String).isNotEmpty).toList();
  }
}
