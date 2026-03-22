import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/saved_voice_song.dart';

class SavedVoiceSongService {
  static const String _prefsKey = 'mongobox_saved_voice_songs';

  Future<List<SavedVoiceSong>> getSongs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_prefsKey) ?? const [];
    final songs = <SavedVoiceSong>[];

    for (final item in raw) {
      try {
        final decoded = jsonDecode(item);
        if (decoded is Map<String, dynamic>) {
          final song = SavedVoiceSong.fromJson(decoded);
          if (await File(song.filePath).exists()) {
            songs.add(song);
          }
        }
      } catch (_) {
        // Ignore malformed entries and clean them up on next save.
      }
    }

    songs.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    final normalized = songs.map((song) => jsonEncode(song.toJson())).toList();
    if (normalized.length != raw.length) {
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
}
