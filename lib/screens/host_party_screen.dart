// lib/screens/host_party_screen.dart
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import 'dart:async';
import '../services/shared_queue_service.dart';
import '../theme/lyric_screen_theme.dart';
import '../services/youtube_mobile_service.dart';
import '../widgets/lyric_page_scaffold.dart';

const String _appLink =
    'https://mongobox-79a1f.firebaseapp.com/join-queue.html';

class HostPartyScreen extends StatefulWidget {
  const HostPartyScreen({super.key});

  @override
  State<HostPartyScreen> createState() => _HostPartyScreenState();
}

class _HostPartyScreenState extends State<HostPartyScreen> {
  late SharedQueueService _queueService;
  late String _partyId;
  List<Song> queue = [];
  YoutubePlayerController? _playerController;
  final YoutubeMobileService _youtube = YoutubeMobileService();
  final _searchController = TextEditingController();
  List<Map<String, dynamic>> _searchResults = [];
  bool _searching = false;
  StreamSubscription<List<Song>>? _queueSubscription;

  @override
  void initState() {
    super.initState();

    // Generate unique party ID - SIMPLIFIED for easier debugging
    _partyId = 'party_${DateTime.now().millisecondsSinceEpoch}';
    print('🎪 ========================================');
    print('🎪 HOST STARTING PARTY');
    print('🎪 Party ID: $_partyId');
    print('🎪 Firebase Path: parties/$_partyId/queue');
    print('🎪 ========================================');

    // Create queue service with party ID
    _queueService = SharedQueueService(partyId: _partyId);

    // Listen to queue stream and properly store subscription
    _queueSubscription = _queueService.streamQueue().listen(
      (newQueue) {
        print('🎵 HOST: Queue updated - ${newQueue.length} songs');
        if (newQueue.isNotEmpty) {
          print('🎵 HOST: First song: ${newQueue.first.title}');
        }
        if (mounted) {
          setState(() => queue = newQueue);
          _playFirstIfNeeded();
        }
      },
      onError: (error) {
        print('❌ HOST: Queue stream error: $error');
      },
    );
  }

  void _playFirstIfNeeded() {
    if (queue.isEmpty) {
      _playerController?.dispose();
      _playerController = null;
      return;
    }
    final first = queue.first;
    if (_playerController?.metadata.videoId == first.id) return;
    _playerController?.dispose();
    _playerController = YoutubePlayerController(
      initialVideoId: first.id,
      flags: const YoutubePlayerFlags(autoPlay: true, mute: false),
    );
  }

  Future<void> _searchSongs() async {
    final q = _searchController.text.trim();
    if (q.isEmpty) return;
    setState(() => _searching = true);

    try {
      final results = await _youtube.searchSongs(q);
      if (mounted) {
        setState(() {
          _searchResults = results;
          _searching = false;
        });
      }
    } catch (e) {
      // Check if it's a quota exceeded error
      if (e.toString().contains('quota exceeded') ||
          e.toString().contains('403') ||
          e.toString().contains('quotaExceeded')) {
        if (mounted) {
          setState(() => _searching = false);
          _showQuotaExceededDialog();
        }
      } else {
        if (mounted) {
          setState(() => _searching = false);
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Error: ${e.toString()}')));
        }
      }
    }
  }

  DateTime _getNextQuotaResetTime() {
    // YouTube quota resets at midnight Pacific Time (PT)
    final now = DateTime.now();
    final pacificOffset = Duration(hours: -8); // UTC-8 (Standard Time)

    final pacificNow = now.add(pacificOffset);
    var resetTime = DateTime(
      pacificNow.year,
      pacificNow.month,
      pacificNow.day,
      0,
      0,
      0,
    );

    // If already past midnight PT today, next reset is tomorrow
    if (pacificNow.isAfter(resetTime)) {
      resetTime = resetTime.add(Duration(days: 1));
    }

    return resetTime.subtract(pacificOffset);
  }

