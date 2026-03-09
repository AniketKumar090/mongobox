// Local storage for recent lyric lines and recent tracks (suggestions).

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

const _keyRecentLines = 'lyric_play_recent_lines';
const _keyRecentTracks = 'lyric_play_recent_tracks';
const _keyRecentSearches = 'lyric_play_recent_searches';
const _maxRecentLines = 20;
const _maxRecentTracks = 30;
const _maxRecentSearches = 40;

class RecentTrack {
  const RecentTrack({
    required this.trackName,
    required this.artistName,
    required this.lyricSnippet,
  });

  final String trackName;
  final String artistName;
  final String lyricSnippet;

  Map<String, dynamic> toJson() => {
        'trackName': trackName,
        'artistName': artistName,
        'lyricSnippet': lyricSnippet,
      };

  static RecentTrack? fromJson(Map<String, dynamic>? m) {
    if (m == null) return null;
    final track = m['trackName'] as String?;
    final artist = m['artistName'] as String?;
    final snippet = m['lyricSnippet'] as String?;
    if (track == null || artist == null) return null;
    return RecentTrack(
      trackName: track,
      artistName: artist,
      lyricSnippet: snippet ?? '',
    );
  }
}

class RecentSearch {
  const RecentSearch({
    required this.query,
    required this.success,
    required this.searchedAtMs,
    this.trackName,
    this.artistName,
  });

  final String query;
  final bool success;
  final int searchedAtMs;
  final String? trackName;
  final String? artistName;

  Map<String, dynamic> toJson() => {
        'query': query,
        'success': success,
        'searchedAtMs': searchedAtMs,
        'trackName': trackName,
        'artistName': artistName,
      };

  static RecentSearch? fromJson(Map<String, dynamic>? m) {
    if (m == null) return null;
    final query = m['query'] as String?;
    if (query == null || query.trim().isEmpty) return null;
    return RecentSearch(
      query: query,
      success: (m['success'] as bool?) ?? false,
      searchedAtMs: (m['searchedAtMs'] as num?)?.toInt() ?? 0,
      trackName: m['trackName'] as String?,
      artistName: m['artistName'] as String?,
    );
  }
}

class LocalSuggestionsService {
  static Future<LocalSuggestionsService> create() async {
    final prefs = await SharedPreferences.getInstance();
    return LocalSuggestionsService._(prefs);
  }

  LocalSuggestionsService._(this._prefs);

  final SharedPreferences _prefs;

  List<String> getRecentLines() {
    final raw = _prefs.getStringList(_keyRecentLines);
    return raw ?? [];
  }

  Future<void> addRecentLine(String line) async {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;

    final list = getRecentLines();
    final normalized = _normalizeSearchText(trimmed);
    final updated = [
      trimmed,
      ...list.where((l) => _normalizeSearchText(l) != normalized),
    ].take(_maxRecentLines).toList();
    await _prefs.setStringList(_keyRecentLines, updated);
  }

  List<RecentTrack> getRecentTracks() {
    final raw = _prefs.getString(_keyRecentTracks);
    if (raw == null) return [];

    try {
      final list = json.decode(raw) as List<dynamic>?;
      if (list == null) return [];
      return list
          .map((e) => RecentTrack.fromJson(e as Map<String, dynamic>?))
          .whereType<RecentTrack>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> addRecentTrack(RecentTrack track) async {
    final list = getRecentTracks();
    final updated = [
      track,
      ...list.where((t) =>
          !(t.trackName == track.trackName && t.artistName == track.artistName))
    ].take(_maxRecentTracks).toList();
    final encoded = json.encode(updated.map((e) => e.toJson()).toList());
    await _prefs.setString(_keyRecentTracks, encoded);
  }

  List<RecentSearch> getRecentSearches() {
    final raw = _prefs.getString(_keyRecentSearches);
    if (raw == null) return [];

    try {
      final list = json.decode(raw) as List<dynamic>?;
      if (list == null) return [];
      return list
          .map((e) => RecentSearch.fromJson(e as Map<String, dynamic>?))
          .whereType<RecentSearch>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> addRecentSearch(RecentSearch search) async {
    final query = search.query.trim();
    if (query.isEmpty) return;

    final existing = getRecentSearches();
    final normalized = _normalizeSearchText(query);
    final updated = [
      RecentSearch(
        query: query,
        success: search.success,
        searchedAtMs: search.searchedAtMs,
        trackName: search.trackName,
        artistName: search.artistName,
      ),
      ...existing.where((s) => _normalizeSearchText(s.query) != normalized),
    ].take(_maxRecentSearches).toList();

    final encoded = json.encode(updated.map((e) => e.toJson()).toList());
    await _prefs.setString(_keyRecentSearches, encoded);
  }

  Future<void> clearRecentSearches() async {
    await _prefs.remove(_keyRecentSearches);
    await _prefs.remove(_keyRecentLines);
    await _prefs.remove(_keyRecentTracks);
  }

  String _normalizeSearchText(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
  }
}
