// LRCLIB API client: search by lyric line, parse synced lyrics for timestamp.
// + Claude AI: generate unique personal song lyrics from user's listening history.

import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'env_config.dart';

const _baseUrl = 'https://lrclib.net';
const _defaultHeaders = {'User-Agent': 'MongoBox LyricPlay/1.0'};

/// One match from LRCLIB search (track + optional synced lyrics).
class LyricsMatch {
  const LyricsMatch({
    required this.id,
    required this.trackName,
    required this.artistName,
    required this.durationSeconds,
    this.syncedLyrics,
  });

  final int id;
  final String trackName;
  final String artistName;
  final int durationSeconds;
  final String? syncedLyrics;
}

/// Result when we resolve a lyric line to a song and a start time (seconds).
class LyricPlayResult {
  const LyricPlayResult({
    required this.trackName,
    required this.artistName,
    required this.durationSeconds,
    required this.startTimeSeconds,
    this.syncedLyrics,
  });

  final String trackName;
  final String artistName;
  final int durationSeconds;
  final int startTimeSeconds;
  final String? syncedLyrics;
}

/// Result from AI personal song generation.
class PersonalSongResult {
  const PersonalSongResult({
    required this.songTitle,
    required this.lyrics,
    required this.inferredMood,
    required this.inferredGenre,
  });

  final String songTitle;     // e.g. "Midnight Signal"
  final String lyrics;        // full [Verse]/[Chorus]/[Bridge] text
  final String inferredMood;  // e.g. "melancholic"
  final String inferredGenre; // e.g. "Indie pop / Synth-pop"

  String get fullText => '"$songTitle"\n\n$lyrics';
}

class LyricsService {
  final http.Client _client = http.Client();
  final Map<String, List<LyricsMatch>> _searchCache = {};
  final Map<int, LyricsMatch?> _idCache = {};

  String _readAnthropicKey() {
    // Centralized key loading + sanitization.
    return EnvConfig.anthropicApiKey;
  }

  String _anthropicErrorFor(http.Response response) {
    // Prefer the server-provided message, but keep it short and user-actionable.
    try {
      final data = json.decode(response.body) as Map<String, dynamic>;
      final err = data['error'];
      if (err is Map<String, dynamic>) {
        final message = (err['message'] as String?)?.trim();
        final type = (err['type'] as String?)?.trim();
        if (message != null && message.isNotEmpty) {
          return message;
        }
        if (type != null && type.isNotEmpty) {
          return type;
        }
      }
    } catch (_) {
      // ignore parse failures; we fall back below
    }
    return 'Request failed (${response.statusCode}).';
  }

  // ───────────────────────────────────────────────────────────────────────────
  // AI PERSONAL SONG GENERATION
  // Reads user's RecentTrack history → infers taste → writes original lyrics
  // ───────────────────────────────────────────────────────────────────────────

