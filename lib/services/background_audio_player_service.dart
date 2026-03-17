import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

class BackgroundAudioPlayerService {
  BackgroundAudioPlayerService._();

  static final BackgroundAudioPlayerService instance =
      BackgroundAudioPlayerService._();

  final AudioPlayer _player = AudioPlayer();

  AudioPlayer get player => _player;

  bool get isPlaying => _player.playing;

  Future<void> playUrl(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    try {
      await _player.setUrl(trimmed);
      await _player.play();
    } catch (e) {
      debugPrint('Background audio play failed: $e');
      rethrow;
    }
  }

  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    try {
      await _player.dispose();
    } catch (_) {}
  }
}

