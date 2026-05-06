import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/song_reference.dart';
import 'env_config.dart';

class VoiceCloneResult {
  const VoiceCloneResult({
    required this.file,
    required this.mixIncluded,
    this.mixLabel,
    this.backgroundMusicUrl,
    this.backgroundMusicLabel,
  });

  final File file;
  final bool mixIncluded;
  final String? mixLabel;
  final String? backgroundMusicUrl;
  final String? backgroundMusicLabel;
}

class _LangMeta {
  const _LangMeta({required this.ttsLanguageCode});

  final String ttsLanguageCode;
}

class VoiceCloneService {
  VoiceCloneService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _langTable = <String, _LangMeta>{
    'hindi': _LangMeta(ttsLanguageCode: 'hi-IN'),
    'hinglish': _LangMeta(ttsLanguageCode: 'hi-IN'),
    'urdu': _LangMeta(ttsLanguageCode: 'ur-PK'),
    'punjabi': _LangMeta(ttsLanguageCode: 'pa-IN'),
    'bengali': _LangMeta(ttsLanguageCode: 'bn-IN'),
    'tamil': _LangMeta(ttsLanguageCode: 'ta-IN'),
    'telugu': _LangMeta(ttsLanguageCode: 'te-IN'),
    'marathi': _LangMeta(ttsLanguageCode: 'mr-IN'),
    'gujarati': _LangMeta(ttsLanguageCode: 'gu-IN'),
    'kannada': _LangMeta(ttsLanguageCode: 'kn-IN'),
    'malayalam': _LangMeta(ttsLanguageCode: 'ml-IN'),
    'british': _LangMeta(ttsLanguageCode: 'en-GB'),
    'american': _LangMeta(ttsLanguageCode: 'en-US'),
    'english': _LangMeta(ttsLanguageCode: 'en-GB'),
  };

  static const _defaultMeta = _LangMeta(ttsLanguageCode: 'hi-IN');

  static String _normalise(String language) {
    final lower = language.trim().toLowerCase();
    final cleaned =
        lower
            .replaceAll(RegExp(r'\s*dominant\s*'), '')
            .replaceAll(RegExp(r'\s*language\s*'), '')
            .trim();
    return cleaned;
  }

  _LangMeta _resolveLangMeta({
    required String language,
    SongReference? referenceSong,
  }) {
    final key = _normalise(language);

    if (_langTable.containsKey(key)) return _langTable[key]!;

    for (final entry in _langTable.entries) {
      if (key.contains(entry.key)) return entry.value;
    }

    final artist = (referenceSong?.artistName ?? '').toLowerCase();
    if (artist.isNotEmpty) {
      const britishMarkers = [
        'adele',
        'ed sheeran',
        'coldplay',
        'dua lipa',
        'sam smith',
        'stormzy',
      ];
      const americanMarkers = [
        'taylor swift',
        'drake',
        'kanye',
        'weeknd',
        'billie eilish',
        'kendrick',
      ];
      const southAsianMarkers = [
        'arijit',
        'atif',
        'shreya',
        'sonu',
        'sunidhi',
        'diljit',
        'badshah',
        'raftaar',
        'neha',
        'darshan',
        'jubin',
        'armaan',
        'pritam',
        'rahman',
        'kishore',
        'lata',
        'shankar',
        'ehsaan',
        'loy',
        'ap dhillon',
        'karan aujla',
        'gurnam',
        'jassi',
        'guru randhawa',
      ];
      if (southAsianMarkers.any(artist.contains)) return _langTable['hindi']!;
      if (britishMarkers.any(artist.contains)) return _langTable['british']!;
      if (americanMarkers.any(artist.contains)) return _langTable['american']!;
    }

    return _defaultMeta;
  }

  Future<VoiceCloneResult> cloneVoice({
    required String voiceSamplePath,
    required String lyrics,
    required String requestId,
    String mood = '',
    String genre = '',
    String language = '',
    String? voiceboxProfileId,
    SongReference? referenceSong,
  }) async {
    final meta = _resolveLangMeta(
      language: language,
      referenceSong: referenceSong,
    );

    final backendUrl = await EnvConfig.resolveVoiceBackendUrl();
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$backendUrl/clone'),
    );

    request.fields['request_id'] = requestId;
    request.fields['lyrics'] = lyrics;
    request.fields['mood'] = mood;
    request.fields['genre'] = genre;

    request.fields['language'] = _normalise(language);
    request.fields['tts_language_code'] = meta.ttsLanguageCode;

    final trimmedVoiceboxProfileId = voiceboxProfileId?.trim() ?? '';
    if (trimmedVoiceboxProfileId.isNotEmpty) {
      request.fields['voicebox_profile_id'] = trimmedVoiceboxProfileId;
    }

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
      final physicalIosLoopback =
          await EnvConfig.isPhysicalIosDeviceUsingLocalBackend();
      throw Exception(
        physicalIosLoopback
            ? EnvConfig.voiceBackendPhysicalDeviceHelp()
            : 'Could not reach the voice backend at $backendUrl. '
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

    final mixStatus =
        (response.headers['x-mongobox-mix-status'] ?? '').trim().toLowerCase();
    final mixLabel = response.headers['x-mongobox-mix-label']?.trim();
    final musicUrlHeader = response.headers['x-mongobox-music-url']?.trim();
    final musicLabel = response.headers['x-mongobox-music-label']?.trim();
    final resolvedMusicUrl =
        musicUrlHeader == null || musicUrlHeader.isEmpty
            ? null
            : Uri.parse(backendUrl).resolve(musicUrlHeader).toString();

    return VoiceCloneResult(
      file: file,
      mixIncluded: mixStatus == 'mixed',
      mixLabel: mixLabel?.isNotEmpty == true ? mixLabel : null,
      backgroundMusicUrl:
          resolvedMusicUrl?.isNotEmpty == true ? resolvedMusicUrl : null,
      backgroundMusicLabel: musicLabel?.isNotEmpty == true ? musicLabel : null,
    );
  }

  Future<void> cancelClone(String requestId) async {
    final trimmed = requestId.trim();
    if (trimmed.isEmpty) return;

    final backendUrl = await EnvConfig.resolveVoiceBackendUrl();
    try {
      final response = await _client
          .post(
            Uri.parse('$backendUrl/clone/cancel'),
            body: {'request_id': trimmed},
          )
          .timeout(const Duration(seconds: 3));

      if (response.statusCode >= 400) {
        throw Exception(
          'Voice backend rejected the cancellation request '
          '(${response.statusCode}).',
        );
      }
    } on TimeoutException {
      throw Exception(
        'Cancellation timed out while waiting for the voice backend.',
      );
    } on SocketException {
      final physicalIosLoopback =
          await EnvConfig.isPhysicalIosDeviceUsingLocalBackend();
      throw Exception(
        physicalIosLoopback
            ? EnvConfig.voiceBackendPhysicalDeviceHelp()
            : 'Could not reach the voice backend to stop cloning.',
      );
    }
  }

  void dispose() {
    _client.close();
  }
}