  /// Generates a unique song based purely on the user's personal listening history.
  ///
  /// Usage:
  /// ```dart
  /// final suggestions = await LocalSuggestionsService.create();
  /// final tracks = suggestions.getRecentTracks();
  /// final song = await lyricsService.generatePersonalSong(tracks);
  /// print(song?.songTitle);  // "Midnight Signal"
  /// print(song?.lyrics);     // full structured lyrics
  /// ```
  Future<PersonalSongResult?> generatePersonalSong(
    List<dynamic> recentTracks, {
    int maxTracks = 20,
  }) async {
    final apiKey = _readAnthropicKey();

    final trackLines = <String>[];
    for (final t in recentTracks.take(maxTracks)) {
      try {
        final name = (t as dynamic).trackName as String? ?? '';
        final artist = (t as dynamic).artistName as String? ?? '';
        if (name.isNotEmpty) {
          trackLines.add(artist.isNotEmpty ? '$name – $artist' : name);
        }
      } catch (_) {
        continue;
      }
    }

    if (trackLines.isEmpty) return null;

    final prompt = '''
You are a songwriter. Study the listening history below to understand this person's musical taste — their preferred genres, moods, lyrical themes, and energy levels.

Listening history:
${trackLines.map((t) => '• $t').join('\n')}

Your task: Write a brand-new, completely original song that fits naturally into their taste.

Rules:
- Do NOT reference, mention, or quote any of the songs or artists above.
- Write as if you are a new artist making music in the same world as what they love.
- Structure: [Verse 1], [Chorus], [Verse 2], [Bridge], [Outro]
- Make lyrics specific, emotional, and vivid — no generic filler lines.
- Title should be 2–4 words, evocative, not cliché.

Respond ONLY with this exact JSON (no markdown, no backticks, no extra text):
{
  "title": "Song Title Here",
  "mood": "single word",
  "genre": "Genre / Sub-genre",
  "lyrics": "[Verse 1]\\nline\\nline\\n\\n[Chorus]\\nline\\nline\\n\\n[Verse 2]\\nline\\nline\\n\\n[Bridge]\\nline\\nline\\n\\n[Outro]\\nline\\nline"
}''';

    try {
      final response = await _client
          .post(
            Uri.parse('https://api.anthropic.com/v1/messages'),
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': apiKey,
              'anthropic-version': '2023-06-01',
            },
            body: json.encode({
              'model': 'claude-sonnet-4-20250514',
              'max_tokens': 1024,
              'messages': [
                {'role': 'user', 'content': prompt},
              ],
            }),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        if (response.statusCode == 401 || response.statusCode == 403) {
          throw Exception(
            '[LyricQsk] Claude authentication failed. '
            'Check ANTHROPIC_API_KEY in your .env (or --dart-define).',
          );
        }
        throw Exception(
          '[LyricQsk] Claude API error ${response.statusCode}: ${_anthropicErrorFor(response)}',
        );
      }

      final data = json.decode(response.body) as Map<String, dynamic>;

      final rawText = (data['content'] as List<dynamic>?)
              ?.whereType<Map<String, dynamic>>()
              .where((b) => b['type'] == 'text')
              .map((b) => b['text'] as String)
              .join('') ??
          '';

      final cleanJson = rawText
          .replaceAll(RegExp(r'```json\s*'), '')
          .replaceAll(RegExp(r'```\s*'), '')
          .trim();

      final parsed = json.decode(cleanJson) as Map<String, dynamic>;

      return PersonalSongResult(
        songTitle: (parsed['title'] as String?) ?? 'Untitled',
        lyrics: (parsed['lyrics'] as String?) ?? '',
        inferredMood: (parsed['mood'] as String?) ?? '',
        inferredGenre: (parsed['genre'] as String?) ?? '',
      );
    } on FormatException catch (e) {
      throw Exception('[LyricQsk] Failed to parse Claude response: $e');
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // EXISTING LRCLIB METHODS — completely unchanged below
  // ───────────────────────────────────────────────────────────────────────────

  /// Search LRCLIB by keyword (e.g. a line of lyrics). Returns up to 20 matches.
  Future<List<LyricsMatch>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    final cacheKey = q.toLowerCase();
    final cached = _searchCache[cacheKey];
    if (cached != null) return cached;

    final uri = Uri.parse('$_baseUrl/api/search').replace(
      queryParameters: {'q': q},
    );

    try {
      final response = await _client
          .get(uri, headers: _defaultHeaders)
          .timeout(const Duration(seconds: 6));

      if (response.statusCode != 200) {
        _searchCache[cacheKey] = const [];
        return const [];
      }

      final list = json.decode(response.body) as List<dynamic>?;
      if (list == null || list.isEmpty) {
        _searchCache[cacheKey] = const [];
        return const [];
      }

      final parsed = list.map((e) {
        final m = e as Map<String, dynamic>;
        return LyricsMatch(
          id: (m['id'] as num?)?.toInt() ?? 0,
          trackName: (m['trackName'] as String?) ?? '',
          artistName: (m['artistName'] as String?) ?? '',
          durationSeconds: (m['duration'] as num?)?.toInt() ?? 0,
          syncedLyrics: m['syncedLyrics'] as String?,
        );
      }).toList();

      _searchCache[cacheKey] = parsed;
      return parsed;
    } catch (_) {
      _searchCache[cacheKey] = const [];
      return const [];
    }
  }

