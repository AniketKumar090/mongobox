// lib/screens/join_party_screen.dart
import 'package:flutter/material.dart';
import '../services/youtube_mobile_service.dart';
import '../services/shared_queue_service.dart';

class JoinPartyScreen extends StatefulWidget {
  final VoidCallback? onBack;
  final String? partyId;
  
  const JoinPartyScreen({
    super.key, 
    this.onBack,
    this.partyId,
  });

  @override
  State<JoinPartyScreen> createState() => _JoinPartyScreenState();
}

class _JoinPartyScreenState extends State<JoinPartyScreen> {
  final _searchController = TextEditingController();
  final YoutubeMobileService _youtube = YoutubeMobileService();
  late SharedQueueService _queueService;
  late String _effectivePartyId;
  List<Map<String, dynamic>> _results = [];
  bool _searching = false;
  final Set<String> _addedIds = {};

  @override
  void initState() {
    super.initState();
    
    // Use provided partyId or default
    _effectivePartyId = widget.partyId ?? 'default_party';
    
    print('👥 ========================================');
    print('👥 GUEST JOINING PARTY');
    print('👥 Party ID: $_effectivePartyId');
    print('👥 Firebase Path: parties/$_effectivePartyId/queue');
    print('👥 ========================================');
    
    _queueService = SharedQueueService(partyId: _effectivePartyId);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

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

    try {
      print('➕ GUEST: Adding song to party $_effectivePartyId');
      print('   Song: ${song['title']}');
      print('   Video ID: $videoId');
      
      await _queueService.addSong(
        Song(
          key: '', 
          id: song['id'], 
          title: song['title'], 
          artist: song['artist'], 
          thumbnail: song['thumbnail']
        ),
      );

      print('✅ GUEST: Song added successfully');

      if (mounted) {
        setState(() => _addedIds.add(videoId));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added "${song['title']}" to the queue')),
        );
      }
    } catch (e) {
      print('❌ GUEST: Error adding song: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error adding song: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Join party'),
            Text(
              'ID: $_effectivePartyId',
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.normal),
            ),
          ],
        ),
        leading: widget.onBack != null 
          ? IconButton(icon: const Icon(Icons.close), onPressed: widget.onBack) 
          : null,
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            color: Theme.of(context).colorScheme.primaryContainer,
            child: Row(
              children: [
                Icon(Icons.info_outline, 
                  size: 20, 
                  color: Theme.of(context).colorScheme.onPrimaryContainer
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Connected to party: $_effectivePartyId',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          ),
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
                  child: _searching 
                    ? const SizedBox(
                        width: 24, 
                        height: 24, 
                        child: CircularProgressIndicator(strokeWidth: 2)
                      ) 
                    : const Text('Search'),
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
                            Icon(Icons.search, 
                              size: 64, 
                              color: Theme.of(context).colorScheme.outline
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'Search for songs to add to the queue', 
                              style: Theme.of(context).textTheme.bodyLarge
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Works in any language', 
                              style: Theme.of(context).textTheme.bodySmall
                            ),
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
                                child: Image.network(
                                  s['thumbnail'], 
                                  width: 56, 
                                  height: 56, 
                                  fit: BoxFit.cover, 
                                  errorBuilder: (_, __, ___) => const Icon(Icons.music_note)
                                ),
                              ),
                              title: Text(
                                s['title'], 
                                maxLines: 2, 
                                overflow: TextOverflow.ellipsis
                              ),
                              subtitle: Text(
                                s['artist'], 
                                maxLines: 1, 
                                overflow: TextOverflow.ellipsis
                              ),
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