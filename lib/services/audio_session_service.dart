import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import 'lyric_background_audio_handler.dart';
import 'lyric_audio_registry.dart';

/// Initialises [AudioService] and registers the handler.
///
/// Hot-restart safe: if [AudioService] is already running (e.g. after a
/// Flutter hot-restart while music is playing), we re-use the existing
/// handler instead of trying to init a second time, which would throw.
class AppAudioSessionService {
  AppAudioSessionService._();

  static LyricBackgroundAudioHandler? _handler;
  static bool _initialized = false;

  // ── Public entry points ──────────────────────────────────────────────────

  /// Alias kept for call-sites that use ensureConfigured().
  static Future<LyricBackgroundAudioHandler> ensureConfigured() => init();

  static Future<LyricBackgroundAudioHandler> init() async {
    if (_initialized && _handler != null) return _handler!;

    try {
      final handler = await AudioService.init<LyricBackgroundAudioHandler>(
        builder: () => LyricBackgroundAudioHandler(),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.kurenai7968.mongobox.audio',
          androidNotificationChannelName: 'LyricQsk Playback',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
        ),
      );
      _handler = handler;
      _initialized = true;
      LyricAudioRegistry.register(handler);
      debugPrint('[AudioSession] AudioService initialised fresh');
      return handler;
    } catch (e) {
      // AudioService.init throws if called again in the same process
      // (happens on hot-restart). The existing handler is still alive.
      debugPrint('[AudioSession] AudioService.init failed ($e) — re-attaching');
      return _reattach();
    }
  }

  /// Re-attach after hot-restart. AudioService keeps the handler alive
  /// internally; we stored it in [_handler] before the restart tore down
  /// the Dart isolate, so if that static survived we can reuse it.
  /// Otherwise we create a standalone handler as a safe fallback.
  static LyricBackgroundAudioHandler _reattach() {
    // _handler is a Dart static — it survives hot-reload but NOT hot-restart
    // (hot-restart tears down the isolate). So on a true hot-restart this
    // will be null. We create a fresh standalone handler; it won't have
    // system media controls but the UI will work correctly.
    if (_handler != null) {
      LyricAudioRegistry.register(_handler!);
      debugPrint('[AudioSession] Re-using cached handler after hot-reload');
      return _handler!;
    }

    debugPrint('[AudioSession] Creating standalone fallback handler');
    final fallback = LyricBackgroundAudioHandler();
    _handler = fallback;
    _initialized = true;
    LyricAudioRegistry.register(fallback);
    return fallback;
  }

  /// Call this before starting audio playback to activate AVAudioSession.
  /// Kept for call-site compatibility — activation is done inside
  /// LyricBackgroundAudioHandler.playSources.
  static Future<void> activatePlayback() async {}
}
