// YouTube Data API search for mobile (same API key as web).

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'env_config.dart';
import 'lyrics_service.dart';
import 'youtube_quota_monitor.dart';

String? _youtubeApiKeyOverride;

void setYoutubeApiKeyOverride(String? apiKey) {
  final trimmed = apiKey?.trim() ?? '';
  _youtubeApiKeyOverride = trimmed.isEmpty ? null : trimmed;
}

String getActiveYoutubeApiKey() {
  final override = _youtubeApiKeyOverride;
  if (override != null && override.isNotEmpty) {
    return override;
  }

  final resolved = EnvConfig.youtubeApiKey.trim();
  if (resolved.isEmpty) {
    throw Exception(
      'YouTube API key missing. Add a valid YOUTUBE_API_KEY in .env.',
    );
  }
  return resolved;
}

String activeYoutubeApiKeyFingerprint() {
  try {
    final apiKey = getActiveYoutubeApiKey();
    if (apiKey.length <= 8) return apiKey;
    return apiKey.substring(apiKey.length - 8);
  } catch (_) {
    return 'missing-key';
  }
}

class YoutubeMobileService {
  final http.Client _client = http.Client();
  final YouTubeQuotaMonitor _quotaMonitor = YouTubeQuotaMonitor();
  static final Map<String, String?> _firstVideoCache = {};
  static final Map<String, List<Map<String, dynamic>>> _searchCache = {};
  static final Map<String, _CachedVideoIdEntry> _songVideoCache = {};
  static Future<SharedPreferences>? _prefsFuture;
  static bool _persistentStateLoaded = false;
  static const int _minFullSongSeconds = 120;
  static const int _defaultSearchMaxResults = 8;
  static const int _resolverSearchMaxResults = 2;
  static const int _maxPersistedSearchEntries = 80;
  static const int _maxPersistedSongEntries = 200;
  static const Duration _searchCacheTtl = Duration(days: 3);
  static const Duration _emptySearchCacheTtl = Duration(hours: 6);
  static const Duration _songVideoCacheTtl = Duration(days: 7);
  static const Duration _videoVerificationTtl = Duration(hours: 24);
  static const String _searchCachePrefsKey = 'youtube_search_cache_v2';
  static const String _songCachePrefsKey = 'youtube_song_id_cache_v2';

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

    final cacheKey = _cacheKey(trimmed);
    if (_firstVideoCache.containsKey(cacheKey)) {
      return _firstVideoCache[cacheKey];
    }

