import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'env_config.dart';

class JamendoTrack {
  const JamendoTrack({
    required this.id,
    required this.name,
    required this.artistName,
    required this.audioUrl,
    required this.durationSeconds,
  });

  final String id;
  final String name;
  final String artistName;

  /// Stream URL (MP3) suitable for `just_audio`.
  final String audioUrl;

  final int durationSeconds;
}

class JamendoService {
  JamendoService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const String _base = 'https://api.jamendo.com/v3.0';

  Future<List<JamendoTrack>> searchTracks(String query, {int limit = 10}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    final clientId = EnvConfig.jamendoClientId;
    if (clientId.isEmpty) return const [];

    final safeLimit = limit.clamp(1, 25);
    final uri = Uri.parse(
      '$_base/tracks'
      '?client_id=${Uri.encodeQueryComponent(clientId)}'
      '&format=json'
      '&limit=$safeLimit'
      '&audioformat=mp32'
      '&include=musicinfo'
      '&search=${Uri.encodeQueryComponent(trimmed)}',
    );

    try {
      final resp = await _client.get(uri).timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return const [];

      final jsonMap = json.decode(resp.body) as Map<String, dynamic>?;
      final results = jsonMap?['results'] as List<dynamic>?;
      if (results == null || results.isEmpty) return const [];

      final tracks = <JamendoTrack>[];
      for (final row in results) {
        final map = row as Map<String, dynamic>;
        final id = (map['id'] as String?) ?? '';
        final name = (map['name'] as String?) ?? '';
        final artist = (map['artist_name'] as String?) ?? '';
        final audio = (map['audio'] as String?) ?? '';
        final duration = (map['duration'] as num?)?.toInt() ?? 0;
        if (id.isEmpty || audio.isEmpty) continue;
        tracks.add(JamendoTrack(
          id: id,
          name: name,
          artistName: artist,
          audioUrl: audio,
          durationSeconds: duration,
        ));
      }
      return tracks;
    } catch (e) {
      debugPrint('Jamendo search failed: $e');
      return const [];
    }
  }

  Future<JamendoTrack?> searchBestTrack(String query) async {
    final list = await searchTracks(query, limit: 8);
    if (list.isEmpty) return null;
    return list.first;
  }

  /// Best-effort "audio mirror" of a YouTube track (title+artist match).
  ///
  /// This does NOT guarantee the same recording/version; it picks the closest
  /// Jamendo result by string similarity.
  Future<({JamendoTrack track, double confidence})?> findMirrorTrack({
    required String trackName,
    required String artistName,
    int limit = 20,
  }) async {
    final t = trackName.trim();
    final a = artistName.trim();
    if (t.isEmpty && a.isEmpty) return null;

    final query = [t, a].where((s) => s.isNotEmpty).join(' ');
    final results = await searchTracks(query, limit: limit);
    if (results.isEmpty) return null;

    double bestScore = -1;
    JamendoTrack? best;

    for (final r in results) {
      final titleScore = _tokenSimilarity(r.name, t);
      final artistScore = _tokenSimilarity(r.artistName, a);

      // Strongly prefer matching artist when we have one.
      var score = (0.65 * titleScore) + (0.35 * artistScore);
      if (a.isNotEmpty && artistScore < 0.25) score -= 0.15;

      if (score > bestScore) {
        bestScore = score;
        best = r;
      }
    }

    if (best == null) return null;
    return (track: best, confidence: bestScore.clamp(0, 1).toDouble());
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

