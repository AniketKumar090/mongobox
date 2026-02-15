// lib/screens/host_party_screen.dart
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import '../services/shared_queue_service.dart';
import '../services/youtube_mobile_service.dart';

const String _appLink = 'https://mongobox-79a1f.firebaseapp.com/join-queue.html';

class HostPartyScreen extends StatefulWidget {
  const HostPartyScreen({super.key});

  @override
  State<HostPartyScreen> createState() => _HostPartyScreenState();
}

class _HostPartyScreenState extends State<HostPartyScreen> {
  List<Song> queue = [];
  YoutubePlayerController? _playerController;
  final YoutubeMobileService _youtube = YoutubeMobileService();
  final _searchController = TextEditingController();
  List<Map<String, dynamic>> _searchResults = [];
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    SharedQueueService().streamQueue().listen((newQueue) {
      if (mounted) {
        setState(() {
          queue = newQueue;
          _playFirstIfNeeded();
        });
      }
    });
  }

  void _playFirstIfNeeded() {
    if (queue.isEmpty) {
      _playerController?.dispose();
      setState(() => _playerController = null);
      return;
    }
    final first = queue.first;
    if (_playerController?.metadata.videoId == first.id) return;
    _playerController?.dispose();
    _playerController = YoutubePlayerController(
      initialVideoId: first.id,
      flags: const YoutubePlayerFlags(autoPlay: true, mute: false),
    );
    setState(() {});
  }

  Future<void> _searchSongs() async {
    final q = _searchController.text.trim();
    if (q.isEmpty) return;
    setState(() => _searching = true);
    final results = await _youtube.searchSongs(q);
    if (mounted) setState(() {
      _searchResults = results;
      _searching = false;
    });
  }

  Future<void> _addToQueue(Map<String, dynamic> song) async {
    if (queue.any((s) => s.id == song['id'])) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Already in queue')));
      return;
    }
    await SharedQueueService().addSong(
      Song(key: '', id: song['id'], title: song['title'], artist: song['artist'], thumbnail: song['thumbnail']),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Added "${song['title']}"')));
    }
  }

  Future<void> _playNext() async {
    if (queue.isNotEmpty) {
      await SharedQueueService().remove(queue.first.key);
    }
  }

  Future<void> _clearQueue() async {
    await SharedQueueService().clear();
    _playerController?.dispose();
    if (mounted) {
      setState(() => _playerController = null);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Queue cleared')));
    }
  }

  void _showHostPartySheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Share MongoBox', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 16),
              QrImageView(data: _appLink, version: QrVersions.auto, size: 200),
              const SizedBox(height: 16),
              Text('Scan to suggest songs • No sign-in needed', style: Theme.of(ctx).textTheme.bodySmall, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: () {
                      Share.share('Try MongoBox: $_appLink', subject: 'MongoBox');
                      Navigator.of(ctx).pop();
                    },
                    icon: const Icon(Icons.share),
                    label: const Text('Share link'),
                  ),
                  const SizedBox(width: 12),
                  TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    _playerController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Host party'),
        actions: [IconButton(icon: const Icon(Icons.qr_code_2), onPressed: _showHostPartySheet, tooltip: 'Host a party')],
      ),
      body: Column(
        children: [
          if (_playerController != null)
            AspectRatio(
              aspectRatio: 16 / 9,
              child: YoutubePlayer(controller: _playerController!, showVideoProgressIndicator: true),
            )
          else
            Container(
              height: 180,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              alignment: Alignment.center,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.music_video, size: 48, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: 8),
                  Text('Queue is empty', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: Row(
              children: [
                Expanded(child: FilledButton.icon(onPressed: queue.isEmpty ? null : _playNext, icon: const Icon(Icons.skip_next), label: const Text('Next'))),
                const SizedBox(width: 12),
                Expanded(child: OutlinedButton.icon(onPressed: queue.isEmpty ? null : _clearQueue, icon: const Icon(Icons.clear_all), label: const Text('Clear queue'))),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: queue.isEmpty
                ? const Center(child: Text('No songs in queue'))
                : ListView.builder(
                    itemCount: queue.length,
                    itemBuilder: (ctx, i) {
                      final s = queue[i];
                      return ListTile(
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: Image.network(s.thumbnail, width: 48, height: 48, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Icon(Icons.music_note)),
                        ),
                        title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(s.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: i == 0 ? Chip(label: const Text('Now playing', style: TextStyle(fontSize: 11))) : null,
                      );
                    },
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: 'Search songs to add...',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    onSubmitted: (_) => _searchSongs(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _searching ? null : _searchSongs,
                  icon: _searching ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.search),
                ),
              ],
            ),
          ),
          if (_searchResults.isNotEmpty)
            SizedBox(
              height: 160,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: _searchResults.length,
                itemBuilder: (ctx, i) {
                  final s = _searchResults[i];
                  return Padding(
                    padding: const EdgeInsets.only(right: 8.0),
                    child: SizedBox(
                      width: 140,
                      child: Card(
                        child: InkWell(
                          onTap: () => _addToQueue(s),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(child: Image.network(s['thumbnail'], fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.music_note, size: 40))),
                              Padding(padding: const EdgeInsets.all(6.0), child: Text(s['title'], maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelSmall)),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                                child: FilledButton.tonal(
                                  onPressed: () => _addToQueue(s),
                                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 4), minimumSize: Size.zero),
                                  child: const Text('Add'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}