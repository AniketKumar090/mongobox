import 'jamendo_service.dart';
import 'soundcloud_service.dart';

class BackgroundMusicTrack {
  const BackgroundMusicTrack({required this.sourceUrl, required this.label});
  final String sourceUrl;
  final String label;
}

/// Finds a background instrumental track.
///
/// Priority order:
///   1. Reference song title + artist (most specific)
///   2. Reference artist's instrumental style
///   3. Language + genre
///   4. Mood + genre
///   5. Generic mood beat
///
/// SoundCloud is tried before Jamendo for each query (better catalogue for
/// Hindi / Bollywood content).
class BackgroundMusicService {
  BackgroundMusicService({
    JamendoService? jamendoService,
    SoundCloudService? soundCloudService,
  })  : _jamendoService = jamendoService ?? JamendoService(),
        _soundCloudService = soundCloudService ?? SoundCloudService();

  final JamendoService _jamendoService;
  final SoundCloudService _soundCloudService;

  Future<BackgroundMusicTrack?> findTrack({
    required String mood,
    required String genre,
    required String language,
    String referenceTrackTitle = '',
    String referenceArtistName = '',
  }) async {
    final queries = _buildQueries(
      mood: mood,
      genre: genre,
      language: language,
      referenceTrackTitle: referenceTrackTitle,
      referenceArtistName: referenceArtistName,
    );

    for (final query in queries) {
      // ── SoundCloud first ─────────────────────────────────────────────────
      try {
        final scTracks = await _soundCloudService.searchTracks(query, limit: 10);
        for (final track in scTracks) {
          final streamUrl = await _soundCloudService.getBestStreamUrl(track.id);
          if (streamUrl == null || streamUrl.isEmpty) continue;
          return BackgroundMusicTrack(
            sourceUrl: streamUrl,
            label: '${track.title} • ${track.userName}',
          );
        }
      } catch (_) {
        // SoundCloud failed for this query — fall through to Jamendo
      }

      // ── Jamendo fallback ─────────────────────────────────────────────────
      try {
        final jamTracks = await _jamendoService.searchTracks(query, limit: 10);
        if (jamTracks.isNotEmpty) {
          final track = jamTracks.first;
          return BackgroundMusicTrack(
            sourceUrl: track.audioUrl,
            label: '${track.name} • ${track.artistName}',
          );
        }
      } catch (_) {
        // Jamendo also failed — try next query
      }
    }

    return null; // No match found across all queries
  }

  /// Builds an ordered list of search queries, most-specific first.
  List<String> _buildQueries({
    required String mood,
    required String genre,
    required String language,
    required String referenceTrackTitle,
    required String referenceArtistName,
  }) {
    final cleanMood = _normalize(mood);
    final cleanGenre = _normalize(genre);
    final cleanLang = _normalize(language);
    final cleanTrack = _normalize(referenceTrackTitle);
    final cleanArtist = _normalize(referenceArtistName);

    // Genre may be slash-separated, e.g. "Bollywood / Romantic"
    final genreParts = cleanGenre
        .split(RegExp(r'[/,&–-]+'))
        .map(_normalize)
        .where((p) => p.isNotEmpty)
        .toList();

    final queries = <String>[
      // ── Tier 1: reference song (most specific) ───────────────────────────
      if (cleanTrack.isNotEmpty && cleanArtist.isNotEmpty)
        '$cleanTrack $cleanArtist instrumental',
      if (cleanTrack.isNotEmpty && cleanArtist.isNotEmpty)
        '$cleanTrack $cleanArtist karaoke',
      if (cleanTrack.isNotEmpty)
        '$cleanTrack instrumental',
      if (cleanArtist.isNotEmpty)
        '$cleanArtist instrumental',
      if (cleanArtist.isNotEmpty && cleanGenre.isNotEmpty)
        '$cleanArtist $cleanGenre instrumental',

      // ── Tier 2: language + genre ─────────────────────────────────────────
      if (cleanLang.isNotEmpty && cleanGenre.isNotEmpty)
        '$cleanLang $cleanGenre instrumental',
      if (cleanLang == 'hindi' && cleanGenre.isNotEmpty)
        'bollywood $cleanGenre instrumental',
      if (cleanLang == 'hindi')
        'bollywood instrumental',

      // ── Tier 3: mood + genre ─────────────────────────────────────────────
      if (cleanMood.isNotEmpty && cleanGenre.isNotEmpty)
        '$cleanMood $cleanGenre instrumental',
      if (cleanGenre.isNotEmpty)
        '$cleanGenre instrumental',

      // ── Tier 4: genre sub-parts ──────────────────────────────────────────
      for (final part in genreParts) ...[
        '$part instrumental',
        if (cleanLang.isNotEmpty) '$cleanLang $part instrumental',
      ],

      // ── Tier 5: mood only (broadest) ─────────────────────────────────────
      if (cleanLang.isNotEmpty && cleanMood.isNotEmpty)
        '$cleanLang $cleanMood instrumental',
      if (cleanMood.isNotEmpty)
        '$cleanMood instrumental beat',
    ];

    // De-duplicate while preserving order
    final seen = <String>{};
    return queries
        .map((q) => q.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((q) => q.isNotEmpty && seen.add(q.toLowerCase()))
        .toList();
  }

  String _normalize(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
}