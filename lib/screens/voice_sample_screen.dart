import 'dart:async';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../models/song_reference.dart';
import '../services/transliteration_service.dart';
import 'voice_song_screen.dart';

/// The sentences the user reads aloud for a voice sample.
/// Short, phonetically diverse — covers most sounds in English.
const _sampleSentences = [
  '"The quick brown fox jumps over the lazy dog."',
  '"She sells seashells by the seashore."',
  '"How much wood would a woodchuck chuck?"',
];

/// Base sentences in native scripts (will be transliterated to Roman for display)
const _urduSampleSentencesNative = [
  '"میری آواز میں یہ گیت دل سے نکلتا ہے۔"',
  '"رات کی خاموشی میں تیری یاد جاگتی رہتی ہے۔"',
  '"دل کی دھڑکن ہر پل تیرا نام پکارتی ہے۔"',
];

const _hindiSampleSentencesNative = [
  '"मेरी आवाज़ में यह गीत दिल से निकलता है।"',
  '"रात की खामोशी में तेरी याद जगती रहती है।"',
  '"दिल की धड़कन हर पल तेरा नाम पुकारती है।"',
];

class VoiceSampleScreen extends StatefulWidget {
  const VoiceSampleScreen({
    super.key,
    required this.songTitle,
    required this.lyrics,
    required this.mood,
    required this.genre,
    required this.language,
    this.referenceSong,
  });

  final String songTitle;
  final String lyrics;
  final String mood;
  final String genre;
  final String language;
  final SongReference? referenceSong;

  @override
  State<VoiceSampleScreen> createState() => _VoiceSampleScreenState();
}

class _VoiceSampleScreenState extends State<VoiceSampleScreen>
    with SingleTickerProviderStateMixin {
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  final _transliterationService = TransliterationService();

  String? _recordedPath;
  bool _isRecording = false;
  bool _isPlaying = false;
  int _recordingSeconds = 0;
  Timer? _timer;

  late AnimationController _waveController;
  
  // Transliterated sample sentences
  List<String> _displaySampleSentences = [];
  bool _isLoadingSentences = false;

  @override
  void initState() {
    super.initState();
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _loadTransliteratedSentences();
  }

  Future<void> _loadTransliteratedSentences() async {
    setState(() => _isLoadingSentences = true);
    final normalizedLanguage = widget.language.trim().toLowerCase();
    
    List<String> nativeSentences;
    switch (normalizedLanguage) {
      case 'urdu':
        nativeSentences = _urduSampleSentencesNative;
        break;
      case 'hindi':
        nativeSentences = _hindiSampleSentencesNative;
        break;
      default:
        nativeSentences = _sampleSentences;
    }
    
    // Transliterate if needed (for non-Latin scripts)
    final transliterated = <String>[];
    for (final sentence in nativeSentences) {
      if (_transliterationService.needsTransliteration(sentence)) {
        final translit = await _transliterationService.transliterate(
          sentence,
          widget.language,
        );
        transliterated.add(translit);
      } else {
        transliterated.add(sentence);
      }
    }
    
    if (mounted) {
      setState(() {
        _displaySampleSentences = transliterated;
        _isLoadingSentences = false;
      });
    }
  }

  Future<void> _showMicSettingsDialog() async {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    await showDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Microphone permission'),
            content: const Text(
              'Microphone access is turned off for this app. Enable it in Settings to record your voice sample.',
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

  @override
  void dispose() {
    _timer?.cancel();
    _recorder.dispose();
    _player.dispose();
    _waveController.dispose();
    super.dispose();
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
    try {
      final path = await _recorder.stop();
      if (!mounted) return;
      setState(() {
        _isRecording = false;
        _recordedPath = path;
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final hasRecording = _recordedPath != null;
    final isShort = _recordingSeconds < 5 && hasRecording;
    final sampleSentences = _displaySampleSentences.isNotEmpty
        ? _displaySampleSentences
        : _sampleSentences;

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
                                'Read aloud in ${widget.language} for 10–15 seconds',
                                style: tt.bodySmall?.copyWith(
                                  color: cs.onPrimaryContainer.withValues(
                                    alpha: 0.7,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Record a short voice sample.',
                      style: tt.bodySmall?.copyWith(
                        color: cs.onPrimaryContainer.withValues(alpha: 0.85),
                      ),
                    ),
                    if (widget.referenceSong != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        'Pronunciation guide: ${widget.referenceSong!.trackName} by ${widget.referenceSong!.artistName}',
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
                'Read this aloud:',
                style: tt.titleSmall?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              if (_isLoadingSentences)
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            cs.primary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          'Preparing readable text...',
                          style: tt.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else
                ...List.generate(sampleSentences.length, (i) {
                  return Container(
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
                      sampleSentences[i],
                      style: tt.bodyLarge?.copyWith(
                        fontStyle: FontStyle.italic,
                        height: 1.5,
                      ),
                    ),
                  );
                }),
              const SizedBox(height: 24),
              if (_isRecording)
                _WaveVisualiser(
                  controller: _waveController,
                  seconds: _recordingSeconds,
                  cs: cs,
                  tt: tt,
                ),
              const SizedBox(height: 16),
              SizedBox(
                height: 64,
                child: FilledButton.icon(
                  onPressed: _isRecording ? _stopRecording : _startRecording,
                  style: FilledButton.styleFrom(
                    backgroundColor: _isRecording ? cs.error : cs.primary,
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
                if (isShort)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: cs.errorContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          color: cs.error,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Recording is very short. For better quality, aim for 10–15 seconds.',
                            style: tt.bodySmall?.copyWith(
                              color: cs.onErrorContainer,
                            ),
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
                    _isPlaying ? Icons.stop_rounded : Icons.play_arrow_rounded,
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
                        builder:
                            (context) => VoiceSongScreen(
                              songTitle: widget.songTitle,
                              lyrics: widget.lyrics,
                              mood: widget.mood,
                              genre: widget.genre,
                              language: widget.language,
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
                final h =
                    8.0 +
                    24.0 * (0.3 + 0.7 * ((controller.value + i * 0.15) % 1.0));
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
      builder:
          (_, __) => Container(
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
