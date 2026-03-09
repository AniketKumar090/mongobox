// LRCLIB API client: search by lyric line, parse synced lyrics for timestamp.

import 'dart:convert';
import 'package:http/http.dart' as http;

const _baseUrl = 'https://lrclib.net';
const _defaultHeaders = {'User-Agent': 'MongoBox LyricPlay/1.0'};

/// One match from LRCLIB search (track + optional synced lyrics).
class LyricsMatch {
  const LyricsMatch({
    required this.id,
    required this.trackName,
    required this.artistName,
    required this.durationSeconds,
    this.syncedLyrics,
  });

  final int id;
  final String trackName;
  final String artistName;
  final int durationSeconds;
  final String? syncedLyrics;
}

/// Result when we resolve a lyric line to a song and a start time (seconds).
class LyricPlayResult {
  const LyricPlayResult({
    required this.trackName,
    required this.artistName,
    required this.durationSeconds,
    required this.startTimeSeconds,
    this.syncedLyrics,
  });

  final String trackName;
  final String artistName;
  final int durationSeconds;
  final int startTimeSeconds;
  final String? syncedLyrics;
}

class LyricsService {
  final http.Client _client = http.Client();
  final Map<String, List<LyricsMatch>> _searchCache = {};
  final Map<int, LyricsMatch?> _idCache = {};

  /// Search LRCLIB by keyword (e.g. a line of lyrics). Returns up to 20 matches.
  Future<List<LyricsMatch>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    final cacheKey = q.toLowerCase();
    final cached = _searchCache[cacheKey];
    if (cached != null) return cached;

    final uri = Uri.parse('$_baseUrl/api/search').replace(
      queryParameters: {'q': q},
    );

