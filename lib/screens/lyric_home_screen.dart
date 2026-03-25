// Mobile Lyric Play: single-line input (text + speech), play from that line.

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
import 'host_party_screen.dart';
import 'join_via_link_screen.dart';
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
  Duration _backgroundSyncPosition = Duration.zero;

  // Track the actual start position for looping
  Duration _loopStartPosition = Duration.zero;

  /// 0–1 on the in-app scale (1 = "full", i.e. current system volume at init).
  double _playerVolume = 1.0;

  /// Snapshot of system volume when the screen initialized; app 100% maps here.
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
    _foregroundAudioSuppressedForBackground = true;
    try {
      controller.mute();
      controller.pause();
    } catch (_) {}
  }

  void _restoreForegroundPlayback() {
    _wasPlayingBeforeBackground = false;
    try {
      _ytController?.mute();
    } catch (_) {}
    unawaited(_restoreForegroundPlaybackAsync());
  }

  Future<void> _restoreForegroundPlaybackAsync() async {
    final mirroredPosition = BackgroundAudioPlayerService.instance.position;
    await BackgroundAudioPlayerService.instance.hardStopAndReset();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    if (!mounted) return;

    final controller = _ytController;
    if (controller == null) {
      _foregroundAudioSuppressedForBackground = false;
      _backgroundSyncPosition = Duration.zero;
      return;
    }

    final resumePosition =
        mirroredPosition > Duration.zero
            ? mirroredPosition
            : _backgroundSyncPosition;

    await _resumeForegroundController(controller, resumePosition);

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

  Future<void> _resumeForegroundController(
    YoutubePlayerController controller,
    Duration resumePosition,
  ) async {
    if (resumePosition > Duration.zero) {
      controller.seekTo(resumePosition);
    }

    await Future.delayed(const Duration(milliseconds: 180));
    if (!mounted) return;

    try {
      controller.unMute();
      controller.play();
    } catch (_) {}
    _applyEmbeddedPlayerVolume();

    await Future.delayed(const Duration(milliseconds: 320));
    if (!mounted) return;

    final state = controller.value.playerState;
    if (!controller.value.isPlaying &&
        state != PlayerState.playing &&
        state != PlayerState.buffering) {
      if (resumePosition > Duration.zero) {
        controller.seekTo(resumePosition);
      }
      try {
        controller.unMute();
        controller.play();
      } catch (_) {}
      _applyEmbeddedPlayerVolume();
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

  // ── FIX 1: Always dispose and recreate the controller in two frames ─────────
  // This prevents the "recreating_view / view id: '0'" PlatformException on iOS
  // that occurs when .load() is called on a controller whose UiKitView has been
  // torn down or is mid-recreation.
  void _playResult(PlaybackResult result) {
    if (BackgroundAudioPlayerService.instance.isPlaying) {
      unawaited(BackgroundAudioPlayerService.instance.stop());
    }
    _backgroundSyncPosition = Duration.zero;
    _foregroundAudioSuppressedForBackground = false;

    // Store the actual start position for looping
    _loopStartPosition = Duration(
      seconds: result.startTimeSeconds < 0 ? 0 : result.startTimeSeconds,
    );

    // Capture and nullify old controller reference before setState.
    final oldController = _ytController;
    _ytController = null;

    // Frame 1: Remove the YoutubePlayer widget from the tree so the platform
    // view is fully deregistered before a new one is created.
    setState(() {
      _nowPlaying = result;
      // _ytController is already null, forcing the Positioned widget to be
      // absent this frame, which causes UiKitView to be unmounted cleanly.
    });

    // Dispose old controller after the widget has been removed from the tree.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      oldController?.dispose();
    });

    // Frame 2: Create the new controller now that the old platform view is gone.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller =
          YouTubePlayerBackgroundHelper.createBackgroundAwareController(
            videoId: result.videoId,
            startSeconds: result.startTimeSeconds,
            autoPlay: true,
            loop: false, // We'll handle loop manually
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

  void _togglePrimaryPlayback() {
    if (_isLoading) return;
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

  // FIXED: Loop restarts from 0:00 to play the full song including intro
void _attachLoopListener(YoutubePlayerController controller) {
  controller.addListener(() {
    if (!_isLooping || _isHandlingLoopRestart) return;
    final playerState = controller.value.playerState;
    
    if (playerState == PlayerState.ended) {
      _isHandlingLoopRestart = true;
      Future.microtask(() async {
        try {
          // FIX: Use load() with correct parameter 'startAt' (in seconds)
          final videoId = controller.metadata.videoId;
          if (videoId.isNotEmpty) {
            controller.load(
              videoId,
              startAt: 0, // Play from beginning on loop (parameter is 'startAt', not 'startSeconds')
            );
          } else {
            // Fallback if videoId is missing
            controller.seekTo(Duration.zero);
          }
          
          await Future.delayed(const Duration(milliseconds: 100));
          if (!mounted) {
            _isHandlingLoopRestart = false;
            return;
          }
          
          controller.play();
          await Future.delayed(const Duration(milliseconds: 50));
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

  // ── FIX 3: Guard against calling setVolume/mute before the player is ready ──
  void _applyEmbeddedPlayerVolume() {
    final controller = _ytController;
    if (controller == null) return;
    // Do not call volume methods if the player is not yet ready; the onReady
    // callback will call this method again once it is safe to do so.
    if (!controller.value.isReady) return;

    final volume = (_playerVolume * 100).round().clamp(0, 100);
    controller.setVolume(volume);
    if (volume == 0) {
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
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: [
                    Text(
                      'Choose your song',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: options.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final option = options[i];
                    final result = option.result;
                    final confidencePct =
                        (option.confidence * 100).clamp(0, 100).round();
                    return ListTile(
                      dense: true,
                      leading: CircleAvatar(
                        radius: 14,
                        child: Text(
                          '${i + 1}',
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                      title: Text(
                        result.trackName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${result.artistName} • ${result.startTimeSeconds}s • ${option.source} • $confidencePct%',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => Navigator.of(ctx).pop(option),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F3EF),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: InkWell(
          onTap: _openGenerateSong,
          borderRadius: BorderRadius.circular(22),
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [Color(0xFF11F08A), Color(0xFF5BB4FF)],
              ),
              borderRadius: BorderRadius.circular(22),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x3312D9A1),
                  blurRadius: 20,
                  offset: Offset(0, 10),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: const Icon(
                    Icons.auto_awesome_rounded,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
                const SizedBox(width: 16),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Generate My Song',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'AI writes original lyrics based on your style and mood',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: Colors.white,
                  size: 28,
                ),
              ],
            ),
          ),
        ),
      ),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.translucent,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isCompact = constraints.maxWidth < 600;
              final horizontalPadding = isCompact ? 24.0 : 48.0;
              return Stack(
                children: [
                  // ── FIX 2: ValueKey tied to videoId forces Flutter to fully
                  // replace the YoutubePlayer widget (and its UiKitView) when
                  // the video changes, avoiding platform-view id collisions. ──
                  if (_ytController != null)
                    Positioned(
                      left: horizontalPadding,
                      right: horizontalPadding,
                      top: 28,
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
                  SingleChildScrollView(
                    padding: EdgeInsets.symmetric(
                      horizontal: horizontalPadding,
                      vertical: 20.0,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _SearchConsoleCard(
                          lyricController: _lyricController,
                          isLoading: _isLoading,
                          isListening: _isListening,
                          isSpeaking: _tts.isSpeaking,
                          isQuotaSavingMode: _isQuotaSavingMode,
                          recentLines: _recentLines,
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
                          onSelectRecentLine: (line) {
                            _lyricController.text = line;
                            _lyricController.selection =
                                TextSelection.collapsed(offset: line.length);
                          },
                        ),
                        const SizedBox(height: 20),
                        _TurntablePlayerCard(
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
                        const SizedBox(height: 18),
                        const SizedBox(height: 32),
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
    final artist = nowPlaying?.artistName ?? 'Classic';
    final badgeText = nowPlaying == null ? 'Classic' : 'Now Playing';
    final trackCount = savedCount.toString().padLeft(3, '0');

    Widget buildCard(bool isPlaying, Duration position, Duration duration) {
      final playbackProgress =
          duration.inMilliseconds <= 0
              ? progress
              : (position.inMilliseconds / duration.inMilliseconds).clamp(
                0.0,
                1.0,
              );
      final rotationAngle =
          duration.inMilliseconds == 0
              ? 0.0
              : (position.inMilliseconds / 12000) * math.pi * 2;

      return Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0xFFF5F3EF),
          borderRadius: BorderRadius.circular(28),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 328,
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
                    const Positioned(top: 10, left: 10, child: _DeckScrew()),
                    const Positioned(top: 10, right: 10, child: _DeckScrew()),
                    const Positioned(bottom: 10, left: 10, child: _DeckScrew()),
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
                      left: 42,
                      top: 14,
                      bottom: 14,
                      right: 42,
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: DecoratedBox(
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
                                Container(
                                  width: 86,
                                  height: 86,
                                  decoration: const BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Color(0xFFF9F8F4),
                                        Color(0xFFDBD8D2),
                                      ],
                                    ),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    artist.length > 12
                                        ? artist.substring(0, 12).toUpperCase()
                                        : artist.toUpperCase(),
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      fontFamily: 'Inter',
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF6B6B6B),
                                      letterSpacing: 0.6,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const Positioned(
                      left: 52,
                      bottom: 78,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Color(0xFFBB1D2D),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(color: Color(0x66BB1D2D), blurRadius: 8),
                          ],
                        ),
                        child: SizedBox(width: 6, height: 6),
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
            const SizedBox(height: 18),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      color: Colors.black,
                      height: 1.05,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEDEAE4),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.add_box_rounded,
                        size: 18,
                        color: Colors.black,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        trackCount,
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Colors.black,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF171717),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    badgeText,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 12,
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
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF575757),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text(
                  _formatClock(position),
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1C1C1C),
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _ScrubbableWaveform(
                    heights: _waveformHeights,
                    progress: playbackProgress,
                    onSeek: controller == null ? null : onSeekToFraction,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  _formatClock(duration),
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1C1C1C),
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _PlayerIconButton(
                  icon: Icons.skip_previous_rounded,
                  onPressed: controller == null ? null : onSeekBackward,
                ),
                Container(
                  width: 72,
                  height: 72,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black,
                  ),
                  child: IconButton(
                    onPressed: isLoading ? null : onPlayPause,
                    icon:
                        isLoading
                            ? const SizedBox(
                              width: 24,
                              height: 24,
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
                              size: 36,
                            ),
                  ),
                ),
                _PlayerIconButton(
                  icon: Icons.skip_next_rounded,
                  onPressed: controller == null ? null : onSeekForward,
                ),
              ],
            ),
          ],
        ),
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

class _SearchConsoleCard extends StatefulWidget {
  const _SearchConsoleCard({
    required this.lyricController,
    required this.isLoading,
    required this.isListening,
    required this.isSpeaking,
    required this.isQuotaSavingMode,
    required this.recentLines,
    required this.onSearch,
    required this.onToggleSpeak,
    required this.onToggleListen,
    required this.onToggleQuotaMode,
    required this.onOpenJoinParty,
    required this.onOpenHostParty,
    required this.onSelectRecentLine,
  });

  final TextEditingController lyricController;
  final bool isLoading;
  final bool isListening;
  final bool isSpeaking;
  final bool isQuotaSavingMode;
  final List<String> recentLines;
  final VoidCallback onSearch;
  final VoidCallback onToggleSpeak;
  final VoidCallback onToggleListen;
  final ValueChanged<bool> onToggleQuotaMode;
  final VoidCallback onOpenJoinParty;
  final VoidCallback onOpenHostParty;
  final ValueChanged<String> onSelectRecentLine;

  @override
  State<_SearchConsoleCard> createState() => _SearchConsoleCardState();
}

class _SearchConsoleCardState extends State<_SearchConsoleCard> {
  bool _showDropdown = false;
  final FocusNode _focusNode = FocusNode();

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
    _focusNode.addListener(() {
      if (_focusNode.hasFocus && widget.recentLines.isNotEmpty) {
        setState(() => _showDropdown = true);
      } else if (!_focusNode.hasFocus) {
        Future.delayed(const Duration(milliseconds: 150), () {
          if (mounted) setState(() => _showDropdown = false);
        });
      }
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F4EE),
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 18,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Search with one lyric line',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 24,
              fontWeight: FontWeight.w900,
              color: Colors.black,
              height: 1.05,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Drop a lyric, use voice, and jump straight into playback.',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Color(0xFF666666),
            ),
          ),
          const SizedBox(height: 14),

          Stack(
            children: [
              Column(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFEDE8E0),
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(22),
                        topRight: const Radius.circular(22),
                        bottomLeft: Radius.circular(_showDropdown ? 0 : 22),
                        bottomRight: Radius.circular(_showDropdown ? 0 : 22),
                      ),
                      border: Border.all(
                        color:
                            widget.isListening
                                ? const Color(0xFF11F08A)
                                : Colors.transparent,
                        width: 1.5,
                      ),
                    ),
                    child: Row(
                      children: [
                        const SizedBox(width: 16),
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
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                color: Colors.black,
                              ),
                              decoration: const InputDecoration(
                                hintText: 'e.g. Hello from the other side',
                                hintStyle: TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFFAAAAAA),
                                ),
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                filled: true,
                                fillColor: Colors.transparent,
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 18,
                                ),
                              ),
                              onSubmitted: (_) => widget.onSearch(),
                              onChanged: (_) {
                                if (widget.recentLines.isEmpty) return;
                                if (!_showDropdown) {
                                  setState(() => _showDropdown = true);
                                } else {
                                  setState(() {});
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
                            width: 40,
                            height: 40,
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
                              size: 20,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  if (_showDropdown && _filteredLines.isNotEmpty)
                    Container(
                      constraints: const BoxConstraints(maxHeight: 220),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEDE8E0),
                        borderRadius: const BorderRadius.only(
                          bottomLeft: Radius.circular(22),
                          bottomRight: Radius.circular(22),
                        ),
                        border: Border.all(
                          color: const Color(0xFFD8D4CC),
                          width: 1,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: const BorderRadius.only(
                          bottomLeft: Radius.circular(22),
                          bottomRight: Radius.circular(22),
                        ),
                        child: ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          shrinkWrap: true,
                          itemCount: _filteredLines.length,
                          separatorBuilder:
                              (_, __) => const Divider(
                                height: 1,
                                indent: 16,
                                endIndent: 16,
                                color: Color(0xFFC8C4BC),
                              ),
                          itemBuilder: (_, i) {
                            final line = _filteredLines[i];
                            return InkWell(
                              onTap: () {
                                widget.onSelectRecentLine(line);
                                setState(() => _showDropdown = false);
                                _focusNode.unfocus();
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 18,
                                  vertical: 12,
                                ),
                                child: Row(
                                  children: [
                                    const Icon(
                                      Icons.history_rounded,
                                      size: 16,
                                      color: Color(0xFF888888),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        line,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontFamily: 'Inter',
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.black,
                                        ),
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
                ],
              ),
            ],
          ),

          const SizedBox(height: 14),

          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 54,
                  child: FilledButton.icon(
                    onPressed: widget.isLoading ? null : widget.onSearch,
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.black,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                    icon:
                        widget.isLoading
                            ? const SizedBox(
                              width: 18,
                              height: 18,
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
                        fontSize: 15,
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
                  height: 54,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color:
                        widget.isQuotaSavingMode
                            ? const Color(0xFF141414)
                            : const Color(0xFFEDE8E0),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        widget.isQuotaSavingMode
                            ? Icons.eco_rounded
                            : Icons.cloud_queue_rounded,
                        size: 20,
                        color:
                            widget.isQuotaSavingMode
                                ? const Color(0xFF11F08A)
                                : const Color(0xFF555555),
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
                                  : const Color(0xFF555555),
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
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color:
                isLooping ? const Color(0xFF161616) : const Color(0xFFD7D7D7),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color:
                  isLooping ? const Color(0xFF11F08A) : const Color(0xFF8A8A8A),
              width: 1.3,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x22000000),
                blurRadius: 8,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: Icon(
            isLooping ? Icons.repeat_one_rounded : Icons.repeat_rounded,
            size: 20,
            color:
                isLooping ? const Color(0xFF11F08A) : const Color(0xFF4E4E4E),
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
    final angle = isPlaying ? (0.2 + (progress * 0.22)) : -0.15;
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

class _PlayerIconButton extends StatelessWidget {
  const _PlayerIconButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.35,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon),
        color: const Color(0xFF111111),
        splashRadius: 24,
        iconSize: 24,
      ),
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
