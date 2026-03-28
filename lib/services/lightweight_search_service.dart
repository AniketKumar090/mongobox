// Lightweight search service optimized for single-line lyric searches
// Reduces YouTube API quota usage by implementing smart caching and fallback strategies

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'lyrics_service.dart';
import 'youtube_mobile_service.dart';
import 'youtube_quota_monitor.dart';
import 'local_suggestions_service.dart';
import 'playback_service_mobile.dart';
import 'grok_search_refinement_service.dart';

class LightweightSearchResult {
  const LightweightSearchResult({
    required this.videoId,
    required this.trackName,
    required this.artistName,
    required this.startTimeSeconds,
    required this.confidence,
    this.matchedLineTimeSeconds,
    this.matchedLyricLine,
    this.source = 'lightweight',
  });

  final String videoId;
  final String trackName;
  final String artistName;
  final int startTimeSeconds;
  final double confidence;
  final int? matchedLineTimeSeconds;
  final String? matchedLyricLine;
  final String source;
}

class LightweightSearchService {
  final LyricsService _lyrics = LyricsService();
  final YoutubeMobileService _youtube = YoutubeMobileService();
  final YouTubeQuotaMonitor _quotaMonitor = YouTubeQuotaMonitor();
  final http.Client _client = http.Client();
  final GrokSearchRefinement _grokRefinement = GrokSearchRefinement();

  // Aggressive caching to reduce API calls
  final Map<String, List<LightweightSearchResult>> _searchCache = {};
  final Map<String, String> _videoIdCache = {};
  final Map<String, String> _titleCache = {};

  // When quota is exceeded, only use cached results
  bool get _isQuotaExceeded {
    final status = _quotaMonitor.getStatus();
    return status.estimatedRemaining <
        500; // Use cached results when less than 500 units left
  }

  /// Prime in-memory caches from disk-stored recent tracks (no API calls).
  void seedFromRecentTracks(List<RecentTrack> tracks) {
    for (final track in tracks) {
      if ((track.videoId ?? '').isEmpty) continue;
      final start = track.startTimeSeconds ?? 0;
      _cacheResult(
        lyricKey: track.lyricSnippet,
        trackName: track.trackName,
        artistName: track.artistName,
        videoId: track.videoId!,
        startTimeSeconds: start,
        source: 'recent-cache',
      );
    }
  }

  /// Cache a freshly played result so it becomes available offline/quota-free.
  void cachePlaybackResult(PlaybackResult result, String lyricLine) {
    _cacheResult(
      lyricKey: lyricLine,
      trackName: result.trackName,
      artistName: result.artistName,
      videoId: result.videoId,
      startTimeSeconds: result.startTimeSeconds,
      matchedLineTimeSeconds: result.matchedLineTimeSeconds,
      matchedLyricLine: result.matchedLyricLine,
      source: 'played-cache',
    );
  }

  void _cacheResult({
    required String lyricKey,
    required String trackName,
    required String artistName,
    required String videoId,
    required int startTimeSeconds,
    int? matchedLineTimeSeconds,
    String? matchedLyricLine,
    required String source,
  }) {
    if (videoId.isEmpty) return;
    final normalizedLyric = _normalize(lyricKey);
    final normalizedTrackKey =
        '${trackName.toLowerCase()}::${artistName.toLowerCase()}';

    final cached = LightweightSearchResult(
      videoId: videoId,
      trackName: trackName,
      artistName: artistName,
      startTimeSeconds: startTimeSeconds,
      confidence: 0.95,
      matchedLineTimeSeconds: matchedLineTimeSeconds,
      matchedLyricLine: matchedLyricLine,
      source: source,
    );

    if (normalizedLyric.isNotEmpty) {
      _searchCache.update(
        normalizedLyric,
        (existing) => _mergeResults(existing, cached),
        ifAbsent: () => [cached],
      );
    }

    // Also index by song title so typing the song name hits cache.
    final songKey = _normalize('$trackName $artistName');
    if (songKey.isNotEmpty) {
      _searchCache.update(
        songKey,
        (existing) => _mergeResults(existing, cached),
        ifAbsent: () => [cached],
      );
    }

    _videoIdCache[normalizedTrackKey] = videoId;
    _titleCache[normalizedTrackKey] = videoId;
  }

