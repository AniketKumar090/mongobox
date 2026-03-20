import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/song_reference.dart';
import 'env_config.dart';

class VoiceCloneService {
  VoiceCloneService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  String _resolveAccentHint({
    required String language,
    SongReference? referenceSong,
  }) {
    final lang = language.trim().toLowerCase();
    const southAsianLangs = {
      'hindi',
      'urdu',
      'punjabi',
      'bengali',
      'tamil',
      'telugu',
      'marathi',
      'gujarati',
      'kannada',
      'malayalam',
    };
    if (southAsianLangs.contains(lang)) return 'indian';

    final artist = (referenceSong?.artistName ?? '').toLowerCase();
    if (artist.isEmpty) return 'indian'; // default as requested

    // Lightweight heuristics: prefer South Asian if we see common markers.
    const southAsianMarkers = [
      'arijit',
      'atif',
      'shreya',
      'sonu',
      'sunidhi',
      'kk',
      'diljit',
      'badshah',
      'raftaar',
      'neha',
      'darshan',
      'jubin',
      'armaan',
      'vishal',
      'shekhar',
      'pritam',
      'a.r.',
      'rahman',
      'rahul',
      'kishore',
      'lata',
      'mohd',
      'mohammed',
      'shankar',
      'ehsaan',
      'loy',
    ];
    if (southAsianMarkers.any(artist.contains)) return 'indian';

    // Very coarse fallbacks for Western artists. If we can’t infer, default Indian.
    const britishMarkers = ['adele', 'ed sheeran', 'coldplay', 'dua lipa', 'sam smith'];
    if (britishMarkers.any(artist.contains)) return 'british';

    const americanMarkers = ['taylor swift', 'drake', 'kanye', 'weeknd', 'billie eilish'];
    if (americanMarkers.any(artist.contains)) return 'american';

    return 'indian';
  }

  Future<File> cloneVoice({
    required String voiceSamplePath,
    required String lyrics,
    String mood = '',
    String genre = '',
    String language = '',
    SongReference? referenceSong,
  }) async {
    final backendUrl = EnvConfig.voiceBackendUrl;
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$backendUrl/clone'),
    );

    request.fields['lyrics'] = lyrics;
    request.fields['mood'] = mood;
    request.fields['genre'] = genre;
    request.fields['language'] = language;
    request.fields['accent_hint'] =
        _resolveAccentHint(language: language, referenceSong: referenceSong);
    if (referenceSong != null) {
      request.fields['reference_track_title'] = referenceSong.trackName;
      request.fields['reference_artist_name'] = referenceSong.artistName;
      request.fields['reference_lyric_snippet'] = referenceSong.lyricSnippet;
      if ((referenceSong.videoId ?? '').isNotEmpty) {
        request.fields['reference_video_id'] = referenceSong.videoId!;
      }
    }
    request.files.add(
      await http.MultipartFile.fromPath('voice_sample', voiceSamplePath),
    );

    late final http.StreamedResponse streamedResponse;
    try {
      streamedResponse = await _client
          .send(request)
          .timeout(const Duration(minutes: 10));
    } on SocketException {
      throw Exception(
        'Could not reach the voice backend at $backendUrl. '
        'Start it with: cd voice-backend && python start.py',
      );
    }

    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      final detail = response.body.trim();
      throw Exception(
        detail.isEmpty
            ? 'Voice cloning failed with status ${response.statusCode}.'
            : 'Voice cloning failed: $detail',
      );
    }

    final tempDir = await getTemporaryDirectory();
    final file = File(
      '${tempDir.path}/cloned_voice_${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    await file.writeAsBytes(response.bodyBytes, flush: true);
    return file;
  }

  void dispose() {
    _client.close();
  }
}
