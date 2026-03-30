import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_twemoji/flutter_twemoji.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../models/song_reference.dart';
import '../services/local_suggestions_service.dart';
import '../widgets/song_flow_timeline.dart';
import 'voice_sample_screen.dart';

// ─── MOOD OPTIONS ─────────────────────────────────────────────────────────────
const _moodData = <String, _MoodInfo>{
  'Energetic': _MoodInfo(
    emoji: '⚡',
    prompt:
        'High-energy vibes: upbeat tempo, powerful delivery, motivational or hype lyrics with strong rhythmic punchlines',
  ),
  'Melancholic': _MoodInfo(
    emoji: '🌧️',
    prompt:
        'Reflective and somber: introspective lyrics about loss, longing, or sadness with emotional depth',
  ),
  'Euphoric': _MoodInfo(
    emoji: '🌟',
    prompt:
        'Uplifting and triumphant: celebratory lyrics about success, joy, or breakthrough moments with soaring energy',
  ),
  'Dreamy': _MoodInfo(
    emoji: '☁️',
    prompt:
        'Ethereal and atmospheric: abstract imagery, soft flow, surreal or poetic expressions about aspirations or fantasies',
  ),
  'Heartbreak': _MoodInfo(
    emoji: '💔',
    prompt:
        'Raw emotional pain: lyrics about betrayal, separation, or unrequited love with vulnerable storytelling',
  ),
  'Intense': _MoodInfo(
    emoji: '🔥',
    prompt:
        'Aggressive and hard-hitting: bold lyrics with sharp wordplay, confrontation, or raw emotion delivered with force',
  ),
  'Chill': _MoodInfo(
    emoji: '🍃',
    prompt:
        'Laid-back and relaxed: smooth flow, mellow vibes, lyrics about unwinding, reflection, or easy-going moments',
  ),
  'Romantic': _MoodInfo(
    emoji: '💕',
    prompt:
        'Love and affection: tender lyrics about connection, intimacy, devotion, or relationship warmth',
  ),
};

class _MoodInfo {
  const _MoodInfo({required this.emoji, required this.prompt});
  final String emoji;
  final String prompt;
}

List<String> get _moods => _moodData.keys.toList();
String _getMoodEmoji(String mood) => _moodData[mood]?.emoji ?? '🎵';
String _getMoodPrompt(String mood) => _moodData[mood]?.prompt ?? '';

Widget _emojiBadge(String emoji, {double size = 18}) =>
    Twemoji(emoji: emoji, width: size, height: size);

// ─── HOME SCREEN PALETTE (matches lyric_home_screen) ──────────────────────────
class _HP {
  static const background = Color(0xFFF5F3EF);
  static const card = Color(0xFFF0EDE7);
  static const cardAlt = Color(0xFFFAF8F5);
  static const border = Color(0xFFD8D4CC);
  static const borderAlt = Color(0xFFEAE6E0);
  static const black = Color(0xFF111111);
  static const blackSoft = Color(0xFF1E1E1E);
  static const grey1 = Color(0xFF444444);
  static const grey2 = Color(0xFF666666);
  static const grey3 = Color(0xFF888888);
  static const grey4 = Color(0xFFAAAAAA);
  static const green = Color(0xFF11F08A);
  static const chip = Color(0xFFE8E3DC);
  static const chipDark = Color(0xFFD8D4CC);
}

// ─── RESULT MODEL ─────────────────────────────────────────────────────────────
class _SongResult {
  const _SongResult({
    required this.title,
    required this.hinglishLyrics,
    required this.englishLyrics,
    required this.mood,
    required this.genre,
    required this.dominantLanguage,
    this.referenceSong,
  });

  final String title;
  final String hinglishLyrics; // Romanized Hindi (Hinglish) for Hindi-dominant
  final String englishLyrics;
  final String mood;
  final String genre;
  final String dominantLanguage; // 'Hindi' | 'English'
  final SongReference? referenceSong;

  String get fullText =>
      '"$title"\nDominant: $dominantLanguage | Mood: $mood | Genre: $genre\n\n'
      '── ${dominantLanguage == 'Hindi' ? 'Hinglish' : 'English'} ──\n'
      '${dominantLanguage == 'Hindi' ? hinglishLyrics : englishLyrics}';
}

enum _GenerationMode { singleSong, history }

// ─── SCREEN ───────────────────────────────────────────────────────────────────
class GenerateSongScreen extends StatefulWidget {
  const GenerateSongScreen({super.key});

  @override
  State<GenerateSongScreen> createState() => _GenerateSongScreenState();
}

