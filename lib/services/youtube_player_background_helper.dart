// YouTube player background audio configuration helper
// Enables YouTube player to continue playing audio when app is in background

import 'package:youtube_player_flutter/youtube_player_flutter.dart';

class YouTubePlayerBackgroundHelper {
  /// Initialize YouTube player controller with background audio support
  ///
  /// - Enables auto-play for seamless resumption
  /// - Allows in-app audio playback to continue in background
  /// - Returns a fully configured controller
  static YoutubePlayerController createBackgroundAwareController({
    required String videoId,
    int startSeconds = 0,
    bool autoPlay = true,
    bool loop = false,
  }) {
    final resolvedVideoId = YoutubePlayer.convertUrlToId(videoId) ?? videoId;
    final safeStartSeconds = startSeconds < 0 ? 0 : startSeconds;
    return YoutubePlayerController(
      initialVideoId: resolvedVideoId,
      flags: YoutubePlayerFlags(
        autoPlay: autoPlay,
        startAt: safeStartSeconds,
        mute: false,
        enableCaption: true,
        useHybridComposition: true,
        loop: loop,
      ),
    );
  }

  /// Configure controller for background playback with all options
  static YoutubePlayerController createWithFullConfig({
    required String videoId,
    int startSeconds = 0,
    bool autoPlay = true,
    bool showFullscreenButton = true,
    bool showControls = true,
    // `showVideoProgressIndicator` is configured on the `YoutubePlayer` widget,
    // not on the controller/flags.
    // ignore: unused_parameter
    bool showVideoProgressIndicator = true,
  }) {
    final resolvedVideoId = YoutubePlayer.convertUrlToId(videoId) ?? videoId;
    final safeStartSeconds = startSeconds < 0 ? 0 : startSeconds;

    return YoutubePlayerController(
      initialVideoId: resolvedVideoId,
      flags: YoutubePlayerFlags(
        autoPlay: autoPlay,
        startAt: safeStartSeconds,
        mute: false,
        enableCaption: true,
        isLive: false,
        hideControls: !showControls,
        // This flag only affects the live-player UI.
        showLiveFullscreenButton: showFullscreenButton,
        useHybridComposition: true,
      ),
    );
  }

  /// Handle app lifecycle to maintain audio playback
  /// Call this in dispose methods to properly cleanup
  static void disposeController(YoutubePlayerController? controller) {
    if (controller == null) return;
    controller.pause();
    controller.dispose();
  }

  /// Resume playback when app comes back to foreground
  static void resumePlayback(YoutubePlayerController? controller) {
    if (controller != null) {
      controller.play();
    }
  }

  /// Pause playback when app goes to background (optional - for battery saving)
  static void pauseOnBackground(YoutubePlayerController? controller) {
    if (controller != null) {
      controller.pause();
    }
  }
}
