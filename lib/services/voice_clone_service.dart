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

// ── Language metadata sent to the Python backend ──────────────────────────────
class _LangMeta {
  const _LangMeta({
    required this.accentHint,
    required this.ttsLanguageCode,
    required this.espeak,
    required this.coquiModel,
    required this.isHindi,
  });
  final String accentHint;
  final String ttsLanguageCode;
  final String espeak;
  final String coquiModel;

  /// True for any South-Asian / Hindi-family language where the backend
  /// should run the Hinglish → Devanagari transliteration pipeline.
  final bool isHindi;
}

class VoiceCloneService {
  VoiceCloneService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  // ── Language table ──────────────────────────────────────────────────────────
  static const _langTable = <String, _LangMeta>{
    // ── South Asian (all flagged isHindi=true so backend transliterates) ──
    'hindi': _LangMeta(
      accentHint: 'hindi',
      ttsLanguageCode: 'hi-IN',
      espeak: 'hi',
      coquiModel: 'tts_models/hi/cv/vits',
      isHindi: true,
    ),
    'hinglish': _LangMeta(
      accentHint: 'hindi',
      ttsLanguageCode: 'hi-IN',
      espeak: 'hi',
      coquiModel: 'tts_models/hi/cv/vits',
      isHindi: true, // ← was missing / ambiguous before
    ),
    'urdu': _LangMeta(
      accentHint: 'urdu',
      ttsLanguageCode: 'ur-PK',
      espeak: 'ur',
      coquiModel: 'tts_models/multilingual/multi-dataset/xtts_v2',
      isHindi: true,
    ),
    'punjabi': _LangMeta(
      accentHint: 'punjabi',
      ttsLanguageCode: 'pa-IN',
      espeak: 'pa',
      coquiModel: 'tts_models/multilingual/multi-dataset/xtts_v2',
      isHindi: true,
    ),
    'bengali': _LangMeta(
      accentHint: 'indian',
      ttsLanguageCode: 'bn-IN',
      espeak: 'bn',
      coquiModel: 'tts_models/multilingual/multi-dataset/xtts_v2',
      isHindi: true,
    ),
    'tamil': _LangMeta(
      accentHint: 'indian',
      ttsLanguageCode: 'ta-IN',
      espeak: 'ta',
      coquiModel: 'tts_models/multilingual/multi-dataset/xtts_v2',
      isHindi: true,
    ),
    'telugu': _LangMeta(
      accentHint: 'indian',
      ttsLanguageCode: 'te-IN',
      espeak: 'te',
      coquiModel: 'tts_models/multilingual/multi-dataset/xtts_v2',
      isHindi: true,
    ),
    'marathi': _LangMeta(
      accentHint: 'indian',
      ttsLanguageCode: 'mr-IN',
      espeak: 'mr',
      coquiModel: 'tts_models/multilingual/multi-dataset/xtts_v2',
      isHindi: true,
    ),
    'gujarati': _LangMeta(
      accentHint: 'indian',
      ttsLanguageCode: 'gu-IN',
      espeak: 'gu',
      coquiModel: 'tts_models/multilingual/multi-dataset/xtts_v2',
      isHindi: true,
    ),
    'kannada': _LangMeta(
      accentHint: 'indian',
      ttsLanguageCode: 'kn-IN',
      espeak: 'kn',
      coquiModel: 'tts_models/multilingual/multi-dataset/xtts_v2',
      isHindi: true,
    ),
    'malayalam': _LangMeta(
      accentHint: 'indian',
      ttsLanguageCode: 'ml-IN',
      espeak: 'ml',
      coquiModel: 'tts_models/multilingual/multi-dataset/xtts_v2',
      isHindi: true,
    ),
    // ── English variants ─────────────────────────────────────────────────
    'british': _LangMeta(
      accentHint: 'british',
      ttsLanguageCode: 'en-GB',
      espeak: 'en-gb',
      coquiModel: 'tts_models/en/ljspeech/vits',
      isHindi: false,
    ),
    'american': _LangMeta(
      accentHint: 'american',
      ttsLanguageCode: 'en-US',
      espeak: 'en-us',
      coquiModel: 'tts_models/en/ljspeech/vits',
      isHindi: false,
    ),
    'english': _LangMeta(
      accentHint: 'british',
      ttsLanguageCode: 'en-GB',
      espeak: 'en-gb',
      coquiModel: 'tts_models/en/ljspeech/vits',
      isHindi: false,
    ),
  };

  static const _defaultMeta = _LangMeta(
    accentHint: 'indian',
    ttsLanguageCode: 'hi-IN',
    espeak: 'hi',
    coquiModel: 'tts_models/hi/cv/vits',
    isHindi: true,
  );

  // ── Language resolution ──────────────────────────────────────────────────

  /// Normalises free-form language strings like "Hindi dominant", "Hinglish",
  /// "Hindi" etc. into a lookup key.
  static String _normalise(String language) {
    final lower = language.trim().toLowerCase();
    // Strip common suffixes that come from GenerateSongScreen
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

    // Direct lookup
    if (_langTable.containsKey(key)) return _langTable[key]!;

    // Partial-match (e.g. "hindi dominant" normalises to "hindi")
    for (final entry in _langTable.entries) {
      if (key.contains(entry.key)) return entry.value;
    }

    // Sniff from artist for English-dominant tracks
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

  // ── Clone API call ────────────────────────────────────────────────────────

  Future<VoiceCloneResult> cloneVoice({
    required String voiceSamplePath,
    required String lyrics,
    required String requestId,
    String mood = '',
    String genre = '',
    String language = '',
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

    // ── Core fields ──────────────────────────────────────────────────────
    request.fields['request_id'] = requestId;
    request.fields['lyrics'] = lyrics;
    request.fields['mood'] = mood;
    request.fields['genre'] = genre;

    // ── Language / accent fields ─────────────────────────────────────────
    // Send the NORMALISED key (e.g. "hindi", "english") not the raw string
    // ("Hindi dominant") so the backend lookup is reliable.
    request.fields['language'] = _normalise(language);
    request.fields['accent_hint'] = meta.accentHint;
    request.fields['tts_language_code'] = meta.ttsLanguageCode;
    request.fields['espeak_voice'] = meta.espeak;
    request.fields['coqui_model_hint'] = meta.coquiModel;

    // This is the critical flag — if true, backend will transliterate
    // Hinglish (Roman script) → Devanagari before synthesis so XTTS
    // uses its Hindi phoneme tokenizer instead of the English one.
    request.fields['is_hindi'] = meta.isHindi ? '1' : '0';

    // ── Reference song fields ─────────────────────────────────────────────
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
      backgroundMusicLabel:
          musicLabel?.isNotEmpty == true ? musicLabel : null,
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
