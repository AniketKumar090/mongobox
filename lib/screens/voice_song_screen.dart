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
// VoiceSongScreen
//
// Clones the user's voice in BOTH Hindi and English in parallel.
// Once both are ready, shows a language preference picker so the user
// chooses which version to play. The dominant language (higher wordplay score)
// is pre-selected as the default.
// ─────────────────────────────────────────────────────────────────────────────

enum _CloneStep { cloning, pickLanguage, ready, error }
enum _LyricsTab { hindi, english }
enum _HindiView { devanagari, hinglish, both }

class VoiceSongScreen extends StatefulWidget {
  const VoiceSongScreen({
    super.key,
    required this.songTitle,
    required this.hindiLyrics,
    required this.englishLyrics,
    required this.dominantLanguage,   // 'Hindi' or 'English'
    required this.mood,
    required this.genre,
    this.referenceSong,
    required this.voiceSamplePath,
  });

  final String songTitle;
  final String hindiLyrics;
  final String englishLyrics;
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
  final _transliterationService = TransliterationService();

  // ── Clone results ──────────────────────────────────────────────────────────
  String? _hindiClonePath;
  String? _englishClonePath;
  String? _hindiCloneError;
  String? _englishCloneError;
  bool _hindiDone = false;
  bool _englishDone = false;

  // ── User's chosen language for playback ───────────────────────────────────
  String? _chosenLanguage;   // 'Hindi' or 'English', set after picker
  String? _activeClonePath;  // path of the chosen clone

  // ── Background music ───────────────────────────────────────────────────────
  String? _musicSourceUrl;
  String? _musicSourceLabel;

  // ── UI state ───────────────────────────────────────────────────────────────
  _CloneStep _step = _CloneStep.cloning;
  bool _isPlaying = false;
  String? _errorMessage;
  StreamSubscription<PlayerState>? _voiceStateSub;

  // ── Hinglish transliteration ───────────────────────────────────────────────
  String? _hinglishLyrics;
  bool _isTransliterating = false;
  _HindiView _hindiView = _HindiView.both;

  // ── Lyrics tab (for display only) ─────────────────────────────────────────
  late _LyricsTab _lyricsTab;

