// Mobile Lyric Play: single-line input (text + speech), play from that line.

import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import '../services/playback_service_mobile.dart';
import '../services/local_suggestions_service.dart';
import 'host_party_screen.dart';
import 'join_via_link_screen.dart';

class LyricHomeScreen extends StatefulWidget {
  const LyricHomeScreen({super.key});

  @override
  State<LyricHomeScreen> createState() => _LyricHomeScreenState();
}

class _LyricHomeScreenState extends State<LyricHomeScreen> {
  final _lyricController = TextEditingController();
  final _playbackService = PlaybackServiceMobile();

  YoutubePlayerController? _ytController;
  PlaybackResult? _nowPlaying;
  bool _isLoading = false;
  bool _isListening = false;

  LocalSuggestionsService? _suggestions;
  List<String> _recentLines = [];
  List<RecentTrack> _recentTracks = [];

  final SpeechToText _speech = SpeechToText();

  @override
  void initState() {
    super.initState();
    _loadSuggestions();
  }

  Future<void> _loadSuggestions() async {
    final service = await LocalSuggestionsService.create();
    if (!mounted) return;
    setState(() {
      _suggestions = service;
      _recentLines = service.getRecentLines();
      _recentTracks = service.getRecentTracks();
    });
  }

  @override
  void dispose() {
    _lyricController.dispose();
    _ytController?.dispose();
    super.dispose();
  }

  void _playResult(PlaybackResult result) {
    _ytController?.dispose();
    _ytController = YoutubePlayerController(
      initialVideoId: result.videoId,
      flags: YoutubePlayerFlags(
        autoPlay: true,
        startAt: result.startTimeSeconds,
        mute: false,
      ),
    );
    setState(() {
      _nowPlaying = result;
    });
    _suggestions?.addRecentLine(_lyricController.text.trim());
    _suggestions?.addRecentTrack(RecentTrack(
      trackName: result.trackName,
      artistName: result.artistName,
      lyricSnippet: _lyricController.text.trim(),
    )).then((_) {
      if (mounted) {
        setState(() {
          _recentLines = _suggestions?.getRecentLines() ?? [];
          _recentTracks = _suggestions?.getRecentTracks() ?? [];
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
          _lyricController.selection = TextSelection.collapsed(offset: _lyricController.text.length);
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

  Future<void> _onSearch() async {
    final query = _lyricController.text.trim();
    if (query.isEmpty) return;

    setState(() => _isLoading = true);
    try {
      final result = await _playbackService.resolveAndSearch(query);
      if (!mounted) return;
      if (result == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No song found for this line. Try another.'),
          ),
        );
        return;
      }
      _playResult(result);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
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
                  InkWell(
                    onTap: _openHostParty,
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.party_mode, color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Host a party',
                                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        color: Theme.of(context).colorScheme.onSurface,
                                      ),
                                ),
                                Text(
                                  'Share a QR or link • Guests add songs to your queue',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ),
                          ),
                          Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.onSurfaceVariant),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  InkWell(
                    onTap: _openJoinParty,
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.person_add, color: Theme.of(context).colorScheme.secondary),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Join a party',
                                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        color: Theme.of(context).colorScheme.onSurface,
                                      ),
                                ),
                                Text(
                                  'Enter your name and add songs to the queue',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ),
                          ),
                          Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.onSurfaceVariant),
                        ],
                      ),
                    ),
                  ),
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
                      hintStyle: TextStyle(color: colorScheme.onSurface.withValues(alpha: 0.6)),
                      prefixIcon: Icon(Icons.music_note_outlined, color: colorScheme.primary),
                      filled: true,
                      fillColor: colorScheme.surfaceContainerHighest,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: colorScheme.outline),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: colorScheme.outline.withValues(alpha: 0.5)),
                      ),
                    ),
                    onSubmitted: (_) => _onSearch(),
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
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.search),
                            label: Text(_isLoading ? 'Finding…' : 'Find & play'),
                          ),
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
                          tooltip: _isListening ? 'Stop listening' : 'Speak lyrics',
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
                              line.length > 40 ? '${line.substring(0, 40)}…' : line,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                            onPressed: () {
                              _lyricController.text = line;
                              _lyricController.selection = TextSelection.collapsed(offset: line.length);
                            },
                          );
                        }).toList(),
                      ),
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
                        title: Text(t.trackName, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(t.artistName, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () {
                          _lyricController.text = t.lyricSnippet.isNotEmpty ? t.lyricSnippet : '${t.trackName} ${t.artistName}';
                          _lyricController.selection = TextSelection.collapsed(offset: _lyricController.text.length);
                        },
                      )),
                    ],
                    if (_nowPlaying != null) ...[
                      const SizedBox(height: 24),
                      _NowPlayingStrip(result: _nowPlaying!),
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
          Icon(
            Icons.music_note,
            color: Theme.of(context).colorScheme.primary,
          ),
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
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
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
