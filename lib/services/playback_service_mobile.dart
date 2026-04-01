// Orchestrates: lyric line -> LRCLIB + Genius + YouTube (parallel) -> (videoId, startSeconds).

import 'genius_search_service.dart';
import 'lyrics_service.dart';
import 'semantic_reranker_service.dart';
import 'youtube_mobile_service.dart';

class PlaybackResult {
  const PlaybackResult({
    required this.videoId,
    required this.startTimeSeconds,
    required this.trackName,
    required this.artistName,
    this.matchedLineTimeSeconds,
    this.matchedLyricLine,
  });

  final String videoId;
  final int startTimeSeconds;
  final String trackName;
  final String artistName;
  final int? matchedLineTimeSeconds;
  final String? matchedLyricLine;
}

class PlaybackOption {
  const PlaybackOption({
    required this.result,
    required this.confidence,
    required this.source,
    this.evidenceText,
  });

  final PlaybackResult result;
  final double confidence;
  final String source;
  final String? evidenceText;
}

class PlaybackServiceMobile {
  final LyricsService _lyrics = LyricsService();
  final YoutubeMobileService _youtube = YoutubeMobileService();
  final GeniusSearchService _genius = GeniusSearchService();
  final SemanticRerankerService _reranker = SemanticRerankerService();
  static const int _linePrerollSeconds = 8;

  // Avoid repeated network calls for the same lyric line in one app session.
  final Map<String, List<PlaybackOption>> _resolvedCache = {};

  Future<PlaybackResult?> resolveAndSearch(String lyricLine) async {
    final options = await resolveCandidates(lyricLine, limit: 1);
    if (options.isEmpty) return null;
    return options.first.result;
  }

  Future<List<PlaybackOption>> resolveCandidates(
    String lyricLine, {
    int limit = 5,
  }) async {
    final trimmed = lyricLine.trim();
    if (trimmed.isEmpty) return const [];

    final cacheKey = trimmed.toLowerCase();
    final cached = _resolvedCache[cacheKey];
    if (cached != null && cached.isNotEmpty) {
      return cached.take(limit).toList();
    }

    final byVideoId = <String, PlaybackOption>{};

    final parallel = await Future.wait([
      _resolveFromLyricsOptions(trimmed, maxCandidates: 4),
      _resolveFromGlobalYoutubeOptions(trimmed, maxCandidates: 5),
      _resolveFromGeniusOptions(trimmed, maxCandidates: 3),
    ]);

    for (final option in parallel[0]) {
      byVideoId.putIfAbsent(option.result.videoId, () => option);
    }
    for (final option in parallel[1]) {
      final existing = byVideoId[option.result.videoId];
      if (existing == null || _shouldPreferOption(option, existing)) {
        byVideoId[option.result.videoId] = option;
      }
    }
    for (final option in parallel[2]) {
      final existing = byVideoId[option.result.videoId];
      if (existing == null || _shouldPreferOption(option, existing)) {
        byVideoId[option.result.videoId] = option;
      }
    }

    final reranked =
        byVideoId.values.map((option) {
          final semanticScore = _reranker.score(
            query: trimmed,
            trackName: option.result.trackName,
            artistName: option.result.artistName,
            evidenceText: option.evidenceText,
          );
          final timingScore = _timingResolutionScore(
            option.result.startTimeSeconds,
          );

          // Blend source confidence + semantic confidence + lyric-timestamp quality.
          final blended =
              ((option.confidence * 0.50) +
                      (semanticScore * 0.35) +
                      (timingScore * 0.15))
                  .clamp(0, 1)
                  .toDouble();
          return PlaybackOption(
            result: option.result,
            confidence: blended,
            source: option.source,
            evidenceText: option.evidenceText,
          );
        }).toList();

    final sorted =
        reranked..sort((a, b) => b.confidence.compareTo(a.confidence));

    final top = sorted.take(limit).toList();
    if (top.isNotEmpty) {
      _resolvedCache[cacheKey] = sorted.take(8).toList();
    }
    return top;
  }