  @override
  void initState() {
    super.initState();
    _lyricsTab = widget.dominantLanguage == 'Hindi'
        ? _LyricsTab.hindi
        : _LyricsTab.english;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startParallelCloning();
      _transliterateInBackground();
    });
  }

  @override
  void dispose() {
    _voiceStateSub?.cancel();
    _musicPlayer.dispose();
    _voicePlayer.dispose();
    _cloneService.dispose();
    super.dispose();
  }

  // ── PARALLEL CLONING ──────────────────────────────────────────────────────
  Future<void> _startParallelCloning() async {
    setState(() {
      _step = _CloneStep.cloning;
      _hindiDone = false;
      _englishDone = false;
      _hindiClonePath = null;
      _englishClonePath = null;
      _hindiCloneError = null;
      _englishCloneError = null;
      _chosenLanguage = null;
      _activeClonePath = null;
      _musicSourceUrl = null;
      _errorMessage = null;
      _isPlaying = false;
    });

    final dominant = widget.dominantLanguage;
    final cloneHindiFirst = dominant == 'Hindi';

    if (cloneHindiFirst) {
      // Only clone Hindi; mark English as "skipped" so the backend isn't hit twice.
      _englishDone = true;
      _englishCloneError = 'Skipped (dominant language is Hindi)';
      await _cloneLanguage(
        lyrics: widget.hindiLyrics,
        language: 'Hindi',
        onDone: (path) => setState(() {
          _hindiClonePath = path;
          _hindiDone = true;
          _checkIfBothDone();
        }),
        onError: (e) => setState(() {
          _hindiCloneError = e;
          _hindiDone = true;
          _checkIfBothDone();
        }),
      );
    } else {
      // Default: clone English only; skip Hindi clone.
      _hindiDone = true;
      _hindiCloneError = 'Skipped (dominant language is not Hindi)';
      await _cloneLanguage(
        lyrics: widget.englishLyrics,
        language: 'English',
        onDone: (path) => setState(() {
          _englishClonePath = path;
          _englishDone = true;
          _checkIfBothDone();
        }),
        onError: (e) => setState(() {
          _englishCloneError = e;
          _englishDone = true;
          _checkIfBothDone();
        }),
      );
    }
  }

  Future<void> _cloneLanguage({
    required String lyrics,
    required String language,
    required void Function(String path) onDone,
    required void Function(String error) onError,
  }) async {
    try {
      final file = await _cloneService.cloneVoice(
        voiceSamplePath: widget.voiceSamplePath,
        lyrics: lyrics,
        mood: widget.mood,
        genre: widget.genre,
        language: language,
        referenceSong: widget.referenceSong,
      );
      if (mounted) onDone(file.path);
    } catch (e) {
      if (mounted) onError(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _checkIfBothDone() {
    if (!_hindiDone || !_englishDone) return;

    // If BOTH failed → error state
    if (_hindiClonePath == null && _englishClonePath == null) {
      setState(() {
        _step = _CloneStep.error;
        _errorMessage =
            'Both voice clones failed.\n'
            'Hindi: ${_hindiCloneError ?? 'unknown'}\n'
            'English: ${_englishCloneError ?? 'unknown'}';
      });
      return;
    }

    // If only one succeeded, skip the picker and use it directly
    if (_hindiClonePath != null && _englishClonePath == null) {
      _finaliseChoice('Hindi');
      return;
    }
    if (_englishClonePath != null && _hindiClonePath == null) {
      _finaliseChoice('English');
      return;
    }

    // Both succeeded → show language picker
    setState(() => _step = _CloneStep.pickLanguage);
    _showLanguagePicker();
  }

  /// Show a bottom sheet asking which language the user wants to hear.
  Future<void> _showLanguagePicker() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => _LanguagePickerSheet(
        dominantLanguage: widget.dominantLanguage,
        songTitle: widget.songTitle,
      ),
    );

    if (!mounted) return;
    // If user dismissed without choosing, default to dominant
    _finaliseChoice(choice ?? widget.dominantLanguage);
  }

  Future<void> _finaliseChoice(String language) async {
    final path =
        language == 'Hindi' ? _hindiClonePath : _englishClonePath;

    // Fetch background music
    final bgTrack = await _bgMusicService.findTrack(
      mood: widget.mood,
      genre: widget.genre,
      language: language,
      referenceTrackTitle: widget.referenceSong?.trackName ?? '',
      referenceArtistName: widget.referenceSong?.artistName ?? '',
    );

    if (!mounted) return;
    setState(() {
      _chosenLanguage = language;
      _activeClonePath = path;
      _musicSourceUrl = bgTrack?.sourceUrl;
      _musicSourceLabel = bgTrack?.label;
      _step = _CloneStep.ready;
      _lyricsTab =
          language == 'Hindi' ? _LyricsTab.hindi : _LyricsTab.english;
    });
  }

  // ── Transliterate Hindi → Hinglish in background ──────────────────────────
  Future<void> _transliterateInBackground() async {
    setState(() => _isTransliterating = true);
    try {
      final roman = await _transliterationService.transliterateLyrics(
        widget.hindiLyrics,
        'Hindi',
      );
      if (!mounted) return;
      setState(() {
        _hinglishLyrics = roman;
        _hindiView = _HindiView.both;
        _isTransliterating = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isTransliterating = false);
    }
  }

  // ── PLAYBACK ──────────────────────────────────────────────────────────────
  Future<void> _play() async {
    final path = _activeClonePath;
    if (path == null) return;

    if (_isPlaying) {
      await _voicePlayer.pause();
      await _musicPlayer.pause();
      setState(() => _isPlaying = false);
      return;
    }

    await _voicePlayer.setFilePath(path);
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
  }

  /// Let the user switch to the other language without re-cloning.
  void _switchLanguage() {
    final other =
        _chosenLanguage == 'Hindi' ? 'English' : 'Hindi';
    final path =
        other == 'Hindi' ? _hindiClonePath : _englishClonePath;
    if (path == null) return; // that clone failed — nothing to switch to

    _voicePlayer.stop();
    _musicPlayer.stop();
    setState(() {
      _isPlaying = false;
      _chosenLanguage = other;
      _activeClonePath = path;
      _lyricsTab =
          other == 'Hindi' ? _LyricsTab.hindi : _LyricsTab.english;
    });
  }

  // ── SHARE / DOWNLOAD ──────────────────────────────────────────────────────
  Future<void> _share() async {
    final path = _activeClonePath;
    if (path == null) return;
    await Share.shareXFiles(
      [XFile(path)],
      subject: '"${widget.songTitle}" — AI voice cover ($_chosenLanguage)',
      text:
          'My AI song "${widget.songTitle}" ($_chosenLanguage version) in my cloned voice 🎤',
    );
  }

  Future<void> _download() async {
    final path = _activeClonePath;
    if (path == null) return;
    final docsDir = await getApplicationDocumentsDirectory();
    final safeName = widget.songTitle
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .replaceAll(' ', '_');
    final lang = _chosenLanguage?.toLowerCase() ?? 'voice';
    final dest = File('${docsDir.path}/${safeName}_${lang}.wav');
    await File(path).copy(dest.path);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Saved to Documents/${safeName}_${lang}.wav'),
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  // ── BUILD ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: Text('"${widget.songTitle}"',
            style: const TextStyle(fontSize: 16)),
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
              // ── Song info card ─────────────────────────────────────────
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

              // ── Pipeline steps ─────────────────────────────────────────
              _PipelineSteps(
                hindiDone: _hindiDone,
                englishDone: _englishDone,
                hindiError: _hindiCloneError,
                englishError: _englishCloneError,
                step: _step,
                cs: cs,
                tt: tt,
              ),

              // ── Error ──────────────────────────────────────────────────
              if (_step == _CloneStep.error) ...[
                const SizedBox(height: 16),
                _ErrorCard(
                  message: _errorMessage ?? 'Unknown error',
                  onRetry: _startParallelCloning,
                  cs: cs,
                  tt: tt,
                ),
              ],

              // ── Picking language (intermediate) ────────────────────────
              if (_step == _CloneStep.pickLanguage) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: cs.primary),
                      ),
                      const SizedBox(width: 14),
                      Text('Waiting for your language preference…',
                          style: tt.bodyMedium),
                    ],
                  ),
                ),
              ],

              // ── Ready ──────────────────────────────────────────────────
              if (_step == _CloneStep.ready) ...[
                const SizedBox(height: 8),

                // Active language banner + switch button
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: cs.primary.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle_outline_rounded,
                          color: cs.primary, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Playing: $_chosenLanguage version'
                          '${_chosenLanguage == widget.dominantLanguage ? '  ★ dominant' : ''}',
                          style: tt.labelMedium?.copyWith(
                            color: cs.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      // Only show switch if the other clone succeeded
                      if ((_chosenLanguage == 'Hindi' &&
                              _englishClonePath != null) ||
                          (_chosenLanguage == 'English' &&
                              _hindiClonePath != null))
                        TextButton(
                          onPressed: _switchLanguage,
                          child: Text(
                            'Switch to '
                            '${_chosenLanguage == 'Hindi' ? 'English' : 'Hindi'}',
                          ),
                        ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // Play button
                SizedBox(
                  height: 72,
                  child: FilledButton.icon(
                    onPressed: _play,
                    style: FilledButton.styleFrom(
                      backgroundColor:
                          _isPlaying ? cs.error : cs.primary,
                      foregroundColor: cs.onPrimary,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20)),
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

                const SizedBox(height: 12),

                // Music status
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: _musicSourceUrl != null
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
                        color: _musicSourceUrl != null
                            ? cs.primary
                            : cs.error,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _musicSourceUrl != null
                              ? '${_musicSourceLabel ?? '${widget.mood} instrumental'} • 30% vol'
                              : 'Background music unavailable — vocals only',
                          style: tt.bodySmall?.copyWith(
                            color: _musicSourceUrl != null
                                ? cs.onSurfaceVariant
                                : cs.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // Share + Save
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _share,
                        icon: const Icon(Icons.share_rounded),
                        label: const Text('Share'),
                        style: OutlinedButton.styleFrom(
                          padding:
                              const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
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
                          padding:
                              const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 24),

                // ── Lyrics section ───────────────────────────────────────
                _LyricsSection(
                  hindiLyrics: widget.hindiLyrics,
                  englishLyrics: widget.englishLyrics,
                  hinglishLyrics: _hinglishLyrics,
                  isTransliterating: _isTransliterating,
                  activeTab: _lyricsTab,
                  hindiView: _hindiView,
                  onTabChanged: (t) => setState(() => _lyricsTab = t),
                  onHindiViewChanged: (v) =>
                      setState(() => _hindiView = v),
                  cs: cs,
                  tt: tt,
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

// ─── LANGUAGE PICKER BOTTOM SHEET ─────────────────────────────────────────────
class _LanguagePickerSheet extends StatelessWidget {
  const _LanguagePickerSheet({
    required this.dominantLanguage,
    required this.songTitle,
  });
  final String dominantLanguage;
  final String songTitle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final secondary = dominantLanguage == 'Hindi' ? 'English' : 'Hindi';

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Handle
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: cs.onSurfaceVariant.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          Text(
            'Which version do you want to hear?',
            style: tt.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            '"$songTitle" has been cloned in both languages.',
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),

          const SizedBox(height: 28),

          // Dominant language card
          _PickerCard(
            language: dominantLanguage,
            badge: '★ More wordplay',
            badgeColor: cs.primary,
            description: dominantLanguage == 'Hindi'
                ? 'Devanagari lyrics with higher rhyme density from the reference'
                : 'English lyrics with richer vocabulary from the reference',
            onTap: () => Navigator.of(context).pop(dominantLanguage),
            cs: cs,
            tt: tt,
            isPrimary: true,
          ),

          const SizedBox(height: 12),

          // Secondary language card
          _PickerCard(
            language: secondary,
            badge: null,
            badgeColor: cs.secondary,
            description: secondary == 'Hindi'
                ? 'Hindi Devanagari version of the song'
                : 'English version of the song',
            onTap: () => Navigator.of(context).pop(secondary),
            cs: cs,
            tt: tt,
            isPrimary: false,
          ),
        ],
      ),
    );
  }
}

class _PickerCard extends StatelessWidget {
  const _PickerCard({
    required this.language,
    required this.badge,
    required this.badgeColor,
    required this.description,
    required this.onTap,
    required this.cs,
    required this.tt,
    required this.isPrimary,
  });
  final String language;
  final String? badge;
  final Color badgeColor;
  final String description;
  final VoidCallback onTap;
  final ColorScheme cs;
  final TextTheme tt;
  final bool isPrimary;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: isPrimary
              ? cs.primaryContainer.withValues(alpha: 0.4)
              : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isPrimary
                ? cs.primary.withValues(alpha: 0.5)
                : cs.outline.withValues(alpha: 0.25),
            width: isPrimary ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isPrimary
                    ? cs.primary.withValues(alpha: 0.15)
                    : cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                language == 'Hindi'
                    ? Icons.translate_rounded
                    : Icons.language_rounded,
                color: isPrimary ? cs.primary : cs.onSurfaceVariant,
                size: 24,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        language == 'Hindi' ? 'हिंदी (Hindi)' : 'English',
                        style: tt.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: isPrimary ? cs.primary : cs.onSurface,
                        ),
                      ),
                      if (badge != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: badgeColor.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            badge!,
                            style: TextStyle(
                              fontSize: 10,
                              color: badgeColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: tt.bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.play_circle_rounded,
              color: isPrimary ? cs.primary : cs.onSurfaceVariant,
              size: 28,
            ),
          ],
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
            child: Icon(Icons.graphic_eq_rounded,
                color: cs.primary, size: 28),
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
                    _SmallChip(
                        label: '★ $dominantLanguage dominant', cs: cs),
                    if (referenceSong != null)
                      _SmallChip(
                          label: referenceSong!.artistName, cs: cs),
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

// ─── PIPELINE STEPS ───────────────────────────────────────────────────────────
class _PipelineSteps extends StatelessWidget {
  const _PipelineSteps({
    required this.hindiDone,
    required this.englishDone,
    required this.hindiError,
    required this.englishError,
    required this.step,
    required this.cs,
    required this.tt,
  });
  final bool hindiDone;
  final bool englishDone;
  final String? hindiError;
  final String? englishError;
  final _CloneStep step;
  final ColorScheme cs;
  final TextTheme tt;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _StepRow(
          icon: Icons.translate_rounded,
          title: 'Hindi voice clone',
          subtitle: hindiError != null
              ? 'Failed: $hindiError'
              : hindiDone
                  ? 'Cloned successfully'
                  : 'Cloning in Hindi (Devanagari)…',
          isDone: hindiDone && hindiError == null,
          isFailed: hindiError != null,
          isActive: !hindiDone,
          cs: cs,
          tt: tt,
        ),
        const SizedBox(height: 10),
        _StepRow(
          icon: Icons.language_rounded,
          title: 'English voice clone',
          subtitle: englishError != null
              ? 'Failed: $englishError'
              : englishDone
                  ? 'Cloned successfully'
                  : 'Cloning in English…',
          isDone: englishDone && englishError == null,
          isFailed: englishError != null,
          isActive: !englishDone,
          cs: cs,
          tt: tt,
        ),
        if (step == _CloneStep.ready) ...[
          const SizedBox(height: 10),
          _StepRow(
            icon: Icons.auto_awesome_rounded,
            title: 'Preview ready',
            subtitle: 'Your cloned vocal is ready to play',
            isDone: true,
            isFailed: false,
            isActive: false,
            cs: cs,
            tt: tt,
          ),
        ],
      ],
    );
  }
}

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
        color: isDone
            ? cs.primaryContainer.withValues(alpha: 0.4)
            : isFailed
                ? cs.errorContainer.withValues(alpha: 0.3)
                : cs.surfaceContainerHighest
                    .withValues(alpha: isActive ? 1 : 0.4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDone
              ? cs.primary.withValues(alpha: 0.3)
              : isFailed
                  ? cs.error.withValues(alpha: 0.3)
                  : cs.outline
                      .withValues(alpha: isActive ? 0.3 : 0.1),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            height: 40,
            child: isDone
                ? Container(
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.check_rounded,
                        color: cs.primary, size: 22),
                  )
                : isFailed
                    ? Container(
                        decoration: BoxDecoration(
                          color: cs.errorContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(Icons.close_rounded,
                            color: cs.error, size: 22),
                      )
                    : isActive
                        ? Padding(
                            padding: const EdgeInsets.all(8),
                            child: CircularProgressIndicator(
                                strokeWidth: 2.5, color: cs.primary),
                          )
                        : Container(
                            decoration: BoxDecoration(
                              color: cs.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(icon,
                                color: cs.onSurfaceVariant
                                    .withValues(alpha: 0.4),
                                size: 20),
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
                    color: isFailed
                        ? cs.error
                        : isDone || isActive
                            ? cs.onSurface
                            : cs.onSurface.withValues(alpha: 0.4),
                    fontWeight: isDone || isActive
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
                Text(
                  subtitle,
                  style: tt.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant
                        .withValues(alpha: isDone ? 0.8 : 0.5),
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
    required this.hindiLyrics,
    required this.englishLyrics,
    required this.hinglishLyrics,
    required this.isTransliterating,
    required this.activeTab,
    required this.hindiView,
    required this.onTabChanged,
    required this.onHindiViewChanged,
    required this.cs,
    required this.tt,
  });
  final String hindiLyrics;
  final String englishLyrics;
  final String? hinglishLyrics;
  final bool isTransliterating;
  final _LyricsTab activeTab;
  final _HindiView hindiView;
  final ValueChanged<_LyricsTab> onTabChanged;
  final ValueChanged<_HindiView> onHindiViewChanged;
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
          // ── Tab row ──────────────────────────────────────────────────
          Row(
            children: [
              Text('Lyrics',
                  style: tt.labelLarge?.copyWith(
                      fontWeight: FontWeight.bold, color: cs.primary)),
              const SizedBox(width: 12),
              _TabButton(
                label: 'हिंदी',
                isActive: activeTab == _LyricsTab.hindi,
                onTap: () => onTabChanged(_LyricsTab.hindi),
                cs: cs,
                tt: tt,
              ),
              const SizedBox(width: 6),
              _TabButton(
                label: 'English',
                isActive: activeTab == _LyricsTab.english,
                onTap: () => onTabChanged(_LyricsTab.english),
                cs: cs,
                tt: tt,
              ),
              if (isTransliterating && activeTab == _LyricsTab.hindi) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: cs.primary),
                ),
              ],
            ],
          ),

          // ── Hinglish toggle (Hindi tab only) ─────────────────────────
          if (activeTab == _LyricsTab.hindi &&
              hinglishLyrics != null) ...[
            const SizedBox(height: 10),
            SegmentedButton<_HindiView>(
              segments: const [
                ButtonSegment(
                    value: _HindiView.devanagari,
                    label: Text('देवनागरी')),
                ButtonSegment(
                    value: _HindiView.hinglish,
                    label: Text('Hinglish')),
                ButtonSegment(
                    value: _HindiView.both, label: Text('Both')),
              ],
              selected: {hindiView},
              onSelectionChanged: (s) => onHindiViewChanged(s.first),
            ),
          ],

          const SizedBox(height: 14),

          // ── Lyrics body ──────────────────────────────────────────────
          if (activeTab == _LyricsTab.english)
            _PlainLines(
                lines: englishLyrics.split('\n'), cs: cs, tt: tt)
          else
            _HindiLines(
              devanagari: hindiLyrics,
              hinglish: hinglishLyrics,
              view: hinglishLyrics != null
                  ? hindiView
                  : _HindiView.devanagari,
              cs: cs,
              tt: tt,
            ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.label,
    required this.isActive,
    required this.onTap,
    required this.cs,
    required this.tt,
  });
  final String label;
  final bool isActive;
  final VoidCallback onTap;
  final ColorScheme cs;
  final TextTheme tt;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isActive ? cs.primary : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: isActive
                  ? cs.primary
                  : cs.outline.withValues(alpha: 0.3)),
        ),
        child: Text(
          label,
          style: tt.labelMedium?.copyWith(
            color: isActive ? cs.onPrimary : cs.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _PlainLines extends StatelessWidget {
  const _PlainLines(
      {required this.lines, required this.cs, required this.tt});
  final List<String> lines;
  final ColorScheme cs;
  final TextTheme tt;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: lines.map((line) {
        if (line.trim().isEmpty) return const SizedBox(height: 4);
        final isHeader = RegExp(
          r'^\[(Verse|Chorus|Bridge|Outro|Pre-Chorus)',
          caseSensitive: false,
        ).hasMatch(line.trim());
        if (isHeader) {
          return Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 4),
            child: Text(line.trim(),
                style: tt.labelMedium?.copyWith(
                    color: cs.primary, fontWeight: FontWeight.bold)),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(line,
              style: tt.bodyMedium
                  ?.copyWith(color: cs.onSurface, height: 1.65)),
        );
      }).toList(),
    );
  }
}