    final list = await searchSongs(trimmed, maxResults: 1);
    final first = list.isEmpty ? null : (list.first['id'] as String?);
    _firstVideoCache[cacheKey] = first;
    return first;
  }

  /// Resolve a likely canonical video ID for a known artist + title pair.
  /// This prefers the local fingerprint cache, then verifies old cached IDs
  /// with a cheap `videos.list` call before making any new 100-unit searches.
  Future<String?> resolveSongVideoId(
    String trackName,
    String artistName,
  ) async {
    final normalizedTrack = trackName.trim();
    final normalizedArtist = artistName.trim();
    if (normalizedTrack.isEmpty && normalizedArtist.isEmpty) return null;

    final songKey = _songKey(normalizedTrack, normalizedArtist);
    await _ensurePersistentStateLoaded();

    final cached = _songVideoCache[songKey];
    if (cached != null) {
      if (!_needsVideoVerification(cached)) {
        return cached.videoId;
      }

      final stillAvailable = await _videoExists(cached.videoId);
      if (stillAvailable == true) {
        await _rememberSongVideoId(
          songKey,
          cached.videoId,
          verifiedAt: DateTime.now(),
        );
        return cached.videoId;
      }

      if (stillAvailable == null) {
        return cached.videoId;
      }

      await _forgetSongVideoId(songKey);
    }

    final pool = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final query in _buildSongResolverQueries(
      normalizedTrack,
      normalizedArtist,
    )) {
      final list = await searchSongs(
        query,
        maxResults: _resolverSearchMaxResults,
      );
      for (final item in list) {
        final videoId = item['id'] as String? ?? '';
        if (videoId.isEmpty || !seen.add(videoId)) continue;
        pool.add(item);
      }
      if (pool.length >= 6) break;
    }

    if (pool.isEmpty) return null;

    pool.sort(
      (a, b) => _scoreResolverCandidate(
        b,
        trackName: normalizedTrack,
        artistName: normalizedArtist,
      ).compareTo(
        _scoreResolverCandidate(
          a,
          trackName: normalizedTrack,
          artistName: normalizedArtist,
        ),
      ),
    );

    final pickedId = pool.first['id'] as String? ?? '';
    if (pickedId.isEmpty) return null;

    await _rememberSongVideoId(songKey, pickedId, verifiedAt: DateTime.now());
    return pickedId;
  }

  /// Search YouTube by query (any language). Returns list of songs for suggestions/queue.
  /// Same API as web; works for Hindi, English, Spanish, etc.
  Future<List<Map<String, dynamic>>> searchSongs(
    String query, {
    int maxResults = _defaultSearchMaxResults,
    bool allowInvidiousFallback = true,
  }) async {
    final trimmedQuery = query.trim();
    if (trimmedQuery.isEmpty) {
      return const [];
    }

    final requestedResults = maxResults.clamp(1, 25).toInt();
    final cacheKey = _cacheKey(trimmedQuery);
    final cached = _searchCache[cacheKey];
    if (cached != null && cached.isNotEmpty) {
      return cached.take(requestedResults).toList();
    }

    await _ensurePersistentStateLoaded();
    final persistedSearch = _readPersistedSearch(cacheKey);
    if (persistedSearch != null) {
      _searchCache[cacheKey] = persistedSearch;
      return persistedSearch.take(requestedResults).toList();
    }

    try {
      final youtubeResults = await _searchSongsFromYoutube(
        trimmedQuery,
        maxResults: requestedResults,
      );
      await _rememberSearchResults(cacheKey, youtubeResults);
      return youtubeResults.take(requestedResults).toList();
    } catch (e) {
      if (allowInvidiousFallback) {
        final fallback = await _searchSongsFromInvidious(
          trimmedQuery,
          maxResults: requestedResults,
        );
        if (fallback.isNotEmpty) {
          await _rememberSearchResults(cacheKey, fallback);
          return fallback.take(requestedResults).toList();
        }
      }

      if (_isYoutubeConfigError(e)) rethrow;
      await _rememberSearchResults(cacheKey, const []);
      return const [];
    }
  }

  Future<List<Map<String, dynamic>>> _searchSongsFromYoutube(
    String query, {
    required int maxResults,
  }) async {
    final apiKey = getActiveYoutubeApiKey();
    final uri = Uri.parse(
      'https://www.googleapis.com/youtube/v3/search'
      '?part=snippet&maxResults=$maxResults&q=${Uri.encodeQueryComponent(query)}'
      '&type=video&key=$apiKey',
    );

    final response = await _client.get(uri).timeout(const Duration(seconds: 6));
    _quotaMonitor.logSearchCall(query);

    if (response.statusCode == 400) {
      final reason = _extractYoutubeErrorReason(response.body);
      if (reason == 'badRequest' || reason == 'keyInvalid') {
        throw Exception(
          'YouTube API key is invalid. Update YOUTUBE_API_KEY in .env.',
        );
      }
    }
    if (response.statusCode == 403) {
      throw Exception('YouTube API quota exceeded: ${response.body}');
    }
    if (response.statusCode != 200) {
      return const [];
    }

    final data = json.decode(response.body) as Map<String, dynamic>?;
    final items = data?['items'] as List<dynamic>?;
    if (items == null || items.isEmpty) {
      return const [];
    }

    final raw =
        items
            .map(
              (item) => {
                'id': item['id']['videoId'],
                'title': item['snippet']['title'],
                'thumbnail': item['snippet']['thumbnails']['default']['url'],
                'artist': item['snippet']['channelTitle'],
                'description': item['snippet']['description'] ?? '',
                'source': 'youtube-api',
              },
            )
            .where((row) => (row['id'] as String? ?? '').isNotEmpty)
            .toList();

    if (raw.isEmpty) {
      return const [];
    }

    final durations = await _fetchDurationsSeconds(
      raw.map((e) => e['id'] as String).toList(),
    );

    return raw
        .where((row) {
          final id = row['id'] as String;
          final duration = durations[id] ?? 0;
          final title = (row['title'] as String? ?? '').toLowerCase();
          final description =
              (row['description'] as String? ?? '').toLowerCase();
          if (duration < _minFullSongSeconds) return false;
          if (_containsAny(title, _shortFormKeywords)) return false;
          if (_containsAny(description, _shortFormKeywords)) return false;
          return true;
        })
        .map((row) {
          final id = row['id'] as String;
          return {...row, 'durationSeconds': durations[id] ?? 0};
        })
        .toList();
  }

  Future<List<Map<String, dynamic>>> _searchSongsFromInvidious(
    String query, {
    required int maxResults,
  }) async {
    final baseUrl = EnvConfig.invidiousBaseUrl;
    if (baseUrl.isEmpty) {
      return const [];
    }

    try {
      final uri = Uri.parse(
        '$baseUrl/api/v1/search?q=${Uri.encodeQueryComponent(query)}&type=video',
      );
      final response = await _client
          .get(uri)
          .timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) {
        return const [];
      }

      final decoded = json.decode(response.body) as List<dynamic>?;
      if (decoded == null || decoded.isEmpty) return const [];

      return decoded
          .whereType<Map<String, dynamic>>()
          .map((item) {
            final thumbs =
                (item['videoThumbnails'] as List<dynamic>?)
                    ?.whereType<Map<String, dynamic>>()
                    .toList() ??
                const [];
            final thumbnail =
                thumbs.isNotEmpty ? (thumbs.last['url'] as String? ?? '') : '';
            final durationSeconds =
                (item['lengthSeconds'] as num?)?.toInt() ?? 0;
            return {
              'id': item['videoId'] as String? ?? '',
              'title': item['title'] as String? ?? '',
              'thumbnail': thumbnail,
              'artist': item['author'] as String? ?? '',
              'description': item['description'] as String? ?? '',
              'durationSeconds': durationSeconds,
              'source': 'invidious',
            };
          })
          .where((row) {
            final id = row['id'] as String? ?? '';
            final duration = (row['durationSeconds'] as num?)?.toInt() ?? 0;
            final title = (row['title'] as String? ?? '').toLowerCase();
            final description =
                (row['description'] as String? ?? '').toLowerCase();
            if (id.isEmpty || duration < _minFullSongSeconds) return false;
            if (_containsAny(title, _shortFormKeywords)) return false;
            if (_containsAny(description, _shortFormKeywords)) return false;
            return true;
          })
          .take(maxResults)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<Map<String, int>> _fetchDurationsSeconds(List<String> ids) async {
    if (ids.isEmpty) return const {};

    final uri = Uri.parse(
      'https://www.googleapis.com/youtube/v3/videos'
      '?part=contentDetails&id=${Uri.encodeQueryComponent(ids.join(','))}&key=${getActiveYoutubeApiKey()}',
    );

    try {
      final response = await _client
          .get(uri)
          .timeout(const Duration(seconds: 6));
      _quotaMonitor.logVideoCall(ids);
      if (response.statusCode == 400) {
        final reason = _extractYoutubeErrorReason(response.body);
        if (reason == 'badRequest' || reason == 'keyInvalid') {
          throw Exception(
            'YouTube API key is invalid. Update YOUTUBE_API_KEY in .env.',
          );
        }
      }
      if (response.statusCode == 403) {
        throw Exception('YouTube API quota exceeded: ${response.body}');
      }
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
    } catch (e) {
      if (_isYoutubeConfigError(e)) rethrow;
      return const {};
    }
  }

  int _parseIsoDurationSeconds(String iso) {
    final match = RegExp(
      r'^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$',
    ).firstMatch(iso);
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

  String _extractYoutubeErrorReason(String body) {
    try {
      final decoded = json.decode(body) as Map<String, dynamic>;
      final error = decoded['error'] as Map<String, dynamic>?;
      final errors = error?['errors'] as List<dynamic>?;
      if (errors != null && errors.isNotEmpty) {
        final first = errors.first as Map<String, dynamic>;
        final reason = (first['reason'] as String?)?.trim();
        if (reason != null && reason.isNotEmpty) return reason;
      }
      final message = (error?['message'] as String?)?.toLowerCase() ?? '';
      if (message.contains('api key not valid')) return 'keyInvalid';
    } catch (_) {
      // Keep fallback empty.
    }
    return '';
  }

  bool _isYoutubeConfigError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('api key') || text.contains('quota exceeded');
  }

  String _cacheKey(String query) => _normalizeFingerprint(query);

  String _songKey(String trackName, String artistName) =>
      _normalizeFingerprint('$trackName $artistName');

  String _normalizeFingerprint(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  List<String> _buildSongResolverQueries(String trackName, String artistName) {
    final cleanTrack = trackName.trim();
    final cleanArtist = artistName.trim();
    final base = '$cleanArtist $cleanTrack'.trim();
    final queries = <String>[
      '$cleanArtist $cleanTrack official audio',
      '$cleanArtist $cleanTrack official video',
      '$cleanArtist $cleanTrack topic',
      '$cleanTrack $cleanArtist official',
      base,
    ];

    final seen = <String>{};
    return queries
        .map((q) => q.trim())
        .where((q) => q.isNotEmpty && seen.add(q.toLowerCase()))
        .toList();
  }

  double _scoreResolverCandidate(
    Map<String, dynamic> song, {
    required String trackName,
    required String artistName,
  }) {
    final title = (song['title'] as String? ?? '').toLowerCase();
    final channel = (song['artist'] as String? ?? '').toLowerCase();
    final description = (song['description'] as String? ?? '').toLowerCase();
    final durationSeconds = (song['durationSeconds'] as num?)?.toInt() ?? 0;

    final identity = '$trackName $artistName'.trim();
    var score = LyricsService.scoreTextMatch('$title $channel', identity);

    if (title.contains(trackName.toLowerCase())) score += 0.14;
    if (title.contains(artistName.toLowerCase()) ||
        channel.contains(artistName.toLowerCase())) {
      score += 0.14;
    }
    if (title.contains('official audio') || title.contains('official video')) {
      score += 0.16;
    }
    if (channel.contains('- topic') || channel.contains('official')) {
      score += 0.12;
    }
    if (description.contains('official')) score += 0.05;
    if (durationSeconds >= 150) score += 0.1;
    if (_containsAny(title, _shortFormKeywords) ||
        _containsAny(description, _shortFormKeywords)) {
      score -= 0.4;
    }

    return score;
  }

  Future<bool?> _videoExists(String videoId) async {
    final trimmed = videoId.trim();
    if (trimmed.isEmpty) return false;

    final uri = Uri.parse(
      'https://www.googleapis.com/youtube/v3/videos'
      '?part=status&id=${Uri.encodeQueryComponent(trimmed)}'
      '&key=${getActiveYoutubeApiKey()}',
    );

    try {
      final response = await _client
          .get(uri)
          .timeout(const Duration(seconds: 6));
      _quotaMonitor.logVideoCall([trimmed]);
      if (response.statusCode == 403) {
        throw Exception('YouTube API quota exceeded: ${response.body}');
      }
      if (response.statusCode != 200) return false;
      final data = json.decode(response.body) as Map<String, dynamic>?;
      final items = data?['items'] as List<dynamic>?;
      return items != null && items.isNotEmpty;
    } catch (_) {
      return null;
    }
  }

  bool _needsVideoVerification(_CachedVideoIdEntry entry) {
    final verifiedAt = entry.verifiedAt;
    if (verifiedAt == null) return true;
    return DateTime.now().difference(verifiedAt) >= _videoVerificationTtl;
  }

  Future<void> _ensurePersistentStateLoaded() async {
    if (_persistentStateLoaded) return;

    final prefs = await _getPrefs();

    _searchCache.clear();
    _songVideoCache.clear();

    final searchRaw = prefs.getString(_searchCachePrefsKey);
    if (searchRaw != null && searchRaw.isNotEmpty) {
      try {
        final decoded = json.decode(searchRaw) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          final parsed = _CachedSearchEntry.fromJson(
            entry.value as Map<String, dynamic>?,
          );
          if (parsed == null || parsed.isExpired) continue;
          _searchCache[entry.key] = parsed.results;
        }
      } catch (_) {
        // Ignore corrupt cache and rebuild naturally.
      }
    }

    final songRaw = prefs.getString(_songCachePrefsKey);
    if (songRaw != null && songRaw.isNotEmpty) {
      try {
        final decoded = json.decode(songRaw) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          final parsed = _CachedVideoIdEntry.fromJson(
            entry.value as Map<String, dynamic>?,
          );
          if (parsed == null || parsed.isExpired) continue;
          _songVideoCache[entry.key] = parsed;
        }
      } catch (_) {
        // Ignore corrupt cache and rebuild naturally.
      }
    }

    _persistentStateLoaded = true;
  }

  List<Map<String, dynamic>>? _readPersistedSearch(String cacheKey) {
    final cached = _searchCache[cacheKey];
    if (cached == null) return null;
    return List<Map<String, dynamic>>.from(cached);
  }

  Future<void> _rememberSearchResults(
    String cacheKey,
    List<Map<String, dynamic>> results,
  ) async {
    final copy = results.map((row) => Map<String, dynamic>.from(row)).toList();
    _searchCache[cacheKey] = copy;

    final prefs = await _getPrefs();
    final existing = _decodeJsonMap(prefs.getString(_searchCachePrefsKey));
    existing[cacheKey] =
        _CachedSearchEntry(
          results: copy,
          savedAt: DateTime.now(),
          expiresAt: DateTime.now().add(
            results.isEmpty ? _emptySearchCacheTtl : _searchCacheTtl,
          ),
        ).toJson();
    _trimPersistedMap(existing, _maxPersistedSearchEntries);
    await prefs.setString(_searchCachePrefsKey, json.encode(existing));
  }

  Future<void> _rememberSongVideoId(
    String songKey,
    String videoId, {
    DateTime? verifiedAt,
  }) async {
    final entry = _CachedVideoIdEntry(
      videoId: videoId,
      savedAt: DateTime.now(),
      expiresAt: DateTime.now().add(_songVideoCacheTtl),
      verifiedAt: verifiedAt,
    );
    _songVideoCache[songKey] = entry;

    final prefs = await _getPrefs();
    final existing = _decodeJsonMap(prefs.getString(_songCachePrefsKey));
    existing[songKey] = entry.toJson();
    _trimPersistedMap(existing, _maxPersistedSongEntries);
    await prefs.setString(_songCachePrefsKey, json.encode(existing));
  }

  Future<void> _forgetSongVideoId(String songKey) async {
    _songVideoCache.remove(songKey);
    final prefs = await _getPrefs();
    final existing = _decodeJsonMap(prefs.getString(_songCachePrefsKey));
    existing.remove(songKey);
    await prefs.setString(_songCachePrefsKey, json.encode(existing));
  }

  Future<SharedPreferences> _getPrefs() {
    return _prefsFuture ??= SharedPreferences.getInstance();
  }

  Map<String, dynamic> _decodeJsonMap(String? raw) {
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      return json.decode(raw) as Map<String, dynamic>;
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  void _trimPersistedMap(Map<String, dynamic> map, int maxEntries) {
    if (map.length <= maxEntries) return;

    final entries =
        map.entries.toList()..sort((a, b) {
          final aSaved =
              (a.value as Map<String, dynamic>?)?['savedAtMs'] as num? ?? 0;
          final bSaved =
              (b.value as Map<String, dynamic>?)?['savedAtMs'] as num? ?? 0;
          return bSaved.compareTo(aSaved);
        });

    map
      ..clear()
      ..addEntries(entries.take(maxEntries));
  }
}

