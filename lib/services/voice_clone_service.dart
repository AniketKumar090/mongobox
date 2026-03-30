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
  });

  final File file;
  final bool mixIncluded;
  final String? mixLabel;
}

// ── Language metadata sent to the Python backend ──────────────────────────────
class _LangMeta {
  const _LangMeta({
    required this.accentHint,
    required this.ttsLanguageCode, // BCP-47 / ISO 639 used by TTS engines
    required this.espeak,          // eSpeak-NG voice ID (Coqui / pyttsx3)
    required this.coquiModel,      // Coqui TTS model hint
  });
  final String accentHint;
  final String ttsLanguageCode;
  final String espeak;
  final String coquiModel;
}

class VoiceCloneService {
  VoiceCloneService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  // ── Language resolution ──────────────────────────────────────────────────

  /// Maps every language variant we might receive to full TTS metadata.
  /// The Python backend should honour ALL four fields.
  static const _langTable = <String, _LangMeta>{
    // ── South Asian ──────────────────────────────────────────────────────
    'hindi': _LangMeta(
      accentHint: 'hindi',
      ttsLanguageCode: 'hi-IN',
      espeak: 'hi',
      coquiModel: 'tts_models/hi/cv/vits',
    ),
    'hinglish': _LangMeta(
      accentHint: 'hindi',          // Romanised Hindi → use Hindi accent
      ttsLanguageCode: 'hi-IN',
      espeak: 'hi',
      coquiModel: 'tts_models/hi/cv/vits',
    ),
    'urdu': _LangMeta(
      accentHint: 'urdu',
      ttsLanguageCode: 'ur-PK',
      espeak: 'ur',
      coquiModel: 'tts_models/multilingual/multi-dataset/xtts_v2',
    ),
    'punjabi': _LangMeta(
      accentHint: 'punjabi',
      ttsLanguageCode: 'pa-IN',
      espeak: 'pa',
      coquiModel: 'tts_models/multilingual/multi-dataset/xtts_v2',
    ),
    'bengali': _LangMeta(
      accentHint: 'indian',
      ttsLanguageCode: 'bn-IN',
      espeak: 'bn',
      coquiModel: 'tts_models/multilingual/multi-dataset/xtts_v2',
    ),
    'tamil': _LangMeta(
      accentHint: 'indian',
      ttsLanguageCode: 'ta-IN',
      espeak: 'ta',
      coquiModel: 'tts_models/multilingual/multi-dataset/xtts_v2',
    ),
    'telugu': _LangMeta(
      accentHint: 'indian',
      ttsLanguageCode: 'te-IN',
      espeak: 'te',
      coquiModel: 'tts_models/multilingual/multi-dataset/xtts_v2',
    ),
    'marathi': _LangMeta(
      accentHint: 'indian',
      ttsLanguageCode: 'mr-IN',
      espeak: 'mr',
      coquiModel: 'tts_models/multilingual/multi-dataset/xtts_v2',
    ),
    'gujarati': _LangMeta(
      accentHint: 'indian',
      ttsLanguageCode: 'gu-IN',
      espeak: 'gu',
      coquiModel: 'tts_models/multilingual/multi-dataset/xtts_v2',
    ),
    'kannada': _LangMeta(
      accentHint: 'indian',
      ttsLanguageCode: 'kn-IN',
      espeak: 'kn',
      coquiModel: 'tts_models/multilingual/multi-dataset/xtts_v2',
    ),
    'malayalam': _LangMeta(
      accentHint: 'indian',
      ttsLanguageCode: 'ml-IN',
      espeak: 'ml',
      coquiModel: 'tts_models/multilingual/multi-dataset/xtts_v2',
    ),
    // ── English variants ─────────────────────────────────────────────────
    'british': _LangMeta(
      accentHint: 'british',
      ttsLanguageCode: 'en-GB',
      espeak: 'en-gb',
      coquiModel: 'tts_models/en/ljspeech/vits',
    ),
    'american': _LangMeta(
      accentHint: 'american',
      ttsLanguageCode: 'en-US',
      espeak: 'en-us',
      coquiModel: 'tts_models/en/ljspeech/vits',
    ),
    'english': _LangMeta(
      accentHint: 'british',        // default English → British (matches prompt)
      ttsLanguageCode: 'en-GB',
      espeak: 'en-gb',
      coquiModel: 'tts_models/en/ljspeech/vits',
    ),
  };

