class SavedVoiceSong {
  const SavedVoiceSong({
    required this.id,
    required this.title,
    required this.filePath,
    required this.fileName,
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
  final String fileName;
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
    'file_path': fileName,
    'file_name': fileName,
    'language': language,
    'mood': mood,
    'genre': genre,
    'created_at_iso': createdAtIso,
    'has_background_music': hasBackgroundMusic,
    'background_music_url': backgroundMusicUrl,
    'background_music_label': backgroundMusicLabel,
  };

  factory SavedVoiceSong.fromJson(Map<String, dynamic> json) {
    final rawPath = json['file_path'] as String? ?? '';
    final fileName = (json['file_name'] as String?)?.trim();
    return SavedVoiceSong(
      id: json['id'] as String,
      title: json['title'] as String,
      filePath: rawPath,
      fileName:
          (fileName == null || fileName.isEmpty)
              ? _basename(rawPath)
              : fileName,
      language: json['language'] as String? ?? '',
      mood: json['mood'] as String? ?? '',
      genre: json['genre'] as String? ?? '',
      createdAtIso: json['created_at_iso'] as String,
      hasBackgroundMusic: json['has_background_music'] as bool? ?? false,
      backgroundMusicUrl: json['background_music_url'] as String? ?? '',
      backgroundMusicLabel: json['background_music_label'] as String? ?? '',
    );
  }

  SavedVoiceSong copyWith({
    String? id,
    String? title,
    String? filePath,
    String? fileName,
    String? language,
    String? mood,
    String? genre,
    String? createdAtIso,
    bool? hasBackgroundMusic,
    String? backgroundMusicUrl,
    String? backgroundMusicLabel,
  }) => SavedVoiceSong(
    id: id ?? this.id,
    title: title ?? this.title,
    filePath: filePath ?? this.filePath,
    fileName: fileName ?? this.fileName,
    language: language ?? this.language,
    mood: mood ?? this.mood,
    genre: genre ?? this.genre,
    createdAtIso: createdAtIso ?? this.createdAtIso,
    hasBackgroundMusic: hasBackgroundMusic ?? this.hasBackgroundMusic,
    backgroundMusicUrl: backgroundMusicUrl ?? this.backgroundMusicUrl,
    backgroundMusicLabel: backgroundMusicLabel ?? this.backgroundMusicLabel,
  );

  DateTime get createdAt =>
      DateTime.tryParse(createdAtIso) ?? DateTime.fromMillisecondsSinceEpoch(0);

  static String _basename(String path) {
    final normalized = path.trim();
    if (normalized.isEmpty) return '';
    final parts = normalized.split(RegExp(r'[\\/]'));
    return parts.isEmpty ? normalized : parts.last;
  }
}
