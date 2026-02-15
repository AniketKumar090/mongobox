// lib/screens/web/home_screen_web.dart
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;
import 'package:qr_flutter/qr_flutter.dart';
import '../../services/shared_queue_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? currentVideoId;
  List<Song> queue = [];
  List<Map<String, dynamic>> searchResults = [];
  final _searchController = TextEditingController();
  final String _iframeElement = 'youtube-player-iframe';
  html.IFrameElement? _currentIframe;

  // Use the SAME link as mobile
  static const String _appLink = 'https://mongobox-79a1f.firebaseapp.com/join-queue.html';

  @override
  void initState() {
    super.initState();
    _registerIframeElement();

    // Listen to shared queue
    SharedQueueService().streamQueue().listen((newQueue) {
      if (mounted) {
        setState(() => queue = newQueue);
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
          ..allow = 'accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share'
          ..allowFullscreen = true
          ..id = 'youtube-player-$viewId';
        _currentIframe = iframe;
        return iframe;
      },
    );
  }

  Future<void> searchSongs(String query) async {
    try {
      final url = 'https://www.googleapis.com/youtube/v3/search?part=snippet&maxResults=10&q=${Uri.encodeQueryComponent(query)}&type=video&key=AIzaSyBJzIb7YbZPPL2XuOGlncntEPwkc0JQpmY';
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          searchResults = (data['items'] as List).map((item) {
            return {
              'id': item['id']['videoId'],
              'title': item['snippet']['title'],
              'thumbnail': item['snippet']['thumbnails']['default']['url'],
              'artist': item['snippet']['channelTitle'],
            };
          }).toList();
        });
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Search error: $e')));
    }
  }

  void playSong(String videoId) {
    _stopCurrentVideo();
    setState(() => currentVideoId = videoId);
    _updateIframeSource(videoId);
  }

  void _stopCurrentVideo() {
    try {
      _currentIframe?.src = 'about:blank';
    } catch (e) {
      print('Stop video error: $e');
    }
  }

  void _updateIframeSource(String videoId) {
    try {
      final src = 'https://www.youtube.com/embed/$videoId?autoplay=1&rel=0&enablejsapi=1&origin=${html.window.location.origin}';
      _currentIframe?.src = src;
    } catch (e) {
      print('Update iframe error: $e');
    }
  }

  Future<void> addToQueue(Map<String, dynamic> song) async {
    if (queue.any((s) => s.id == song['id'])) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Already in queue')));
      return;
    }
    await SharedQueueService().addSong(
      Song(key: '', id: song['id'], title: song['title'], artist: song['artist'], thumbnail: song['thumbnail']),
    );
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Added "${song['title']}"')));
  }

  Future<void> removeFromQueue(String key) async {
    await SharedQueueService().remove(key);
  }

  Future<void> clearQueue() async {
    await SharedQueueService().clear();
  }

  void _showQRCodeDialog(BuildContext context, String qrData) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Share MongoBox"),
        content: SizedBox(
          width: 250,
          height: 250,
          child: Center(child: QrImageView(data: qrData, version: QrVersions.auto, size: 200)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text("Close")),
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
        title: const Text('MongoBox Jukebox', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.red[600],
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.qr_code), onPressed: _generateQRCode, tooltip: "Share app link"),
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
                      boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 8, offset: const Offset(0, 4))],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: currentVideoId != null
                          ? HtmlElementView(viewType: _iframeElement, key: ValueKey('player-$currentVideoId'))
                          : const Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.music_video, size: 64, color: Colors.white54),
                                  SizedBox(height: 16),
                                  Text('Search and select a song to play', style: TextStyle(color: Colors.white70, fontSize: 16), textAlign: TextAlign.center),
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
                      boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4, offset: const Offset(0, 2))],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        ElevatedButton.icon(
                          onPressed: queue.isEmpty ? null : () => removeFromQueue(queue.first.key),
                          icon: const Icon(Icons.skip_next),
                          label: const Text('Next'),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.red[600], foregroundColor: Colors.white),
                        ),
                        ElevatedButton.icon(
                          onPressed: queue.isEmpty ? null : clearQueue,
                          icon: const Icon(Icons.clear_all),
                          label: const Text('Clear Queue'),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[600], foregroundColor: Colors.white),
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
                        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4, offset: const Offset(0, 2))],
                      ),
                      child: Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.red[50],
                              borderRadius: const BorderRadius.only(topLeft: Radius.circular(12), topRight: Radius.circular(12)),
                            ),
                            child: const Row(
                              children: [
                                Icon(Icons.queue_music, color: Colors.red),
                                SizedBox(width: 8),
                                Text('Queue', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.red)),
                                Spacer(),
                                Icon(Icons.drag_handle, color: Colors.red),
                                SizedBox(width: 4),
                                Text('Drag to reorder', style: TextStyle(fontSize: 12, color: Colors.red, fontStyle: FontStyle.italic)),
                              ],
                            ),
                          ),
                          Expanded(
                            child: queue.isEmpty
                                ? const Center(
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.queue_music, size: 48, color: Colors.grey),
                                        SizedBox(height: 8),
                                        Text('No songs in queue', style: TextStyle(color: Colors.grey, fontSize: 14)),
                                      ],
                                    ),
                                  )
                                : ListView.builder(
                                    padding: const EdgeInsets.all(8),
                                    itemCount: queue.length,
                                    itemBuilder: (context, index) {
                                      final song = queue[index];
                                      return ListTile(
                                        key: ValueKey(song.key),
                                        leading: ClipRRect(
                                          borderRadius: BorderRadius.circular(4),
                                          child: Image.network(song.thumbnail, width: 40, height: 40, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.music_note)),
                                        ),
                                        title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                                        subtitle: Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                                        trailing: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            IconButton(
                                              icon: const Icon(Icons.play_arrow),
                                              onPressed: () => playSong(song.id),
                                              tooltip: 'Play Now',
                                            ),
                                            IconButton(
                                              icon: const Icon(Icons.close, color: Colors.red),
                                              onPressed: () => removeFromQueue(song.key),
                                              tooltip: 'Remove',
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
                      boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4, offset: const Offset(0, 2))],
                    ),
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Search songs (any language)...',
                        prefixIcon: const Icon(Icons.search, color: Colors.red),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.send, color: Colors.red),
                          onPressed: () {
                            if (_searchController.text.trim().isNotEmpty) {
                              searchSongs(_searchController.text);
                            }
                          },
                        ),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                        filled: true,
                        fillColor: Colors.white,
                      ),
                      onSubmitted: (value) => searchSongs(value),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4, offset: const Offset(0, 2))],
                      ),
                      child: searchResults.isEmpty
                          ? const Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.search, size: 64, color: Colors.grey),
                                  SizedBox(height: 16),
                                  Text('Search for songs to see results', style: TextStyle(fontSize: 16, color: Colors.grey)),
                                ],
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.all(8),
                              itemCount: searchResults.length,
                              itemBuilder: (context, index) {
                                final s = searchResults[index];
                                final isInQueue = queue.any((song) => song.id == s['id']);
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
                                      onPressed: isInQueue ? null : () => addToQueue(s),
                                      child: Text(isInQueue ? 'Added' : 'Add'),
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
}