  Future<List<PlaybackOption>> _resolveFromLyricsOptions(
    String lyricLine, {
    int maxCandidates = 4,
  }) async {
    final matches = await _searchLyricsAcrossVariants(lyricLine);
    if (matches.isEmpty) return const [];

    final top = matches.take(18).toList();
    final hydrated = await Future.wait(
      top.map((m) async {
        if ((m.syncedLyrics ?? '').isNotEmpty) return m;
        return await _lyrics.getById(m.id) ?? m;
      }),
    );

    final scored = <_ScoredLyricsCandidate>[];
    for (final m in hydrated.take(maxCandidates * 2)) {
      final playResult = _lyrics.toPlayResult(m, lyricLine);
      final score = LyricsService.scoreSyncedLyricsMatch(
        m.syncedLyrics ?? '',
        lyricLine,
      );
      final bestLine =
          LyricsService.bestMatchingLineText(m.syncedLyrics ?? '', lyricLine) ??
          '';
      scored.add(
        _ScoredLyricsCandidate(
          trackName: m.trackName,
          artistName: m.artistName,
          startTimeSeconds: _applyLinePreroll(
            playResult?.startTimeSeconds ?? 0,
          ),
          matchedLineTimeSeconds: playResult?.exactLineTimeSeconds,
          score: score,
          evidenceText: playResult?.matchedLyricLine ?? bestLine,
        ),
      );
    }

    scored.sort((a, b) => b.score.compareTo(a.score));

    final options = <PlaybackOption>[];
    final seenTrackArtist = <String>{};

    for (final c in scored) {
      final key = '${c.trackName.toLowerCase()}::${c.artistName.toLowerCase()}';
      if (!seenTrackArtist.add(key)) continue;

      final videoId = await _searchBestVideoIdForSong(
        c.trackName,
        c.artistName,
      );
      if (videoId == null || videoId.isEmpty) continue;

      options.add(
        PlaybackOption(
          result: PlaybackResult(
            videoId: videoId,
            startTimeSeconds: c.startTimeSeconds,
            trackName: c.trackName,
            artistName: c.artistName,
            matchedLineTimeSeconds: c.matchedLineTimeSeconds,
            matchedLyricLine: c.evidenceText,
          ),
          confidence: c.score.clamp(0, 1).toDouble(),
          source: 'lyrics',
          evidenceText: c.evidenceText,
        ),
      );

      if (options.length >= maxCandidates) break;
    }

    if (options.isEmpty && hydrated.isNotEmpty) {
      final first = hydrated.first;
      final firstResult = _lyrics.toPlayResult(first, lyricLine);
      final videoId = await _searchBestVideoIdForSong(
        first.trackName,
        first.artistName,
      );
      if (videoId != null && videoId.isNotEmpty) {
        options.add(
          PlaybackOption(
            result: PlaybackResult(
              videoId: videoId,
              startTimeSeconds: 0,
              trackName: first.trackName,
              artistName: first.artistName,
              matchedLineTimeSeconds: firstResult?.exactLineTimeSeconds,
              matchedLyricLine: firstResult?.matchedLyricLine,
            ),
            confidence: 0.3,
            source: 'lyrics',
            evidenceText: firstResult?.matchedLyricLine ?? lyricLine,
          ),
        );
      }
    }

    return options;
  }

