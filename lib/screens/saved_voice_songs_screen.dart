import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../models/saved_voice_song.dart';
import '../services/audio_session_service.dart';
import '../services/saved_voice_song_service.dart';

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
      final playing = state.playing &&
          state.processingState != ProcessingState.completed;
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
      builder: (context) => AlertDialog(
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
    final month = [
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
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Saved Songs'),
        backgroundColor: cs.inverseSurface,
        foregroundColor: cs.onInverseSurface,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _songs.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.library_music_outlined,
                            size: 60, color: cs.outline),
                        const SizedBox(height: 16),
                        Text(
                          'No saved cloned songs yet',
                          style: tt.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Save a cloned song after generation and it will appear here for replay anytime.',
                          textAlign: TextAlign.center,
                          style: tt.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _songs.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final song = _songs[index];
                    final isActive = _activeSongId == song.id;
                    final exists = File(song.filePath).existsSync();
                    return Container(
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: isActive
                              ? cs.primary.withValues(alpha: 0.4)
                              : cs.outline.withValues(alpha: 0.15),
                        ),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 10,
                        ),
                        leading: CircleAvatar(
                          backgroundColor: isActive
                              ? cs.primary
                              : cs.primaryContainer,
                          foregroundColor:
                              isActive ? cs.onPrimary : cs.onPrimaryContainer,
                          child: Icon(
                            isActive && _isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                          ),
                        ),
                        title: Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${song.language} • ${song.hasBackgroundMusic ? 'with music' : 'vocals only'}\n${_formatDate(song.createdAtIso)}',
                        ),
                        isThreeLine: true,
                        onTap: exists ? () => _togglePlay(song) : null,
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline_rounded),
                          tooltip: 'Delete',
                          onPressed: () => _deleteSong(song),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
