import 'dart:convert';

import 'package:http/http.dart' as http;

import 'env_config.dart';

/// Fetches BPM for a YouTube track from the voice backend.
/// Used for beat-synced karaoke cursor timing.
class BpmService {
  BpmService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Returns BPM (50–220) or null if unavailable.
  Future<double?> fetchBpm(String videoId) async {
    if (videoId.isEmpty) return null;
    final base = await EnvConfig.resolveVoiceBackendUrl();
    final uri = Uri.parse(
      '$base/analyze-bpm',
    ).replace(queryParameters: {'video_id': videoId});
    try {
      final response = await _client
          .get(uri)
          .timeout(const Duration(seconds: 45));
      if (response.statusCode != 200) return null;
      final data = json.decode(response.body) as Map<String, dynamic>?;
      if (data == null) return null;
      final bpm = data['bpm'];
      if (bpm == null) return null;
      final v = (bpm is num) ? bpm.toDouble() : double.tryParse('$bpm');
      return (v != null && v >= 50 && v <= 220) ? v : null;
    } catch (_) {
      return null;
    }
  }
}
