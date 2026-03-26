import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'dart:async';

typedef BackgroundStreamSource = ({String url, Map<String, String>? headers});

class BackgroundAudioPlayerService {
  BackgroundAudioPlayerService._() {
    _bindPlayer(_player);
  }

  static final BackgroundAudioPlayerService instance =
      BackgroundAudioPlayerService._();

  AudioPlayer _player = AudioPlayer();
  bool _loopEnabled = false;
  StreamSubscription<Duration>? _positionSubscription;
  Duration _trackedPosition = Duration.zero;
  bool _hasLoadedSource = false;

  AudioPlayer get player => _player;

  bool get isPlaying => _player.playing;
  Duration get position {
    if (!_hasLoadedSource) return Duration.zero;
    final live = _player.position;
    return live > _trackedPosition ? live : _trackedPosition;
  }

  void _bindPlayer(AudioPlayer player) {
    _positionSubscription?.cancel();
    _positionSubscription = player.positionStream.listen(
      (position) {
        if (position > _trackedPosition) {
          _trackedPosition = position;
        } else {
          _trackedPosition = position;
        }
      },
      onError: (_) {},
      cancelOnError: false,
    );
  }

  Duration _capturePosition(AudioPlayer player) {
    if (!_hasLoadedSource) return Duration.zero;
    final live = player.position;
    final captured = live > _trackedPosition ? live : _trackedPosition;
    _trackedPosition = captured;
    return captured;
  }

  bool _isPlayableUrl(String? url) {
    final trimmed = url?.trim() ?? '';
    if (trimmed.isEmpty) return false;

    final uri = Uri.tryParse(trimmed);
    return uri != null &&
        uri.isAbsolute &&
        (uri.scheme == 'http' || uri.scheme == 'https');
  }

  Future<void> playUrl(String url, {Map<String, String>? headers}) async {
    return playSources([(url: url, headers: headers)]);
  }

  Future<void> playSources(
    List<BackgroundStreamSource> sources, [
    Duration? initialPosition,
  ]) async {
    Object? lastError;
    _hasLoadedSource = false;
    _trackedPosition = initialPosition ?? Duration.zero;
    for (final source in sources) {
      final trimmed = source.url.trim();
      if (!_isPlayableUrl(trimmed)) {
        debugPrint('[BackgroundAudio] Skipping invalid URL: ${source.url}');
        continue;
      }

      try {
        final duration = await _player.setAudioSource(
          AudioSource.uri(Uri.parse(trimmed), headers: source.headers),
        );
        _hasLoadedSource = true;
        if (initialPosition != null && initialPosition > Duration.zero) {
          final safeTarget =
              duration != null && initialPosition > duration
                  ? duration
                  : initialPosition;
          await _player.seek(safeTarget);
          _trackedPosition = safeTarget;
        }
        await _player.play();
        return;
      } catch (e) {
        lastError = e;
        debugPrint('[BackgroundAudio] Failed: $trimmed');
        debugPrint('[BackgroundAudio] Error: $e');

        final message = e.toString();
        if (message.contains('NSURLErrorDomain')) {
          if (message.contains('-1013')) {
            debugPrint(
              '[BackgroundAudio] Hint: redirect loop or non-final stream URL.',
            );
          } else if (message.contains('-1015')) {
            debugPrint(
              '[BackgroundAudio] Hint: SSL/TLS decode error or expired stream URL.',
            );
          }
        }
      }
    }

    if (lastError != null) {
      throw lastError;
    }
  }

  Future<void> stop() async {
    try {
      _capturePosition(_player);
      await _player.stop();
    } catch (_) {}
    _hasLoadedSource = false;
    _trackedPosition = Duration.zero;
  }

  /// Stops the current player synchronously before swapping it out, so the
  /// caller can immediately resume foreground audio without overlap.
  ///
  /// The old player's [dispose] is still fire-and-forgotten (it is a
  /// heavyweight async op), but audio stops *before* the swap so there is
  /// never a window in which both the old background player and the new
  /// foreground YouTube player are producing sound simultaneously.
  Future<Duration> hardStopAndReset() async {
    final oldPlayer = _player;
    final stopPosition = _capturePosition(oldPlayer);

    try {
      await oldPlayer.pause();
    } catch (_) {}
    final pausedPosition = _capturePosition(oldPlayer);
    try {
      await oldPlayer.stop();
    } catch (_) {}
    final stoppedPosition = _capturePosition(oldPlayer);
    // Silence the output immediately even if stop() takes a moment to settle.
    try {
      await oldPlayer.setVolume(0);
    } catch (_) {}

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        final session = await AudioSession.instance;
        await session.setActive(false);
      } catch (e) {
        debugPrint('[BackgroundAudio] Audio session reset failed: $e');
      }
    }

    _player = AudioPlayer();
    final finalPosition =
        stoppedPosition > pausedPosition
            ? stoppedPosition
            : pausedPosition > stopPosition
            ? pausedPosition
            : stopPosition;
    _trackedPosition = Duration.zero;
    _hasLoadedSource = false;
    _bindPlayer(_player);
    try {
      await _player.setLoopMode(_loopEnabled ? LoopMode.one : LoopMode.off);
    } catch (_) {}

    Future<void>(() async {
      try {
        await oldPlayer.seek(Duration.zero);
      } catch (_) {}
      try {
        await oldPlayer.dispose();
      } catch (_) {}
    });

    await Future<void>.delayed(const Duration(milliseconds: 100));
    return finalPosition;
  }

  Future<void> setLoopEnabled(bool enabled) async {
    _loopEnabled = enabled;
    try {
      await _player.setLoopMode(enabled ? LoopMode.one : LoopMode.off);
    } catch (_) {}
  }

  Future<void> dispose() async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    try {
      await _player.dispose();
    } catch (_) {}
  }
}
