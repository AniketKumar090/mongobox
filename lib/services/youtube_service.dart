import 'dart:convert';
import 'package:http/http.dart' as http;

class YouTubeService {
  static const _apiKey = 'AIzaSyBJzIb7YbZPPL2XuOGlncntEPwkc0JQpmY'; // From Step 1
  static const _baseUrl = 'https://www.googleapis.com/youtube/v3';

  Future<List<Map<String, dynamic>>> searchSongs(String query) async {
    final response = await http.get(
      Uri.parse(
        '$_baseUrl/search?part=snippet&maxResults=10&q=${Uri.encodeQueryComponent(query)}&type=video&key=$_apiKey',
      ),
    );

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return (data['items'] as List).map((item) {
        return {
          'id': item['id']['videoId'],
          'title': item['snippet']['title'],
          'thumbnail': item['snippet']['thumbnails']['default']['url'],
          'channel': item['snippet']['channelTitle'],
        };
      }).toList();
    } else {
      throw Exception('Failed to load songs');
    }
  }
}