// Genius API: lyric-oriented search that complements LRCLIB (strong on hip-hop / annotations).
// Optional — set GENIUS_ACCESS_TOKEN in .env (https://genius.com/api-clients).

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'env_config.dart';
import 'lyrics_service.dart';

/// One song hit from Genius search (enough to resolve YouTube).
class GeniusSongHit {
  const GeniusSongHit({
    required this.title,
    required this.artistName,
    this.snippet,
    this.fullTitle,
  });

  final String title;
  final String artistName;
  final String? snippet;
  final String? fullTitle;
}

class GeniusSearchService {
  GeniusSearchService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  final Map<String, List<GeniusSongHit>> _cache = {};

  /// Search by a lyric line or phrase. Returns [] if token missing or request fails.
  Future<List<GeniusSongHit>> searchLyricLine(String line) async {
    final token = EnvConfig.geniusAccessToken;
    if (token.isEmpty) return const [];

    final q = line.trim();
    if (q.isEmpty) return const [];

    final cacheKey = q.toLowerCase();
    if (_cache.containsKey(cacheKey)) {
      return _cache[cacheKey]!;
    }

    var hits = await _search(q, token);
    if (hits.isEmpty && q.split(RegExp(r'\s+')).length > 10) {
      for (final phrase in LyricsService.lyricLineScoringPhrases(q)) {
        if (phrase.length < q.length * 0.65 && phrase.length >= 12) {
          hits = await _search(phrase, token);
          if (hits.isNotEmpty) break;
        }
      }
    }

    _cache[cacheKey] = hits;
    return hits;
  }

  Future<List<GeniusSongHit>> _search(String query, String token) async {
    try {
      final uri = Uri.parse(
        'https://api.genius.com/search?q=${Uri.encodeQueryComponent(query)}',
      );
      final response = await _client
          .get(
            uri,
            headers: {
              'Authorization': 'Bearer $token',
              'User-Agent': 'MongoBox/1.0',
            },
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        return const [];
      }

      final data = json.decode(response.body) as Map<String, dynamic>?;
      final responseMap = data?['response'] as Map<String, dynamic>?;
      final rawHits = responseMap?['hits'] as List<dynamic>?;
      if (rawHits == null || rawHits.isEmpty) return const [];

      final out = <GeniusSongHit>[];
      for (final item in rawHits) {
        if (item is! Map<String, dynamic>) continue;
        final result = item['result'] as Map<String, dynamic>?;
        if (result == null) continue;

        final title = (result['title'] as String?)?.trim() ?? '';
        if (title.isEmpty) continue;

        final fullTitle = result['full_title'] as String?;

        String artistName = '';
        final primary = result['primary_artist'];
        if (primary is Map<String, dynamic>) {
          artistName = (primary['name'] as String?)?.trim() ?? '';
        }
        if (artistName.isEmpty) {
          final artists = result['artist_names'];
          if (artists is List && artists.isNotEmpty) {
            final first = artists.first;
            if (first is String) artistName = first.trim();
          }
        }
        if (artistName.isEmpty && fullTitle != null && fullTitle.contains(' by ')) {
          final parts = fullTitle.split(' by ');
          if (parts.length >= 2) {
            artistName = parts[1].split(RegExp(r'\(|Ft\.|feat\.', caseSensitive: false)).first.trim();
          }
        }
        final snippet = _snippetFromHit(item, result);

        out.add(GeniusSongHit(
          title: title,
          artistName: artistName,
          snippet: snippet,
          fullTitle: fullTitle,
        ));
        if (out.length >= 12) break;
      }

      return out;
    } catch (_) {
      return const [];
    }
  }

  String? _snippetFromHit(Map<String, dynamic> hit, Map<String, dynamic> result) {
    final high = hit['highlights'];
    if (high is List && high.isNotEmpty) {
      final first = high.first;
      if (first is Map<String, dynamic>) {
        final t = first['text'] as String?;
        if (t != null && t.trim().isNotEmpty) return t.trim();
      }
    }
    final path = result['path'] as String?;
    if (path != null && path.trim().isNotEmpty) return path.trim();
    return result['full_title'] as String?;
  }
}
