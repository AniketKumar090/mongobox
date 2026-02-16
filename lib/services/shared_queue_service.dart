// lib/services/shared_queue_service.dart
import 'package:firebase_database/firebase_database.dart';

class SharedQueueService {
  static final DatabaseReference _ref = FirebaseDatabase.instance.ref('queue');

  Stream<List<Song>> streamQueue() {
    return _ref.onValue.map((event) {
      final data = event.snapshot.value;
      if (data == null) return [];
      final map = data as Map<dynamic, dynamic>;
      return map.entries.map((e) {
        final key = e.key.toString();
        final value = e.value as Map<dynamic, dynamic>;
        return Song(
          key: key,
          id: value['id'] ?? '',
          title: value['title'] ?? '',
          artist: value['artist'] ?? '',
          thumbnail: value['thumbnail'] ?? '',
        );
      }).toList();
    });
  }

  Future<void> addSong(Song song) async {
    await _ref.push().set(song.toJson());
  }

  Future<void> remove(String key) async {
    await _ref.child(key).remove();
  }

  Future<void> clear() async {
    await _ref.remove();
  }
}

class Song {
  final String key, id, title, artist, thumbnail;
  Song({required this.key, required this.id, required this.title, required this.artist, required this.thumbnail});
  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'artist': artist, 'thumbnail': thumbnail};
}