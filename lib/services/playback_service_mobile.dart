// Orchestrates: lyric line -> LRCLIB -> YouTube -> (videoId, startSeconds).

import 'lyrics_service.dart';
import 'youtube_mobile_service.dart';

class PlaybackResult {
  const PlaybackResult({
    required this.videoId,
    required this.startTimeSeconds,
    required this.trackName,
    required this.artistName,
  });

  final String videoId;
  final int startTimeSeconds;
  final String trackName;
  final String artistName;
}

class PlaybackServiceMobile {
  /// Helper: Find timestamp (in seconds) for a lyric line in LRC format
  int? _findTimestampForLine(String lrc, String searchLine) {
    final lines = lrc.split('\n');
    final normalizedSearch = searchLine.trim().toLowerCase();
    
    // Remove common punctuation for better matching
    final searchWords = normalizedSearch.replaceAll(RegExp(r'[^\w\s]'), '').split(' ');
    
    print('🔍 Searching for: "$normalizedSearch"');
    print('🔍 Search words: $searchWords');
    
    for (final line in lines) {
      final match = RegExp(r'\[(\d+):(\d+)(?:\.(\d+))?\](.*)').firstMatch(line);
      if (match != null) {
        final minutes = int.parse(match.group(1)!);
        final seconds = int.parse(match.group(2)!);
        final text = match.group(4)!.trim().toLowerCase();
        final timestamp = minutes * 60 + seconds;
        
        // Method 1: Exact contains match
        if (text.contains(normalizedSearch)) {
          print('✅ Exact match found at ${timestamp}s: "$text"');
          return timestamp;
        }
        
        // Method 2: Word-by-word matching (more flexible)
        final textWords = text.replaceAll(RegExp(r'[^\w\s]'), '').split(' ');
        int matchCount = 0;
        for (final word in searchWords) {
          if (word.length > 2 && textWords.contains(word)) {
            matchCount++;
          }
        }
        
        // If more than 60% of significant words match
        if (searchWords.isNotEmpty && matchCount >= (searchWords.length * 0.6).ceil()) {
          print('✅ Fuzzy match found at ${timestamp}s: "$text" (matched $matchCount/${searchWords.length} words)');
          return timestamp;
        }
      }
    }
    
    print('❌ No timestamp found for: "$normalizedSearch"');
    return null;
  }

  final LyricsService _lyrics = LyricsService();
  final YoutubeMobileService _youtube = YoutubeMobileService();

  /// Resolve a single line of lyrics to a YouTube video and start time.
  /// Returns null if no match or no video found.
  Future<PlaybackResult?> resolveAndSearch(String lyricLine) async {
    final trimmed = lyricLine.trim();
    if (trimmed.isEmpty) return null;

    print('🔍 Resolving line: "$trimmed"');

    // Step 1: Search for lyrics match
    final matches = await _lyrics.search(trimmed);
    
    if (matches.isNotEmpty) {
      print('✅ Found ${matches.length} lyrics matches');
      
      // Use first match; optionally later we can let user pick from list
      LyricsMatch? chosen = matches.first;
      
      // Fetch full lyrics if needed
      if (chosen.syncedLyrics == null || chosen.syncedLyrics!.isEmpty) {
        print('📥 Fetching full lyrics for: ${chosen.trackName} - ${chosen.artistName}');
        final full = await _lyrics.getById(chosen.id);
        chosen = full ?? chosen;
      }

      // Find timestamp for the specific line
      int startTime = 0;
      if (chosen.syncedLyrics != null && chosen.syncedLyrics!.isNotEmpty) {
        print('📝 Synced lyrics available, length: ${chosen.syncedLyrics!.length} characters');
        final time = _findTimestampForLine(chosen.syncedLyrics!, trimmed);
        if (time != null) {
          startTime = time;
          print('⏱️ Found timestamp: $startTime seconds');
        } else {
          print('⚠️ Could not find timestamp, will start from beginning');
        }
      } else {
        print('⚠️ No synced lyrics available');
      }

      // Search YouTube for the song
      final query = '${chosen.trackName} ${chosen.artistName}';
      print('🔍 Searching YouTube for: "$query"');
      
      final videoId = await _youtube.searchFirstVideoId(query);
      if (videoId == null || videoId.isEmpty) {
        print('❌ No YouTube video found');
        return null;
      }

      print('✅ Found YouTube video: $videoId');
      
      return PlaybackResult(
        videoId: videoId,
        startTimeSeconds: startTime,
        trackName: chosen.trackName,
        artistName: chosen.artistName,
      );
    } else {
      // Fallback: search YouTube directly with the lyric line
      print('⚠️ No lyrics matches found, falling back to direct YouTube search');
      print('🔍 Searching YouTube for: "$trimmed"');
      
      final youtubeResults = await _youtube.searchSongs(trimmed);
      if (youtubeResults.isNotEmpty) {
        print('✅ Found ${youtubeResults.length} YouTube results');
        
        final first = youtubeResults.first;
        final trackName = first['title'] ?? '';
        final artistName = first['artist'] ?? '';
        final videoId = first['id'];
        
        print('📺 Top result: "$trackName" by "$artistName" (ID: $videoId)');

        // Try to get lyrics for the found song
        int startTime = 0;
        final lyricsMatches = await _lyrics.search('$trackName $artistName');
        
        if (lyricsMatches.isNotEmpty) {
          print('✅ Found lyrics for YouTube result');
          final match = lyricsMatches.first;
          String? syncedLyrics = match.syncedLyrics;
          
          if (syncedLyrics == null || syncedLyrics.isEmpty) {
            print('📥 Fetching full lyrics for: ${match.trackName} - ${match.artistName}');
            final full = await _lyrics.getById(match.id);
            syncedLyrics = full?.syncedLyrics;
          }
          
          if (syncedLyrics != null && syncedLyrics.isNotEmpty) {
            print('📝 Synced lyrics available, searching for timestamp');
            // Find timestamp for searched line - using the class-level helper
            final time = _findTimestampForLine(syncedLyrics, trimmed);
            if (time != null) {
              startTime = time;
              print('⏱️ Found timestamp: $startTime seconds');
            }
          }
        } else {
          print('⚠️ No lyrics found for YouTube result');
        }
        
        return PlaybackResult(
          videoId: videoId,
          startTimeSeconds: startTime,
          trackName: trackName,
          artistName: artistName,
        );
      } else {
        print('❌ No YouTube results found');
        return null;
      }
    }
  }
}