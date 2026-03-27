import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../models/saved_voice_song.dart';
import '../services/audio_session_service.dart';
import '../services/saved_voice_song_service.dart';
import '../widgets/lyric_page_scaffold.dart';

class SavedVoiceSongsScreen extends StatefulWidget {
  const SavedVoiceSongsScreen({super.key});

  @override
  State<SavedVoiceSongsScreen> createState() => _SavedVoiceSongsScreenState();
}

class _SavedVoiceSongsScreenState extends State<SavedVoiceSongsScreen> {
  final _service = SavedVoiceSongService();
  final _player = AudioPlayer();
  final _musicPlayer = AudioPlayer();

  List<SavedVoiceSong> _songs = const [];
  bool _loading = true;
  String? _activeSongId;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _player.playerStateStream.listen((state) {
      if (!mounted) return;
      final playing =
          state.playing && state.processingState != ProcessingState.completed;
      setState(() => _isPlaying = playing);
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
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Delete saved song?'),
            content: Text('Remove "${song.title}" from your saved songs?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Delete'),
              ),
            ],
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
      ),
    );
  }

  String _formatDate(String iso) {
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    final month =
        [
          'Jan',
          'Feb',
          'Mar',
          'Apr',
          'May',
          'Jun',
          'Jul',
          'Aug',
          'Sep',
          'Oct',
          'Nov',
          'Dec',
        ][dt.month - 1];
    final hour = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final minute = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '${dt.day} $month ${dt.year} • $hour:$minute $period';
  }

  @override
  Widget build(BuildContext context) {
    return LyricPageScaffold(
      title: 'Downloads',
      subtitle:
          'Replay the cloned songs you have saved, jump back into your favorites, and tidy up the library when you want.',
      badge: 'Saved audio',
      child: Builder(
        builder:
            (context) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LyricSectionCard(
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      LyricStatChip(
                        label: 'Saved tracks',
                        value: '${_songs.length}',
                        icon: Icons.library_music_rounded,
                      ),
                      LyricStatChip(
                        label: 'Now playing',
                        value: _activeSongId == null ? 'Idle' : 'Live preview',
                        icon: Icons.play_circle_rounded,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (_loading)
                  const LyricSectionCard(
                    child: Padding(
                      padding: EdgeInsets.all(28),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  )
                else if (_songs.isEmpty)
                  const LyricSectionCard(child: _DownloadsEmptyState())
                else
                  Column(
                    children: [
                      for (var index = 0; index < _songs.length; index++) ...[
                        _SavedSongCard(
                          song: _songs[index],
                          isActive: _activeSongId == _songs[index].id,
                          isPlaying: _isPlaying,
                          exists: File(_songs[index].filePath).existsSync(),
                          formattedDate: _formatDate(
                            _songs[index].createdAtIso,
                          ),
                          onPlay: () => _togglePlay(_songs[index]),
                          onDelete: () => _deleteSong(_songs[index]),
                        ),
                        if (index != _songs.length - 1)
                          const SizedBox(height: 12),
                      ],
                    ],
                  ),
              ],
            ),
      ),
    );
  }
}

class _DownloadsEmptyState extends StatelessWidget {
  const _DownloadsEmptyState();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: cs.tertiaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Icon(Icons.library_music_outlined, size: 56, color: cs.outline),
          const SizedBox(height: 14),
          Text(
            'No saved cloned songs yet',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            'Save a cloned song after generation and it will appear here for replay anytime.',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _SavedSongCard extends StatelessWidget {
  const _SavedSongCard({
    required this.song,
    required this.isActive,
    required this.isPlaying,
    required this.exists,
    required this.formattedDate,
    required this.onPlay,
    required this.onDelete,
  });

  final SavedVoiceSong song;
  final bool isActive;
  final bool isPlaying;
  final bool exists;
  final String formattedDate;
  final VoidCallback onPlay;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color:
            isActive
                ? cs.secondaryContainer.withValues(alpha: 0.7)
                : cs.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color:
              isActive
                  ? cs.secondary.withValues(alpha: 0.35)
                  : cs.outline.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: isActive ? cs.primary : cs.tertiaryContainer,
                foregroundColor: isActive ? cs.onPrimary : cs.onSurface,
                child: Icon(
                  isActive && isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      formattedDate,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded),
                tooltip: 'Delete',
                onPressed: onDelete,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (song.language.trim().isNotEmpty)
                LyricTag(label: song.language, icon: Icons.language_rounded),
              if (song.genre.trim().isNotEmpty)
                LyricTag(label: song.genre, icon: Icons.graphic_eq_rounded),
              if (song.mood.trim().isNotEmpty)
                LyricTag(label: song.mood, icon: Icons.auto_awesome_rounded),
              LyricTag(
                label: song.hasBackgroundMusic ? 'With music' : 'Vocals only',
                icon:
                    song.hasBackgroundMusic
                        ? Icons.album_rounded
                        : Icons.mic_rounded,
                highlighted: song.hasBackgroundMusic,
              ),
              if (!exists)
                const LyricTag(
                  label: 'File missing',
                  icon: Icons.warning_amber_rounded,
                ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: exists ? onPlay : null,
                  icon: Icon(
                    isActive && isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
                  label: Text(isActive && isPlaying ? 'Pause' : 'Play'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('Remove'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
