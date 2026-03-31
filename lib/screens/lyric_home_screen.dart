// Mobile Lyric Play: single-line input (text + speech), play from that line.
// REFACTORED: Fully dynamic, non-scrollable layout adapting to all screen sizes.
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import '../services/playback_service_mobile.dart';
import '../services/local_suggestions_service.dart';
import '../services/youtube_quota_monitor.dart';
import '../services/lightweight_search_service.dart';
import '../services/tts_service.dart';
import '../services/lyric_audio_registry.dart';
import '../services/lyric_audio_playback.dart';
import '../services/youtube_audio_stream_service.dart';
import '../services/audio_session_service.dart';
import 'host_party_screen.dart';
import 'join_via_link_screen.dart';
import 'saved_voice_songs_screen.dart';
import '../screens/generate_song_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// How many seconds before the matched lyric line playback should begin.
// ─────────────────────────────────────────────────────────────────────────────
const int _kPreRollSeconds = 8;

class LyricHomeScreen extends StatefulWidget {
  const LyricHomeScreen({super.key});

  @override
  State<LyricHomeScreen> createState() => _LyricHomeScreenState();
}

class _LyricHomeScreenState extends State<LyricHomeScreen> {
  final _lyricController = TextEditingController();
  final _playbackService = PlaybackServiceMobile();
  final _quotaMonitor = YouTubeQuotaMonitor();
  final _lightweightService = LightweightSearchService();
  PlaybackResult? _nowPlaying;
  bool _isLoading = false;

  // ── Stream-playback loading state ─────────────────────────────────────────
  // Tracks only the URL-resolution + just_audio-init phase.
  // Once play() succeeds this is cleared immediately, regardless of whether
  // _isLoading (the search phase) is still true.
  bool _isStartingStreamPlayback = false;

  bool _isListening = false;
  bool _keepMicAlive = false;
  bool _isQuotaSavingMode = false;
  bool _isLooping = false;
  double _playerVolume = 1.0;
  double _volumeSystemCap = 1.0;
  StreamSubscription<dynamic>? _volumeSubscription;
  Timer? _speechRestartTimer;

  // ── Completion listener ───────────────────────────────────────────────────
  StreamSubscription<PlayerState>? _playerStateSubscription;

  static const String _volumeFetchInitialKey = 'fetchInitialVolume';
  static const String _volumeEventChannelName =
      'com.kurenai7968.volume_controller.volume_listener_event';
  LocalSuggestionsService? _suggestions;
  List<String> _recentLines = [];
  List<RecentTrack> _recentTracks = [];
  final SpeechToText _speech = SpeechToText();
  final TtsService _tts = TtsService();

  LyricAudioPlayback get _audio => LyricAudioRegistry.instance;
  bool get _isMicActive => _keepMicAlive || _isListening;
  @override
  void initState() {
    super.initState();
    unawaited(_initVolumeController());
    _loadSuggestions();
    _initTts();
    _bindPlayerCompletionListener();
    // Re-sync UI with any playback that survived a hot-restart.
    _recoverPlaybackState();
  }

  void _recoverPlaybackState() {
    final player = _audio.player;

    // Nothing to recover if the player is idle or finished.
    if (player.processingState == ProcessingState.idle ||
        player.processingState == ProcessingState.completed) {
      return;
    }

    // just_audio stores the MediaItem we passed as the AudioSource tag.
    final sequence = player.sequence;
    final index = player.currentIndex ?? 0;
    if (sequence == null || sequence.isEmpty) return;

    final tag = sequence[index].tag;
    if (tag is! MediaItem) return;

    final videoId = tag.id;
    if (videoId.isEmpty) return;

    debugPrint('[LyricHome] Recovering playback state for "$videoId"');

    setState(() {
      _nowPlaying = PlaybackResult(
        videoId: videoId,
        startTimeSeconds: 0,
        trackName: tag.title,
        artistName: tag.artist ?? '',
        matchedLineTimeSeconds: null,
        matchedLyricLine: null,
      );
    });
  }

