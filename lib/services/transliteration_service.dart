import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Utility service for transliterating text from various scripts to Roman/Latin script.
/// Supports Hindi, Urdu, Arabic, Bengali, Tamil, Telugu, and other non-Latin scripts.
/// All output is in readable Roman/Hinglish format.
class TransliterationService {
  static final TransliterationService _instance =
      TransliterationService._internal();
  factory TransliterationService() => _instance;
  TransliterationService._internal();

  final Map<String, String> _cache = {};
  String? _apiKey;

  /// Get the API key from environment
  String? get _groqApiKey {
    if (_apiKey != null) return _apiKey;
    try {
      // Prefer flutter_dotenv if available (matches the rest of the app)
      final dotEnvKey = dotenv.env['GROQ_API_KEY'];
      if (dotEnvKey != null && dotEnvKey.isNotEmpty) {
        _apiKey = dotEnvKey;
        return _apiKey;
      }

      // Try to load from environment
      _apiKey = const String.fromEnvironment('GROQ_API_KEY');
      if (_apiKey == null || _apiKey!.isEmpty) {
        // Fallback: try to load from dart:io (for non-web)
        if (!kIsWeb) {
          // Lazy import to avoid web issues
          // ignore: avoid_dynamic_calls
          _apiKey = _loadFromEnv();
        }
      }
    } catch (_) {
      // Ignore errors
    }
    return _apiKey;
  }

  dynamic _loadFromEnv() {
    try {
      // Dynamic import for flutter_dotenv
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Check if text contains non-Latin script characters
  bool needsTransliteration(String text) {
    // Check for common non-Latin script ranges
    final nonLatinRanges = [
      RegExp(r'[\u0900-\u097F]'), // Devanagari (Hindi, Sanskrit)
      RegExp(r'[\u0600-\u06FF]'), // Arabic (Urdu, Arabic, Persian)
      RegExp(r'[\u0980-\u09FF]'), // Bengali
      RegExp(r'[\u0B80-\u0BFF]'), // Tamil
      RegExp(r'[\u0C00-\u0C7F]'), // Telugu
      RegExp(r'[\u0A00-\u0A7F]'), // Gurmukhi (Punjabi)
      RegExp(r'[\u0C80-\u0CFF]'), // Kannada
      RegExp(r'[\u0D00-\u0D7F]'), // Malayalam
      RegExp(r'[\u0E00-\u0E7F]'), // Thai
      RegExp(r'[\u3040-\u309F]'), // Hiragana (Japanese)
      RegExp(r'[\u30A0-\u30FF]'), // Katakana (Japanese)
      RegExp(r'[\u4E00-\u9FFF]'), // CJK (Chinese, Japanese Kanji)
      RegExp(r'[\uAC00-\uD7AF]'), // Hangul (Korean)
      RegExp(r'[\u0400-\u04FF]'), // Cyrillic (Russian)
      RegExp(r'[\u0370-\u03FF]'), // Greek
      RegExp(r'[\u0590-\u05FF]'), // Hebrew
    ];

    return nonLatinRanges.any((regex) => regex.hasMatch(text));
  }

  /// Transliterate text to Roman/Latin script using Groq AI
  /// Returns the original text if transliteration fails or if text is already in Latin script
  Future<String> transliterate(String text, String language) async {
    if (!needsTransliteration(text)) {
      return text;
    }

    final cacheKey = '${language}:${text.hashCode}';
    if (_cache.containsKey(cacheKey)) {
      return _cache[cacheKey]!;
    }

    final apiKey = _groqApiKey;
    if (apiKey == null || apiKey.isEmpty) {
      debugPrint('TransliterationService: No API key available');
      return text; // Return original if no API key
    }

    try {
      final response = await http
          .post(
            Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: json.encode({
              'model': 'llama-3.3-70b-versatile',
              'max_tokens': 500,
              'temperature': 0.1,
              'messages': [
                {
                  'role': 'system',
                  'content':
                      'You are a transliterator. Convert $language script text into Roman/Latin script phonetically. '
                      'For Hindi/Urdu, use common Hinglish conventions (e.g., "dil" not "heart", "tum" not "you"). '
                      'For other languages, use standard phonetic romanization. '
                      'Output ONLY the transliterated text - no explanations, no quotes, no markdown.',
                },
                {
                  'role': 'user',
                  'content': text,
                },
              ],
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final transliterated =
            (data['choices'][0]['message']['content'] as String).trim();
        
        if (transliterated.isNotEmpty) {
          _cache[cacheKey] = transliterated;
          return transliterated;
        }
      }

      debugPrint(
          'TransliterationService: API call failed with status ${response.statusCode}');
    } catch (e) {
      debugPrint('TransliterationService: Error - $e');
    }

    // Return original text if transliteration fails
    return text;
  }

  /// Transliterate multiple lines (optimized for lyrics)
  Future<String> transliterateLyrics(String lyrics, String language) async {
    if (!needsTransliteration(lyrics)) {
      return lyrics;
    }

    final cacheKey = 'lyrics:${language}:${lyrics.hashCode}';
    if (_cache.containsKey(cacheKey)) {
      return _cache[cacheKey]!;
    }

    final apiKey = _groqApiKey;
    if (apiKey == null || apiKey.isEmpty) {
      return lyrics;
    }

    try {
      final response = await http
          .post(
            Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: json.encode({
              'model': 'llama-3.3-70b-versatile',
              'max_tokens': 1500,
              'temperature': 0.1,
              'messages': [
                {
                  'role': 'system',
                  'content':
                      'You are a transliterator. Convert $language script lyrics into Roman/Latin script phonetically. '
                      'Use Hinglish-style for Hindi/Urdu (e.g., "dil", "ishq", "raat"). '
                      'For other languages, use familiar phonetic romanization. '
                      'PRESERVE ALL section headers like [Verse 1], [Chorus], [Bridge], [Outro] exactly as-is. '
                      'Keep blank lines between sections. '
                      'Output ONLY the transliterated lyrics - no explanations, no JSON, no markdown.',
                },
                {
                  'role': 'user',
                  'content': lyrics,
                },
              ],
            }),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final transliterated =
            (data['choices'][0]['message']['content'] as String).trim();
        
        if (transliterated.isNotEmpty) {
          _cache[cacheKey] = transliterated;
          return transliterated;
        }
      }

      debugPrint(
          'TransliterationService: Lyrics API call failed with status ${response.statusCode}');
    } catch (e) {
      debugPrint('TransliterationService: Lyrics error - $e');
    }

    return lyrics;
  }

  /// Clear the cache (useful for testing or memory management)
  void clearCache() {
    _cache.clear();
  }
}
