// lib/services/shared_queue_service.dart
import 'package:firebase_database/firebase_database.dart';

class SharedQueueService {
  static final DatabaseReference _ref = FirebaseDatabase.instance.ref('queue');

  // Stream the entire queue as a list of Song objects
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

  // Add a song to the shared queue
  Future<void> addSong(Song song) async {
    await _ref.push().set(song.toJson());
  }

  // Remove a song by its Firebase key
  Future<void> remove(String key) async {
    await _ref.child(key).remove();
  }

  // Clear the entire queue
  Future<void> clear() async {
    await _ref.remove();
  }
}

class Song {
  final String key; // Firebase push key
  final String id, title, artist, thumbnail;

  Song({
    required this.key,
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
}