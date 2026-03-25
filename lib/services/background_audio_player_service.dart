import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

typedef BackgroundStreamSource = ({String url, Map<String, String>? headers});

class BackgroundAudioPlayerService {
  BackgroundAudioPlayerService._();

  static final BackgroundAudioPlayerService instance =
      BackgroundAudioPlayerService._();

  AudioPlayer _player = AudioPlayer();
  bool _loopEnabled = false;

  AudioPlayer get player => _player;

  bool get isPlaying => _player.playing;
  Duration get position => _player.position;

  Future<void> playUrl(String url, {Map<String, String>? headers}) async {
    return playSources([(url: url, headers: headers)]);
  }

  Future<void> playSources(
    List<BackgroundStreamSource> sources, [
    Duration? initialPosition,
  ]) async {
    Object? lastError;
    for (final source in sources) {
      final trimmed = source.url.trim();
      if (trimmed.isEmpty) continue;
      try {
        final duration = await _player.setAudioSource(
          AudioSource.uri(Uri.parse(trimmed), headers: source.headers),
        );
        if (initialPosition != null && initialPosition > Duration.zero) {
          final safeTarget =
              duration != null && initialPosition > duration
                  ? duration
                  : initialPosition;
          await _player.seek(safeTarget);
        }
        await _player.play();
        return;
      } catch (e) {
        lastError = e;
        debugPrint('Background audio play failed: $e');
      }
    }

    if (lastError != null) {
      throw lastError;
    }
  }

  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (_) {}
  }

  /// Stops the current player synchronously before swapping it out, so the
  /// caller can immediately resume foreground audio without overlap.
  ///
  /// The old player's [dispose] is still fire-and-forgotten (it is a
  /// heavyweight async op), but audio stops *before* the swap so there is
  /// never a window in which both the old background player and the new
  /// foreground YouTube player are producing sound simultaneously.
  Future<void> hardStopAndReset() async {
    final oldPlayer = _player;

    // ── Stop audio on the OLD player NOW, before anything else. ─────────────
    // pause() + stop() together covers both the case where the player is
    // actively playing and the case where it is buffering.
    try {
      await oldPlayer.pause();
    } catch (_) {}
    try {
      await oldPlayer.stop();
    } catch (_) {}
    // Silence the output immediately even if stop() takes a moment to settle.
    try {
      await oldPlayer.setVolume(0);
    } catch (_) {}

    // ── Swap in a fresh player. ──────────────────────────────────────────────
    _player = AudioPlayer();
    try {
      await _player.setLoopMode(_loopEnabled ? LoopMode.one : LoopMode.off);
    } catch (_) {}

    // ── Dispose the old player in the background — audio is already silent. ──
    Future<void>(() async {
      try {
        await oldPlayer.seek(Duration.zero);
      } catch (_) {}
      try {
        await oldPlayer.dispose();
      } catch (_) {}
    });
  }

  Future<void> setLoopEnabled(bool enabled) async {
    _loopEnabled = enabled;
    try {
      await _player.setLoopMode(enabled ? LoopMode.one : LoopMode.off);
    } catch (_) {}
  }

  Future<void> dispose() async {
    try {
      await _player.dispose();
    } catch (_) {}
  }
}