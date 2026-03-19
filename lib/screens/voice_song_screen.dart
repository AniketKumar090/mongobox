import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/song_reference.dart';
import '../services/background_music_service.dart';
import '../services/transliteration_service.dart';
import '../services/voice_clone_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Static UI Mode: Voice song preview and playback
// ─────────────────────────────────────────────────────────────────────────────

class VoiceSongScreen extends StatefulWidget {
  const VoiceSongScreen({
    super.key,
    required this.songTitle,
    required this.lyrics,
    required this.mood,
    required this.genre,
    required this.language,
    this.referenceSong,
    required this.voiceSamplePath,
  });

  final String songTitle;
  final String lyrics;
  final String mood;
  final String genre;
  final String language;
  final SongReference? referenceSong;
  final String voiceSamplePath;

  @override
  State<VoiceSongScreen> createState() => _VoiceSongScreenState();
}

class _VoiceSongScreenState extends State<VoiceSongScreen> {
  final _musicPlayer = AudioPlayer();
  final _voicePlayer = AudioPlayer();
  final _cloneService = VoiceCloneService();
  final _backgroundMusicService = BackgroundMusicService();
  final _transliterationService = TransliterationService();

  String? _voiceAudioPath;
  String? _musicSourceUrl;
  String? _errorMessage;

  _Step _currentStep = _Step.cloningVoice;
  bool _voiceDone = false;
  bool _musicDone = false;
  bool _isPlaying = false;

  // Voice quality tracking
  String? _qualityWarning;
  String? _voiceSourceLabel;
  String? _musicSourceLabel;
  StreamSubscription<PlayerState>? _voicePlayerStateSub;
  
