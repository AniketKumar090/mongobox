// lib/services/local_queue_service.dart
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class Song {
  final String id;
  final String title;
  final String artist;
  final String thumbnail;

  Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.thumbnail,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'thumbnail': thumbnail,
      };

  factory Song.fromJson(Map<String, dynamic> json) => Song(
        id: json['id'] as String,
        title: json['title'] as String,
        artist: json['artist'] as String,
        thumbnail: json['thumbnail'] as String,
      );
}

class LocalQueueService {
  static const String _queueKey = 'mongobox_queue';

  Future<List<Song>> getQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_queueKey) ?? [];
    return list.map((s) => Song.fromJson(jsonDecode(s))).toList();
  }

  Future<void> setQueue(List<Song> queue) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = queue.map((s) => jsonEncode(s.toJson())).toList();
    await prefs.setStringList(_queueKey, encoded);
  }

  Future<void> addSong(Song song) async {
    final queue = await getQueue();
    queue.insert(0, song); // add to top
    await setQueue(queue);
  }

  Future<void> removeAt(int index) async {
    final queue = await getQueue();
    if (index >= 0 && index < queue.length) {
      queue.removeAt(index);
      await setQueue(queue);
    }
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_queueKey);
  }

  Future<void> playNext() async {
    final queue = await getQueue();
    if (queue.isNotEmpty) {
      queue.removeAt(0);
      await setQueue(queue);
    }
  }
}