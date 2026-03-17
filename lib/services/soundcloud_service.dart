import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'env_config.dart';

class SoundCloudTrack {
  const SoundCloudTrack({
    required this.id,
    required this.title,
    required this.userName,
    required this.durationMs,
  });

  final int id;
  final String title;
  final String userName;
  final int durationMs;
}

class SoundCloudService {
  SoundCloudService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  String? _accessToken;
  DateTime? _expiresAt;

  Future<String?> _getAccessToken() async {
    final clientId = EnvConfig.soundcloudClientId;
    final clientSecret = EnvConfig.soundcloudClientSecret;
    if (clientId.isEmpty || clientSecret.isEmpty) return null;

    final now = DateTime.now();
    if (_accessToken != null && _expiresAt != null && now.isBefore(_expiresAt!)) {
      return _accessToken;
    }

    // NOTE: embedding a client_secret in a mobile app is not secure.
    // This is best moved to a backend proxy, but implemented here per request.
    final uri = Uri.parse('https://secure.soundcloud.com/oauth/token');
    try {
      final resp = await _client.post(
        uri,
        headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'client_credentials',
          'client_id': clientId,
          'client_secret': clientSecret,
        },
      ).timeout(const Duration(seconds: 8));

      if (resp.statusCode != 200) {
        debugPrint('SoundCloud token failed: ${resp.statusCode} ${resp.body}');
        return null;
      }

      final map = json.decode(resp.body) as Map<String, dynamic>?;
      final token = map?['access_token'] as String?;
      final expiresIn = (map?['expires_in'] as num?)?.toInt() ?? 0;
      if (token == null || token.isEmpty) return null;

      _accessToken = token;
      // Keep a small buffer.
      _expiresAt = DateTime.now().add(Duration(seconds: (expiresIn - 30).clamp(60, 6 * 3600)));
      return _accessToken;
    } catch (e) {
      debugPrint('SoundCloud token exception: $e');
      return null;
    }
  }

  Future<List<SoundCloudTrack>> searchTracks(String query, {int limit = 10}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    final token = await _getAccessToken();
    if (token == null || token.isEmpty) return const [];

    final safeLimit = limit.clamp(1, 25);
    final uri = Uri.parse(
      'https://api.soundcloud.com/search/tracks'
      '?q=${Uri.encodeQueryComponent(trimmed)}'
      '&limit=$safeLimit',
    );

    try {
      final resp = await _client.get(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 8));

      if (resp.statusCode != 200) {
        debugPrint('SoundCloud search failed: ${resp.statusCode} ${resp.body}');
        return const [];
      }

      final map = json.decode(resp.body) as Map<String, dynamic>?;
      final collection = map?['collection'] as List<dynamic>?;
      if (collection == null || collection.isEmpty) return const [];

      final tracks = <SoundCloudTrack>[];
      for (final row in collection) {
        final t = row as Map<String, dynamic>;
        final id = (t['id'] as num?)?.toInt() ?? 0;
        final title = (t['title'] as String?) ?? '';
        final duration = (t['duration'] as num?)?.toInt() ?? 0;
        final user = (t['user'] as Map<String, dynamic>?)?['username'] as String? ?? '';
        if (id <= 0 || title.isEmpty) continue;
        tracks.add(SoundCloudTrack(id: id, title: title, userName: user, durationMs: duration));
      }
      return tracks;
    } catch (e) {
      debugPrint('SoundCloud search exception: $e');
      return const [];
    }
  }

  Future<String?> getBestStreamUrl(int trackId) async {
    final token = await _getAccessToken();
    if (token == null || token.isEmpty) return null;

    final uri = Uri.parse('https://api.soundcloud.com/tracks/$trackId/streams');
    try {
      final resp = await _client.get(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 8));

      if (resp.statusCode != 200) {
        debugPrint('SoundCloud streams failed: ${resp.statusCode} ${resp.body}');
        return null;
      }

      final map = json.decode(resp.body) as Map<String, dynamic>?;
      final url = (map?['hls_aac_160_url'] as String?) ??
          (map?['hls_aac_96_url'] as String?) ??
          (map?['http_mp3_128_url'] as String?);

      return (url == null || url.isEmpty) ? null : url;
    } catch (e) {
      debugPrint('SoundCloud streams exception: $e');
      return null;
    }
  }

  Future<({SoundCloudTrack track, double confidence, String streamUrl})?> findMirrorStream({
    required String trackName,
    required String artistName,
  }) async {
    final t = trackName.trim();
    final a = artistName.trim();
    if (t.isEmpty && a.isEmpty) return null;

    final query = [t, a].where((s) => s.isNotEmpty).join(' ');
    final results = await searchTracks(query, limit: 20);
    if (results.isEmpty) return null;

    double bestScore = -1;
    SoundCloudTrack? best;
    for (final r in results) {
      final titleScore = _tokenSimilarity(r.title, t);
      final artistScore = _tokenSimilarity(r.userName, a);
      var score = (0.7 * titleScore) + (0.3 * artistScore);
      if (a.isNotEmpty && artistScore < 0.2) score -= 0.12;
      if (score > bestScore) {
        bestScore = score;
        best = r;
      }
    }

    if (best == null) return null;
    final streamUrl = await getBestStreamUrl(best.id);
    if (streamUrl == null || streamUrl.isEmpty) return null;

    return (track: best, confidence: bestScore.clamp(0, 1).toDouble(), streamUrl: streamUrl);
  }

  double _tokenSimilarity(String a, String b) {
    final left = _tokens(a);
    final right = _tokens(b);
    if (left.isEmpty || right.isEmpty) return 0;
    final intersection = left.intersection(right).length;
    final union = left.union(right).length;
    if (union == 0) return 0;
    return intersection / union;
  }

  Set<String> _tokens(String s) {
    final cleaned = s
        .toLowerCase()
        .replaceAll(RegExp(r'[\(\)\[\]\{\}]'), ' ')
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return {};

    final stop = {
      'the',
      'a',
      'an',
      'and',
      'or',
      'feat',
      'ft',
      'official',
      'audio',
      'video',
      'lyrics',
      'lyric',
      'remix',
      'edit',
      'version',
    };

    return cleaned
        .split(' ')
        .where((t) => t.length >= 2 && !stop.contains(t))
        .toSet();
  }
}

