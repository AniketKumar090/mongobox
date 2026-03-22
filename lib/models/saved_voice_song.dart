class SavedVoiceSong {
  const SavedVoiceSong({
    required this.id,
    required this.title,
    required this.filePath,
    required this.language,
    required this.mood,
    required this.genre,
    required this.createdAtIso,
    required this.hasBackgroundMusic,
    this.backgroundMusicUrl = '',
    this.backgroundMusicLabel = '',
  });

  final String id;
  final String title;
  final String filePath;
  final String language;
  final String mood;
  final String genre;
  final String createdAtIso;
  final bool hasBackgroundMusic;
  final String backgroundMusicUrl;
  final String backgroundMusicLabel;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'file_path': filePath,
        'language': language,
        'mood': mood,
        'genre': genre,
        'created_at_iso': createdAtIso,
        'has_background_music': hasBackgroundMusic,
        'background_music_url': backgroundMusicUrl,
        'background_music_label': backgroundMusicLabel,
      };

  factory SavedVoiceSong.fromJson(Map<String, dynamic> json) => SavedVoiceSong(
        id: json['id'] as String,
        title: json['title'] as String,
        filePath: json['file_path'] as String,
        language: json['language'] as String? ?? '',
        mood: json['mood'] as String? ?? '',
        genre: json['genre'] as String? ?? '',
        createdAtIso: json['created_at_iso'] as String,
        hasBackgroundMusic: json['has_background_music'] as bool? ?? false,
        backgroundMusicUrl: json['background_music_url'] as String? ?? '',
        backgroundMusicLabel: json['background_music_label'] as String? ?? '',
      );

  DateTime get createdAt =>
      DateTime.tryParse(createdAtIso) ?? DateTime.fromMillisecondsSinceEpoch(0);
}
