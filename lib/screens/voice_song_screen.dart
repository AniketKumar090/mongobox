import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/saved_voice_song.dart';
import '../models/song_reference.dart';
import '../services/saved_voice_song_service.dart';
import '../services/audio_session_service.dart';
import '../services/background_music_service.dart';
import '../services/voice_clone_service.dart';
import '../widgets/song_flow_timeline.dart';
import 'saved_voice_songs_screen.dart';

// ─── PALETTE — mirrors VoiceSampleScreen's _HP ────────────────────────────────
class _P {
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
  static const greenSoft = Color(0xFFEAFAF2);
  static const greenBorder = Color(0xFFB3EDD3);
  static const red = Color(0xFFFF3B30);
  static const redSoft = Color(0xFFFFF0EE);
  static const redBorder = Color(0xFFFFCCCC);
}

enum _CloneStep { cloning, ready, error }

enum _PendingCloneExitAction { saveWhenReady, stopProcess }

class VoiceSongScreen extends StatefulWidget {
  const VoiceSongScreen({
    super.key,
    required this.songTitle,
    required this.hindiLyrics,
    required this.englishLyrics,
    required this.dominantLanguage,
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
  final _scrollController = ScrollController();

  String? _clonePath;
  String? _musicSourceUrl;
  String? _musicSourceLabel;
  Map<String, String>? _musicSourceHeaders;
  bool _mixIncluded = false;

  _CloneStep _step = _CloneStep.cloning;
  bool _isPlaying = false;
  bool _isSaving = false;
  bool _showLyrics = false;
  bool _returnHomeWhenReady = false;
  bool _isLeavingScreen = false;
  String? _activeCloneRequestId;
  String? _errorMessage;
  StreamSubscription<PlayerState>? _voiceStateSub;

  double _voiceSpeed = 1.2;
  double _voiceVolume = 0.6;
  double _musicVolume = 1.0;

  double get _maxVoiceCap => _musicVolume > 1.0 ? 1.0 : _musicVolume;
  bool get _isHindiDominant =>
      widget.dominantLanguage.trim().toLowerCase().contains('hindi');
  String get _cloneLyrics =>
      _isHindiDominant
          ? ((widget.hinglishLyrics?.trim().isNotEmpty ?? false)
              ? widget.hinglishLyrics!
              : widget.hindiLyrics)
          : widget.englishLyrics;

  void _reconcileVoiceCap() {
    if (_voiceVolume > _maxVoiceCap) _voiceVolume = _maxVoiceCap;
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
    _scrollController.dispose();
    super.dispose();
  }

  // ── Cloning ───────────────────────────────────────────────────────────────
  Future<void> _startCloning() async {
    final requestId = DateTime.now().microsecondsSinceEpoch.toString();
    _activeCloneRequestId = requestId;
    setState(() {
      _step = _CloneStep.cloning;
      _clonePath = null;
      _musicSourceUrl = null;
      _errorMessage = null;
      _isPlaying = false;
    });
    final language = widget.dominantLanguage;
    try {
      final file = await _cloneService.cloneVoice(
        voiceSamplePath: widget.voiceSamplePath,
        lyrics: _cloneLyrics,
        requestId: requestId,
        mood: widget.mood,
        genre: widget.genre,
        language: language,
        referenceSong: widget.referenceSong,
      );
      if (_activeCloneRequestId == requestId) {
        _activeCloneRequestId = null;
      }
      if (!mounted) return;
      await _finalise(file);
    } catch (e) {
      if (_activeCloneRequestId == requestId) {
        _activeCloneRequestId = null;
      }
      if (!mounted) return;
      setState(() {
        _step = _CloneStep.error;
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _finalise(VoiceCloneResult result) async {
    final language = widget.dominantLanguage;
    String? musicUrl;
    String? musicLabel;
    Map<String, String>? musicHeaders;

    if (result.mixIncluded) {
      musicLabel =
          result.mixLabel ?? 'Original instrumental mixed into preview';
    } else {
      final bgTrack = await _bgMusicService.findTrack(
        mood: widget.mood,
        genre: widget.genre,
        language: language,
        referenceTrackTitle: widget.referenceSong?.trackName ?? '',
        referenceArtistName: widget.referenceSong?.artistName ?? '',
      );
      musicUrl = bgTrack?.sourceUrl;
      musicLabel = bgTrack?.label;
      musicHeaders = bgTrack?.headers;
    }
    if (!mounted) return;
    setState(() {
      _clonePath = result.file.path;
      _musicSourceUrl = musicUrl;
      _musicSourceLabel = musicLabel;
      _musicSourceHeaders = musicHeaders;
      _mixIncluded = result.mixIncluded;
      _step = _CloneStep.ready;
    });

    if (_returnHomeWhenReady) {
      final didSave = await _saveCurrentSong(
        sourcePath: result.file.path,
        showSuccessSnack: false,
        showOpenLibraryAction: false,
      );
      if (!mounted) return;
      if (didSave) {
        await _returnToLyricHome();
      } else {
        setState(() => _returnHomeWhenReady = false);
        _showSnack('Could not save automatically. Please try again.');
      }
    }
  }

  // ── Playback ──────────────────────────────────────────────────────────────
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
      _showSnack('Audio file missing. Try again.');
      return;
    }
    try {
      await AppAudioSessionService.activatePlayback();
      await _voicePlayer.stop();
      await _voicePlayer.setFilePath(absPath);
      await _voicePlayer.setSpeed(_voiceSpeed);
      _reconcileVoiceCap();
      await _voicePlayer.setVolume(_voiceVolume);
      await _voicePlayer.seek(Duration.zero);
      var canPlayMusic = _musicSourceUrl != null;
      if (canPlayMusic) {
        try {
          await _musicPlayer.stop();
          await _musicPlayer.setAudioSource(
            AudioSource.uri(
              Uri.parse(_musicSourceUrl!),
              headers: _musicSourceHeaders,
            ),
          );
          await _musicPlayer.setSpeed(_voiceSpeed);
          await _musicPlayer.setVolume(_musicVolume);
          await _musicPlayer.setLoopMode(LoopMode.all);
          await _musicPlayer.seek(Duration.zero);
        } catch (_) {
          canPlayMusic = false;
          if (mounted)
            setState(() {
              _musicSourceUrl = null;
              _musicSourceLabel = null;
              _musicSourceHeaders = null;
            });
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
    } catch (e) {
      if (mounted) {
        setState(() => _isPlaying = false);
        _showSnack('Could not play: $e');
      }
    }
  }

  // ── Share / Save ──────────────────────────────────────────────────────────
  Future<void> _share() async {
    if (_clonePath == null) return;
    await Share.shareXFiles(
      [XFile(_clonePath!)],
      subject:
          '"${widget.songTitle}" — AI voice cover (${widget.dominantLanguage})',
      text: 'My AI song "${widget.songTitle}" in my cloned voice 🎤',
    );
  }

  Future<void> _download() async {
    if (_clonePath == null || _isSaving) return;
    setState(() => _isSaving = true);
    try {
      await _saveCurrentSong(
        sourcePath: _clonePath!,
        showSuccessSnack: true,
        showOpenLibraryAction: true,
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<bool> _saveCurrentSong({
    required String sourcePath,
    required bool showSuccessSnack,
    required bool showOpenLibraryAction,
  }) async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final libraryDir = Directory('${docsDir.path}/saved_voice_songs');
      if (!await libraryDir.exists()) await libraryDir.create(recursive: true);
      final safeName = widget.songTitle
          .replaceAll(RegExp(r'[^\w\s]'), '')
          .trim()
          .replaceAll(RegExp(r'\s+'), '_');
      final lang = widget.dominantLanguage.toLowerCase();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName =
          '${safeName.isEmpty ? 'song' : safeName}_${lang}_$timestamp.wav';
      final dest = File('${libraryDir.path}/$fileName');
      await File(sourcePath).copy(dest.path);
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

      if (showSuccessSnack && mounted) {
        _showSnack(
          'Saved! Tap to open library.',
          action:
              showOpenLibraryAction
                  ? _SnackAction(
                    label: 'Open',
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const SavedVoiceSongsScreen(),
                        ),
                      );
                    },
                  )
                  : null,
        );
      }
      return true;
    } catch (e) {
      if (mounted) _showSnack('Could not save: $e');
      return false;
    }
  }

  Future<void> _returnToLyricHome() async {
    if (!mounted || _isLeavingScreen) return;
    _isLeavingScreen = true;
    await _voiceStateSub?.cancel();
    await _voicePlayer.stop();
    await _musicPlayer.stop();
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _handleBackNavigation() async {
    if (_step == _CloneStep.cloning) {
      if (_returnHomeWhenReady) {
        _showSnack(
          'This song will be saved and sent home once cloning finishes.',
        );
        return;
      }

      final action = await _showPendingCloneExitDialog();
      if (!mounted || action == null) return;

      if (action == _PendingCloneExitAction.saveWhenReady) {
        setState(() => _returnHomeWhenReady = true);
        _showSnack(
          'We’ll save the song and return to Lyric Home when it is ready.',
        );
        return;
      }

      final requestId = _activeCloneRequestId;
      _activeCloneRequestId = null;
      if (requestId != null) {
        try {
          await _cloneService.cancelClone(requestId);
        } catch (e) {
          debugPrint('Voice clone cancellation warning: $e');
        }
      }

      _cloneService.dispose();
      await _returnToLyricHome();
      return;
    }

    await _returnToLyricHome();
  }

  Future<_PendingCloneExitAction?> _showPendingCloneExitDialog() {
    return showDialog<_PendingCloneExitAction>(
      context: context,
      barrierDismissible: true,
      builder:
          (dialogContext) => AlertDialog(
            backgroundColor: const Color(0xFFF8F4EE),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            title: const Text(
              'Cloning is still running',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: _P.black,
              ),
            ),
            content: const Text(
              'Do you want us to save the song when cloning completes, or stop the process and go back now?',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: _P.grey2,
                height: 1.5,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text(
                  'Cancel',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.w700,
                    color: _P.grey2,
                  ),
                ),
              ),
              TextButton(
                onPressed:
                    () => Navigator.of(
                      dialogContext,
                    ).pop(_PendingCloneExitAction.stopProcess),
                child: const Text(
                  'Stop process',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.w800,
                    color: _P.red,
                  ),
                ),
              ),
              FilledButton(
                onPressed:
                    () => Navigator.of(
                      dialogContext,
                    ).pop(_PendingCloneExitAction.saveWhenReady),
                style: FilledButton.styleFrom(
                  backgroundColor: _P.black,
                  foregroundColor: Colors.white,
                ),
                child: const Text(
                  'Save when ready',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
    );
  }

  // ── Snackbar (matches _HP style) ──────────────────────────────────────────
  void _showSnack(String msg, {_SnackAction? action}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Expanded(
                child: Text(
                  msg,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: Colors.white,
                  ),
                ),
              ),
              if (action != null) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: action.onTap,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: _P.green,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      action.label,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                        color: _P.black,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: _P.blackSoft,
          elevation: 0,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          duration: const Duration(seconds: 3),
        ),
      );
  }

  // ── BUILD ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final sw = mq.size.width;
    final hPad = sw < 600 ? sw * 0.05 : sw * 0.08;

    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _handleBackNavigation();
      },
      child: Scaffold(
        backgroundColor: _P.background,
        body: SafeArea(
          child: Column(
            children: [
              // ── Top bar ──────────────────────────────────────────────────
              Padding(
                padding: EdgeInsets.fromLTRB(hPad, 16, hPad, 12),
                child: _TopBar(
                  songTitle: widget.songTitle,
                  referenceSong: widget.referenceSong,
                  onBack: _handleBackNavigation,
                  onLibrary:
                      () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const SavedVoiceSongsScreen(),
                        ),
                      ),
                ),
              ),

              // ── Scrollable body ──────────────────────────────────────────
              Expanded(
                child: SingleChildScrollView(
                  controller: _scrollController,
                  padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Song info pill
                      _SongInfoPill(
                        songTitle: widget.songTitle,
                        mood: widget.mood,
                        genre: widget.genre,
                        language: widget.dominantLanguage,
                        referenceSong: widget.referenceSong,
                      ),
                      const SizedBox(height: 16),

                      // Step status
                      _StatusCard(
                        step: _step,
                        language: widget.dominantLanguage,
                        errorMessage: _errorMessage,
                        onRetry: _startCloning,
                      ),

                      // Ready state content
                      if (_step == _CloneStep.ready) ...[
                        const SizedBox(height: 16),

                        // ── Big play button ──────────────────────────────
                        _PlayButton(
                          isPlaying: _isPlaying,
                          hasBgMusic: _mixIncluded || _musicSourceUrl != null,
                          onPressed: _play,
                        ),
                        const SizedBox(height: 10),

                        // ── Music badge ──────────────────────────────────
                        _MusicBadge(
                          label: _musicSourceLabel,
                          hasMusic: _mixIncluded || _musicSourceUrl != null,
                        ),
                        const SizedBox(height: 12),

                        // ── Mix controls ─────────────────────────────────
                        _MixCard(
                          voiceSpeed: _voiceSpeed,
                          voiceVolume: _voiceVolume,
                          musicVolume: _musicVolume,
                          maxVoiceCap: _maxVoiceCap,
                          onSpeedChanged: (v) async {
                            setState(() => _voiceSpeed = v);
                            await _voicePlayer.setSpeed(v);
                            await _musicPlayer.setSpeed(v);
                          },
                          onVoiceVolumeChanged: (v) async {
                            final c = v.clamp(0.4, _maxVoiceCap);
                            setState(() => _voiceVolume = c);
                            await _voicePlayer.setVolume(c);
                          },
                          onMusicVolumeChanged: (v) async {
                            setState(() {
                              _musicVolume = v;
                              _reconcileVoiceCap();
                            });
                            await _musicPlayer.setVolume(v);
                            await _voicePlayer.setVolume(_voiceVolume);
                          },
                        ),
                        const SizedBox(height: 12),

                        // ── Share / Save ─────────────────────────────────
                        Row(
                          children: [
                            Expanded(
                              child: _OutlineButton(
                                icon: Icons.share_rounded,
                                label: 'Share',
                                onPressed: _share,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _OutlineButton(
                                icon:
                                    _isSaving
                                        ? Icons.hourglass_top_rounded
                                        : Icons.bookmark_add_rounded,
                                label: _isSaving ? 'Saving…' : 'Save',
                                onPressed: _download,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),

                        // ── Lyrics collapsible ────────────────────────────
                        _LyricsCard(
                          lyrics: _cloneLyrics,
                          language: widget.dominantLanguage,
                          showFull: _showLyrics,
                          onToggle:
                              () => setState(() => _showLyrics = !_showLyrics),
                          scrollController: _scrollController,
                        ),
                      ],
                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SnackAction {
  const _SnackAction({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;
}

// ─────────────────────────────────────────────────────────────────────────────
// TOP BAR
// ─────────────────────────────────────────────────────────────────────────────
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.songTitle,
    required this.referenceSong,
    required this.onBack,
    required this.onLibrary,
  });

  final String songTitle;
  final SongReference? referenceSong;
  final Future<void> Function() onBack;
  final VoidCallback onLibrary;

  @override
  Widget build(BuildContext context) {
    final displayTitle =
        referenceSong != null
            ? '${referenceSong!.trackName} — ${referenceSong!.artistName}'
            : songTitle;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SongFlowTimeline(currentStep: 3),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: onBack,
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: _P.chip,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _P.border),
                ),
                child: const Icon(
                  Icons.arrow_back_rounded,
                  size: 20,
                  color: _P.black,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Preview your song',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      color: _P.black,
                      height: 1.05,
                    ),
                  ),
                  const SizedBox(height: 3),
                  const Text(
                    'Your cloned vocal is being prepared.',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: _P.grey2,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        // Song pill row - full width, aligned with left edge
        Row(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: _P.chip,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _P.border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.music_note_rounded,
                      size: 12,
                      color: _P.grey2,
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
                          color: _P.grey1,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onLibrary,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: _P.chip,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _P.border),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.library_music_rounded,
                      size: 12,
                      color: _P.grey2,
                    ),
                    SizedBox(width: 5),
                    Text(
                      'Saved',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: _P.grey1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SONG INFO PILL
// ─────────────────────────────────────────────────────────────────────────────
class _SongInfoPill extends StatelessWidget {
  const _SongInfoPill({
    required this.songTitle,
    required this.mood,
    required this.genre,
    required this.language,
    required this.referenceSong,
  });
  final String songTitle, mood, genre, language;
  final SongReference? referenceSong;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _P.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _P.border),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: _P.black,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.graphic_eq_rounded,
              color: Colors.white,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 6),
                Text(
                  '"$songTitle"',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: _P.black,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 5,
                  runSpacing: 4,
                  children: [
                    _Chip(mood),
                    _Chip(genre),
                    _Chip(language),
                    if (referenceSong != null) _Chip(referenceSong!.artistName),
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

class _Chip extends StatelessWidget {
  const _Chip(this.label);
  final String label;
  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _P.chip,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _P.border),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: _P.grey1,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// STATUS CARD
// ─────────────────────────────────────────────────────────────────────────────
class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.step,
    required this.language,
    required this.errorMessage,
    required this.onRetry,
  });
  final _CloneStep step;
  final String language;
  final String? errorMessage;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return switch (step) {
      _CloneStep.cloning => _StatusRow(
        icon: null,
        isLoading: true,
        title: 'Cloning in $language…',
        subtitle: 'Applying your voice model to the lyrics.',
        isSuccess: false,
        isError: false,
      ),
      _CloneStep.ready => Column(
        children: [
          _StatusRow(
            icon: Icons.check_rounded,
            isLoading: false,
            title: '$language voice cloned',
            subtitle: 'Ready to preview',
            isSuccess: true,
            isError: false,
          ),
          const SizedBox(height: 8),
          _StatusRow(
            icon: Icons.auto_awesome_rounded,
            isLoading: false,
            title: 'Preview ready',
            subtitle: 'Listen, mix, and save below',
            isSuccess: true,
            isError: false,
          ),
        ],
      ),
      _CloneStep.error => _ErrorCard(
        message: errorMessage ?? 'Unknown error',
        onRetry: onRetry,
      ),
    };
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.icon,
    required this.isLoading,
    required this.title,
    required this.subtitle,
    required this.isSuccess,
    required this.isError,
  });
  final IconData? icon;
  final bool isLoading, isSuccess, isError;
  final String title, subtitle;

  @override
  Widget build(BuildContext context) {
    final bg =
        isSuccess
            ? _P.greenSoft
            : isError
            ? _P.redSoft
            : _P.card;
    final border =
        isSuccess
            ? _P.greenBorder
            : isError
            ? _P.redBorder
            : _P.border;
    final iconBg =
        isSuccess
            ? const Color(0xFF0A9B5A)
            : isError
            ? _P.red
            : _P.grey3;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child:
                isLoading
                    ? const Padding(
                      padding: EdgeInsets.all(6),
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: _P.black,
                      ),
                    )
                    : Container(
                      decoration: BoxDecoration(
                        color: iconBg,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(icon, size: 18, color: Colors.white),
                    ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color:
                        isSuccess
                            ? const Color(0xFF0A9B5A)
                            : isError
                            ? _P.red
                            : _P.black,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: _P.grey3,
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

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _P.redSoft,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _P.redBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.error_outline_rounded, size: 15, color: _P.red),
              SizedBox(width: 7),
              Text(
                'Voice clone failed',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: _P.red,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            message,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: _P.red,
            ),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: onRetry,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              decoration: BoxDecoration(
                color: _P.black,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                'Try Again',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
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
// PLAY BUTTON  (big, black, green-bordered when playing)
// ─────────────────────────────────────────────────────────────────────────────
class _PlayButton extends StatelessWidget {
  const _PlayButton({
    required this.isPlaying,
    required this.hasBgMusic,
    required this.onPressed,
  });
  final bool isPlaying, hasBgMusic;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.mediumImpact();
        onPressed();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 62,
        decoration: BoxDecoration(
          color: isPlaying ? _P.blackSoft : _P.black,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: isPlaying ? _P.green : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: 26,
              color: isPlaying ? _P.green : Colors.white,
            ),
            const SizedBox(width: 9),
            Text(
              isPlaying
                  ? 'Pause'
                  : hasBgMusic
                  ? 'Play with Music'
                  : 'Play My Song',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 15,
                fontWeight: FontWeight.w900,
                color: isPlaying ? _P.green : Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MUSIC BADGE
// ─────────────────────────────────────────────────────────────────────────────
class _MusicBadge extends StatelessWidget {
  const _MusicBadge({required this.label, required this.hasMusic});
  final String? label;
  final bool hasMusic;

  @override
  Widget build(BuildContext context) {
    final bg = hasMusic ? _P.greenSoft : _P.redSoft;
    final border = hasMusic ? _P.greenBorder : _P.redBorder;
    final color = hasMusic ? const Color(0xFF0A9B5A) : _P.red;
    final icon = hasMusic ? Icons.music_note_rounded : Icons.music_off_rounded;
    final text =
        hasMusic
            ? (label ?? 'Background music included')
            : 'Background music unavailable — vocals only';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MIX CARD
// ─────────────────────────────────────────────────────────────────────────────
class _MixCard extends StatelessWidget {
  const _MixCard({
    required this.voiceSpeed,
    required this.voiceVolume,
    required this.musicVolume,
    required this.maxVoiceCap,
    required this.onSpeedChanged,
    required this.onVoiceVolumeChanged,
    required this.onMusicVolumeChanged,
  });
  final double voiceSpeed, voiceVolume, musicVolume, maxVoiceCap;
  final ValueChanged<double> onSpeedChanged,
      onVoiceVolumeChanged,
      onMusicVolumeChanged;

  @override
  Widget build(BuildContext context) {
    final voiceSliderMax = math.max(0.401, math.min(1.0, maxVoiceCap));
    final voiceSliderVal = voiceVolume.clamp(0.4, voiceSliderMax);
    final voiceRange = voiceSliderMax - 0.4;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _P.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _P.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.tune_rounded, size: 14, color: _P.grey3),
              SizedBox(width: 6),
              Text(
                'Mix & Speed',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: _P.grey2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _SliderRow(
            label: 'Speed',
            valueLabel: '${voiceSpeed.toStringAsFixed(2)}x',
            value: voiceSpeed,
            min: 1.0,
            max: 1.5,
            divisions: 10,
            activeColor: _P.black,
            onChanged: onSpeedChanged,
          ),
          const SizedBox(height: 4),
          _SliderRow(
            label: 'Vocals',
            valueLabel: '${(100 * voiceVolume).round()}%',
            value: voiceSliderVal,
            min: 0.4,
            max: voiceSliderMax,
            divisions:
                voiceRange < 0.02
                    ? null
                    : math.max(1, (voiceRange / 0.1).round()),
            activeColor: _P.black,
            onChanged: onVoiceVolumeChanged,
          ),
          const SizedBox(height: 4),
          _SliderRow(
            label: 'Music',
            valueLabel: '${(100 * musicVolume).round()}%',
            value: musicVolume,
            min: 0.4,
            max: 2.0,
            divisions: 16,
            activeColor: _P.black,
            onChanged: onMusicVolumeChanged,
          ),
        ],
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.activeColor,
    required this.onChanged,
  });
  final String label, valueLabel;
  final double value, min, max;
  final int? divisions;
  final Color activeColor;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 52,
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: _P.grey2,
            ),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2.5,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: activeColor,
              inactiveTrackColor: _P.chipDark,
              thumbColor: activeColor,
              overlayColor: activeColor.withValues(alpha: 0.12),
            ),
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 42,
          child: Text(
            valueLabel,
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: _P.grey3,
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// OUTLINE BUTTON (matches VoiceSampleScreen)
// ─────────────────────────────────────────────────────────────────────────────
class _OutlineButton extends StatelessWidget {
  const _OutlineButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onPressed();
      },
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: _P.chip,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _P.border),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 17, color: _P.black),
            const SizedBox(width: 7),
            Text(
              label,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: _P.black,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// LYRICS CARD (collapsible — identical pattern to VoiceSampleScreen)
// ─────────────────────────────────────────────────────────────────────────────
class _LyricsCard extends StatelessWidget {
  const _LyricsCard({
    required this.lyrics,
    required this.language,
    required this.showFull,
    required this.onToggle,
    required this.scrollController,
  });
  final String lyrics, language;
  final bool showFull;
  final VoidCallback onToggle;
  final ScrollController scrollController;

  List<String> _lines() => lyrics.split('\n');

  @override
  Widget build(BuildContext context) {
    final lines = _lines();
    return Container(
      decoration: BoxDecoration(
        color: _P.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _P.border),
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
                      color: _P.chip,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _P.border),
                    ),
                    child: const Icon(
                      Icons.lyrics_outlined,
                      size: 16,
                      color: _P.black,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Lyrics',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: _P.black,
                          ),
                        ),
                        Text(
                          language,
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: _P.grey3,
                          ),
                        ),
                      ],
                    ),
                  ),
                  AnimatedRotation(
                    turns: showFull ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: _P.grey2,
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
            constraints: BoxConstraints(maxHeight: showFull ? 340 : 0),
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(18),
              ),
              child: Container(
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: _P.border)),
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
                          lines.map((line) {
                            if (line.trim().isEmpty)
                              return const SizedBox(height: 4);
                            final isHeader = RegExp(
                              r'^\[',
                              caseSensitive: false,
                            ).hasMatch(line.trim());
                            return Padding(
                              padding: EdgeInsets.only(
                                bottom: isHeader ? 2 : 5,
                                top: isHeader ? 10 : 0,
                              ),
                              child: Text(
                                line,
                                style: TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 13,
                                  fontWeight:
                                      isHeader
                                          ? FontWeight.w800
                                          : FontWeight.w500,
                                  color: isHeader ? _P.grey3 : _P.grey1,
                                  height: 1.65,
                                ),
                              ),
                            );
                          }).toList(),
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
