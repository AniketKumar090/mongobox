// Mobile Lyric Play: single-line input (text + speech), play from that line.

import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import '../services/playback_service_mobile.dart';
import '../services/local_suggestions_service.dart';
import '../services/youtube_quota_monitor.dart';
import '../services/lightweight_search_service.dart';
import '../services/tts_service.dart';
import '../services/youtube_player_background_helper.dart';
import '../services/jamendo_service.dart';
import '../services/background_audio_player_service.dart';
import '../services/soundcloud_service.dart';
import 'host_party_screen.dart';
import 'join_via_link_screen.dart';
import '../screens/generate_song_screen.dart'; // ← NEW
import 'saved_voice_songs_screen.dart';

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

  LocalSuggestionsService? _suggestions;
  List<String> _recentLines = [];
  List<RecentTrack> _recentTracks = [];
  List<RecentSearch> _recentSearches = [];

  final SpeechToText _speech = SpeechToText();
  final TtsService _tts = TtsService();
  final JamendoService _jamendo = JamendoService();
  final SoundCloudService _soundcloud = SoundCloudService();

  bool _isBackgroundAudioLoading = false;
  JamendoTrack? _backgroundTrack;
  SoundCloudTrack? _backgroundSoundCloudTrack;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
      _wasPlayingBeforeBackground = c.value.isPlaying;
      // If user minimizes while YouTube is playing, try to mirror audio in a
      // background-capable player automatically.
      if (_wasPlayingBeforeBackground) {
        _autoStartBackgroundMirror();
      }
      return;
    }

    if (state == AppLifecycleState.resumed && _wasPlayingBeforeBackground) {
      YouTubePlayerBackgroundHelper.resumePlayback(c);
    }
  }

  void _autoStartBackgroundMirror() {
    // Fire-and-forget; lifecycle callback must stay sync.
    _startBackgroundMirrorFromNowPlaying(auto: true);
  }

  Future<void> _startBackgroundMirrorFromNowPlaying({required bool auto}) async {
    if (_isBackgroundAudioLoading) return;
    if (BackgroundAudioPlayerService.instance.isPlaying) return;

    final now = _nowPlaying;
    if (now == null) return;
    if (now.trackName.trim().isEmpty || now.artistName.trim().isEmpty) return;

    setState(() => _isBackgroundAudioLoading = true);
    try {
      // 1) Prefer SoundCloud mirror (usually closest for mainstream tracks).
      final sc = await _soundcloud.findMirrorStream(
        trackName: now.trackName,
        artistName: now.artistName,
      );

      if (!mounted) return;
      if (sc != null && sc.confidence >= 0.62) {
        _ytController?.pause();
        await BackgroundAudioPlayerService.instance.playUrl(sc.streamUrl);
        if (!mounted) return;
        setState(() {
          _backgroundSoundCloudTrack = sc.track;
          _backgroundTrack = null;
        });
        return;
      }

      // 2) Fallback to Jamendo mirror (royalty-free catalog; may be different).
      final jm = await _jamendo.findMirrorTrack(
        trackName: now.trackName,
        artistName: now.artistName,
      );
      if (!mounted) return;
      final jmTrack = jm?.track;
      final jmConf = jm?.confidence ?? 0;

      if (jmTrack != null && jmConf >= 0.55) {
        _ytController?.pause();
        await BackgroundAudioPlayerService.instance.playUrl(jmTrack.audioUrl);
        if (!mounted) return;
        setState(() {
          _backgroundTrack = jmTrack;
          _backgroundSoundCloudTrack = null;
        });
        return;
      }

      // If auto mode, keep quiet; user can manually try via the button.
      if (!auto) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not find a close-enough background stream.'),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      if (!auto) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Background audio failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isBackgroundAudioLoading = false);
    }
  }

  Future<void> _initTts() async {
    await _tts.init(onStateChanged: () {
      if (mounted) setState(() {});
    });
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
    _recentSearches = _suggestions?.getRecentSearches() ?? [];
    _lightweightService.seedFromRecentTracks(_recentTracks);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lyricController.dispose();
    _ytController?.dispose();
    _tts.dispose();
    super.dispose();
  }

  void _playResult(PlaybackResult result) {
    if (_ytController == null) {
      _ytController = YouTubePlayerBackgroundHelper.createBackgroundAwareController(
        videoId: result.videoId,
        startSeconds: result.startTimeSeconds,
        autoPlay: true,
      );
    } else {
      _ytController!.load(result.videoId, startAt: result.startTimeSeconds);
    }

    setState(() {
      _nowPlaying = result;
    });
    _lightweightService.cachePlaybackResult(result, _lyricController.text.trim());
    _suggestions?.addRecentLine(_lyricController.text.trim());
    _suggestions?.addRecentTrack(RecentTrack(
      trackName: result.trackName,
      artistName: result.artistName,
      lyricSnippet: _lyricController.text.trim(),
      videoId: result.videoId,
      startTimeSeconds: result.startTimeSeconds,
    ));
    _suggestions?.addRecentSearch(RecentSearch(
      query: _lyricController.text.trim(),
      success: true,
      searchedAtMs: DateTime.now().millisecondsSinceEpoch,
      trackName: result.trackName,
      artistName: result.artistName,
    )).then((_) {
      if (mounted) {
        setState(() {
          _syncRecentFromService();
        });
      }
    });
  }

  Future<void> _toggleBackgroundAudio() async {
    if (_isBackgroundAudioLoading) return;

    final isPlaying = BackgroundAudioPlayerService.instance.isPlaying;
    if (isPlaying) {
      await BackgroundAudioPlayerService.instance.stop();
      if (mounted) {
        setState(() {
          _backgroundTrack = null;
          _backgroundSoundCloudTrack = null;
        });
      }
      return;
    }

    final now = _nowPlaying;
    final typed = _lyricController.text.trim();
    final hasIdentity = now != null &&
        now.trackName.trim().isNotEmpty &&
        now.artistName.trim().isNotEmpty;
    if ((typed.isEmpty) && !hasIdentity) return;

    setState(() => _isBackgroundAudioLoading = true);
    try {
      // Prefer SoundCloud when we have a known track identity.
      if (hasIdentity) {
        final sc = await _soundcloud.findMirrorStream(
          trackName: now!.trackName,
          artistName: now.artistName,
        );
        if (!mounted) return;
        if (sc != null && sc.confidence >= 0.62) {
          if (_ytController?.value.isPlaying ?? false) {
            _ytController?.pause();
          }
          await BackgroundAudioPlayerService.instance.playUrl(sc.streamUrl);
          if (!mounted) return;
          setState(() {
            _backgroundSoundCloudTrack = sc.track;
            _backgroundTrack = null;
          });
          return;
        }
      }

      JamendoTrack? track;
      double confidence = 0;

      if (hasIdentity) {
        final mirror = await _jamendo.findMirrorTrack(
          trackName: now!.trackName,
          artistName: now.artistName,
        );
        track = mirror?.track;
        confidence = mirror?.confidence ?? 0;
      } else {
        track = await _jamendo.searchBestTrack(typed);
        confidence = track == null ? 0 : 0.35;
      }

      if (!mounted) return;
      if (track == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No background-capable stream found.')),
        );
        return;
      }

      // If we're mirroring a known YouTube song, enforce a minimum confidence
      // so we don't play a completely different track "discreetly".
      if (hasIdentity && confidence < 0.55) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not find a close-enough Jamendo match for this song.',
            ),
          ),
        );
        return;
      }

      // Avoid double-audio: pause YouTube if it’s currently playing.
      if (_ytController?.value.isPlaying ?? false) {
        _ytController?.pause();
      }

      await BackgroundAudioPlayerService.instance.playUrl(track.audioUrl);
      if (!mounted) return;
      setState(() {
        _backgroundTrack = track;
        _backgroundSoundCloudTrack = null;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Background audio failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _isBackgroundAudioLoading = false);
    }
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
    if (!mounted || !available) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Speech not available')),
      );
      return;
    }
    await _speech.listen(
      onResult: (result) {
        if (mounted && result.finalResult) {
          _lyricController.text = result.recognizedWords;
          _lyricController.selection =
              TextSelection.collapsed(offset: _lyricController.text.length);
        }
      },
      listenFor: const Duration(seconds: 15),
      pauseFor: const Duration(seconds: 3),
      partialResults: true,
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('TTS error: $e')),
      );
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
              Icon(Icons.warning_amber, color: Theme.of(context).colorScheme.error),
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
                  color: Theme.of(context)
                      .colorScheme
                      .errorContainer
                      .withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.schedule,
                            color: Theme.of(context).colorScheme.error),
                        const SizedBox(width: 8),
                        Text(
                          'Time until reset:',
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '$hours hours $minutes minutes',
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
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
        final lightweightResults = await _lightweightService.searchSingleLineLyrics(
          query,
          cacheOnly: true,
        );
        options = lightweightResults
            .map((result) => PlaybackOption(
                  result: PlaybackResult(
                    videoId: result.videoId,
                    startTimeSeconds: result.startTimeSeconds,
                    trackName: result.trackName,
                    artistName: result.artistName,
                  ),
                  confidence: result.confidence,
                  source: result.source,
                ))
            .toList();
      } else {
        options = await _playbackService.resolveCandidates(query, limit: 5);
      }

      if (!mounted) return;
      if (options.isEmpty) {
        await _suggestions?.addRecentSearch(RecentSearch(
          query: query,
          success: false,
          searchedAtMs: DateTime.now().millisecondsSinceEpoch,
        ));
        if (mounted) setState(_syncRecentFromService);

        final message = _isQuotaSavingMode
            ? 'No song found in cache. Try normal mode or different lyrics.'
            : 'No song found for this line. Try another.';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
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
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('Error: $e')));
        }
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _openHostParty() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const HostPartyScreen()),
    );
  }

  void _openJoinParty() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => JoinViaLinkScreen(
          onBack: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  // ── NEW ──────────────────────────────────────────────────────────────────────
  void _openGenerateSong() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) =>  GenerateSongScreen()),
    );
  }
  // ─────────────────────────────────────────────────────────────────────────────

  String _formatRecentTime(int epochMs) {
    if (epochMs <= 0) return 'just now';
    final dt = DateTime.fromMillisecondsSinceEpoch(epochMs);
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${dt.day}/${dt.month}';
  }

  Future<PlaybackOption?> _pickCandidateFromOptions(
      List<PlaybackOption> options) async {
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
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
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
                        child: Text('${i + 1}',
                            style: theme.textTheme.labelSmall),
                      ),
                      title: Text(result.trackName,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
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
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        title: const Text('Lyric Play'),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Theme.of(context).colorScheme.inverseSurface,
        foregroundColor: Theme.of(context).colorScheme.onInverseSurface,
        actions: [
          IconButton(
            icon: const Icon(Icons.library_music_rounded),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SavedVoiceSongsScreen(),
                ),
              );
            },
            tooltip: 'Saved songs',
          ),
          IconButton(
            icon: const Icon(Icons.qr_code_2),
            onPressed: _openHostParty,
            tooltip: 'Host a party',
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isCompact = constraints.maxWidth < 600;
            final colorScheme = Theme.of(context).colorScheme;
            return SingleChildScrollView(
              padding: EdgeInsets.symmetric(
                horizontal: isCompact ? 24.0 : 48.0,
                vertical: 20.0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 8),

                  // Host party card
                  InkWell(
                    onTap: _openHostParty,
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .primaryContainer
                            .withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: 0.3),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.party_mode,
                              color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Host a party',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleSmall
                                      ?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface,
                                      ),
                                ),
                                Text(
                                  'Share a QR or link • Guests add songs to your queue',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ),
                          ),
                          Icon(Icons.chevron_right,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Join party card
                  InkWell(
                    onTap: _openJoinParty,
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .secondaryContainer
                            .withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Theme.of(context)
                              .colorScheme
                              .secondary
                              .withValues(alpha: 0.3),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.person_add,
                              color: Theme.of(context).colorScheme.secondary),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Join a party',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleSmall
                                      ?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface,
                                      ),
                                ),
                                Text(
                                  'Enter your name and add songs to the queue',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ),
                          ),
                          Icon(Icons.chevron_right,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // ── AI GENERATE SONG BANNER ─────────────────────────────────
                  InkWell(
                    onTap: _openGenerateSong,
                    borderRadius: BorderRadius.circular(16),
                    child: Ink(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            colorScheme.primary,
                            colorScheme.tertiary.withValues(alpha: 0.85),
                          ],
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                        ),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: colorScheme.primary.withValues(alpha: 0.35),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 18),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(
                                Icons.auto_awesome,
                                color: Colors.white,
                                size: 26,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'Generate My Song',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white,
                                        ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'AI writes original lyrics based on your taste',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                          color: Colors.white
                                              .withValues(alpha: 0.85),
                                        ),
                                  ),
                                ],
                              ),
                            ),
                            const Icon(
                              Icons.arrow_forward_ios_rounded,
                              color: Colors.white,
                              size: 18,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // ───────────────────────────────────────────────────────────

                  const SizedBox(height: 20),
                  Text(
                    'Enter a line of lyrics',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: colorScheme.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _lyricController,
                    maxLines: 1,
                    enabled: !_isLoading,
                    style: TextStyle(color: colorScheme.onSurface),
                    decoration: InputDecoration(
                      hintText: 'e.g. Hello from the other side',
                      hintStyle: TextStyle(
                          color: colorScheme.onSurface.withValues(alpha: 0.6)),
                      prefixIcon: Icon(Icons.music_note_outlined,
                          color: colorScheme.primary),
                      filled: true,
                      fillColor: colorScheme.surfaceContainerHighest,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide:
                            BorderSide(color: colorScheme.outline),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                            color: colorScheme.outline.withValues(alpha: 0.5)),
                      ),
                    ),
                    onSubmitted: (_) => _onSearch(),
                  ),
                  const SizedBox(height: 12),

                  // Quota-saving mode toggle
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: _isQuotaSavingMode
                          ? colorScheme.primaryContainer.withValues(alpha: 0.3)
                          : colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _isQuotaSavingMode
                            ? colorScheme.primary.withValues(alpha: 0.5)
                            : colorScheme.outline.withValues(alpha: 0.2),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _isQuotaSavingMode ? Icons.eco : Icons.cloud,
                          color: _isQuotaSavingMode
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Quota-Saving Mode',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleSmall
                                    ?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      color: _isQuotaSavingMode
                                          ? colorScheme.primary
                                          : colorScheme.onSurface,
                                    ),
                              ),
                              Text(
                                _isQuotaSavingMode
                                    ? 'Uses cached results • Saves API quota'
                                    : 'Full search • Higher accuracy',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                        color: colorScheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: _isQuotaSavingMode,
                          onChanged: (value) =>
                              setState(() => _isQuotaSavingMode = value),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _isLoading ? null : _onSearch,
                          icon: _isLoading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              : const Icon(Icons.search),
                          label:
                              Text(_isLoading ? 'Finding…' : 'Find & play'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      IconButton.filled(
                        onPressed: _isLoading ? null : _toggleSpeakLine,
                        icon: Icon(
                          _tts.isSpeaking ? Icons.stop : Icons.volume_up,
                        ),
                        tooltip: _tts.isSpeaking ? 'Stop speaking' : 'Speak line',
                      ),
                      const SizedBox(width: 12),
                      IconButton.filled(
                        onPressed: _isLoading
                            ? null
                            : () {
                                if (_isListening) {
                                  _stopListening();
                                } else {
                                  _startListening();
                                }
                              },
                        icon: Icon(_isListening ? Icons.mic : Icons.mic_none),
                        tooltip:
                            _isListening ? 'Stop listening' : 'Speak lyrics',
                      ),
                    ],
                  ),

                  if (_recentLines.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Text(
                      'Recent lines',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            color: colorScheme.onSurface,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _recentLines.take(10).map((line) {
                        return ActionChip(
                          label: Text(
                            line.length > 40
                                ? '${line.substring(0, 40)}…'
                                : line,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                          onPressed: () {
                            _lyricController.text = line;
                            _lyricController.selection =
                                TextSelection.collapsed(offset: line.length);
                          },
                        );
                      }).toList(),
                    ),
                  ],

                  if (_recentSearches.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Text(
                          'Recent searches',
                          style: Theme.of(context)
                              .textTheme
                              .labelLarge
                              ?.copyWith(
                                color: colorScheme.onSurface,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () async {
                            await _suggestions?.clearRecentSearches();
                            if (!mounted) return;
                            setState(_syncRecentFromService);
                          },
                          child: const Text('Clear'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ..._recentSearches.take(6).map((s) => ListTile(
                          dense: true,
                          leading: Icon(
                            s.success
                                ? Icons.check_circle_outline
                                : Icons.search_off,
                            size: 20,
                            color: s.success
                                ? colorScheme.primary
                                : colorScheme.error,
                          ),
                          title: Text(s.query,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            s.success
                                ? '${s.trackName ?? ''}${(s.artistName ?? '').isNotEmpty ? ' • ${s.artistName}' : ''} • ${_formatRecentTime(s.searchedAtMs)}'
                                : 'No match • ${_formatRecentTime(s.searchedAtMs)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () {
                            _lyricController.text = s.query;
                            _lyricController.selection =
                                TextSelection.collapsed(
                                    offset: s.query.length);
                          },
                        )),
                  ],

                  if (_recentTracks.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(
                      'Recent tracks',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            color: colorScheme.onSurface,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 8),
                    ..._recentTracks.take(5).map((t) => ListTile(
                          dense: true,
                          leading: const Icon(Icons.history),
                          title: Text(t.trackName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          subtitle: Text(t.artistName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          onTap: () {
                            _lyricController.text = t.lyricSnippet.isNotEmpty
                                ? t.lyricSnippet
                                : '${t.trackName} ${t.artistName}';
                            _lyricController.selection =
                                TextSelection.collapsed(
                                    offset: _lyricController.text.length);
                          },
                        )),
                  ],

                  if (_nowPlaying != null) ...[
                    const SizedBox(height: 24),
                    _NowPlayingStrip(result: _nowPlaying!),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _isBackgroundAudioLoading
                                ? null
                                : _toggleBackgroundAudio,
                            icon: _isBackgroundAudioLoading
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Icon(
                                    BackgroundAudioPlayerService
                                            .instance.isPlaying
                                        ? Icons.stop_rounded
                                        : Icons.headphones_rounded,
                                  ),
                            label: Text(
                              BackgroundAudioPlayerService.instance.isPlaying
                                  ? 'Stop background audio'
                                  : 'Play in background',
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_backgroundSoundCloudTrack != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Background stream: ${_backgroundSoundCloudTrack!.title} • ${_backgroundSoundCloudTrack!.userName}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ] else if (_backgroundTrack != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Background stream: ${_backgroundTrack!.name} • ${_backgroundTrack!.artistName}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                  if (_ytController != null) ...[
                    const SizedBox(height: 16),
                    AspectRatio(
                      aspectRatio: 16 / 9,
                      child: YoutubePlayer(
                        controller: _ytController!,
                        showVideoProgressIndicator: true,
                      ),
                    ),
                  ],
                  const SizedBox(height: 32),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _NowPlayingStrip extends StatelessWidget {
  const _NowPlayingStrip({required this.result});

  final PlaybackResult result;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.music_note,
              color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  result.trackName,
                  style: Theme.of(context).textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  result.artistName,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant,
                      ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Text(
            'From ${result.startTimeSeconds}s',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}
