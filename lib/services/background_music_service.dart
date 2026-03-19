import 'jamendo_service.dart';
import 'soundcloud_service.dart';

class BackgroundMusicTrack {
  const BackgroundMusicTrack({required this.sourceUrl, required this.label});

  final String sourceUrl;
  final String label;
}

class BackgroundMusicService {
  BackgroundMusicService({
    JamendoService? jamendoService,
    SoundCloudService? soundCloudService,
  }) : _jamendoService = jamendoService ?? JamendoService(),
       _soundCloudService = soundCloudService ?? SoundCloudService();

  final JamendoService _jamendoService;
  final SoundCloudService _soundCloudService;

  Future<BackgroundMusicTrack?> findTrack({
    required String mood,
    required String genre,
    required String language,
  }) async {
    final queries = _buildQueries(mood: mood, genre: genre, language: language);

    for (final query in queries) {
      final soundCloudMatch = await _soundCloudService.searchTracks(
        query,
        limit: 10,
      );
      for (final track in soundCloudMatch) {
        final streamUrl = await _soundCloudService.getBestStreamUrl(track.id);
        if (streamUrl == null || streamUrl.isEmpty) continue;
        return BackgroundMusicTrack(
          sourceUrl: streamUrl,
          label: '${track.title} • ${track.userName}',
        );
      }

      final jamendoMatch = await _jamendoService.searchTracks(query, limit: 10);
      if (jamendoMatch.isNotEmpty) {
        final track = jamendoMatch.first;
        return BackgroundMusicTrack(
          sourceUrl: track.audioUrl,
          label: '${track.name} • ${track.artistName}',
        );
      }
    }

    return null;
  }

  List<String> _buildQueries({
    required String mood,
    required String genre,
    required String language,
  }) {
    final cleanMood = _normalize(mood);
    final cleanGenre = _normalize(genre);
    final cleanLanguage = _normalize(language);

    final genreParts =
        cleanGenre
            .split(RegExp(r'[/,&-]+'))
            .map(_normalize)
            .where((part) => part.isNotEmpty)
            .toList();

    final queries = <String>[
      if (cleanLanguage.isNotEmpty && cleanGenre.isNotEmpty)
        '$cleanLanguage $cleanGenre instrumental',
      if (cleanLanguage == 'urdu' && cleanGenre.isNotEmpty)
        'pakistani $cleanGenre instrumental',
      if (cleanMood.isNotEmpty && cleanGenre.isNotEmpty)
        '$cleanMood $cleanGenre instrumental',
      if (cleanGenre.isNotEmpty) '$cleanGenre instrumental',
      if (cleanLanguage.isNotEmpty && cleanMood.isNotEmpty)
        '$cleanLanguage $cleanMood instrumental',
      if (cleanMood.isNotEmpty) '$cleanMood instrumental beat',
    ];

    for (final part in genreParts) {
      queries.add('$part instrumental');
      if (cleanLanguage.isNotEmpty) {
        queries.add('$cleanLanguage $part instrumental');
      }
    }

    final seen = <String>{};
    return queries
        .map((query) => query.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((query) => query.isNotEmpty && seen.add(query.toLowerCase()))
        .toList();
  }

  String _normalize(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }
}
