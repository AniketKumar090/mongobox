// lib/services/shared_queue_service.dart
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_core/firebase_core.dart';

class SharedQueueService {
  final String _partyId;

  // Singleton cache - ensures the same party ID always uses the same instance
  static final Map<String, SharedQueueService> _instances = {};

  late final DatabaseReference _ref = FirebaseDatabase.instanceFor(
    app: Firebase.app("MongoBox"),
  ).ref('parties/$_partyId/queue');
  late final DatabaseReference _membersRef = FirebaseDatabase.instanceFor(
    app: Firebase.app("MongoBox"),
  ).ref('parties/$_partyId/members');
  late final DatabaseReference _metaRef = FirebaseDatabase.instanceFor(
    app: Firebase.app("MongoBox"),
  ).ref('parties/$_partyId/meta');

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

    return _ref.onValue.map((event) {
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

        final entries =
            map.entries.toList()
              ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));
        final songs = <Song>[];
        for (var i = 0; i < entries.length; i++) {
          final entry = entries[i];
          try {
            final songMap = entry.value as Map<dynamic, dynamic>;
            final song = Song(
              key: entry.key.toString(),
              id: songMap['id']?.toString() ?? '',
              title: songMap['title']?.toString() ?? '',
              artist: songMap['artist']?.toString() ?? '',
              thumbnail: songMap['thumbnail']?.toString() ?? '',
              order: (songMap['order'] as num?)?.toInt() ?? i,
            );
            songs.add(song);
            print('  ✅ Parsed song: ${song.title} (${song.id})');
          } catch (e) {
            print('  ❌ Error parsing individual song: $e');
            print('     Song data: ${entry.value}');
          }
        }

        songs.sort((a, b) {
          final orderCompare = a.order.compareTo(b.order);
          if (orderCompare != 0) return orderCompare;
          return a.key.compareTo(b.key);
        });

        print(
          '✅ Successfully parsed ${songs.length} songs for party: $_partyId',
        );
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

  Stream<List<PartyMember>> streamMembers() {
    print('👥 ========================================');
    print('👥 Starting members stream for party: $_partyId');
    print('📍 Firebase path: parties/$_partyId/members');
    print('👥 ========================================');

    return _membersRef.onValue.map((event) {
      final data = event.snapshot.value;
      if (data == null) {
        return <PartyMember>[];
      }

      try {
        final map = data as Map<dynamic, dynamic>;
        final members = <PartyMember>[];
        for (final entry in map.entries) {
          final value = entry.value;
          if (value is! Map<dynamic, dynamic>) continue;
          members.add(PartyMember.fromJson(entry.key.toString(), value));
        }
        members.sort((a, b) => a.joinedAt.compareTo(b.joinedAt));
        return members;
      } catch (e) {
        print('❌ Error parsing members for party $_partyId: $e');
        return <PartyMember>[];
      }
    });
  }

  Stream<PartyLiveStatus> streamPartyStatus() {
    return _metaRef.onValue.map((event) {
      final data = event.snapshot.value;
      if (data is Map<dynamic, dynamic>) {
        return PartyLiveStatus.fromJson(data);
      }
      return const PartyLiveStatus();
    });
  }

  Future<PartyLiveStatus> fetchPartyStatus() async {
    final snapshot = await _metaRef.get();
    final data = snapshot.value;
    if (data is Map<dynamic, dynamic>) {
      return PartyLiveStatus.fromJson(data);
    }
    return const PartyLiveStatus();
  }

  Future<void> startHostingSession() async {
    try {
      await _metaRef.onDisconnect().update({
        'isLive': false,
        'endedAt': ServerValue.timestamp,
      });
    } catch (e) {
      print(
        '⚠️ Error registering onDisconnect handler for party $_partyId: $e',
      );
    }

    try {
      // Use set() so endedAt is physically absent from the node —
      // update() can't delete keys and two-step remove+update creates
      // a race window that briefly makes guests see the party as ended.
      await _metaRef.set({
        'isLive': true,
        'startedAt': ServerValue.timestamp,
        'hostLastSeenAt': ServerValue.timestamp,
      });
    } catch (e) {
      print('❌ Error starting hosting session for party $_partyId: $e');
      rethrow;
    }
  }

  Future<void> pulseHostingSession() async {
    try {
      // Same reasoning — set() overwrites the whole meta node so there
      // is never a transient state where endedAt exists alongside isLive:true.
      await _metaRef.set({
        'isLive': true,
        'hostLastSeenAt': ServerValue.timestamp,
      });
    } catch (e) {
      print('❌ Error updating host heartbeat for party $_partyId: $e');
    }
  }

  Future<void> stopHostingSession() async {
    try {
      await _metaRef.onDisconnect().cancel();
    } catch (e) {
      print(
        '⚠️ Error cancelling onDisconnect handler for party $_partyId: $e',
      );
    }

    try {
      await _metaRef.update({
        'isLive': false,
        'endedAt': ServerValue.timestamp,
      });
    } catch (e) {
      print('❌ Error stopping hosting session for party $_partyId: $e');
    }
  }

