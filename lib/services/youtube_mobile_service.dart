// YouTube Data API search for mobile (same API key as web).

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'env_config.dart';

/// Use API key from .env file for consistency across the app.
late String youtubeApiKey;

void initializeYoutubeApiKey() {
  try {
    youtubeApiKey = EnvConfig.youtubeApiKey;
    print('✅ YouTube API key initialized');
  } catch (e) {
    print('⚠️  YouTube API key not available. API calls will fail until key is set.');
    youtubeApiKey = '';
  }
}

class YoutubeMobileService {
  final http.Client _client = http.Client();
  final Map<String, String?> _firstVideoCache = {};
  final Map<String, List<Map<String, dynamic>>> _searchCache = {};
  static const int _minFullSongSeconds = 120;

  static const _shortFormKeywords = [
    'shorts',
    '#shorts',
    'reel',
    'remix reel',
    'status',
    'whatsapp status',
  ];

  /// Search YouTube by query (e.g. "trackName artistName"). Returns first video id or null.
  Future<String?> searchFirstVideoId(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return null;

    final cacheKey = trimmed.toLowerCase();
    if (_firstVideoCache.containsKey(cacheKey)) {
      return _firstVideoCache[cacheKey];
    }

    final list = await searchSongs(trimmed);
    final first = list.isEmpty ? null : (list.first['id'] as String?);
    _firstVideoCache[cacheKey] = first;
    return first;
  }

  /// Search YouTube by query (any language). Returns list of songs for suggestions/queue.
  /// Same API as web; works for Hindi, English, Spanish, etc.
  Future<List<Map<String, dynamic>>> searchSongs(String query) async {
    final trimmedQuery = query.trim();
    if (trimmedQuery.isEmpty) {
      return const [];
    }

    final cacheKey = trimmedQuery.toLowerCase();
    final cached = _searchCache[cacheKey];
    if (cached != null) return cached;

    final uri = Uri.parse(
      'https://www.googleapis.com/youtube/v3/search?part=snippet&maxResults=25&q=${Uri.encodeQueryComponent(trimmedQuery)}&type=video&key=$youtubeApiKey',
    );

    try {
      final response = await _client.get(uri).timeout(const Duration(seconds: 6));
      if (response.statusCode == 403) {
        // Quota exceeded - throw exception to show user-friendly error
        throw Exception('YouTube API quota exceeded: ${response.body}');
      }
      if (response.statusCode != 200) {
        _searchCache[cacheKey] = const [];
        return const [];
      }

      final data = json.decode(response.body) as Map<String, dynamic>?;
      final items = data?['items'] as List<dynamic>?;
      if (items == null || items.isEmpty) {
        _searchCache[cacheKey] = const [];
        return const [];
      }

      final raw = items
          .map((item) => {
                'id': item['id']['videoId'],
                'title': item['snippet']['title'],
                'thumbnail': item['snippet']['thumbnails']['default']['url'],
                'artist': item['snippet']['channelTitle'],
                'description': item['snippet']['description'] ?? '',
              })
          .where((row) => (row['id'] as String? ?? '').isNotEmpty)
          .toList();

      if (raw.isEmpty) {
        _searchCache[cacheKey] = const [];
        return const [];
      }

      final durations = await _fetchDurationsSeconds(
        raw.map((e) => e['id'] as String).toList(),
      );

      final results = raw.where((row) {
        final id = row['id'] as String;
        final duration = durations[id] ?? 0;
        final title = (row['title'] as String? ?? '').toLowerCase();
        final description = (row['description'] as String? ?? '').toLowerCase();
        if (duration < _minFullSongSeconds) return false;
        if (_containsAny(title, _shortFormKeywords)) return false;
        if (_containsAny(description, _shortFormKeywords)) return false;
        return true;
      }).map((row) {
        final id = row['id'] as String;
        return {
          ...row,
          'durationSeconds': durations[id] ?? 0,
        };
      }).toList();

      _searchCache[cacheKey] = results;
      return results;
    } catch (_) {
      _searchCache[cacheKey] = const [];
      return const [];
    }
  }

  Future<Map<String, int>> _fetchDurationsSeconds(List<String> ids) async {
    if (ids.isEmpty) return const {};

    final uri = Uri.parse(
      'https://www.googleapis.com/youtube/v3/videos'
      '?part=contentDetails&id=${Uri.encodeQueryComponent(ids.join(','))}&key=$youtubeApiKey',
    );

    try {
      final response = await _client.get(uri).timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) return const {};

      final data = json.decode(response.body) as Map<String, dynamic>?;
      final items = data?['items'] as List<dynamic>?;
      if (items == null || items.isEmpty) return const {};

      final byId = <String, int>{};
      for (final item in items) {
        final map = item as Map<String, dynamic>;
        final id = map['id'] as String?;
        final content = map['contentDetails'] as Map<String, dynamic>?;
        final iso = content?['duration'] as String?;
        if (id == null || iso == null) continue;
        byId[id] = _parseIsoDurationSeconds(iso);
      }
      return byId;
    } catch (_) {
      return const {};
    }
  }

  int _parseIsoDurationSeconds(String iso) {
    final match = RegExp(r'^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$').firstMatch(iso);
    if (match == null) return 0;
    final h = int.tryParse(match.group(1) ?? '0') ?? 0;
    final m = int.tryParse(match.group(2) ?? '0') ?? 0;
    final s = int.tryParse(match.group(3) ?? '0') ?? 0;
    return (h * 3600) + (m * 60) + s;
  }

  bool _containsAny(String value, List<String> terms) {
    for (final t in terms) {
      if (value.contains(t)) return true;
    }
    return false;
  }
}
