import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_twemoji/flutter_twemoji.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../models/song_reference.dart';
import '../constants/colors.dart';
import '../services/local_suggestions_service.dart';
import '../theme/song_creation_palette.dart';
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

// ─── HOME SCREEN PALETTE ──────────────────────────────────────────────────────
class _HP {
  static SongCreationPalette get _p => SongCreationPalette.current;

  static Color get background => _p.background;
  static Color get card => _p.card;
  static Color get border => _p.border;
  static Color get black => _p.black;
  static Color get blackSoft => _p.blackSoft;
  static Color get grey1 => _p.grey1;
  static Color get grey2 => _p.grey2;
  static Color get grey3 => _p.grey3;
  static Color get green => _p.green;
  static Color get chip => _p.chip;
  static Color get chipDark => _p.chipDark;
  static Color get onBlack => _p.onBlack;
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
  final String hinglishLyrics;
  final String englishLyrics;
  final String mood;
  final String genre;
  final String dominantLanguage;
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
      if (mounted) {
        setState(() {
          _aiSuggestedMood = null;
          _isMoodLoading = false;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _isMoodLoading = true;
        _aiSuggestedMood = null;
      });
    }
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

  // ─── LANGUAGE DETECTION ───────────────────────────────────────────────────
  bool _containsSouthAsianScript(String text) {
    for (final rune in text.runes) {
      if ((rune >= 0x0900 && rune <= 0x097F) ||
          (rune >= 0x0600 && rune <= 0x06FF)) {
        return true;
      }
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

  double _southAsianScore(RecentTrack track) {
    double score = 0.0;
    final combined =
        '${track.trackName} ${track.artistName} ${track.lyricSnippet}'
            .toLowerCase();
    if (_containsSouthAsianScript('${track.trackName}${track.lyricSnippet}')) {
      score += 0.9;
      return score.clamp(0.0, 1.0);
    }
    int wordHits = 0;
    for (final word in _hindiUrduWords) {
      if (combined.contains(word)) wordHits++;
    }
    score += (wordHits * 0.08).clamp(0.0, 0.6);
    final artistLower = track.artistName.toLowerCase();
    for (final marker in _southAsianArtistMarkers) {
      if (artistLower.contains(marker)) {
        score += 0.5;
        break;
      }
    }
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
      if (response.statusCode != 200) {
        throw Exception(
          'Groq API error ${response.statusCode}: ${response.body}',
        );
      }

      final data = json.decode(response.body);
      final raw =
          (data['choices'][0]['message']['content'] as String)
              .replaceAll(RegExp(r'```json\s*'), '')
              .replaceAll(RegExp(r'```\s*'), '')
              .trim();

      final parsed = json.decode(raw) as Map<String, dynamic>;

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
          content: Row(
            children: [
              Icon(Icons.check_circle_rounded, size: 16, color: _HP.green),
              SizedBox(width: 8),
              Text(
                'Lyrics copied!',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: _HP.onBlack,
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

  // ─── SONG PICKER MODAL ────────────────────────────────────────────────────
  void _showSongPickerModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder:
          (_) => _SongPickerSheet(
            tracks: _recentTracks,
            selectedTrack: _selectedTrack,
            onSelected: (track) {
              Navigator.of(context).pop();
              _selectTrack(track);
            },
          ),
    );
  }

  // ─── MOOD PICKER MODAL ────────────────────────────────────────────────────
  void _showMoodPickerModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder:
          (_) => _MoodPickerSheet(
            selectedMood: _selectedMood ?? _aiSuggestedMood,
            aiSuggestedMood: _aiSuggestedMood,
            onSelected: (mood) {
              Navigator.of(context).pop();
              setState(() {
                _selectedMood = mood;
                _customMoodPrompt = _getMoodPrompt(mood);
              });
            },
            onReset: () {
              Navigator.of(context).pop();
              setState(() {
                _selectedMood = null;
                _customMoodPrompt =
                    _aiSuggestedMood != null
                        ? _getMoodPrompt(_aiSuggestedMood!)
                        : null;
              });
            },
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
    final isCompact = screenWidth < 600;
    final hPad = isCompact ? screenWidth * 0.05 : screenWidth * 0.08;

    final activeMood = _selectedMood ?? _aiSuggestedMood;

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
          child: Column(
            children: [
              // ── Header ──────────────────────────────────────────────────
              Padding(
                padding: EdgeInsets.fromLTRB(hPad, 16, hPad, 12),
                child: _ScreenHeader(
                  hasResult: _result != null,
                  onCopy: _copyToClipboard,
                ),
              ),
              // ── Scrollable content ──────────────────────────────────────
              Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // ── AI Songwriting card ──────────────────────────────
                      _SongwritingCard(
                        recentTracks: _recentTracks,
                        mode: _generationMode,
                        selectedTrack: _selectedTrack,
                        onModeChanged: _setGenerationMode,
                        onPickSong: () => _showSongPickerModal(context),
                      ),
                      const SizedBox(height: 20),

                      // ── Mood row (compact dropdown) ──────────────────────
                      _MoodRow(
                        activeMood: activeMood,
                        aiSuggestedMood: _aiSuggestedMood,
                        selectedMood: _selectedMood,
                        isMoodLoading: _isMoodLoading,
                        onOpenPicker: () => _showMoodPickerModal(context),
                      ),
                      const SizedBox(height: 14),

                      // ── Customize prompt ─────────────────────────────────
                      if (activeMood != null)
                        _CustomizePromptBox(
                          activeMood: activeMood,
                          customPrompt: _customMoodPrompt,
                          onPromptChanged:
                              (p) => setState(() => _customMoodPrompt = p),
                        ),

                      // ── Loading steps ────────────────────────────────────
                      if (_isLoading) ...[
                        const SizedBox(height: 20),
                        const _LoadingSteps(),
                      ],

                      // ── Error message ────────────────────────────────────
                      if (_errorMessage != null) ...[
                        const SizedBox(height: 16),
                        _ErrorBanner(message: _errorMessage!),
                      ],

                      // ── Result card ──────────────────────────────────────
                      if (_result != null) ...[
                        const SizedBox(height: 24),
                        _ResultCard(result: _result!, onCopy: _copyToClipboard),
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
                child: Icon(
                  Icons.arrow_back_rounded,
                  size: 20,
                  color: _HP.black,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
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
                  const SizedBox(height: 3),
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

// ─── SONGWRITING CARD (compact — no song chips) ───────────────────────────────
class _SongwritingCard extends StatelessWidget {
  const _SongwritingCard({
    required this.recentTracks,
    required this.mode,
    required this.selectedTrack,
    required this.onModeChanged,
    required this.onPickSong,
  });

  final List<RecentTrack> recentTracks;
  final _GenerationMode mode;
  final RecentTrack? selectedTrack;
  final Future<void> Function(_GenerationMode) onModeChanged;
  final VoidCallback onPickSong;

  @override
  Widget build(BuildContext context) {
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
                child: Icon(
                  Icons.auto_awesome_rounded,
                  color: _HP.onBlack,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
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

          // Mode toggle
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
            // Label
            Row(
              children: [
                _emojiBadge(
                  mode == _GenerationMode.singleSong ? '🎧' : '📚',
                  size: 13,
                ),
                const SizedBox(width: 6),
                Text(
                  mode == _GenerationMode.singleSong
                      ? 'Reference song'
                      : 'Using ${recentTracks.length} tracks from your history',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _HP.grey1,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // ── Compact song picker button (single song mode) ──────────────
            if (mode == _GenerationMode.singleSong)
              GestureDetector(
                onTap: onPickSong,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: _HP.chipDark,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _HP.border),
                  ),
                  child: Row(
                    children: [
                      // Music note icon
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: _HP.chip,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Icon(
                          Icons.music_note_rounded,
                          size: 16,
                          color: _HP.grey2,
                        ),
                      ),
                      const SizedBox(width: 10),
                      // Track info
                      Expanded(
                        child:
                            selectedTrack != null
                                ? Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      selectedTrack!.trackName,
                                      style: TextStyle(
                                        fontFamily: 'Inter',
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: _HP.black,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    if (selectedTrack!
                                        .artistName
                                        .isNotEmpty) ...[
                                      const SizedBox(height: 1),
                                      Text(
                                        selectedTrack!.artistName,
                                        style: TextStyle(
                                          fontFamily: 'Inter',
                                          fontSize: 11,
                                          fontWeight: FontWeight.w500,
                                          color: _HP.grey2,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ],
                                )
                                : Text(
                                  'Choose a song…',
                                  style: TextStyle(
                                    fontFamily: 'Inter',
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: _HP.grey3,
                                  ),
                                ),
                      ),
                      const SizedBox(width: 8),
                      // "Change" label + chevron
                      Text(
                        'Change',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: _HP.grey2,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 18,
                        color: _HP.grey2,
                      ),
                    ],
                  ),
                ),
              ),

            // History mode: show a summary chip instead
            if (mode == _GenerationMode.history)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: _HP.chipDark,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _HP.border),
                ),
                child: Row(
                  children: [
                    Icon(Icons.queue_music_rounded, size: 16, color: _HP.grey2),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${recentTracks.length} recently played tracks',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _HP.grey1,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ] else ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _HP.chipDark,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded, size: 14, color: _HP.grey2),
                  const SizedBox(width: 7),
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

// ─── MODE PILL ────────────────────────────────────────────────────────────────
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
            color: active ? _HP.onBlack : _HP.grey1,
          ),
        ),
      ),
    );
  }
}

// ─── MOOD ROW (compact dropdown trigger) ─────────────────────────────────────
class _MoodRow extends StatelessWidget {
  const _MoodRow({
    required this.activeMood,
    required this.aiSuggestedMood,
    required this.selectedMood,
    required this.isMoodLoading,
    required this.onOpenPicker,
  });

  final String? activeMood;
  final String? aiSuggestedMood;
  final String? selectedMood;
  final bool isMoodLoading;
  final VoidCallback onOpenPicker;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section title row
        Row(
          children: [
            Text(
              'Mood',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 16,
                fontWeight: FontWeight.w900,
                color: _HP.black,
              ),
            ),
            const SizedBox(width: 8),
            if (isMoodLoading)
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: _HP.black,
                ),
              )
            else if (aiSuggestedMood != null && selectedMood == null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _HP.green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _HP.green.withValues(alpha: 0.4)),
                ),
                child: Text(
                  'AI picked',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: AppColors.accentStrong,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),

        // Compact dropdown trigger button
        GestureDetector(
          onTap: onOpenPicker,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: _HP.card,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _HP.border),
            ),
            child: Row(
              children: [
                if (activeMood != null) ...[
                  _emojiBadge(_getMoodEmoji(activeMood!), size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      activeMood!,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: _HP.black,
                      ),
                    ),
                  ),
                ] else ...[
                  Icon(Icons.mood_rounded, size: 18, color: _HP.grey3),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      isMoodLoading ? 'Detecting mood…' : 'Select a mood',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: _HP.grey3,
                      ),
                    ),
                  ),
                ],
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 20,
                  color: _HP.grey2,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ─── CUSTOMIZE PROMPT BOX ─────────────────────────────────────────────────────
class _CustomizePromptBox extends StatefulWidget {
  const _CustomizePromptBox({
    required this.activeMood,
    required this.customPrompt,
    required this.onPromptChanged,
  });
  final String activeMood;
  final String? customPrompt;
  final void Function(String) onPromptChanged;

  @override
  State<_CustomizePromptBox> createState() => _CustomizePromptBoxState();
}

class _CustomizePromptBoxState extends State<_CustomizePromptBox> {
  late TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(
      text: widget.customPrompt ?? _getMoodPrompt(widget.activeMood),
    );
  }

  @override
  void didUpdateWidget(_CustomizePromptBox old) {
    super.didUpdateWidget(old);
    if (widget.activeMood != old.activeMood ||
        (widget.customPrompt != null && widget.customPrompt != _ctrl.text)) {
      _ctrl.text = widget.customPrompt ?? _getMoodPrompt(widget.activeMood);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _HP.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _HP.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.edit_note_rounded, size: 14, color: _HP.grey2),
              const SizedBox(width: 6),
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
          Text(
            'Prompt edits change style and imagery — language follows your reference song.',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: _HP.grey3,
            ),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: TextField(
              controller: _ctrl,
              maxLines: 3,
              minLines: 2,
              onChanged: widget.onPromptChanged,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: _HP.black,
              ),
              cursorColor: _HP.black,
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: _HP.background,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: _HP.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: _HP.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: _HP.border, width: 1.5),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── SONG PICKER BOTTOM SHEET ─────────────────────────────────────────────────
class _SongPickerSheet extends StatefulWidget {
  const _SongPickerSheet({
    required this.tracks,
    required this.selectedTrack,
    required this.onSelected,
  });
  final List<RecentTrack> tracks;
  final RecentTrack? selectedTrack;
  final void Function(RecentTrack) onSelected;

  @override
  State<_SongPickerSheet> createState() => _SongPickerSheetState();
}

class _SongPickerSheetState extends State<_SongPickerSheet> {
  late List<RecentTrack> _filtered;
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _filtered = widget.tracks;
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _filter(String q) {
    final ql = q.toLowerCase();
    setState(() {
      _filtered =
          q.isEmpty
              ? widget.tracks
              : widget.tracks.where((t) {
                return t.trackName.toLowerCase().contains(ql) ||
                    t.artistName.toLowerCase().contains(ql);
              }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Container(
      height: mq.size.height * 0.75,
      decoration: BoxDecoration(
        color: _HP.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        border: Border.all(color: _HP.border),
      ),
      child: Column(
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 4),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: _HP.border,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Choose a reference song',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      color: _HP.black,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: _HP.chipDark,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.close_rounded,
                      size: 15,
                      color: _HP.grey1,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Search
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: TextField(
                controller: _searchCtrl,
                onChanged: _filter,
                autofocus: false,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 14,
                  color: _HP.black,
                ),
                cursorColor: _HP.black,
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: _HP.background,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 11,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: _HP.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: _HP.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: _HP.border, width: 1.5),
                  ),
                  hintText: 'Search songs…',
                  hintStyle: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    color: _HP.grey3,
                  ),
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    size: 18,
                    color: _HP.grey2,
                  ),
                ),
              ),
            ),
          ),
          // Track count hint
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${_filtered.length} song${_filtered.length == 1 ? '' : 's'}',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: _HP.grey3,
                ),
              ),
            ),
          ),
          // Divider
          Container(height: 1, color: _HP.border),
          // List
          Expanded(
            child:
                _filtered.isEmpty
                    ? Center(
                      child: Text(
                        'No songs found',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 13,
                          color: _HP.grey3,
                        ),
                      ),
                    )
                    : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      itemCount: _filtered.length,
                      itemBuilder: (context, i) {
                        final track = _filtered[i];
                        final isSelected =
                            widget.selectedTrack?.trackName ==
                                track.trackName &&
                            widget.selectedTrack?.artistName ==
                                track.artistName;
                        return _SongPickerItem(
                          track: track,
                          index: widget.tracks.indexOf(track),
                          isSelected: isSelected,
                          onTap: () => widget.onSelected(track),
                        );
                      },
                    ),
          ),
          SizedBox(height: mq.padding.bottom + 8),
        ],
      ),
    );
  }
}

