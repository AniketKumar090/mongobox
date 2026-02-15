// LRCLIB API client: search by lyric line, parse synced lyrics for timestamp.

import 'dart:convert';
import 'package:http/http.dart' as http;

const _baseUrl = 'https://lrclib.net';

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

  /// Search LRCLIB by keyword (e.g. a line of lyrics). Returns up to 20 matches.
  Future<List<LyricsMatch>> search(String query) async {
    if (query.trim().isEmpty) return [];

    final uri = Uri.parse('$_baseUrl/api/search').replace(
      queryParameters: {'q': query.trim()},
    );
    final response = await _client.get(
      uri,
      headers: {'User-Agent': 'MongoBox LyricPlay/1.0'},
    );

    if (response.statusCode != 200) return [];

    final list = json.decode(response.body) as List<dynamic>?;
    if (list == null || list.isEmpty) return [];

    return list.map((e) {
      final m = e as Map<String, dynamic>;
      return LyricsMatch(
        id: (m['id'] as num?)?.toInt() ?? 0,
        trackName: (m['trackName'] as String?) ?? '',
        artistName: (m['artistName'] as String?) ?? '',
        durationSeconds: (m['duration'] as num?)?.toInt() ?? 0,
        syncedLyrics: m['syncedLyrics'] as String?,
      );
    }).toList();
  }

  /// Get full lyrics by LRCLIB id (e.g. when search didn't include syncedLyrics).
  Future<LyricsMatch?> getById(int id) async {
    final uri = Uri.parse('$_baseUrl/api/get/$id');
    final response = await _client.get(
      uri,
      headers: {'User-Agent': 'MongoBox LyricPlay/1.0'},
    );

    if (response.statusCode != 200) return null;

    final m = json.decode(response.body) as Map<String, dynamic>?;
    if (m == null) return null;

    return LyricsMatch(
      id: (m['id'] as num?)?.toInt() ?? id,
      trackName: (m['trackName'] as String?) ?? '',
      artistName: (m['artistName'] as String?) ?? '',
      durationSeconds: (m['duration'] as num?)?.toInt() ?? 0,
      syncedLyrics: m['syncedLyrics'] as String?,
    );
  }

  /// Find the best matching line in LRC text and return its start time in seconds.
  /// LRC format: [MM:SS.xx] or [MM:SS] line text
  /// Returns -1 if not found.
  static int findStartTimeSeconds(String syncedLyrics, String userLine) {
    if (syncedLyrics.isEmpty || userLine.isEmpty) return 0;

    final normalizedUser = _normalizeLine(userLine);
    if (normalizedUser.isEmpty) return 0;

    final regex = RegExp(r'\[(\d+):(\d+)\.?(\d*)\]\s*(.*)');
    int lastSeconds = 0;

    for (final line in syncedLyrics.split('\n')) {
      final match = regex.firstMatch(line);
      if (match == null) continue;

      final minutes = int.tryParse(match.group(1) ?? '0') ?? 0;
      final seconds = int.tryParse(match.group(2) ?? '0') ?? 0;
      final text = (match.group(4) ?? '').trim();

      lastSeconds = minutes * 60 + seconds;

      final normalizedText = _normalizeLine(text);
      if (normalizedText.contains(normalizedUser) || normalizedUser.contains(normalizedText)) {
        return lastSeconds;
      }
    }

    // Fuzzy: find any line that contains the user's words
    final userWords = normalizedUser.split(RegExp(r'\s+')).where((w) => w.length > 1).toList();
    if (userWords.isEmpty) return 0;

    for (final line in syncedLyrics.split('\n')) {
      final match = regex.firstMatch(line);
      if (match == null) continue;

      final minutes = int.tryParse(match.group(1) ?? '0') ?? 0;
      final seconds = int.tryParse(match.group(2) ?? '0') ?? 0;
      final text = (match.group(4) ?? '').trim();
      final normalizedText = _normalizeLine(text);

      final matchCount = userWords.where((w) => normalizedText.contains(w)).length;
      if (matchCount >= (userWords.length / 2).ceil()) {
        return minutes * 60 + seconds;
      }
    }

    return 0;
  }

  static String _normalizeLine(String s) {
    return s.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  /// Build a [LyricPlayResult] from a [LyricsMatch] and the user's line (to compute start time).
  LyricPlayResult? toPlayResult(LyricsMatch match, String userLine) {
    String? synced = match.syncedLyrics;
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
