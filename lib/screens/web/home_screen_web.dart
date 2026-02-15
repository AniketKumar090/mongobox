// Web-only jukebox home screen (uses dart:html, iframe). Queue stored locally.

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;
import 'package:qr_flutter/qr_flutter.dart';
import '../../services/local_queue_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? currentVideoId;
  List<Map<String, dynamic>> searchResults = [];
  List<Map<String, dynamic>> queue = [];
  final _searchController = TextEditingController();
  final String _iframeElement = 'youtube-player-iframe';
  html.IFrameElement? _currentIframe;
  LocalQueueService? _queueService;

  static const String apiKey = 'AIzaSyBJzIb7YbZPPL2XuOGlncntEPwkc0JQpmY';
  static const String _appLink = 'https://mongobox-79a1f.firebaseapp.com/join-queue.html';

  @override
  void initState() {
    super.initState();
    _registerIframeElement();
    LocalQueueService.create().then((service) {
      if (mounted) {
        setState(() {
          _queueService = service;
          queue = service.getQueue();
        });
      }
    });
  }

  void _registerIframeElement() {
    ui_web.platformViewRegistry.registerViewFactory(
      _iframeElement,
      (int viewId) {
        final iframe = html.IFrameElement()
          ..width = '100%'
          ..height = '100%'
          ..src = 'about:blank'
          ..style.border = 'none'
          ..allow =
              'accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share'
          ..allowFullscreen = true
          ..id = 'youtube-player-$viewId';
        _currentIframe = iframe;
        return iframe;
      },
    );
  }

  void _refreshQueue() {
    if (_queueService != null) {
      setState(() => queue = _queueService!.getQueue());
    }
  }

  Future<void> searchSongs(String query) async {
    try {
      final url =
          'https://www.googleapis.com/youtube/v3/search?part=snippet&maxResults=10&q=${Uri.encodeQueryComponent(query)}&type=video&key=$apiKey';
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          searchResults = (data['items'] as List).map((item) {
            return {
              'id': item['id']['videoId'],
              'title': item['snippet']['title'],
              'thumbnail': item['snippet']['thumbnails']['default']['url'],
              'channel': item['snippet']['channelTitle'],
            };
          }).toList();
        });
      } else {
        throw Exception('Failed to load songs: ${response.statusCode}');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error searching songs: $e')),
      );
    }
  }

  void playSong(String videoId) {
    _stopCurrentVideo();
    setState(() {
      currentVideoId = videoId;
    });
    Future.delayed(const Duration(milliseconds: 200), () {
      _updateIframeSource(videoId);
      Future.delayed(const Duration(milliseconds: 100), () {
        _updateIframeSource(videoId);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _updateIframeSource(videoId);
      });
    });
  }

  void _stopCurrentVideo() {
    try {
      if (_currentIframe != null) {
        _currentIframe!.src = 'about:blank';
        return;
      }
      final iframe = html.document.querySelector('iframe[id*="youtube-player"]')
          as html.IFrameElement?;
      if (iframe != null) {
        iframe.src = 'about:blank';
        return;
      }
      final iframes = html.document.querySelectorAll('iframe');
      for (final element in iframes) {
        if (element is html.IFrameElement) {
          element.src = 'about:blank';
          break;
        }
      }
    } catch (e) {
      print('Error stopping video: $e');
    }
  }

  void _updateIframeSource(String videoId) {
    try {
      if (_currentIframe != null) {
        _currentIframe!.src =
            'https://www.youtube.com/embed/$videoId?autoplay=1&rel=0&enablejsapi=1&origin=${html.window.location.origin}';
        return;
      }
      final iframe = html.document.querySelector('iframe[id*="youtube-player"]')
          as html.IFrameElement?;
      if (iframe != null) {
        iframe.src =
            'https://www.youtube.com/embed/$videoId?autoplay=1&rel=0&enablejsapi=1&origin=${html.window.location.origin}';
        return;
      }
      final iframes = html.document.querySelectorAll('iframe');
      for (final element in iframes) {
        if (element is html.IFrameElement) {
          element.src =
              'https://www.youtube.com/embed/$videoId?autoplay=1&rel=0&enablejsapi=1&origin=${html.window.location.origin}';
          break;
        }
      }
    } catch (e) {
      print('Error updating iframe: $e');
    }
  }

  Future<void> addToQueue(Map<String, dynamic> song) async {
    if (_queueService == null) return;
    if (queue.any((item) => item['id'] == song['id'])) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Song already in queue')),
      );
      return;
    }
    await _queueService!.addSong(song);
    _refreshQueue();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added "${song['title']}" to queue')),
      );
    }
  }

  Future<void> playFromQueue(int index) async {
    if (index < queue.length) {
      final song = queue[index];
      playSong(song['id'] as String);
      await removeFromQueue(index);
    }
  }

  Future<void> removeFromQueue(int index) async {
    if (_queueService == null || index < 0 || index >= queue.length) return;
    final removedTitle = queue[index]['title'];
    await _queueService!.removeAt(index);
    _refreshQueue();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Removed "$removedTitle" from queue')),
      );
    }
  }

  Future<void> _onQueueReorder(int oldIndex, int newIndex) async {
    if (_queueService == null) return;
    if (newIndex > oldIndex) newIndex -= 1;
    await _queueService!.reorder(oldIndex, newIndex);
    _refreshQueue();
  }

  Future<void> clearQueue() async {
    if (_queueService == null) return;
    await _queueService!.clear();
    _refreshQueue();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Queue cleared')),
      );
    }
  }

  void _showQRCodeDialog(BuildContext context, String qrData) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Share MongoBox"),
        content: SizedBox(
          width: 250,
          height: 250,
          child: Center(
            child: QrImageView(
              data: qrData,
              version: QrVersions.auto,
              size: 200,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text("Close"),
          )
        ],
      ),
    );
  }

  void _generateQRCode() {
    _showQRCodeDialog(context, _appLink);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: const Text(
          'MongoBox Jukebox',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.red[600],
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code),
            onPressed: _generateQRCode,
            tooltip: "Share app link",
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 1,
              child: Column(
                children: [
                  Container(
                    width: double.infinity,
                    height: MediaQuery.of(context).size.height * 0.4,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: currentVideoId != null
                          ? HtmlElementView(
                              viewType: _iframeElement,
                              key: ValueKey('player-$currentVideoId'),
                            )
                          : const Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.music_video,
                                    size: 64,
                                    color: Colors.white54,
                                  ),
                                  SizedBox(height: 16),
                                  Text(
                                    'Search and select a song to play',
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 16,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black12,
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        ElevatedButton.icon(
                          onPressed: queue.isNotEmpty ? () => playNext() : null,
                          icon: const Icon(Icons.skip_next),
                          label: const Text('Next'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red[600],
                            foregroundColor: Colors.white,
                          ),
                        ),
                        ElevatedButton.icon(
                          onPressed: queue.isNotEmpty ? clearQueue : null,
                          icon: const Icon(Icons.clear_all),
                          label: const Text('Clear Queue'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.grey[600],
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black12,
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.red[50],
                              borderRadius: const BorderRadius.only(
                                topLeft: Radius.circular(12),
                                topRight: Radius.circular(12),
                              ),
                            ),
                            child: const Row(
                              children: [
                                Icon(Icons.queue_music, color: Colors.red),
                                SizedBox(width: 8),
                                Text(
                                  'Queue',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.red,
                                  ),
                                ),
                                Spacer(),
                                Icon(Icons.drag_handle, color: Colors.red),
                                SizedBox(width: 4),
                                Text(
                                  'Drag to reorder',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.red,
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: queue.isEmpty
                                ? const Center(
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          Icons.queue_music,
                                          size: 48,
                                          color: Colors.grey,
                                        ),
                                        SizedBox(height: 8),
                                        Text(
                                          'No songs in queue',
                                          style: TextStyle(
                                            color: Colors.grey,
                                            fontSize: 14,
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                : ReorderableListView.builder(
                                    padding: const EdgeInsets.all(8),
                                    itemCount: queue.length,
                                    onReorder: _onQueueReorder,
                                    itemBuilder: (context, index) {
                                      final song = queue[index];
                                      return ListTile(
                                        key: ValueKey('queue-${song['id']}-$index'),
                                        dense: true,
                                        leading: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              '${index + 1}.',
                                              style: const TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.grey,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            ClipRRect(
                                              borderRadius: BorderRadius.circular(4),
                                              child: Image.network(
                                                song['thumbnail'],
                                                width: 40,
                                                height: 40,
                                                fit: BoxFit.cover,
                                                errorBuilder:
                                                    (context, error, stackTrace) {
                                                  return Container(
                                                    width: 40,
                                                    height: 40,
                                                    color: Colors.grey[300],
                                                    child: const Icon(Icons.music_note),
                                                  );
                                                },
                                              ),
                                            ),
                                          ],
                                        ),
                                        title: Text(
                                          song['title'],
                                          style: const TextStyle(fontSize: 12),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        subtitle: Text(
                                          song['artist'],
                                          style: const TextStyle(fontSize: 10),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        trailing: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const SizedBox(width: 12),
                                            IconButton(
                                              icon: const Icon(Icons.play_arrow, size: 20),
                                              onPressed: () => playFromQueue(index),
                                              padding: EdgeInsets.zero,
                                              constraints: const BoxConstraints(),
                                              tooltip: 'Play Now',
                                            ),
                                            IconButton(
                                              icon: const Icon(Icons.close, size: 20, color: Colors.red),
                                              onPressed: () => removeFromQueue(index),
                                              tooltip: 'Remove from Queue',
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 2,
              child: Column(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black12,
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        labelText: 'Search for songs',
                        hintText: 'Enter song name, artist, or keywords...',
                        prefixIcon: const Icon(Icons.search, color: Colors.red),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.send, color: Colors.red),
                          onPressed: () {
                            if (_searchController.text.trim().isNotEmpty) {
                              searchSongs(_searchController.text);
                            }
                          },
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        fillColor: Colors.white,
                      ),
                      onSubmitted: (value) {
                        if (value.trim().isNotEmpty) {
                          searchSongs(value);
                        }
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black12,
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: searchResults.isEmpty
                          ? const Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.search,
                                    size: 64,
                                    color: Colors.grey,
                                  ),
                                  SizedBox(height: 16),
                                  Text(
                                    'Search for songs to see results here',
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: Colors.grey,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.all(8),
                              itemCount: searchResults.length,
                              itemBuilder: (context, index) {
                                final result = searchResults[index];
                                final isCurrentlyPlaying =
                                    currentVideoId == result['id'];
                                final isInQueue = queue
                                    .any((item) => item['id'] == result['id']);
                                return Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  decoration: BoxDecoration(
                                    color: isCurrentlyPlaying
                                        ? Colors.red[50]
                                        : Colors.white,
                                    borderRadius: BorderRadius.circular(8),
                                    border: isCurrentlyPlaying
                                        ? Border.all(
                                            color: Colors.red[300]!, width: 2)
                                        : Border.all(
                                            color: Colors.grey[200]!, width: 1),
                                  ),
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.all(12),
                                    leading: ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: Image.network(
                                        result['thumbnail'],
                                        width: 60,
                                        height: 60,
                                        fit: BoxFit.cover,
                                        errorBuilder:
                                            (context, error, stackTrace) {
                                          return Container(
                                            width: 60,
                                            height: 60,
                                            color: Colors.grey[300],
                                            child: const Icon(Icons.music_note),
                                          );
                                        },
                                      ),
                                    ),
                                    title: Text(
                                      result['title'],
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: isCurrentlyPlaying
                                            ? Colors.red[700]
                                            : Colors.black87,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text(
                                        result['channel'],
                                        style: TextStyle(
                                          color: Colors.grey[600],
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (isInQueue)
                                          Icon(Icons.queue_music,
                                              color: Colors.orange[600], size: 20),
                                        const SizedBox(width: 8),
                                        IconButton(
                                          icon: Icon(
                                            Icons.add_to_queue,
                                            color: isInQueue
                                                ? Colors.grey
                                                : Colors.blue[600],
                                          ),
                                          onPressed: isInQueue
                                              ? null
                                              : () => addToQueue(result),
                                          tooltip: 'Add to Queue',
                                        ),
                                        IconButton(
                                          icon: Icon(
                                            isCurrentlyPlaying
                                                ? Icons.volume_up
                                                : Icons.play_arrow,
                                            color: isCurrentlyPlaying
                                                ? Colors.red[600]
                                                : Colors.green[600],
                                          ),
                                          onPressed: () => playSong(result['id']),
                                          tooltip: 'Play Now',
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> playNext() async {
    if (_queueService == null || queue.isEmpty) return;
    final nextSong = queue.first;
    await _queueService!.removeFirst();
    _refreshQueue();
    if (mounted) playSong(nextSong['id'] as String);
  }
}