    try {
      final response = await _client
          .get(uri, headers: _defaultHeaders)
          .timeout(const Duration(seconds: 6));

      if (response.statusCode != 200) {
        _searchCache[cacheKey] = const [];
        return const [];
      }

      final list = json.decode(response.body) as List<dynamic>?;
      if (list == null || list.isEmpty) {
        _searchCache[cacheKey] = const [];
        return const [];
      }

      final parsed = list.map((e) {
        final m = e as Map<String, dynamic>;
        return LyricsMatch(
          id: (m['id'] as num?)?.toInt() ?? 0,
          trackName: (m['trackName'] as String?) ?? '',
          artistName: (m['artistName'] as String?) ?? '',
          durationSeconds: (m['duration'] as num?)?.toInt() ?? 0,
          syncedLyrics: m['syncedLyrics'] as String?,
        );
      }).toList();

      _searchCache[cacheKey] = parsed;
      return parsed;
    } catch (_) {
      _searchCache[cacheKey] = const [];
      return const [];
    }
  }

  /// Get full lyrics by LRCLIB id (e.g. when search didn't include syncedLyrics).
  Future<LyricsMatch?> getById(int id) async {
    final cached = _idCache[id];
    if (_idCache.containsKey(id)) return cached;

    final uri = Uri.parse('$_baseUrl/api/get/$id');

    try {
      final response = await _client
          .get(uri, headers: _defaultHeaders)
          .timeout(const Duration(seconds: 6));

      if (response.statusCode != 200) {
        _idCache[id] = null;
        return null;
      }

      final m = json.decode(response.body) as Map<String, dynamic>?;
      if (m == null) {
        _idCache[id] = null;
        return null;
      }

      final parsed = LyricsMatch(
        id: (m['id'] as num?)?.toInt() ?? id,
        trackName: (m['trackName'] as String?) ?? '',
        artistName: (m['artistName'] as String?) ?? '',
        durationSeconds: (m['duration'] as num?)?.toInt() ?? 0,
        syncedLyrics: m['syncedLyrics'] as String?,
      );

      _idCache[id] = parsed;
      return parsed;
    } catch (_) {
      _idCache[id] = null;
      return null;
    }
  }

  /// Find the best matching line in LRC text and return its start time in seconds.
  /// LRC format: [MM:SS.xx] or [MM:SS] line text
  /// Returns 0 if no confident match was found.
  static int findStartTimeSeconds(String syncedLyrics, String userLine) {
    final best = _bestTimedMatch(syncedLyrics, userLine);
    if (best == null) return 0;

    final normalizedUser = _normalizeLine(userLine);
    final queryTokens = _splitTokens(normalizedUser);

    // Keep a quality bar, but allow slightly looser matching for transliterated lines.
    final threshold = queryTokens.length >= 6 ? 0.46 : 0.40;
    return best.score >= threshold ? best.seconds : 0;
  }

  /// Scores how well [userLine] matches any line in [syncedLyrics]. 0..1
  static double scoreSyncedLyricsMatch(String syncedLyrics, String userLine) {
    final best = _bestTimedMatch(syncedLyrics, userLine);
    return best?.score ?? 0;
  }

  /// Returns the best matching lyric line text for [userLine], if available.
  static String? bestMatchingLineText(String syncedLyrics, String userLine) {
    final best = _bestTimedMatch(syncedLyrics, userLine);
    final line = best?.lineText.trim();
    if (line == null || line.isEmpty) return null;
    return line;
  }

  /// Returns best matching timestamp with configurable lower-bound confidence.
  /// Useful as a fallback when strict thresholding returns 0.
  static int? bestMatchingLineSeconds(
    String syncedLyrics,
    String userLine, {
    double minScore = 0.34,
  }) {
    final best = _bestTimedMatch(syncedLyrics, userLine);
    if (best == null) return null;
    return best.score >= minScore ? best.seconds : null;
  }

  /// Scores free text similarity (0..1), useful for ranking global fallbacks.
  static double scoreTextMatch(String text, String query) {
    final normalizedText = _normalizeLine(text);
    final normalizedQuery = _normalizeLine(query);
    if (normalizedText.isEmpty || normalizedQuery.isEmpty) return 0;

    final queryWords = _splitTokens(normalizedQuery).toSet();

    if (queryWords.isEmpty) return 0;
    return _lineSimilarity(normalizedText, normalizedQuery, queryWords);
  }

  static _TimedMatch? _bestTimedMatch(String syncedLyrics, String userLine) {
    if (syncedLyrics.isEmpty || userLine.isEmpty) return null;

    final normalizedUser = _normalizeLine(userLine);
    if (normalizedUser.isEmpty) return null;

    final userWords = _splitTokens(normalizedUser).toSet();

    if (userWords.isEmpty) return null;

    final regex = RegExp(r'\[(\d+):(\d+)\.?(\d*)\]\s*(.*)');
    _TimedMatch? best;

    for (final line in syncedLyrics.split('\n')) {
      final match = regex.firstMatch(line);
      if (match == null) continue;

      final minutes = int.tryParse(match.group(1) ?? '0') ?? 0;
      final seconds = int.tryParse(match.group(2) ?? '0') ?? 0;
      final text = (match.group(4) ?? '').trim();
      if (text.isEmpty) continue;

      final normalizedText = _normalizeLine(text);
      final score = _lineSimilarity(normalizedText, normalizedUser, userWords);
      final timed = _TimedMatch(
        seconds: (minutes * 60) + seconds,
        score: score,
        lineText: text,
      );

      if (best == null || timed.score > best.score) {
        best = timed;
      }
    }

    return best;
  }

  static double _lineSimilarity(String normalizedText, String normalizedUser, Set<String> userWords) {
    if (normalizedText.isEmpty) return 0;

    if (normalizedText == normalizedUser) return 1.0;
    if (normalizedText.contains(normalizedUser) || normalizedUser.contains(normalizedText)) {
      return 0.92;
    }

    final textTokens = _splitTokens(normalizedText);
    final userTokens = _splitTokens(normalizedUser);
    final textWords = textTokens.toSet();

    if (textWords.isEmpty || userTokens.isEmpty) return 0;

    final common = userWords.intersection(textWords).length.toDouble();
    final union = userWords.union(textWords).length.toDouble();
    final jaccard = union == 0 ? 0 : common / union;

    final coverage = userWords.isEmpty ? 0 : common / userWords.length;
    final phraseOverlap = _maxContiguousOverlapRatio(userTokens, textTokens);
    final trigram = _charNgramSimilarity(normalizedUser, normalizedText, 3);

    // Blend token coverage with order-sensitive phrase overlap for line-level precision.
    return (0.45 * coverage) + (0.2 * jaccard) + (0.2 * phraseOverlap) + (0.15 * trigram);
  }

  static List<String> _splitTokens(String text) {
    return text.split(RegExp(r'\s+')).where((w) => w.length > 1).toList();
  }

  static double _maxContiguousOverlapRatio(List<String> queryTokens, List<String> textTokens) {
    if (queryTokens.isEmpty || textTokens.isEmpty) return 0;

    int best = 0;
    for (var i = 0; i < queryTokens.length; i++) {
      for (var j = 0; j < textTokens.length; j++) {
        var k = 0;
        while (i + k < queryTokens.length &&
            j + k < textTokens.length &&
            queryTokens[i + k] == textTokens[j + k]) {
          k++;
        }
        if (k > best) best = k;
      }
    }
    return best / queryTokens.length;
  }

  static double _charNgramSimilarity(String a, String b, int n) {
    if (a.isEmpty || b.isEmpty || n <= 0) return 0;

    final gramsA = _charNgrams(a, n);
    final gramsB = _charNgrams(b, n);
    if (gramsA.isEmpty || gramsB.isEmpty) return 0;

    final common = gramsA.intersection(gramsB).length.toDouble();
    return (2 * common) / (gramsA.length + gramsB.length);
  }

  static Set<String> _charNgrams(String text, int n) {
    final compact = text.replaceAll(' ', '');
    if (compact.length < n) return {compact};

    final out = <String>{};
    for (var i = 0; i <= compact.length - n; i++) {
      out.add(compact.substring(i, i + n));
    }
    return out;
  }

  static String _normalizeLine(String s) {
    return s
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  /// Build a [LyricPlayResult] from a [LyricsMatch] and the user's line (to compute start time).
  LyricPlayResult? toPlayResult(LyricsMatch match, String userLine) {
    final synced = match.syncedLyrics;
    if (synced == null || synced.isEmpty) return null;

    final startSeconds = findStartTimeSeconds(synced, userLine);
    return LyricPlayResult(
      trackName: match.trackName,
      artistName: match.artistName,
      durationSeconds: match.durationSeconds,
      startTimeSeconds: startSeconds,
      syncedLyrics: synced,
    );
  }
}

class _TimedMatch {
  const _TimedMatch({
    required this.seconds,
    required this.score,
    required this.lineText,
  });

  final int seconds;
  final double score;
  final String lineText;
}