class _GenerateSongScreenState extends State<GenerateSongScreen>
    with SingleTickerProviderStateMixin {
  List<RecentTrack> _recentTracks = [];
  RecentTrack? _selectedTrack;
  _GenerationMode _generationMode = _GenerationMode.singleSong;

  String? _aiSuggestedMood;
  String? _selectedMood;
  String? _customMoodPrompt;

  _SongResult? _result;
  bool _isLoading = false;
  bool _isMoodLoading = false;
  String? _errorMessage;

  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _loadTracksAndSuggestMood();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _loadTracksAndSuggestMood() async {
    final service = await LocalSuggestionsService.create();
    if (!mounted) return;
    final tracks = service.getRecentTracks();
    setState(() {
      _recentTracks = tracks;
      _selectedTrack = tracks.isNotEmpty ? tracks.first : null;
      _isMoodLoading = _analysisTracks.isNotEmpty;
    });
    if (_analysisTracks.isEmpty) return;
    await _refreshMoodSuggestion();
  }

  List<RecentTrack> get _analysisTracks {
    if (_generationMode == _GenerationMode.singleSong) {
      final s = _selectedTrack;
      return s == null ? const [] : [s];
    }
    return _recentTracks;
  }

  Future<void> _refreshMoodSuggestion() async {
    final tracks = _analysisTracks;
    if (tracks.isEmpty) {
      if (mounted)
        setState(() {
          _aiSuggestedMood = null;
          _isMoodLoading = false;
        });
      return;
    }
    if (mounted)
      setState(() {
        _isMoodLoading = true;
        _aiSuggestedMood = null;
      });
    try {
      final mood = await _detectMood(tracks);
      if (mounted) setState(() => _aiSuggestedMood = mood);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _isMoodLoading = false);
    }
  }

  Future<void> _setGenerationMode(_GenerationMode mode) async {
    if (_generationMode == mode) return;
    setState(() {
      _generationMode = mode;
      _result = null;
      _errorMessage = null;
      _selectedMood = null;
      _isMoodLoading = _analysisTracks.isNotEmpty;
    });
    await _refreshMoodSuggestion();
  }

  Future<void> _selectTrack(RecentTrack track) async {
    if (_selectedTrack == track) return;
    setState(() {
      _selectedTrack = track;
      _result = null;
      _errorMessage = null;
      _selectedMood = null;
      _isMoodLoading = _analysisTracks.isNotEmpty;
    });
    if (_generationMode == _GenerationMode.singleSong) {
      await _refreshMoodSuggestion();
    }
  }

  Future<String> _detectMood(List<RecentTrack> tracks) async {
    final apiKey = dotenv.env['GROQ_API_KEY'] ?? '';
    if (apiKey.isEmpty) throw Exception('GROQ_API_KEY not set');
    final trackList = tracks
        .take(15)
        .map((t) => '${t.trackName} – ${t.artistName}')
        .join(', ');
    final response = await http
        .post(
          Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          body: json.encode({
            'model': 'llama-3.3-70b-versatile',
            'max_tokens': 10,
            'messages': [
              {
                'role': 'system',
                'content':
                    'You are a music mood analyst. Reply with ONLY one word from: Energetic, Melancholic, Euphoric, Dreamy, Heartbreak, Intense, Chill, Romantic. No punctuation, nothing else.',
              },
              {
                'role': 'user',
                'content':
                    'Based on these songs, what is the dominant mood? $trackList',
              },
            ],
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) throw Exception('Mood detection failed');
    final data = json.decode(response.body);
    final raw = (data['choices'][0]['message']['content'] as String).trim();
    return _moods.firstWhere(
      (m) => raw.toLowerCase().contains(m.toLowerCase()),
      orElse: () => 'Chill',
    );
  }

  // ─── IMPROVED LANGUAGE DETECTION ──────────────────────────────────────────
  // Checks multiple signals: script, known Hindi/Urdu words, artist origin
  // and uses a scoring approach rather than a binary flag.

  bool _containsSouthAsianScript(String text) {
    for (final rune in text.runes) {
      // Devanagari, Arabic/Urdu scripts
      if ((rune >= 0x0900 && rune <= 0x097F) ||
          (rune >= 0x0600 && rune <= 0x06FF))
        return true;
    }
    return false;
  }

  static const _hindiUrduWords = [
    'mohabbat',
    'ishq',
    'dil',
    'zindagi',
    'safar',
    'yaad',
    'tere',
    'meri',
    'tujhe',
    'tum',
    'hum',
    'khuda',
    'junoon',
    'raat',
    'pyaar',
    'bina',
    'aankhon',
    'jaan',
    'teri',
    'mera',
    'hua',
    'koi',
    'nahi',
    'hai',
    'ho',
    'kar',
    'ab',
    'ek',
    'aur',
    'woh',
    'jo',
    'se',
    'ke',
    'ki',
    'ka',
    'main',
    'aaj',
    'kal',
    'roz',
    'sach',
    'jhooth',
    'khwab',
    'sitara',
    'duniya',
    'dunya',
    'rooh',
    'noor',
    'chaand',
    'suraj',
    'pani',
    'aag',
    'hawa',
    'mehfil',
    'shayar',
    'ghazal',
    'qawwali',
    'bollywood',
    'filmi',
    'hindi',
    'urdu',
    'punjabi',
    'hindustani',
  ];

  static const _southAsianArtistMarkers = [
    'arijit',
    'atif',
    'shreya',
    'neha',
    'sonu',
    'lata',
    'rafi',
    'kishore',
    'rahat',
    'nusrat',
    'abida',
    'gulam',
    'ustad',
    'pandit',
    'ar rahman',
    'pritam',
    'vishal',
    'shekhar',
    'shankar',
    'ehsaan',
    'loy',
    'amit trivedi',
    'young stunners',
    'talha',
    'talhah',
    'emiway',
    'divine',
    'mc stan',
    'badshah',
    'honey singh',
    'yo yo',
    'diljit',
    'ap dhillon',
    'sidhu',
    'karan aujla',
    'b praak',
    'jassi',
    'guru randhawa',
    'harrdy',
    'darshan',
    'jubin',
    'armaan',
    'stebin',
    'rahul jain',
    'ankur tewari',
    'prateek kuhad',
    'mitraz',
    'when chai met toast',
    'the local train',
    'parikrama',
    'strings',
    'ali zafar',
    'asim azhar',
    'momina',
    'quratulain',
    'farida',
    'coke studio',
  ];

  /// Returns a score 0.0–1.0 where >0.5 means Hindi/South-Asian dominant.
  double _southAsianScore(RecentTrack track) {
    double score = 0.0;
    final combined =
        '${track.trackName} ${track.artistName} ${track.lyricSnippet}'
            .toLowerCase();

    // Hard signal: Devanagari/Arabic script in any field
    if (_containsSouthAsianScript('${track.trackName}${track.lyricSnippet}')) {
      score += 0.9;
      return score.clamp(0.0, 1.0);
    }

    // Hindi/Urdu word matches in combined text
    int wordHits = 0;
    for (final word in _hindiUrduWords) {
      if (combined.contains(word)) wordHits++;
    }
    // Each word hit contributes; cap contribution at 0.6
    score += (wordHits * 0.08).clamp(0.0, 0.6);

    // Artist name matches South-Asian roster
    final artistLower = track.artistName.toLowerCase();
    for (final marker in _southAsianArtistMarkers) {
      if (artistLower.contains(marker)) {
        score += 0.5;
        break;
      }
    }

    // Track name in non-ASCII but not Devanagari (e.g. Romanized Hindi titles)
    final trackLower = track.trackName.toLowerCase();
    if (_hindiUrduWords.any(trackLower.contains)) score += 0.2;

    return score.clamp(0.0, 1.0);
  }

  bool _isHindiDominantTrack(RecentTrack track) =>
      _southAsianScore(track) > 0.4;

  bool _isHindiDominantTracks(List<RecentTrack> tracks) {
    if (tracks.isEmpty) return false;
    final hindiCount = tracks.where(_isHindiDominantTrack).length;
    return hindiCount >= ((tracks.length + 1) ~/ 2);
  }

  Future<void> _generate() async {
    if (_isLoading) return;
    final referenceTracks = _analysisTracks;
    if (referenceTracks.isEmpty) {
      setState(() {
        _errorMessage =
            _generationMode == _GenerationMode.singleSong
                ? 'Pick a reference song first.'
                : 'No listening history yet — play a few songs first!';
      });
      return;
    }

    final mood = _selectedMood ?? _aiSuggestedMood ?? 'Chill';
    final apiKey = dotenv.env['GROQ_API_KEY'] ?? '';
    if (apiKey.isEmpty) {
      setState(() {
        _errorMessage =
            'GROQ_API_KEY not set in .env\nGet a free key at console.groq.com';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _result = null;
    });

    final trackList = referenceTracks
        .take(20)
        .map((t) => '${t.trackName} – ${t.artistName}')
        .join('\n');
    final selectedReference = _selectedTrack;
    final moodPrompt = _customMoodPrompt;

    // Use improved language detection
    final isHindiDominant =
        _generationMode == _GenerationMode.singleSong
            ? _isHindiDominantTrack(selectedReference!)
            : _isHindiDominantTracks(referenceTracks);

    final dominantLanguage = isHindiDominant ? 'Hindi' : 'English';

    final prompt =
        _generationMode == _GenerationMode.singleSong
            ? _buildSingleSongPrompt(
              mood: mood,
              moodPrompt: moodPrompt,
              reference: selectedReference!,
              isHindiDominant: isHindiDominant,
            )
            : _buildHistoryPrompt(
              mood: mood,
              moodPrompt: moodPrompt,
              trackList: trackList,
              isHindiDominant: isHindiDominant,
            );

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
              'max_tokens': 1800,
              'temperature': 0.9,
              'messages': [
                {
                  'role': 'system',
                  'content':
                      isHindiDominant
                          ? 'You are a bilingual Hindi-English hip-hop / rap songwriter. Write lyrics in Hinglish (Romanized Hindi) with clear rhythm, rhyme, and poetic imagery. Always respond with valid JSON only. No markdown.'
                          : 'You are an English hip-hop / rap songwriter with British accent and flow. Always respond with valid JSON only. No markdown.',
                },
                {'role': 'user', 'content': prompt},
              ],
            }),
          )
          .timeout(const Duration(seconds: 40));

      if (!mounted) return;
      if (response.statusCode != 200)
        throw Exception(
          'Groq API error ${response.statusCode}: ${response.body}',
        );

      final data = json.decode(response.body);
      final raw =
          (data['choices'][0]['message']['content'] as String)
              .replaceAll(RegExp(r'```json\s*'), '')
              .replaceAll(RegExp(r'```\s*'), '')
              .trim();

      final parsed = json.decode(raw) as Map<String, dynamic>;

      // For Hindi dominant: use hinglish_lyrics; for English: use english_lyrics
      final hinglishLyrics =
          (parsed['hinglish_lyrics'] ?? parsed['hindi_lyrics'] ?? '')
              as String? ??
          '';
      final englishLyrics = (parsed['english_lyrics'] ?? '') as String? ?? '';

      final result = _SongResult(
        title: parsed['title'] as String? ?? 'Untitled',
        hinglishLyrics: hinglishLyrics,
        englishLyrics: englishLyrics,
        mood: parsed['mood'] as String? ?? mood,
        genre: parsed['genre'] as String? ?? '',
        dominantLanguage: dominantLanguage,
        referenceSong:
            selectedReference == null
                ? null
                : SongReference(
                  trackName: selectedReference.trackName,
                  artistName: selectedReference.artistName,
                  lyricSnippet: selectedReference.lyricSnippet,
                  videoId: selectedReference.videoId,
                  startTimeSeconds: selectedReference.startTimeSeconds,
                ),
      );

      if (!mounted) return;
      setState(() {
        _result = result;
        _isLoading = false;
      });

      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder:
              (_) => VoiceSampleScreen(
                songTitle: result.title,
                hindiLyrics:
                    result.hinglishLyrics, // pass Hinglish as hindiLyrics
                englishLyrics: result.englishLyrics,
                dominantLanguage: result.dominantLanguage,
                mood: result.mood,
                genre: result.genre,
                referenceSong: result.referenceSong,
                hinglishLyrics: result.hinglishLyrics,
              ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  void _copyToClipboard() {
    if (_result == null) return;
    Clipboard.setData(ClipboardData(text: _result!.fullText));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(
                Icons.check_circle_rounded,
                size: 16,
                color: Color(0xFF11F08A),
              ),
              SizedBox(width: 8),
              Text(
                'Lyrics copied!',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: _HP.black,
          elevation: 0,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  void _openVoiceClone() {
    final r = _result;
    if (r == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => VoiceSampleScreen(
              songTitle: r.title,
              hindiLyrics: r.hinglishLyrics,
              englishLyrics: r.englishLyrics,
              dominantLanguage: r.dominantLanguage,
              mood: r.mood,
              genre: r.genre,
              referenceSong: r.referenceSong,
              hinglishLyrics: r.hinglishLyrics,
            ),
      ),
    );
  }

  // ─── PROMPT BUILDERS ──────────────────────────────────────────────────────
  String _buildHistoryPrompt({
    required String mood,
    required String? moodPrompt,
    required String trackList,
    required bool isHindiDominant,
  }) {
    final moodInfo =
        (moodPrompt != null && moodPrompt.isNotEmpty)
            ? 'Mood instructions: $moodPrompt\n'
            : 'Requested mood: $mood\n';
    return isHindiDominant
        ? _buildHindiPrompt(
          mood: mood,
          moodInfo: moodInfo,
          trackList: trackList,
          isHistory: true,
        )
        : _buildEnglishPrompt(
          mood: mood,
          moodInfo: moodInfo,
          trackList: trackList,
          isHistory: true,
        );
  }

  String _buildSingleSongPrompt({
    required String mood,
    required String? moodPrompt,
    required RecentTrack reference,
    required bool isHindiDominant,
  }) {
    final snippet = reference.lyricSnippet.trim();
    final moodInfo =
        (moodPrompt != null && moodPrompt.isNotEmpty)
            ? 'Mood instructions: $moodPrompt\n'
            : 'Requested mood: $mood\n';
    return isHindiDominant
        ? _buildHindiPrompt(
          mood: mood,
          moodInfo: moodInfo,
          trackList: '${reference.trackName} – ${reference.artistName}',
          isHistory: false,
          snippet: snippet,
        )
        : _buildEnglishPrompt(
          mood: mood,
          moodInfo: moodInfo,
          trackList: '${reference.trackName} – ${reference.artistName}',
          isHistory: false,
          snippet: snippet,
        );
  }

  /// Hindi-dominant: output is HINGLISH (Romanized Hindi), NOT Devanagari.
  /// P.S. from user: Hindi language lyrics should be in Hinglish.
  String _buildHindiPrompt({
    required String mood,
    required String moodInfo,
    required String trackList,
    required bool isHistory,
    String? snippet,
  }) {
    final refInfo =
        isHistory
            ? 'Listening history:\n$trackList\n\n'
            : 'Reference song: $trackList\n${snippet != null && snippet.isNotEmpty ? 'Lyric snippet: $snippet\n' : ''}';

    return 'You are a bilingual Hindi-English hip-hop / rap songwriter.\n\n'
        '$refInfo'
        '$moodInfo\n'
        'IMPORTANT: Write ALL Hindi lyrics in HINGLISH (Romanized Hindi using English alphabet). '
        'Do NOT use Devanagari script at all. Write as you would rap it phonetically.\n\n'
        'Rules:\n'
        '- Write COMPLETELY ORIGINAL bilingual lyrics with HINDI as the dominant language\n'
        '- All Hindi words must be written in Roman/English letters (Hinglish) — e.g. "Meri jaan", "Tere bina adhoora hoon", "Dil ki baat"\n'
        '- Strong rhythm, end rhymes, internal rhymes where natural, and vivid poetry\n'
        '- You can include some English words/phrases for flavor (70-80% Hindi words in Hinglish, 20-30% English)\n'
        '- Section headers ([Intro], [Verse 1], [Hook], [Verse 2], [Bridge], [Outro]) always in English\n'
        '- Use [Hook] instead of [Chorus] for the main refrain\n'
        '- Title: 2–4 words, bilingual style (e.g. "Dil ki Beat" or "Roshan Nights")\n\n'
        'Respond ONLY with this JSON (no markdown, no Devanagari anywhere):\n'
        '{"title":"...","mood":"$mood","genre":"Hip-hop",'
        '"hinglish_lyrics":"[Verse 1]\\nHinglish line here\\n\\n[Hook]\\nHinglish line here\\n\\n[Verse 2]\\nHinglish line here\\n\\n[Bridge]\\nHinglish line here\\n\\n[Outro]\\nHinglish line here",'
        '"english_lyrics":"[Verse 1]\\nEnglish translation line\\n\\n[Hook]\\nEnglish translation line\\n\\n[Verse 2]\\nEnglish translation line\\n\\n[Bridge]\\nEnglish translation line\\n\\n[Outro]\\nEnglish translation line"}';
  }

  /// English-dominant: pure English with British flavour, no Hindi at all.
  String _buildEnglishPrompt({
    required String mood,
    required String moodInfo,
    required String trackList,
    required bool isHistory,
    String? snippet,
  }) {
    final refInfo =
        isHistory
            ? 'Listening history:\n$trackList\n\n'
            : 'Reference song: $trackList\n${snippet != null && snippet.isNotEmpty ? 'Lyric snippet: $snippet\n' : ''}';

    return 'You are an English hip-hop / rap songwriter with British accent and flow.\n\n'
        '$refInfo'
        '$moodInfo\n'
        'Rules:\n'
        '- Write COMPLETELY ORIGINAL lyrics in PURE ENGLISH only\n'
        '- Use British English spelling, vocabulary, and accent\n'
        '- Strong rhythm, end rhymes, internal rhymes where natural, and vivid poetry\n'
        '- NO Hindi words, NO Hinglish, NO Indian language mixing — pure English only\n'
        '- Section headers ([Intro], [Verse 1], [Hook], [Verse 2], [Bridge], [Outro]) always in English\n'
        '- Use [Hook] instead of [Chorus] for the main refrain\n'
        '- Title: 2–4 words, English style (e.g. "London Nights" or "Mid Rain")\n\n'
        'Respond ONLY with this JSON (no markdown):\n'
        '{"title":"...","mood":"$mood","genre":"Hip-hop",'
        '"hinglish_lyrics":"",'
        '"english_lyrics":"[Verse 1]\\nBritish English line\\n\\n[Hook]\\nBritish English line\\n\\n[Verse 2]\\nBritish English line\\n\\n[Bridge]\\nBritish English line\\n\\n[Outro]\\nBritish English line"}';
  }

  // ─── BUILD ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final screenWidth = mq.size.width;
    final screenHeight = mq.size.height;
    final isCompact = screenWidth < 600;
    final hPad = isCompact ? screenWidth * 0.05 : screenWidth * 0.08;

    return Scaffold(
      backgroundColor: _HP.background,
      bottomNavigationBar: SafeArea(
        minimum: EdgeInsets.fromLTRB(hPad, 8, hPad, 12),
        child: _GenerateButton(
          isLoading: _isLoading,
          mode: _generationMode,
          pulseController: _pulseController,
          onPressed: _isLoading ? null : _generate,
        ),
      ),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.opaque,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return Column(
                children: [
                  // ── Header ──────────────────────────────────────────────
                  Padding(
                    padding: EdgeInsets.fromLTRB(hPad, 16, hPad, 12),
                    child: _ScreenHeader(
                      hasResult: _result != null,
                      onCopy: _copyToClipboard,
                    ),
                  ),
                  // ── Scrollable content ───────────────────────────────────
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Reference song card
                          _ReferenceCard(
                            recentTracks: _recentTracks,
                            mode: _generationMode,
                            selectedTrack: _selectedTrack,
                            onModeChanged: _setGenerationMode,
                            onTrackSelected: _selectTrack,
                          ),
                          const SizedBox(height: 20),
                          // Mood selector
                          _MoodSection(
                            aiSuggestedMood: _aiSuggestedMood,
                            selectedMood: _selectedMood,
                            isMoodLoading: _isMoodLoading,
                            customPrompt: _customMoodPrompt,
                            onMoodSelected:
                                (mood) => setState(() {
                                  _selectedMood =
                                      _selectedMood == mood ? null : mood;
                                }),
                            onPromptChanged:
                                (p) => setState(() => _customMoodPrompt = p),
                          ),
                          // Loading steps
                          if (_isLoading) ...[
                            const SizedBox(height: 20),
                            const _LoadingSteps(),
                          ],
                          // Error message
                          if (_errorMessage != null) ...[
                            const SizedBox(height: 16),
                            _ErrorBanner(message: _errorMessage!),
                          ],
                          // Result card
                          if (_result != null) ...[
                            const SizedBox(height: 24),
                            _ResultCard(
                              result: _result!,
                              onCopy: _copyToClipboard,
                            ),
                            const SizedBox(height: 14),
                            _ActionRow(
                              isLoading: _isLoading,
                              onRecord: _openVoiceClone,
                              onRegenerate: _generate,
                            ),
                          ],
                          const SizedBox(height: 16),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

// ─── SCREEN HEADER ────────────────────────────────────────────────────────────
class _ScreenHeader extends StatelessWidget {
  const _ScreenHeader({required this.hasResult, required this.onCopy});
  final bool hasResult;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SongFlowTimeline(currentStep: 1),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () => Navigator.of(context).maybePop(),
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: _HP.chip,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _HP.border),
                ),
                child: const Icon(
                  Icons.arrow_back_rounded,
                  size: 20,
                  color: _HP.black,
                ),
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Write your song',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      color: _HP.black,
                      height: 1.05,
                    ),
                  ),
                  SizedBox(height: 3),
                  Text(
                    'Choose the vibe, generate lyrics, then record.',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: _HP.grey2,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ─── REFERENCE CARD ───────────────────────────────────────────────────────────
class _ReferenceCard extends StatelessWidget {
  const _ReferenceCard({
    required this.recentTracks,
    required this.mode,
    required this.selectedTrack,
    required this.onModeChanged,
    required this.onTrackSelected,
  });
  final List<RecentTrack> recentTracks;
  final _GenerationMode mode;
  final RecentTrack? selectedTrack;
  final Future<void> Function(_GenerationMode) onModeChanged;
  final Future<void> Function(RecentTrack) onTrackSelected;

  @override
  Widget build(BuildContext context) {
    final visibleTracks =
        mode == _GenerationMode.singleSong
            ? recentTracks.take(4).toList()
            : recentTracks;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _HP.card,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _HP.border, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: _HP.black,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Icon(
                  Icons.auto_awesome_rounded,
                  color: Colors.white,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'AI Songwriting',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                        color: _HP.black,
                      ),
                    ),
                    Text(
                      'Hindi lyrics • Powered by Groq',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: _HP.grey2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Mode toggle — matches home screen pill style
          Row(
            children: [
              _ModePill(
                label: 'One Song',
                active: mode == _GenerationMode.singleSong,
                onTap: () => onModeChanged(_GenerationMode.singleSong),
              ),
              const SizedBox(width: 8),
              _ModePill(
                label: 'History',
                active: mode == _GenerationMode.history,
                onTap: () => onModeChanged(_GenerationMode.history),
              ),
            ],
          ),
          if (recentTracks.isNotEmpty) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                _emojiBadge(
                  mode == _GenerationMode.singleSong ? '🎧' : '📚',
                  size: 14,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    mode == _GenerationMode.singleSong
                        ? 'Choose a reference song'
                        : 'Using ${recentTracks.length} tracks from your history',
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _HP.grey1,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children:
                  visibleTracks.map((t) {
                    final isSelected =
                        mode == _GenerationMode.singleSong &&
                        selectedTrack?.trackName == t.trackName &&
                        selectedTrack?.artistName == t.artistName;
                    return GestureDetector(
                      onTap:
                          mode == _GenerationMode.singleSong
                              ? () => onTrackSelected(t)
                              : null,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: isSelected ? _HP.black : _HP.chipDark,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: isSelected ? _HP.black : _HP.border,
                          ),
                        ),
                        child: Text(
                          '${t.trackName}${t.artistName.isEmpty ? '' : ' • ${t.artistName}'}',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: isSelected ? Colors.white : _HP.grey1,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    );
                  }).toList(),
            ),
          ] else ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _HP.chipDark,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline_rounded, size: 14, color: _HP.grey2),
                  SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      'Play some songs first to build your taste profile.',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: _HP.grey2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ModePill extends StatelessWidget {
  const _ModePill({
    required this.label,
    required this.active,
    required this.onTap,
  });
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: active ? _HP.black : _HP.chip,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: active ? _HP.black : _HP.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: active ? Colors.white : _HP.grey1,
          ),
        ),
      ),
    );
  }
}

