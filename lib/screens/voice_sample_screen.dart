import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import '../models/song_reference.dart';
import '../services/bpm_service.dart';
import '../services/lyrics_service.dart';
import '../widgets/song_flow_timeline.dart';
import 'voice_song_screen.dart';

// ─── HOME SCREEN PALETTE ──────────────────────────────────────────────────────
class _HP {
  static const background = Color(0xFFF5F3EF);
  static const card = Color(0xFFF0EDE7);
  static const border = Color(0xFFD8D4CC);
  static const black = Color(0xFF111111);
  static const blackSoft = Color(0xFF1E1E1E);
  static const grey1 = Color(0xFF444444);
  static const grey2 = Color(0xFF666666);
  static const grey3 = Color(0xFF888888);
  static const grey4 = Color(0xFFAAAAAA);
  static const chip = Color(0xFFE8E3DC);
  static const chipDark = Color(0xFFD8D4CC);
  static const green = Color(0xFF11F08A);
  static const red = Color(0xFFFF3B30);
  static const redSoft = Color(0xFFFFF0EE);
  static const redBorder = Color(0xFFFFCCCC);
}

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
  final _lyricsService = LyricsService();
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

  late final String _cloneLanguage;
  late final bool _isHindiDominant;
  late final String _targetLyrics;
  late final List<String> _preparedFlowPromptLines;
  late final int _fallbackTargetWpm;
  late AnimationController _waveController;

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
    _isHindiDominant = widget.dominantLanguage.toLowerCase().contains('hindi');
    _cloneLanguage = _isHindiDominant ? 'Hindi' : 'English';
    _targetLyrics =
        _isHindiDominant
            ? (widget.hinglishLyrics?.isNotEmpty == true
                ? widget.hinglishLyrics!
                : widget.hindiLyrics)
            : widget.englishLyrics;
    _preparedFlowPromptLines = _extractFlowPromptLines(
      _targetLyrics,
      isHindiDominant: _isHindiDominant,
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

  // ── Permissions ────────────────────────────────────────────────────────────
  Future<void> _showMicSettingsDialog() async {
    await showDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: _HP.card,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: const Row(
              children: [
                Icon(Icons.mic_off_rounded, color: _HP.red, size: 20),
                SizedBox(width: 8),
                Text(
                  'Microphone Required',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                    color: _HP.black,
                  ),
                ),
              ],
            ),
            content: const Text(
              'Microphone access is disabled. Please enable it in Settings to continue recording.',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: _HP.grey1,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text(
                  'Cancel',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.w700,
                    color: _HP.grey2,
                  ),
                ),
              ),
              GestureDetector(
                onTap: () async {
                  Navigator.of(ctx).pop();
                  await openAppSettings();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: _HP.black,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'Open Settings',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
    );
  }

  // ── Recording ──────────────────────────────────────────────────────────────
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
      if (mounted)
        setState(() {
          _isRecording = true;
          _recordedPath = null;
          _paceFeedback = null;
        });
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
      if (mounted) setState(() => _isRecording = false);
      _showSnack('Recording failed: $e');
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
      _showSnack('Stop failed: $e');
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
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            msg,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: Colors.white,
            ),
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: _HP.black,
          elevation: 0,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  Future<void> _startVoiceCloneFlow() async {
    final recordedPath = _recordedPath;
    if (recordedPath == null) return;
    await HapticFeedback.mediumImpact();
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder:
            (_) => VoiceSongScreen(
              songTitle: widget.songTitle,
              hindiLyrics: widget.hindiLyrics,
              englishLyrics: widget.englishLyrics,
              hinglishLyrics: widget.hinglishLyrics,
              dominantLanguage: _cloneLanguage,
              mood: widget.mood,
              genre: widget.genre,
              referenceSong: widget.referenceSong,
              voiceSamplePath: recordedPath,
            ),
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

  List<String> _linesForDominantLanguage(String lyrics, bool isHindi) {
    final raw = lyrics.split('\n');
    final result = <String>[];
    var section = '';
    for (final line in raw) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final lower = t.toLowerCase();
      if (RegExp(r'^\[.+\]').hasMatch(lower)) {
        section = lower.replaceAll(RegExp(r'[\[\]]'), '');
        continue;
      }
      final match =
          isHindi
              ? _hindiSections.any((s) => section.contains(s))
              : _englishSections.any((s) => section.contains(s));
      if (match && t.length >= 8) result.add(t);
    }
    if (result.isEmpty) return _cleanSingableLines(lyrics);
    return result;
  }

  List<String> _cleanSingableLines(String lyrics) =>
      lyrics
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
    var section = '';
    for (final line in raw) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final lower = t.toLowerCase();
      if (RegExp(r'^\[.+\]').hasMatch(lower)) {
        section = lower.replaceAll(RegExp(r'[\[\]]'), '');
        result.add(t);
        continue;
      }
      final match =
          _hindiSections.any((s) => section.contains(s)) ||
          _englishSections.any((s) => section.contains(s));
      if ((match && t.length >= 8) || t.length >= 5) result.add(t);
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
    return ((words / lines.take(10).length) * 18).round().clamp(90, 150);
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
        final lineCount = (lineEnd - lineStart).clamp(1, 9999);
        _activeLineProgress = ((safeIndex - lineStart) + 1) / lineCount;
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
    if (ratio > 1.20) return 'Too slow — tighten delivery to match flow.';
    return 'Great pacing — close to target flow.';
  }

  // ── BUILD ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final sw = mq.size.width;
    final hPad = sw < 600 ? sw * 0.05 : sw * 0.08;

    final hasRecording = _recordedPath != null;
    final isShort = _recordingSeconds < 5 && hasRecording;

    return Scaffold(
      backgroundColor: _HP.background,
      body: SafeArea(
        child: Column(
          children: [
            // ── Top bar ───────────────────────────────────────────────────
            Padding(
              padding: EdgeInsets.fromLTRB(hPad, 16, hPad, 12),
              child: _TopBar(
                hPad: hPad,
                songTitle: widget.songTitle,
                referenceSong: widget.referenceSong,
              ),
            ),

            // ── Scrollable body ───────────────────────────────────────────
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Pre-record: hint + lyrics preview
                    if (!_isRecording && !hasRecording) ...[
                      _HintCard(
                        text:
                            'Record yourself reading the lyrics aloud for 10–15 seconds.',
                      ),
                      const SizedBox(height: 14),
                      _SpeakingLinesCard(
                        targetLyrics: _targetLyrics,
                        isHindiDominant: _isHindiDominant,
                      ),
                      const SizedBox(height: 14),
                      _LyricsCard(
                        lines: _getAllLyricsLines(_targetLyrics),
                        scrollController: _scrollController,
                        showFull: _showFullLyrics,
                        onToggle:
                            () => setState(
                              () => _showFullLyrics = !_showFullLyrics,
                            ),
                      ),
                      const SizedBox(height: 20),
                    ],

                    // Recording: wave bar + karaoke
                    if (_isRecording) ...[
                      _WaveBar(
                        controller: _waveController,
                        seconds: _recordingSeconds,
                      ),
                      const SizedBox(height: 16),
                      if (_karaokeFlowLines.isNotEmpty) ...[
                        const Text(
                          'Follow the highlighted words',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: _HP.grey1,
                          ),
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
                        const SizedBox(height: 20),
                      ],
                    ],

                    // Post-record: lyrics display
                    if (hasRecording && !_isRecording) ...[
                      _LyricsCard(
                        lines: _getAllLyricsLines(_targetLyrics),
                        scrollController: _scrollController,
                        showFull: _showFullLyrics,
                        onToggle:
                            () => setState(
                              () => _showFullLyrics = !_showFullLyrics,
                            ),
                      ),
                      const SizedBox(height: 16),
                    ],
                  ],
                ),
              ),
            ),

            // ── Bottom action bar ─────────────────────────────────────────
            Container(
              padding: EdgeInsets.fromLTRB(hPad, 14, hPad, 22),
              decoration: const BoxDecoration(
                color: _HP.background,
                border: Border(top: BorderSide(color: _HP.border)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Recorded flow lines summary
                  if (hasRecording &&
                      !_isRecording &&
                      _karaokeFlowLines.isNotEmpty) ...[
                    _RecordedLinesCard(lines: _karaokeFlowLines),
                    const SizedBox(height: 10),
                  ],

                  // Pace feedback
                  if ((_paceFeedback ?? '').isNotEmpty && !_isRecording) ...[
                    _PaceBanner(text: _paceFeedback!),
                    const SizedBox(height: 10),
                  ],

                  // Playback row (after recording)
                  if (hasRecording && !_isRecording) ...[
                    Row(
                      children: [
                        Expanded(
                          child: _OutlineButton(
                            icon:
                                _isPlaying
                                    ? Icons.stop_rounded
                                    : Icons.play_arrow_rounded,
                            label: _isPlaying ? 'Stop' : 'Play Recording',
                            onPressed: _playback,
                          ),
                        ),
                        if (isShort) ...[
                          const SizedBox(width: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: _HP.redSoft,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: _HP.redBorder),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.warning_amber_rounded,
                                  size: 14,
                                  color: _HP.red,
                                ),
                                SizedBox(width: 5),
                                Text(
                                  'Too short',
                                  style: TextStyle(
                                    fontFamily: 'Inter',
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: _HP.red,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 10),
                    // Slide to clone
                    _SlideToCloneButton(onCompleted: _startVoiceCloneFlow),
                    const SizedBox(height: 10),
                  ],

                  // Stop / Record / Re-record button
                  if (_isRecording)
                    _RedButton(
                      label: 'Stop (${_recordingSeconds}s)',
                      icon: Icons.stop_rounded,
                      onPressed: _stopRecording,
                    )
                  else
                    _PrimaryButton(
                      label: hasRecording ? 'Re-record' : 'Start Recording',
                      icon: Icons.mic_rounded,
                      filled: !hasRecording,
                      onPressed: _startRecording,
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
// TOP BAR
// ─────────────────────────────────────────────────────────────────────────────
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.hPad,
    required this.songTitle,
    required this.referenceSong,
  });
  final double hPad;
  final String songTitle;
  final SongReference? referenceSong;

  @override
  Widget build(BuildContext context) {
    final displayTitle =
        referenceSong != null
            ? '${referenceSong!.trackName} — ${referenceSong!.artistName}'
            : songTitle;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SongFlowTimeline(currentStep: 2),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () => Navigator.of(context).maybePop(),
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: _HP.chip,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _HP.border),
                ),
                child: const Icon(
                  Icons.arrow_back_rounded,
                  size: 20,
                  color: _HP.black,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Record your voice',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      color: _HP.black,
                      height: 1.05,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Read a short sample clearly for your voice clone.',
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: _HP.grey2,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: _HP.chip,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _HP.border),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.music_note_rounded,
                          size: 12,
                          color: _HP.grey2,
                        ),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            displayTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: _HP.grey1,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// HINT CARD
// ─────────────────────────────────────────────────────────────────────────────
class _HintCard extends StatelessWidget {
  const _HintCard({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: _HP.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _HP.border),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded, size: 16, color: _HP.grey3),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: _HP.grey1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SPEAKING LINES CARD (expandable)
// ─────────────────────────────────────────────────────────────────────────────
class _SpeakingLinesCard extends StatefulWidget {
  const _SpeakingLinesCard({
    required this.targetLyrics,
    required this.isHindiDominant,
  });
  final String targetLyrics;
  final bool isHindiDominant;

  @override
  State<_SpeakingLinesCard> createState() => _SpeakingLinesCardState();
}

class _SpeakingLinesCardState extends State<_SpeakingLinesCard> {
  bool _expanded = false;
  late final List<String> _lines;
  final _sc = ScrollController();

  @override
  void initState() {
    super.initState();
    _lines = _extract(widget.targetLyrics, widget.isHindiDominant);
  }

  List<String> _extract(String lyrics, bool isHindi) {
    final raw = lyrics.split('\n');
    final result = <String>[];
    var section = '';
    for (final line in raw) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final lower = t.toLowerCase();
      if (RegExp(r'^\[.+\]').hasMatch(lower)) {
        section = lower.replaceAll(RegExp(r'[\[\]]'), '');
        continue;
      }
      final match =
          isHindi
              ? [
                'verse 1',
                'verse 2',
                'verse 3',
                'bridge',
                'pre-chorus',
              ].any((s) => section.contains(s))
              : ['chorus', 'outro', 'hook'].any((s) => section.contains(s));
      if (match && t.length >= 8) result.add(t);
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
    _sc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_lines.isEmpty) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        color: _HP.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _HP.border),
      ),
      child: Column(
        children: [
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: _HP.black,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.mic_rounded,
                      size: 16,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Your Speaking Lines',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: _HP.black,
                          ),
                        ),
                        Text(
                          '${_lines.length} lines to record',
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: _HP.grey3,
                          ),
                        ),
                      ],
                    ),
                  ),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: _HP.grey2,
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeInOut,
            constraints: BoxConstraints(maxHeight: _expanded ? 200 : 0),
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(18),
              ),
              child: Container(
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: _HP.border)),
                ),
                child: Scrollbar(
                  controller: _sc,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _sc,
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Practice these before recording:',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: _HP.grey3,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ..._lines.map(
                          (line) => Padding(
                            padding: const EdgeInsets.only(bottom: 7),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '›  ',
                                  style: TextStyle(
                                    fontFamily: 'Inter',
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: _HP.grey3,
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    line,
                                    style: const TextStyle(
                                      fontFamily: 'Inter',
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                      color: _HP.grey1,
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

// ─────────────────────────────────────────────────────────────────────────────
// LYRICS CARD (collapsible)
// ─────────────────────────────────────────────────────────────────────────────
class _LyricsCard extends StatelessWidget {
  const _LyricsCard({
    required this.lines,
    required this.scrollController,
    required this.showFull,
    required this.onToggle,
  });
  final List<String> lines;
  final ScrollController scrollController;
  final bool showFull;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _HP.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _HP.border),
      ),
      child: Column(
        children: [
          GestureDetector(
            onTap: onToggle,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: _HP.chip,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _HP.border),
                    ),
                    child: const Icon(
                      Icons.lyrics_outlined,
                      size: 16,
                      color: _HP.black,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Generated Lyrics',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: _HP.black,
                      ),
                    ),
                  ),
                  AnimatedRotation(
                    turns: showFull ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: _HP.grey2,
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeInOut,
            constraints: BoxConstraints(maxHeight: showFull ? 320 : 0),
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(18),
              ),
              child: Container(
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: _HP.border)),
                ),
                child: Scrollbar(
                  controller: scrollController,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: scrollController,
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children:
                          lines
                              .map(
                                (line) => Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Text(
                                    line,
                                    style: TextStyle(
                                      fontFamily: 'Inter',
                                      fontSize: 13,
                                      fontWeight:
                                          line.startsWith('[')
                                              ? FontWeight.w800
                                              : FontWeight.w500,
                                      color:
                                          line.startsWith('[')
                                              ? _HP.grey3
                                              : _HP.grey1,
                                      height: 1.6,
                                    ),
                                  ),
                                ),
                              )
                              .toList(),
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

