class SongReference {
  const SongReference({
    required this.trackName,
    required this.artistName,
    this.lyricSnippet = '',
    this.videoId,
    this.startTimeSeconds,
  });

  final String trackName;
  final String artistName;
  final String lyricSnippet;
  final String? videoId;
  final int? startTimeSeconds;
}