  void _showQuotaExceededDialog() {
    final resetTime = _getNextQuotaResetTime();
    final now = DateTime.now();
    final duration = resetTime.difference(now);

    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;
    final seconds = duration.inSeconds % 60;

    showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            icon: const Icon(
              Icons.schedule_rounded,
              color: LyricScreenPalette.error,
            ),
            title: const Text('YouTube API Quota Exceeded'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'You\'ve used up today\'s YouTube API quota. The search feature is temporarily unavailable.',
                  style: TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: LyricScreenPalette.errorSoft,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: LyricScreenPalette.error.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Time Until Reset',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '$hours hour${hours != 1 ? 's' : ''} ${minutes.toString().padLeft(2, '0')} min ${seconds.toString().padLeft(2, '0')} sec',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: LyricScreenPalette.error,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Reset: ${resetTime.toString().split('.')[0]} (PT)',
                        style: const TextStyle(
                          fontSize: 11,
                          color: LyricScreenPalette.mutedText,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Try again after the quota resets at midnight Pacific Time.',
                  style: TextStyle(
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                    color: LyricScreenPalette.mutedText,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
    );
  }

  Future<void> _addToQueue(Map<String, dynamic> song) async {
    if (queue.any((s) => s.id == song['id'])) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Already in queue')));
      return;
    }
    print('➕ HOST: Adding song: ${song['title']} to party: $_partyId');
    await _queueService.addSong(
      Song(
        key: '',
        id: song['id'],
        title: song['title'],
        artist: song['artist'],
        thumbnail: song['thumbnail'],
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Added "${song['title']}"')));
    }
  }

  Future<void> _playNext() async {
    if (queue.isNotEmpty) {
      await _queueService.remove(queue.first.key);
    }
  }

  Future<void> _clearQueue() async {
    await _queueService.clear();
    _playerController?.dispose();
    if (mounted) {
      setState(() => _playerController = null);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Queue cleared')));
    }
  }

  void _showHostPartySheet() {
    // Create shareable link with party ID
    final partyLink = '$_appLink?partyId=$_partyId';

    print('🔗 ========================================');
    print('🔗 SHARING PARTY LINK');
    print('🔗 Link: $partyLink');
    print('🔗 Party ID: $_partyId');
    print('🔗 ========================================');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: LyricScreenPalette.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder:
          (ctx) => Theme(
            data: lyricScreenTheme(ctx),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Share your party',
                      style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Guests can scan the QR code or open the link to start suggesting songs instantly.',
                      textAlign: TextAlign.center,
                      style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 18),
                    LyricSectionCard(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          Text(
                            'Party ID',
                            style: Theme.of(
                              ctx,
                            ).textTheme.labelMedium?.copyWith(
                              color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 6),
                          SelectableText(
                            _partyId,
                            style: Theme.of(
                              ctx,
                            ).textTheme.titleMedium?.copyWith(
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    Container(
                      width: 220,
                      height: 220,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Theme.of(ctx).colorScheme.surface,
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(
                          color: Theme.of(
                            ctx,
                          ).colorScheme.outline.withValues(alpha: 0.45),
                        ),
                      ),
                      child: Center(
                        child: QrImageView(
                          data: partyLink,
                          version: QrVersions.auto,
                          size: 170,
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    SelectableText(
                      partyLink,
                      style: Theme.of(
                        ctx,
                      ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Scan to suggest songs. No sign-in needed.',
                      textAlign: TextAlign.center,
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        FilledButton.icon(
                          onPressed: () {
                            Share.share(
                              'Join my MongoBox party\n\n$partyLink',
                              subject: 'MongoBox Party',
                            );
                            Navigator.of(ctx).pop();
                          },
                          icon: const Icon(Icons.share_rounded),
                          label: const Text('Share link'),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          child: const Text('Close'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
    );
  }

  @override
  void dispose() {
    print('🎪 HOST: Disposing party $_partyId');
    _queueSubscription?.cancel();
    _searchController.dispose();
    _playerController?.dispose();
    super.dispose();
  }

  Future<void> _manualRefresh() async {
    print('🔄 Manual refresh triggered');
    await _queueService.diagnosticCheck();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Diagnostic check complete - see console'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LyricPageScaffold(
      title: 'Host a party',
      subtitle:
          'Share the room code, manage the live queue, and keep playback moving with the same clean Lyric look.',
      badge: 'Live host',
      actions: [
        OutlinedButton.icon(
          onPressed: _manualRefresh,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('Check live'),
        ),
        FilledButton.icon(
          onPressed: _showHostPartySheet,
          icon: const Icon(Icons.qr_code_2_rounded, size: 18),
          label: const Text('Share'),
        ),
      ],
      bodyBottomPadding: 20,
      child: Builder(
        builder:
            (context) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LyricSectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Party ready',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Use the QR share sheet to invite guests. Suggestions land here instantly and the first track in line becomes the active deck.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          LyricStatChip(
                            label: 'Party ID',
                            value: _partyId,
                            icon: Icons.tag_rounded,
                          ),
                          LyricStatChip(
                            label: 'Queue',
                            value:
                                '${queue.length} song${queue.length == 1 ? '' : 's'}',
                            icon: Icons.queue_music_rounded,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                LyricSectionCard(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Now playing',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(22),
                        child:
                            _playerController != null
                                ? AspectRatio(
                                  aspectRatio: 16 / 9,
                                  child: YoutubePlayer(
                                    controller: _playerController!,
                                    showVideoProgressIndicator: true,
                                    progressColors: const ProgressBarColors(
                                      playedColor: LyricScreenPalette.accent,
                                      handleColor: LyricScreenPalette.ink,
                                    ),
                                  ),
                                )
                                : Container(
                                  height: 220,
                                  color:
                                      Theme.of(
                                        context,
                                      ).colorScheme.surfaceContainerHighest,
                                  alignment: Alignment.center,
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.music_video_rounded,
                                        size: 48,
                                        color:
                                            Theme.of(
                                              context,
                                            ).colorScheme.outline,
                                      ),
                                      const SizedBox(height: 10),
                                      Text(
                                        'Queue is empty',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleSmall?.copyWith(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'Search below to seed the first song.',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall?.copyWith(
                                          color:
                                              Theme.of(
                                                context,
                                              ).colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: queue.isEmpty ? null : _playNext,
                              icon: const Icon(Icons.skip_next_rounded),
                              label: const Text('Next up'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: queue.isEmpty ? null : _clearQueue,
                              icon: const Icon(Icons.clear_all_rounded),
                              label: const Text('Clear queue'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                LyricSectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Queue',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        queue.isEmpty
                            ? 'New suggestions will appear here.'
                            : 'The first song is the active track. Everything below it stays lined up in order.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 14),
                      if (queue.isEmpty)
                        const _HostEmptyState(
                          icon: Icons.queue_music_rounded,
                          title: 'No songs in the queue yet',
                          message:
                              'Share the party and add a track to get the room started.',
                        )
                      else
                        ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: queue.length,
                          separatorBuilder:
                              (_, __) => const SizedBox(height: 10),
                          itemBuilder: (ctx, i) {
                            final song = queue[i];
                            return _QueueSongTile(song: song, isActive: i == 0);
                          },
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                LyricSectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Add songs',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Search YouTube and drop a track straight into the shared queue.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Container(
                        decoration: BoxDecoration(
                          color:
                              Theme.of(context).colorScheme.tertiaryContainer,
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: Row(
                          children: [
                            const SizedBox(width: 14),
                            Icon(
                              Icons.search_rounded,
                              color:
                                  Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                            ),
                            Expanded(
                              child: TextField(
                                controller: _searchController,
                                decoration: const InputDecoration(
                                  hintText: 'Search songs to add...',
                                  border: InputBorder.none,
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 16,
                                  ),
                                ),
                                onSubmitted: (_) => _searchSongs(),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: FilledButton(
                                onPressed: _searching ? null : _searchSongs,
                                child:
                                    _searching
                                        ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                        : const Text('Search'),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_searchResults.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _searchResults.length,
                          separatorBuilder:
                              (_, __) => const SizedBox(height: 10),
                          itemBuilder: (ctx, i) {
                            final song = _searchResults[i];
                            return _SearchResultTile(
                              title: song['title'] as String? ?? 'Untitled',
                              artist:
                                  song['artist'] as String? ?? 'Unknown artist',
                              thumbnail: song['thumbnail'] as String? ?? '',
                              buttonLabel: 'Add',
                              onPressed: () => _addToQueue(song),
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
      ),
    );
  }
}

class _HostEmptyState extends StatelessWidget {
  const _HostEmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: cs.tertiaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Icon(icon, size: 42, color: cs.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueSongTile extends StatelessWidget {
  const _QueueSongTile({required this.song, required this.isActive});

  final Song song;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color:
            isActive
                ? cs.secondaryContainer.withValues(alpha: 0.7)
                : cs.tertiaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        leading: LyricThumbnailAvatar(imageUrl: song.thumbnail, size: 56),
        title: Text(
          song.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            song.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
        trailing:
            isActive
                ? const LyricTag(
                  label: 'Now playing',
                  icon: Icons.graphic_eq_rounded,
                  highlighted: true,
                )
                : const LyricTag(label: 'Queued', icon: Icons.schedule_rounded),
      ),
    );
  }
}

class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({
    required this.title,
    required this.artist,
    required this.thumbnail,
    required this.buttonLabel,
    required this.onPressed,
  });

  final String title;
  final String artist;
  final String thumbnail;
  final String buttonLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: cs.tertiaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        leading: LyricThumbnailAvatar(imageUrl: thumbnail, size: 56),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
        trailing: FilledButton(onPressed: onPressed, child: Text(buttonLabel)),
      ),
    );
  }
}
