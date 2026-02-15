// Persistent local queue (shared_preferences). Used by web jukebox and mobile host.

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

const _keyQueue = 'mongobox_queue';

class LocalQueueService {
  static Future<LocalQueueService> create() async {
    final prefs = await SharedPreferences.getInstance();
    return LocalQueueService._(prefs);
  }

  LocalQueueService._(this._prefs);

  final SharedPreferences _prefs;

  List<Map<String, dynamic>> getQueue() {
    final raw = _prefs.getString(_keyQueue);
    if (raw == null) return [];
    try {
      final list = json.decode(raw) as List<dynamic>?;
      if (list == null) return [];
      return list
          .map((e) => Map<String, dynamic>.from(e as Map<dynamic, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> setQueue(List<Map<String, dynamic>> songs) async {
    final encoded = json.encode(songs);
    await _prefs.setString(_keyQueue, encoded);
  }

  Future<void> addSong(Map<String, dynamic> song) async {
    final list = getQueue();
    if (list.any((s) => s['id'] == song['id'])) return;
    final sanitized = {
      'id': song['id']?.toString() ?? '',
      'title': song['title']?.toString() ?? 'Unknown',
      'artist': (song['artist'] ?? song['channel'])?.toString() ?? 'Unknown',
      'thumbnail': song['thumbnail']?.toString() ?? 'https://via.placeholder.com/60x60',
    };
    list.add(sanitized);
    await setQueue(list);
  }

  Future<void> removeAt(int index) async {
    final list = getQueue();
    if (index < 0 || index >= list.length) return;
    list.removeAt(index);
    await setQueue(list);
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
    final list = getQueue();
    if (oldIndex < 0 || oldIndex >= list.length) return;
    if (newIndex < 0 || newIndex >= list.length) return;
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    await setQueue(list);
  }

  Future<void> clear() async {
    await setQueue([]);
  }

  Future<void> removeFirst() async {
    final list = getQueue();
    if (list.isEmpty) return;
    list.removeAt(0);
    await setQueue(list);
  }
}