class _HindiLines extends StatelessWidget {
  const _HindiLines({
    required this.devanagari,
    required this.hinglish,
    required this.view,
    required this.cs,
    required this.tt,
  });
  final String devanagari;
  final String? hinglish;
  final _HindiView view;
  final ColorScheme cs;
  final TextTheme tt;

  @override
  Widget build(BuildContext context) {
    final devLines = devanagari.split('\n');
    final hinLines = hinglish?.split('\n');
    final primary =
        (view == _HindiView.hinglish && hinLines != null)
            ? hinLines
            : devLines;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: List.generate(primary.length, (i) {
        final line = primary[i];
        final isHeader = RegExp(
          r'^\[(Verse|Chorus|Bridge|Outro|Pre-Chorus)',
          caseSensitive: false,
        ).hasMatch(line.trim());

        if (isHeader) {
          return Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 4),
            child: Text(line.trim(),
                style: tt.labelMedium?.copyWith(
                    color: cs.primary, fontWeight: FontWeight.bold)),
          );
        }
        if (line.trim().isEmpty) return const SizedBox(height: 4);

        if (view != _HindiView.both || hinLines == null) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(line,
                style: tt.bodyMedium
                    ?.copyWith(color: cs.onSurface, height: 1.65)),
          );
        }

        final hin = i < hinLines.length ? hinLines[i] : '';
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(devLines[i],
                  style: tt.bodyMedium
                      ?.copyWith(color: cs.onSurface, height: 1.6)),
              if (hin.trim().isNotEmpty &&
                  hin.trim() != devLines[i].trim())
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(hin,
                      style: tt.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant, height: 1.35)),
                ),
            ],
          ),
        );
      }),
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
          Text('Could not generate voice preview',
              style: tt.titleSmall?.copyWith(
                  color: cs.onErrorContainer, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(message,
              style: tt.bodyMedium?.copyWith(color: cs.onErrorContainer)),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: onRetry,
            style: FilledButton.styleFrom(
                backgroundColor: cs.error, foregroundColor: cs.onError),
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
            fontWeight: FontWeight.w500),
      ),
    );
  }
}