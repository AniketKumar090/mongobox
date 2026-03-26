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

class SoundCloudStreamSource {
  const SoundCloudStreamSource({required this.url, this.headers});

  final String url;
  final Map<String, String>? headers;
}

class SoundCloudService {
  SoundCloudService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  String? _accessToken;
  DateTime? _expiresAt;
  Future<String?>? _tokenRequest;

  void _clearTokenCache() {
    _accessToken = null;
    _expiresAt = null;
  }

  Map<String, String> _oauthHeaders(String token) => {
    'Authorization': 'OAuth $token',
    'Accept': '*/*',
  };

  bool _isValidStreamUrl(String? url) {
    final trimmed = url?.trim() ?? '';
    if (trimmed.isEmpty) return false;

    final uri = Uri.tryParse(trimmed);
    return uri != null &&
        uri.isAbsolute &&
        (uri.scheme == 'http' || uri.scheme == 'https');
  }

  Future<String?> _getAccessToken({bool forceRefresh = false}) async {
    final clientId = EnvConfig.soundcloudClientId;
    final clientSecret = EnvConfig.soundcloudClientSecret;
    if (clientId.isEmpty || clientSecret.isEmpty) return null;

    final now = DateTime.now();
    if (!forceRefresh &&
        _accessToken != null &&
        _expiresAt != null &&
        now.isBefore(_expiresAt!)) {
      return _accessToken;
    }

    if (_tokenRequest != null) {
      return _tokenRequest!;
    }

    // NOTE: embedding a client_secret in a mobile app is not secure.
    // This is best moved to a backend proxy, but implemented here per request.
    final uri = Uri.parse('https://secure.soundcloud.com/oauth/token');
    final basicAuth = base64Encode(utf8.encode('$clientId:$clientSecret'));
    final request = () async {
      try {
        final resp = await _client
            .post(
              uri,
              headers: {
                'Accept': 'application/json; charset=utf-8',
                'Content-Type': 'application/x-www-form-urlencoded',
                'Authorization': 'Basic $basicAuth',
              },
              body: {'grant_type': 'client_credentials'},
            )
            .timeout(const Duration(seconds: 8));

        if (resp.statusCode != 200) {
          _clearTokenCache();
          debugPrint(
            'SoundCloud token failed: ${resp.statusCode} ${resp.body}',
          );
          return null;
        }

        final map = json.decode(resp.body) as Map<String, dynamic>?;
        final token = map?['access_token'] as String?;
        final expiresIn = (map?['expires_in'] as num?)?.toInt() ?? 3600;
        if (token == null || token.isEmpty) {
          _clearTokenCache();
          return null;
        }

        _accessToken = token;
        // Refresh early so normal requests don't drift into an expired token.
        final refreshWindow = expiresIn > 180 ? 120 : 30;
        _expiresAt = DateTime.now().add(
          Duration(seconds: (expiresIn - refreshWindow).clamp(30, 6 * 3600)),
        );
        return _accessToken;
      } catch (e) {
        _clearTokenCache();
        debugPrint('SoundCloud token exception: $e');
        return null;
      } finally {
        _tokenRequest = null;
      }
    }();

    _tokenRequest = request;
    return request;
  }

  Future<http.Response?> _authorizedGet(Uri uri) async {
    Future<http.Response> perform(String token) {
      return _client
          .get(uri, headers: _oauthHeaders(token))
          .timeout(const Duration(seconds: 8));
    }

    final token = await _getAccessToken();
    if (token == null || token.isEmpty) return null;

    try {
      var resp = await perform(token);
      if (resp.statusCode != 401) {
        return resp;
      }

      // If SoundCloud rejects the cached token, force a refresh and retry once.
      _clearTokenCache();
      final freshToken = await _getAccessToken(forceRefresh: true);
      if (freshToken == null || freshToken.isEmpty) {
        return resp;
      }
      resp = await perform(freshToken);
      return resp;
    } catch (e) {
      debugPrint('SoundCloud request exception: $e');
      return null;
    }
  }

  Future<Map<String, String>?> getPlaybackHeaders() async {
    final token = await _getAccessToken();
    if (token == null || token.isEmpty) return null;
    return _oauthHeaders(token);
  }

  Future<List<SoundCloudTrack>> searchTracks(
    String query, {
    int limit = 10,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    final safeLimit = limit.clamp(1, 25);
    final uri = Uri.parse(
      'https://api.soundcloud.com/tracks'
      '?q=${Uri.encodeQueryComponent(trimmed)}'
      '&access=playable'
      '&linked_partitioning=true'
      '&limit=$safeLimit',
    );

    try {
      final resp = await _authorizedGet(uri);
      if (resp == null) return const [];

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
        final user =
            (t['user'] as Map<String, dynamic>?)?['username'] as String? ?? '';
        if (id <= 0 || title.isEmpty) continue;
        tracks.add(
          SoundCloudTrack(
            id: id,
            title: title,
            userName: user,
            durationMs: duration,
          ),
        );
      }
      return tracks;
    } catch (e) {
      debugPrint('SoundCloud search exception: $e');
      return const [];
    }
  }

  Future<List<SoundCloudStreamSource>> getPlayableStreamSources(
    int trackId,
  ) async {
    final uri = Uri.parse('https://api.soundcloud.com/tracks/$trackId/streams');
    try {
      final resp = await _authorizedGet(uri);
      if (resp == null) return const [];

      if (resp.statusCode != 200) {
        debugPrint(
          'SoundCloud streams failed: ${resp.statusCode} ${resp.body}',
        );
        return const [];
      }

      final map = json.decode(resp.body) as Map<String, dynamic>?;
      final headers = await getPlaybackHeaders();
      final seen = <String>{};
      final sources = <SoundCloudStreamSource>[];

      void addSource(String? url, {required bool withHeaders}) {
        final trimmed = url?.trim() ?? '';
        if (!_isValidStreamUrl(trimmed)) {
          if (trimmed.isNotEmpty) {
            debugPrint('SoundCloud skipped invalid stream URL: $url');
          }
          return;
        }
        final key = '$trimmed|$withHeaders';
        if (!seen.add(key)) return;
        sources.add(
          SoundCloudStreamSource(
            url: trimmed,
            headers: withHeaders ? headers : null,
          ),
        );
      }

      // Prefer unsigned/signed direct playback first, then retry the same
      // variants with OAuth headers for hosts that still require them.
      addSource(map?['hls_aac_160_url'] as String?, withHeaders: false);
      addSource(map?['hls_aac_96_url'] as String?, withHeaders: false);
      addSource(map?['http_mp3_128_url'] as String?, withHeaders: false);
      addSource(map?['preview_mp3_128_url'] as String?, withHeaders: false);

      if (headers != null && headers.isNotEmpty) {
        addSource(map?['hls_aac_160_url'] as String?, withHeaders: true);
        addSource(map?['hls_aac_96_url'] as String?, withHeaders: true);
        addSource(map?['http_mp3_128_url'] as String?, withHeaders: true);
        addSource(map?['preview_mp3_128_url'] as String?, withHeaders: true);
      }

      return sources;
    } catch (e) {
      debugPrint('SoundCloud streams exception: $e');
      return const [];
    }
  }

  Future<
    ({
      SoundCloudTrack track,
      double confidence,
      List<SoundCloudStreamSource> streamSources,
    })?
  >
  findMirrorStream({
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
    final streamSources = await getPlayableStreamSources(best.id);
    if (streamSources.isEmpty) return null;

    return (
      track: best,
      confidence: bestScore.clamp(0, 1).toDouble(),
      streamSources: streamSources,
    );
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
    final cleaned =
        s
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