// ─── MOOD SECTION ──────────────────────────────────────────────────────────────
class _MoodSection extends StatefulWidget {
  const _MoodSection({
    required this.aiSuggestedMood,
    required this.selectedMood,
    required this.isMoodLoading,
    required this.customPrompt,
    required this.onMoodSelected,
    required this.onPromptChanged,
  });
  final String? aiSuggestedMood;
  final String? selectedMood;
  final bool isMoodLoading;
  final String? customPrompt;
  final void Function(String) onMoodSelected;
  final void Function(String) onPromptChanged;

  @override
  State<_MoodSection> createState() => _MoodSectionState();
}

class _MoodSectionState extends State<_MoodSection> {
  final _promptController = TextEditingController();
  String? _lastActiveMood;

  @override
  void initState() {
    super.initState();
    final initialMood = widget.selectedMood ?? widget.aiSuggestedMood;
    if (initialMood != null) {
      _promptController.text =
          widget.customPrompt ?? _getMoodPrompt(initialMood);
    }
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_MoodSection old) {
    super.didUpdateWidget(old);
    final activeMood = widget.selectedMood ?? widget.aiSuggestedMood;
    if (activeMood != _lastActiveMood) {
      _lastActiveMood = activeMood;
      if (activeMood != null)
        _promptController.text =
            widget.customPrompt ?? _getMoodPrompt(activeMood);
    } else if (widget.customPrompt != null &&
        _promptController.text != widget.customPrompt) {
      _promptController.text = widget.customPrompt!;
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeMood = widget.selectedMood ?? widget.aiSuggestedMood;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section title row
        Row(
          children: [
            const Text(
              'Mood',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 16,
                fontWeight: FontWeight.w900,
                color: _HP.black,
              ),
            ),
            const SizedBox(width: 8),
            if (widget.isMoodLoading)
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: _HP.black,
                ),
              )
            else if (widget.aiSuggestedMood != null &&
                widget.selectedMood == null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _HP.green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _HP.green.withValues(alpha: 0.4)),
                ),
                child: const Text(
                  'AI picked',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0A9B5A),
                  ),
                ),
              ),
            if (widget.selectedMood != null) ...[
              const Spacer(),
              GestureDetector(
                onTap: () => widget.onMoodSelected(widget.selectedMood!),
                child: const Text(
                  'Reset to AI',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: _HP.grey2,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        // Mood chips — same pill style as home screen
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children:
              _moods.map((mood) {
                final isActive = activeMood == mood;
                return GestureDetector(
                  onTap: () => widget.onMoodSelected(mood),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: isActive ? _HP.black : _HP.chip,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: isActive ? _HP.black : _HP.border,
                        width: isActive ? 1.5 : 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _emojiBadge(_getMoodEmoji(mood), size: 14),
                        const SizedBox(width: 7),
                        Text(
                          mood,
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: isActive ? Colors.white : _HP.grey1,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
        ),
        // Customize prompt — only when mood selected
        if (activeMood != null) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _HP.card,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _HP.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.edit_note_rounded, size: 14, color: _HP.grey2),
                    SizedBox(width: 6),
                    Text(
                      'Customize prompt',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: _HP.grey1,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'Prompt edits change style and imagery — language follows your reference song.',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: _HP.grey3,
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  decoration: BoxDecoration(
                    color: _HP.background,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _HP.border),
                  ),
                  child: Theme(
                    // Force light theme on the TextField so it never inherits
                    // a dark scaffold's input decoration colors.
                    data: ThemeData(
                      brightness: Brightness.light,
                      colorScheme: const ColorScheme.light(
                        primary: _HP.black,
                        surface: _HP.background,
                      ),
                      inputDecorationTheme: const InputDecorationTheme(
                        filled: true,
                        fillColor: _HP.background,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                      ),
                    ),
                    child: TextField(
                      controller: _promptController,
                      maxLines: 3,
                      minLines: 2,
                      onChanged: widget.onPromptChanged,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: _HP.black,
                      ),
                      cursorColor: _HP.black,
                      decoration: const InputDecoration(
                        isDense: true,
                        filled: true,
                        fillColor: _HP.background,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

// ─── LOADING STEPS ────────────────────────────────────────────────────────────
class _LoadingSteps extends StatefulWidget {
  const _LoadingSteps();
  @override
  State<_LoadingSteps> createState() => _LoadingStepsState();
}

class _LoadingStepsState extends State<_LoadingSteps> {
  int _step = 0;
  final _steps = [
    '⚡ Sending to Groq…',
    '🎵 Analysing your taste…',
    '✍️ Writing your lyrics…',
    '✨ Almost ready…',
  ];

  @override
  void initState() {
    super.initState();
    _tick();
  }

  Future<void> _tick() async {
    for (var i = 1; i < _steps.length; i++) {
      await Future.delayed(const Duration(milliseconds: 1800));
      if (!mounted) return;
      setState(() => _step = i);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: Text(
          _steps[_step],
          key: ValueKey(_step),
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: _HP.grey2,
            fontStyle: FontStyle.italic,
          ),
        ),
      ),
    );
  }
}

// ─── ERROR BANNER ─────────────────────────────────────────────────────────────
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF0F0),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFFCCCC)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 16,
            color: Color(0xFFCC0000),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Color(0xFF880000),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── RESULT CARD ──────────────────────────────────────────────────────────────
class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result, required this.onCopy});
  final _SongResult result;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final lyrics =
        result.dominantLanguage == 'Hindi'
            ? result.hinglishLyrics
            : result.englishLyrics;
    return Container(
      decoration: BoxDecoration(
        color: _HP.card,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _HP.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title row
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '"${result.title}"',
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          color: _HP.black,
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          _ResultChip(label: result.mood),
                          _ResultChip(label: result.genre),
                          _ResultChip(
                            label: '${result.dominantLanguage} dominant',
                            highlight: true,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: onCopy,
                  icon: const Icon(
                    Icons.copy_rounded,
                    size: 18,
                    color: _HP.grey2,
                  ),
                ),
              ],
            ),
          ),
          // Divider
          Container(height: 1, color: _HP.border),
          // Lyrics preview
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.lyrics_outlined,
                      size: 13,
                      color: _HP.grey3,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      result.dominantLanguage == 'Hindi'
                          ? 'Hinglish Lyrics'
                          : 'English Lyrics',
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: _HP.grey2,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  lyrics.length > 400 ? '${lyrics.substring(0, 400)}…' : lyrics,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: _HP.grey1,
                    height: 1.6,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultChip extends StatelessWidget {
  const _ResultChip({required this.label, this.highlight = false});
  final String label;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: highlight ? _HP.black : _HP.chipDark,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: highlight ? Colors.white : _HP.grey1,
        ),
      ),
    );
  }
}