  List<LightweightSearchResult> _mergeResults(
    List<LightweightSearchResult> existing,
    LightweightSearchResult incoming,
  ) {
    final deduped = <String, LightweightSearchResult>{};
    for (final r in [...existing, incoming]) {
      if (!deduped.containsKey(r.videoId) ||
          r.confidence > deduped[r.videoId]!.confidence) {
        deduped[r.videoId] = r;
      }
    }
    final merged =
        deduped.values.toList()
          ..sort((a, b) => b.confidence.compareTo(a.confidence));
    return merged;
  }

  String _normalize(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Optimized search that uses minimal API calls
  Future<List<LightweightSearchResult>> searchSingleLineLyrics(
    String lyricLine, {
    bool cacheOnly = false,
  }) async {
    final query = lyricLine.trim();
    if (query.isEmpty) return [];

    final cacheKey = _normalize(query);

    // Check cache first (highest priority)
    if (_searchCache.containsKey(cacheKey)) {
      return _searchCache[cacheKey]!;
    }

    // In cache-only mode we must not hit network at all.
    if (cacheOnly) {
      return await _fallbackSearch(query);
    }

    // If quota is exceeded, try fallback search
    if (_isQuotaExceeded) {
      return await _fallbackSearch(query);
    }

    // Normal optimized search
    var results = await _optimizedSearch(query);

    // Refine results using Grok for better ranking (only if we have results)
    if (results.isNotEmpty) {
      results = await _grokRefinement.refineSearchResults(query, results);
    }

    // Cache only successful results so a bad/exhausted key does not poison later searches.
    if (results.isNotEmpty) {
      _searchCache[cacheKey] = results;
    }

    return results;
  }

  /// Optimized search that minimizes API calls
  Future<List<LightweightSearchResult>> _optimizedSearch(String query) async {
    final results = <LightweightSearchResult>[];

    final lyricMatches = await _collectLyricMatches(query);
    if (lyricMatches.isNotEmpty) {
      for (final match in lyricMatches.take(3)) {
        final videoId = await _getVideoIdWithCache(
          match.trackName,
          match.artistName,
        );
        if (videoId == null) continue;

        final startTime = _calculateStartTime(match.syncedLyrics, query);

        results.add(
          LightweightSearchResult(
            videoId: videoId,
            trackName: match.trackName,
            artistName: match.artistName,
            startTimeSeconds: startTime,
            confidence: _calculateConfidence(match.syncedLyrics, query),
            matchedLineTimeSeconds: _findExactLineTime(
              match.syncedLyrics,
              query,
            ),
            matchedLyricLine: LyricsService.bestMatchingLineText(
              match.syncedLyrics ?? '',
              query,
            ),
          ),
        );
      }

      results.sort((a, b) => b.confidence.compareTo(a.confidence));
      return results;
    }

    return _youtubeLyricOnlyFallback(query);
  }

  /// Merge LRCLIB hits across multiple query variants (head/mid/tail/sliding), like [PlaybackServiceMobile].
  Future<List<LyricsMatch>> _collectLyricMatches(String query) async {
    final variants = LyricsService.lyricSearchQueryVariants(
      query,
      maxQueries: 12,
    );
    final byId = <int, LyricsMatch>{};
    final order = <int>[];

    for (final q in variants) {
      final list = await _lyrics.search(q);
      for (final m in list) {
        if (!byId.containsKey(m.id)) {
          order.add(m.id);
          byId[m.id] = m;
        }
      }
      if (order.length >= 18) break;
    }

    return order.map((id) => byId[id]!).toList();
  }

  /// When LRCLIB has no match (common for deep rap), search YouTube with the same variants as playback.
  Future<List<LightweightSearchResult>> _youtubeLyricOnlyFallback(
    String query,
  ) async {
    final results = <LightweightSearchResult>[];
    if (_isQuotaExceeded) return results;

    final variants = LyricsService.youtubeLyricSearchVariants(
      query,
      maxQueries: 6,
    );
    final seen = <String>{};
    final pool = <Map<String, dynamic>>[];

    for (final q in variants) {
      try {
        final list = await _youtube.searchSongs(q);
        for (final item in list) {
          final id = item['id'] as String? ?? '';
          if (id.isEmpty || !seen.add(id)) continue;
          pool.add(item);
        }
      } catch (_) {
        // Quota / network — try next variant.
      }
      if (pool.length >= 22) break;
    }

    if (pool.isEmpty) return results;

    pool.sort(
      (a, b) => LyricsService.scoreYoutubeCandidateForLyricLine(
        b,
        query,
      ).compareTo(LyricsService.scoreYoutubeCandidateForLyricLine(a, query)),
    );

    for (final picked in pool.take(3)) {
      final videoId = picked['id'] as String? ?? '';
      final title = picked['title'] as String? ?? '';
      final channel = picked['artist'] as String? ?? '';
      if (videoId.isEmpty) continue;

      final score = LyricsService.scoreYoutubeCandidateForLyricLine(
        picked,
        query,
      );

      results.add(
        LightweightSearchResult(
          videoId: videoId,
          trackName: _trackFromYoutubeTitle(title, channel),
          artistName: _artistFromYoutubeTitle(title, channel),
          startTimeSeconds: 0,
          confidence: score.clamp(0, 1),
          source: 'yt-lyric-fallback',
        ),
      );
    }

    return results;
  }

  String _trackFromYoutubeTitle(String title, String channel) {
    final sep =
        title.contains(' - ') ? ' - ' : (title.contains(' | ') ? ' | ' : null);
    if (sep != null) {
      final parts =
          title
              .split(sep)
              .map((p) => p.trim())
              .where((p) => p.isNotEmpty)
              .toList();
      if (parts.length >= 2) return parts[0];
    }
    return title;
  }

  String _artistFromYoutubeTitle(String title, String channel) {
    final sep =
        title.contains(' - ') ? ' - ' : (title.contains(' | ') ? ' | ' : null);
    if (sep != null) {
      final parts =
          title
              .split(sep)
              .map((p) => p.trim())
              .where((p) => p.isNotEmpty)
              .toList();
      if (parts.length >= 2) return parts[1];
    }
    return channel;
  }

  /// Get video ID with aggressive caching
  Future<String?> _getVideoIdWithCache(
    String trackName,
    String artistName,
  ) async {
    final cacheKey =
        '${activeYoutubeApiKeyFingerprint()}::${trackName.toLowerCase()}::${artistName.toLowerCase()}';

    // Check cache first
    final cached = _videoIdCache[cacheKey];
    if (cached != null) {
      return cached.isEmpty ? null : cached;
    }

    // If quota is low, don't make new YouTube calls
    if (_isQuotaExceeded) {
      return null;
    }

    // Make minimal YouTube API call
    final videoId = await _searchSingleVideo(trackName, artistName);

    // Cache the result (even if null to avoid repeated calls)
    _videoIdCache[cacheKey] = videoId ?? '';

    return videoId;
  }

  /// Minimal YouTube search - just one API call
  Future<String?> _searchSingleVideo(
    String trackName,
    String artistName,
  ) async {
    final searchQuery = '$trackName $artistName official audio';
    final cacheKey =
        '${activeYoutubeApiKeyFingerprint()}::${searchQuery.toLowerCase()}';

    final cached = _titleCache[cacheKey];
    if (cached != null) {
      return cached.isEmpty ? null : cached;
    }

    try {
      final youtubeApiKey = getActiveYoutubeApiKey();
      final uri = Uri.parse(
        'https://www.googleapis.com/youtube/v3/search'
        '?part=snippet&maxResults=1&q=${Uri.encodeQueryComponent(searchQuery)}'
        '&type=video&key=$youtubeApiKey',
      );

      final response = await _client
          .get(uri)
          .timeout(const Duration(seconds: 6));

      if (response.statusCode == 403) {
        // Quota exceeded - log and return null
        _quotaMonitor.logSearchCall(searchQuery);
        _titleCache[cacheKey] = '';
        return null;
      }

      if (response.statusCode != 200) {
        _titleCache[cacheKey] = '';
        return null;
      }

      final data = json.decode(response.body) as Map<String, dynamic>?;
      final items = data?['items'] as List<dynamic>?;

      if (items == null || items.isEmpty) {
        _titleCache[cacheKey] = '';
        return null;
      }

      final videoId = items.first['id']['videoId'] as String?;
      _quotaMonitor.logSearchCall(searchQuery);

      // Cache the result
      _titleCache[cacheKey] = videoId ?? '';
      return videoId;
    } catch (_) {
      _titleCache[cacheKey] = '';
      return null;
    }
  }

  /// Fallback search using only cached data when quota is exceeded
  Future<List<LightweightSearchResult>> _fallbackSearch(String query) async {
    final results = <LightweightSearchResult>[];
    final normalizedQuery = _normalize(query);

    // Try to find matches in existing cache
    for (final entry in _searchCache.entries) {
      final key = entry.key;
      final exactLike =
          key.contains(normalizedQuery) || normalizedQuery.contains(key);
      if (exactLike) {
        results.addAll(entry.value);
        continue;
      }

      // Fuzzy rescue path for noisy/transcribed rap lines in cache-only mode.
      final fuzzy = LyricsService.scoreTextMatch(key, normalizedQuery);
      if (fuzzy >= 0.58) {
        final boosted =
            entry.value
                .map(
                  (r) => LightweightSearchResult(
                    videoId: r.videoId,
                    trackName: r.trackName,
                    artistName: r.artistName,
                    startTimeSeconds: r.startTimeSeconds,
                    confidence:
                        ((r.confidence * 0.75) + (fuzzy * 0.25))
                            .clamp(0, 1)
                            .toDouble(),
                    matchedLineTimeSeconds: r.matchedLineTimeSeconds,
                    matchedLyricLine: r.matchedLyricLine,
                    source: '${r.source}-fuzzy',
                  ),
                )
                .toList();
        results.addAll(boosted);
      }
    }

    // Remove duplicates and sort by relevance
    final uniqueResults = <String, LightweightSearchResult>{};
    for (final result in results) {
      if (!uniqueResults.containsKey(result.videoId) ||
          result.confidence > uniqueResults[result.videoId]!.confidence) {
        uniqueResults[result.videoId] = result;
      }
    }

    final sorted =
        uniqueResults.values.toList()
          ..sort((a, b) => b.confidence.compareTo(a.confidence));
    return sorted.take(5).toList(); // Limit fallback results
  }

  /// Calculate start time with -8 seconds offset
  int _calculateStartTime(String? syncedLyrics, String userLine) {
    if (syncedLyrics == null || syncedLyrics.isEmpty) return 0;

    final startTime = LyricsService.findStartTimeSeconds(
      syncedLyrics,
      userLine,
    );
    if (startTime <= 0) return 0;

    final preroll = startTime - 8;
    return preroll > 0
        ? preroll
        : 0; // Start 8 seconds before, but not before 0
  }

  int? _findExactLineTime(String? syncedLyrics, String userLine) {
    if (syncedLyrics == null || syncedLyrics.isEmpty) return null;
    return LyricsService.bestMatchingLineSeconds(
      syncedLyrics,
      userLine,
      minScore: 0.0,
    );
  }

  /// Calculate confidence score for the match
  double _calculateConfidence(String? syncedLyrics, String userLine) {
    if (syncedLyrics == null || syncedLyrics.isEmpty) return 0.3;

    return LyricsService.scoreSyncedLyricsMatch(syncedLyrics, userLine);
  }

  /// Clear cache to free memory
  void clearCache() {
    _searchCache.clear();
    _videoIdCache.clear();
    _titleCache.clear();
    _grokRefinement.clearCache();
  }

  /// Get cache statistics
  Map<String, int> getCacheStats() {
    return {
      'searchCache': _searchCache.length,
      'videoIdCache': _videoIdCache.length,
      'titleCache': _titleCache.length,
      ..._grokRefinement.getCacheStats(),
    };
  }
}
