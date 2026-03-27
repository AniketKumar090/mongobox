// lib/screens/join_party_screen.dart
import 'package:flutter/material.dart';
import '../services/youtube_mobile_service.dart';
import '../services/shared_queue_service.dart';
import '../widgets/lyric_page_scaffold.dart';

class JoinPartyScreen extends StatefulWidget {
  final VoidCallback? onBack;
  final String? partyId;

  const JoinPartyScreen({super.key, this.onBack, this.partyId});

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
    try {
      final list = await _youtube.searchSongs(q);
      if (!mounted) return;
      setState(() {
        _results = list;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _searching = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not search songs: $e')));
    }
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
          thumbnail: song['thumbnail'],
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error adding song: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return LyricPageScaffold(
      title: 'Join a party',
      subtitle:
          'Search anything you want to hear, then send it straight to the host queue without leaving the Lyric flow.',
      badge: 'Guest mode',
      actions: [
        if (widget.onBack != null)
          OutlinedButton.icon(
            onPressed: widget.onBack,
            icon: const Icon(Icons.close_rounded, size: 18),
            label: const Text('Close'),
          ),
      ],
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
                        'Connected to the room',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Every song you add lands in the host queue for this live party.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          LyricStatChip(
                            label: 'Party ID',
                            value: _effectivePartyId,
                            icon: Icons.tag_rounded,
                          ),
                          const LyricTag(
                            label: 'Live queue',
                            icon: Icons.bolt_rounded,
                            highlighted: true,
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
                        'Search songs',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Search in any language, tap add, and your suggestion is instantly sent to the host.',
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
                                  hintText: 'Search songs (any language)...',
                                  border: InputBorder.none,
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 16,
                                  ),
                                ),
                                onSubmitted: (_) => _search(),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: FilledButton(
                                onPressed: _searching ? null : _search,
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
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                LyricSectionCard(
                  child:
                      _searching
                          ? const Padding(
                            padding: EdgeInsets.all(28),
                            child: Center(child: CircularProgressIndicator()),
                          )
                          : _results.isEmpty
                          ? const _JoinEmptyState()
                          : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Results',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Add the track you want to hear next.',
                                style: Theme.of(
                                  context,
                                ).textTheme.bodySmall?.copyWith(
                                  color:
                                      Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 14),
                              ListView.separated(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: _results.length,
                                separatorBuilder:
                                    (_, __) => const SizedBox(height: 10),
                                itemBuilder: (ctx, i) {
                                  final song = _results[i];
                                  final id = song['id'] as String? ?? '';
                                  final added = _addedIds.contains(id);
                                  return _JoinResultTile(
                                    title:
                                        song['title'] as String? ?? 'Untitled',
                                    artist:
                                        song['artist'] as String? ??
                                        'Unknown artist',
                                    thumbnail:
                                        song['thumbnail'] as String? ?? '',
                                    added: added,
                                    onPressed:
                                        added ? null : () => _addToQueue(song),
                                  );
                                },
                              ),
                            ],
                          ),
                ),
              ],
            ),
      ),
    );
  }
}

class _JoinEmptyState extends StatelessWidget {
  const _JoinEmptyState();

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
          Icon(Icons.search_rounded, size: 46, color: cs.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            'Search for songs to add to the queue',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            'Works in any language.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _JoinResultTile extends StatelessWidget {
  const _JoinResultTile({
    required this.title,
    required this.artist,
    required this.thumbnail,
    required this.added,
    required this.onPressed,
  });

  final String title;
  final String artist;
  final String thumbnail;
  final bool added;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color:
            added
                ? cs.secondaryContainer.withValues(alpha: 0.7)
                : cs.tertiaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        leading: LyricThumbnailAvatar(imageUrl: thumbnail, size: 56),
        title: Text(
          title,
          maxLines: 2,
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
        trailing:
            added
                ? const LyricTag(
                  label: 'Added',
                  icon: Icons.check_rounded,
                  highlighted: true,
                )
                : FilledButton(onPressed: onPressed, child: const Text('Add')),
      ),
    );
  }
}
