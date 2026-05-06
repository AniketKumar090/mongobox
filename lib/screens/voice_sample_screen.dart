import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import '../models/song_reference.dart';
import '../constants/colors.dart';
import '../services/bpm_service.dart';
import '../services/lyrics_service.dart';
import '../services/voice_profile_bootstrap_service.dart';
import '../theme/song_creation_palette.dart';
import '../widgets/song_flow_timeline.dart';
import 'voice_song_screen.dart';

// ─── HOME SCREEN PALETTE ──────────────────────────────────────────────────────
class _HP {
  static SongCreationPalette get _p => SongCreationPalette.current;

  static Color get background => _p.background;
  static Color get card => _p.card;
  static Color get border => _p.border;
  static Color get black => _p.black;
  static Color get grey1 => _p.grey1;
  static Color get grey2 => _p.grey2;
  static Color get grey3 => _p.grey3;
  static Color get chip => _p.chip;
  static Color get chipDark => _p.chipDark;
  static Color get green => _p.green;
  static Color get greenSoft => _p.greenSoft;
  static Color get greenBorder => _p.greenBorder;
  static Color get red => _p.red;
  static Color get redSoft => _p.redSoft;
  static Color get redBorder => _p.redBorder;
  static Color get onBlack => _p.onBlack;
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
  final _voiceProfileBootstrapService = VoiceProfileBootstrapService();
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
  bool _showFullLyrics = false;

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
    _voiceProfileBootstrapService.dispose();
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
            title: Row(
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
            content: Text(
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
                child: Text(
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
                  child: Text(
                    'Open Settings',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      color: _HP.onBlack,
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
            style: TextStyle(
              fontFamily: 'Inter',
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: _HP.onBlack,
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

    String? voiceboxProfileId;
    try {
      final profile = await _voiceProfileBootstrapService.bootstrapProfile(
        voiceSamplePath: recordedPath,
        language: _cloneLanguage,
      );
      voiceboxProfileId = profile.profileId;
    } catch (e) {
      debugPrint('Voice profile bootstrap skipped: $e');
    }

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
              voiceboxProfileId: voiceboxProfileId,
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
    final bottomActionBar = SafeArea(
      minimum: EdgeInsets.fromLTRB(hPad, 8, hPad, 12),
      child: Container(
        color: _HP.background,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasRecording &&
                !_isRecording &&
                _karaokeFlowLines.isNotEmpty) ...[
              _RecordedLinesCard(lines: _karaokeFlowLines),
              const SizedBox(height: 10),
            ],
            if ((_paceFeedback ?? '').isNotEmpty && !_isRecording) ...[
              _PaceBanner(text: _paceFeedback!),
              const SizedBox(height: 10),
            ],
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
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            size: 14,
                            color: _HP.red,
                          ),
                          const SizedBox(width: 5),
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
              _HapticFlowCloneButton(onCompleted: _startVoiceCloneFlow),
              const SizedBox(height: 10),
            ],
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
    );

    return Scaffold(
      backgroundColor: _HP.background,
      bottomNavigationBar: bottomActionBar,
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
                padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 24),
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
                        Text(
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
                child: Icon(
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
                  Text(
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
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: _HP.grey2,
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
          Icon(Icons.info_outline_rounded, size: 16, color: _HP.grey3),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
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
  bool _expanded = true;
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
                    child: Icon(
                      Icons.mic_rounded,
                      size: 16,
                      color: _HP.onBlack,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
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
                          style: TextStyle(
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
                    child: Icon(
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
                decoration: BoxDecoration(
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
                        Text(
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
                                Text(
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
                                    style: TextStyle(
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
                    child: Icon(
                      Icons.lyrics_outlined,
                      size: 16,
                      color: _HP.black,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
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
                    child: Icon(
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
                decoration: BoxDecoration(
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
            style: TextStyle(
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
              Icon(Icons.queue_music_rounded, size: 13, color: _HP.grey3),
              const SizedBox(width: 5),
              Text(
                referenceMsPerWord != null
                    ? 'Karaoke Guide (Reference Tempo)'
                    : 'Karaoke Guide ($targetWpm WPM)',
                style: TextStyle(
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
                                  decoration: BoxDecoration(
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
                                    ? _HP.onBlack
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
          Row(
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
                  Text(
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
                      style: TextStyle(
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
        color: isGood ? _HP.greenSoft : _HP.redSoft,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isGood ? _HP.greenBorder : _HP.redBorder),
      ),
      child: Row(
        children: [
          Icon(
            Icons.speed_rounded,
            size: 16,
            color: isGood ? AppColors.accentStrong : _HP.red,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isGood ? AppColors.accentStrong : _HP.red,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// HAPTIC FLOW CLONE BUTTON  (fixed for light + dark mode)
// ─────────────────────────────────────────────────────────────────────────────
class _HapticFlowCloneButton extends StatefulWidget {
  const _HapticFlowCloneButton({required this.onCompleted});
  final Future<void> Function() onCompleted;

  @override
  State<_HapticFlowCloneButton> createState() => _HapticFlowCloneButtonState();
}

class _HapticFlowCloneButtonState extends State<_HapticFlowCloneButton>
    with TickerProviderStateMixin {
  static const _holdDuration = Duration(milliseconds: 1050);
  static const _hapticMilestones = [0.18, 0.38, 0.58, 0.78, 0.94];

  late final AnimationController _shimmer;
  late final AnimationController _hold;

  bool _isPressing = false;
  bool _isSubmitting = false;
  int _lastHapticIndex = -1;

  double get _progress => _hold.value.clamp(0.0, 1.0);

  @override
  void initState() {
    super.initState();
    _shimmer = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    )..repeat();
    _hold =
        AnimationController(vsync: this, duration: _holdDuration)
          ..addListener(_handleHoldTick)
          ..addStatusListener(_handleHoldStatus);
  }

  @override
  void dispose() {
    _shimmer.dispose();
    _hold
      ..removeListener(_handleHoldTick)
      ..removeStatusListener(_handleHoldStatus)
      ..dispose();
    super.dispose();
  }

  void _handleHoldTick() {
    if (!mounted) return;
    for (var i = _lastHapticIndex + 1; i < _hapticMilestones.length; i++) {
      if (_progress < _hapticMilestones[i]) break;
      _lastHapticIndex = i;
      HapticFeedback.selectionClick();
    }
    setState(() {});
  }

  Future<void> _handleHoldStatus(AnimationStatus status) async {
    if (status != AnimationStatus.completed || _isSubmitting) return;
    _lastHapticIndex = _hapticMilestones.length;
    setState(() {
      _isPressing = false;
      _isSubmitting = true;
    });
    await HapticFeedback.mediumImpact();
    try {
      await widget.onCompleted();
    } finally {
      if (mounted) {
        _hold.value = 0;
        setState(() {
          _isSubmitting = false;
          _isPressing = false;
          _lastHapticIndex = -1;
        });
      }
    }
  }

  void _startHold() {
    if (_isSubmitting || _isPressing) return;
    _lastHapticIndex = -1;
    _isPressing = true;
    HapticFeedback.lightImpact();
    _hold.forward(from: 0);
    setState(() {});
  }

  void _cancelHold() {
    if (_isSubmitting) return;
    if (!_isPressing && _progress == 0) return;
    _isPressing = false;
    _lastHapticIndex = -1;
    _hold.animateBack(
      0,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // Use Brightness to resolve explicit colors — avoids palette inversion issues
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final btnBg = const Color(0xFF0E0E0E);
    final btnFg = isDark ? const Color(0xFFFFFFFF) : const Color(0xFFFFFFFF);
    final btnSubFg = const Color(0xFFFFFFFF).withValues(alpha: 0.40);
    final activeBorder = _HP.green.withValues(alpha: 0.6);
    final inactiveBorder =
        isDark ? const Color(0xFF2E2E2E) : const Color(0xFF222222);
    return SizedBox(
      height: 72,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, c) {
          final titleSize = (c.maxWidth * 0.037).clamp(13.0, 15.5);
          final subSize = (c.maxWidth * 0.026).clamp(10.0, 11.5);
          final fillWidth = (c.maxWidth * _progress).clamp(0.0, c.maxWidth);
          final fillLeft = (c.maxWidth - fillWidth) / 2;
          final isActive = _isPressing || _isSubmitting;

          return Semantics(
            button: true,
            label: 'Hold to clone my voice',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (_) => _startHold(),
              onTapUp: (_) => _cancelHold(),
              onTapCancel: _cancelHold,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                decoration: BoxDecoration(
                  color: btnBg,
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(
                    color: isActive ? activeBorder : inactiveBorder,
                    width: 1.4,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color:
                          isActive
                              ? _HP.green.withValues(alpha: 0.2)
                              : Colors.black.withValues(alpha: 0.10),
                      blurRadius: isActive ? 20 : 8,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(26),
                  child: Stack(
                    children: [
                      // Green fill sweep during hold
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 90),
                        curve: Curves.easeOutCubic,
                        left: fillLeft,
                        top: 0,
                        bottom: 0,
                        width: fillWidth,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                              colors: [
                                _HP.green.withValues(alpha: 0.0),
                                _HP.green.withValues(alpha: 0.22),
                                _HP.green.withValues(alpha: 0.0),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // Shimmer
                      Positioned.fill(
                        child: IgnorePointer(
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 150),
                            opacity: isActive ? 0.6 : 1.0,
                            child: AnimatedBuilder(
                              animation: _shimmer,
                              builder: (_, __) {
                                final bw = c.maxWidth * 0.28;
                                return CustomPaint(
                                  painter: _ShimmerPainter(
                                    progress: _shimmer.value,
                                    bw: bw,
                                    shimmerColor: btnFg,
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                      // Label
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Center(
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 120),
                            opacity: _isSubmitting ? 0.7 : 1,
                            child: Row(
                              children: [
                                _ChevronCluster(
                                  towardCenter: true,
                                  color: isActive ? _HP.green : btnFg,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        _isSubmitting
                                            ? 'Starting voice clone…'
                                            : isActive
                                            ? 'Keep holding to clone'
                                            : 'Hold to Clone My Voice',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontFamily: 'Inter',
                                          fontSize: titleSize,
                                          fontWeight: FontWeight.w900,
                                          color: isActive ? _HP.green : btnFg,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        _isSubmitting
                                            ? 'Opening voice clone flow'
                                            : isActive
                                            ? 'Release to cancel'
                                            : 'AI writes in your voice',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontFamily: 'Inter',
                                          fontSize: subSize,
                                          fontWeight: FontWeight.w500,
                                          color: btnSubFg,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 10),
                                _ChevronCluster(
                                  towardCenter: false,
                                  color: isActive ? _HP.green : btnFg,
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
            ),
          );
        },
      ),
    );
  }
}

class _ChevronCluster extends StatelessWidget {
  const _ChevronCluster({required this.towardCenter, required this.color});

  final bool towardCenter;
  final Color color;

  static const List<double> _opacities = [0.24, 0.46, 0.72, 1.0];

  @override
  Widget build(BuildContext context) {
    final icon =
        towardCenter ? Icons.chevron_left_rounded : Icons.chevron_right_rounded;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(_opacities.length, (index) {
        final opacity =
            towardCenter
                ? _opacities[index]
                : _opacities[_opacities.length - 1 - index];
        return Padding(
          padding: EdgeInsets.only(
            right: index == _opacities.length - 1 ? 0 : 1,
          ),
          child: Icon(icon, size: 16, color: color.withValues(alpha: opacity)),
        );
      }),
    );
  }
}

class _ShimmerPainter extends CustomPainter {
  const _ShimmerPainter({
    required this.progress,
    required this.bw,
    required this.shimmerColor,
  });
  final double progress;
  final double bw;
  final Color shimmerColor;

  @override
  void paint(Canvas canvas, Size size) {
    final gradColors = [
      shimmerColor.withValues(alpha: 0),
      shimmerColor.withValues(alpha: 0.03),
      shimmerColor.withValues(alpha: 0.10),
      shimmerColor.withValues(alpha: 0.03),
      shimmerColor.withValues(alpha: 0),
    ];
    final centerX = size.width / 2;
    final travel = (size.width / 2) + bw;
    final leftX = centerX - (bw / 2) - (progress * travel);
    final rightX = centerX - (bw / 2) + (progress * travel);

    final leftGrad = LinearGradient(
      begin: Alignment.centerRight,
      end: Alignment.centerLeft,
      colors: gradColors,
    ).createShader(Rect.fromLTWH(leftX, 0, bw, size.height));

    final rightGrad = LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: gradColors,
    ).createShader(Rect.fromLTWH(rightX, 0, bw, size.height));

    canvas
      ..drawRect(
        Rect.fromLTWH(leftX, 0, bw, size.height),
        Paint()
          ..shader = leftGrad
          ..blendMode = BlendMode.screen,
      )
      ..drawRect(
        Rect.fromLTWH(rightX, 0, bw, size.height),
        Paint()
          ..shader = rightGrad
          ..blendMode = BlendMode.screen,
      );
  }

  @override
  bool shouldRepaint(_ShimmerPainter o) =>
      o.progress != progress || o.bw != bw || o.shimmerColor != shimmerColor;
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
            Icon(icon, size: 18, color: filled ? _HP.onBlack : _HP.black),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: filled ? _HP.onBlack : _HP.black,
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
              style: TextStyle(
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
              style: TextStyle(
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
