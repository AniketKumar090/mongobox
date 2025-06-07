import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class SuggestSongScreen extends StatefulWidget {
  const SuggestSongScreen({super.key});

  @override
  State<SuggestSongScreen> createState() => _SuggestSongScreenState();
}

class _SuggestSongScreenState extends State<SuggestSongScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> searchResults = [];
  String? selectedSongId;

  Future<void> searchSongs(String query) async {
    final apiKey = 'AIzaSyBJzIb7YbZPPL2XuOGlncntEPwkc0JQpmY'; // Same as in HomeScreen
    final url =
        'https://www.googleapis.com/youtube/v3/search?part=snippet&maxResults=5&q=${Uri.encodeQueryComponent(query)}&type=video&key=$apiKey';

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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to load songs')),
      );
    }
  }

  void suggestSong(String videoId) {
    // This should send the suggested song to backend or Firestore
    print("Suggested Song ID: $videoId");
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Song suggested successfully!')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Suggest a Song"),
        backgroundColor: Colors.red[600],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                labelText: "Search for a song",
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () => searchSongs(_searchController.text),
                ),
              ),
              onSubmitted: (value) => searchSongs(value),
            ),
            const SizedBox(height: 20),
            Expanded(
              child: ListView.builder(
                itemCount: searchResults.length,
                itemBuilder: (context, index) {
                  final song = searchResults[index];
                  return ListTile(
                    leading: Image.network(song['thumbnail']),
                    title: Text(song['title']),
                    subtitle: Text(song['channel']),
                    trailing: IconButton(
                      icon: const Icon(Icons.add_circle_outline),
                      onPressed: () => suggestSong(song['id']),
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