import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'env_config.dart';

class VoiceCloneService {
  VoiceCloneService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<File> cloneVoice({
    required String voiceSamplePath,
    required String lyrics,
    String mood = '',
    String genre = '',
  }) async {
    final backendUrl = EnvConfig.voiceBackendUrl;
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$backendUrl/clone'),
    );

    request.fields['lyrics'] = lyrics;
    request.fields['mood'] = mood;
    request.fields['genre'] = genre;
    request.files.add(
      await http.MultipartFile.fromPath('voice_sample', voiceSamplePath),
    );

    late final http.StreamedResponse streamedResponse;
    try {
      streamedResponse = await _client
          .send(request)
          .timeout(const Duration(minutes: 3));
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
