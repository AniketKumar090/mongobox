// Mobile Lyric Play: single-line input (text + speech), play from that line.
// REFACTORED: Fully dynamic, non-scrollable layout adapting to all screen sizes.
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import '../services/playback_service_mobile.dart';
import '../services/local_suggestions_service.dart';
import '../services/youtube_quota_monitor.dart';
import '../services/lightweight_search_service.dart';
import '../services/tts_service.dart';
import '../services/youtube_player_background_helper.dart';
import '../services/background_audio_player_service.dart';
import '../services/soundcloud_service.dart';
import '../theme/lyric_screen_theme.dart';
import '../widgets/lyric_page_scaffold.dart';
import 'host_party_screen.dart';
import 'join_via_link_screen.dart';
import 'saved_voice_songs_screen.dart';
import '../screens/generate_song_screen.dart';

class LyricHomeScreen extends StatefulWidget {
  const LyricHomeScreen({super.key});

  @override
  State<LyricHomeScreen> createState() => _LyricHomeScreenState();
}

class _LyricHomeScreenState extends State<LyricHomeScreen>
    with WidgetsBindingObserver {
  final _lyricController = TextEditingController();
  final _playbackService = PlaybackServiceMobile();
  final _quotaMonitor = YouTubeQuotaMonitor();
  final _lightweightService = LightweightSearchService();
  YoutubePlayerController? _ytController;
  PlaybackResult? _nowPlaying;
  bool _isLoading = false;
  bool _isListening = false;
  bool _isQuotaSavingMode = false;
  bool _wasPlayingBeforeBackground = false;
  bool _isLooping = false;
  bool _isHandlingLoopRestart = false;
  bool _backgroundMirrorFailed = false;
  bool _foregroundAudioSuppressedForBackground = false;
  bool _isRestoringForeground = false;
  Duration _backgroundSyncPosition = Duration.zero;
  Duration _loopStartPosition = Duration.zero;
  double _playerVolume = 1.0;
  double _volumeSystemCap = 1.0;
  StreamSubscription<dynamic>? _volumeSubscription;
  static const String _volumeFetchInitialKey = 'fetchInitialVolume';
  static const String _volumeEventChannelName =
      'com.kurenai7968.volume_controller.volume_listener_event';
  LocalSuggestionsService? _suggestions;
  List<String> _recentLines = [];
  List<RecentTrack> _recentTracks = [];
  final SpeechToText _speech = SpeechToText();
  final TtsService _tts = TtsService();
  final SoundCloudService _soundcloud = SoundCloudService();
  bool _isBackgroundAudioLoading = false;
  bool _appIsInBackground = false;
  int _backgroundMirrorRequestId = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initVolumeController());
    _loadSuggestions();
    _initTts();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _ytController;
    if (c == null) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _appIsInBackground = true;
      _wasPlayingBeforeBackground =
          c.value.isPlaying ||
          c.value.playerState == PlayerState.playing ||
          c.value.playerState == PlayerState.buffering;
      if (_wasPlayingBeforeBackground) {
        _suppressForegroundPlaybackForBackground();
        _autoStartBackgroundMirror(++_backgroundMirrorRequestId);
      }
      return;
    }
    _appIsInBackground = false;
    _backgroundMirrorRequestId++;
    if (state == AppLifecycleState.resumed && _wasPlayingBeforeBackground) {
      _restoreForegroundPlayback();
    }
  }

  void _suppressForegroundPlaybackForBackground() {
    final controller = _ytController;
    if (controller == null || _foregroundAudioSuppressedForBackground) return;
    _backgroundSyncPosition = controller.value.position;
    debugPrint(
      '[Background] Saved YouTube position: ${_backgroundSyncPosition.inSeconds}s',
    );
    _foregroundAudioSuppressedForBackground = true;
    try {
      controller.mute();
      controller.pause();
    } catch (_) {}
  }

  void _restoreForegroundPlayback() {
    _wasPlayingBeforeBackground = false;
    _isRestoringForeground = true;
    try {
      _ytController?.mute();
      _ytController?.pause();
    } catch (_) {}
    _restoreForegroundPlaybackAsync().whenComplete(() {
      _isRestoringForeground = false;
    });
  }

  Future<void> _restoreForegroundPlaybackAsync() async {
    final mirroredPosition = BackgroundAudioPlayerService.instance.position;
    debugPrint(
      '[Resume] Background player position: ${mirroredPosition.inSeconds}s',
    );
    final stoppedPosition =
        await BackgroundAudioPlayerService.instance.hardStopAndReset();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!mounted) {
      _isRestoringForeground = false;
      return;
    }
    final controller = _ytController;
    if (controller == null) {
      _foregroundAudioSuppressedForBackground = false;
      _backgroundSyncPosition = Duration.zero;
      _isRestoringForeground = false;
      return;
    }
    await _waitForYoutubeControllerReady(controller);
    if (!mounted || controller != _ytController) {
      _isRestoringForeground = false;
      return;
    }
    final resumePosition =
        stoppedPosition > Duration.zero
            ? stoppedPosition
            : mirroredPosition > Duration.zero
            ? mirroredPosition
            : _backgroundSyncPosition;
    debugPrint('[Resume] Seeking YouTube to: ${resumePosition.inSeconds}s');
    if (resumePosition > Duration.zero) {
      controller.seekTo(resumePosition);
      await Future.delayed(const Duration(milliseconds: 150));
    }
    if (!mounted) {
      _isRestoringForeground = false;
      return;
    }
    try {
      controller.unMute();
      controller.play();
    } catch (_) {}
    _applyEmbeddedPlayerVolume();
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    if (!controller.value.isPlaying &&
        controller.value.playerState != PlayerState.playing &&
        controller.value.playerState != PlayerState.buffering) {
      if (resumePosition > Duration.zero) {
        controller.seekTo(resumePosition);
      }
      try {
        controller.unMute();
        controller.play();
      } catch (_) {}
      _applyEmbeddedPlayerVolume();
    }
    _foregroundAudioSuppressedForBackground = false;
    _backgroundSyncPosition = Duration.zero;
    if (_backgroundMirrorFailed) {
      _backgroundMirrorFailed = false;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Background audio needs valid SoundCloud credentials '
            '(set SOUNDCLOUD_CLIENT_ID and SOUNDCLOUD_CLIENT_SECRET in .env).',
          ),
        ),
      );
    }
  }

  Future<void> _waitForYoutubeControllerReady(
    YoutubePlayerController controller,
  ) async {
    if (controller.value.isReady) return;
    final completer = Completer<void>();
    late VoidCallback listener;
    Timer? timeout;
    listener = () {
      if (controller.value.isReady && !completer.isCompleted) {
        completer.complete();
      }
    };
    controller.addListener(listener);
    timeout = Timer(const Duration(seconds: 5), () {
      if (!completer.isCompleted) {
        debugPrint('[YouTube] Controller readiness wait timed out');
        completer.complete();
      }
    });
    try {
      await completer.future;
    } finally {
      timeout.cancel();
      controller.removeListener(listener);
    }
  }

  void _autoStartBackgroundMirror(int requestId) {
    _startBackgroundMirrorFromNowPlaying(auto: true, requestId: requestId);
  }

  Future<void> _startBackgroundMirrorFromNowPlaying({
    required bool auto,
    required int requestId,
  }) async {
    if (_isBackgroundAudioLoading) return;
    if (BackgroundAudioPlayerService.instance.isPlaying) return;
    final now = _nowPlaying;
    if (now == null) return;
    if (now.trackName.trim().isEmpty || now.artistName.trim().isEmpty) return;
    setState(() => _isBackgroundAudioLoading = true);
    if (auto) {
      _backgroundMirrorFailed = false;
    }
    try {
      await BackgroundAudioPlayerService.instance.setLoopEnabled(_isLooping);
      final sc = await _soundcloud.findMirrorStream(
        trackName: now.trackName,
        artistName: now.artistName,
      );
      if (!mounted ||
          !_appIsInBackground ||
          requestId != _backgroundMirrorRequestId) {
        return;
      }
      if (sc != null && sc.confidence >= 0.62) {
        debugPrint(
          '[Background] Starting SoundCloud stream at: ${_backgroundSyncPosition.inSeconds}s',
        );
        await BackgroundAudioPlayerService.instance.playSources(
          sc.streamSources
              .map((source) => (url: source.url, headers: source.headers))
              .toList(),
          _backgroundSyncPosition,
        );
        return;
      }
      if (!auto) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not find a usable SoundCloud background stream.',
            ),
          ),
        );
      }
      if (auto) {
        _backgroundMirrorFailed = true;
      }
    } catch (e) {
      if (!mounted) return;
      if (!auto) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Background audio failed: $e')));
      }
      if (auto) {
        _backgroundMirrorFailed = true;
      }
    } finally {
      if (mounted) setState(() => _isBackgroundAudioLoading = false);
    }
  }

  Future<void> _initTts() async {
    await _tts.init(
      onStateChanged: () {
        if (mounted) setState(() {});
      },
    );
  }

  Future<void> _initVolumeController() async {
    if (kIsWeb) {
      _volumeSystemCap = 1.0;
      return;
    }
    final volumeController = VolumeController.instance;
    volumeController.showSystemUI = false;
    try {
      final cap = await volumeController.getVolume();
      _volumeSystemCap = cap.clamp(0.001, 1.0);
    } catch (_) {
      _volumeSystemCap = 1.0;
      return;
    }
    if (!mounted) return;
    _volumeSubscription = const EventChannel(_volumeEventChannelName)
        .receiveBroadcastStream(<String, dynamic>{_volumeFetchInitialKey: true})
        .listen(
          (dynamic d) {
            if (!mounted) return;
            final systemVol = (d as num).toDouble().clamp(0.0, 1.0);
            setState(() {
              _playerVolume = (systemVol / _volumeSystemCap).clamp(0.0, 1.0);
            });
            _applyEmbeddedPlayerVolume();
          },
          onError: (_) {},
          cancelOnError: false,
        );
  }

  Future<void> _loadSuggestions() async {
    final service = await LocalSuggestionsService.create();
    if (!mounted) return;
    setState(() {
      _suggestions = service;
      _syncRecentFromService();
    });
  }

  void _syncRecentFromService() {
    _recentLines = _suggestions?.getRecentLines() ?? [];
    _recentTracks = _suggestions?.getRecentTracks() ?? [];
    _lightweightService.seedFromRecentTracks(_recentTracks);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _volumeSubscription?.cancel();
    _volumeSubscription = null;
    _lyricController.dispose();
    _ytController?.dispose();
    _tts.dispose();
    super.dispose();
  }

  void _playResult(PlaybackResult result) {
    if (BackgroundAudioPlayerService.instance.isPlaying) {
      unawaited(BackgroundAudioPlayerService.instance.stop());
    }
    _backgroundSyncPosition = Duration.zero;
    _foregroundAudioSuppressedForBackground = false;
    _loopStartPosition = Duration(
      seconds: result.startTimeSeconds < 0 ? 0 : result.startTimeSeconds,
    );
    final oldController = _ytController;
    _ytController = null;
    setState(() {
      _nowPlaying = result;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      oldController?.dispose();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller =
          YouTubePlayerBackgroundHelper.createBackgroundAwareController(
            videoId: result.videoId,
            startSeconds: result.startTimeSeconds,
            autoPlay: true,
            loop: false,
          );
      _attachLoopListener(controller);
      setState(() => _ytController = controller);
      _applyEmbeddedPlayerVolume();
    });
    _lightweightService.cachePlaybackResult(
      result,
      _lyricController.text.trim(),
    );
    _suggestions?.addRecentLine(_lyricController.text.trim());
    _suggestions?.addRecentTrack(
      RecentTrack(
        trackName: result.trackName,
        artistName: result.artistName,
        lyricSnippet: _lyricController.text.trim(),
        videoId: result.videoId,
        startTimeSeconds: result.startTimeSeconds,
      ),
    );
    _suggestions
        ?.addRecentSearch(
          RecentSearch(
            query: _lyricController.text.trim(),
            success: true,
            searchedAtMs: DateTime.now().millisecondsSinceEpoch,
            trackName: result.trackName,
            artistName: result.artistName,
          ),
        )
        .then((_) {
          if (mounted) {
            setState(() {
              _syncRecentFromService();
            });
          }
        });
  }

  Future<void> _startListening() async {
    final available = await _speech.initialize(
      onStatus: (status) {
        if (mounted) setState(() => _isListening = status == 'listening');
      },
      onError: (_) {
        if (mounted) setState(() => _isListening = false);
      },
    );
    if (!mounted) return;
    if (!available) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Speech not available')));
      return;
    }
    await _speech.listen(
      onResult: (result) {
        if (mounted && result.finalResult) {
          _lyricController.text = result.recognizedWords;
          _lyricController.selection = TextSelection.collapsed(
            offset: _lyricController.text.length,
          );
        }
      },
      listenFor: const Duration(seconds: 15),
      pauseFor: const Duration(seconds: 3),
      listenOptions: SpeechListenOptions(partialResults: true),
    );
  }

  Future<void> _stopListening() async {
    await _speech.stop();
    if (mounted) setState(() => _isListening = false);
  }

  Future<void> _toggleSpeakLine() async {
    if (_isLoading) return;
    final text = _lyricController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Type a line first to speak it')),
      );
      return;
    }
    if (_isListening) {
      await _stopListening();
    }
    try {
      if (_tts.isSpeaking) {
        await _tts.stop();
      } else {
        await _tts.speak(text);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('TTS error: $e')));
    }
  }

  void _showQuotaExceededDialog() {
    final status = _quotaMonitor.getStatus();
    final timeUntilReset = status.nextResetTime.difference(DateTime.now());
    final hours = timeUntilReset.inHours;
    final minutes = timeUntilReset.inMinutes % 60;
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(
                Icons.warning_amber,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(width: 8),
              const Text('YouTube API Quota Exceeded'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'The daily YouTube API search limit has been reached. Please try again later.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.errorContainer.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.schedule,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Time until reset:',
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '$hours hours $minutes minutes',
                      style: Theme.of(
                        context,
                      ).textTheme.headlineSmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'Resets at: ${status.nextResetTime.hour.toString().padLeft(2, '0')}:${status.nextResetTime.minute.toString().padLeft(2, '0')}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Usage: ${status.percentageUsed.toStringAsFixed(1)}% of daily quota',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Got it'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _onSearch() async {
    if (_isLoading) return;
    final query = _lyricController.text.trim();
    if (query.isEmpty) return;
    setState(() => _isLoading = true);
    try {
      List<PlaybackOption> options;
      if (_isQuotaSavingMode) {
        final lightweightResults = await _lightweightService
            .searchSingleLineLyrics(query, cacheOnly: true);
        options =
            lightweightResults
                .map(
                  (result) => PlaybackOption(
                    result: PlaybackResult(
                      videoId: result.videoId,
                      startTimeSeconds: result.startTimeSeconds,
                      trackName: result.trackName,
                      artistName: result.artistName,
                    ),
                    confidence: result.confidence,
                    source: result.source,
                  ),
                )
                .toList();
      } else {
        options = await _playbackService.resolveCandidates(query, limit: 5);
      }
      if (!mounted) return;
      if (options.isEmpty) {
        await _suggestions?.addRecentSearch(
          RecentSearch(
            query: query,
            success: false,
            searchedAtMs: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        if (!mounted) return;
        setState(_syncRecentFromService);
        final message =
            _isQuotaSavingMode
                ? 'No song found in cache. Try normal mode or different lyrics.'
                : 'No song found for this line. Try another.';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
        return;
      }
      final selected = await _pickCandidateFromOptions(options);
      if (!mounted || selected == null) return;
      _playResult(selected.result);
    } catch (e) {
      if (mounted) {
        if (e.toString().contains('403') ||
            e.toString().contains('quota exceeded')) {
          _showQuotaExceededDialog();
          setState(() => _isQuotaSavingMode = true);
        } else {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Error: $e')));
        }
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _openHostParty() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const HostPartyScreen()));
  }

  void _openJoinParty() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => JoinViaLinkScreen(onBack: () => Navigator.of(context).pop()),
      ),
    );
  }

  void _openGenerateSong() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => GenerateSongScreen()));
  }

  void _openDownloads() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SavedVoiceSongsScreen()));
  }

  Future<void> _openGenerateSongBySlide() async {
    await HapticFeedback.mediumImpact();
    if (!mounted) return;
    _openGenerateSong();
  }

  void _togglePrimaryPlayback() {
    if (_isLoading || _isRestoringForeground) return;
    final controller = _ytController;
    if (controller == null) {
      _onSearch();
      return;
    }
    if (controller.value.isPlaying) {
      controller.pause();
    } else {
      controller.play();
    }
  }

  void _toggleLooping() {
    final next = !_isLooping;
    setState(() => _isLooping = next);
    if (BackgroundAudioPlayerService.instance.isPlaying) {
      unawaited(BackgroundAudioPlayerService.instance.setLoopEnabled(next));
    }
  }

  void _attachLoopListener(YoutubePlayerController controller) {
    controller.addListener(() {
      if (!_isLooping || _isHandlingLoopRestart || _isRestoringForeground) {
        return;
      }
      final playerState = controller.value.playerState;
      if (playerState == PlayerState.ended) {
        _isHandlingLoopRestart = true;
        Future.microtask(() async {
          try {
            if (_isRestoringForeground) return;
            final videoId = controller.metadata.videoId;
            if (videoId.isNotEmpty) {
              controller.load(videoId, startAt: 0);
            } else {
              controller.seekTo(Duration.zero);
            }
            await Future.delayed(const Duration(milliseconds: 100));
            if (!mounted || _isRestoringForeground) {
              _isHandlingLoopRestart = false;
              return;
            }
            controller.play();
            await Future.delayed(const Duration(milliseconds: 50));
            if (_isRestoringForeground) return;
            _applyEmbeddedPlayerVolume();
            await Future.delayed(const Duration(milliseconds: 100));
          } catch (e) {
            debugPrint('Loop restart error: $e');
          } finally {
            _isHandlingLoopRestart = false;
          }
        });
      }
    });
  }

  void _seekRelative(int seconds) {
    final controller = _ytController;
    if (controller == null) return;
    final currentMs = controller.value.position.inMilliseconds;
    final durationMs = controller.metadata.duration.inMilliseconds;
    final targetMs = currentMs + (seconds * 1000);
    final clampedMs =
        durationMs > 0 ? targetMs.clamp(0, durationMs) : math.max(0, targetMs);
    controller.seekTo(Duration(milliseconds: clampedMs));
  }

  void _applyEmbeddedPlayerVolume() {
    final controller = _ytController;
    if (controller == null) return;
    if (!controller.value.isReady) return;
    final volume = (_playerVolume * 100).round().clamp(0, 100);
    controller.setVolume(volume);
    if (_isRestoringForeground || volume == 0) {
      controller.mute();
    } else {
      controller.unMute();
    }
  }

  void _seekToFraction(double fraction) {
    final controller = _ytController;
    if (controller == null) return;
    final duration = controller.metadata.duration;
    if (duration <= Duration.zero) return;
    final clamped = fraction.clamp(0.0, 1.0);
    controller.seekTo(
      Duration(milliseconds: (duration.inMilliseconds * clamped).round()),
    );
  }

  Future<PlaybackOption?> _pickCandidateFromOptions(
    List<PlaybackOption> options,
  ) async {
    if (options.length == 1) return options.first;
    return showModalBottomSheet<PlaybackOption>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder:
          (ctx) => Theme(
            data: lyricScreenTheme(ctx),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Container(
                  decoration: BoxDecoration(
                    color: LyricScreenPalette.background,
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(
                      color: LyricScreenPalette.outline.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 10),
                      Container(
                        width: 48,
                        height: 5,
                        decoration: BoxDecoration(
                          color: LyricScreenPalette.outline,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Choose your song',
                              style: Theme.of(ctx).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w900),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'We found multiple strong matches. Pick the one that feels right and jump straight in.',
                              style: Theme.of(
                                ctx,
                              ).textTheme.bodyMedium?.copyWith(
                                color:
                                    Theme.of(ctx).colorScheme.onSurfaceVariant,
                                height: 1.45,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Flexible(
                        child: ListView.separated(
                          shrinkWrap: true,
                          padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                          itemCount: options.length,
                          separatorBuilder:
                              (_, __) => const SizedBox(height: 10),
                          itemBuilder: (_, i) {
                            final option = options[i];
                            final result = option.result;
                            final confidencePct =
                                (option.confidence * 100).clamp(0, 100).round();

                            return Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onTap: () => Navigator.of(ctx).pop(option),
                                borderRadius: BorderRadius.circular(22),
                                child: Container(
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: LyricScreenPalette.surface,
                                    borderRadius: BorderRadius.circular(22),
                                    border: Border.all(
                                      color: LyricScreenPalette.outline
                                          .withValues(alpha: 0.45),
                                    ),
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      // Modified: Circular image with fallback
                                      _CircularThumbnail(
                                        imageUrl:
                                            'https://img.youtube.com/vi/${result.videoId}/0.jpg',
                                        size: 56,
                                        fallbackText: 'LyricQSK',
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              result.trackName,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(
                                                ctx,
                                              ).textTheme.titleSmall?.copyWith(
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              result.artistName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(
                                                ctx,
                                              ).textTheme.bodySmall?.copyWith(
                                                color:
                                                    Theme.of(ctx)
                                                        .colorScheme
                                                        .onSurfaceVariant,
                                              ),
                                            ),
                                            const SizedBox(height: 10),
                                            Wrap(
                                              spacing: 8,
                                              runSpacing: 8,
                                              children: [
                                                LyricTag(
                                                  label:
                                                      '${result.startTimeSeconds}s',
                                                  icon: Icons.timer_rounded,
                                                ),
                                                LyricTag(
                                                  label: option.source,
                                                  icon: Icons.tune_rounded,
                                                ),
                                                LyricTag(
                                                  label: '$confidencePct%',
                                                  icon:
                                                      Icons.auto_graph_rounded,
                                                  highlighted:
                                                      confidencePct >= 80,
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Container(
                                        width: 34,
                                        height: 34,
                                        decoration: BoxDecoration(
                                          color: LyricScreenPalette.accentSoft,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: const Icon(
                                          Icons.chevron_right_rounded,
                                          color: LyricScreenPalette.ink,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                        child: Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => Navigator.of(ctx).pop(),
                                child: const Text('Cancel'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final screenWidth = mq.size.width;
    final screenHeight = mq.size.height;
    final isCompact = screenWidth < 600;
    final hPad = isCompact ? screenWidth * 0.05 : screenWidth * 0.08;
    final vGap = screenHeight < 700 ? 8.0 : 12.0;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F3EF),
      bottomNavigationBar: SafeArea(
        minimum: EdgeInsets.fromLTRB(hPad, 8, hPad, 12),
        child: SizedBox(
          height: screenHeight < 700 ? 60 : 60,
          child: _GenerateSongSliderCard(
            compact: isCompact,
            onCompleted: _openGenerateSongBySlide,
          ),
        ),
      ),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.translucent,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final availH = constraints.maxHeight;
              final availW = constraints.maxWidth;
              return Stack(
                children: [
                  // 🎵  Hidden YouTube player (off-screen, 1% opacity) 🎵 🎵 🎵  🎵
                  if (_ytController != null)
                    Positioned(
                      left: hPad,
                      right: hPad,
                      top: 0,
                      child: IgnorePointer(
                        child: Opacity(
                          opacity: 0.01,
                          child: AspectRatio(
                            aspectRatio: 16 / 9,
                            child: YoutubePlayer(
                              key: ValueKey(
                                _nowPlaying?.videoId ?? 'yt_player',
                              ),
                              controller: _ytController!,
                              showVideoProgressIndicator: false,
                              onReady: _applyEmbeddedPlayerVolume,
                            ),
                          ),
                        ),
                      ),
                    ),
                  // 🎵  Main non-scrollable column 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵
                  Padding(
                    padding: EdgeInsets.fromLTRB(hPad, vGap, hPad, vGap),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _SearchConsoleCard(
                          lyricController: _lyricController,
                          isLoading: _isLoading,
                          isListening: _isListening,
                          isSpeaking: _tts.isSpeaking,
                          isQuotaSavingMode: _isQuotaSavingMode,
                          recentLines: _recentLines,
                          availableWidth: availW - hPad * 2,
                          isCompact: isCompact,
                          screenHeight: availH,
                          onSearch: _onSearch,
                          onToggleSpeak: _toggleSpeakLine,
                          onToggleListen: () {
                            if (_isListening) {
                              _stopListening();
                            } else {
                              _startListening();
                            }
                          },
                          onToggleQuotaMode:
                              (value) =>
                                  setState(() => _isQuotaSavingMode = value),
                          onOpenJoinParty: _openJoinParty,
                          onOpenHostParty: _openHostParty,
                          onOpenDownloads: _openDownloads,
                          onSelectRecentLine: (line) {
                            _lyricController.text = line;
                            _lyricController.selection =
                                TextSelection.collapsed(offset: line.length);
                          },
                        ),
                        SizedBox(height: vGap),
                        Expanded(
                          child: _TurntablePlayerCard(
                            controller: _ytController,
                            nowPlaying: _nowPlaying,
                            savedCount: _recentLines.length,
                            isLoading: _isLoading,
                            isLooping: _isLooping,
                            onToggleLoop: _toggleLooping,
                            onSeekBackward: () => _seekRelative(-10),
                            onPlayPause: _togglePrimaryPlayback,
                            onSeekForward: () => _seekRelative(10),
                            onSeekToFraction: _seekToFraction,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

// 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵
// _TurntablePlayerCard
// 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵
class _TurntablePlayerCard extends StatelessWidget {
  const _TurntablePlayerCard({
    required this.controller,
    required this.nowPlaying,
    required this.savedCount,
    required this.isLoading,
    required this.isLooping,
    required this.onToggleLoop,
    required this.onSeekBackward,
    required this.onPlayPause,
    required this.onSeekForward,
    required this.onSeekToFraction,
  });

  final YoutubePlayerController? controller;
  final PlaybackResult? nowPlaying;
  final int savedCount;
  final bool isLoading;
  final bool isLooping;
  final VoidCallback onToggleLoop;
  final VoidCallback onSeekBackward;
  final VoidCallback onPlayPause;
  final VoidCallback onSeekForward;
  final ValueChanged<double> onSeekToFraction;

  static const List<double> _waveformHeights = [
    10,
    14,
    18,
    24,
    16,
    12,
    20,
    28,
    18,
    12,
    26,
    14,
    22,
    32,
    16,
    12,
    18,
    26,
    30,
    16,
    12,
    18,
    22,
    26,
    18,
    14,
    16,
    20,
    14,
    12,
  ];

  @override
  Widget build(BuildContext context) {
    final musicController = controller;
    final basePosition =
        musicController?.value.position ??
        const Duration(minutes: 1, seconds: 54);
    final baseDuration =
        musicController != null &&
                musicController.metadata.duration > Duration.zero
            ? musicController.metadata.duration
            : const Duration(minutes: 3, seconds: 35);
    final progress =
        baseDuration.inMilliseconds <= 0
            ? 0.54
            : (basePosition.inMilliseconds / baseDuration.inMilliseconds).clamp(
              0.0,
              1.0,
            );
    final title = nowPlaying?.trackName ?? 'The Suffering';
    final artist = nowPlaying?.artistName ?? 'LyricQSK';
    final badgeText = nowPlaying == null ? 'Now Playing' : 'Now Playing';
    final trackCount = savedCount.toString().padLeft(3, '0');

    Widget buildCard(bool isPlaying, Duration position, Duration duration) {
      final playbackProgress =
          duration.inMilliseconds <= 0
              ? progress
              : (position.inMilliseconds / duration.inMilliseconds).clamp(
                0.0,
                1.0,
              );
      // Calculate rotation angle - full rotation every 12 seconds of playback time
      final rotationAngle =
          duration.inMilliseconds == 0
              ? 0.0
              : (position.inMilliseconds / 12000) * math.pi * 2;
      return LayoutBuilder(
        builder: (context, constraints) {
          final cardW = constraints.maxWidth;
          final titleFontSize = (cardW * 0.065).clamp(18.0, 28.0);
          final clockFontSize = (cardW * 0.048).clamp(14.0, 22.0);
          final playBtnSize = (cardW * 0.17).clamp(52.0, 72.0);
          return Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F3EF),
              borderRadius: BorderRadius.circular(28),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color(0xFFD7D7D7),
                          Color(0xFFB7B7B7),
                          Color(0xFF9C9C9C),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(26),
                      border: Border.all(
                        color: const Color(0xFF858585),
                        width: 1.3,
                      ),
                    ),
                    child: Stack(
                      children: [
                        const Positioned(
                          top: 10,
                          left: 10,
                          child: _DeckScrew(),
                        ),
                        const Positioned(
                          top: 10,
                          right: 10,
                          child: _DeckScrew(),
                        ),
                        const Positioned(
                          bottom: 10,
                          left: 10,
                          child: _DeckScrew(),
                        ),
                        const Positioned(
                          bottom: 10,
                          right: 10,
                          child: _DeckScrew(),
                        ),
                        Positioned(
                          top: 18,
                          left: 18,
                          child: _DeckLoopButton(
                            isLooping: isLooping,
                            onPressed: controller == null ? null : onToggleLoop,
                          ),
                        ),
                        Positioned(
                          left: 15,
                          top: 14,
                          bottom: 14,
                          right: 42,
                          child: Center(
                            child: AspectRatio(
                              aspectRatio: 1,
                              child: LayoutBuilder(
                                builder: (context, vinylConstraints) {
                                  final vinylDiameter =
                                      vinylConstraints.maxWidth + 100;
                                  final labelSize = vinylDiameter * 0.27;
                                  final labelFontSize = (vinylDiameter * 0.032)
                                      .clamp(8.0, 11.0);
                                  return DecoratedBox(
                                    decoration: const BoxDecoration(
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: Color(0x33000000),
                                          blurRadius: 18,
                                          offset: Offset(0, 10),
                                        ),
                                      ],
                                    ),
                                    child: Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        Transform.rotate(
                                          angle: rotationAngle,
                                          child: const CustomPaint(
                                            painter: _VinylPainter(),
                                            child: SizedBox.expand(),
                                          ),
                                        ),
                                        // Center label with image - rotates at same speed as vinyl
                                        Transform.rotate(
                                          angle: rotationAngle,
                                          child: Container(
                                            width: labelSize,
                                            height: labelSize,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              gradient: const LinearGradient(
                                                begin: Alignment.topCenter,
                                                end: Alignment.bottomCenter,
                                                colors: [
                                                  Color(0xFFF9F8F4),
                                                  Color(0xFFDBD8D2),
                                                ],
                                              ),
                                            ),
                                            child: ClipOval(
                                              child:
                                                  nowPlaying != null
                                                      ? _CircularThumbnail(
                                                        imageUrl:
                                                            'https://img.youtube.com/vi/${nowPlaying!.videoId}/0.jpg',
                                                        size: labelSize,
                                                        fallbackText:
                                                            'LYRICQSK',
                                                      )
                                                      : Transform.rotate(
                                                        angle:
                                                            math.pi, // 180 degrees rotation
                                                        child: Center(
                                                          child: Text(
                                                            artist.length > 12
                                                                ? artist
                                                                    .substring(
                                                                      0,
                                                                      12,
                                                                    )
                                                                    .toUpperCase()
                                                                : artist
                                                                    .toUpperCase(),
                                                            textAlign:
                                                                TextAlign
                                                                    .center,
                                                            style: TextStyle(
                                                              fontFamily:
                                                                  'Inter',
                                                              fontSize:
                                                                  labelFontSize,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w700,
                                                              color:
                                                                  const Color(
                                                                    0xFF6B6B6B,
                                                                  ),
                                                              letterSpacing:
                                                                  0.6,
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 260,
                          bottom: 45,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 400),
                            curve: Curves.easeInOut,
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color:
                                  isPlaying
                                      ? const Color(0xFFFF2040)
                                      : const Color(0xFF661020),
                              shape: BoxShape.circle,
                              boxShadow:
                                  isPlaying
                                      ? const [
                                        BoxShadow(
                                          color: Color(0xCCFF2040),
                                          blurRadius: 10,
                                          spreadRadius: 3,
                                        ),
                                        BoxShadow(
                                          color: Color(0x66FF2040),
                                          blurRadius: 20,
                                          spreadRadius: 6,
                                        ),
                                      ]
                                      : const [],
                            ),
                          ),
                        ),
                        const Positioned(
                          left: 18,
                          bottom: 22,
                          child: _DeckKnob(size: 28),
                        ),
                        const Positioned(
                          right: 22,
                          bottom: 20,
                          child: _DeckKnob(size: 24),
                        ),
                        Positioned(
                          right: 12,
                          top: 20,
                          child: _ToneArm(
                            isPlaying: isPlaying,
                            progress: playbackProgress,
                            onTap: isLoading ? null : onPlayPause,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: titleFontSize,
                          fontWeight: FontWeight.w900,
                          color: Colors.black,
                          height: 1.05,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEDEAE4),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.add_box_rounded,
                            size: 16,
                            color: Colors.black,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            trackCount,
                            style: const TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              color: Colors.black,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF171717),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        badgeText,
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF575757),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Text(
                      _formatClock(position),
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: clockFontSize,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF1C1C1C),
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _ScrubbableWaveform(
                        heights: _waveformHeights,
                        progress: playbackProgress,
                        onSeek: controller == null ? null : onSeekToFraction,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _formatClock(duration),
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: clockFontSize,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF1C1C1C),
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _SeekButton(
                      seconds: -10,
                      onPressed: controller == null ? null : onSeekBackward,
                    ),
                    Container(
                      width: playBtnSize,
                      height: playBtnSize,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black,
                      ),
                      child: IconButton(
                        onPressed: isLoading ? null : onPlayPause,
                        icon:
                            isLoading
                                ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.4,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.white,
                                    ),
                                  ),
                                )
                                : Icon(
                                  isPlaying
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow,
                                  color: Colors.white,
                                  size: playBtnSize * 0.47,
                                ),
                      ),
                    ),
                    _SeekButton(
                      seconds: 10,
                      onPressed: controller == null ? null : onSeekForward,
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      );
    }

    if (musicController == null) {
      return buildCard(false, basePosition, baseDuration);
    }
    return AnimatedBuilder(
      animation: musicController,
      builder: (context, _) {
        final position = musicController.value.position;
        final duration =
            musicController.metadata.duration > Duration.zero
                ? musicController.metadata.duration
                : baseDuration;
        return buildCard(musicController.value.isPlaying, position, duration);
      },
    );
  }

  static String _formatClock(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final minutes = (totalSeconds ~/ 60).toString();
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

// 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵  🎵 🎵  🎵 🎵
// _SearchConsoleCard
// 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵  🎵  🎵  🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵
class _SearchConsoleCard extends StatefulWidget {
  const _SearchConsoleCard({
    required this.lyricController,
    required this.isLoading,
    required this.isListening,
    required this.isSpeaking,
    required this.isQuotaSavingMode,
    required this.recentLines,
    required this.availableWidth,
    required this.isCompact,
    required this.screenHeight,
    required this.onSearch,
    required this.onToggleSpeak,
    required this.onToggleListen,
    required this.onToggleQuotaMode,
    required this.onOpenJoinParty,
    required this.onOpenHostParty,
    required this.onOpenDownloads,
    required this.onSelectRecentLine,
  });

  final TextEditingController lyricController;
  final bool isLoading;
  final bool isListening;
  final bool isSpeaking;
  final bool isQuotaSavingMode;
  final List<String> recentLines;
  final double availableWidth;
  final bool isCompact;
  final double screenHeight;
  final VoidCallback onSearch;
  final VoidCallback onToggleSpeak;
  final VoidCallback onToggleListen;
  final ValueChanged<bool> onToggleQuotaMode;
  final VoidCallback onOpenJoinParty;
  final VoidCallback onOpenHostParty;
  final VoidCallback onOpenDownloads;
  final ValueChanged<String> onSelectRecentLine;

  @override
  State<_SearchConsoleCard> createState() => _SearchConsoleCardState();
}

class _SearchConsoleCardState extends State<_SearchConsoleCard> {
  bool _showDropdown = false;
  final FocusNode _focusNode = FocusNode();
  OverlayEntry? _overlayEntry;
  final LayerLink _layerLink = LayerLink();

  List<String> get _filteredLines {
    final query = widget.lyricController.text.trim().toLowerCase();
    if (query.isEmpty) return widget.recentLines;
    return widget.recentLines
        .where((l) => l.toLowerCase().contains(query))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (_focusNode.hasFocus && widget.recentLines.isNotEmpty) {
      _showOverlay();
    } else if (!_focusNode.hasFocus) {
      Future.delayed(const Duration(milliseconds: 150), _hideOverlay);
    }
  }

  void _showOverlay() {
    if (_overlayEntry != null) {
      _overlayEntry!.markNeedsBuild();
      return;
    }
    _overlayEntry = _buildOverlayEntry();
    Overlay.of(context).insert(_overlayEntry!);
    setState(() => _showDropdown = true);
  }

  void _hideOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    if (mounted) setState(() => _showDropdown = false);
  }

  void _refreshOverlay() {
    _overlayEntry?.markNeedsBuild();
  }

  OverlayEntry _buildOverlayEntry() {
    return OverlayEntry(
      builder: (context) {
        final lines = _filteredLines;
        if (lines.isEmpty) return const SizedBox.shrink();
        return Positioned(
          width: widget.availableWidth,
          child: CompositedTransformFollower(
            link: _layerLink,
            showWhenUnlinked: false,
            followerAnchor: Alignment.topLeft,
            targetAnchor: Alignment.bottomLeft,
            offset: const Offset(0, 2),
            child: Material(
              color: Colors.transparent,
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFEDE8E0),
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(22),
                    bottomRight: Radius.circular(22),
                  ),
                  border: Border.all(color: const Color(0xFFD8D4CC), width: 1),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x18000000),
                      blurRadius: 12,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(22),
                    bottomRight: Radius.circular(22),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                    child: SizedBox(
                      height: 55,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        itemCount: lines.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (_, i) {
                          final line = lines[i];
                          return GestureDetector(
                            onTap: () {
                              widget.onSelectRecentLine(line);
                              _hideOverlay();
                              _focusNode.unfocus();
                            },
                            child: Container(
                              constraints: const BoxConstraints(
                                minWidth: 100,
                                maxWidth: 100,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFD8D4CC),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    line,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontFamily: 'Inter',
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.black,
                                      height: 1.3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _hideOverlay();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final titleFontSize = (widget.availableWidth * 0.058).clamp(16.0, 24.0);
    final subtitleFontSize = (widget.availableWidth * 0.034).clamp(11.0, 14.0);
    final showSubtitle = widget.screenHeight > 680;
    final btnHeight = widget.screenHeight < 700 ? 46.0 : 52.0;
    return Container(
      padding: EdgeInsets.only(bottom: widget.screenHeight < 700 ? 12 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  'Search with one lyric line',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: titleFontSize,
                    fontWeight: FontWeight.w900,
                    color: Colors.black,
                    height: 1.05,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _HeaderQuickMenu(
                compact: widget.isCompact,
                onOpenHostParty: widget.onOpenHostParty,
                onOpenJoinParty: widget.onOpenJoinParty,
                onOpenDownloads: widget.onOpenDownloads,
              ),
            ],
          ),
          if (showSubtitle) ...[
            const SizedBox(height: 4),
            Text(
              'Drop a lyric, use voice, and jump straight into playback.',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: subtitleFontSize,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF666666),
              ),
            ),
          ],
          SizedBox(height: widget.screenHeight < 700 ? 8 : 12),
          CompositedTransformTarget(
            link: _layerLink,
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF8F4EE),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color:
                      widget.isListening
                          ? const Color(0xFF11F08A)
                          : const Color(0xFFD8D4CC),
                  width: 1.5,
                ),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 14),
                  const Icon(
                    Icons.search_rounded,
                    color: Color(0xFF555555),
                    size: 20,
                  ),
                  Expanded(
                    child: Theme(
                      data: Theme.of(context).copyWith(
                        textSelectionTheme: const TextSelectionThemeData(
                          cursorColor: Colors.black,
                          selectionColor: Color(0x4411F08A),
                          selectionHandleColor: Colors.black,
                        ),
                      ),
                      child: TextField(
                        controller: widget.lyricController,
                        focusNode: _focusNode,
                        maxLines: 1,
                        enabled: !widget.isLoading,
                        cursorColor: Colors.black,
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Colors.black,
                        ),
                        decoration: const InputDecoration(
                          hintText: 'e.g. Hello from the other side',
                          hintStyle: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFFAAAAAA),
                          ),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: true,
                          fillColor: Colors.transparent,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 16,
                          ),
                        ),
                        onSubmitted: (_) => widget.onSearch(),
                        onChanged: (_) {
                          if (widget.recentLines.isEmpty) return;
                          if (_overlayEntry == null) {
                            _showOverlay();
                          } else {
                            _refreshOverlay();
                          }
                        },
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: widget.onToggleListen,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.only(right: 8),
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color:
                            widget.isListening
                                ? const Color(0xFF11F08A)
                                : const Color(0xFFD8D4CC),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        widget.isListening
                            ? Icons.mic_rounded
                            : Icons.mic_none_rounded,
                        color:
                            widget.isListening
                                ? Colors.black
                                : const Color(0xFF555555),
                        size: 18,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: widget.screenHeight < 700 ? 8 : 12),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: btnHeight,
                  child: FilledButton.icon(
                    onPressed: widget.isLoading ? null : widget.onSearch,
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.black,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: const Color(0xFF333333),
                      disabledForegroundColor: const Color(0xFF888888),
                      elevation: 0,
                      shadowColor: Colors.transparent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(btnHeight / 2),
                      ),
                    ),
                    icon:
                        widget.isLoading
                            ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.white,
                                ),
                              ),
                            )
                            : const Icon(Icons.play_arrow_rounded),
                    label: Text(
                      widget.isLoading ? 'Finding…' : 'Find & play',
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap:
                    () => widget.onToggleQuotaMode(!widget.isQuotaSavingMode),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  height: btnHeight,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color:
                        widget.isQuotaSavingMode
                            ? Colors.black
                            : const Color(0xFFE8E3DC),
                    borderRadius: BorderRadius.circular(btnHeight / 2),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.eco_rounded,
                        size: 17,
                        color:
                            widget.isQuotaSavingMode
                                ? const Color(0xFF11F08A)
                                : const Color(0xFF666666),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Eco',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color:
                              widget.isQuotaSavingMode
                                  ? Colors.white
                                  : const Color(0xFF444444),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// New widget: Circular thumbnail with fallback
class _CircularThumbnail extends StatelessWidget {
  const _CircularThumbnail({
    required this.imageUrl,
    required this.size,
    required this.fallbackText,
  });

  final String imageUrl;
  final double size;
  final String fallbackText;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: Image.network(
          imageUrl,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) {
            return Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: const Color(0xFFD8D4CC),
                borderRadius: BorderRadius.circular(size / 2),
              ),
              child: Center(
                child: Text(
                  fallbackText.length > 6
                      ? fallbackText.substring(0, 6)
                      : fallbackText,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: size * 0.2,
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF6B6B6B),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// 🎵 🎵 🎵 🎵 🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵  🎵 🎵
// Small reusable deck widgets
// 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵  🎵 🎵  🎵 🎵 🎵 🎵 🎵 🎵  🎵  🎵 🎵
class _DeckScrew extends StatelessWidget {
  const _DeckScrew();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: const Color(0xFF666666),
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFFAFAFAF), width: 1.2),
      ),
    );
  }
}

class _DeckKnob extends StatelessWidget {
  const _DeckKnob({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFE9E9E9), Color(0xFF8B8B8B)],
        ),
        border: Border.all(color: const Color(0xFF565656), width: 1.4),
      ),
    );
  }
}

class _DeckLoopButton extends StatelessWidget {
  const _DeckLoopButton({required this.isLooping, required this.onPressed});

  final bool isLooping;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFE2E2E2), Color(0xFFC4C4C4)],
            ),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF9A9A9A), width: 1.2),
            boxShadow: const [
              BoxShadow(
                color: Color(0x22000000),
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Icon(
            isLooping ? Icons.repeat_one_rounded : Icons.repeat_rounded,
            size: 18,
            color:
                isLooping ? const Color(0xFF111111) : const Color(0xFF4E4E4E),
          ),
        ),
      ),
    );
  }
}

class _ToneArm extends StatelessWidget {
  const _ToneArm({
    required this.isPlaying,
    required this.progress,
    required this.onTap,
  });

  final bool isPlaying;
  final double progress;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final angle = isPlaying ? (0.35 + (progress * 0.22)) : -0.05;
    return SizedBox(
      width: 110,
      height: 190,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          children: [
            Positioned(
              top: 0,
              right: 22,
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFFF2F2F2), Color(0xFF9D9D9D)],
                  ),
                  border: Border.all(
                    color: const Color(0xFF6B6B6B),
                    width: 1.4,
                  ),
                ),
                child: Center(
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFFD8D8D8),
                      border: Border.all(
                        color: const Color(0xFF818181),
                        width: 1.2,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 18,
              right: 24,
              child: AnimatedRotation(
                turns: angle / (2 * math.pi),
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                alignment: Alignment.topCenter,
                child: Column(
                  children: [
                    Container(
                      width: 8,
                      height: 112,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0xFFF3F3F3), Color(0xFF9F9F9F)],
                        ),
                        borderRadius: BorderRadius.circular(99),
                        border: Border.all(
                          color: const Color(0xFF707070),
                          width: 1,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      width: 22,
                      height: 34,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF4F4F4),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: const Color(0xFF707070),
                          width: 1,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              top: 12,
              right: 0,
              child: Container(
                width: 16,
                height: 30,
                decoration: BoxDecoration(
                  color: const Color(0xFFB3B3B3),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF707070), width: 1),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScrubbableWaveform extends StatelessWidget {
  const _ScrubbableWaveform({
    required this.heights,
    required this.progress,
    required this.onSeek,
  });

  final List<double> heights;
  final double progress;
  final ValueChanged<double>? onSeek;

  void _handleSeek(Offset localPosition, double width) {
    if (onSeek == null || width <= 0) return;
    onSeek!((localPosition.dx / width).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => _handleSeek(details.localPosition, width),
          onHorizontalDragStart:
              (details) => _handleSeek(details.localPosition, width),
          onHorizontalDragUpdate:
              (details) => _handleSeek(details.localPosition, width),
          child: SizedBox(
            height: 32,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: List.generate(heights.length, (index) {
                final barProgress = index / (heights.length - 1);
                final isActive = barProgress <= progress;
                return Expanded(
                  child: Align(
                    alignment: Alignment.center,
                    child: Container(
                      width: 4,
                      height: heights[index],
                      decoration: BoxDecoration(
                        color:
                            isActive
                                ? const Color(0xFF141414)
                                : const Color(0xFFD6D6D6),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        );
      },
    );
  }
}

// 🎵 🎵 🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵
// _GenerateSongSliderCard - Modified to only proceed when slid the whole way
// 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵
class _GenerateSongSliderCard extends StatefulWidget {
  const _GenerateSongSliderCard({
    required this.compact,
    required this.onCompleted,
  });

  final bool compact;
  final Future<void> Function() onCompleted;

  @override
  State<_GenerateSongSliderCard> createState() =>
      _GenerateSongSliderCardState();
}

class _GenerateSongSliderCardState extends State<_GenerateSongSliderCard>
    with SingleTickerProviderStateMixin {
  static const double _handleSize = 50;
  static const double _trackPadding = 6;
  static const double _completeThreshold =
      0.99; // Changed to 0.99 for full slide
  double _progress = 0;
  bool _isSubmitting = false;
  bool _isDragging = false;
  late AnimationController _shimmerController;

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      duration: const Duration(milliseconds: 3800),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

  double _maxTravel(BoxConstraints c) =>
      (c.maxWidth - _handleSize - _trackPadding * 2).clamp(
        0.0,
        double.infinity,
      );

  void _updateProgress(Offset local, BoxConstraints c) {
    if (_isSubmitting) return;
    final t = ((local.dx - _trackPadding - _handleSize / 2) / _maxTravel(c))
        .clamp(0.0, 1.0);
    if (t == _progress) return;
    setState(() {
      _progress = t;
      _isDragging = t > 0;
    });
  }

  Future<void> _onDragEnd() async {
    setState(() => _isDragging = false);
    if (_isSubmitting) return;
    // Only proceed if slid to completion (full width)
    if (_progress >= _completeThreshold) {
      setState(() {
        _progress = 1;
        _isSubmitting = true;
      });
      try {
        await widget.onCompleted();
      } finally {
        if (mounted)
          setState(() {
            _isSubmitting = false;
            _progress = 0;
          });
      }
    } else {
      // Reset progress if not fully slid
      setState(() => _progress = 0);
    }
  }

  BoxDecoration _buildTrackDecoration() => BoxDecoration(
    color: const Color(0xFF1E1E1E),
    borderRadius: BorderRadius.circular(22),
    border: Border.all(
      color: _isDragging ? const Color(0xFF11F08A) : const Color(0xFF3A3A3A),
      width: _isDragging ? 1.5 : 1,
    ),
  );

  Widget _buildShimmer(BoxConstraints c) {
    return Positioned.fill(
      child: IgnorePointer(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: AnimatedBuilder(
            animation: _shimmerController,
            builder: (_, __) {
              final bandW = c.maxWidth * 0.30;
              final x =
                  -bandW + (_shimmerController.value * (c.maxWidth + bandW));
              return CustomPaint(
                painter: _ShimmerPainter(x: x, bandWidth: bandW),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildHandle(double knobOffset) {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOut,
      left: _trackPadding + knobOffset,
      top: _trackPadding,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: _handleSize,
        height: _handleSize,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors:
                _isDragging
                    ? [const Color(0xFF11F08A), const Color(0xFF0CC878)]
                    : [const Color(0xFF383838), const Color(0xFF262626)],
          ),
          borderRadius: BorderRadius.circular(17),
          border: Border.all(
            color:
                _isDragging
                    ? Colors.white.withValues(alpha: 0.45)
                    : const Color(0xFF565656),
          ),
          boxShadow: [
            BoxShadow(
              color:
                  _isDragging
                      ? const Color(0xFF11F08A).withValues(alpha: 0.35)
                      : Colors.black.withValues(alpha: 0.4),
              blurRadius: _isDragging ? 16 : 8,
              offset: Offset(0, _isDragging ? 4 : 2),
            ),
          ],
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child:
              _isSubmitting
                  ? const SizedBox(
                    key: ValueKey('loading'),
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation(Colors.white),
                    ),
                  )
                  : Icon(
                    Icons.auto_awesome_rounded,
                    key: const ValueKey('icon'),
                    size: 22,
                    color: _isDragging ? Colors.black : Colors.white,
                  ),
        ),
      ),
    );
  }

  Widget _buildContent(BoxConstraints c) {
    final titleSize = (c.maxWidth * 0.037).clamp(13.0, 15.5);
    final subSize = (c.maxWidth * 0.026).clamp(10.0, 11.5);
    return Padding(
      padding: EdgeInsets.fromLTRB(_handleSize + _trackPadding + 14, 0, 14, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 120),
              opacity: _isSubmitting ? 0.6 : (1 - _progress * 0.45),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.auto_awesome_rounded,
                        size: titleSize + 1,
                        color:
                            _isDragging
                                ? const Color(0xFF11F08A)
                                : const Color(0xFFCCCCCC),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _isSubmitting
                              ? 'Opening generator…'
                              : _isDragging
                              ? 'Slide to create 🎵 '
                              : 'Generate My Song',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: titleSize,
                            fontWeight: FontWeight.w900,
                            color:
                                _isDragging
                                    ? const Color(0xFF11F08A)
                                    : Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _isDragging
                        ? 'Release to generate AI song'
                        : 'AI writes lyrics based on your style',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: subSize,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF888888),
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedOpacity(
            duration: const Duration(milliseconds: 120),
            opacity: _isSubmitting ? 0.2 : (_progress < 0.25 ? 0.8 : 0.15),
            child: SizedBox(
              width: 48,
              height: 18,
              child: Stack(
                children: List.generate(4, (i) {
                  const alphas = [1.0, 0.65, 0.38, 0.18];
                  return Positioned(
                    left: i * 11.0,
                    child: Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: Colors.white.withValues(alpha: alphas[i]),
                    ),
                  );
                }),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Generate My Song',
      hint: 'Slide right to open the AI song generator.',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxTravel = _maxTravel(constraints);
          final knobOffset = maxTravel * _progress;
          final revealW = (_handleSize + _trackPadding * 2 + knobOffset).clamp(
            _handleSize + _trackPadding * 2,
            constraints.maxWidth,
          );
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (d) {
              HapticFeedback.lightImpact();
              _updateProgress(d.localPosition, constraints);
            },
            onHorizontalDragUpdate:
                (d) => _updateProgress(d.localPosition, constraints),
            onHorizontalDragEnd: (_) => _onDragEnd(),
            onHorizontalDragCancel: () {
              if (!_isSubmitting)
                setState(() {
                  _progress = 0;
                  _isDragging = false;
                });
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              decoration: _buildTrackDecoration(),
              child: Stack(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    width: revealW,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2C2C2C),
                      borderRadius: BorderRadius.circular(22),
                    ),
                  ),
                  _buildShimmer(constraints),
                  Positioned.fill(child: _buildContent(constraints)),
                  _buildHandle(knobOffset),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// 🎵 🎵  Shimmer painter (extracted for cleanliness) 🎵  🎵  🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵 🎵 🎵 🎵  🎵 🎵  🎵  🎵  🎵 🎵 🎵 🎵  🎵  🎵  🎵  🎵  🎵  🎵  🎵  🎵  🎵  🎵  🎵  🎵  🎵 🎵
class _ShimmerPainter extends CustomPainter {
  const _ShimmerPainter({required this.x, required this.bandWidth});

  final double x;
  final double bandWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final grad = LinearGradient(
      colors: [
        Colors.white.withValues(alpha: 0),
        Colors.white.withValues(alpha: 0.025),
        Colors.white.withValues(alpha: 0.10),
        Colors.white.withValues(alpha: 0.025),
        Colors.white.withValues(alpha: 0),
      ],
    ).createShader(Rect.fromLTWH(x, 0, bandWidth, size.height));
    canvas.save();
    canvas.transform(Matrix4.rotationZ(-0.12).storage);
    canvas.drawRect(
      Rect.fromLTWH(x - 10, -20, bandWidth, size.height + 40),
      Paint()..shader = grad,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ShimmerPainter old) =>
      old.x != x || old.bandWidth != bandWidth;
}

class _SeekButton extends StatelessWidget {
  const _SeekButton({required this.seconds, required this.onPressed});

  final int seconds;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final isForward = seconds > 0;
    return Opacity(
      opacity: enabled ? 1.0 : 0.35,
      child: GestureDetector(
        onTap: onPressed,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 56,
          height: 56,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isForward ? Icons.forward_10_rounded : Icons.replay_10_rounded,
                color: const Color(0xFF111111),
                size: 28,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderQuickMenu extends StatelessWidget {
  const _HeaderQuickMenu({
    required this.compact,
    required this.onOpenHostParty,
    required this.onOpenJoinParty,
    required this.onOpenDownloads,
  });

  final bool compact;
  final VoidCallback onOpenHostParty;
  final VoidCallback onOpenJoinParty;
  final VoidCallback onOpenDownloads;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_HeaderMenuAction>(
      tooltip: 'Open menu',
      onSelected: (value) {
        switch (value) {
          case _HeaderMenuAction.hostParty:
            onOpenHostParty();
            break;
          case _HeaderMenuAction.joinParty:
            onOpenJoinParty();
            break;
          case _HeaderMenuAction.downloads:
            onOpenDownloads();
            break;
        }
      },
      color: const Color(0xFFF4EFE7),
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      itemBuilder:
          (context) => const [
            PopupMenuItem<_HeaderMenuAction>(
              value: _HeaderMenuAction.hostParty,
              child: _HeaderMenuItem(
                icon: Icons.celebration_rounded,
                label: 'Host a party',
              ),
            ),
            PopupMenuItem<_HeaderMenuAction>(
              value: _HeaderMenuAction.joinParty,
              child: _HeaderMenuItem(
                icon: Icons.group_add_rounded,
                label: 'Join a party',
              ),
            ),
            PopupMenuItem<_HeaderMenuAction>(
              value: _HeaderMenuAction.downloads,
              child: _HeaderMenuItem(
                icon: Icons.download_rounded,
                label: 'Downloads',
              ),
            ),
          ],
      child: Container(
        height: compact ? 28 : 20,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFF8F4EE),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFD8D3CC), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.keyboard_arrow_down_rounded,
              color: const Color(0xFF333333),
              size: compact ? 20 : 22,
            ),
          ],
        ),
      ),
    );
  }
}

enum _HeaderMenuAction { hostParty, joinParty, downloads }

class _HeaderMenuItem extends StatelessWidget {
  const _HeaderMenuItem({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: const Color(0xFF222222)),
        const SizedBox(width: 10),
        Text(
          label,
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: Color(0xFF222222),
          ),
        ),
      ],
    );
  }
}

class _VinylPainter extends CustomPainter {
  const _VinylPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0xFF2B2B2B), Color(0xFF151515), Color(0xFF090909)],
          stops: [0.2, 0.72, 1],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
    final groovePaint =
        Paint()
          ..style = PaintingStyle.stroke
          ..color = const Color(0x14FFFFFF)
          ..strokeWidth = 1;
    for (double groove = radius * 0.35; groove < radius * 0.96; groove += 9) {
      canvas.drawCircle(center, groove, groovePaint);
    }
    final dotPaint = Paint()..color = const Color(0xCCF4F4F4);
    for (int i = 0; i < 132; i++) {
      final theta = (i / 132) * math.pi * 2;
      final dotCenter = Offset(
        center.dx + math.cos(theta) * radius * 0.93,
        center.dy + math.sin(theta) * radius * 0.93,
      );
      canvas.drawCircle(dotCenter, 1.3, dotPaint);
    }
    canvas.drawCircle(
      center,
      radius * 0.16,
      Paint()..color = const Color(0xFFEDEAE4),
    );
    canvas.drawCircle(
      center,
      radius * 0.028,
      Paint()..color = const Color(0xFF949494),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