// ─────────────────────────────────────────────────────────────────────────────
// WAVE BAR
// ─────────────────────────────────────────────────────────────────────────────
class _WaveBar extends StatelessWidget {
  const _WaveBar({required this.controller, required this.seconds});
  final AnimationController controller;
  final int seconds;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: _HP.redSoft,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _HP.redBorder),
      ),
      child: Row(
        children: [
          _PulsingDot(color: _HP.red),
          const SizedBox(width: 8),
          Text(
            'REC ${seconds}s / 30s',
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: _HP.red,
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
                        20.0 *
                            (0.3 + 0.7 * ((controller.value + i * 0.12) % 1.0));
                    return Container(
                      width: 3,
                      height: h,
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(
                        color: _HP.red.withValues(alpha: 0.65),
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
  Widget build(BuildContext context) => AnimatedBuilder(
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

// ─────────────────────────────────────────────────────────────────────────────
// KARAOKE BOX
// ─────────────────────────────────────────────────────────────────────────────
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
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _HP.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _HP.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.queue_music_rounded, size: 13, color: _HP.grey3),
              const SizedBox(width: 5),
              Text(
                referenceMsPerWord != null
                    ? 'Karaoke Guide (Reference Tempo)'
                    : 'Karaoke Guide ($targetWpm WPM)',
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: _HP.grey3,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...List.generate(flowLines.length, (i) {
            final line = flowLines[i];
            final lineWords = splitWords(line);
            final start = i < lineWordStart.length ? lineWordStart[i] : 0;
            final currentInLine = currentWord - start;
            final activeLine = i == currentLine;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
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
                                    color: _HP.chipDark,
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
                                  decoration: const BoxDecoration(
                                    color: _HP.black,
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
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color:
                              isCurrent
                                  ? _HP.black
                                  : isPast
                                  ? _HP.chipDark
                                  : Colors.transparent,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          lineWords[wi],
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 14,
                            fontWeight:
                                isCurrent ? FontWeight.w800 : FontWeight.w500,
                            color:
                                isCurrent
                                    ? Colors.white
                                    : isPast
                                    ? _HP.grey1
                                    : _HP.grey3,
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

// ─────────────────────────────────────────────────────────────────────────────
// RECORDED LINES CARD
// ─────────────────────────────────────────────────────────────────────────────
class _RecordedLinesCard extends StatelessWidget {
  const _RecordedLinesCard({required this.lines});
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _HP.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _HP.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.article_outlined, size: 13, color: _HP.grey3),
              SizedBox(width: 5),
              Text(
                'Lines You Recorded',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: _HP.grey2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...lines.map(
            (line) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '›  ',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: _HP.grey3,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      line,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: _HP.grey1,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PACE BANNER
// ─────────────────────────────────────────────────────────────────────────────
class _PaceBanner extends StatelessWidget {
  const _PaceBanner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final isGood = text.toLowerCase().contains('great');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: isGood ? const Color(0xFFEAFAF2) : _HP.redSoft,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isGood ? const Color(0xFFB3EDD3) : _HP.redBorder,
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.speed_rounded,
            size: 16,
            color: isGood ? const Color(0xFF0A9B5A) : _HP.red,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isGood ? const Color(0xFF0A9B5A) : _HP.red,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SLIDE TO CLONE BUTTON  (matches _GenerateSongSliderCard aesthetic)
// ─────────────────────────────────────────────────────────────────────────────
class _SlideToCloneButton extends StatefulWidget {
  const _SlideToCloneButton({required this.onCompleted});
  final Future<void> Function() onCompleted;
  @override
  State<_SlideToCloneButton> createState() => _SlideToCloneButtonState();
}

class _SlideToCloneButtonState extends State<_SlideToCloneButton>
    with SingleTickerProviderStateMixin {
  static const double _handleSize = 50;
  static const double _trackPadding = 6;
  static const double _threshold = 0.90;

  double _progress = 0;
  bool _isSubmitting = false;
  bool _isDragging = false;
  bool _isDragValid = false;
  double _dragStartDx = 0;
  double _dragStartProg = 0;

  late AnimationController _shimmer;

  @override
  void initState() {
    super.initState();
    _shimmer = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    )..repeat();
  }

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  double _maxTravel(BoxConstraints c) =>
      (c.maxWidth - _handleSize - _trackPadding * 2).clamp(
        0.0,
        double.infinity,
      );

  void _onStart(DragStartDetails d, BoxConstraints c) {
    if (_isSubmitting) return;
    final maxTravel = _maxTravel(c);
    final handleLeft = _trackPadding + maxTravel * _progress;
    final tapX = d.localPosition.dx;
    if (tapX >= handleLeft && tapX <= handleLeft + _handleSize) {
      _isDragValid = true;
      _dragStartDx = tapX;
      _dragStartProg = _progress;
      HapticFeedback.lightImpact();
      setState(() => _isDragging = true);
    } else {
      _isDragValid = false;
    }
  }

  void _onUpdate(DragUpdateDetails d, BoxConstraints c) {
    if (_isSubmitting || !_isDragValid) return;
    final maxTravel = _maxTravel(c);
    if (maxTravel <= 0) return;
    final t = (_dragStartProg + (d.localPosition.dx - _dragStartDx) / maxTravel)
        .clamp(0.0, 1.0);
    if (t == _progress) return;
    setState(() {
      _progress = t;
      _isDragging = true;
    });
  }

  Future<void> _onEnd() async {
    setState(() {
      _isDragging = false;
      _isDragValid = false;
    });
    if (_isSubmitting) return;
    if (_progress < _threshold) {
      setState(() => _progress = 0);
      return;
    }
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
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 62,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, c) {
          final maxTravel = _maxTravel(c);
          final knobOffset = maxTravel * _progress;
          final revealW = (_handleSize + _trackPadding * 2 + knobOffset).clamp(
            _handleSize + _trackPadding * 2,
            c.maxWidth,
          );
          final titleSize = (c.maxWidth * 0.037).clamp(13.0, 15.5);
          final subSize = (c.maxWidth * 0.026).clamp(10.0, 11.5);

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (d) => _onStart(d, c),
            onHorizontalDragUpdate: (d) => _onUpdate(d, c),
            onHorizontalDragEnd: (_) => _onEnd(),
            onHorizontalDragCancel: () {
              if (!_isSubmitting)
                setState(() {
                  _progress = 0;
                  _isDragging = false;
                  _isDragValid = false;
                });
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              decoration: BoxDecoration(
                color: _HP.black,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color:
                      _isDragging
                          ? _HP.green.withValues(alpha: 0.6)
                          : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: Stack(
                children: [
                  // Fill reveal
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    width: revealW,
                    decoration: BoxDecoration(
                      color: _HP.blackSoft,
                      borderRadius: BorderRadius.circular(22),
                    ),
                  ),
                  // Shimmer
                  Positioned.fill(
                    child: IgnorePointer(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(22),
                        child: AnimatedBuilder(
                          animation: _shimmer,
                          builder: (_, __) {
                            final bw = c.maxWidth * 0.28;
                            final x =
                                -bw + (_shimmer.value * (c.maxWidth + bw));
                            return CustomPaint(
                              painter: _ShimmerPainter(x: x, bw: bw),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                  // Content
                  Positioned.fill(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        _handleSize + _trackPadding + 14,
                        0,
                        14,
                        0,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 120),
                              opacity:
                                  _isSubmitting ? 0.6 : (1 - _progress * 0.45),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.record_voice_over_rounded,
                                        size: titleSize + 1,
                                        color:
                                            _isDragging
                                                ? _HP.green
                                                : const Color(0xFFCCCCCC),
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          _isSubmitting
                                              ? 'Starting voice clone…'
                                              : _isDragging
                                              ? 'Keep sliding…'
                                              : 'Slide to Clone My Voice',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontFamily: 'Inter',
                                            fontSize: titleSize,
                                            fontWeight: FontWeight.w900,
                                            color:
                                                _isDragging
                                                    ? _HP.green
                                                    : Colors.white,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _isDragging
                                        ? 'Release to start cloning'
                                        : 'AI writes in your voice',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: 'Inter',
                                      fontSize: subSize,
                                      fontWeight: FontWeight.w500,
                                      color: _HP.grey3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          AnimatedOpacity(
                            duration: const Duration(milliseconds: 120),
                            opacity:
                                _isSubmitting
                                    ? 0.2
                                    : (_progress < 0.25 ? 0.8 : 0.15),
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
                                      color: Colors.white.withValues(
                                        alpha: alphas[i],
                                      ),
                                    ),
                                  );
                                }),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Handle knob
                  AnimatedPositioned(
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
                                  ? [_HP.green, const Color(0xFF0CC878)]
                                  : [
                                    const Color(0xFF383838),
                                    const Color(0xFF262626),
                                  ],
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
                                    ? _HP.green.withValues(alpha: 0.35)
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
                                  key: ValueKey('spin'),
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    valueColor: AlwaysStoppedAnimation(
                                      Colors.white,
                                    ),
                                  ),
                                )
                                : Icon(
                                  Icons.record_voice_over_rounded,
                                  key: const ValueKey('icon'),
                                  size: 22,
                                  color:
                                      _isDragging ? Colors.black : Colors.white,
                                ),
                      ),
                    ),
                  ),
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
  const _ShimmerPainter({required this.x, required this.bw});
  final double x, bw;
  @override
  void paint(Canvas canvas, Size size) {
    final grad = LinearGradient(
      colors: [
        Colors.white.withValues(alpha: 0),
        Colors.white.withValues(alpha: 0.025),
        Colors.white.withValues(alpha: 0.09),
        Colors.white.withValues(alpha: 0.025),
        Colors.white.withValues(alpha: 0),
      ],
    ).createShader(Rect.fromLTWH(x, 0, bw, size.height));
    canvas.save();
    canvas.transform(Matrix4.rotationZ(-0.12).storage);
    canvas.drawRect(
      Rect.fromLTWH(x - 10, -20, bw, size.height + 40),
      Paint()..shader = grad,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ShimmerPainter o) => o.x != x;
}

// ─────────────────────────────────────────────────────────────────────────────
// BUTTON HELPERS
// ─────────────────────────────────────────────────────────────────────────────
class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.icon,
    required this.filled,
    required this.onPressed,
  });
  final String label;
  final IconData icon;
  final bool filled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        height: 56,
        width: double.infinity,
        decoration: BoxDecoration(
          color: filled ? _HP.black : _HP.chip,
          borderRadius: BorderRadius.circular(20),
          border: filled ? null : Border.all(color: _HP.border),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: filled ? Colors.white : _HP.black),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: filled ? Colors.white : _HP.black,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RedButton extends StatelessWidget {
  const _RedButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        height: 56,
        width: double.infinity,
        decoration: BoxDecoration(
          color: _HP.redSoft,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _HP.redBorder),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: _HP.red),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: _HP.red,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OutlineButton extends StatelessWidget {
  const _OutlineButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: _HP.chip,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _HP.border),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: _HP.black),
            const SizedBox(width: 7),
            Text(
              label,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: _HP.black,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