  Future<List<PlaybackOption>> _resolveFromGeniusOptions(
    String lyricLine, {
    int maxCandidates = 3,
  }) async {
    final hits = await _genius.searchLyricLine(lyricLine);
    if (hits.isEmpty) return const [];

    final options = <PlaybackOption>[];
    final seen = <String>{};

    for (final hit in hits) {
      if (hit.artistName.trim().isEmpty) continue;

      final key = '${hit.title.toLowerCase()}::${hit.artistName.toLowerCase()}';
      if (!seen.add(key)) continue;

      final videoId = await _searchBestVideoIdForSong(
        hit.title,
        hit.artistName,
      );
      if (videoId == null || videoId.isEmpty) continue;

      final blob = '${hit.title} ${hit.artistName}';
      final snippet = hit.snippet ?? hit.fullTitle ?? '';
      double conf;
      if (snippet.isNotEmpty) {
        conf =
            (0.5 * LyricsService.scoreTextMatch(blob, lyricLine)) +
            (0.5 * LyricsService.scoreTextMatch(snippet, lyricLine));
      } else {
        conf = LyricsService.scoreTextMatch(blob, lyricLine) * 0.5 + 0.35;
      }

      options.add(
        PlaybackOption(
          result: PlaybackResult(
            videoId: videoId,
            startTimeSeconds: 0,
            trackName: hit.title,
            artistName: hit.artistName,
          ),
          confidence: conf.clamp(0, 1).toDouble(),
          source: 'genius',
          evidenceText: snippet.isNotEmpty ? snippet : hit.fullTitle,
        ),
      );

      if (options.length >= maxCandidates) break;
    }

    return options;
  }

  Future<List<LyricsMatch>> _searchLyricsAcrossVariants(
    String lyricLine,
  ) async {
    final queries = _buildLyricQueries(lyricLine);
    final lists = await Future.wait(queries.map(_lyrics.search));

    final byId = <int, LyricsMatch>{};
    for (final list in lists) {
      for (final m in list) {
        byId.putIfAbsent(m.id, () => m);
      }
    }

    return byId.values.toList();
  }

  Future<String?> _searchBestVideoIdForSong(
    String trackName,
    String artistName,
  ) => _youtube.resolveSongVideoId(trackName, artistName);

  Future<List<PlaybackOption>> _resolveFromGlobalYoutubeOptions(
    String lyricLine, {
    int maxCandidates = 5,
  }) async {
    final queries = _buildYoutubeQueries(lyricLine);
    final seenIds = <String>{};
    final merged = <Map<String, dynamic>>[];

    for (final q in queries.take(6)) {
      final list = await _youtube.searchSongs(q, maxResults: 2);
      for (final item in list) {
        final id = item['id'] as String? ?? '';
        if (id.isEmpty || !seenIds.add(id)) continue;
        merged.add(item);
      }
      if (merged.length >= 10) break;
    }

    if (merged.isEmpty) return const [];

    merged.sort(
      (a, b) => _scoreYoutubeCandidate(
        b,
        lyricLine,
      ).compareTo(_scoreYoutubeCandidate(a, lyricLine)),
    );

    final options = <PlaybackOption>[];
    for (final picked in merged.take(maxCandidates)) {
      final videoId = picked['id'] as String? ?? '';
      if (videoId.isEmpty) continue;

      final pickedTitle = picked['title'] as String? ?? '';
      final pickedArtist = picked['artist'] as String? ?? '';
      final parsed = _extractTrackArtistFromTitle(pickedTitle, pickedArtist);

      final enriched = await _resolveLyricMetadataForYoutubeCandidate(
        pickedTitle: pickedTitle,
        pickedArtist: pickedArtist,
        parsed: parsed,
        userLyricLine: lyricLine,
      );

      final result =
          enriched != null
              ? PlaybackResult(
                videoId: videoId,
                startTimeSeconds: _applyLinePreroll(enriched.startTimeSeconds),
                trackName: enriched.trackName,
                artistName: enriched.artistName,
                matchedLineTimeSeconds: enriched.exactLineTimeSeconds,
                matchedLyricLine: enriched.matchedLyricLine,
              )
              : PlaybackResult(
                videoId: videoId,
                startTimeSeconds: 0,
                trackName: parsed?.track ?? pickedTitle,
                artistName: parsed?.artist ?? pickedArtist,
              );

      options.add(
        PlaybackOption(
          result: result,
          confidence:
              (_scoreYoutubeCandidate(picked, lyricLine) +
                      _timingConfidenceBoost(result.startTimeSeconds))
                  .clamp(0, 1)
                  .toDouble(),
          source: 'youtube',
          evidenceText: result.matchedLyricLine ?? picked['title'] as String?,
        ),
      );
    }

    return options;
  }

  List<String> _buildLyricQueries(String line) =>
      LyricsService.lyricSearchQueryVariants(line, maxQueries: 16);