class _SongPickerItem extends StatelessWidget {
  const _SongPickerItem({
    required this.track,
    required this.index,
    required this.isSelected,
    required this.onTap,
  });
  final RecentTrack track;
  final int index;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? _HP.black : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            // Index badge
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color:
                    isSelected
                        ? _HP.onBlack.withValues(alpha: 0.15)
                        : _HP.chipDark,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Center(
                child: Text(
                  '${index + 1}',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: isSelected ? _HP.onBlack : _HP.grey2,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            // Track info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.trackName,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: isSelected ? _HP.onBlack : _HP.black,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (track.artistName.isNotEmpty) ...[
                    const SizedBox(height: 1),
                    Text(
                      track.artistName,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color:
                            isSelected
                                ? _HP.onBlack.withValues(alpha: 0.6)
                                : _HP.grey2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            // Checkmark
            if (isSelected)
              Icon(Icons.check_circle_rounded, size: 18, color: _HP.onBlack),
          ],
        ),
      ),
    );
  }
}

// ─── MOOD PICKER BOTTOM SHEET ─────────────────────────────────────────────────
class _MoodPickerSheet extends StatelessWidget {
  const _MoodPickerSheet({
    required this.selectedMood,
    required this.aiSuggestedMood,
    required this.onSelected,
    required this.onReset,
  });
  final String? selectedMood;
  final String? aiSuggestedMood;
  final void Function(String) onSelected;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Container(
      decoration: BoxDecoration(
        color: _HP.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        border: Border.all(color: _HP.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 4),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: _HP.border,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Select mood',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      color: _HP.black,
                    ),
                  ),
                ),
                // Reset to AI button (only when user has manually selected)
                if (selectedMood != null && aiSuggestedMood != null)
                  GestureDetector(
                    onTap: onReset,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: _HP.green.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: _HP.green.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Text(
                        'Reset to AI',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.accentStrong,
                        ),
                      ),
                    ),
                  ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: _HP.chipDark,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.close_rounded,
                      size: 15,
                      color: _HP.grey1,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          // Mood 2-column grid
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
            child: GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                childAspectRatio: 3.2,
              ),
              itemCount: _moods.length,
              itemBuilder: (context, i) {
                final mood = _moods[i];
                final isActive = selectedMood == mood;
                final isAiPicked =
                    aiSuggestedMood == mood && selectedMood == null;
                return GestureDetector(
                  onTap: () => onSelected(mood),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: isActive ? _HP.black : _HP.chipDark,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color:
                            isAiPicked
                                ? _HP.green.withValues(alpha: 0.5)
                                : isActive
                                ? _HP.black
                                : _HP.border,
                        width: isAiPicked ? 1.5 : 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        _emojiBadge(_getMoodEmoji(mood), size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            mood,
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: isActive ? _HP.onBlack : _HP.grey1,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isAiPicked)
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: _HP.green,
                              shape: BoxShape.circle,
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          SizedBox(height: mq.padding.bottom + 8),
        ],
      ),
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
          style: TextStyle(
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
                        style: TextStyle(
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
                  icon: Icon(Icons.copy_rounded, size: 18, color: _HP.grey2),
                ),
              ],
            ),
          ),
          // Divider
          Container(height: 1, color: _HP.border),
          // Lyrics
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.lyrics_outlined, size: 13, color: _HP.grey3),
                    const SizedBox(width: 5),
                    Text(
                      result.dominantLanguage == 'Hindi'
                          ? 'Hinglish Lyrics'
                          : 'English Lyrics',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: _HP.grey2,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SelectableText(
                  lyrics,
                  style: TextStyle(
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
          color: highlight ? _HP.onBlack : _HP.grey1,
        ),
      ),
    );
  }
}

// ─── ACTION ROW ───────────────────────────────────────────────────────────────
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
              color: filled ? _HP.onBlack : (enabled ? _HP.black : _HP.grey3),
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: filled ? _HP.onBlack : (enabled ? _HP.black : _HP.grey3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── GENERATE BUTTON ─────────────────────────────────────────────────────────
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
                        valueColor: AlwaysStoppedAnimation<Color>(_HP.onBlack),
                      ),
                    )
                    : Icon(
                      Icons.auto_awesome_rounded,
                      size: 20,
                      color: _HP.onBlack,
                    ),
                const SizedBox(width: 10),
                Text(
                  isLoading
                      ? 'Writing your song…'
                      : mode == _GenerationMode.singleSong
                      ? 'Generate From This Song'
                      : 'Generate My Song',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                    color: _HP.onBlack,
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
