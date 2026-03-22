import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

class AppAudioSessionService {
  AppAudioSessionService._();

  static bool _configured = false;

  /// Configure a playback-focused audio session so audio can continue
  /// when the app is backgrounded (platform permitting).
  static Future<void> ensureConfigured() async {
    if (_configured) return;
    _configured = true;

    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      await session.setActive(true);
    } catch (e) {
      debugPrint('Audio session config failed: $e');
    }
  }

  /// Call before starting playback (e.g. after other audio or route changes).
  static Future<void> activatePlayback() async {
    try {
      final session = await AudioSession.instance;
      await session.setActive(true);
    } catch (e) {
      debugPrint('Audio session activate failed: $e');
    }
  }
}

