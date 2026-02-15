// Orchestrates: lyric line -> LRCLIB -> YouTube -> (videoId, startSeconds).

import 'lyrics_service.dart';
import 'youtube_mobile_service.dart';

class PlaybackResult {
  const PlaybackResult({
    required this.videoId,
    required this.startTimeSeconds,
    required this.trackName,
    required this.artistName,
  });

  final String videoId;
  final int startTimeSeconds;
  final String trackName;
  final String artistName;
}

class PlaybackServiceMobile {
  final LyricsService _lyrics = LyricsService();
  final YoutubeMobileService _youtube = YoutubeMobileService();

  /// Resolve a single line of lyrics to a YouTube video and start time.
  /// Returns null if no match or no video found.
  Future<PlaybackResult?> resolveAndSearch(String lyricLine) async {
    final trimmed = lyricLine.trim();
    if (trimmed.isEmpty) return null;

    final matches = await _lyrics.search(trimmed);
    if (matches.isEmpty) return null;

    // Use first match; optionally later we can let user pick from list
    LyricsMatch? chosen = matches.first;
    if (chosen.syncedLyrics == null || chosen.syncedLyrics!.isEmpty) {
      final full = await _lyrics.getById(chosen.id);
      chosen = full ?? chosen;
    }

    final playResult = _lyrics.toPlayResult(chosen, trimmed);
    if (playResult == null) return null;

    final query = '${playResult.trackName} ${playResult.artistName}';
    final videoId = await _youtube.searchFirstVideoId(query);
    if (videoId == null || videoId.isEmpty) return null;

    return PlaybackResult(
      videoId: videoId,
      startTimeSeconds: playResult.startTimeSeconds,
      trackName: playResult.trackName,
      artistName: playResult.artistName,
    );
  }
}
