import 'dart:async';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import '../models/song_reference.dart';
import '../services/bpm_service.dart';
import '../services/lyrics_service.dart';
import '../theme/lyric_screen_theme.dart';
import '../widgets/flow_step_header.dart';
import 'voice_song_screen.dart';

class VoiceSampleScreen extends StatefulWidget {
  const VoiceSampleScreen({
    super.key,
    required this.songTitle,
    required this.hindiLyrics,
    required this.englishLyrics,
    required this.dominantLanguage,
    required this.mood,
    required this.genre,
    this.referenceSong,
    this.hinglishLyrics,
  });

  final String songTitle;
  final String hindiLyrics;
  final String englishLyrics;
  final String? hinglishLyrics;
  final String dominantLanguage;
  final String mood;
  final String genre;
  final SongReference? referenceSong;

  @override
  State<VoiceSampleScreen> createState() => _VoiceSampleScreenState();
}

class _VoiceSampleScreenState extends State<VoiceSampleScreen>
    with SingleTickerProviderStateMixin {
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  final _bpmService = BpmService();
  late ScrollController _scrollController;
  String? _recordedPath;
  bool _isRecording = false;
  bool _isPlaying = false;
  int _recordingSeconds = 0;
  Timer? _timer;
  Timer? _karaokeTicker;
  final Stopwatch _karaokeWatch = Stopwatch();
  List<String> _karaokeFlowLines = const [];
  List<String> _karaokeWords = const [];
  List<int> _karaokeLineWordStart = const [];
  int _karaokeCurrentWord = -1;
  int _karaokeCurrentLine = 0;
  int _karaokeTargetWpm = 108;
  int? _referenceMsPerWord;
  double _activeLineProgress = 0;
  String? _paceFeedback;
  bool _showFullLyrics = true;
  late final String _targetLyrics;
  late final List<String> _preparedFlowPromptLines;
  late final int _fallbackTargetWpm;
  late AnimationController _waveController;
  final _lyricsService = LyricsService();

  @override
  void initState() {
    super.initState();
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _scrollController = ScrollController();
    _prepareRecordingAssets();
    _fetchReferenceTempo();
  }

  void _prepareRecordingAssets() {
    final isHindiDominant = widget.dominantLanguage.toLowerCase().contains(
      'hindi',
    );
    _targetLyrics =
        isHindiDominant
            ? (widget.hinglishLyrics?.isNotEmpty == true
                ? widget.hinglishLyrics!
                : widget.hindiLyrics)
            : widget.englishLyrics;
    _preparedFlowPromptLines = _extractFlowPromptLines(
      _targetLyrics,
      isHindiDominant: isHindiDominant,
    );
    _fallbackTargetWpm = _estimateTargetWpm(_targetLyrics);
  }

  Future<void> _fetchReferenceTempo() async {
    final ref = widget.referenceSong;
    if (ref == null) return;
    if (ref.trackName.trim().isNotEmpty && ref.artistName.trim().isNotEmpty) {
      try {
        final matches = await _lyricsService.search(
          '${ref.trackName} ${ref.artistName}',
        );
        for (final m in matches.take(5)) {
          final synced = m.syncedLyrics;
          if (synced != null && synced.isNotEmpty) {
            final ms = LyricsService.computeMsPerWordFromSyncedLyrics(synced);
            if (ms != null && mounted) {
              setState(() => _referenceMsPerWord = ms);
              return;
            }
          }
          final full = await _lyricsService.getById(m.id);
          if (full?.syncedLyrics != null && full!.syncedLyrics!.isNotEmpty) {
            final ms = LyricsService.computeMsPerWordFromSyncedLyrics(
              full.syncedLyrics,
            );
            if (ms != null && mounted) {
              setState(() => _referenceMsPerWord = ms);
              return;
            }
          }
        }
      } catch (_) {}
    }
    final videoId = ref.videoId?.trim();
    if (videoId != null && videoId.isNotEmpty) {
      try {
        final bpm = await _bpmService.fetchBpm(videoId);
        if (bpm != null && bpm >= 50 && bpm <= 220 && mounted) {
          final ms = (60000 / (bpm * 1.5)).round().clamp(220, 900);
          setState(() => _referenceMsPerWord = ms);
        }
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _karaokeTicker?.cancel();
    _recorder.dispose();
    _player.dispose();
    _waveController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _showMicSettingsDialog() async {
    await showDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Row(
              children: [
                Icon(
                  Icons.mic_off_rounded,
                  color: Theme.of(ctx).colorScheme.error,
                ),
                const SizedBox(width: 8),
                const Text('Microphone Permission Required'),
              ],
            ),
            content: const Text(
              'Microphone access is disabled. Please enable it in Settings to continue recording.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () async {
                  Navigator.of(ctx).pop();
                  await openAppSettings();
                },
                child: const Text('Open Settings'),
              ),
            ],
          ),
    );
  }

  Future<void> _startRecording() async {
    final current = await Permission.microphone.status;
    if (current.isPermanentlyDenied || current.isRestricted) {
      if (!mounted) return;
      await _showMicSettingsDialog();
      return;
    }
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      if (!mounted) return;
      if (mic.isPermanentlyDenied || mic.isRestricted) {
        await _showMicSettingsDialog();
      } else {
        _showSnack('Microphone permission required');
      }
      return;
    }
    try {
      if (mounted) {
        setState(() {
          _isRecording = true;
          _recordedPath = null;
          _paceFeedback = null;
        });
      }
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/voice_sample.m4a';
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: path,
      );
      _timer?.cancel();
      _recordingSeconds = 0;
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _recordingSeconds++);
        if (_recordingSeconds >= 30) _stopRecording();
      });
      final targetWpm =
          _referenceMsPerWord != null
              ? (60000 / _referenceMsPerWord!).round().clamp(90, 150)
              : _fallbackTargetWpm;
      _waveController.repeat(reverse: true);
      _startKaraokeGuide(
        flowLines: _preparedFlowPromptLines,
        targetWpm: targetWpm,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _isRecording = false);
      }
      _showSnack('Recording failed: ${e.toString()}');
    }
  }

  Future<void> _stopRecording() async {
    _timer?.cancel();
    _waveController.stop();
    _stopKaraokeGuide();
    try {
      final path = await _recorder.stop();
      if (!mounted) return;
      final feedback = _buildPaceFeedback(
        spokenSeconds: _recordingSeconds,
        targetWpm: _karaokeTargetWpm,
        flowLines: _karaokeFlowLines,
      );
      setState(() {
        _isRecording = false;
        _recordedPath = path;
        _paceFeedback = feedback;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isRecording = false);
      _showSnack('Stop failed: ${e.toString()}');
    }
  }

  Future<void> _playback() async {
    if (_recordedPath == null) return;
    if (_isPlaying) {
      await _player.stop();
      if (mounted) setState(() => _isPlaying = false);
      return;
    }
    await _player.setFilePath(_recordedPath!);
    setState(() => _isPlaying = true);
    await _player.play();
    if (mounted) setState(() => _isPlaying = false);
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  // ── Lyrics helpers ─────────────────────────────────────────────────────────
  static const _hindiSections = [
    'verse 1',
    'verse 2',
    'verse 3',
    'bridge',
    'pre-chorus',
  ];
  static const _englishSections = ['chorus', 'outro', 'hook'];

  List<String> _linesForDominantLanguage(String lyrics, bool isHindiDominant) {
    final raw = lyrics.split('\n');
    final result = <String>[];
    var currentSection = '';
    for (final line in raw) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final lower = trimmed.toLowerCase();
      if (RegExp(r'^\[.+\]').hasMatch(lower)) {
        currentSection = lower.replaceAll(RegExp(r'[\[\]]'), '');
        continue;
      }
      final sectionMatch =
          isHindiDominant
              ? _hindiSections.any((s) => currentSection.contains(s))
              : _englishSections.any((s) => currentSection.contains(s));
      if (sectionMatch && trimmed.length >= 8) result.add(trimmed);
    }
    if (result.isEmpty) return _cleanSingableLines(lyrics);
    return result;
  }

  List<String> _cleanSingableLines(String lyrics) {
    return lyrics
        .split('\n')
        .map((l) => l.trim())
        .where(
          (l) =>
              l.isNotEmpty &&
              !l.startsWith('[') &&
              l
                      .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '')
                      .length >=
                  8,
        )
        .toList();
  }

  List<String> _extractFlowPromptLines(
    String lyrics, {
    required bool isHindiDominant,
  }) {
    final filtered = _linesForDominantLanguage(lyrics, isHindiDominant);
    if (filtered.isEmpty) return const [];
    filtered.sort((a, b) => a.length.compareTo(b.length));
    final picked = filtered.where((l) => l.length <= 90).take(4).toList();
    return picked.isNotEmpty ? picked : filtered.take(3).toList();
  }

  List<String> _getAllLyricsLines(String lyrics) {
    final raw = lyrics.split('\n');
    final result = <String>[];
    var currentSection = '';
    for (final line in raw) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final lower = trimmed.toLowerCase();
      if (RegExp(r'^\[.+\]').hasMatch(lower)) {
        currentSection = lower.replaceAll(RegExp(r'[\[\]]'), '');
        result.add(trimmed);
        continue;
      }
      final sectionMatch =
          _hindiSections.any((s) => currentSection.contains(s)) ||
          _englishSections.any((s) => currentSection.contains(s));
      if (sectionMatch && trimmed.length >= 8) {
        result.add(trimmed);
      } else if (trimmed.length >= 5) {
        result.add(trimmed);
      }
    }
    return result;
  }

  int _estimateTargetWpm(String lyrics) {
    final lines = _cleanSingableLines(lyrics);
    if (lines.isEmpty) return 105;
    final words = lines
        .take(10)
        .map((l) => l.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length)
        .fold<int>(0, (a, b) => a + b);
    final avgWordsPerLine = words / lines.take(10).length;
    return (avgWordsPerLine * 18).round().clamp(90, 150);
  }

  List<String> _splitWords(String line) =>
      line.split(RegExp(r'\s+')).where((w) => w.trim().isNotEmpty).toList();

  void _startKaraokeGuide({
    required List<String> flowLines,
    required int targetWpm,
  }) {
    _karaokeFlowLines = flowLines;
    _karaokeTargetWpm = targetWpm;
    _karaokeCurrentWord = -1;
    _karaokeCurrentLine = 0;
    _activeLineProgress = 0;
    _paceFeedback = null;
    final starts = <int>[];
    final words = <String>[];
    var cursor = 0;
    for (final line in flowLines) {
      starts.add(cursor);
      final split = _splitWords(line);
      words.addAll(split);
      cursor += split.length;
    }
    _karaokeLineWordStart = starts;
    _karaokeWords = words;
    _karaokeTicker?.cancel();
    _karaokeWatch
      ..reset()
      ..start();
    _karaokeTicker = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (!mounted || _karaokeWords.isEmpty) return;
      final msPerWord =
          _referenceMsPerWord ??
          (60000 / _karaokeTargetWpm).round().clamp(220, 900);
      final rawIndex = (_karaokeWatch.elapsedMilliseconds / msPerWord).floor();
      final safeIndex = rawIndex.clamp(0, _karaokeWords.length - 1);
      if (safeIndex == _karaokeCurrentWord) return;
      var lineIndex = 0;
      for (var i = 0; i < _karaokeLineWordStart.length; i++) {
        final start = _karaokeLineWordStart[i];
        final next =
            i + 1 < _karaokeLineWordStart.length
                ? _karaokeLineWordStart[i + 1]
                : _karaokeWords.length;
        if (safeIndex >= start && safeIndex < next) {
          lineIndex = i;
          break;
        }
      }
      setState(() {
        _karaokeCurrentWord = safeIndex;
        _karaokeCurrentLine = lineIndex;
        final lineStart =
            lineIndex < _karaokeLineWordStart.length
                ? _karaokeLineWordStart[lineIndex]
                : 0;
        final lineEnd =
            lineIndex + 1 < _karaokeLineWordStart.length
                ? _karaokeLineWordStart[lineIndex + 1]
                : _karaokeWords.length;
        final lineWordCount = (lineEnd - lineStart).clamp(1, 9999);
        final inLine = (safeIndex - lineStart).clamp(0, lineWordCount - 1);
        _activeLineProgress = (inLine + 1) / lineWordCount;
      });
    });
  }

  void _stopKaraokeGuide() {
    _karaokeTicker?.cancel();
    _karaokeWatch.stop();
  }

  String _buildPaceFeedback({
    required int spokenSeconds,
    required int targetWpm,
    required List<String> flowLines,
  }) {
    if (spokenSeconds <= 0 || flowLines.isEmpty) return '';
    final targetWords = flowLines.expand(_splitWords).length.clamp(1, 9999);
    final ratio = spokenSeconds / (targetWords * 60 / targetWpm);
    if (ratio < 0.85) return 'Too fast — slow down to stay on beat.';
    if (ratio > 1.2) return 'Too slow — tighten delivery to match flow.';
    return 'Great pacing — close to target flow.';
  }

  // ───────────────────────────────────────────────────────────────────────────
  // BUILD
  // ───────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final pageTheme = lyricScreenTheme(context);
    final cs = pageTheme.colorScheme;
    final tt = pageTheme.textTheme;
    final hasRecording = _recordedPath != null;
    final isShort = _recordingSeconds < 5 && hasRecording;
    final isHindiDominant = widget.dominantLanguage.toLowerCase().contains(
      'hindi',
    );
    final targetLyrics = _targetLyrics;

    return Theme(
      data: pageTheme,
      child: Scaffold(
        backgroundColor: LyricScreenPalette.background,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final horizontalPadding = flowHorizontalPadding(
                constraints.maxWidth,
              );
              final contentMaxWidth = flowContentMaxWidth(constraints.maxWidth);

              return Column(
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      16,
                      horizontalPadding,
                      12,
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: contentMaxWidth),
                        child: const FlowStepHeader(
                          title: 'Record your voice',
                          subtitle:
                              'Read a short sample clearly so we can build a solid voice clone for your song.',
                          steps: ['Song', 'Voice', 'Preview'],
                          currentStep: 2,
                        ),
                      ),
                    ),
                  ),
                  if (hasRecording && !_isRecording)
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          horizontalPadding,
                          0,
                          horizontalPadding,
                          16,
                        ),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: contentMaxWidth,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _InfoCard(
                                  songTitle: widget.songTitle,
                                  referenceSong: widget.referenceSong,
                                  cs: cs,
                                  tt: tt,
                                ),
                                const SizedBox(height: 16),
                                Expanded(
                                  child: Container(
                                    padding: const EdgeInsets.all(20),
                                    decoration: BoxDecoration(
                                      color: cs.surface,
                                      borderRadius: BorderRadius.circular(24),
                                      border: Border.all(
                                        color: cs.outline.withValues(
                                          alpha: 0.65,
                                        ),
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Container(
                                              width: 36,
                                              height: 36,
                                              decoration: BoxDecoration(
                                                color: cs.secondaryContainer,
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                              child: Icon(
                                                Icons.lyrics_rounded,
                                                size: 18,
                                                color: cs.secondary,
                                              ),
                                            ),
                                            const SizedBox(width: 10),
                                            Text(
                                              'Generated Lyrics',
                                              style: tt.titleSmall?.copyWith(
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 14),
                                        Expanded(
                                          child: Scrollbar(
                                            controller: _scrollController,
                                            thumbVisibility: true,
                                            child: SingleChildScrollView(
                                              controller: _scrollController,
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  ..._getAllLyricsLines(
                                                    targetLyrics,
                                                  ).map(
                                                    (line) => Padding(
                                                      padding:
                                                          const EdgeInsets.only(
                                                            bottom: 6,
                                                          ),
                                                      child: Text(
                                                        line,
                                                        style: tt.bodyMedium?.copyWith(
                                                          height: 1.6,
                                                          color:
                                                              line.startsWith(
                                                                    '[',
                                                                  )
                                                                  ? cs.onSurfaceVariant
                                                                  : cs.onSurface,
                                                          fontWeight:
                                                              line.startsWith(
                                                                    '[',
                                                                  )
                                                                  ? FontWeight
                                                                      .w700
                                                                  : FontWeight
                                                                      .normal,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(
                          horizontalPadding,
                          0,
                          horizontalPadding,
                          16,
                        ),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: contentMaxWidth,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _InfoCard(
                                  songTitle: widget.songTitle,
                                  referenceSong: widget.referenceSong,
                                  cs: cs,
                                  tt: tt,
                                ),
                                const SizedBox(height: 16),
                                if (!_isRecording && !hasRecording) ...[
                                  _HintBanner(
                                    text:
                                        'Record yourself reading the lyrics aloud for 10-15 seconds.',
                                    color: cs.secondary,
                                    cs: cs,
                                    tt: tt,
                                  ),
                                  const SizedBox(height: 12),
                                  _SpeakingLinesDropdown(
                                    targetLyrics: targetLyrics,
                                    isHindiDominant: isHindiDominant,
                                    cs: cs,
                                    tt: tt,
                                  ),
                                  const SizedBox(height: 16),
                                  LayoutBuilder(
                                    builder: (context, innerConstraints) {
                                      final compactHeader =
                                          innerConstraints.maxWidth < 420;
                                      return compactHeader
                                          ? Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                'Lyrics to Record',
                                                style: tt.titleSmall?.copyWith(
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                              const SizedBox(height: 8),
                                              TextButton.icon(
                                                onPressed: () {
                                                  setState(
                                                    () =>
                                                        _showFullLyrics =
                                                            !_showFullLyrics,
                                                  );
                                                },
                                                icon: AnimatedRotation(
                                                  turns:
                                                      _showFullLyrics ? 0.5 : 0,
                                                  duration: const Duration(
                                                    milliseconds: 200,
                                                  ),
                                                  child: const Icon(
                                                    Icons.keyboard_arrow_down,
                                                    size: 20,
                                                  ),
                                                ),
                                                label: Text(
                                                  _showFullLyrics
                                                      ? 'Hide'
                                                      : 'Show',
                                                ),
                                                style: TextButton.styleFrom(
                                                  foregroundColor: cs.onSurface,
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 0,
                                                        vertical: 4,
                                                      ),
                                                ),
                                              ),
                                            ],
                                          )
                                          : Row(
                                            children: [
                                              Text(
                                                'Lyrics to Record',
                                                style: tt.titleSmall?.copyWith(
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                              const Spacer(),
                                              TextButton.icon(
                                                onPressed: () {
                                                  setState(
                                                    () =>
                                                        _showFullLyrics =
                                                            !_showFullLyrics,
                                                  );
                                                },
                                                icon: AnimatedRotation(
                                                  turns:
                                                      _showFullLyrics ? 0.5 : 0,
                                                  duration: const Duration(
                                                    milliseconds: 200,
                                                  ),
                                                  child: const Icon(
                                                    Icons.keyboard_arrow_down,
                                                    size: 20,
                                                  ),
                                                ),
                                                label: Text(
                                                  _showFullLyrics
                                                      ? 'Hide'
                                                      : 'Show',
                                                ),
                                                style: TextButton.styleFrom(
                                                  foregroundColor: cs.onSurface,
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 8,
                                                        vertical: 4,
                                                      ),
                                                ),
                                              ),
                                            ],
                                          );
                                    },
                                  ),
                                  const SizedBox(height: 8),
                                  AnimatedContainer(
                                    duration: const Duration(milliseconds: 300),
                                    curve: Curves.easeInOut,
                                    constraints: BoxConstraints(
                                      maxHeight: _showFullLyrics ? 320 : 0,
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(24),
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: cs.surface,
                                          border: Border.all(
                                            color: cs.outline.withValues(
                                              alpha: 0.65,
                                            ),
                                          ),
                                        ),
                                        child: Scrollbar(
                                          controller: _scrollController,
                                          thumbVisibility: true,
                                          child: SingleChildScrollView(
                                            controller: _scrollController,
                                            padding: const EdgeInsets.all(16),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                ..._getAllLyricsLines(
                                                  targetLyrics,
                                                ).map(
                                                  (line) => Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                          bottom: 6,
                                                        ),
                                                    child: Text(
                                                      line,
                                                      style: tt.bodyMedium?.copyWith(
                                                        height: 1.6,
                                                        color:
                                                            line.startsWith('[')
                                                                ? cs.onSurfaceVariant
                                                                : cs.onSurface,
                                                        fontWeight:
                                                            line.startsWith('[')
                                                                ? FontWeight
                                                                    .w700
                                                                : FontWeight
                                                                    .normal,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 20),
                                ],
                                if (_isRecording) ...[
                                  _WaveBar(
                                    controller: _waveController,
                                    seconds: _recordingSeconds,
                                    cs: cs,
                                  ),
                                  const SizedBox(height: 16),
                                  if (_karaokeFlowLines.isNotEmpty) ...[
                                    Text(
                                      'Follow the highlighted words',
                                      style: tt.labelLarge?.copyWith(
                                        fontWeight: FontWeight.w700,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                    const SizedBox(height: 12),
                                    _KaraokeBox(
                                      flowLines: _karaokeFlowLines,
                                      lineWordStart: _karaokeLineWordStart,
                                      currentWord: _karaokeCurrentWord,
                                      currentLine: _karaokeCurrentLine,
                                      activeLineProgress: _activeLineProgress,
                                      targetWpm: _karaokeTargetWpm,
                                      referenceMsPerWord: _referenceMsPerWord,
                                      splitWords: _splitWords,
                                      cs: cs,
                                      tt: tt,
                                    ),
                                  ],
                                  const SizedBox(height: 20),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  Container(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      12,
                      horizontalPadding,
                      20,
                    ),
                    decoration: BoxDecoration(
                      color: LyricScreenPalette.background,
                      border: Border(
                        top: BorderSide(
                          color: cs.outline.withValues(alpha: 0.35),
                        ),
                      ),
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: contentMaxWidth),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (hasRecording && !_isRecording) ...[
                              if (_karaokeFlowLines.isNotEmpty) ...[
                                Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: cs.surface,
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: cs.outline.withValues(alpha: 0.55),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Container(
                                            width: 32,
                                            height: 32,
                                            decoration: BoxDecoration(
                                              color: cs.secondaryContainer,
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                            ),
                                            child: Icon(
                                              Icons.article_outlined,
                                              size: 16,
                                              color: cs.secondary,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            'Lines You Recorded',
                                            style: tt.labelLarge?.copyWith(
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      ..._karaokeFlowLines.map(
                                        (line) => Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 6,
                                          ),
                                          child: Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                '›  ',
                                                style: tt.bodyMedium?.copyWith(
                                                  color: cs.secondary,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                              Expanded(
                                                child: Text(
                                                  line,
                                                  style: tt.bodyMedium
                                                      ?.copyWith(
                                                        color: cs.onSurface,
                                                      ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 10),
                              ],
                              if ((_paceFeedback ?? '').isNotEmpty) ...[
                                _PaceBanner(
                                  text: _paceFeedback!,
                                  cs: cs,
                                  tt: tt,
                                ),
                                const SizedBox(height: 8),
                              ],
                              LayoutBuilder(
                                builder: (context, footerConstraints) {
                                  final stackPlayback =
                                      isShort &&
                                      footerConstraints.maxWidth < 470;
                                  final playButton = SizedBox(
                                    width:
                                        stackPlayback ? double.infinity : null,
                                    child: OutlinedButton.icon(
                                      onPressed: _playback,
                                      icon: Icon(
                                        _isPlaying
                                            ? Icons.stop_rounded
                                            : Icons.play_arrow_rounded,
                                        size: 20,
                                      ),
                                      label: Text(_isPlaying ? 'Stop' : 'Play'),
                                    ),
                                  );
                                  final shortBadge = Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      color: cs.errorContainer,
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(
                                        color: cs.error.withValues(alpha: 0.25),
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.warning_amber_rounded,
                                          size: 16,
                                          color: cs.error,
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          'Too short',
                                          style: tt.labelSmall?.copyWith(
                                            color: cs.error,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                    ),
                                  );

                                  if (stackPlayback) {
                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        playButton,
                                        const SizedBox(height: 10),
                                        Align(
                                          alignment: Alignment.centerLeft,
                                          child: shortBadge,
                                        ),
                                      ],
                                    );
                                  }

                                  return Row(
                                    children: [
                                      Expanded(child: playButton),
                                      if (isShort) ...[
                                        const SizedBox(width: 12),
                                        shortBadge,
                                      ],
                                    ],
                                  );
                                },
                              ),
                              const SizedBox(height: 12),
                              SizedBox(
                                height: 56,
                                width: double.infinity,
                                child: FilledButton.icon(
                                  onPressed: () {
                                    Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder:
                                            (_) => VoiceSongScreen(
                                              songTitle: widget.songTitle,
                                              hindiLyrics: widget.hindiLyrics,
                                              englishLyrics:
                                                  widget.englishLyrics,
                                              hinglishLyrics:
                                                  widget.hinglishLyrics,
                                              dominantLanguage:
                                                  widget.dominantLanguage,
                                              mood: widget.mood,
                                              genre: widget.genre,
                                              referenceSong:
                                                  widget.referenceSong,
                                              voiceSamplePath: _recordedPath!,
                                            ),
                                      ),
                                    );
                                  },
                                  icon: const Icon(
                                    Icons.arrow_forward_rounded,
                                    size: 18,
                                  ),
                                  label: Text(
                                    'Use This Recording',
                                    style: tt.labelLarge?.copyWith(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                            ],
                            _isRecording
                                ? SizedBox(
                                  height: 56,
                                  width: double.infinity,
                                  child: OutlinedButton.icon(
                                    onPressed: _stopRecording,
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: cs.error,
                                      backgroundColor: cs.errorContainer,
                                      side: BorderSide(
                                        color: cs.error.withValues(alpha: 0.55),
                                      ),
                                    ),
                                    icon: const Icon(
                                      Icons.stop_rounded,
                                      size: 18,
                                    ),
                                    label: Text(
                                      'Stop (${_recordingSeconds}s)',
                                      style: tt.labelLarge?.copyWith(
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                )
                                : SizedBox(
                                  height: 56,
                                  width: double.infinity,
                                  child:
                                      hasRecording
                                          ? OutlinedButton.icon(
                                            onPressed: _startRecording,
                                            icon: const Icon(
                                              Icons.mic_rounded,
                                              size: 18,
                                            ),
                                            label: Text(
                                              'Re-record',
                                              style: tt.labelLarge?.copyWith(
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                          )
                                          : FilledButton.icon(
                                            onPressed: _startRecording,
                                            icon: const Icon(
                                              Icons.mic_rounded,
                                              size: 18,
                                            ),
                                            label: Text(
                                              'Start Recording',
                                              style: tt.labelLarge?.copyWith(
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                          ),
                                ),
                          ],
                        ),
                      ),
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

// ─────────────────────────────────────────────────────────────────────────────
// PRIVATE SUB-WIDGETS
// ─────────────────────────────────────────────────────────────────────────────

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.songTitle,
    required this.referenceSong,
    required this.cs,
    required this.tt,
  });

  final String songTitle;
  final SongReference? referenceSong;
  final ColorScheme cs;
  final TextTheme tt;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [cs.primaryContainer, cs.secondaryContainer],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: cs.outline.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: cs.surface.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              Icons.record_voice_over_rounded,
              color: cs.onSurface,
              size: 24,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              referenceSong != null
                  ? '${referenceSong!.trackName} — ${referenceSong!.artistName}'
                  : songTitle,
              style: tt.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: cs.onSurface,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _HintBanner extends StatelessWidget {
  const _HintBanner({
    required this.text,
    required this.color,
    required this.cs,
    required this.tt,
  });

  final String text;
  final Color color;
  final ColorScheme cs;
  final TextTheme tt;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: cs.outline.withValues(alpha: 0.35), width: 1),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _PaceBanner extends StatelessWidget {
  const _PaceBanner({required this.text, required this.cs, required this.tt});

  final String text;
  final ColorScheme cs;
  final TextTheme tt;

  @override
  Widget build(BuildContext context) {
    final isPositive = text.toLowerCase().contains('great');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: isPositive ? cs.secondaryContainer : cs.errorContainer,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: (isPositive ? cs.secondary : cs.error).withValues(alpha: 0.22),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.speed_rounded,
            size: 18,
            color: isPositive ? cs.secondary : cs.error,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: tt.bodyMedium?.copyWith(
                color: cs.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SpeakingLinesDropdown extends StatefulWidget {
  const _SpeakingLinesDropdown({
    required this.targetLyrics,
    required this.isHindiDominant,
    required this.cs,
    required this.tt,
  });

  final String targetLyrics;
  final bool isHindiDominant;
  final ColorScheme cs;
  final TextTheme tt;

  @override
  State<_SpeakingLinesDropdown> createState() => _SpeakingLinesDropdownState();
}

class _SpeakingLinesDropdownState extends State<_SpeakingLinesDropdown> {
  bool _isExpanded = false;
  late final List<String> _speakingLines;
  late ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _speakingLines = _extractFlowPromptLines(
      widget.targetLyrics,
      isHindiDominant: widget.isHindiDominant,
    );
  }

  List<String> _extractFlowPromptLines(
    String lyrics, {
    required bool isHindiDominant,
  }) {
    final raw = lyrics.split('\n');
    final result = <String>[];
    var currentSection = '';
    for (final line in raw) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final lower = trimmed.toLowerCase();
      if (RegExp(r'^\[.+\]').hasMatch(lower)) {
        currentSection = lower.replaceAll(RegExp(r'[\[\]]'), '');
        continue;
      }
      final sectionMatch =
          isHindiDominant
              ? [
                'verse 1',
                'verse 2',
                'verse 3',
                'bridge',
                'pre-chorus',
              ].any((s) => currentSection.contains(s))
              : [
                'chorus',
                'outro',
                'hook',
              ].any((s) => currentSection.contains(s));
      if (sectionMatch && trimmed.length >= 8) {
        result.add(trimmed);
      }
    }
    if (result.isEmpty) {
      return lyrics
          .split('\n')
          .map((l) => l.trim())
          .where(
            (l) =>
                l.isNotEmpty &&
                !l.startsWith('[') &&
                l
                        .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '')
                        .length >=
                    8,
          )
          .toList();
    }
    result.sort((a, b) => a.length.compareTo(b.length));
    final picked = result.where((l) => l.length <= 90).take(4).toList();
    return picked.isNotEmpty ? picked : result.take(3).toList();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_speakingLines.isEmpty) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        color: widget.cs.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: widget.cs.outline.withValues(alpha: 0.55)),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            borderRadius: BorderRadius.circular(22),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: widget.cs.secondaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.mic_rounded,
                      color: widget.cs.secondary,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Your Speaking Lines',
                          style: widget.tt.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_speakingLines.length} lines to record',
                          style: widget.tt.bodySmall?.copyWith(
                            color: widget.cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  AnimatedRotation(
                    turns: _isExpanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      color: widget.cs.onSurface,
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            constraints: BoxConstraints(maxHeight: _isExpanded ? 200 : 0),
            child: ClipRRect(
              child: Container(
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: widget.cs.outline.withValues(alpha: 0.35),
                      width: 1,
                    ),
                  ),
                ),
                child: Scrollbar(
                  controller: _scrollController,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Practice these lines before recording:',
                          style: widget.tt.labelSmall?.copyWith(
                            color: widget.cs.onSurfaceVariant,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ..._speakingLines.map(
                          (line) => Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Row(
                              children: [
                                Text(
                                  '• ',
                                  style: widget.tt.bodyMedium?.copyWith(
                                    color: widget.cs.secondary,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    line,
                                    style: widget.tt.bodyMedium?.copyWith(
                                      color: widget.cs.onSurface,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WaveBar extends StatelessWidget {
  const _WaveBar({
    required this.controller,
    required this.seconds,
    required this.cs,
  });

  final AnimationController controller;
  final int seconds;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: cs.error.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          _PulsingDot(color: cs.error),
          const SizedBox(width: 8),
          Text(
            'REC ${seconds}s / 30s',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: cs.error,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: List.generate(18, (i) {
                return AnimatedBuilder(
                  animation: controller,
                  builder: (_, __) {
                    final h =
                        4.0 +
                        22.0 *
                            (0.3 + 0.7 * ((controller.value + i * 0.12) % 1.0));
                    return Container(
                      width: 3,
                      height: h,
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(
                        color: cs.error.withValues(alpha: 0.75),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    );
                  },
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.color});

  final Color color;

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder:
          (_, __) => Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: widget.color.withValues(alpha: 0.4 + 0.6 * _c.value),
              shape: BoxShape.circle,
            ),
          ),
    );
  }
}

class _KaraokeBox extends StatelessWidget {
  const _KaraokeBox({
    required this.flowLines,
    required this.lineWordStart,
    required this.currentWord,
    required this.currentLine,
    required this.activeLineProgress,
    required this.targetWpm,
    required this.referenceMsPerWord,
    required this.splitWords,
    required this.cs,
    required this.tt,
  });

  final List<String> flowLines;
  final List<int> lineWordStart;
  final int currentWord;
  final int currentLine;
  final double activeLineProgress;
  final int targetWpm;
  final int? referenceMsPerWord;
  final List<String> Function(String) splitWords;
  final ColorScheme cs;
  final TextTheme tt;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: cs.outline.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            referenceMsPerWord != null
                ? 'Karaoke Guide (Reference Tempo)'
                : 'Karaoke Guide ($targetWpm WPM)',
            style: tt.labelSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          ...List.generate(flowLines.length, (i) {
            final line = flowLines[i];
            final lineWords = splitWords(line);
            final start = i < lineWordStart.length ? lineWordStart[i] : 0;
            final currentInLine = currentWord - start;
            final activeLine = i == currentLine;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (activeLine) ...[
                    LayoutBuilder(
                      builder: (ctx, c) {
                        final width = c.maxWidth.clamp(1.0, 9999.0);
                        final dotX = (width * activeLineProgress).clamp(
                          0.0,
                          width - 6,
                        );
                        return SizedBox(
                          height: 10,
                          child: Stack(
                            children: [
                              Positioned(
                                left: 0,
                                right: 0,
                                top: 4,
                                child: Container(
                                  height: 2,
                                  decoration: BoxDecoration(
                                    color: cs.secondary.withValues(alpha: 0.25),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),
                              AnimatedPositioned(
                                duration: const Duration(milliseconds: 120),
                                curve: Curves.easeOut,
                                left: dotX,
                                top: 0,
                                child: Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    color: cs.secondary,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 4),
                  ],
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: List.generate(lineWords.length, (wi) {
                      final isPast = activeLine && wi < currentInLine;
                      final isCurrent = activeLine && wi == currentInLine;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 100),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color:
                              isCurrent
                                  ? cs.secondary
                                  : isPast
                                  ? cs.secondaryContainer
                                  : Colors.transparent,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          lineWords[wi],
                          style: tt.bodyMedium?.copyWith(
                            color:
                                isCurrent
                                    ? cs.onSecondary
                                    : isPast
                                    ? cs.onSurface
                                    : cs.onSurfaceVariant,
                            fontWeight:
                                isCurrent ? FontWeight.w700 : FontWeight.normal,
                          ),
                        ),
                      );
                    }),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}