  Future<void> addSong(Song song) async {
    try {
      final partyStatus = await fetchPartyStatus();
      if (partyStatus.endedAt != null) {
        throw StateError('This party has ended.');
      }

      print('➕ ========================================');
      print('➕ Adding song to party: $_partyId');
      print('➕ Firebase path: parties/$_partyId/queue');
      print('➕ Song: ${song.title}');
      print('➕ Video ID: ${song.id}');

      final songData = {...song.toJson(), 'order': await _nextOrderValue()};
      print('➕ Song data: $songData');

      final ref = _ref.push();
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

  Future<void> joinMember(PartyMember member) async {
    try {
      print('👤 ========================================');
      print('👤 Registering member in party: $_partyId');
      print('👤 Member: ${member.name} (${member.id})');
      await _membersRef.child(member.id).set(member.toJson());
      print('✅ Member registered successfully');
      print('👤 ========================================');
    } catch (e) {
      print('❌ Error registering member in party $_partyId: $e');
      rethrow;
    }
  }

  Future<void> leaveMember(String memberId) async {
    if (memberId.trim().isEmpty) return;
    try {
      print('👋 ========================================');
      print('👋 Removing member $memberId from party: $_partyId');
      await _membersRef.child(memberId).remove();
      print('✅ Member removed successfully');
      print('👋 ========================================');
    } catch (e) {
      print('❌ Error removing member from party $_partyId: $e');
      rethrow;
    }
  }

  Future<void> incrementMemberSongsAdded(String memberId) async {
    if (memberId.trim().isEmpty) return;
    try {
      final memberRef = _membersRef.child(memberId);
      final snapshot = await memberRef.get();
      final data = snapshot.value as Map<dynamic, dynamic>?;
      if (data == null) return;
      final currentCount = (data['songsAdded'] as num?)?.toInt() ?? 0;
      await memberRef.update({
        'songsAdded': currentCount + 1,
        'lastSeenAt': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      print('❌ Error incrementing songsAdded for member $memberId: $e');
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

  Future<void> reorderQueue(List<Song> songs) async {
    try {
      print('🔀 ========================================');
      print('🔀 Reordering queue for party: $_partyId');
      final updates = <String, Object?>{};
      for (var i = 0; i < songs.length; i++) {
        final key = songs[i].key.trim();
        if (key.isEmpty) continue;
        updates['$key/order'] = i;
      }
      if (updates.isEmpty) {
        print('⚠️ No queue items had keys; skipping reorder');
        print('🔀 ========================================');
        return;
      }
      await _ref.update(updates);
      print('✅ Queue reordered successfully');
      print('🔀 ========================================');
    } catch (e) {
      print('❌ ========================================');
      print('❌ Error reordering queue for party $_partyId: $e');
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

  Future<int> _nextOrderValue() async {
    final snapshot = await _ref.once();
    final data = snapshot.snapshot.value;
    if (data is! Map<dynamic, dynamic>) return 0;

    final entries = data.entries.where(
      (entry) => entry.value is Map<dynamic, dynamic>,
    );
    var count = 0;
    var maxExplicitOrder = -1;
    for (final entry in entries) {
      final songMap = entry.value as Map<dynamic, dynamic>;
      count++;
      final order = (songMap['order'] as num?)?.toInt();
      if (order != null && order > maxExplicitOrder) {
        maxExplicitOrder = order;
      }
    }

    final fallbackLastOrder = count - 1;
    final lastOrder =
        maxExplicitOrder > fallbackLastOrder
            ? maxExplicitOrder
            : fallbackLastOrder;
    return lastOrder + 1;
  }

  /// Clear all cached instances (useful for testing)
  static void clearCache() {
    _instances.clear();
    print('🗑️ Cleared all SharedQueueService instances');
  }
}

class Song {
  final String key, id, title, artist, thumbnail;
  final int order;

  Song({
    required this.key,
    required this.id,
    required this.title,
    required this.artist,
    required this.thumbnail,
    this.order = 0,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'thumbnail': thumbnail,
    'order': order,
  };

  @override
  String toString() =>
      'Song(key: $key, id: $id, title: $title, artist: $artist, order: $order)';
}

class PartyMember {
  const PartyMember({
    required this.id,
    required this.name,
    required this.joinedAt,
    required this.lastSeenAt,
    this.songsAdded = 0,
  });

  final String id;
  final String name;
  final DateTime joinedAt;
  final DateTime lastSeenAt;
  final int songsAdded;

  Map<String, dynamic> toJson() => {
    'name': name,
    'joinedAt': joinedAt.toIso8601String(),
    'lastSeenAt': lastSeenAt.toIso8601String(),
    'songsAdded': songsAdded,
  };

  factory PartyMember.fromJson(String id, Map<dynamic, dynamic> json) {
    return PartyMember(
      id: id,
      name: json['name']?.toString() ?? 'Guest',
      joinedAt:
          DateTime.tryParse(json['joinedAt']?.toString() ?? '') ??
          DateTime.now(),
      lastSeenAt:
          DateTime.tryParse(json['lastSeenAt']?.toString() ?? '') ??
          DateTime.now(),
      songsAdded: (json['songsAdded'] as num?)?.toInt() ?? 0,
    );
  }
}

class PartyLiveStatus {
  const PartyLiveStatus({
    this.isLive = false,
    this.startedAt,
    this.hostLastSeenAt,
    this.endedAt,
  });

  final bool isLive;
  final DateTime? startedAt;
  final DateTime? hostLastSeenAt;
  final DateTime? endedAt;

  factory PartyLiveStatus.fromJson(Map<dynamic, dynamic> json) {
    return PartyLiveStatus(
      isLive: json['isLive'] == true,
      startedAt: _parsePartyTimestamp(json['startedAt']),
      hostLastSeenAt: _parsePartyTimestamp(json['hostLastSeenAt']),
      endedAt: _parsePartyTimestamp(json['endedAt']),
    );
  }
}

DateTime? _parsePartyTimestamp(dynamic raw) {
  if (raw == null) return null;
  if (raw is int) {
    return DateTime.fromMillisecondsSinceEpoch(raw);
  }
  if (raw is double) {
    return DateTime.fromMillisecondsSinceEpoch(raw.round());
  }
  return DateTime.tryParse(raw.toString());
}
