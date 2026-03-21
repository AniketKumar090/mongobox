import 'dart:async';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../models/song_reference.dart';
import '../services/bpm_service.dart';
import '../services/lyrics_service.dart';
import 'voice_song_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Base English sentences the user reads aloud for a voice sample.
// Short, phonetically diverse — covers most sounds in English.
// For Hindi / Hindi‑dominant songs we instead show Hindi sample lines with
// a Hinglish (Latin) line underneath so users can read even if they can't
// read Devanagari.
// ─────────────────────────────────────────────────────────────────────────────
const _sampleSentences = [
  'The quick brown fox jumps over the lazy dog.',
  'She sells seashells by the seashore.',
  'How much wood would a woodchuck chuck if a woodchuck could chuck wood?',
];

/// Hinglish fallback lines when no flow lines available (Hindi-dominant only).
const _hinglishFallbackLines = [
  'Meri awaaz mein ye gaana dil se nikalta hai.',
  'Raat ki khamoshi mein teri yaad goonjti rehti hai.',
  'Dil ki dhadkan har pal tera naam pukarti hai.',
];

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

  late AnimationController _waveController;
  final _lyricsService = LyricsService();

  @override
  void initState() {
    super.initState();
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fetchReferenceTempo();
  }

  Future<void> _fetchReferenceTempo() async {
    final ref = widget.referenceSong;
    if (ref == null) return;

    // 1) Try LRCLIB synced lyrics for exact word timing
    if (ref.trackName.trim().isNotEmpty && ref.artistName.trim().isNotEmpty) {
      try {
        final matches = await _lyricsService.search('${ref.trackName} ${ref.artistName}');
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
            final ms = LyricsService.computeMsPerWordFromSyncedLyrics(full.syncedLyrics);
            if (ms != null && mounted) {
              setState(() => _referenceMsPerWord = ms);
              return;
            }
          }
        }
      } catch (_) {}
    }

    // 2) Fallback: fetch BPM from reference track (voice backend)
    final videoId = ref.videoId?.trim();
    if (videoId != null && videoId.isNotEmpty) {
      try {
        final bpm = await _bpmService.fetchBpm(videoId);
        if (bpm != null && bpm >= 50 && bpm <= 220 && mounted) {
          // ~1.5 words per beat → ms per word = 60000 / (bpm * 1.5)
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
    super.dispose();
  }

  Future<void> _showMicSettingsDialog() async {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Microphone permission'),
        content: const Text(
          'Microphone access is turned off. Enable it in Settings to record your voice.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Cancel', style: tt.labelLarge),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: cs.primary,
              foregroundColor: cs.onPrimary,
            ),
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
      final isHindiDominant =
          widget.dominantLanguage.toLowerCase().contains('hindi');
      final targetLyrics = isHindiDominant
          ? (widget.hinglishLyrics ?? widget.hindiLyrics)
          : widget.englishLyrics;
      final flowPromptLines = _extractFlowPromptLines(
        targetLyrics,
        isHindiDominant: isHindiDominant,
      );
      int targetWpm;
      final videoId = (widget.referenceSong?.videoId ?? '').trim();
      if (videoId.isNotEmpty) {
        final bpm = await _bpmService.fetchBpm(videoId);
        targetWpm = bpm != null
            ? (bpm * 1.2).round().clamp(90, 150)
            : _estimateTargetWpm(targetLyrics);
      } else {
        targetWpm = _estimateTargetWpm(targetLyrics);
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

      _waveController.repeat(reverse: true);
      _startKaraokeGuide(flowLines: flowPromptLines, targetWpm: targetWpm);
      setState(() {
        _isRecording = true;
        _recordedPath = null;
      });
    } catch (e) {
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  static const _hindiSections = ['verse 1', 'verse 2', 'verse 3', 'bridge', 'pre-chorus'];
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
      final sectionMatch = isHindiDominant
          ? _hindiSections.any((s) => currentSection.contains(s))
          : _englishSections.any((s) => currentSection.contains(s));
      if (sectionMatch && trimmed.length >= 8) {
        result.add(trimmed);
      }
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
            l.replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '').length >=
                8)
        .toList();
  }

  List<String> _extractFlowPromptLines(String lyrics, {required bool isHindiDominant}) {
    final filtered = _linesForDominantLanguage(lyrics, isHindiDominant);
    if (filtered.isEmpty) return const [];
    filtered.sort((a, b) => a.length.compareTo(b.length));
    final picked = filtered.where((l) => l.length <= 90).take(4).toList();
    return picked.isNotEmpty ? picked : filtered.take(3).toList();
  }

  int _estimateTargetWpm(String lyrics) {
    final lines = _cleanSingableLines(lyrics);
    if (lines.isEmpty) return 105;
    final words = lines
        .take(10)
        .map((l) => l.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length)
        .fold<int>(0, (a, b) => a + b);
    final avgWordsPerLine = words / lines.take(10).length;
    final estimated = (avgWordsPerLine * 18).round(); // rough spoken cadence map
    return estimated.clamp(90, 150);
  }

  List<String> _splitWords(String line) {
    return line.split(RegExp(r'\s+')).where((w) => w.trim().isNotEmpty).toList();
  }

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
      final msPerWord = _referenceMsPerWord ??
          (60000 / _karaokeTargetWpm).round().clamp(220, 900);
      final rawIndex = (_karaokeWatch.elapsedMilliseconds / msPerWord).floor();
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
    final expectedSeconds = (targetWords * 60 / targetWpm);
    final ratio = spokenSeconds / expectedSeconds;
    if (ratio < 0.85) {
      return 'Too fast: slow down a bit to stay on beat.';
    }
    if (ratio > 1.2) {
      return 'Too slow: tighten delivery to match song flow.';
    }
    return 'Great pacing: you are close to target flow.';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final hasRecording = _recordedPath != null;
    final isShort = _recordingSeconds < 5 && hasRecording;
    final isHindiDominant =
        widget.dominantLanguage.toLowerCase().contains('hindi');
    final targetLyrics = isHindiDominant
        ? (widget.hinglishLyrics ?? widget.hindiLyrics)
        : widget.englishLyrics;
    final flowPromptLines = _extractFlowPromptLines(
      targetLyrics,
      isHindiDominant: isHindiDominant,
    );

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: const Text('Record Your Voice'),
        centerTitle: true,
        backgroundColor: cs.inverseSurface,
        foregroundColor: cs.onInverseSurface,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Info card ────────────────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [cs.primaryContainer, cs.tertiaryContainer],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: cs.primary.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.record_voice_over_rounded,
                            color: cs.primary,
                            size: 26,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Voice Sample',
                                style: tt.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: cs.onPrimaryContainer,
                                ),
                              ),
                              Text(
                                'Read aloud clearly for 10–15 seconds',
                                style: tt.bodySmall?.copyWith(
                                  color: cs.onPrimaryContainer
                                      .withValues(alpha: 0.7),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (widget.referenceSong != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        'Style reference: ${widget.referenceSong!.trackName} by ${widget.referenceSong!.artistName}',
                        style: tt.bodySmall?.copyWith(
                          color: cs.onPrimaryContainer.withValues(alpha: 0.85),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 28),

              Text(
                'Read these sentences aloud:',
                style: tt.titleSmall?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),

              if (flowPromptLines.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer.withValues(alpha: 0.28),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'Lyrical flow extracted from your selected song. '
                    'Use karaoke mode while recording - words light up automatically.',
                    style: tt.bodySmall?.copyWith(
                      color: cs.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],

              // ── Prompt sentences: Hindi+Hinglish for Hindi songs, otherwise English only ──
              if (flowPromptLines.isNotEmpty)
                ...flowPromptLines.map(
                  (line) => Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: cs.outline.withValues(alpha: 0.2),
                      ),
                    ),
                    child: Text(
                      line,
                      style: tt.bodyLarge?.copyWith(
                        fontStyle: FontStyle.italic,
                        height: 1.5,
                      ),
                    ),
                  ),
                )
              else if (isHindiDominant)
                ..._hinglishFallbackLines.map(
                  (line) => Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: cs.outline.withValues(alpha: 0.2),
                      ),
                    ),
                    child: Text(
                      line,
                      style: tt.bodyLarge?.copyWith(
                        fontStyle: FontStyle.italic,
                        height: 1.5,
                      ),
                    ),
                  ),
                )
              else
                ..._sampleSentences.map(
                  (sentence) => Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: cs.outline.withValues(alpha: 0.2),
                      ),
                    ),
                    child: Text(
                      sentence,
                      style: tt.bodyLarge?.copyWith(
                        fontStyle: FontStyle.italic,
                        height: 1.55,
                      ),
                    ),
                  ),
                ),

              const SizedBox(height: 8),

              // ── Tip ──────────────────────────────────────────────────────
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: cs.primaryContainer.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(Icons.lightbulb_outline_rounded,
                        size: 16, color: cs.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Speak naturally — your voice tone is what matters, not the words.',
                        style: tt.bodySmall
                            ?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // ── Wave visualiser while recording ──────────────────────────
              if (_isRecording)
                _WaveVisualiser(
                  controller: _waveController,
                  seconds: _recordingSeconds,
                  cs: cs,
                  tt: tt,
                ),

              if (_isRecording && _karaokeFlowLines.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: cs.primary.withValues(alpha: 0.25),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _referenceMsPerWord != null
                            ? 'Karaoke guide (reference track tempo)'
                            : 'Karaoke guide (${_karaokeTargetWpm} WPM target)',
                        style: tt.labelLarge?.copyWith(
                          color: cs.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...List.generate(_karaokeFlowLines.length, (i) {
                        final line = _karaokeFlowLines[i];
                        final words = _splitWords(line);
                        final start = i < _karaokeLineWordStart.length
                            ? _karaokeLineWordStart[i]
                            : 0;
                        final currentInLine = _karaokeCurrentWord - start;
                        final activeLine = i == _karaokeCurrentLine;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (activeLine)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: LayoutBuilder(
                                    builder: (context, c) {
                                      final width = c.maxWidth.clamp(1.0, 9999.0);
                                      final x = (width * _activeLineProgress)
                                          .clamp(0.0, width);
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
                                                color: cs.primary
                                                    .withValues(alpha: 0.25),
                                              ),
                                            ),
                                            AnimatedPositioned(
                                              duration: const Duration(milliseconds: 120),
                                              curve: Curves.easeOut,
                                              left: x - 4,
                                              top: 0,
                                              child: Container(
                                                width: 8,
                                                height: 8,
                                                decoration: BoxDecoration(
                                                  color: cs.primary,
                                                  shape: BoxShape.circle,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              Wrap(
                                spacing: 4,
                                runSpacing: 6,
                                children: List.generate(words.length, (wi) {
                                  final isPast = activeLine && wi < currentInLine;
                                  final isCurrent = activeLine && wi == currentInLine;
                                  final bg = isCurrent
                                      ? cs.primary
                                      : isPast
                                          ? cs.primary.withValues(alpha: 0.2)
                                          : Colors.transparent;
                                  final fg = isCurrent
                                      ? cs.onPrimary
                                      : isPast
                                          ? cs.primary
                                          : cs.onSurfaceVariant;
                                  return AnimatedContainer(
                                    duration: const Duration(milliseconds: 120),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: bg,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      words[wi],
                                      style: tt.bodyMedium?.copyWith(
                                        color: fg,
                                        fontWeight: isCurrent
                                            ? FontWeight.w700
                                            : FontWeight.w500,
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
                ),
              ],

              const SizedBox(height: 16),

              // ── Record / Stop button ─────────────────────────────────────
              SizedBox(
                height: 64,
                child: FilledButton.icon(
                  onPressed:
                      _isRecording ? _stopRecording : _startRecording,
                  style: FilledButton.styleFrom(
                    backgroundColor:
                        _isRecording ? cs.error : cs.primary,
                    foregroundColor: cs.onPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                    elevation: 4,
                  ),
                  icon: Icon(
                    _isRecording ? Icons.stop_rounded : Icons.mic_rounded,
                    size: 26,
                  ),
                  label: Text(
                    _isRecording
                        ? 'Stop  (${_recordingSeconds}s)'
                        : hasRecording
                            ? 'Re-record'
                            : 'Start Recording',
                    style: tt.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: cs.onPrimary,
                    ),
                  ),
                ),
              ),

              if (hasRecording) ...[
                const SizedBox(height: 12),

                if ((_paceFeedback ?? '').isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: cs.primaryContainer.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.speed_rounded, color: cs.primary, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _paceFeedback!,
                            style: tt.bodySmall?.copyWith(
                              color: cs.onPrimaryContainer,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                if (isShort)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: cs.errorContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber_rounded,
                            color: cs.error, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Recording is very short. Aim for 10–15 seconds for best quality.',
                            style: tt.bodySmall
                                ?.copyWith(color: cs.onErrorContainer),
                          ),
                        ),
                      ],
                    ),
                  ),

                const SizedBox(height: 12),

                OutlinedButton.icon(
                  onPressed: _playback,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: Icon(
                    _isPlaying
                        ? Icons.stop_rounded
                        : Icons.play_arrow_rounded,
                  ),
                  label: Text(
                    _isPlaying ? 'Stop playback' : 'Play back recording',
                  ),
                ),

                const SizedBox(height: 12),

                FilledButton.icon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => VoiceSongScreen(
                          songTitle: widget.songTitle,
                          hindiLyrics: widget.hindiLyrics,
                          englishLyrics: widget.englishLyrics,
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
                    backgroundColor: cs.primary,
                    foregroundColor: cs.onPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.arrow_forward_rounded),
                  label: const Text('Use This Recording'),
                ),
              ],

              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── WAVE VISUALISER ──────────────────────────────────────────────────────────
class _WaveVisualiser extends StatelessWidget {
  const _WaveVisualiser({
    required this.controller,
    required this.seconds,
    required this.cs,
    required this.tt,
  });
  final AnimationController controller;
  final int seconds;
  final ColorScheme cs;
  final TextTheme tt;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 72,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: cs.errorContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.error.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _PulsingDot(cs: cs),
          const SizedBox(width: 12),
          Text(
            'Recording  ${seconds}s / 30s',
            style: tt.labelLarge?.copyWith(
              color: cs.error,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 16),
          ...List.generate(20, (i) {
            return AnimatedBuilder(
              animation: controller,
              builder: (_, __) {
                final h = 8.0 +
                    24.0 *
                        (0.3 + 0.7 * ((controller.value + i * 0.15) % 1.0));
                return Container(
                  width: 3,
                  height: h,
                  margin: const EdgeInsets.symmetric(horizontal: 1.5),
                  decoration: BoxDecoration(
                    color: cs.error.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(2),
                  ),
                );
              },
            );
          }),
        ],
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.cs});
  final ColorScheme cs;
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
      builder: (_, __) => Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: widget.cs.error.withValues(alpha: 0.5 + 0.5 * _c.value),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}