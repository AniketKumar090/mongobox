// lib/screens/join_party_screen.dart
import 'package:flutter/material.dart';
import '../services/youtube_mobile_service.dart';
import '../services/shared_queue_service.dart';

class JoinPartyScreen extends StatefulWidget {
  const JoinPartyScreen({super.key, this.onBack});
  final VoidCallback? onBack;

  @override
  State<JoinPartyScreen> createState() => _JoinPartyScreenState();
}

class _JoinPartyScreenState extends State<JoinPartyScreen> {
  final _searchController = TextEditingController();
  final YoutubeMobileService _youtube = YoutubeMobileService();
  List<Map<String, dynamic>> _results = [];
  bool _searching = false;
  final Set<String> _addedIds = {};

  Future<void> _search() async {
    final q = _searchController.text.trim();
    if (q.isEmpty) return;
    setState(() => _searching = true);
    final list = await _youtube.searchSongs(q);
    if (mounted) setState(() {
      _results = list;
      _searching = false;
    });
  }

  Future<void> _addToQueue(Map<String, dynamic> song) async {
    final videoId = song['id'] as String? ?? '';
    if (videoId.isEmpty || _addedIds.contains(videoId)) return;

    await SharedQueueService().addSong(
      Song(key: '', id: song['id'], title: song['title'], artist: song['artist'], thumbnail: song['thumbnail']),
    );

    if (mounted) {
      setState(() => _addedIds.add(videoId));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Added "${song['title']}" to the queue')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Join party'),
        leading: widget.onBack != null ? IconButton(icon: const Icon(Icons.close), onPressed: widget.onBack) : null,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: 'Search songs (any language)...',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      prefixIcon: const Icon(Icons.search),
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _searching ? null : _search,
                  child: _searching ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Search'),
                ),
              ],
            ),
          ),
          Expanded(
            child: _searching
                ? const Center(child: CircularProgressIndicator())
                : _results.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.search, size: 64, color: Theme.of(context).colorScheme.outline),
                            const SizedBox(height: 16),
                            Text('Search for songs to add to the queue', style: Theme.of(context).textTheme.bodyLarge),
                            const SizedBox(height: 8),
                            Text('Works in any language', style: Theme.of(context).textTheme.bodySmall),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: _results.length,
                        itemBuilder: (ctx, i) {
                          final s = _results[i];
                          final id = s['id'] as String? ?? '';
                          final added = _addedIds.contains(id);
                          return Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.network(s['thumbnail'], width: 56, height: 56, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.music_note)),
                              ),
                              title: Text(s['title'], maxLines: 2, overflow: TextOverflow.ellipsis),
                              subtitle: Text(s['artist'], maxLines: 1, overflow: TextOverflow.ellipsis),
                              trailing: FilledButton(
                                onPressed: added ? null : () => _addToQueue(s),
                                child: Text(added ? 'Added' : 'Add'),
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