  List<String> _buildYoutubeQueries(String line) =>
      LyricsService.youtubeLyricSearchVariants(line);

  double _scoreYoutubeCandidate(Map<String, dynamic> song, String lyricLine) =>
      LyricsService.scoreYoutubeCandidateForLyricLine(song, lyricLine);

  Future<LyricPlayResult?> _resolveLyricMetadataForYoutubeCandidate({
    required String pickedTitle,
    required String pickedArtist,
    required _TrackArtist? parsed,
    required String userLyricLine,
  }) async {
    final trackName = parsed?.track ?? pickedTitle;
    final artistName = parsed?.artist ?? pickedArtist;
    final seeds = _buildLrclibSeedsForYoutubeCandidate(
      trackName: trackName,
      artistName: artistName,
      rawTitle: pickedTitle,
      rawArtist: pickedArtist,
      userLyricLine: userLyricLine,
    );

    if (seeds.isEmpty) return null;

    final candidates = <LyricsMatch>[];
    final seen = <int>{};

    for (final s in seeds) {
      if (s.trim().isEmpty) continue;
      final list = await _lyrics.search(s);
      for (final m in list) {
        if (seen.add(m.id)) candidates.add(m);
      }
      if (candidates.length >= 16) break;
    }

    if (candidates.isEmpty) return null;

    final hydrated = await Future.wait(
      candidates.take(16).map((m) async {
        if ((m.syncedLyrics ?? '').isNotEmpty) return m;
        return await _lyrics.getById(m.id) ?? m;
      }),
    );

    LyricPlayResult? best;
    double bestScore = -1.0;

    final expectedIdentity = '$trackName $artistName'.trim();

    for (final m in hydrated) {
      final synced = m.syncedLyrics ?? '';
      if (synced.isEmpty) continue;

      final lineScore = LyricsService.scoreSyncedLyricsMatch(
        synced,
        userLyricLine,
      );
      final identityScore = LyricsService.scoreTextMatch(
        '${m.trackName} ${m.artistName}',
        expectedIdentity,
      );
      final titleScore = LyricsService.scoreTextMatch(m.trackName, trackName);
      final combined =
          (0.60 * lineScore) + (0.30 * identityScore) + (0.10 * titleScore);

      var result = _lyrics.toPlayResult(m, userLyricLine);

      // Fallback: allow a looser hit if strict threshold left timestamp at 0.
      if ((result == null || result.startTimeSeconds == 0) &&
          lineScore >= 0.30) {
        final looseSeconds = LyricsService.bestMatchingLineSeconds(
          synced,
          userLyricLine,
          minScore: 0.33,
        );
        if (looseSeconds != null) {
          result = LyricPlayResult(
            trackName: m.trackName,
            artistName: m.artistName,
            durationSeconds: m.durationSeconds,
            startTimeSeconds: looseSeconds,
            exactLineTimeSeconds: looseSeconds,
            matchedLyricLine: LyricsService.bestMatchingLineText(
              synced,
              userLyricLine,
            ),
            syncedLyrics: synced,
          );
        }
      }

      if (result != null && combined > bestScore) {
        best = result;
        bestScore = combined;
      }
    }

    return best;
  }

  bool _shouldPreferOption(PlaybackOption incoming, PlaybackOption existing) {
    final incomingHasLine =
        (incoming.result.matchedLyricLine ?? '').trim().isNotEmpty ||
        (incoming.result.matchedLineTimeSeconds ?? 0) > 0;
    final existingHasLine =
        (existing.result.matchedLyricLine ?? '').trim().isNotEmpty ||
        (existing.result.matchedLineTimeSeconds ?? 0) > 0;
    if (incomingHasLine != existingHasLine) {
      return incomingHasLine;
    }
    return incoming.confidence > existing.confidence;
  }