  /// Get full lyrics by LRCLIB id (e.g. when search didn't include syncedLyrics).
  Future<LyricsMatch?> getById(int id) async {
    final cached = _idCache[id];
    if (_idCache.containsKey(id)) return cached;

    final uri = Uri.parse('$_baseUrl/api/get/$id');

    try {
      final response = await _client
          .get(uri, headers: _defaultHeaders)
          .timeout(const Duration(seconds: 6));

      if (response.statusCode != 200) {
        _idCache[id] = null;
        return null;
      }

      final m = json.decode(response.body) as Map<String, dynamic>?;
      if (m == null) {
        _idCache[id] = null;
        return null;
      }

      final parsed = LyricsMatch(
        id: (m['id'] as num?)?.toInt() ?? id,
        trackName: (m['trackName'] as String?) ?? '',
        artistName: (m['artistName'] as String?) ?? '',
        durationSeconds: (m['duration'] as num?)?.toInt() ?? 0,
        syncedLyrics: m['syncedLyrics'] as String?,
      );

      _idCache[id] = parsed;
      return parsed;
    } catch (_) {
      _idCache[id] = null;
      return null;
    }
  }

  /// One-edit and typo-style alternates to help LRCLIB when speech-to-text or typing is wrong.
  static List<String> typoExpandedQueries(String line, {int maxVariants = 6}) {
    final normalized = line.trim().replaceAll(RegExp(r'[\s]+'), ' ').trim();
    if (normalized.isEmpty) return const [];

    final words = normalized.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final out = <String>[];
    final seen = <String>{normalized.toLowerCase()};

    void add(String s) {
      final t = s.trim();
      if (t.isEmpty) return;
      final k = t.toLowerCase();
      if (!seen.add(k)) return;
      out.add(t);
    }

    // One deletion in the middle of long tokens (common STT glitch).
    for (var wi = 0; wi < words.length; wi++) {
      final w = words[wi];
      if (w.length < 6) continue;
      final idx = w.length ~/ 2;
      final oneLess = w.substring(0, idx) + w.substring(idx + 1);
      if (oneLess.length < 3) continue;
      add([...words.sublist(0, wi), oneLess, ...words.sublist(wi + 1)].join(' '));
      if (out.length >= maxVariants) return out;
    }

    // Transposition of adjacent characters in the first long token.
    for (var wi = 0; wi < words.length; wi++) {
      final w = words[wi];
      if (w.length < 4) continue;
      final i = w.length ~/ 2;
      if (i + 1 >= w.length) continue;
      final swapped = w.substring(0, i) + w[i + 1] + w[i] + w.substring(i + 2);
      add([...words.sublist(0, wi), swapped, ...words.sublist(wi + 1)].join(' '));
      if (out.length >= maxVariants) return out;
      break;
    }

    // Single QWERTY-neighbor substitution in the first eligible token.
    for (var wi = 0; wi < words.length; wi++) {
      final w = words[wi];
      if (w.length < 5) continue;
      final i = w.length ~/ 2;
      final ch = w[i];
      final lower = ch.toLowerCase();
      final alt = _keyboardNeighborChar(lower);
      if (alt == null) continue;
      final nw = w.replaceRange(i, i + 1, ch == lower ? alt : alt.toUpperCase());
      add([...words.sublist(0, wi), nw, ...words.sublist(wi + 1)].join(' '));
      if (out.length >= maxVariants) return out;
      break;
    }

    // Collapse accidental double letters ("committ" → "comitt" path).
    for (var wi = 0; wi < words.length; wi++) {
      final w = words[wi];
      for (var i = 0; i < w.length - 1; i++) {
        if (w[i].toLowerCase() == w[i + 1].toLowerCase()) {
          final collapsed = w.substring(0, i) + w.substring(i + 1);
          add([...words.sublist(0, wi), collapsed, ...words.sublist(wi + 1)].join(' '));
          if (out.length >= maxVariants) return out;
          break;
        }
      }
    }

    // Duplicate a character once (helps when user omits a double letter).
    for (var wi = 0; wi < words.length; wi++) {
      final w = words[wi];
      if (w.length < 6) continue;
      final i = w.length ~/ 2;
      final c = w[i];
      final doubled = w.substring(0, i) + c + c + w.substring(i + 1);
      add([...words.sublist(0, wi), doubled, ...words.sublist(wi + 1)].join(' '));
      if (out.length >= maxVariants) return out;
      break;
    }

    return out;
  }