class _CachedSearchEntry {
  const _CachedSearchEntry({
    required this.results,
    required this.savedAt,
    required this.expiresAt,
  });

  final List<Map<String, dynamic>> results;
  final DateTime savedAt;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  Map<String, dynamic> toJson() => {
    'results': results,
    'savedAtMs': savedAt.millisecondsSinceEpoch,
    'expiresAtMs': expiresAt.millisecondsSinceEpoch,
  };

  static _CachedSearchEntry? fromJson(Map<String, dynamic>? jsonMap) {
    if (jsonMap == null) return null;
    final rawResults = jsonMap['results'] as List<dynamic>?;
    if (rawResults == null) return null;
    final savedAtMs = (jsonMap['savedAtMs'] as num?)?.toInt() ?? 0;
    final expiresAtMs = (jsonMap['expiresAtMs'] as num?)?.toInt() ?? 0;
    return _CachedSearchEntry(
      results:
          rawResults
              .whereType<Map<String, dynamic>>()
              .map((row) => Map<String, dynamic>.from(row))
              .toList(),
      savedAt: DateTime.fromMillisecondsSinceEpoch(savedAtMs),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAtMs),
    );
  }
}

class _CachedVideoIdEntry {
  const _CachedVideoIdEntry({
    required this.videoId,
    required this.savedAt,
    required this.expiresAt,
    this.verifiedAt,
  });

  final String videoId;
  final DateTime savedAt;
  final DateTime expiresAt;
  final DateTime? verifiedAt;

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  Map<String, dynamic> toJson() => {
    'videoId': videoId,
    'savedAtMs': savedAt.millisecondsSinceEpoch,
    'expiresAtMs': expiresAt.millisecondsSinceEpoch,
    'verifiedAtMs': verifiedAt?.millisecondsSinceEpoch,
  };

  static _CachedVideoIdEntry? fromJson(Map<String, dynamic>? jsonMap) {
    if (jsonMap == null) return null;
    final videoId = jsonMap['videoId'] as String?;
    if (videoId == null || videoId.trim().isEmpty) return null;
    final savedAtMs = (jsonMap['savedAtMs'] as num?)?.toInt() ?? 0;
    final expiresAtMs = (jsonMap['expiresAtMs'] as num?)?.toInt() ?? 0;
    final verifiedAtMs = (jsonMap['verifiedAtMs'] as num?)?.toInt();
    return _CachedVideoIdEntry(
      videoId: videoId,
      savedAt: DateTime.fromMillisecondsSinceEpoch(savedAtMs),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAtMs),
      verifiedAt:
          verifiedAtMs == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(verifiedAtMs),
    );
  }
}
