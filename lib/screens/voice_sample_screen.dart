import 'dart:async';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import '../models/song_reference.dart';
import '../services/bpm_service.dart';
import '../services/lyrics_service.dart';
import '../theme/pixel_theme.dart';
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
  late ScrollController _scrollController; // ← Changed to late
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
    _scrollController = ScrollController(); // ← Initialize here
    _prepareRecordingAssets();
    _fetchReferenceTempo();
  }

  void _prepareRecordingAssets() {
    final isHindiDominant =
        widget.dominantLanguage.toLowerCase().contains('hindi');
    _targetLyrics = isHindiDominant
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
        final matches =
            await _lyricsService.search('${ref.trackName} ${ref.artistName}');
        for (final m in matches.take(5)) {
          final synced = m.syncedLyrics;
          if (synced != null && synced.isNotEmpty) {
            final ms =
                LyricsService.computeMsPerWordFromSyncedLyrics(synced);
            if (ms != null && mounted) {
              setState(() => _referenceMsPerWord = ms);
              return;
            }
          }
          final full = await _lyricsService.getById(m.id);
          if (full?.syncedLyrics != null &&
              full!.syncedLyrics!.isNotEmpty) {
            final ms = LyricsService.computeMsPerWordFromSyncedLyrics(
                full.syncedLyrics);
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
    _scrollController.dispose(); // ← Dispose controller
    super.dispose();
  }

  Future<void> _showMicSettingsDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          '[ MIC PERMISSION ]',
          style: PixelFonts.pressStart(size: 7, color: PixelColors.green),
        ),
        content: Text(
          'Microphone is off.\nEnable it in Settings.',
          style: PixelFonts.vt323(size: 16, color: PixelColors.textPrimary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('CANCEL',
                style: PixelFonts.pressStart(
                    size: 6, color: PixelColors.muted)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await openAppSettings();
            },
            child: Text('OPEN SETTINGS',
                style: PixelFonts.pressStart(
                    size: 6, color: PixelColors.green)),
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
      final targetWpm = _referenceMsPerWord != null
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
        content: Text(msg, style: PixelFonts.vt323(size: 14)),
        behavior: SnackBarBehavior.floating,
        shape:
            const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      ),
    );
  }

  // ── Lyrics helpers ─────────────────────────────────────────────────────────
  static const _hindiSections = [
    'verse 1',
    'verse 2',
    'verse 3',
    'bridge',
    'pre-chorus'
  ];
  static const _englishSections = ['chorus', 'outro', 'hook'];

  List<String> _linesForDominantLanguage(
      String lyrics, bool isHindiDominant) {
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
      final sectionMatch = isHindiDominant
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
        .where((l) =>
            l.isNotEmpty &&
            !l.startsWith('[') &&
            l
                .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '')
                .length >=
                8)
        .toList();
  }

  List<String> _extractFlowPromptLines(String lyrics,
      {required bool isHindiDominant}) {
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
        .map((l) =>
            l.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length)
        .fold<int>(0, (a, b) => a + b);
    final avgWordsPerLine = words / lines.take(10).length;
    return (avgWordsPerLine * 18).round().clamp(90, 150);
  }

  List<String> _splitWords(String line) =>
      line.split(RegExp(r'\s+')).where((w) => w.trim().isNotEmpty).toList();

  void _startKaraokeGuide(
      {required List<String> flowLines, required int targetWpm}) {
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
      final msPerWord = _referenceMsPerWord ??
          (60000 / _karaokeTargetWpm).round().clamp(220, 900);
      final rawIndex =
          (_karaokeWatch.elapsedMilliseconds / msPerWord).floor();
      final safeIndex = rawIndex.clamp(0, _karaokeWords.length - 1);
      if (safeIndex == _karaokeCurrentWord) return;
      var lineIndex = 0;
      for (var i = 0; i < _karaokeLineWordStart.length; i++) {
        final start = _karaokeLineWordStart[i];
        final next = i + 1 < _karaokeLineWordStart.length
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
        final lineStart = lineIndex < _karaokeLineWordStart.length
            ? _karaokeLineWordStart[lineIndex]
            : 0;
        final lineEnd = lineIndex + 1 < _karaokeLineWordStart.length
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
    if (ratio < 0.85) return 'TOO FAST — slow down to stay on beat.';
    if (ratio > 1.2) return 'TOO SLOW — tighten delivery to match flow.';
    return 'GREAT PACING — close to target flow.';
  }

  // ───────────────────────────────────────────────────────────────────────────
  // BUILD
  // ───────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final hasRecording = _recordedPath != null;
    final isShort = _recordingSeconds < 5 && hasRecording;
    final isHindiDominant =
        widget.dominantLanguage.toLowerCase().contains('hindi');
    final targetLyrics = _targetLyrics;

    return Scaffold(
      backgroundColor: PixelColors.bg,
      appBar: AppBar(
        title: Text(
          '// RECORD VOICE //',
          style: PixelFonts.pressStart(size: 7, color: PixelColors.green),
        ),
        centerTitle: true,
        backgroundColor: PixelColors.card,
        foregroundColor: PixelColors.green,
        elevation: 0,
        shape: const Border(
          bottom: BorderSide(color: PixelColors.green, width: 2),
        ),
      ),
      // ── Replace the entire body: property in your build() method with this ──────

      body: SafeArea(
        child: Column(
          children: [
            // ── Scrollable content fills remaining space ─────────────────
            if (hasRecording && !_isRecording)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _PixelInfoCard(
                        songTitle: widget.songTitle,
                        referenceSong: widget.referenceSong,
                      ),
                      const SizedBox(height: 16),
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: PixelColors.card,
                            border:
                                Border.all(color: PixelColors.blue, width: 2),
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0xFF1A5A99),
                                offset: Offset(3, 3),
                                blurRadius: 0,
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 10),
                                child: Row(
                                  children: [
                                    const Icon(Icons.lyrics_outlined,
                                        size: 13, color: PixelColors.blue),
                                    const SizedBox(width: 6),
                                    Text(
                                      'GENERATED LYRICS',
                                      style: PixelFonts.pressStart(
                                          size: 5, color: PixelColors.blue),
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                height: 1,
                                color: PixelColors.blue.withValues(alpha: 0.3),
                              ),
                              Expanded(
                                child: Scrollbar(
                                  controller: _scrollController,
                                  thumbVisibility: true,
                                  child: SingleChildScrollView(
                                    controller: _scrollController,
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        ..._getAllLyricsLines(targetLyrics).map(
                                          (line) => Padding(
                                            padding:
                                                const EdgeInsets.only(bottom: 6),
                                            child: Text(
                                              line.startsWith('[')
                                                  ? line
                                                  : '  $line',
                                              style: PixelFonts.vt323(
                                                size: line.startsWith('[')
                                                    ? 14
                                                    : 15,
                                                color: line.startsWith('[')
                                                    ? PixelColors.blue
                                                    : PixelColors.textPrimary,
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
              )
            else
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // ── Info card ──────────────────────────────────────────
                      _PixelInfoCard(
                        songTitle: widget.songTitle,
                        referenceSong: widget.referenceSong,
                      ),
                      const SizedBox(height: 16),
                      // ── Before recording ────────────────────────────────────
                      if (!_isRecording && !hasRecording) ...[
                        const _HintBanner(
                          text:
                              'Record yourself reading the lyrics aloud (10-15 seconds)',
                          color: PixelColors.blue,
                        ),
                        const SizedBox(height: 12),
                        _SpeakingLinesDropdown(
                          targetLyrics: targetLyrics,
                          isHindiDominant: isHindiDominant,
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            PixelLabel('LYRICS TO RECORD:'),
                            const Spacer(),
                            TextButton.icon(
                              onPressed: () {
                                setState(
                                    () => _showFullLyrics = !_showFullLyrics);
                              },
                              icon: AnimatedRotation(
                                turns: _showFullLyrics ? 0.5 : 0,
                                duration: const Duration(milliseconds: 200),
                                child: const Icon(
                                  Icons.keyboard_arrow_down,
                                  size: 20,
                                  color: PixelColors.blue,
                                ),
                              ),
                              label: Text(
                                _showFullLyrics ? 'HIDE' : 'SHOW',
                                style: PixelFonts.pressStart(
                                    size: 8, color: PixelColors.blue),
                              ),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                          constraints: BoxConstraints(
                            maxHeight: _showFullLyrics ? 300 : 0,
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              decoration: BoxDecoration(
                                color: PixelColors.card,
                                border: Border.all(
                                    color: PixelColors.blue, width: 2),
                              ),
                              child: Scrollbar(
                                controller: _scrollController,
                                thumbVisibility: true,
                                child: SingleChildScrollView(
                                  controller: _scrollController,
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      ..._getAllLyricsLines(targetLyrics).map(
                                        (line) => Padding(
                                          padding:
                                              const EdgeInsets.only(bottom: 6),
                                          child: Text(
                                            line.startsWith('[')
                                                ? line
                                                : '  $line',
                                            style: PixelFonts.vt323(
                                              size:
                                                  line.startsWith('[') ? 14 : 15,
                                              color: line.startsWith('[')
                                                  ? PixelColors.blue
                                                  : PixelColors.textPrimary,
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
                      // ── During recording: Wave + Karaoke guide ─────────────
                      if (_isRecording) ...[
                        _PixelWaveBar(
                          controller: _waveController,
                          seconds: _recordingSeconds,
                        ),
                        const SizedBox(height: 16),
                        if (_karaokeFlowLines.isNotEmpty) ...[
                          Text(
                            'Follow the highlighted words',
                            style: PixelFonts.pressStart(
                                size: 5, color: PixelColors.green),
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
                          ),
                        ],
                        const SizedBox(height: 20),
                      ],
                    ],
                  ),
                ),
              ),

            // ── Bottom panel always pinned to bottom ──────────────────────
            Container(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              color: PixelColors.bg,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── Post-recording section ───────────────────────────────
                  if (hasRecording && !_isRecording) ...[

                    // ── Speaking lines review card ─────────────────────────
                    if (_karaokeFlowLines.isNotEmpty) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: PixelColors.card,
                          border: Border.all(color: PixelColors.green, width: 2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.article_outlined,
                                    size: 13, color: PixelColors.green),
                                const SizedBox(width: 6),
                                Text(
                                  'LINES YOU RECORDED',
                                  style: PixelFonts.pressStart(
                                      size: 5, color: PixelColors.green),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            ..._karaokeFlowLines.map(
                              (line) => Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('›  ',
                                        style: PixelFonts.vt323(
                                            size: 15,
                                            color: PixelColors.green)),
                                    Expanded(
                                      child: Text(
                                        line,
                                        style: PixelFonts.vt323(
                                            size: 15,
                                            color: PixelColors.textPrimary),
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

                    // ── Pace feedback ──────────────────────────────────────
                    if ((_paceFeedback ?? '').isNotEmpty) ...[
                      _PaceBanner(text: _paceFeedback!),
                      const SizedBox(height: 8),
                    ],

                    // ── Playback row + too-short warning ───────────────────
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _playback,
                            style: OutlinedButton.styleFrom(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(28)),
                              side: BorderSide(
                                color: _isPlaying
                                    ? PixelColors.red
                                    : PixelColors.muted,
                                width: 2,
                              ),
                            ),
                            icon: Icon(
                              _isPlaying
                                  ? Icons.stop_rounded
                                  : Icons.play_arrow_rounded,
                              color: _isPlaying
                                  ? PixelColors.red
                                  : PixelColors.muted,
                              size: 16,
                            ),
                            label: Text(
                              _isPlaying ? 'STOP' : 'PLAY',
                              style: PixelFonts.pressStart(
                                size: 6,
                                color: _isPlaying
                                    ? PixelColors.red
                                    : PixelColors.muted,
                              ),
                            ),
                          ),
                        ),
                        if (isShort) ...[
                          const SizedBox(width: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF2A0D12),
                              borderRadius: BorderRadius.circular(28),
                              border: Border.all(
                                  color: PixelColors.red, width: 2),
                            ),
                            child: Row(children: [
                              const Icon(Icons.warning_amber_rounded,
                                  size: 14, color: PixelColors.red),
                              const SizedBox(width: 6),
                              Text('Too short',
                                  style: PixelFonts.vt323(
                                      size: 13, color: PixelColors.red)),
                            ]),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),

                    // ── USE THIS RECORDING — same style as RE-RECORD ────────
                    SizedBox(
                      height: 56,
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => VoiceSongScreen(
                                songTitle: widget.songTitle,
                                hindiLyrics: widget.hindiLyrics,
                                englishLyrics: widget.englishLyrics,
                                hinglishLyrics: widget.hinglishLyrics,
                                dominantLanguage: widget.dominantLanguage,
                                mood: widget.mood,
                                genre: widget.genre,
                                referenceSong: widget.referenceSong,
                                voiceSamplePath: _recordedPath!,
                              ),
                            ),
                          );
                        },
                        style: FilledButton.styleFrom(
                          backgroundColor: PixelColors.purple,
                          foregroundColor: PixelColors.bg,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(28)),
                          side: const BorderSide(
                              color: PixelColors.purpleDim, width: 2),
                          elevation: 0,
                        ),
                        icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                        label: Text(
                          'USE THIS RECORDING',
                          style: PixelFonts.pressStart(
                              size: 7, color: PixelColors.bg),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],

                  // ── Record / Stop button (always at very bottom) ──────────
                  _isRecording
                      ? PixelStopButton(
                          label: 'STOP  (${_recordingSeconds}s)',
                          onPressed: _stopRecording,
                        )
                      : SizedBox(
                          height: 56,
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _startRecording,
                            style: FilledButton.styleFrom(
                              backgroundColor: PixelColors.green,
                              foregroundColor: PixelColors.bg,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(28)),
                              side: const BorderSide(
                                  color: PixelColors.greenDim, width: 2),
                              elevation: 0,
                            ),
                            icon: const Icon(Icons.mic_rounded, size: 18),
                            label: Text(
                              hasRecording ? 'RE-RECORD' : 'START RECORDING',
                              style: PixelFonts.pressStart(
                                  size: 7, color: PixelColors.bg),
                            ),
                          ),
                        ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PRIVATE SUB-WIDGETS
// ─────────────────────────────────────────────────────────────────────────────

class _PixelInfoCard extends StatelessWidget {
  const _PixelInfoCard(
      {required this.songTitle, required this.referenceSong});

  final String songTitle;
  final SongReference? referenceSong;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: PixelColors.card,
        border: Border.all(color: PixelColors.purple, width: 2),
        boxShadow: const [
          BoxShadow(
              color: PixelColors.purpleDim, offset: Offset(3, 3), blurRadius: 0),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: PixelColors.purple,
              border: Border.all(color: const Color(0xFFD0AAFF), width: 1),
            ),
            child: const Icon(Icons.record_voice_over_rounded,
                color: PixelColors.bg, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              referenceSong != null
                  ? '${referenceSong!.trackName} — ${referenceSong!.artistName}'
                  : songTitle,
              style: PixelFonts.vt323(
                  size: 16, color: const Color(0xFFD0AAFF)),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _HintBanner extends StatelessWidget {
  const _HintBanner({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: PixelColors.card2,
        border: Border(
          left: BorderSide(color: color, width: 3),
          top: BorderSide(color: color.withValues(alpha: 0.3), width: 1),
          right: BorderSide(color: color.withValues(alpha: 0.3), width: 1),
          bottom: BorderSide(color: color.withValues(alpha: 0.3), width: 1),
        ),
      ),
      child: Text(text, style: PixelFonts.vt323(size: 14, color: color)),
    );
  }
}

class _PaceBanner extends StatelessWidget {
  const _PaceBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: const BoxDecoration(
        color: PixelColors.card2,
        border: Border(
          left: BorderSide(color: PixelColors.green, width: 3),
          top: BorderSide(color: PixelColors.green, width: 1),
          right: BorderSide(color: PixelColors.green, width: 1),
          bottom: BorderSide(color: PixelColors.green, width: 1),
        ),
      ),
      child: Row(children: [
        const Icon(Icons.speed_rounded, size: 14, color: PixelColors.green),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              style: PixelFonts.vt323(size: 14, color: PixelColors.green)),
        ),
      ]),
    );
  }
}

class _SpeakingLinesDropdown extends StatefulWidget {
  const _SpeakingLinesDropdown({
    required this.targetLyrics,
    required this.isHindiDominant,
  });

  final String targetLyrics;
  final bool isHindiDominant;

  @override
  State<_SpeakingLinesDropdown> createState() => _SpeakingLinesDropdownState();
}

class _SpeakingLinesDropdownState extends State<_SpeakingLinesDropdown> {
  bool _isExpanded = false;
  late final List<String> _speakingLines;
  late ScrollController _scrollController; // ← Changed to late

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController(); // ← Initialize here
    _speakingLines = _extractFlowPromptLines(
      widget.targetLyrics,
      isHindiDominant: widget.isHindiDominant,
    );
  }

  List<String> _extractFlowPromptLines(String lyrics,
      {required bool isHindiDominant}) {
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
      final sectionMatch = isHindiDominant
          ? [
              'verse 1',
              'verse 2',
              'verse 3',
              'bridge',
              'pre-chorus'
            ].any((s) => currentSection.contains(s))
          : ['chorus', 'outro', 'hook']
              .any((s) => currentSection.contains(s));
      if (sectionMatch && trimmed.length >= 8) {
        result.add(trimmed);
      }
    }
    if (result.isEmpty) {
      return lyrics
          .split('\n')
          .map((l) => l.trim())
          .where((l) =>
              l.isNotEmpty &&
              !l.startsWith('[') &&
              l
                  .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '')
                  .length >=
                  8)
          .toList();
    }
    result.sort((a, b) => a.length.compareTo(b.length));
    final picked = result.where((l) => l.length <= 90).take(4).toList();
    return picked.isNotEmpty ? picked : result.take(3).toList();
  }

  @override
  void dispose() {
    _scrollController.dispose(); // ← Dispose controller
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_speakingLines.isEmpty) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        color: PixelColors.card,
        border: Border.all(color: PixelColors.green, width: 2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: PixelColors.green,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Icon(Icons.mic_rounded,
                        color: PixelColors.bg, size: 16),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'YOUR SPEAKING LINES',
                          style: PixelFonts.pressStart(
                              size: 6, color: PixelColors.green),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_speakingLines.length} lines to record',
                          style: PixelFonts.vt323(
                              size: 12, color: PixelColors.muted),
                        ),
                      ],
                    ),
                  ),
                  AnimatedRotation(
                    turns: _isExpanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      color: PixelColors.green,
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
                        color: PixelColors.green.withValues(alpha: 0.3),
                        width: 1),
                  ),
                ),
                child: Scrollbar(
                  controller: _scrollController, // ← Fixed
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _scrollController, // ← Fixed
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '🎤 Practice these lines before recording:',
                          style: PixelFonts.pressStart(
                              size: 5, color: PixelColors.green),
                        ),
                        const SizedBox(height: 8),
                        ..._speakingLines.map(
                          (line) => Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Row(
                              children: [
                                Text('• ',
                                    style: PixelFonts.vt323(
                                        size: 14, color: PixelColors.green)),
                                Expanded(
                                  child: Text(
                                    line,
                                    style: PixelFonts.vt323(
                                        size: 14,
                                        color: PixelColors.textPrimary),
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

class _PixelWaveBar extends StatelessWidget {
  const _PixelWaveBar(
      {required this.controller, required this.seconds});

  final AnimationController controller;
  final int seconds;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF2A0D12),
        border: Border.all(color: PixelColors.red, width: 2),
      ),
      child: Row(children: [
        const _PulsingDot(),
        const SizedBox(width: 8),
        Text('REC ${seconds}s / 30s',
            style: PixelFonts.pressStart(size: 6, color: PixelColors.red)),
        const SizedBox(width: 10),
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: List.generate(18, (i) {
              return AnimatedBuilder(
                animation: controller,
                builder: (_, __) {
                  final h = 4.0 +
                      22.0 *
                          (0.3 +
                              0.7 *
                                  ((controller.value + i * 0.12) % 1.0));
                  return Container(
                    width: 3,
                    height: h,
                    margin: const EdgeInsets.symmetric(horizontal: 1),
                    color: PixelColors.red.withValues(alpha: 0.75),
                  );
                },
              );
            }),
          ),
        ),
      ]),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

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
            vsync: this, duration: const Duration(milliseconds: 600))
      ..repeat(reverse: true);
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
      builder: (_, __) => Container(
        width: 8,
        height: 8,
        color: PixelColors.red.withValues(alpha: 0.4 + 0.6 * _c.value),
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
  });

  final List<String> flowLines;
  final List<int> lineWordStart;
  final int currentWord;
  final int currentLine;
  final double activeLineProgress;
  final int targetWpm;
  final int? referenceMsPerWord;
  final List<String> Function(String) splitWords;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: PixelColors.card,
        border: Border.all(color: PixelColors.blue, width: 2),
        boxShadow: const [
          BoxShadow(
              color: Color(0xFF1A5A99), offset: Offset(3, 3), blurRadius: 0),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            referenceMsPerWord != null
                ? '> KARAOKE GUIDE (REF TEMPO)'
                : '> KARAOKE GUIDE ($targetWpm WPM)',
            style: PixelFonts.pressStart(
                size: 5, color: PixelColors.blue, letterSpacing: 1),
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
                    LayoutBuilder(builder: (ctx, c) {
                      final width = c.maxWidth.clamp(1.0, 9999.0);
                      final dotX = (width * activeLineProgress)
                          .clamp(0.0, width - 6);
                      return SizedBox(
                        height: 10,
                        child: Stack(children: [
                          Positioned(
                            left: 0,
                            right: 0,
                            top: 4,
                            child: Container(
                              height: 2,
                              color: PixelColors.blue.withValues(alpha: 0.25),
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
                              color: PixelColors.blue,
                            ),
                          ),
                        ]),
                      );
                    }),
                    const SizedBox(height: 4),
                  ],
                  Wrap(
                    spacing: 3,
                    runSpacing: 4,
                    children: List.generate(lineWords.length, (wi) {
                      final isPast = activeLine && wi < currentInLine;
                      final isCurrent = activeLine && wi == currentInLine;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 100),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        color: isCurrent
                            ? PixelColors.blue
                            : isPast
                                ? PixelColors.blue.withValues(alpha: 0.15)
                                : Colors.transparent,
                        child: Text(
                          lineWords[wi],
                          style: PixelFonts.vt323(
                            size: 15,
                            color: isCurrent
                                ? PixelColors.bg
                                : isPast
                                    ? PixelColors.blue
                                    : PixelColors.muted,
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