  static String? _keyboardNeighborChar(String ch) {
    const neighbors = {
      'a': 's',
      'b': 'v',
      'c': 'x',
      'd': 's',
      'e': 'r',
      'f': 'd',
      'g': 'f',
      'h': 'j',
      'i': 'o',
      'j': 'k',
      'k': 'j',
      'l': 'k',
      'm': 'n',
      'n': 'm',
      'o': 'p',
      'p': 'o',
      'q': 'w',
      'r': 't',
      's': 'a',
      't': 'y',
      'u': 'y',
      'v': 'c',
      'w': 'q',
      'x': 'z',
      'y': 'u',
      'z': 'x',
    };
    return neighbors[ch];
  }

  /// Prioritized LRCLIB search strings for one user line (rap/long lines get extra windows).
  static List<String> lyricSearchQueryVariants(String line, {int maxQueries = 22}) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return const [];

    final normalized = trimmed
        .replaceAll(RegExp(r'[\s]+'), ' ')
        .replaceAll(RegExp(r'[\"]|[“”‘’]'), '')
        .trim();

    final words = normalized.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final out = <String>[];
    final seen = <String>{};

    void add(String? s) {
      if (s == null) return;
      final t = s.trim();
      if (t.isEmpty) return;
      final k = t.toLowerCase();
      if (!seen.add(k)) return;
      out.add(t);
    }

    add(trimmed);
    add(normalized);

    if (words.length >= 5) {
      add(words.take(8).join(' '));
    }
    if (words.length > 10) {
      add(words.skip((words.length / 3).floor()).take(8).join(' '));
      add(words.skip(words.length - 8).join(' '));
    }

    if (words.length >= 12) {
      for (var i = 0; i + 8 <= words.length && i <= 28; i += 4) {
        add(words.skip(i).take(8).join(' '));
      }
    }

    final distinct = _distinctiveWords(words, maxWords: 8);
    if (distinct.length >= 4) {
      add(distinct.join(' '));
    }

    for (final typo in typoExpandedQueries(normalized)) {
      add(typo);
    }

    const lrclibSuffixes = [
      'lyrics',
      'song lyrics',
      'lyric video',
      'official lyrics',
      'hindi lyrics',
      'english translation',
      'translated lyrics',
      'गीत',
      'गाना',
      'letra',
      'paroles',
      'testo',
      '가사',
      '歌詞',
    ];
    for (final h in lrclibSuffixes) {
      add('$normalized $h');
    }

