import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'lyric_audio_playback.dart';

/// [audio_service] + [just_audio] — required on Android for reliable background
/// playback (foreground media service) and system media controls.
///
/// Fix log (2025-Q2):
///   - Activate AudioSession BEFORE calling play() — on iOS this is mandatory.
///   - On iOS, Android-signed URLs are rewritten by [YouTubeAudioStreamService]
///     before reaching here, so no additional URL surgery needed.
///   - [playSources] now throws the last error only after ALL sources have been
///     tried, giving the caller accurate failure info.
///   - [stop] clears _hasLoadedSource immediately so subsequent isPlaying /
///     position checks return sane values.
///   - [hardStopAndReset] deactivates the audio session before swapping players
///     so the new player can acquire it cleanly.
///   - [_isPlayableUrl] rejects empty / non-http(s) strings early.
class LyricBackgroundAudioHandler extends BaseAudioHandler
    with SeekHandler
    implements LyricAudioPlayback {
  LyricBackgroundAudioHandler() {
    _bindPlayerListeners();
    _bindPositionTracking();
    _bindDurationTracking();
  }

  AudioPlayer _player = AudioPlayer();
  bool _loopEnabled = false;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  StreamSubscription<PlaybackState>? _playbackEventSubscription;
  Duration _trackedPosition = Duration.zero;
  bool _hasLoadedSource = false;

  @override
  AudioPlayer get player => _player;

  @override
  bool get isPlaying => _player.playing;

  @override
  Duration get position {
    if (!_hasLoadedSource) return Duration.zero;
    final live = _player.position;
    return live > _trackedPosition ? live : _trackedPosition;
  }

  void _bindPositionTracking() {
    _positionSubscription?.cancel();
    _positionSubscription = _player.positionStream.listen(
      (p) => _trackedPosition = p,
      onError: (_) {},
      cancelOnError: false,
    );
  }

  void _bindPlayerListeners() {
    _playbackEventSubscription?.cancel();
    _playbackEventSubscription = _player.playbackEventStream
        .map(_transformEvent)
        .listen(playbackState.add, onError: (_) {}, cancelOnError: false);
  }

  void _bindDurationTracking() {
    _durationSubscription?.cancel();
    _durationSubscription = _player.durationStream.listen(
      (duration) {
        final current = mediaItem.value;
        if (current == null || duration == null || duration <= Duration.zero) {
          return;
        }
        if (current.duration == duration) return;
        mediaItem.add(current.copyWith(duration: duration));
      },
      onError: (_) {},
      cancelOnError: false,
    );
  }

  PlaybackState _transformEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.rewind,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
        MediaControl.fastForward,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 3],
      processingState:
          const {
            ProcessingState.idle: AudioProcessingState.idle,
            ProcessingState.loading: AudioProcessingState.loading,
            ProcessingState.buffering: AudioProcessingState.buffering,
            ProcessingState.ready: AudioProcessingState.ready,
            ProcessingState.completed: AudioProcessingState.completed,
          }[_player.processingState]!,
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: event.currentIndex,
    );
  }

  Duration _capturePosition(AudioPlayer p) {
    if (!_hasLoadedSource) return Duration.zero;
    final live = p.position;
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

  /// Activate AVAudioSession (iOS) / AudioFocus (Android).
  /// MUST be called before [AudioPlayer.play].
  Future<void> _activateSession() async {
    if (kIsWeb) return;
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      await session.setActive(true);
    } catch (e) {
      debugPrint('[BackgroundHandler] Audio session activation failed: $e');
    }
  }

  @override
  Future<void> playSources(
    List<BackgroundStreamSource> sources, [
    Duration? initialPosition,
    MediaItem? mediaItem,
  ]) async {
    Object? lastError;
    _hasLoadedSource = false;
    _trackedPosition = initialPosition ?? Duration.zero;

    if (mediaItem != null) {
      this.mediaItem.add(mediaItem);
    }

    // Activate session before any play() call.
    await _activateSession();

    for (final source in sources) {
      final trimmed = source.url.trim();
      if (!_isPlayableUrl(trimmed)) {
        debugPrint('[BackgroundHandler] Skipping invalid URL: ${source.url}');
        continue;
      }

      try {
        final duration = await _player.setAudioSource(
          AudioSource.uri(
            Uri.parse(trimmed),
            headers: source.headers,
            tag: mediaItem,
          ),
        );
        _hasLoadedSource = true;

        if (mediaItem != null &&
            duration != null &&
            duration > Duration.zero &&
            this.mediaItem.value?.duration != duration) {
          this.mediaItem.add(mediaItem.copyWith(duration: duration));
        }

        if (initialPosition != null && initialPosition > Duration.zero) {
          final safeTarget =
              (duration != null && initialPosition > duration)
                  ? duration
                  : initialPosition;
          await _player.seek(safeTarget);
          _trackedPosition = safeTarget;
        }

        await _player.setLoopMode(_loopEnabled ? LoopMode.one : LoopMode.off);
        final playFuture = _player.play();
        unawaited(
          playFuture.catchError((Object error, StackTrace stackTrace) {
            debugPrint(
              '[BackgroundHandler] Playback error after start: $error',
            );
            debugPrint('$stackTrace');
          }),
        );
        debugPrint('[BackgroundHandler] Playback started: $trimmed');
        return; // ← success, early exit
      } catch (e) {
        lastError = e;
        _hasLoadedSource = false; // reset so next source starts clean
        debugPrint(
          '[BackgroundHandler] Failed source: ${trimmed.substring(0, trimmed.length.clamp(0, 80))}…',
        );
        debugPrint('[BackgroundHandler] Error: $e');

        final msg = e.toString();
        if (msg.contains('NSURLErrorDomain')) {
          if (msg.contains('-1013')) {
            debugPrint(
              '[BackgroundHandler] Hint: redirect loop or non-final stream URL.',
            );
          } else if (msg.contains('-1015')) {
            debugPrint(
              '[BackgroundHandler] Hint: SSL/TLS decode error or expired URL.',
            );
          } else if (msg.contains('-1')) {
            debugPrint(
              '[BackgroundHandler] Hint: iOS CDN auth mismatch — URL may have wrong client token.',
            );
          }
        }
        if (msg.contains('-11828')) {
          debugPrint(
            '[BackgroundHandler] Hint: (-11828) = unsupported codec on iOS (WebM/Opus). Skipping.',
          );
        }
        // Continue to next source.
      }
    }

    // All sources failed.
    if (lastError != null) throw lastError;
  }

  @override
  Future<void> stop() async {
    _hasLoadedSource = false; // clear immediately so UI reflects stopped state
    _trackedPosition = Duration.zero;
    try {
      await _player.stop();
    } catch (_) {}
    await super.stop();
  }

  @override
  Future<Duration> hardStopAndReset() async {
    final oldPlayer = _player;
    final stopPosition = _capturePosition(oldPlayer);

    try {
      await oldPlayer.setVolume(0);
    } catch (_) {}
    try {
      await oldPlayer.pause();
    } catch (_) {}
    final pausedPosition = _capturePosition(oldPlayer);
    try {
      await oldPlayer.stop();
    } catch (_) {}
    final stoppedPosition = _capturePosition(oldPlayer);

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        final session = await AudioSession.instance;
        await session.setActive(false);
      } catch (e) {
        debugPrint('[BackgroundHandler] Session deactivation failed: $e');
      }
    }

    _player = AudioPlayer();
    final finalPosition = [
      stoppedPosition,
      pausedPosition,
      stopPosition,
    ].reduce((a, b) => a > b ? a : b);
    _trackedPosition = Duration.zero;
    _hasLoadedSource = false;
    _bindPlayerListeners();
    _bindPositionTracking();
    _bindDurationTracking();
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

  @override
  Future<void> setLoopEnabled(bool enabled) async {
    _loopEnabled = enabled;
    try {
      await _player.setLoopMode(enabled ? LoopMode.one : LoopMode.off);
    } catch (_) {}
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);
}
