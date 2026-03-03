// lib/services/shared_queue_service.dart
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_core/firebase_core.dart';

class SharedQueueService {
  final String _partyId;
  
  // Singleton cache - ensures the same party ID always uses the same instance
  static final Map<String, SharedQueueService> _instances = {};

  late final DatabaseReference _ref = FirebaseDatabase.instanceFor(
    app: Firebase.app("MongoBox")
  ).ref('parties/$_partyId/queue');

  /// Private constructor
  SharedQueueService._internal({required String partyId}) : _partyId = partyId {
    print('🔧 SharedQueueService created for party: $_partyId');
  }

  /// Factory constructor - returns cached instance for party ID or creates new one
  factory SharedQueueService({String? partyId}) {
    final party = partyId ?? 'default_party';
    
    if (_instances.containsKey(party)) {
      print('🔄 Reusing cached SharedQueueService for party: $party');
      return _instances[party]!;
    }
    
    print('✨ Creating new SharedQueueService instance for party: $party');
    final instance = SharedQueueService._internal(partyId: party);
    _instances[party] = instance;
    return instance;
  }

  /// Stream all songs in this party's queue
  Stream<List<Song>> streamQueue() {
    print('🎧 ========================================');
    print('🎧 Starting queue stream for party: $_partyId');
    print('📍 Firebase path: parties/$_partyId/queue');
    print('🔥 Firebase ref valid: $_ref != null');
    print('🎧 ========================================');
    
    return _ref.onValue
      .map((event) {
        final timestamp = DateTime.now().toString();
        print('📥 ========================================');
        print('📥 Queue event received for party: $_partyId');
        print('📥 Timestamp: $timestamp');
        
        final data = event.snapshot.value;
        print('📥 Raw data type: ${data.runtimeType}');
        print('📥 Raw data: $data');
        
        if (data == null) {
          print('📭 No data in queue for party: $_partyId');
          print('📥 ========================================');
          return <Song>[];
        }
        
        try {
          final map = data as Map<dynamic, dynamic>;
          print('📦 Found ${map.length} items in queue');
          
          final songs = <Song>[];
          map.forEach((key, value) {
            try {
              final songMap = value as Map<dynamic, dynamic>;
              final song = Song(
                key: key.toString(),
                id: songMap['id']?.toString() ?? '',
                title: songMap['title']?.toString() ?? '',
                artist: songMap['artist']?.toString() ?? '',
                thumbnail: songMap['thumbnail']?.toString() ?? '',
              );
              songs.add(song);
              print('  ✅ Parsed song: ${song.title} (${song.id})');
            } catch (e) {
              print('  ❌ Error parsing individual song: $e');
              print('     Song data: $value');
            }
          });
          
          print('✅ Successfully parsed ${songs.length} songs for party: $_partyId');
          print('📥 ========================================');
          return songs;
        } catch (e) {
          print('❌ ========================================');
          print('❌ Error parsing queue for party $_partyId: $e');
          print('❌ Raw data: $data');
          print('❌ ========================================');
          return <Song>[];
        }
      });
  }

  Future<void> addSong(Song song) async {
    try {
      print('➕ ========================================');
      print('➕ Adding song to party: $_partyId');
      print('➕ Firebase path: parties/$_partyId/queue');
      print('➕ Song: ${song.title}');
      print('➕ Video ID: ${song.id}');
      
      final songData = song.toJson();
      print('➕ Song data: $songData');
      
      final ref = await _ref.push();
      await ref.set(songData);
      
      print('✅ Song added successfully with key: ${ref.key}');
      print('➕ ========================================');
    } catch (e) {
      print('❌ ========================================');
      print('❌ Error adding song to party $_partyId: $e');
      print('❌ ========================================');
      rethrow;
    }
  }

  Future<void> remove(String key) async {
    try {
      print('➖ ========================================');
      print('➖ Removing song: $key from party: $_partyId');
      await _ref.child(key).remove();
      print('✅ Song removed successfully');
      print('➖ ========================================');
    } catch (e) {
      print('❌ ========================================');
      print('❌ Error removing song from party $_partyId: $e');
      print('❌ ========================================');
      rethrow;
    }
  }

  Future<void> clear() async {
    try {
      print('🗑️ ========================================');
      print('🗑️ Clearing queue for party: $_partyId');
      await _ref.remove();
      print('✅ Queue cleared successfully');
      print('🗑️ ========================================');
    } catch (e) {
      print('❌ ========================================');
      print('❌ Error clearing queue for party $_partyId: $e');
      print('❌ ========================================');
      rethrow;
    }
  }

  /// Test method to manually fetch queue data
  Future<void> testFetch() async {
    try {
      print('🧪 ========================================');
      print('🧪 TEST: Manually fetching queue for party: $_partyId');
      print('🧪 Firebase path: parties/$_partyId/queue');
      
      final snapshot = await _ref.once();
      final data = snapshot.snapshot.value;
      
      print('🧪 Raw data type: ${data.runtimeType}');
      print('🧪 Raw data: $data');
      
      if (data == null) {
        print('🧪 Queue is empty');
      } else {
        final map = data as Map<dynamic, dynamic>;
        print('🧪 Found ${map.length} songs in queue:');
        map.forEach((key, value) {
          print('   - Key: $key');
          print('     Data: $value');
        });
      }
      print('🧪 ========================================');
    } catch (e) {
      print('❌ Test fetch error: $e');
    }
  }

  /// Diagnostic: Check current Firebase connection state and party path
  Future<void> diagnosticCheck() async {
    print('\n🔍 ========================================');
    print('🔍 DIAGNOSTIC CHECK for party: $_partyId');
    print('🔍 Firebase path: parties/$_partyId/queue');
    print('🔍 Service instance ID: ${this.hashCode}');
    print('🔍 ========================================');
    
    // Manually fetch to verify data exists
    await testFetch();
    
    // Test if we can write
    try {
      final testRef = _ref.push();
      print('✅ Can write to Firebase (test push created: ${testRef.key})');
      await testRef.remove();
      print('✅ Can remove from Firebase (cleaned up test)');
    } catch (e) {
      print('❌ Cannot write to Firebase: $e');
    }
    
    print('🔍 END DIAGNOSTIC\n');
  }

  /// Clear all cached instances (useful for testing)
  static void clearCache() {
    _instances.clear();
    print('🗑️ Cleared all SharedQueueService instances');
  }
}

class Song {
  final String key, id, title, artist, thumbnail;
  
  Song({
    required this.key, 
    required this.id, 
    required this.title, 
    required this.artist, 
    required this.thumbnail
  });
  
  Map<String, dynamic> toJson() => {
    'id': id, 
    'title': title, 
    'artist': artist, 
    'thumbnail': thumbnail
  };

  @override
  String toString() => 'Song(key: $key, id: $id, title: $title, artist: $artist)';
}