  // ── Bind a listener that reacts when the track finishes naturally ──────────
  void _bindPlayerCompletionListener() {
    _playerStateSubscription?.cancel();
    _playerStateSubscription = _audio.player.playerStateStream.listen(
      (state) {
        if (!mounted) return;
        // When the player reaches the end of the track (not looping),
        // clear the loading/starting flags so the UI is responsive again.
        if (state.processingState == ProcessingState.completed) {
          unawaited(_audio.player.pause());
          setState(() {
            _isStartingStreamPlayback = false;
            // Keep _nowPlaying so the user can see what just finished and
            // press play again to restart. Just ensure loading is cleared.
            _isLoading = false;
          });
        }
        // Also clear the stream-start spinner as soon as the player is ready
        // or playing — this handles the case where _isStartingStreamPlayback
        // was left true by a previous call.
        if (state.processingState == ProcessingState.ready || state.playing) {
          if (_isStartingStreamPlayback) {
            setState(() => _isStartingStreamPlayback = false);
          }
        }
      },
      onError: (_) {
        if (mounted) {
          setState(() {
            _isStartingStreamPlayback = false;
            _isLoading = false;
          });
        }
      },
      cancelOnError: false,
    );
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
            _applyStreamPlayerVolume();
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
    _volumeSubscription?.cancel();
    _volumeSubscription = null;
    _playerStateSubscription?.cancel();
    _playerStateSubscription = null;
    _speechRestartTimer?.cancel();
    _lyricController.dispose();
    unawaited(_speech.cancel());
    unawaited(_audio.stop());
    _tts.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Computes the actual start time for playback.
  // ─────────────────────────────────────────────────────────────────────────
  int _resolvePlaybackStart(PlaybackResult result) {
    final lineTs = result.matchedLineTimeSeconds;
    if (lineTs != null && lineTs > 0) {
      return math.max(0, lineTs - _kPreRollSeconds);
    }
    return result.startTimeSeconds;
  }

  Future<void> _playResult(PlaybackResult result, {String? searchQuery}) async {
    // Stop any currently playing track first.
    if (_audio.isPlaying) {
      await _audio.stop();
    }

    setState(() {
      _nowPlaying = result;
      _isStartingStreamPlayback = true;
    });

    // Re-bind the completion listener to the (possibly recycled) player.
    _bindPlayerCompletionListener();

    final startSeconds = _resolvePlaybackStart(result);
    final startPosition = Duration(seconds: startSeconds);

    try {
      await _audio.setLoopEnabled(_isLooping);
      final streamSources = await YouTubeAudioStreamService.instance
          .getPlayableAudioSources(result.videoId);
      await AppAudioSessionService.activatePlayback();
      await _audio.playSources(
        streamSources,
        startPosition,
        MediaItem(
          id: result.videoId,
          title: result.trackName,
          artist: result.artistName,
          artUri: Uri.parse(
            'https://img.youtube.com/vi/${result.videoId}/0.jpg',
          ),
        ),
      );
      _applyStreamPlayerVolume();
    } catch (e, st) {
      debugPrint('[LyricPlay] Stream playback failed: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not start playback. Check your connection and try again. '
              '($e)',
            ),
          ),
        );
        setState(() => _nowPlaying = null);
      }
      return;
    } finally {
      // Always clear the stream-start spinner, even on success — the
      // playerStateStream listener above will also clear it, but this
      // guarantees it for the synchronous path.
      if (mounted) setState(() => _isStartingStreamPlayback = false);
    }

    final resolvedSearchQuery = (searchQuery ?? _lyricController.text).trim();

    _lightweightService.cachePlaybackResult(result, resolvedSearchQuery);
    _suggestions?.addRecentLine(resolvedSearchQuery);
    _suggestions?.addRecentTrack(
      RecentTrack(
        trackName: result.trackName,
        artistName: result.artistName,
        lyricSnippet: resolvedSearchQuery,
        videoId: result.videoId,
        startTimeSeconds: result.startTimeSeconds,
      ),
    );
    _suggestions
        ?.addRecentSearch(
          RecentSearch(
            query: resolvedSearchQuery,
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

  Future<bool> _ensureSpeechReady() async {
    bool available = false;
    try {
      available = await _speech.initialize(
        onStatus: (status) {
          if (!mounted) return;
          if (status == 'listening') {
            setState(() => _isListening = true);
            return;
          }
          if (status == 'done' || status == 'notListening') {
            setState(() => _isListening = false);
            if (_keepMicAlive) _scheduleListeningRestart();
          }
        },
        onError: (error) {
          if (!mounted) return;
          setState(() => _isListening = false);

          final code = error.errorMsg;
          if (code == 'error_listen_failed') {
            _keepMicAlive = false;
            _speechRestartTimer?.cancel();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Voice input not available here. Type your lyric instead.',
                ),
                behavior: SnackBarBehavior.floating,
                backgroundColor: Color(0xFF333333),
              ),
            );
            return;
          }

          const recoverableErrors = {
            'error_speech_timeout',
            'error_no_match',
            'error_client',
            'error_recognizer_busy',
          };
          if (recoverableErrors.contains(code)) {
            if (_keepMicAlive) _scheduleListeningRestart();
            return;
          }

          _keepMicAlive = false;
          _speechRestartTimer?.cancel();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Mic error: $code'),
              behavior: SnackBarBehavior.floating,
              backgroundColor: Colors.red.shade800,
            ),
          );
        },
      );
    } catch (_) {
      available = false;
    }
    return available;
  }

  void _scheduleListeningRestart() {
    if (!_keepMicAlive) return;
    _speechRestartTimer?.cancel();
    _speechRestartTimer = Timer(const Duration(milliseconds: 160), () {
      _speechRestartTimer = null;
      if (!_keepMicAlive || !mounted) return;
      unawaited(_beginListeningSession());
    });
  }

  Future<void> _beginListeningSession() async {
    if (!_keepMicAlive || !_speech.isAvailable || _speech.isListening) return;
    if (mounted && !_isListening) {
      setState(() => _isListening = true);
    }
    try {
      await _speech.listen(
        onResult: (result) {
          if (!mounted) return;
          setState(() {
            _lyricController.text = result.recognizedWords;
            _lyricController.selection = TextSelection.collapsed(
              offset: _lyricController.text.length,
            );
          });
        },
        listenFor: const Duration(minutes: 5),
        pauseFor: const Duration(seconds: 12),
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: false,
          listenMode: ListenMode.dictation,
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _isListening = false);
      if (_keepMicAlive) _scheduleListeningRestart();
    }
  }

  Future<void> _startListening() async {
    if (_tts.isSpeaking) await _tts.stop();

    _keepMicAlive = true;
    _speechRestartTimer?.cancel();
    final available = await _ensureSpeechReady();
    if (!mounted) return;
    if (!available) {
      _keepMicAlive = false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Speech not available'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    await _beginListeningSession();
  }

  Future<void> _stopListening() async {
    _keepMicAlive = false;
    _speechRestartTimer?.cancel();
    _speechRestartTimer = null;
    if (_speech.isListening) {
      await _speech.stop();
    } else if (_speech.isAvailable) {
      await _speech.cancel();
    }
    if (mounted) setState(() => _isListening = false);
  }

  Future<void> _toggleMic() async {
    if (_isMicActive) {
      await _stopListening();
    } else {
      await _startListening();
    }
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
    if (_isMicActive) {
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
                      matchedLineTimeSeconds: result.matchedLineTimeSeconds,
                      matchedLyricLine: result.matchedLyricLine,
                    ),
                    confidence: result.confidence,
                    source: result.source,
                    evidenceText: result.matchedLyricLine,
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
      _lyricController.clear();
      await _playResult(selected.result, searchQuery: query);
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
      // Always clear the search-loading flag when _onSearch finishes,
      // regardless of whether playback succeeded or failed.
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

  Future<void> _openGenerateSong() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => GenerateSongScreen()));
    if (!mounted) return;
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _openDownloads() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SavedVoiceSongsScreen()));
  }

  Future<void> _openGenerateSongBySlide() async {
    await HapticFeedback.mediumImpact();
    if (!mounted) return;

    FocusManager.instance.primaryFocus?.unfocus();

    final player = _audio.player;
    final isCompleted = player.processingState == ProcessingState.completed;
    if (_audio.isPlaying && !isCompleted) {
      await player.pause();
    }

    await _openGenerateSong();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Primary play/pause toggle — this is what the big center button calls.
  //
  // Fixed logic:
  //   • Never blocked by _isStartingStreamPlayback so the user can always
  //     interrupt a stream that's taking too long to start.
  //   • If loading (search in progress) → ignore (still show spinner).
  //   • If nothing loaded yet → trigger search.
  //   • If playing → pause.
  //   • If paused / completed → play (restart from beginning if completed).
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _togglePrimaryPlayback() async {
    // Only block during the search phase, not during stream startup.
    if (_isLoading) return;

    final p = _audio.player;
    final isCompleted = p.processingState == ProcessingState.completed;
    final isEffectivelyPlaying = _audio.isPlaying && !isCompleted;

    if (_nowPlaying == null) {
      // Nothing loaded — run a search.
      await _onSearch();
      return;
    }

    if (_isStartingStreamPlayback) {
      // Stream is still being initialised — let the user cancel by stopping.
      await _audio.stop();
      setState(() {
        _isStartingStreamPlayback = false;
        _nowPlaying = null;
      });
      return;
    }

    if (isEffectivelyPlaying) {
      await p.pause();
    } else {
      // If the track finished, replay from the true beginning instead of the
      // lyric-match preroll that is only meant for the initial search result.
      if (isCompleted) {
        await p.seek(Duration.zero);
      }
      await p.play();
    }
  }

  void _toggleLooping() {
    final next = !_isLooping;
    setState(() => _isLooping = next);
    unawaited(_audio.setLoopEnabled(next));
  }

  void _seekRelative(int seconds) {
    if (_nowPlaying == null) return;
    final player = _audio.player;
    final current = _audio.position;
    final total = player.duration ?? Duration.zero;
    final target = current + Duration(seconds: seconds);
    final clamped =
        total > Duration.zero
            ? Duration(
              milliseconds: target.inMilliseconds.clamp(
                0,
                total.inMilliseconds,
              ),
            )
            : (target.isNegative ? Duration.zero : target);
    unawaited(player.seek(clamped));
  }

  void _applyStreamPlayerVolume() {
    try {
      _audio.player.setVolume(_playerVolume.clamp(0.0, 1.0));
    } catch (_) {}
  }

  void _seekToFraction(double fraction) {
    if (_nowPlaying == null) return;
    final total = _audio.player.duration;
    if (total == null || total <= Duration.zero) return;
    final clamped = fraction.clamp(0.0, 1.0);
    unawaited(
      _audio.player.seek(
        Duration(milliseconds: (total.inMilliseconds * clamped).round()),
      ),
    );
  }

  String _formatClockLabel(int seconds) {
    final safe = seconds < 0 ? 0 : seconds;
    final minutes = safe ~/ 60;
    final remainder = safe % 60;
    return '$minutes:${remainder.toString().padLeft(2, '0')}';
  }

  String? _bestEvidenceSnippet(PlaybackOption option) {
    final line = option.result.matchedLyricLine?.trim();
    if (line != null && line.isNotEmpty) return line;

    final evidence = option.evidenceText?.trim();
    if (evidence == null || evidence.isEmpty) return null;

    final compact = evidence.replaceAll(RegExp(r'\s+'), ' ');
    if (compact.length <= 120) return compact;
    return '${compact.substring(0, 117)}...';
  }

  Future<PlaybackOption?> _pickCandidateFromOptions(
    List<PlaybackOption> options,
  ) async {
    if (options.length == 1) return options.first;

    return showModalBottomSheet<PlaybackOption>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return _SongPickerSheet(
          options: options,
          formatClock: _formatClockLabel,
          bestSnippet: _bestEvidenceSnippet,
          preRollSeconds: _kPreRollSeconds,
        );
      },
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
      resizeToAvoidBottomInset: false,
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
                  Padding(
                    padding: EdgeInsets.fromLTRB(hPad, vGap, hPad, vGap),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _SearchConsoleCard(
                          lyricController: _lyricController,
                          isLoading: _isLoading,
                          isListening: _isMicActive,
                          isSpeaking: _tts.isSpeaking,
                          isQuotaSavingMode: _isQuotaSavingMode,
                          recentLines: _recentLines,
                          availableWidth: availW - hPad * 2,
                          isCompact: isCompact,
                          screenHeight: availH,
                          onSearch: _onSearch,
                          onToggleSpeak: _toggleSpeakLine,
                          onToggleListen: _toggleMic,
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
                            audio: _audio,
                            nowPlaying: _nowPlaying,
                            savedCount: _recentLines.length,
                            // Pass the combined loading flag to the player card.
                            // The play button shows a spinner only during the
                            // search phase (_isLoading), NOT during stream
                            // startup — that way the user can tap to cancel.
                            isLoading: _isLoading,
                            isStreamStarting: _isStartingStreamPlayback,
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

// _SongPickerSheet
// ─────────────────────────────────────────────────────────────────────────────

class _SongPickerSheet extends StatelessWidget {
  const _SongPickerSheet({
    required this.options,
    required this.formatClock,
    required this.bestSnippet,
    required this.preRollSeconds,
  });

  final List<PlaybackOption> options;
  final String Function(int) formatClock;
  final String? Function(PlaybackOption) bestSnippet;
  final int preRollSeconds;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.72,
      minChildSize: 0.45,
      maxChildSize: 0.94,
      expand: false,
      builder: (ctx, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFFF5F3EF),
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 4),
                child: Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFFCBC8C2),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Pick a match',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                              color: Colors.black,
                              height: 1.1,
                            ),
                          ),
                          const SizedBox(height: 5),
                          RichText(
                            text: TextSpan(
                              style: const TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: Color(0xFF888888),
                                height: 1.45,
                              ),
                              children: [
                                const TextSpan(text: 'Exact lyric hits play '),
                                TextSpan(
                                  text: '${preRollSeconds}s before',
                                  style: const TextStyle(
                                    color: Colors.black,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const TextSpan(text: ' the matched line.'),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '${options.length} result${options.length == 1 ? '' : 's'}',
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: ListView.separated(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  itemCount: options.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    return _SongPickerCard(
                      option: options[i],
                      rank: i,
                      formatClock: formatClock,
                      snippet: bestSnippet(options[i]),
                      preRollSeconds: preRollSeconds,
                      onTap: () => Navigator.of(context).pop(options[i]),
                    );
                  },
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF444444),
                        side: const BorderSide(color: Color(0xFFD8D4CC)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
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
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _SongPickerCard
// ─────────────────────────────────────────────────────────────────────────────

class _SongPickerCard extends StatelessWidget {
  const _SongPickerCard({
    required this.option,
    required this.rank,
    required this.formatClock,
    required this.snippet,
    required this.preRollSeconds,
    required this.onTap,
  });

  final PlaybackOption option;
  final int rank;
  final String Function(int) formatClock;
  final String? snippet;
  final int preRollSeconds;
  final VoidCallback onTap;

  static Color _confidenceColor(double c) {
    if (c >= 0.80) return const Color(0xFF11C979);
    if (c >= 0.60) return const Color(0xFFFFB830);
    return const Color(0xFFCCCCCC);
  }

  @override
  Widget build(BuildContext context) {
    final result = option.result;
    final hasExactLine =
        (result.matchedLyricLine ?? '').trim().isNotEmpty &&
        result.matchedLineTimeSeconds != null &&
        result.matchedLineTimeSeconds! >= 0;

    final playStart =
        hasExactLine
            ? math.max(0, result.matchedLineTimeSeconds! - preRollSeconds)
            : result.startTimeSeconds;

    final confidencePct = (option.confidence * 100).clamp(0, 100).round();
    final accentColor = _confidenceColor(option.confidence);
    final isTopResult = rank == 0;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color:
                isTopResult ? const Color(0xFFF0EDE7) : const Color(0xFFFAF8F5),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color:
                  isTopResult
                      ? const Color(0xFFD8D4CC)
                      : const Color(0xFFEAE6E0),
              width: isTopResult ? 1.5 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  _ZoomedCircularThumbnail(
                    imageUrl:
                        'https://img.youtube.com/vi/${result.videoId}/0.jpg',
                    size: 58,
                    fallbackText: result.trackName,
                  ),
                  if (isTopResult)
                    Positioned(
                      bottom: -4,
                      right: -4,
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: const BoxDecoration(
                          color: Colors.black,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.star_rounded,
                          size: 12,
                          color: Color(0xFFFFD000),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            result.trackName,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: Colors.black,
                              height: 1.2,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: accentColor.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Text(
                            '$confidencePct%',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color:
                                  accentColor == const Color(0xFFCCCCCC)
                                      ? const Color(0xFF888888)
                                      : accentColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      result.artistName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF777777),
                      ),
                    ),
                    if (snippet != null) ...[
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEAE6DF),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(top: 1),
                              child: Icon(
                                Icons.format_quote_rounded,
                                size: 13,
                                color: Color(0xFF888888),
                              ),
                            ),
                            const SizedBox(width: 5),
                            Expanded(
                              child: Text(
                                snippet!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 12,
                                  fontStyle: FontStyle.italic,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF444444),
                                  height: 1.4,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _MetaChip(
                          icon: Icons.play_circle_outline_rounded,
                          label: 'Plays from ${formatClock(playStart)}',
                          highlighted: true,
                        ),
                        if (hasExactLine)
                          _MetaChip(
                            icon: Icons.lyrics_outlined,
                            label:
                                'Line at ${formatClock(result.matchedLineTimeSeconds!)}',
                          ),
                        _MetaChip(
                          icon: Icons.tune_rounded,
                          label: option.source,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(
                  Icons.chevron_right_rounded,
                  color: Color(0xFFAAAAAA),
                  size: 22,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _ZoomedCircularThumbnail
// ─────────────────────────────────────────────────────────────────────────────
class _ZoomedCircularThumbnail extends StatelessWidget {
  const _ZoomedCircularThumbnail({
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
      clipBehavior: Clip.antiAliasWithSaveLayer,
      child: Image.network(
        imageUrl,
        width: size,
        height: size,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.high,
        // This effectively zooms in on the image by scaling it up slightly
        // and centering it within the oval. 
        // A scale of 1.3 provides a nice zoomed-in effect that fills the circle
        // without losing important visual details for most YouTube thumbnails.
        scale: 0.85, 
        errorBuilder: (_, __, ___) {
          return Container(
            width: size,
            height: size,
            decoration: const BoxDecoration(
              color: Color(0xFFD8D4CC),
              shape: BoxShape.circle,
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
    );
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// _MetaChip
// ─────────────────────────────────────────────────────────────────────────────

class _MetaChip extends StatelessWidget {
  const _MetaChip({
    required this.icon,
    required this.label,
    this.highlighted = false,
  });

  final IconData icon;
  final String label;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: highlighted ? const Color(0xFF111111) : const Color(0xFFE4E0D9),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 11,
            color: highlighted ? Colors.white : const Color(0xFF666666),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: highlighted ? Colors.white : const Color(0xFF555555),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _TurntablePlayerCard
// ─────────────────────────────────────────────────────────────────────────────
class _TurntablePlayerCard extends StatelessWidget {
  const _TurntablePlayerCard({
    required this.audio,
    required this.nowPlaying,
    required this.savedCount,
    required this.isLoading,
    required this.isStreamStarting,
    required this.isLooping,
    required this.onToggleLoop,
    required this.onSeekBackward,
    required this.onPlayPause,
    required this.onSeekForward,
    required this.onSeekToFraction,
  });

  final LyricAudioPlayback audio;
  final PlaybackResult? nowPlaying;
  final int savedCount;
  final bool isLoading;
  final bool isStreamStarting; // separate flag: stream URL being fetched/loaded
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
    final player = audio.player;
    final basePosition = const Duration(minutes: 1, seconds: 54);
    final baseDuration = const Duration(minutes: 3, seconds: 35);
    final resolvedDuration = player.duration;
    final effectiveDuration =
        resolvedDuration != null && resolvedDuration > Duration.zero
            ? resolvedDuration
            : baseDuration;
    final baseProgress =
        effectiveDuration.inMilliseconds <= 0
            ? 0.54
            : (audio.position.inMilliseconds / effectiveDuration.inMilliseconds)
                .clamp(0.0, 1.0);
    final title = nowPlaying?.trackName ?? 'The Suffering';
    final artist = nowPlaying?.artistName ?? 'LyricQSK';
    final trackCount = savedCount.toString().padLeft(3, '0');

    Widget buildCard(bool isPlaying, Duration position, Duration duration) {
      final playbackProgress =
          duration.inMilliseconds <= 0
              ? baseProgress
              : (position.inMilliseconds / duration.inMilliseconds).clamp(
                0.0,
                1.0,
              );
      final rotationAngle =
          duration.inMilliseconds == 0
              ? 0.0
              : (position.inMilliseconds / 12000) * math.pi * 2;

      // Determine what the center button should show:
      //   • isLoading (search phase)  → spinner, button disabled
      //   • isStreamStarting          → spinner, but button IS tappable (cancel)
      //   • playing                   → pause icon
      //   • paused / completed / idle → play icon
      final showSearchSpinner = isLoading && !isStreamStarting;
      final buttonEnabled = !isLoading || isStreamStarting;

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
                            onPressed: nowPlaying == null ? null : onToggleLoop,
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
                                            child: SizedBox(
                                              width: labelSize,
                                              height: labelSize,
                                              child: ClipOval(
                                                clipBehavior:
                                                    Clip.antiAliasWithSaveLayer,
                                                child:
                                                    nowPlaying != null
                                                        ? Image.network(
                                                          'https://img.youtube.com/vi/${nowPlaying!.videoId}/0.jpg',
                                                          width: labelSize,
                                                          height: labelSize,
                                                          fit: BoxFit.cover,
                                                          filterQuality:
                                                              FilterQuality
                                                                  .high,
                                                          scale: 0.85, // Zoom in effect for the turntable label as well
                                                          errorBuilder:
                                                              (
                                                                _,
                                                                __,
                                                                ___,
                                                              ) => Container(
                                                                color:
                                                                    const Color(
                                                                      0xFFD8D4CC,
                                                                    ),
                                                                child: Center(
                                                                  child: Text(
                                                                    'LYRICQSK',
                                                                    style: TextStyle(
                                                                      fontFamily:
                                                                          'Inter',
                                                                      fontSize:
                                                                          labelSize *
                                                                          0.12,
                                                                      fontWeight:
                                                                          FontWeight
                                                                              .w700,
                                                                      color: const Color(
                                                                        0xFF6B6B6B,
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ),
                                                              ),
                                                        )
                                                        : Transform.rotate(
                                                          angle: math.pi,
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
                            onTap: buttonEnabled ? onPlayPause : null,
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
                        // Show loading state in the badge when stream is starting
                        isStreamStarting ? 'Loading…' : 'Now Playing',
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
                        onSeek: nowPlaying == null ? null : onSeekToFraction,
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
                      onPressed: nowPlaying == null ? null : onSeekBackward,
                    ),
                    Container(
                      width: playBtnSize,
                      height: playBtnSize,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black,
                      ),
                      child: IconButton(
                        // Button is always tappable unless we're in the pure
                        // search phase (isLoading && !isStreamStarting).
                        onPressed: buttonEnabled ? onPlayPause : null,
                        icon:
                            showSearchSpinner
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
                                : isStreamStarting
                                // Stream loading: show a smaller spinner but
                                // with a stop-square overlay so user knows
                                // they can tap to cancel.
                                ? Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    SizedBox(
                                      width: playBtnSize * 0.42,
                                      height: playBtnSize * 0.42,
                                      child: const CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                              Color(0x88FFFFFF),
                                            ),
                                      ),
                                    ),
                                    Icon(
                                      Icons.stop_rounded,
                                      color: Colors.white,
                                      size: playBtnSize * 0.28,
                                    ),
                                  ],
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
                      onPressed: nowPlaying == null ? null : onSeekForward,
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      );
    }

    if (nowPlaying == null) {
      return buildCard(false, basePosition, baseDuration);
    }
    return StreamBuilder<Duration>(
      stream: player.positionStream,
      builder: (context, positionSnap) {
        final position = positionSnap.data ?? audio.position;
        return StreamBuilder<PlayerState>(
          stream: player.playerStateStream,
          builder: (context, stateSnap) {
            final state = stateSnap.data;
            final isCompleted =
                state?.processingState == ProcessingState.completed;
            final playing = (state?.playing ?? audio.isPlaying) && !isCompleted;
            final duration =
                (player.duration != null && player.duration! > Duration.zero)
                    ? player.duration!
                    : baseDuration;
            return buildCard(playing, position, duration);
          },
        );
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

// ─────────────────────────────────────────────────────────────────────────────
// Everything below this line is unchanged from the original file.
// ─────────────────────────────────────────────────────────────────────────────

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
  }

  void _hideOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
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

// ─────────────────────────────────────────────────────────────────────────────
// _CircularThumbnail
// ─────────────────────────────────────────────────────────────────────────────
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
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: const BoxDecoration(shape: BoxShape.circle),
      child: Image.network(
        imageUrl,
        width: size,
        height: size,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.high,
        errorBuilder: (_, __, ___) {
          return Container(
            width: size,
            height: size,
            decoration: const BoxDecoration(
              color: Color(0xFFD8D4CC),
              shape: BoxShape.circle,
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
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Small deck widgets (unchanged)
// ─────────────────────────────────────────────────────────────────────────────

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
          onTapDown: (d) => _handleSeek(d.localPosition, width),
          onHorizontalDragStart: (d) => _handleSeek(d.localPosition, width),
          onHorizontalDragUpdate: (d) => _handleSeek(d.localPosition, width),
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

// ─────────────────────────────────────────────────────────────────────────────
// _GenerateSongSliderCard (unchanged)
// ─────────────────────────────────────────────────────────────────────────────
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
  static const double _completeThreshold = 0.99;

  double _progress = 0;
  bool _isSubmitting = false;
  bool _isDragging = false;
  bool _isDragValid = false;
  double _dragStartDx = 0;
  double _dragStartProgress = 0;

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

  void _onDragStart(DragStartDetails details, BoxConstraints c) {
    if (_isSubmitting) return;
    final maxTravel = _maxTravel(c);
    final handleLeft = _trackPadding + maxTravel * _progress;
    final handleRight = handleLeft + _handleSize;
    final tapX = details.localPosition.dx;
    if (tapX >= handleLeft && tapX <= handleRight) {
      _isDragValid = true;
      _dragStartDx = tapX;
      _dragStartProgress = _progress;
      HapticFeedback.lightImpact();
      setState(() => _isDragging = true);
    } else {
      _isDragValid = false;
    }
  }

  void _onDragUpdate(DragUpdateDetails details, BoxConstraints c) {
    if (_isSubmitting || !_isDragValid) return;
    final maxTravel = _maxTravel(c);
    if (maxTravel <= 0) return;
    final delta = details.localPosition.dx - _dragStartDx;
    final t = (_dragStartProgress + delta / maxTravel).clamp(0.0, 1.0);
    if (t == _progress) return;
    setState(() {
      _progress = t;
      _isDragging = true;
    });
  }

  Future<void> _onDragEnd() async {
    setState(() {
      _isDragging = false;
      _isDragValid = false;
    });
    if (_isSubmitting) return;
    if (_progress >= _completeThreshold) {
      setState(() {
        _progress = 1;
        _isSubmitting = true;
      });
      try {
        await widget.onCompleted();
      } finally {
        if (mounted) {
          setState(() {
            _isSubmitting = false;
            _progress = 0;
          });
        }
      }
    } else {
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
          child: Icon(
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
              opacity: 1 - _progress * 0.45,
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
                          _isDragging
                              ? 'Slide to create music '
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
            opacity: _progress < 0.25 ? 0.8 : 0.15,
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
      hint: 'Slide the handle right to open the AI song generator.',
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
            onHorizontalDragStart: (d) => _onDragStart(d, constraints),
            onHorizontalDragUpdate: (d) => _onDragUpdate(d, constraints),
            onHorizontalDragEnd: (_) => _onDragEnd(),
            onHorizontalDragCancel: () {
              if (!_isSubmitting) {
                setState(() {
                  _progress = 0;
                  _isDragging = false;
                  _isDragValid = false;
                });
              }
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