// ─── ACTION ROW (after result) ────────────────────────────────────────────────
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.isLoading,
    required this.onRecord,
    required this.onRegenerate,
  });
  final bool isLoading;
  final VoidCallback onRecord;
  final VoidCallback onRegenerate;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: SizedBox(
            height: 52,
            child: _HomeStyleButton(
              label: 'Record My Voice',
              icon: Icons.record_voice_over_rounded,
              filled: true,
              onPressed: isLoading ? null : onRecord,
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          height: 52,
          child: _HomeStyleButton(
            label: 'Again',
            icon: Icons.refresh_rounded,
            filled: false,
            onPressed: isLoading ? null : onRegenerate,
          ),
        ),
      ],
    );
  }
}

// ─── HOME-STYLE BUTTON ────────────────────────────────────────────────────────
class _HomeStyleButton extends StatelessWidget {
  const _HomeStyleButton({
    required this.label,
    required this.icon,
    required this.filled,
    required this.onPressed,
  });
  final String label;
  final IconData icon;
  final bool filled;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return GestureDetector(
      onTap: onPressed,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: filled ? (enabled ? _HP.black : _HP.chipDark) : _HP.chip,
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: filled ? Colors.transparent : _HP.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 16,
              color: filled ? Colors.white : (enabled ? _HP.black : _HP.grey3),
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color:
                    filled ? Colors.white : (enabled ? _HP.black : _HP.grey3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── GENERATE BUTTON (bottom bar) ────────────────────────────────────────────
class _GenerateButton extends StatelessWidget {
  const _GenerateButton({
    required this.isLoading,
    required this.mode,
    required this.pulseController,
    required this.onPressed,
  });
  final bool isLoading;
  final _GenerationMode mode;
  final AnimationController pulseController;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: AnimatedBuilder(
        animation: pulseController,
        builder: (_, __) {
          return Container(
            height: 60,
            decoration: BoxDecoration(
              color: isLoading ? _HP.blackSoft : _HP.black,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color:
                    isLoading
                        ? _HP.green.withValues(
                          alpha: 0.4 + pulseController.value * 0.4,
                        )
                        : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                isLoading
                    ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Colors.white,
                        ),
                      ),
                    )
                    : const Icon(
                      Icons.auto_awesome_rounded,
                      size: 20,
                      color: Colors.white,
                    ),
                const SizedBox(width: 10),
                Text(
                  isLoading
                      ? 'Writing your song…'
                      : mode == _GenerationMode.singleSong
                      ? 'Generate From This Song'
                      : 'Generate My Song',
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