  // Transliterated lyrics
  String? _romanLyrics;
  bool _showRoman = false;
  bool _isTransliterating = false;
  _LyricsViewMode _lyricsViewMode = _LyricsViewMode.original;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _generatePreview();
      _transliterateLyricsIfNeeded();
    });
  }

  @override
  void dispose() {
    _voicePlayerStateSub?.cancel();
    _musicPlayer.dispose();
    _voicePlayer.dispose();
    _cloneService.dispose();
    super.dispose();
  }

  Future<void> _generatePreview() async {
    setState(() {
      _currentStep = _Step.cloningVoice;
      _voiceDone = false;
      _musicDone = false;
      _isPlaying = false;
      _voiceAudioPath = null;
      _musicSourceUrl = null;
      _errorMessage = null;
      _voiceSourceLabel = null;
      _qualityWarning = null;
      _musicSourceLabel = null;
    });

    try {
      final clonedFile = await _cloneService.cloneVoice(
        voiceSamplePath: widget.voiceSamplePath,
        lyrics: widget.lyrics,
        mood: widget.mood,
        genre: widget.genre,
        language: widget.language,
        referenceSong: widget.referenceSong,
      );

      if (!mounted) return;
      setState(() {
        _currentStep = _Step.generatingMusic;
        _voiceDone = true;
        _voiceSourceLabel =
            widget.referenceSong == null
                ? 'Generated from your voice sample'
                : 'Generated from your voice sample with ${widget.referenceSong!.artistName} pronunciation guidance';
        _qualityWarning =
            'This MVP uses cloned voice TTS with reference-song metadata for pronunciation guidance, so it will sound closer to your voice performing the lyrics than a fully natural sung vocal.';
      });

      final backgroundTrack = await _backgroundMusicService.findTrack(
        mood: widget.mood,
        genre: widget.genre,
        language: widget.language,
      );

      await Future<void>.delayed(const Duration(milliseconds: 180));
      if (!mounted) return;

      setState(() {
        _voiceAudioPath = clonedFile.path;
        _musicSourceUrl = backgroundTrack?.sourceUrl;
        _musicSourceLabel = backgroundTrack?.label;
        _musicDone = true;
        _currentStep = _Step.ready;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _currentStep = _Step.error;
        _errorMessage = _readableError(error);
      });
    }
  }

  String _readableError(Object error) {
    return error.toString().replaceFirst('Exception: ', '').trim();
  }

  // Transliterate lyrics if they're in a non-Latin script
  Future<void> _transliterateLyricsIfNeeded() async {
    if (!_transliterationService.needsTransliteration(widget.lyrics)) {
      return;
    }

    setState(() => _isTransliterating = true);

    try {
      final roman = await _transliterationService.transliterateLyrics(
        widget.lyrics,
        widget.language,
      );
      
      if (!mounted) return;
      setState(() {
        _romanLyrics = roman;
        _showRoman = true; // Auto-show Roman version
        _lyricsViewMode = _LyricsViewMode.both;
        _isTransliterating = false;
      });
    } catch (_) {
      // Silently fail — stay on original script
      if (mounted) setState(() => _isTransliterating = false);
    }
  }

  // ── PLAYBACK: voice + music simultaneously ──────────────────────────────────
  Future<void> _play() async {
    if (_voiceAudioPath == null) return;

    if (_isPlaying) {
      await _voicePlayer.pause();
      await _musicPlayer.pause();
      setState(() => _isPlaying = false);
      return;
    }

    await _voicePlayer.setFilePath(_voiceAudioPath!);
    await _voicePlayer.setVolume(1.0);

    var canPlayMusic = _musicSourceUrl != null;
    if (canPlayMusic) {
      try {
        await _musicPlayer.setUrl(_musicSourceUrl!);
        await _musicPlayer.setVolume(0.3);
        await _musicPlayer.setLoopMode(LoopMode.all);
      } catch (_) {
        canPlayMusic = false;
        if (mounted) {
          setState(() {
            _musicSourceUrl = null;
            _musicSourceLabel = null;
          });
        }
      }
    }

    await _voicePlayerStateSub?.cancel();
    _voicePlayerStateSub = _voicePlayer.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed && mounted) {
        _musicPlayer.stop();
        setState(() => _isPlaying = false);
      }
    });

    setState(() => _isPlaying = true);

    await Future.wait([
      _voicePlayer.play(),
      if (canPlayMusic) _musicPlayer.play(),
    ]);
  }

  // ── SHARE ───────────────────────────────────────────────────────────────────
  Future<void> _share() async {
    if (_voiceAudioPath == null) return;
    await Share.shareXFiles(
      [XFile(_voiceAudioPath!)],
      subject: '"${widget.songTitle}" — AI voice cover',
      text: 'My AI song "${widget.songTitle}" in my cloned voice 🎤',
    );
  }

  // ── DOWNLOAD ────────────────────────────────────────────────────────────────
  Future<void> _download() async {
    if (_voiceAudioPath == null) return;
    final docsDir = await getApplicationDocumentsDirectory();
    final safeName = widget.songTitle
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .replaceAll(' ', '_');
    final dest = File('${docsDir.path}/${safeName}_voice.wav');
    await File(_voiceAudioPath!).copy(dest.path);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Saved to Documents/${safeName}_voice.wav'),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  // ── BUILD ───────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: Text(
          '"${widget.songTitle}"',
          style: const TextStyle(fontSize: 16),
        ),
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
              // ── Song info card ───────────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [cs.primaryContainer, cs.secondaryContainer],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        Icons.graphic_eq_rounded,
                        color: cs.primary,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '"${widget.songTitle}"',
                            style: tt.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: cs.onPrimaryContainer,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 6,
                            children: [
                              _SmallChip(label: widget.mood, cs: cs),
                              _SmallChip(label: widget.genre, cs: cs),
                              _SmallChip(label: widget.language, cs: cs),
                              if (widget.referenceSong != null)
                                _SmallChip(
                                  label: widget.referenceSong!.artistName,
                                  cs: cs,
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 28),

              // ── Pipeline steps ───────────────────────────────────────────
              _PipelineSteps(
                currentStep: _currentStep,
                voiceDone: _voiceDone,
                musicDone: _musicDone,
                cs: cs,
                tt: tt,
              ),

              if (_currentStep == _Step.cloningVoice ||
                  _currentStep == _Step.generatingMusic) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    'We are sending your recording and lyrics to the voice backend, then saving the returned WAV locally on your device.',
                    style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              ],

              // ── Ready ────────────────────────────────────────────────────
              if (_currentStep == _Step.ready) ...[
                // Voice source label
                if (_voiceSourceLabel != null)
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: cs.primaryContainer.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: cs.primary.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.check_circle_outline_rounded,
                          color: cs.primary,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _voiceSourceLabel!,
                            style: tt.labelMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: cs.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                if (_qualityWarning != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: cs.tertiaryContainer.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline_rounded,
                          color: cs.onTertiaryContainer,
                          size: 18,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _qualityWarning!,
                            style: tt.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 20),

                // Play button
                SizedBox(
                  height: 72,
                  child: FilledButton.icon(
                    onPressed: _play,
                    style: FilledButton.styleFrom(
                      backgroundColor: _isPlaying ? cs.error : cs.primary,
                      foregroundColor: cs.onPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      elevation: 6,
                    ),
                    icon: Icon(
                      _isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: 32,
                    ),
                    label: Text(
                      _isPlaying
                          ? 'Pause'
                          : _musicSourceUrl != null
                          ? 'Play with Background Music'
                          : 'Play My Song',
                      style: tt.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: cs.onPrimary,
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 14),

                // Music status
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color:
                        _musicSourceUrl != null
                            ? cs.surfaceContainerHighest
                            : cs.errorContainer.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _musicSourceUrl != null
                            ? Icons.music_note_rounded
                            : Icons.music_off_rounded,
                        size: 18,
                        color: _musicSourceUrl != null ? cs.primary : cs.error,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _musicSourceUrl != null
                              ? '${_musicSourceLabel ?? '${widget.mood} instrumental'} • 30% volume'
                              : 'Background music unavailable — vocals only',
                          style: tt.bodySmall?.copyWith(
                            color:
                                _musicSourceUrl != null
                                    ? cs.onSurfaceVariant
                                    : cs.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),

                // Share + Save row
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _share,
                        icon: const Icon(Icons.share_rounded),
                        label: const Text('Share'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _download,
                        icon: const Icon(Icons.download_rounded),
                        label: const Text('Save'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 24),

                // Lyrics
                if (_isTransliterating)
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      children: [
                        SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              cs.primary,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Making lyrics readable...',
                          style: tt.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  _LyricsCard(
                    lyrics: _romanLyrics ?? widget.lyrics,
                    originalLyrics: widget.lyrics,
                    romanLyrics: _romanLyrics,
                    showRoman: _showRoman,
                    onToggle: () {
                      setState(() => _showRoman = !_showRoman);
                    },
                    viewMode: _lyricsViewMode,
                    onViewModeChanged: (mode) {
                      setState(() {
                        _lyricsViewMode = mode;
                        _showRoman = mode != _LyricsViewMode.original;
                      });
                    },
                    cs: cs,
                    tt: tt,
                  ),
              ],

              if (_currentStep == _Step.error) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: cs.errorContainer,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Could not generate the voice preview',
                        style: tt.titleSmall?.copyWith(
                          color: cs.onErrorContainer,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _errorMessage ??
                            'An unexpected error happened while calling the voice backend.',
                        style: tt.bodyMedium?.copyWith(
                          color: cs.onErrorContainer,
                        ),
                      ),
                      const SizedBox(height: 14),
                      FilledButton.icon(
                        onPressed: _generatePreview,
                        style: FilledButton.styleFrom(
                          backgroundColor: cs.error,
                          foregroundColor: cs.onError,
                        ),
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Try Again'),
                      ),
                    ],
                  ),
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

// ─── PIPELINE STEPS UI ────────────────────────────────────────────────────────
enum _Step { cloningVoice, generatingMusic, ready, error }

class _PipelineSteps extends StatelessWidget {
  const _PipelineSteps({
    required this.currentStep,
    required this.voiceDone,
    required this.musicDone,
    required this.cs,
    required this.tt,
  });

  final _Step currentStep;
  final bool voiceDone;
  final bool musicDone;
  final ColorScheme cs;
  final TextTheme tt;

  @override
  Widget build(BuildContext context) {
    final steps = [
      _StepData(
        icon: Icons.record_voice_over_rounded,
        title: 'Uploading your sample',
        subtitle: 'Sending your recording and lyrics to the voice backend',
        isDone: voiceDone,
        isActive: !voiceDone && currentStep != _Step.error,
      ),
      _StepData(
        icon: Icons.music_note_rounded,
        title: 'Generating cloned vocals',
        subtitle: 'XTTS-v2 renders your lyrics in your voice tone',
        isDone: musicDone,
        isActive: !musicDone && currentStep != _Step.error,
      ),
      _StepData(
        icon: Icons.auto_awesome_rounded,
        title: 'Preview ready',
        subtitle: 'Your cloned vocal file is ready to play and save',
        isDone: currentStep == _Step.ready,
        isActive: voiceDone && musicDone && currentStep != _Step.ready,
      ),
    ];

    return Column(
      children:
          steps.map((s) {
            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color:
                    s.isDone
                        ? cs.primaryContainer.withValues(alpha: 0.4)
                        : s.isActive
                        ? cs.surfaceContainerHighest
                        : cs.surfaceContainerHighest.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color:
                      s.isDone
                          ? cs.primary.withValues(alpha: 0.3)
                          : s.isActive
                          ? cs.outline.withValues(alpha: 0.3)
                          : cs.outline.withValues(alpha: 0.1),
                ),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 40,
                    height: 40,
                    child:
                        s.isDone
                            ? Container(
                              decoration: BoxDecoration(
                                color: cs.primary.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                Icons.check_rounded,
                                color: cs.primary,
                                size: 22,
                              ),
                            )
                            : s.isActive
                            ? Padding(
                              padding: const EdgeInsets.all(8),
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: cs.primary,
                              ),
                            )
                            : Container(
                              decoration: BoxDecoration(
                                color: cs.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                s.icon,
                                color: cs.onSurfaceVariant.withValues(
                                  alpha: 0.4,
                                ),
                                size: 20,
                              ),
                            ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.title,
                          style: tt.labelLarge?.copyWith(
                            color:
                                s.isDone || s.isActive
                                    ? cs.onSurface
                                    : cs.onSurface.withValues(alpha: 0.4),
                            fontWeight:
                                s.isDone || s.isActive
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                          ),
                        ),
                        Text(
                          s.subtitle,
                          style: tt.labelSmall?.copyWith(
                            color: cs.onSurfaceVariant.withValues(
                              alpha: s.isDone ? 0.8 : 0.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
    );
  }
}

class _StepData {
  const _StepData({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.isDone,
    required this.isActive,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final bool isDone;
  final bool isActive;
}

// ─── LYRICS CARD ──────────────────────────────────────────────────────────────
class _LyricsCard extends StatelessWidget {
  const _LyricsCard({
    required this.lyrics,
    required this.originalLyrics,
    this.romanLyrics,
    required this.showRoman,
    required this.onToggle,
    required this.viewMode,
    required this.onViewModeChanged,
    required this.cs,
    required this.tt,
  });
  
  final String lyrics;
  final String originalLyrics;
  final String? romanLyrics;
  final bool showRoman;
  final VoidCallback onToggle;
  final _LyricsViewMode viewMode;
  final ValueChanged<_LyricsViewMode> onViewModeChanged;
  final ColorScheme cs;
  final TextTheme tt;

  @override
  Widget build(BuildContext context) {
    final originalLines = originalLyrics.split('\n');
    final romanLines = romanLyrics?.split('\n');
    final canShowRoman = romanLines != null;
    final effectiveViewMode = canShowRoman ? viewMode : _LyricsViewMode.original;

    final lines =
        effectiveViewMode == _LyricsViewMode.hinglish && romanLines != null
            ? romanLines
            : originalLines;
    
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Lyrics',
                style: tt.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: cs.primary,
                ),
              ),
              const Spacer(),
              if (canShowRoman)
                SegmentedButton<_LyricsViewMode>(
                  segments: const [
                    ButtonSegment(
                      value: _LyricsViewMode.original,
                      label: Text('Original'),
                    ),
                    ButtonSegment(
                      value: _LyricsViewMode.hinglish,
                      label: Text('Hinglish'),
                    ),
                    ButtonSegment(
                      value: _LyricsViewMode.both,
                      label: Text('Both'),
                    ),
                  ],
                  selected: {effectiveViewMode},
                  onSelectionChanged: (set) {
                    onViewModeChanged(set.first);
                  },
                ),
            ],
          ),
          const SizedBox(height: 14),
          ...List.generate(lines!.length, (i) {
            final line = lines[i];
            final isSection = RegExp(
              r'^\[(Verse|Chorus|Bridge|Outro|Pre-Chorus)',
              caseSensitive: false,
            ).hasMatch(line.trim());

            if (isSection) {
              return Padding(
                padding: const EdgeInsets.only(top: 16, bottom: 4),
                child: Text(
                  line.trim(),
                  style: tt.labelMedium?.copyWith(
                    color: cs.primary,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
              );
            }
            if (line.trim().isEmpty) return const SizedBox(height: 4);

            final useBoth = effectiveViewMode == _LyricsViewMode.both && romanLines != null;
            if (!useBoth) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  line,
                  style: tt.bodyMedium?.copyWith(
                    color: cs.onSurface,
                    height: 1.65,
                  ),
                ),
              );
            }

            final romanLine = i < romanLines.length ? romanLines[i] : '';
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    originalLines[i],
                    style: tt.bodyMedium?.copyWith(
                      color: cs.onSurface,
                      height: 1.6,
                    ),
                  ),
                  if (romanLine.trim().isNotEmpty &&
                      romanLine.trim() != originalLines[i].trim())
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        romanLine,
                        style: tt.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                          height: 1.35,
                        ),
                      ),
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

enum _LyricsViewMode { original, hinglish, both }

// ─── SMALL CHIP ───────────────────────────────────────────────────────────────
class _SmallChip extends StatelessWidget {
  const _SmallChip({required this.label, required this.cs});
  final String label;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: cs.onPrimaryContainer,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
