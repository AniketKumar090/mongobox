// home_screen.dart

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:html' as html;
import 'dart:ui';
import 'dart:ui_web' as ui_web;
import 'package:qr_flutter/qr_flutter.dart';

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

  static const String apiKey = 'AIzaSyBJzIb7YbZPPL2XuOGlncntEPwkc0JQpmY';

  @override
  void initState() {
    super.initState();
    _registerIframeElement();
    _listenToQueueChanges();
  }

  void _registerIframeElement() {
    // Register the iframe element for web
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
        // Store reference to the iframe
        _currentIframe = iframe;
        return iframe;
      },
    );
  }

  void _listenToQueueChanges() {
  FirebaseFirestore.instance
      .collection('queues')
      .doc('currentQueue')
      .snapshots()
      .listen((snapshot) {
    if (snapshot.exists) {
      final songsData = snapshot.get('songs') as List<dynamic>? ?? [];
      final sanitizedQueue = songsData.map((song) {
        // Validate and sanitize the song data
        final id = song['id']?.toString() ?? '';
        final title = song['title']?.toString() ?? 'Unknown Title';
        final channel = song['artist']?.toString() ?? 'Unknown Artist';
        final thumbnail = song['thumbnail']?.toString() ?? 'https://via.placeholder.com/60x60';  
        if (id.isEmpty || title.isEmpty || channel.isEmpty || thumbnail.isEmpty) {
          print("Malformed song object: $song");
        }
        return {
          'id': id,
          'title': title,
          'channel': channel,
          'thumbnail': thumbnail,
        };
      }).toList();
      setState(() {
        queue = sanitizedQueue;
      });
    }
  });
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
    print('Playing video: $videoId'); // Debug log
    // First stop any currently playing video
    _stopCurrentVideo();
    setState(() {
      currentVideoId = videoId;
    });
    // Small delay to ensure previous video is stopped before loading new one
    Future.delayed(const Duration(milliseconds: 200), () {
      // Multiple strategies to ensure the iframe gets updated
      _updateIframeSource(videoId);
      // Also try after a small delay to ensure DOM is ready
      Future.delayed(const Duration(milliseconds: 100), () {
        _updateIframeSource(videoId);
      });
      // And one more time with post-frame callback
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _updateIframeSource(videoId);
      });
    });
  }

  void _stopCurrentVideo() {
    try {
      // Method 1: Use stored reference
      if (_currentIframe != null) {
        _currentIframe!.src = 'about:blank';
        print('Stopped video via stored reference');
        return;
      }
      // Method 2: Find by specific ID pattern
      final iframe = html.document.querySelector('iframe[id*="youtube-player"]') as html.IFrameElement?;
      if (iframe != null) {
        iframe.src = 'about:blank';
        print('Stopped video via querySelector');
        return;
      }
      // Method 3: Find any iframe in the document
      final iframes = html.document.querySelectorAll('iframe');
      for (final element in iframes) {
        if (element is html.IFrameElement) {
          element.src = 'about:blank';
          print('Stopped video via fallback method');
          break;
        }
      }
    } catch (e) {
      print('Error stopping video: $e');
    }
  }

  void _updateIframeSource(String videoId) {
    try {
      // Method 1: Use stored reference
      if (_currentIframe != null) {
        _currentIframe!.src = 'https://www.youtube.com/embed/$videoId?autoplay=1&rel=0&enablejsapi=1&origin=${html.window.location.origin}';
        print('Updated iframe via stored reference');
        return;
      }
      // Method 2: Find by specific ID pattern
      final iframe = html.document.querySelector('iframe[id*="youtube-player"]') as html.IFrameElement?;
      if (iframe != null) {
        iframe.src = 'https://www.youtube.com/embed/$videoId?autoplay=1&rel=0&enablejsapi=1&origin=${html.window.location.origin}';
        print('Updated iframe via querySelector');
        return;
      }
      // Method 3: Find any iframe in the document
      final iframes = html.document.querySelectorAll('iframe');
      for (final element in iframes) {
        if (element is html.IFrameElement) {
          element.src = 'https://www.youtube.com/embed/$videoId?autoplay=1&rel=0&enablejsapi=1&origin=${html.window.location.origin}';
          print('Updated iframe via fallback method');
          break;
        }
      }
    } catch (e) {
      print('Error updating iframe: $e');
    }
  }

  void addToQueue(Map<String, dynamic> song) {
  setState(() {
    if (!queue.any((item) => item['id'] == song['id'])) {
      // Validate and sanitize the song data
      final sanitizedSong = {
        'id': song['id']?.toString() ?? '',
        'title': song['title']?.toString() ?? 'Unknown Title',
        'channel': song['artist']?.toString() ?? 'Unknown Artist',
        'thumbnail': song['thumbnail']?.toString() ?? 'https://via.placeholder.com/60x60', 
      };

      queue.add(sanitizedSong);
      FirebaseFirestore.instance.collection('queues').doc('currentQueue').set({
        'songs': FieldValue.arrayUnion([sanitizedSong])
      }, SetOptions(merge: true));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added "${sanitizedSong['title']}" to queue')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Song already in queue')),
      );
    }
  });
}
  void playFromQueue(int index) {
    if (index < queue.length) {
      final song = queue[index];
      playSong(song['id']);
      removeFromQueue(index);
    }
  }

  void removeFromQueue(int index) {
    setState(() {
      if (index < queue.length) {
        final removedSong = queue.removeAt(index);
        FirebaseFirestore.instance.collection('queues').doc('currentQueue').update({
          'songs': queue,
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Removed "${removedSong['title']}" from queue')),
        );
      }
    });
  }

  void _onQueueReorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      final item = queue.removeAt(oldIndex);
      queue.insert(newIndex, item);

      FirebaseFirestore.instance.collection('queues').doc('currentQueue').update({
        'songs': queue,
      });
    });
  }

  void clearQueue() {
    setState(() {
      queue.clear();
      FirebaseFirestore.instance.collection('queues').doc('currentQueue').update({
        'songs': [],
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Queue cleared')),
      );
    });
  }

  void _showQRCodeDialog(BuildContext context, String qrData) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Scan to Join Queue"),
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
            onPressed: Navigator.of(context).pop,
            child: const Text("Close"),
          )
        ],
      ),
    );
  }

  void _generateQRCode() {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser != null) {
      final qrLink = 'https://mongobox-79a1f.firebaseapp.com/join-queue.html?uid=${currentUser.uid}';
      _showQRCodeDialog(context, qrLink);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('User not logged in')),
      );
    }
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
            icon: const Icon(Icons.logout),
            onPressed: () => FirebaseAuth.instance.signOut(),
            tooltip: 'Sign Out',
          ),
          IconButton(
            icon: const Icon(Icons.qr_code),
            onPressed: _generateQRCode,
            tooltip: "Generate QR Code",
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Left side - Video Player (1/3 of screen)
            Expanded(
              flex: 1,
              child: Column(
                children: [
                  // Video Player
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
                  // Player Controls
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
                  // Queue Section with Reorderable List
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
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.network(
                  song['thumbnail'], // Fallback handled in _listenToQueueChanges
                  width: 40,
                  height: 40,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) {
                    return Container(
                      width: 40,
                      height: 40,
                      color: Colors.grey[300],
                      child: const Icon(Icons.music_note),
                    );
                  },
                ),
              ),
              title: Text(
                song['title'], // Fallback handled in _listenToQueueChanges
                style: const TextStyle(fontSize: 12),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                song['channel'], // Fallback handled in _listenToQueueChanges
                style: const TextStyle(fontSize: 10),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${index + 1}',
                    style: const TextStyle(
                      fontSize: 10,
                      color: Colors.grey,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.play_arrow, size: 20),
                    onPressed: () => playFromQueue(index),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    tooltip: 'Play Now',
                  ),
                  IconButton(
                    icon: const Icon(Icons.remove, size: 20),
                    onPressed: () => removeFromQueue(index),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
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
            // Right side - Search and Results (2/3 of screen)
            Expanded(
              flex: 2,
              child: Column(
                children: [
                  // Search Bar
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
                  // Results Section
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
                                final isCurrentlyPlaying = currentVideoId == result['id'];
                                final isInQueue = queue.any((item) => item['id'] == result['id']);
                                return Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  decoration: BoxDecoration(
                                    color: isCurrentlyPlaying ? Colors.red[50] : Colors.white,
                                    borderRadius: BorderRadius.circular(8),
                                    border: isCurrentlyPlaying
                                        ? Border.all(color: Colors.red[300]!, width: 2)
                                        : Border.all(color: Colors.grey[200]!, width: 1),
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
                                        errorBuilder: (context, error, stackTrace) {
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
                                        color: isCurrentlyPlaying ? Colors.red[700] : Colors.black87,
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
                                          Icon(Icons.queue_music, color: Colors.orange[600], size: 20),
                                        const SizedBox(width: 8),
                                        IconButton(
                                          icon: Icon(
                                            Icons.add_to_queue,
                                            color: isInQueue ? Colors.grey : Colors.blue[600],
                                          ),
                                          onPressed: isInQueue ? null : () => addToQueue(result),
                                          tooltip: 'Add to Queue',
                                        ),
                                        IconButton(
                                          icon: Icon(
                                            isCurrentlyPlaying ? Icons.volume_up : Icons.play_arrow,
                                            color: isCurrentlyPlaying ? Colors.red[600] : Colors.green[600],
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

  void playNext() {
    if (queue.isNotEmpty) {
      final nextSong = queue.removeAt(0);
      playSong(nextSong['id']);
    }
  }
}