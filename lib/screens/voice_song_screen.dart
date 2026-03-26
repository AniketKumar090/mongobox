import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/saved_voice_song.dart';
import '../models/song_reference.dart';
import '../services/saved_voice_song_service.dart';
import '../services/audio_session_service.dart';
import '../services/background_music_service.dart';
import '../services/voice_clone_service.dart';
import '../theme/lyric_screen_theme.dart';
import '../widgets/flow_step_header.dart';
import 'saved_voice_songs_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// VoiceSongScreen
//
// Clones the user's voice in the dominant language only, then plays it back.
// ─────────────────────────────────────────────────────────────────────────────

enum _CloneStep { cloning, ready, error }

class VoiceSongScreen extends StatefulWidget {
  const VoiceSongScreen({
    super.key,
    required this.songTitle,
    required this.hindiLyrics,
    required this.englishLyrics,
    required this.dominantLanguage, // 'Hindi' or 'English'
    required this.mood,
    required this.genre,
    this.referenceSong,
    required this.voiceSamplePath,
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
  final String voiceSamplePath;

  @override
  State<VoiceSongScreen> createState() => _VoiceSongScreenState();
}

class _VoiceSongScreenState extends State<VoiceSongScreen> {
  final _musicPlayer = AudioPlayer();
  final _voicePlayer = AudioPlayer();
  final _cloneService = VoiceCloneService();
  final _bgMusicService = BackgroundMusicService();
  final _savedSongsService = SavedVoiceSongService();

  // ── Clone result ───────────────────────────────────────────────────────────
  String? _clonePath;

  // ── Background music ───────────────────────────────────────────────────────
  String? _musicSourceUrl;
  String? _musicSourceLabel;

  // ── UI state ───────────────────────────────────────────────────────────────
  _CloneStep _step = _CloneStep.cloning;
  bool _isPlaying = false;
  bool _isSaving = false;
  String? _errorMessage;
  StreamSubscription<PlayerState>? _voiceStateSub;
  double _voiceSpeed = 1.2;
  double _voiceVolume = 0.6;
  double _musicVolume = 1.0;

  double get _maxVoiceCap => _musicVolume > 1.0 ? 1.0 : _musicVolume;

  void _reconcileVoiceToMusicCap() {
    final cap = _maxVoiceCap;
    if (_voiceVolume > cap) _voiceVolume = cap;
  }

  Future<void> _applyVoiceVolume(double v) async {
    final clamped = v.clamp(0.4, _maxVoiceCap);
    setState(() => _voiceVolume = clamped);
    await _voicePlayer.setVolume(_voiceVolume);
  }

  Future<void> _applyMusicVolume(double v) async {
    setState(() {
      _musicVolume = v;
      _reconcileVoiceToMusicCap();
    });
    await _musicPlayer.setVolume(_musicVolume);
    await _voicePlayer.setVolume(_voiceVolume);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startCloning());
  }

  @override
  void dispose() {
    _voiceStateSub?.cancel();
    _musicPlayer.dispose();
    _voicePlayer.dispose();
    _cloneService.dispose();
    super.dispose();
  }

  // ── CLONING ───────────────────────────────────────────────────────────────
  Future<void> _startCloning() async {
    setState(() {
      _step = _CloneStep.cloning;
      _clonePath = null;
      _musicSourceUrl = null;
      _errorMessage = null;
      _isPlaying = false;
    });

    final language = widget.dominantLanguage;
    final lyrics =
        language == 'Hindi' ? widget.hindiLyrics : widget.englishLyrics;

    try {
      final file = await _cloneService.cloneVoice(
        voiceSamplePath: widget.voiceSamplePath,
        lyrics: lyrics,
        mood: widget.mood,
        genre: widget.genre,
        language: language,
        referenceSong: widget.referenceSong,
      );
      if (!mounted) return;
      await _finalise(file.path);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _step = _CloneStep.error;
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _finalise(String path) async {
    final language = widget.dominantLanguage;

    String? musicUrl;
    String? musicLabel;
    if ((widget.referenceSong?.videoId ?? '').isEmpty) {
      final bgTrack = await _bgMusicService.findTrack(
        mood: widget.mood,
        genre: widget.genre,
        language: language,
        referenceTrackTitle: widget.referenceSong?.trackName ?? '',
        referenceArtistName: widget.referenceSong?.artistName ?? '',
      );
      musicUrl = bgTrack?.sourceUrl;
      musicLabel = bgTrack?.label;
    } else {
      musicLabel = 'Mixed with original instrumental';
    }

    if (!mounted) return;
    setState(() {
      _clonePath = path;
      _musicSourceUrl = musicUrl;
      _musicSourceLabel = musicLabel;
      _step = _CloneStep.ready;
    });
  }

  // ── PLAYBACK ──────────────────────────────────────────────────────────────
  Future<void> _play() async {
    if (_clonePath == null) return;

    if (_isPlaying) {
      await _voicePlayer.pause();
      await _musicPlayer.pause();
      setState(() => _isPlaying = false);
      return;
    }

    final absPath = File(_clonePath!).absolute.path;
    if (!File(absPath).existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Audio file is missing. Try generating the clone again.',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    try {
      await AppAudioSessionService.activatePlayback();

      // Reset player state so replay after "completed" starts from the beginning
      // (just_audio can otherwise stay at the end and play() is silent).
      await _voicePlayer.stop();
      await _voicePlayer.setFilePath(absPath);
      await _voicePlayer.setSpeed(_voiceSpeed);
      _reconcileVoiceToMusicCap();
      await _voicePlayer.setVolume(_voiceVolume);
      await _voicePlayer.seek(Duration.zero);

      var canPlayMusic = _musicSourceUrl != null;
      if (canPlayMusic) {
        try {
          await _musicPlayer.stop();
          await _musicPlayer.setUrl(_musicSourceUrl!);
          await _musicPlayer.setSpeed(_voiceSpeed);
          await _musicPlayer.setVolume(_musicVolume);
          await _musicPlayer.setLoopMode(LoopMode.all);
          await _musicPlayer.seek(Duration.zero);
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

      await _voiceStateSub?.cancel();
      _voiceStateSub = _voicePlayer.playerStateStream.listen((s) {
        if (s.processingState == ProcessingState.completed && mounted) {
          _musicPlayer.stop();
          setState(() => _isPlaying = false);
        }
      });

      setState(() => _isPlaying = true);
      await Future.wait([
        _voicePlayer.play(),
        if (canPlayMusic) _musicPlayer.play(),
      ]);
    } catch (e, st) {
      debugPrint('VoiceSongScreen._play failed: $e\n$st');
      if (mounted) {
        setState(() => _isPlaying = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not play: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  // ── SHARE / DOWNLOAD ──────────────────────────────────────────────────────
  Future<void> _share() async {
    if (_clonePath == null) return;
    await Share.shareXFiles(
      [XFile(_clonePath!)],
      subject:
          '"${widget.songTitle}" — AI voice cover (${widget.dominantLanguage})',
      text:
          'My AI song "${widget.songTitle}" (${widget.dominantLanguage} version) in my cloned voice 🎤',
    );
  }

  Future<void> _download() async {
    if (_clonePath == null || _isSaving) return;
    setState(() => _isSaving = true);
    final docsDir = await getApplicationDocumentsDirectory();
    try {
      final libraryDir = Directory('${docsDir.path}/saved_voice_songs');
      if (!await libraryDir.exists()) {
        await libraryDir.create(recursive: true);
      }

      final safeName = widget.songTitle
          .replaceAll(RegExp(r'[^\w\s]'), '')
          .trim()
          .replaceAll(RegExp(r'\s+'), '_');
      final lang = widget.dominantLanguage.toLowerCase();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName =
          '${safeName.isEmpty ? 'song' : safeName}_${lang}_$timestamp.wav';
      final dest = File('${libraryDir.path}/$fileName');
      await File(_clonePath!).copy(dest.path);

      final savedSong = SavedVoiceSong(
        id: '$safeName-$timestamp',
        title: widget.songTitle,
        filePath: dest.path,
        language: widget.dominantLanguage,
        mood: widget.mood,
        genre: widget.genre,
        createdAtIso: DateTime.now().toIso8601String(),
        hasBackgroundMusic:
            _musicSourceUrl != null ||
            ((widget.referenceSong?.videoId ?? '').isNotEmpty),
        backgroundMusicUrl: _musicSourceUrl ?? '',
        backgroundMusicLabel: _musicSourceLabel ?? '',
      );
      await _savedSongsService.saveSong(savedSong);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Saved. You can replay "${widget.songTitle}" anytime.'),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: 'Open',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SavedVoiceSongsScreen(),
                ),
              );
            },
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not save song: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  // ── BUILD ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final pageTheme = lyricScreenTheme(context);
    final cs = pageTheme.colorScheme;
    final tt = pageTheme.textTheme;

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
                        child: FlowStepHeader(
                          title: 'Preview your cloned song',
                          subtitle:
                              'Your voice model is being prepared, then you can listen, tweak the mix, and save the final version.',
                          steps: const ['Song', 'Voice', 'Preview'],
                          currentStep: 3,
                          actions: [
                            OutlinedButton.icon(
                              onPressed: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder:
                                        (_) => const SavedVoiceSongsScreen(),
                                  ),
                                );
                              },
                              icon: const Icon(
                                Icons.library_music_rounded,
                                size: 18,
                              ),
                              label: const Text('Saved songs'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPadding,
                        0,
                        horizontalPadding,
                        24,
                      ),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: contentMaxWidth,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _SongInfoCard(
                                songTitle: widget.songTitle,
                                mood: widget.mood,
                                genre: widget.genre,
                                dominantLanguage: widget.dominantLanguage,
                                referenceSong: widget.referenceSong,
                                cs: cs,
                                tt: tt,
                              ),
                              const SizedBox(height: 28),
                              _StepRow(
                                icon:
                                    widget.dominantLanguage == 'Hindi'
                                        ? Icons.translate_rounded
                                        : Icons.language_rounded,
                                title: '${widget.dominantLanguage} voice clone',
                                subtitle:
                                    _step == _CloneStep.error
                                        ? 'Failed: ${_errorMessage ?? 'unknown'}'
                                        : _step == _CloneStep.ready
                                        ? 'Cloned successfully'
                                        : 'Cloning in ${widget.dominantLanguage}…',
                                isDone: _step == _CloneStep.ready,
                                isFailed: _step == _CloneStep.error,
                                isActive: _step == _CloneStep.cloning,
                                cs: cs,
                                tt: tt,
                              ),
                              if (_step == _CloneStep.ready) ...[
                                const SizedBox(height: 10),
                                _StepRow(
                                  icon: Icons.auto_awesome_rounded,
                                  title: 'Preview ready',
                                  subtitle:
                                      'Your cloned vocal is ready to play',
                                  isDone: true,
                                  isFailed: false,
                                  isActive: false,
                                  cs: cs,
                                  tt: tt,
                                ),
                              ],
                              if (_step == _CloneStep.error) ...[
                                const SizedBox(height: 16),
                                _ErrorCard(
                                  message: _errorMessage ?? 'Unknown error',
                                  onRetry: _startCloning,
                                  cs: cs,
                                  tt: tt,
                                ),
                              ],
                              if (_step == _CloneStep.ready) ...[
                                const SizedBox(height: 16),
                                SizedBox(
                                  height: 72,
                                  child: FilledButton.icon(
                                    onPressed: _play,
                                    style: FilledButton.styleFrom(
                                      backgroundColor:
                                          _isPlaying ? cs.error : cs.primary,
                                      foregroundColor: cs.onPrimary,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      elevation: 0,
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
                                const SizedBox(height: 12),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color:
                                        _musicSourceUrl != null
                                            ? cs.surfaceContainerHighest
                                            : cs.errorContainer.withValues(
                                              alpha: 0.4,
                                            ),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        _musicSourceUrl != null
                                            ? Icons.music_note_rounded
                                            : Icons.music_off_rounded,
                                        size: 18,
                                        color:
                                            _musicSourceUrl != null
                                                ? cs.primary
                                                : cs.error,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          _musicSourceUrl != null
                                              ? '${_musicSourceLabel ?? '${widget.mood} instrumental'} • music ${(100 * _musicVolume).round()}% / vocal ${(100 * _voiceVolume).round()}%'
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
                                const SizedBox(height: 12),
                                Container(
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: cs.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: cs.outline.withValues(alpha: 0.2),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Vocal speed ${_voiceSpeed.toStringAsFixed(2)}x',
                                        style: tt.labelLarge?.copyWith(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      Slider(
                                        value: _voiceSpeed,
                                        min: 1.0,
                                        max: 1.5,
                                        divisions: 10,
                                        label:
                                            '${_voiceSpeed.toStringAsFixed(2)}x',
                                        onChanged: (v) async {
                                          setState(() => _voiceSpeed = v);
                                          await _voicePlayer.setSpeed(v);
                                          await _musicPlayer.setSpeed(v);
                                        },
                                      ),
                                      Text(
                                        'Mix balance — vocal level cannot exceed music (same-scale); music boosts up to 200%',
                                        style: tt.bodySmall?.copyWith(
                                          color: cs.onSurfaceVariant,
                                        ),
                                      ),
                                      Builder(
                                        builder: (context) {
                                          final voiceCap = math.min(
                                            1.0,
                                            _maxVoiceCap,
                                          );
                                          final voiceSliderMax = math.max(
                                            0.401,
                                            voiceCap,
                                          );
                                          final voiceSliderValue = _voiceVolume
                                              .clamp(0.4, voiceSliderMax);
                                          final voiceRange =
                                              voiceSliderMax - 0.4;
                                          return LayoutBuilder(
                                            builder: (
                                              context,
                                              sliderConstraints,
                                            ) {
                                              final stackSliders =
                                                  sliderConstraints.maxWidth <
                                                  520;
                                              final vocalControl = Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    'Vocals',
                                                    style: tt.labelSmall,
                                                  ),
                                                  Slider(
                                                    value: voiceSliderValue,
                                                    min: 0.4,
                                                    max: voiceSliderMax,
                                                    divisions:
                                                        voiceRange < 0.02
                                                            ? null
                                                            : math.max(
                                                              1,
                                                              (voiceRange / 0.1)
                                                                  .round(),
                                                            ),
                                                    label:
                                                        '${(100 * voiceSliderValue).round()}%',
                                                    onChanged:
                                                        (v) async =>
                                                            _applyVoiceVolume(
                                                              v,
                                                            ),
                                                  ),
                                                ],
                                              );
                                              final musicControl = Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    'Music',
                                                    style: tt.labelSmall,
                                                  ),
                                                  Slider(
                                                    value: _musicVolume,
                                                    min: 0.4,
                                                    max: 2.0,
                                                    divisions: 16,
                                                    label:
                                                        '${(100 * _musicVolume).round()}%',
                                                    onChanged:
                                                        (v) async =>
                                                            _applyMusicVolume(
                                                              v,
                                                            ),
                                                  ),
                                                ],
                                              );

                                              if (stackSliders) {
                                                return Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    vocalControl,
                                                    const SizedBox(height: 8),
                                                    musicControl,
                                                  ],
                                                );
                                              }

                                              return Row(
                                                children: [
                                                  Expanded(child: vocalControl),
                                                  const SizedBox(width: 12),
                                                  Expanded(child: musicControl),
                                                ],
                                              );
                                            },
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 16),
                                LayoutBuilder(
                                  builder: (context, actionConstraints) {
                                    final stackActions =
                                        actionConstraints.maxWidth < 520;
                                    final shareButton = OutlinedButton.icon(
                                      onPressed: _share,
                                      icon: const Icon(Icons.share_rounded),
                                      label: const Text('Share'),
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 14,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                        ),
                                      ),
                                    );
                                    final saveButton = OutlinedButton.icon(
                                      onPressed: _download,
                                      icon: Icon(
                                        _isSaving
                                            ? Icons.hourglass_top_rounded
                                            : Icons.bookmark_add_rounded,
                                      ),
                                      label: Text(
                                        _isSaving ? 'Saving...' : 'Save',
                                      ),
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 14,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                        ),
                                      ),
                                    );

                                    if (stackActions) {
                                      return Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          shareButton,
                                          const SizedBox(height: 12),
                                          saveButton,
                                        ],
                                      );
                                    }

                                    return Row(
                                      children: [
                                        Expanded(child: shareButton),
                                        const SizedBox(width: 12),
                                        Expanded(child: saveButton),
                                      ],
                                    );
                                  },
                                ),
                                const SizedBox(height: 24),
                                _LyricsSection(
                                  lyrics:
                                      widget.dominantLanguage == 'Hindi'
                                          ? (widget
                                                      .hinglishLyrics
                                                      ?.isNotEmpty ==
                                                  true
                                              ? widget.hinglishLyrics!
                                              : widget.hindiLyrics)
                                          : widget.englishLyrics,
                                  language: widget.dominantLanguage,
                                  cs: cs,
                                  tt: tt,
                                ),
                              ],
                              const SizedBox(height: 40),
                            ],
                          ),
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

