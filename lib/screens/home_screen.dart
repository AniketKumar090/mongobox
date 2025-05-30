import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:html' as html;
// For web platform views
import 'dart:ui_web' as ui_web;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? currentVideoId;
  List<Map<String, dynamic>> searchResults = [];
  final _searchController = TextEditingController();
  String _iframeElement = 'youtube-player-iframe';

  static const String apiKey = 'AIzaSyBJzIb7YbZPPL2XuOGlncntEPwkc0JQpmY';

  @override
  void initState() {
    super.initState();
    _registerIframeElement();
  }

  void _registerIframeElement() {
    // Register the iframe element for web
    ui_web.platformViewRegistry.registerViewFactory(
      _iframeElement,
      (int viewId) {
        final iframe = html.IFrameElement()
          ..width = '100%'
          ..height = '315'
          ..src = 'about:blank'
          ..style.border = 'none'
          ..allow = 'accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture'
          ..allowFullscreen = true;
        
        return iframe;
      },
    );
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
    setState(() {
      currentVideoId = videoId;
    });
    
    // Update the iframe src to play the video
    final iframe = html.document.querySelector('iframe') as html.IFrameElement?;
    if (iframe != null) {
      iframe.src = 'https://www.youtube.com/embed/$videoId?autoplay=1&rel=0';
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
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Player Section
            Container(
              width: double.infinity,
              height: 250,
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
                        key: ValueKey(currentVideoId),
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
                            ),
                          ],
                        ),
                      ),
              ),
            ),

            const SizedBox(height: 24),

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
                      itemCount: searchResults.length,
                      itemBuilder: (context, index) {
                        final result = searchResults[index];
                        final isCurrentlyPlaying = currentVideoId == result['id'];
                        
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: isCurrentlyPlaying ? Colors.red[50] : Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: isCurrentlyPlaying 
                                ? Border.all(color: Colors.red[300]!, width: 2)
                                : null,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black12,
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ],
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
                            trailing: isCurrentlyPlaying
                                ? Icon(Icons.volume_up, color: Colors.red[600])
                                : Icon(Icons.play_arrow, color: Colors.grey[600]),
                            onTap: () => playSong(result['id']),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}