  List<String> _buildLrclibSeedsForYoutubeCandidate({
    required String trackName,
    required String artistName,
    required String rawTitle,
    required String rawArtist,
    required String userLyricLine,
  }) {
    String sanitizeTitle(String s) {
      return s
          .replaceAll(RegExp(r'\([^)]*\)'), ' ')
          .replaceAll(RegExp(r'\[[^\]]*\]'), ' ')
          .replaceAll(
            RegExp(
              r'\b(official|audio|video|lyrics?|visualizer|topic|hd|4k)\b',
              caseSensitive: false,
            ),
            ' ',
          )
          .replaceAll(
            RegExp(r'\b(feat|ft)\.?[^-–|]*', caseSensitive: false),
            ' ',
          )
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }

    final cleanTrack = sanitizeTitle(trackName);
    final cleanRawTitle = sanitizeTitle(rawTitle);
    final shortLyric = userLyricLine
        .trim()
        .split(RegExp(r'\s+'))
        .take(6)
        .join(' ');

    final seeds = <String>[
      '$trackName $artistName',
      if (cleanTrack.isNotEmpty) '$cleanTrack $artistName',
      if (cleanRawTitle.isNotEmpty) '$cleanRawTitle $artistName',
      if (cleanTrack.isNotEmpty) cleanTrack,
      if (cleanRawTitle.isNotEmpty) cleanRawTitle,
      rawTitle,
      '$rawTitle $rawArtist',
      if (shortLyric.isNotEmpty) '$cleanTrack $shortLyric',
    ];

    final seen = <String>{};
    return seeds
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty && seen.add(s.toLowerCase()))
        .toList();
  }

  _TrackArtist? _extractTrackArtistFromTitle(
    String rawTitle,
    String fallbackArtist,
  ) {
    final cleaned =
        rawTitle
            .replaceAll(RegExp(r'\([^)]*\)'), ' ')
            .replaceAll(RegExp(r'\[[^\]]*\]'), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();

    if (cleaned.isEmpty) return null;

    final separator =
        cleaned.contains(' - ')
            ? ' - '
            : (cleaned.contains(' | ') ? ' | ' : null);
    if (separator == null) {
      if (fallbackArtist.trim().isEmpty) return null;
      return _TrackArtist(track: cleaned, artist: fallbackArtist.trim());
    }

    final parts =
        cleaned
            .split(separator)
            .map((p) => p.trim())
            .where((p) => p.isNotEmpty)
            .toList();
    if (parts.length < 2) return null;

    final first = parts[0];
    final second = parts[1];
    if (_looksLikeArtist(first) && !_looksLikeArtist(second)) {
      return _TrackArtist(track: second, artist: first);
    }

    return _TrackArtist(track: first, artist: second);
  }

  bool _looksLikeArtist(String text) {
    final lowered = text.toLowerCase();
    return lowered.contains('feat') ||
        lowered.contains('&') ||
        lowered.contains('x ') ||
        lowered.contains('official');
  }

  int _applyLinePreroll(int startTimeSeconds) {
    if (startTimeSeconds <= 0) return 0;
    final shifted = startTimeSeconds - _linePrerollSeconds;
    return shifted < 0 ? 0 : shifted;
  }

  double _timingConfidenceBoost(int startTimeSeconds) {
    if (startTimeSeconds <= 0) return 0;
    // Non-zero line resolution should rank higher than plain title-text matches.
    if (startTimeSeconds <= 20) return 0.10;
    return 0.16;
  }

  double _timingResolutionScore(int startTimeSeconds) {
    if (startTimeSeconds <= 0) return 0;
    // Reward options where line-level timing was actually resolved.
    if (startTimeSeconds <= 20) return 0.70;
    return 1.0;
  }
}

class _TrackArtist {
  const _TrackArtist({required this.track, required this.artist});

  final String track;
  final String artist;
}

class _ScoredLyricsCandidate {
  const _ScoredLyricsCandidate({
    required this.trackName,
    required this.artistName,
    required this.startTimeSeconds,
    required this.matchedLineTimeSeconds,
    required this.score,
    required this.evidenceText,
  });

  final String trackName;
  final String artistName;
  final int startTimeSeconds;
  final int? matchedLineTimeSeconds;
  final double score;
  final String evidenceText;
}