// ─── SONG INFO CARD ───────────────────────────────────────────────────────────
class _SongInfoCard extends StatelessWidget {
  const _SongInfoCard({
    required this.songTitle,
    required this.mood,
    required this.genre,
    required this.dominantLanguage,
    required this.referenceSong,
    required this.cs,
    required this.tt,
  });
  final String songTitle;
  final String mood;
  final String genre;
  final String dominantLanguage;
  final SongReference? referenceSong;
  final ColorScheme cs;
  final TextTheme tt;

  @override
  Widget build(BuildContext context) {
    return Container(
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
            child: Icon(Icons.graphic_eq_rounded, color: cs.primary, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '"$songTitle"',
                  style: tt.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: cs.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    _SmallChip(label: mood, cs: cs),
                    _SmallChip(label: genre, cs: cs),
                    _SmallChip(label: dominantLanguage, cs: cs),
                    if (referenceSong != null)
                      _SmallChip(label: referenceSong!.artistName, cs: cs),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── STEP ROW ─────────────────────────────────────────────────────────────────
class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.isDone,
    required this.isFailed,
    required this.isActive,
    required this.cs,
    required this.tt,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final bool isDone;
  final bool isFailed;
  final bool isActive;
  final ColorScheme cs;
  final TextTheme tt;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color:
            isDone
                ? cs.primaryContainer.withValues(alpha: 0.4)
                : isFailed
                ? cs.errorContainer.withValues(alpha: 0.3)
                : cs.surfaceContainerHighest.withValues(
                  alpha: isActive ? 1 : 0.4,
                ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color:
              isDone
                  ? cs.primary.withValues(alpha: 0.3)
                  : isFailed
                  ? cs.error.withValues(alpha: 0.3)
                  : cs.outline.withValues(alpha: isActive ? 0.3 : 0.1),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            height: 40,
            child:
                isDone
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
                    : isFailed
                    ? Container(
                      decoration: BoxDecoration(
                        color: cs.errorContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.close_rounded,
                        color: cs.error,
                        size: 22,
                      ),
                    )
                    : isActive
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
                        icon,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.4),
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
                  title,
                  style: tt.labelLarge?.copyWith(
                    color:
                        isFailed
                            ? cs.error
                            : isDone || isActive
                            ? cs.onSurface
                            : cs.onSurface.withValues(alpha: 0.4),
                    fontWeight:
                        isDone || isActive
                            ? FontWeight.bold
                            : FontWeight.normal,
                  ),
                ),
                Text(
                  subtitle,
                  style: tt.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant.withValues(
                      alpha: isDone ? 0.8 : 0.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── LYRICS SECTION ───────────────────────────────────────────────────────────
class _LyricsSection extends StatelessWidget {
  const _LyricsSection({
    required this.lyrics,
    required this.language,
    required this.cs,
    required this.tt,
  });
  final String lyrics;
  final String language;
  final ColorScheme cs;
  final TextTheme tt;

  @override
  Widget build(BuildContext context) {
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
          Text(
            'Lyrics — $language',
            style: tt.labelLarge?.copyWith(
              fontWeight: FontWeight.bold,
              color: cs.primary,
            ),
          ),
          const SizedBox(height: 14),
          _PlainLines(lines: lyrics.split('\n'), cs: cs, tt: tt),
        ],
      ),
    );
  }
}

class _PlainLines extends StatelessWidget {
  const _PlainLines({required this.lines, required this.cs, required this.tt});
  final List<String> lines;
  final ColorScheme cs;
  final TextTheme tt;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children:
          lines.map((line) {
            if (line.trim().isEmpty) return const SizedBox(height: 4);
            final isHeader = RegExp(
              r'^\[(Verse|Chorus|Bridge|Outro|Pre-Chorus)',
              caseSensitive: false,
            ).hasMatch(line.trim());
            if (isHeader) {
              return Padding(
                padding: const EdgeInsets.only(top: 16, bottom: 4),
                child: Text(
                  line.trim(),
                  style: tt.labelMedium?.copyWith(
                    color: cs.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              );
            }
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
          }).toList(),
    );
  }
}

// ─── ERROR CARD ───────────────────────────────────────────────────────────────
class _ErrorCard extends StatelessWidget {
  const _ErrorCard({
    required this.message,
    required this.onRetry,
    required this.cs,
    required this.tt,
  });
  final String message;
  final VoidCallback onRetry;
  final ColorScheme cs;
  final TextTheme tt;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Could not generate voice preview',
            style: tt.titleSmall?.copyWith(
              color: cs.onErrorContainer,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: tt.bodyMedium?.copyWith(color: cs.onErrorContainer),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: onRetry,
            style: FilledButton.styleFrom(
              backgroundColor: cs.error,
              foregroundColor: cs.onError,
            ),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try Again'),
          ),
        ],
      ),
    );
  }
}

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
