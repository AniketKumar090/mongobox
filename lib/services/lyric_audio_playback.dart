import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

typedef BackgroundStreamSource = ({String url, Map<String, String>? headers});

/// Shared contract for the background stream player (plain [AudioPlayer] or
/// [audio_service] handler).
abstract class LyricAudioPlayback {
  AudioPlayer get player;

  bool get isPlaying;

  Duration get position;

  Future<void> playSources(
    List<BackgroundStreamSource> sources, [
    Duration? initialPosition,
    MediaItem? mediaItem,
  ]);

  Future<void> stop();

  Future<Duration> hardStopAndReset();

  Future<void> setLoopEnabled(bool enabled);
}
