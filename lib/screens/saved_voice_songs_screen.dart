// lib/screens/saved_voice_songs_screen.dart
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import '../models/saved_voice_song.dart';
import '../services/audio_session_service.dart';
import '../services/saved_voice_song_service.dart';

class SavedVoiceSongsScreen extends StatefulWidget {
  const SavedVoiceSongsScreen({super.key});

  @override
  State<SavedVoiceSongsScreen> createState() => _SavedVoiceSongsScreenState();
}

class _SavedVoiceSongsScreenState extends State<SavedVoiceSongsScreen>
    with SingleTickerProviderStateMixin {
  final _service = SavedVoiceSongService();
  final _player = AudioPlayer();
  final _musicPlayer = AudioPlayer();

  List<SavedVoiceSong> _songs = const [];
  bool _loading = true;
  String? _activeSongId;
  bool _isPlaying = false;

  late AnimationController _waveController;

  @override
  void initState() {
    super.initState();
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _player.playerStateStream.listen((state) {
      if (!mounted) return;
      final playing =
          state.playing && state.processingState != ProcessingState.completed;
      setState(() => _isPlaying = playing);
      if (playing) {
        _waveController.repeat(reverse: true);
      } else {
        _waveController.stop();
        _waveController.reset();
      }
      if (state.processingState == ProcessingState.completed) {
        _musicPlayer.stop();
        setState(() {
          _activeSongId = null;
          _isPlaying = false;
        });
      }
    });
    _loadSongs();
  }

  @override
  void dispose() {
    _waveController.dispose();
    _musicPlayer.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _loadSongs() async {
    final songs = await _service.getSongs();
    if (!mounted) return;
    setState(() {
      _songs = songs;
      _loading = false;
    });
  }

  Future<void> _togglePlay(SavedVoiceSong song) async {
    HapticFeedback.lightImpact();
    final sameSong = _activeSongId == song.id;
    if (sameSong && _isPlaying) {
      await _player.pause();
      await _musicPlayer.pause();
      return;
    }
    await AppAudioSessionService.activatePlayback();
    await _player.stop();
    await _musicPlayer.stop();
    await _player.setFilePath(song.filePath);
    await _player.seek(Duration.zero);
    final bgUrl = song.backgroundMusicUrl.trim();
    if (bgUrl.isNotEmpty) {
      try {
        await _musicPlayer.setUrl(bgUrl);
        await _musicPlayer.setLoopMode(LoopMode.all);
        await _musicPlayer.seek(Duration.zero);
      } catch (_) {
        await _musicPlayer.stop();
      }
    }
    if (!mounted) return;
    setState(() => _activeSongId = song.id);
    await Future.wait([
      _player.play(),
      if (bgUrl.isNotEmpty) _musicPlayer.play(),
    ]);
  }

  Future<void> _deleteSong(SavedVoiceSong song) async {
    HapticFeedback.mediumImpact();
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: const Color(0xFFF5F3EF),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFE5E5),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.delete_outline_rounded,
                    color: Color(0xFFCC2222), size: 22),
              ),
              const SizedBox(height: 16),
              const Text(
                'Delete saved song?',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Remove "${song.title}" from your saved songs? This cannot be undone.',
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF666666),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.of(context).pop(false),
                      child: Container(
                        height: 46,
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8E3DC),
                          borderRadius: BorderRadius.circular(23),
                        ),
                        alignment: Alignment.center,
                        child: const Text(
                          'Cancel',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF333333),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.of(context).pop(true),
                      child: Container(
                        height: 46,
                        decoration: BoxDecoration(
                          color: const Color(0xFFCC2222),
                          borderRadius: BorderRadius.circular(23),
                        ),
                        alignment: Alignment.center,
                        child: const Text(
                          'Delete',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (shouldDelete != true) return;
    if (_activeSongId == song.id) {
      await _player.stop();
      await _musicPlayer.stop();
      if (mounted) {
        setState(() {
          _activeSongId = null;
          _isPlaying = false;
        });
      }
    }
    await _service.removeSong(song.id);
    await _loadSongs();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Saved song removed'),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Color(0xFF111111),
      ),
    );
  }

  String _formatDate(String iso) {
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final hour =
        dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final minute = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '${dt.day} ${months[dt.month - 1]} ${dt.year} · $hour:$minute $period';
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final screenWidth = mq.size.width;
    final isCompact = screenWidth < 600;
    final hPad = isCompact ? screenWidth * 0.05 : screenWidth * 0.08;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F3EF),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Top nav bar ────────────────────────────────────────────────
            Padding(
              padding: EdgeInsets.fromLTRB(hPad, 14, hPad, 0),
              child: Row(
                children: [
                  // Back button
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8F4EE),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                            color: const Color(0xFFD8D4CC), width: 1),
                      ),
                      child: const Icon(Icons.arrow_back_ios_new_rounded,
                          size: 16, color: Color(0xFF333333)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Title + subtitle
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Downloads',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                            color: Colors.black,
                            height: 1.1,
                          ),
                        ),
                        Text(
                          '${_songs.length} saved track${_songs.length == 1 ? '' : 's'}',
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF888888),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Now playing badge (shows when active)
                  if (_activeSongId != null)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 13,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _isPlaying ? 'Playing' : 'Paused',
                            style: const TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    // Saved audio badge
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEDE8E0),
                        borderRadius: BorderRadius.circular(99),
                        border: Border.all(color: const Color(0xFFD8D4CC)),
                      ),
                      child: const Text(
                        'Saved audio',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF444444),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // ── Content ────────────────────────────────────────────────────
            Expanded(
              child: _loading
                  ? _buildLoading()
                  : _songs.isEmpty
                      ? const _DownloadsEmptyState()
                      : _buildSongsList(hPad),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoading() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.black),
            ),
          ),
          SizedBox(height: 16),
          Text(
            'Loading your library…',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Color(0xFF555555),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSongsList(double hPad) {
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(hPad, 16, hPad, 32),
      physics: const BouncingScrollPhysics(),
      itemCount: _songs.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (ctx, i) {
        final song = _songs[i];
        return _SavedSongCard(
          song: song,
          isActive: _activeSongId == song.id,
          isPlaying: _isPlaying && _activeSongId == song.id,
          exists: File(song.filePath).existsSync(),
          formattedDate: _formatDate(song.createdAtIso),
          waveAnimation: _waveController,
          onPlay: () => _togglePlay(song),
          onDelete: () => _deleteSong(song),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _DownloadsEmptyState
// ─────────────────────────────────────────────────────────────────────────────

class _DownloadsEmptyState extends StatelessWidget {
  const _DownloadsEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: const Color(0xFFEDE8E0),
                borderRadius: BorderRadius.circular(22),
              ),
              child: const Icon(Icons.library_music_outlined,
                  size: 34, color: Color(0xFF888888)),
            ),
            const SizedBox(height: 18),
            const Text(
              'No saved songs yet',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 20,
                fontWeight: FontWeight.w900,
                color: Colors.black,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Generate a cloned song and save it —\nit will appear here for replay anytime.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Color(0xFF888888),
                height: 1.55,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _SavedSongCard
// ─────────────────────────────────────────────────────────────────────────────

class _SavedSongCard extends StatelessWidget {
  const _SavedSongCard({
    required this.song,
    required this.isActive,
    required this.isPlaying,
    required this.exists,
    required this.formattedDate,
    required this.waveAnimation,
    required this.onPlay,
    required this.onDelete,
  });

  final SavedVoiceSong song;
  final bool isActive;
  final bool isPlaying;
  final bool exists;
  final String formattedDate;
  final Animation<double> waveAnimation;
  final VoidCallback onPlay;
  final VoidCallback onDelete;

  static const List<double> _barBaseHeights = [
    10, 18, 14, 24, 16, 20, 12, 22, 18, 14, 26, 12, 20, 16, 22,
  ];

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isActive ? const Color(0xFFF0EDE7) : const Color(0xFFF8F4EE),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: isActive
              ? const Color(0xFFBBB8B2)
              : const Color(0xFFD8D4CC),
          width: isActive ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Top row: play circle + info + delete ───────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Play/pause circle
              GestureDetector(
                onTap: exists ? onPlay : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: isActive
                        ? Colors.black
                        : const Color(0xFFE4E0D9),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: isActive
                        ? Colors.white
                        : const Color(0xFF555555),
                    size: 26,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              // Title + date
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 2),
                    Text(
                      song.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Colors.black,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        const Icon(Icons.access_time_rounded,
                            size: 11, color: Color(0xFF999999)),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            formattedDate,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF999999),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Delete icon button
              GestureDetector(
                onTap: onDelete,
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: const Color(0xFFEDE8E0),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFD8D4CC)),
                  ),
                  child: const Icon(Icons.delete_outline_rounded,
                      size: 17, color: Color(0xFF888888)),
                ),
              ),
            ],
          ),

          // ── Animated waveform (when active) ────────────────────────────
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 300),
            crossFadeState: isActive
                ? CrossFadeState.showFirst
                : CrossFadeState.showSecond,
            firstChild: Padding(
              padding: const EdgeInsets.only(top: 14),
              child: AnimatedBuilder(
                animation: waveAnimation,
                builder: (context, _) {
                  return SizedBox(
                    height: 32,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: List.generate(_barBaseHeights.length, (i) {
                        final phase =
                            (i / _barBaseHeights.length) * math.pi;
                        final h = _barBaseHeights[i] *
                            (0.55 +
                                0.45 *
                                    math.sin(
                                        waveAnimation.value * math.pi +
                                            phase));
                        return Expanded(
                          child: Align(
                            alignment: Alignment.center,
                            child: Container(
                              width: 4,
                              height: h.clamp(6.0, 32.0),
                              decoration: BoxDecoration(
                                color: isPlaying
                                    ? const Color(0xFF111111)
                                    : const Color(0xFFBBBBBB),
                                borderRadius: BorderRadius.circular(99),
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                  );
                },
              ),
            ),
            secondChild: const SizedBox.shrink(),
          ),

          // ── Tag chips ──────────────────────────────────────────────────
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (song.language.trim().isNotEmpty)
                _TagChip(
                    icon: Icons.language_rounded, label: song.language),
              if (song.genre.trim().isNotEmpty)
                _TagChip(
                    icon: Icons.graphic_eq_rounded, label: song.genre),
              if (song.mood.trim().isNotEmpty)
                _TagChip(
                    icon: Icons.auto_awesome_rounded, label: song.mood),
              _TagChip(
                icon: song.hasBackgroundMusic
                    ? Icons.album_rounded
                    : Icons.mic_rounded,
                label: song.hasBackgroundMusic
                    ? 'With music'
                    : 'Vocals only',
                highlighted: song.hasBackgroundMusic,
              ),
              if (!exists)
                const _TagChip(
                  icon: Icons.warning_amber_rounded,
                  label: 'File missing',
                  isWarning: true,
                ),
            ],
          ),

          const SizedBox(height: 14),

          // ── Play button ────────────────────────────────────────────────
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton.icon(
              onPressed: exists ? onPlay : null,
              style: FilledButton.styleFrom(
                backgroundColor: isActive
                    ? Colors.black
                    : const Color(0xFFE4E0D9),
                foregroundColor: isActive
                    ? Colors.white
                    : const Color(0xFF333333),
                disabledBackgroundColor: const Color(0xFFD8D4CC),
                disabledForegroundColor: const Color(0xFF999999),
                elevation: 0,
                shadowColor: Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
              icon: Icon(
                isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                size: 20,
              ),
              label: Text(
                isPlaying
                    ? 'Pause'
                    : (exists ? 'Play' : 'File missing'),
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
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
// _TagChip
// ─────────────────────────────────────────────────────────────────────────────

class _TagChip extends StatelessWidget {
  const _TagChip({
    required this.icon,
    required this.label,
    this.highlighted = false,
    this.isWarning = false,
  });

  final IconData icon;
  final String label;
  final bool highlighted;
  final bool isWarning;

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;

    if (isWarning) {
      bg = const Color(0xFFFFE5E5);
      fg = const Color(0xFFCC2222);
    } else if (highlighted) {
      bg = const Color(0xFF111111);
      fg = Colors.white;
    } else {
      bg = const Color(0xFFE4E0D9);
      fg = const Color(0xFF555555);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: fg),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}