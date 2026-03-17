// Grok-powered search refinement service
// Enhances search results by using xAI Grok API for intelligent re-ranking and filtering

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'env_config.dart';
import 'lightweight_search_service.dart';

class GrokSearchRefinement {
  final http.Client _client = http.Client();
  static const String _grokApiUrl = 'https://api.x.ai/v1/chat/completions';

  // Cache refined results to avoid redundant API calls
  final Map<String, List<LightweightSearchResult>> _refinementCache = {};

  /// Refine search results using Grok API for better ranking and filtering
  ///
  /// - Keeps original logic intact (fallback if Grok fails)
  /// - Uses Grok to analyze relevance quickly
  /// - Re-ranks results based on semantic understanding
  /// - Returns original results if API fails or is rate limited
  Future<List<LightweightSearchResult>> refineSearchResults(
    String userQuery,
    List<LightweightSearchResult> originalResults,
  ) async {
    if (originalResults.isEmpty) return originalResults;

    final cacheKey = '${userQuery.toLowerCase()}::refine';

    // Return cached refinements if available
    if (_refinementCache.containsKey(cacheKey)) {
      return _refinementCache[cacheKey]!;
    }

    try {
      // Quick timeout - if Grok is slow, fallback to original results
      final refined = await _getRefinedResults(userQuery, originalResults)
          .timeout(const Duration(seconds: 4), onTimeout: () => originalResults);

      // Cache the refined results
      _refinementCache[cacheKey] = refined;
      return refined;
    } catch (e) {
      // Graceful fallback on any error
      print('⚠️ Grok refinement failed, using original results: $e');
      return originalResults;
    }
  }

  /// Use Grok to analyze search results and re-rank them
  Future<List<LightweightSearchResult>> _getRefinedResults(
    String userQuery,
    List<LightweightSearchResult> results,
  ) async {
    final grokApiKey = EnvConfig.grokApiKey;
    if (grokApiKey.isEmpty) {
      print('⚠️ Grok API key not configured, skipping refinement');
      return results;
    }

    // Prepare results summary for Grok analysis
    final resultsSummary = results
        .asMap()
        .entries
        .map((e) => '${e.key + 1}. "${e.value.trackName}" by ${e.value.artistName} '
            '(confidence: ${(e.value.confidence * 100).toStringAsFixed(0)}%)')
        .join('\n');

    final prompt = '''User is searching for: "$userQuery"

Here are the current search results ranked by confidence:
$resultsSummary

Based on the user's query, identify which songs are most relevant and should be prioritized:
1. Check if the song title/artist matches the query semantically
2. Consider if it's likely to contain the exact lyrics the user mentioned
3. Filter out unlikely matches (remixes, karaoke versions, covers if user asked for original)
4. Return the best matches first

Respond with a JSON array of song indices (1-based) in order of relevance, like: [1, 3, 2]
Only return the JSON array, no other text.''';

    try {
      final response = await _client.post(
        Uri.parse(_grokApiUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $grokApiKey',
        },
        body: jsonEncode({
          'model': 'grok-beta',
          'messages': [
            {
              'role': 'user',
              'content': prompt,
            }
          ],
          'temperature': 0.3, // Low temperature for consistent ranking
        }),
      );

      if (response.statusCode != 200) {
        print('⚠️ Grok API error (${response.statusCode}): ${response.body}');
        return results;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>?;
      final message = data?['choices']?[0]?['message']?['content'] as String?;

      if (message == null) {
        print('⚠️ Invalid Grok response format');
        return results;
      }

      // Parse the JSON array of indices from Grok
      final cleanedMessage = message.trim();
      final parsed = jsonDecode(cleanedMessage);

      if (parsed is! List) {
        print('⚠️ Grok returned unexpected format: $cleanedMessage');
        return results;
      }

      // Re-order results based on Grok's ranking
      final indices = parsed.cast<int>();
      final reordered = <LightweightSearchResult>[];

      for (final idx in indices) {
        // Guard against out-of-bounds indices
        if (idx > 0 && idx <= results.length) {
          reordered.add(results[idx - 1]); // Convert 1-based to 0-based
        }
      }

      // Add any remaining results that weren't ranked by Grok
      final includedIndices = indices.whereType<int>().toSet();
      for (int i = 0; i < results.length; i++) {
        if (!includedIndices.contains(i + 1)) {
          reordered.add(results[i]);
        }
      }

      print('✅ Grok refined ${results.length} results → ${reordered.length} ranked');
      return reordered.take(results.length).toList(); // Maintain original length
    } catch (e) {
      print('⚠️ Grok parsing error: $e');
      return results;
    }
  }

  /// Analyze a search query to extract key terms for better search
  /// Optionally can be used for query expansion before search
  Future<String> analyzeQueryForExpansion(String userQuery) async {
    final grokApiKey = EnvConfig.grokApiKey;
    if (grokApiKey.isEmpty) return userQuery;

    try {
      final response = await _client.post(
        Uri.parse(_grokApiUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $grokApiKey',
        },
        body: jsonEncode({
          'model': 'grok-beta',
          'messages': [
            {
              'role': 'user',
              'content': '''The user is searching for a song by providing a lyric line: "$userQuery"

Extract potential song title, artist name, or significant keywords from this lyric.
Respond with a JSON object: {"keywords": ["keyword1", "keyword2"], "likely_title": "if detectable"}
Only return the JSON, nothing else.''',
            }
          ],
          'temperature': 0.3,
        }),
      )
      .timeout(const Duration(seconds: 2));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>?;
        final message = data?['choices']?[0]?['message']?['content'] as String?;
        if (message != null) {
          print('✅ Grok query analysis: $message');
          return message;
        }
      }
      return userQuery;
    } catch (e) {
      print('⚠️ Query expansion failed: $e');
      return userQuery;
    }
  }

  /// Clear cache to free memory
  void clearCache() {
    _refinementCache.clear();
  }

  /// Get cache statistics
  Map<String, int> getCacheStats() {
    return {'refinementCache': _refinementCache.length};
  }
}
