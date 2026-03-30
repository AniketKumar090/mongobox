import 'background_audio_player_service.dart';
import 'lyric_audio_playback.dart';

/// After [AudioService.init], the handler replaces the plain [AudioPlayer] path
/// so Android can run a foreground media service and playback survives minimize.
class LyricAudioRegistry {
  LyricAudioRegistry._();

  static LyricAudioPlayback? _handler;

  static void register(LyricAudioPlayback handler) {
    _handler = handler;
  }

  static LyricAudioPlayback get instance =>
      _handler ?? BackgroundAudioPlayerService.instance;
}
