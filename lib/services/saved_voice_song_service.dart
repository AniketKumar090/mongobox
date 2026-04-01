import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

import '../models/saved_voice_song.dart';

class SavedVoiceSongService {
  static const String _prefsKey = 'mongobox_saved_voice_songs';

  Future<List<SavedVoiceSong>> getSongs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_prefsKey) ?? const [];
    final songs = <SavedVoiceSong>[];
    final libraryDir = await _getLibraryDir();
    var needsRewrite = false;

    for (final item in raw) {
      try {
        final decoded = jsonDecode(item);
        if (decoded is Map<String, dynamic>) {
          final song = await _resolveSongPath(
            SavedVoiceSong.fromJson(decoded),
            libraryDir,
          );
          songs.add(song);
          if ((decoded['file_name'] as String?)?.trim() != song.fileName ||
              (decoded['file_path'] as String?)?.trim() != song.fileName) {
            needsRewrite = true;
          }
        }
      } catch (_) {
        // Ignore malformed entries and clean them up on next save.
        needsRewrite = true;
      }
    }

    songs.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    final normalized = songs.map((song) => jsonEncode(song.toJson())).toList();
    if (needsRewrite || normalized.length != raw.length) {
      await prefs.setStringList(_prefsKey, normalized);
    }

    return songs;
  }

  Future<void> saveSong(SavedVoiceSong song) async {
    final songs = await getSongs();
    songs.removeWhere((existing) => existing.id == song.id);
    songs.insert(0, song);
    await _persist(songs);
  }

  Future<void> removeSong(String id) async {
    final songs = await getSongs();
    final match = songs.where((song) => song.id == id).toList();
    if (match.isNotEmpty) {
      try {
        await File(match.first.filePath).delete();
      } catch (_) {
        // Ignore file deletion errors; remove metadata either way.
      }
    }
    songs.removeWhere((song) => song.id == id);
    await _persist(songs);
  }

  Future<void> _persist(List<SavedVoiceSong> songs) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = songs.map((song) => jsonEncode(song.toJson())).toList();
    await prefs.setStringList(_prefsKey, encoded);
  }

  Future<Directory> _getLibraryDir() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final libraryDir = Directory('${docsDir.path}/saved_voice_songs');
    if (!await libraryDir.exists()) {
      await libraryDir.create(recursive: true);
    }
    return libraryDir;
  }

  Future<SavedVoiceSong> _resolveSongPath(
    SavedVoiceSong song,
    Directory libraryDir,
  ) async {
    final safeFileName = song.fileName.trim();
    if (safeFileName.isEmpty) return song;

    final currentPath = '${libraryDir.path}/$safeFileName';
    final currentFile = File(currentPath);
    if (await currentFile.exists()) {
      return song.copyWith(filePath: currentPath, fileName: safeFileName);
    }

    final legacyPath = song.filePath.trim();
    if (legacyPath.isNotEmpty) {
      final legacyFile = File(legacyPath);
      if (await legacyFile.exists()) {
        try {
          if (legacyPath != currentPath) {
            await legacyFile.copy(currentPath);
          }
          return song.copyWith(filePath: currentPath, fileName: safeFileName);
        } catch (_) {
          return song.copyWith(filePath: legacyPath, fileName: safeFileName);
        }
      }
    }

    return song.copyWith(filePath: currentPath, fileName: safeFileName);
  }
}