    return out.take(math.max(1, maxQueries)).toList();
  }

  /// YouTube search query variants when resolving a lyric line (LRCLIB miss / rap depth).
  static List<String> youtubeLyricSearchVariants(String line, {int maxQueries = 32}) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return const [];

    final words = trimmed.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final shortHead = words.take(8).join(' ');
    final midWindow = words.length > 10
        ? words.skip((words.length / 3).floor()).take(8).join(' ')
        : '';
    final tailWindow = words.length > 10 ? words.skip(words.length - 8).join(' ') : '';

    final out = <String>[];
    final seen = <String>{};

    void add(String? s) {
      if (s == null) return;
      final t = s.trim();
      if (t.isEmpty) return;
      final k = t.toLowerCase();
      if (!seen.add(k)) return;
      out.add(t);
    }

    add('"$trimmed" lyrics');
    add('$trimmed lyrics');
    add(trimmed);
    add('$trimmed song');
    add('$trimmed full song');

    const ytHints = [
      'lyrics',
      'lyric video',
      'song lyrics',
      'official lyrics',
      'full song',
      'hindi lyrics',
      'english translation',
      'translated lyrics',
      'गीत',
      'गाना',
      'letra',
      'paroles',
      'testo',
      '가사',
      '歌詞',
    ];
    for (final h in ytHints) {
      add('$trimmed $h');
    }

    if (shortHead.isNotEmpty && shortHead != trimmed) {
      add('$shortHead lyrics');
      for (final h in ytHints) {
        add('$shortHead $h');
      }
    }
    if (midWindow.isNotEmpty && midWindow != trimmed) {
      add('$midWindow lyrics');
      add('$midWindow song');
    }
    if (tailWindow.isNotEmpty && tailWindow != trimmed) {
      add('$tailWindow lyrics');
    }

    if (words.length >= 12) {
      for (var i = 0; i + 8 <= words.length && i <= 28; i += 4) {
        add('${words.skip(i).take(8).join(' ')} lyrics');
      }
    }

    final distinct = _distinctiveWords(
      words.map((w) => w.toLowerCase()).toList(),
      maxWords: 8,
    );
    if (distinct.length >= 4) {
      add('${distinct.join(' ')} lyrics');
    }

    final latinHeavy = _looksLatinLyricLine(trimmed);
    if (latinHeavy && words.length >= 8) {
      add('$trimmed rap lyrics');
      add('$trimmed hip hop lyrics');
    }

    for (final typo in typoExpandedQueries(trimmed, maxVariants: 3)) {
      add('$typo lyrics');
      add(typo);
    }

    return out.take(math.max(1, maxQueries)).toList();
  }

  /// Short phrases derived from [line] — take max [scoreTextMatch] vs metadata for ranking.
  static List<String> lyricLineScoringPhrases(String line) {
    final normalized = _normalizeLine(line);
    if (normalized.isEmpty) return const [];

    final words = normalized.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final out = <String>[normalized];
    final seen = <String>{normalized};

    void add(String s) {
      if (s.isEmpty || !seen.add(s)) return;
      out.add(s);
    }

    if (words.length >= 12) {
      add(words.take(8).join(' '));
      add(words.skip(words.length - 8).join(' '));
      add(words.skip((words.length / 3).floor()).take(8).join(' '));
    } else if (words.length >= 6) {
      add(words.take(8).join(' '));
      add(words.skip(words.length - 6).join(' '));
    }

    if (words.length >= 5) {
      add(words.take(6).join(' '));
    }

    final distinct = _distinctiveWords(words, maxWords: 8);
    if (distinct.length >= 4) {
      add(distinct.join(' '));
    }

    return out;
  }

  /// Best fuzzy match of any scoring phrase against title + channel + description.
  static double bestTextMatchForLyricLine(
    String title,
    String artist,
    String description,
    String lyricLine,
  ) {
    final blob = '$title $artist $description';
    var best = 0.0;
    for (final phrase in lyricLineScoringPhrases(lyricLine)) {
      best = math.max(best, scoreTextMatch(blob, phrase));
    }
    return best;
  }

  static const List<String> youtubeBadVersionKeywords = [
    'remix',
    'reel',
    'shorts',
    '#shorts',
    'sped up',
    'slowed',
    'nightcore',
    'lofi',
    'mashup',
    'edit',
    'dj',
    '8d',
    'bass boosted',
    'fanmade',
    'cover',
    'karaoke',
    'instrumental',
    'live',
    'short video',
    'status',
  ];

  static const List<String> youtubeGoodVersionKeywords = [
    'official audio',
    'official video',
    'audio',
    'lyric video',
    'topic',
    'vevo',
  ];

  /// Rank a YouTube search result against a user lyric line (shared by playback + lightweight search).
  static double scoreYoutubeCandidateForLyricLine(Map<String, dynamic> song, String lyricLine) {
    final title = song['title'] as String? ?? '';
    final artist = song['artist'] as String? ?? '';
    final description = song['description'] as String? ?? '';
    final durationSeconds = (song['durationSeconds'] as num?)?.toInt() ?? 0;

    var score = bestTextMatchForLyricLine(title, artist, description, lyricLine);

    final loweredTitle = title.toLowerCase();
    final loweredDescription = description.toLowerCase();
    if (loweredTitle.contains('lyrics')) score += 0.08;
    if (loweredTitle.contains('official')) score += 0.05;
    if (_containsAnyKeyword(loweredTitle, youtubeBadVersionKeywords)) score -= 0.28;
    if (_containsAnyKeyword(loweredDescription, youtubeBadVersionKeywords)) score -= 0.2;
    if (_containsAnyKeyword(loweredTitle, youtubeGoodVersionKeywords)) score += 0.12;
    if (durationSeconds >= 150) score += 0.08;

    return score;
  }

  static bool _containsAnyKeyword(String value, List<String> terms) {
    for (final t in terms) {
      if (value.contains(t)) return true;
    }
    return false;
  }

  static bool _looksLatinLyricLine(String s) {
    var latin = 0;
    var total = 0;
    for (final r in s.runes) {
      final ch = String.fromCharCode(r);
      if (ch.trim().isEmpty) continue;
      total++;
      if (RegExp(r'[A-Za-z]').hasMatch(ch)) latin++;
    }
    return total == 0 || (latin / total) >= 0.62;
  }

  static List<String> _distinctiveWords(List<String> words, {int maxWords = 8}) {
    final out = <String>[];
    for (final w in words) {
      final lw = w.toLowerCase();
      if (lw.length <= 1) continue;
      if (_englishStopWords.contains(lw)) continue;
      out.add(w);
      if (out.length >= maxWords) break;
    }
    return out;
  }

  static const Set<String> _englishStopWords = {
    'the', 'a', 'an', 'to', 'and', 'or', 'but', 'in', 'on', 'at', 'for', 'of', 'with', 'by',
    'from', 'as', 'is', 'was', 'are', 'were', 'be', 'been', 'being', 'have', 'has', 'had',
    'do', 'does', 'did', 'will', 'would', 'could', 'should', 'may', 'might', 'must', 'shall',
    'can', 'need', 'it', 'its', 'this', 'that', 'these', 'those', 'i', 'you', 'he', 'she', 'we',
    'they', 'them', 'me', 'my', 'your', 'his', 'her', 'our', 'their', 'what', 'which', 'who',
    'when', 'where', 'why', 'how', 'if', 'then', 'so', 'than', 'too', 'very', 'just', 'not',
    'no', 'yes', 'all', 'each', 'every', 'both', 'few', 'more', 'most', 'other', 'some', 'such',
    'only', 'same', 'own', 'into', 'out', 'up', 'down', 'about', 'over', 'under', 'again',
    'after', 'before', 'once', 'here', 'there', 'now', 'im', 'dont', 'gonna', 'wanna', 'got',
    'get', 'like', 'know', 'yeah', 'oh', 'uh', 'na',
  };

  /// Find the best matching line in LRC text and return its start time in seconds.
  /// LRC format: [MM:SS.xx] or [MM:SS] line text
  /// Returns 0 if no confident match was found.
  static int findStartTimeSeconds(String syncedLyrics, String userLine) {
    final best = _bestTimedMatch(syncedLyrics, userLine);
    if (best == null) return 0;

    final normalizedUser = _normalizeLine(userLine);
    final queryTokens = _splitTokens(normalizedUser);

    // Long dense lines (rap): slightly looser bar; short lines stay strict.
    final threshold = queryTokens.length >= 12
        ? 0.42
        : queryTokens.length >= 6
            ? 0.46
            : 0.40;
    return best.score >= threshold ? best.seconds : 0;
  }

  /// Scores how well [userLine] matches any line in [syncedLyrics]. 0..1
  static double scoreSyncedLyricsMatch(String syncedLyrics, String userLine) {
    final best = _bestTimedMatch(syncedLyrics, userLine);
    return best?.score ?? 0;
  }

  /// Returns the best matching lyric line text for [userLine], if available.
  static String? bestMatchingLineText(String syncedLyrics, String userLine) {
    final best = _bestTimedMatch(syncedLyrics, userLine);
    final line = best?.lineText.trim();
    if (line == null || line.isEmpty) return null;
    return line;
  }

  /// Returns best matching timestamp with configurable lower-bound confidence.
  /// Useful as a fallback when strict thresholding returns 0.
  static int? bestMatchingLineSeconds(
    String syncedLyrics,
    String userLine, {
    double minScore = 0.34,
  }) {
    final best = _bestTimedMatch(syncedLyrics, userLine);
    if (best == null) return null;
    return best.score >= minScore ? best.seconds : null;
  }

  /// Scores free text similarity (0..1), useful for ranking global fallbacks.
  static double scoreTextMatch(String text, String query) {
    final normalizedText = _normalizeLine(text);
    final normalizedQuery = _normalizeLine(query);
    if (normalizedText.isEmpty || normalizedQuery.isEmpty) return 0;

    final queryWords = _splitTokens(normalizedQuery).toSet();

    if (queryWords.isEmpty) return 0;
    return _lineSimilarity(normalizedText, normalizedQuery, queryWords);
  }

  static _TimedMatch? _bestTimedMatch(String syncedLyrics, String userLine) {
    if (syncedLyrics.isEmpty || userLine.isEmpty) return null;

    final normalizedUser = _normalizeLine(userLine);
    if (normalizedUser.isEmpty) return null;

    final userTokens = _splitTokens(normalizedUser);
    final userWords = userTokens.toSet();

    if (userWords.isEmpty) return null;

    final regex = RegExp(r'\[(\d+):(\d+)\.?(\d*)\]\s*(.*)');
    _TimedMatch? best;

    for (final line in syncedLyrics.split('\n')) {
      final match = regex.firstMatch(line);
      if (match == null) continue;

      final minutes = int.tryParse(match.group(1) ?? '0') ?? 0;
      final seconds = int.tryParse(match.group(2) ?? '0') ?? 0;
      final text = (match.group(4) ?? '').trim();
      if (text.isEmpty) continue;

      final normalizedText = _normalizeLine(text);
      final score = _lineSimilarity(
        normalizedText,
        normalizedUser,
        userWords,
        userTokens: userTokens,
      );
      final timed = _TimedMatch(
        seconds: (minutes * 60) + seconds,
        score: score,
        lineText: text,
      );

      if (best == null || timed.score > best.score) {
        best = timed;
      }
    }

    return best;
  }

  static double _lineSimilarity(
    String normalizedText,
    String normalizedUser,
    Set<String> userWords, {
    List<String>? userTokens,
  }) {
    if (normalizedText.isEmpty) return 0;

    if (normalizedText == normalizedUser) return 1.0;
    if (normalizedText.contains(normalizedUser) || normalizedUser.contains(normalizedText)) {
      return 0.92;
    }

    final textTokens = _splitTokens(normalizedText);
    final queryTokens = userTokens ?? _splitTokens(normalizedUser);
    final textWords = textTokens.toSet();

    if (textWords.isEmpty || queryTokens.isEmpty) return 0;

    final common = userWords.intersection(textWords).length.toDouble();
    final union = userWords.union(textWords).length.toDouble();
    final jaccard = union == 0 ? 0 : common / union;

    final coverage = userWords.isEmpty ? 0 : common / userWords.length;
    final phraseOverlap = _maxContiguousOverlapRatio(queryTokens, textTokens);
    final trigram = _charNgramSimilarity(normalizedUser, normalizedText, 3);
    final orderedWindow = _orderedWindowCoverage(queryTokens, textTokens);

    // Better for dense rap lines: emphasize coverage + nearby order while tolerating filler words.
    return (0.38 * coverage) +
        (0.16 * jaccard) +
        (0.20 * phraseOverlap) +
        (0.14 * trigram) +
        (0.12 * orderedWindow);
  }

  static List<String> _splitTokens(String text) {
    return text.split(RegExp(r'\s+')).where((w) => w.length > 1).toList();
  }

  /// Compute average milliseconds per word from synced lyrics (LRC format).
  /// Used to drive beat cursor at reference track's real tempo.
  /// Returns null if synced lyrics are empty or can't be parsed.
  static int? computeMsPerWordFromSyncedLyrics(String? syncedLyrics) {
    if (syncedLyrics == null || syncedLyrics.isEmpty) return null;

    final regex = RegExp(r'\[(\d+):(\d+)\.?(\d*)\]\s*(.*)');
    final entries = <_LrcEntry>[];
    for (final line in syncedLyrics.split('\n')) {
      final match = regex.firstMatch(line);
      if (match == null) continue;
      final minutes = int.tryParse(match.group(1) ?? '0') ?? 0;
      final seconds = int.tryParse(match.group(2) ?? '0') ?? 0;
      final text = (match.group(4) ?? '').trim();
      if (text.isEmpty) continue;
      final totalSeconds = (minutes * 60) + seconds;
      final cleanText = text.replaceAll(RegExp(r'\[\d+:\d+\.?\d*\]'), ' ');
      final words = _splitTokens(cleanText);
      if (words.isEmpty) continue;
      entries.add(_LrcEntry(seconds: totalSeconds, wordCount: words.length));
    }
    if (entries.isEmpty) return null;

    entries.sort((a, b) => a.seconds.compareTo(b.seconds));
    final firstSec = entries.first.seconds;
    final lastSec = entries.last.seconds;
    final spanSec = (lastSec - firstSec).clamp(1, 600); // 1s–10min
    final totalWords = entries.fold<int>(0, (s, e) => s + e.wordCount);
    if (totalWords == 0) return null;

    final msPerWord = (spanSec * 1000) ~/ totalWords;
    return msPerWord.clamp(200, 1200); // sane range 200–1200 ms/word
  }

  static double _maxContiguousOverlapRatio(List<String> queryTokens, List<String> textTokens) {
    if (queryTokens.isEmpty || textTokens.isEmpty) return 0;

    int best = 0;
    for (var i = 0; i < queryTokens.length; i++) {
      for (var j = 0; j < textTokens.length; j++) {
        var k = 0;
        while (i + k < queryTokens.length &&
            j + k < textTokens.length &&
            queryTokens[i + k] == textTokens[j + k]) {
          k++;
        }
        if (k > best) best = k;
      }
    }
    return best / queryTokens.length;
  }

  static double _orderedWindowCoverage(List<String> queryTokens, List<String> textTokens) {
    if (queryTokens.isEmpty || textTokens.isEmpty) return 0;

    var qi = 0;
    var hits = 0;
    for (final token in textTokens) {
      if (qi < queryTokens.length && token == queryTokens[qi]) {
        qi++;
        hits++;
      }
    }
    if (hits == 0) return 0;
    return hits / queryTokens.length;
  }

  static double _charNgramSimilarity(String a, String b, int n) {
    if (a.isEmpty || b.isEmpty || n <= 0) return 0;

    final gramsA = _charNgrams(a, n);
    final gramsB = _charNgrams(b, n);
    if (gramsA.isEmpty || gramsB.isEmpty) return 0;

    final common = gramsA.intersection(gramsB).length.toDouble();
    return (2 * common) / (gramsA.length + gramsB.length);
  }

  static Set<String> _charNgrams(String text, int n) {
    final compact = text.replaceAll(' ', '');
    if (compact.length < n) return {compact};

    final out = <String>{};
    for (var i = 0; i <= compact.length - n; i++) {
      out.add(compact.substring(i, i + n));
    }
    return out;
  }

  static String _normalizeLine(String s) {
    var out = s.toLowerCase();
    for (final entry in _normalizationReplacements.entries) {
      out = out.replaceAll(entry.key, entry.value);
    }
    return out
        .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  // Lightweight slang/contraction normalization to improve one-line lyric recall.
  static const Map<String, String> _normalizationReplacements = {
    "can't": "cant",
    "won't": "wont",
    "ain't": "aint",
    "i'm": "im",
    "you're": "youre",
    "we're": "were",
    "they're": "theyre",
    "it's": "its",
    "that's": "thats",
    "there's": "theres",
    "what's": "whats",
    "don't": "dont",
    "doesn't": "doesnt",
    "didn't": "didnt",
    "isn't": "isnt",
    "aren't": "arent",
    "wasn't": "wasnt",
    "weren't": "werent",
    "couldn't": "couldnt",
    "shouldn't": "shouldnt",
    "wouldn't": "wouldnt",
    "gonna": "going to",
    "wanna": "want to",
    "gotta": "got to",
    "imma": "i am going to",
    "tryna": "trying to",
    "ya": "you",
    "yall": "you all",
    "finna": "going to",
    "bout": "about",
    "cuz": "because",
    "cos": "because",
    "til": "until",
    "wit": "with",
    "dat": "that",
    "dem": "them",
  };

  /// Build a [LyricPlayResult] from a [LyricsMatch] and the user's line (to compute start time).
  LyricPlayResult? toPlayResult(LyricsMatch match, String userLine) {
    final synced = match.syncedLyrics;
    if (synced == null || synced.isEmpty) return null;

    final startSeconds = findStartTimeSeconds(synced, userLine);
    return LyricPlayResult(
      trackName: match.trackName,
      artistName: match.artistName,
      durationSeconds: match.durationSeconds,
      startTimeSeconds: startSeconds,
      syncedLyrics: synced,
    );
  }
}

class _TimedMatch {
  const _TimedMatch({
    required this.seconds,
    required this.score,
    required this.lineText,
  });

  final int seconds;
  final double score;
  final String lineText;
}

class _LrcEntry {
  const _LrcEntry({required this.seconds, required this.wordCount});
  final int seconds;
  final int wordCount;
}