  static const _defaultMeta = _LangMeta(
    accentHint: 'indian',
    ttsLanguageCode: 'hi-IN',
    espeak: 'hi',
    coquiModel: 'tts_models/hi/cv/vits',
  );

  /// Resolves full language metadata from a free-form language string
  /// (e.g. "Hindi", "Hinglish", "English") plus optional artist context.
  _LangMeta _resolveLangMeta({
    required String language,
    SongReference? referenceSong,
  }) {
    final key = language.trim().toLowerCase();

    // Direct lookup first
    if (_langTable.containsKey(key)) return _langTable[key]!;

    // Partial match (e.g. "Hindi dominant" → 'hindi')
    for (final entry in _langTable.entries) {
      if (key.contains(entry.key)) return entry.value;
    }

    // Fallback: sniff from artist name for English-dominant tracks
    final artist = (referenceSong?.artistName ?? '').toLowerCase();
    if (artist.isNotEmpty) {
      const britishMarkers = ['adele', 'ed sheeran', 'coldplay', 'dua lipa', 'sam smith', 'stormzy'];
      const americanMarkers = ['taylor swift', 'drake', 'kanye', 'weeknd', 'billie eilish', 'kendrick'];
      const southAsianMarkers = [
        'arijit', 'atif', 'shreya', 'sonu', 'sunidhi', 'diljit', 'badshah',
        'raftaar', 'neha', 'darshan', 'jubin', 'armaan', 'pritam', 'rahman',
        'kishore', 'lata', 'shankar', 'ehsaan', 'loy', 'ap dhillon',
        'karan aujla', 'gurnam', 'jassi', 'guru randhawa',
      ];
      if (southAsianMarkers.any(artist.contains)) return _langTable['hindi']!;
      if (britishMarkers.any(artist.contains)) return _langTable['british']!;
      if (americanMarkers.any(artist.contains)) return _langTable['american']!;
    }

    return _defaultMeta;
  }

  // ── Clone API call ────────────────────────────────────────────────────────

  Future<VoiceCloneResult> cloneVoice({
    required String voiceSamplePath,
    required String lyrics,
    String mood = '',
    String genre = '',
    String language = '',
    SongReference? referenceSong,
  }) async {
    final meta = _resolveLangMeta(language: language, referenceSong: referenceSong);

    final backendUrl = EnvConfig.voiceBackendUrl;
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$backendUrl/clone'),
    );

    // ── Core fields ──────────────────────────────────────────────────────
    request.fields['lyrics']            = lyrics;
    request.fields['mood']              = mood;
    request.fields['genre']             = genre;

    // ── Language / accent fields (ALL sent so backend can pick what it needs)
    request.fields['language']          = language;          // raw ("Hindi")
    request.fields['accent_hint']       = meta.accentHint;   // "hindi"
    request.fields['tts_language_code'] = meta.ttsLanguageCode; // "hi-IN"
    request.fields['espeak_voice']      = meta.espeak;       // "hi"
    request.fields['coqui_model_hint']  = meta.coquiModel;   // Coqui model path
    // Boolean convenience flag — backend can branch on this alone if preferred
    request.fields['is_hindi']          =
        (meta.ttsLanguageCode.startsWith('hi') ||
            meta.accentHint == 'hindi' ||
            meta.accentHint == 'urdu' ||
            meta.accentHint == 'punjabi' ||
            meta.accentHint == 'indian')
            ? '1'
            : '0';

    // ── Reference song fields ─────────────────────────────────────────────
    if (referenceSong != null) {
      request.fields['reference_track_title']  = referenceSong.trackName;
      request.fields['reference_artist_name']  = referenceSong.artistName;
      request.fields['reference_lyric_snippet']= referenceSong.lyricSnippet;
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

    final mixStatus =
        (response.headers['x-mongobox-mix-status'] ?? '').trim().toLowerCase();
    final mixLabel = response.headers['x-mongobox-mix-label']?.trim();

    return VoiceCloneResult(
      file: file,
      mixIncluded: mixStatus == 'mixed',
      mixLabel: mixLabel?.isNotEmpty == true ? mixLabel : null,
    );
  }

  void dispose() {
    _client.close();
  }
}