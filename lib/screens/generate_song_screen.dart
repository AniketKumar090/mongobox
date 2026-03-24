import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_twemoji/flutter_twemoji.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../models/song_reference.dart';
import '../services/local_suggestions_service.dart';
import 'voice_sample_screen.dart';

// ─── MOOD OPTIONS ─────────────────────────────────────────────────────────────
const _moodData = <String, _MoodInfo>{
  'Energetic':  _MoodInfo(emoji: '⚡',  prompt: 'High-energy vibes: upbeat tempo, powerful delivery, motivational or hype lyrics with strong rhythmic punchlines'),
  'Melancholic':_MoodInfo(emoji: '🌧️', prompt: 'Reflective and somber: introspective lyrics about loss, longing, or sadness with emotional depth'),
  'Euphoric':   _MoodInfo(emoji: '🌟', prompt: 'Uplifting and triumphant: celebratory lyrics about success, joy, or breakthrough moments with soaring energy'),
  'Dreamy':     _MoodInfo(emoji: '☁️', prompt: 'Ethereal and atmospheric: abstract imagery, soft flow, surreal or poetic expressions about aspirations or fantasies'),
  'Heartbreak': _MoodInfo(emoji: '💔', prompt: 'Raw emotional pain: lyrics about betrayal, separation, or unrequited love with vulnerable storytelling'),
  'Intense':    _MoodInfo(emoji: '🔥', prompt: 'Aggressive and hard-hitting: bold lyrics with sharp wordplay, confrontation, or raw emotion delivered with force'),
  'Chill':      _MoodInfo(emoji: '🍃', prompt: 'Laid-back and relaxed: smooth flow, mellow vibes, lyrics about unwinding, reflection, or easy-going moments'),
  'Romantic':   _MoodInfo(emoji: '💕', prompt: 'Love and affection: tender lyrics about connection, intimacy, devotion, or relationship warmth'),
};

class _MoodInfo {
  const _MoodInfo({required this.emoji, required this.prompt});
  final String emoji;
  final String prompt;
}

List<String> get _moods => _moodData.keys.toList();
String _getMoodEmoji(String mood) => _moodData[mood]?.emoji ?? '🎵';
String _getMoodPrompt(String mood) => _moodData[mood]?.prompt ?? '';

Widget _emojiBadge(String emoji, {double size = 18}) {
  return Twemoji(
    emoji: emoji,
    width: size,
    height: size,
  );
}

// ─── RESULT MODEL ─────────────────────────────────────────────────────────────
class _SongResult {
  const _SongResult({
    required this.title,
    required this.hindiLyrics,
    required this.englishLyrics,
    required this.mood,
    required this.genre,
    required this.dominantLanguage,
    this.referenceSong,
    this.hinglishLyrics,
  });

  final String title;
  final String hindiLyrics;
  final String englishLyrics;
  final String mood;
  final String genre;
  final String dominantLanguage;
  final SongReference? referenceSong;
  final String? hinglishLyrics;

  String get primaryLyrics =>
      dominantLanguage == 'Hindi' ? hindiLyrics : englishLyrics;
  String get secondaryLyrics =>
      dominantLanguage == 'Hindi' ? englishLyrics : hindiLyrics;
  String get secondaryLanguage =>
      dominantLanguage == 'Hindi' ? 'English' : 'Hindi';

  String get fullText =>
      '"$title"\nDominant: $dominantLanguage | Mood: $mood | Genre: $genre\n\n'
      '── Hindi ──\n$hindiLyrics\n\n── English ──\n$englishLyrics';
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

  late AnimationController _shimmerController;

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _loadTracksAndSuggestMood();
  }

  @override
  void dispose() {
    _shimmerController.dispose();
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
      if (mounted) setState(() { _aiSuggestedMood = null; _isMoodLoading = false; });
      return;
    }
    if (mounted) setState(() { _isMoodLoading = true; _aiSuggestedMood = null; });
    try {
      final mood = await _detectMood(tracks);
      if (mounted) setState(() => _aiSuggestedMood = mood);
    } catch (_) {}
    finally {
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
                    'You are a music mood analyst. Reply with ONLY one word from: '
                    'Energetic, Melancholic, Euphoric, Dreamy, Heartbreak, Intense, Chill, Romantic. '
                    'No punctuation, nothing else.',
              },
              {
                'role': 'user',
                'content': 'Based on these songs, what is the dominant mood? $trackList',
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

  Future<void> _generate() async {
    if (_isLoading) return;
    final referenceTracks = _analysisTracks;
    if (referenceTracks.isEmpty) {
      setState(() {
        _errorMessage = _generationMode == _GenerationMode.singleSong
            ? 'Pick a reference song first.'
            : 'No listening history yet — play a few songs first!';
      });
      return;
    }

    final mood = _selectedMood ?? _aiSuggestedMood ?? 'Chill';
    final apiKey = dotenv.env['GROQ_API_KEY'] ?? '';
    if (apiKey.isEmpty) {
      setState(() {
        _errorMessage = 'GROQ_API_KEY not set in .env\nGet a free key at console.groq.com';
      });
      return;
    }

    setState(() { _isLoading = true; _errorMessage = null; _result = null; });

    final trackList = referenceTracks
        .take(20)
        .map((t) => '${t.trackName} – ${t.artistName}')
        .join('\n');
    final selectedReference = _selectedTrack;
    final moodPrompt = _customMoodPrompt;

    final isEnglishDominant = _generationMode == _GenerationMode.singleSong
        ? _isEnglishDominantTrack(selectedReference!)
        : _isEnglishDominantTracks(referenceTracks);

    final prompt = _generationMode == _GenerationMode.singleSong
        ? _buildSingleSongPrompt(
            mood: mood,
            moodPrompt: moodPrompt,
            reference: selectedReference!,
            isEnglishDominant: isEnglishDominant,
          )
        : _buildHistoryPrompt(
            mood: mood,
            moodPrompt: moodPrompt,
            trackList: trackList,
            isEnglishDominant: isEnglishDominant,
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
                      'You are a bilingual Hindi-English hip-hop / rap songwriter. '
                      'Write lyrics with clear rhythm, rhyme, and poetic imagery (metaphor, wordplay, punchlines). '
                      'Always respond with valid JSON only. No markdown.',
                },
                {'role': 'user', 'content': prompt},
              ],
            }),
          )
          .timeout(const Duration(seconds: 40));

      if (!mounted) return;
      if (response.statusCode != 200) {
        throw Exception('Groq API error ${response.statusCode}: ${response.body}');
      }

      final data = json.decode(response.body);
      final raw = (data['choices'][0]['message']['content'] as String)
          .replaceAll(RegExp(r'```json\s*'), '')
          .replaceAll(RegExp(r'```\s*'), '')
          .trim();

      final parsed = json.decode(raw) as Map<String, dynamic>;
      
      // Determine dominant language from the generated lyrics
      final hindiLyrics = (parsed['hindi_lyrics'] ?? '') as String? ?? '';
      final hinglishLyrics = (parsed['hinglish_lyrics'] ?? '') as String? ?? '';
      final englishLyrics = (parsed['english_lyrics'] ?? '') as String? ?? '';
      
      // If hindi_lyrics has content, it's Hindi dominant; otherwise English dominant
      final isHindiDominant = hindiLyrics.trim().isNotEmpty;
      final dominantLanguage = isHindiDominant ? 'Hindi' : 'English';

      final result = _SongResult(
        title: parsed['title'] as String? ?? 'Untitled',
        hindiLyrics: hindiLyrics,
        englishLyrics: englishLyrics,
        mood: parsed['mood'] as String? ?? mood,
        genre: parsed['genre'] as String? ?? '',
        dominantLanguage: dominantLanguage,
        referenceSong: selectedReference == null
            ? null
            : SongReference(
                trackName: selectedReference.trackName,
                artistName: selectedReference.artistName,
                lyricSnippet: selectedReference.lyricSnippet,
                videoId: selectedReference.videoId,
                startTimeSeconds: selectedReference.startTimeSeconds,
              ),
        hinglishLyrics: hinglishLyrics,
      );

      if (!mounted) return;
      setState(() { _result = result; _isLoading = false; });
      
      // Automatically navigate to VoiceSampleScreen with generated lyrics
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => VoiceSampleScreen(
            songTitle: result.title,
            hindiLyrics: result.hindiLyrics,
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Lyrics copied!'),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  void _openVoiceClone() {
    final r = _result;
    if (r == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VoiceSampleScreen(
          songTitle: r.title,
          hindiLyrics: r.hindiLyrics,
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

  String _buildHistoryPrompt({
    required String mood,
    required String? moodPrompt,
    required String trackList,
    required bool isEnglishDominant,
  }) {
    final moodInfo = moodPrompt != null && moodPrompt.isNotEmpty
        ? 'Mood instructions: $moodPrompt\n'
        : 'Requested mood: $mood\n';

    if (isEnglishDominant) {
      return _buildEnglishDominantPrompt(mood: mood, moodInfo: moodInfo, trackList: trackList, isHistory: true);
    } else {
      return _buildHindiDominantPrompt(mood: mood, moodInfo: moodInfo, trackList: trackList, isHistory: true);
    }
  }

  String _buildSingleSongPrompt({
    required String mood,
    required String? moodPrompt,
    required RecentTrack reference,
    required bool isEnglishDominant,
  }) {
    final snippet = reference.lyricSnippet.trim();
    final moodInfo = moodPrompt != null && moodPrompt.isNotEmpty
        ? 'Mood instructions: $moodPrompt\n'
        : 'Requested mood: $mood\n';

    if (isEnglishDominant) {
      return _buildEnglishDominantPrompt(
        mood: mood,
        moodInfo: moodInfo,
        trackList: '${reference.trackName} – ${reference.artistName}',
        isHistory: false,
        snippet: snippet,
      );
    } else {
      return _buildHindiDominantPrompt(
        mood: mood,
        moodInfo: moodInfo,
        trackList: '${reference.trackName} – ${reference.artistName}',
        isHistory: false,
        snippet: snippet,
      );
    }
  }

  bool _containsSouthAsianScript(String text) {
    for (final rune in text.runes) {
      if ((rune >= 0x0900 && rune <= 0x097F) ||
          (rune >= 0x0600 && rune <= 0x06FF)) {
        return true;
      }
    }
    return false;
  }

  bool _looksHindiOrUrduText(String text) {
    if (text.trim().isEmpty) return false;
    if (_containsSouthAsianScript(text)) return true;

    final lower = text.toLowerCase();
    const southAsianMarkers = [
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
    ];
    return southAsianMarkers.any(lower.contains);
  }

  bool _isEnglishDominantTrack(RecentTrack track) {
    final combined = [
      track.trackName,
      track.artistName,
      track.lyricSnippet,
    ].join(' ');
    return !_looksHindiOrUrduText(combined);
  }

  bool _isEnglishDominantTracks(List<RecentTrack> tracks) {
    if (tracks.isEmpty) return false;
    final englishCount =
        tracks.where(_isEnglishDominantTrack).length;
    return englishCount >= ((tracks.length + 1) ~/ 2);
  }

  String _buildHindiDominantPrompt({
    required String mood,
    required String moodInfo,
    required String trackList,
    required bool isHistory,
    String? snippet,
  }) {
    final referenceInfo = isHistory 
        ? 'Listening history:\n$trackList\n\n'
        : 'Reference song: $trackList\n${snippet != null && snippet.isNotEmpty ? 'Lyric snippet: $snippet\n' : ''}';
    
    return 'You are a bilingual Hindi-English hip-hop / rap songwriter.\n\n'
        '$referenceInfo'
        '$moodInfo\n'
        'Rules:\n'
        '- Write COMPLETELY ORIGINAL bilingual lyrics with HINDI as the dominant language\n'
        '- Strong rhythm, end rhymes, internal rhymes where natural, and vivid poetry (imagery, wordplay, punchlines)\n'
        '- Use a consistent bar feel: similar syllable counts per line within each verse\n'
        '- Write TWO Hindi versions of the same lyrics: (1) Devanagari Hindi and (2) Hinglish (Romanized Hindi)\n'
        '- Keep meaning, rhyme scheme, and section structure aligned across Devanagari and Hinglish\n'
        '- Hinglish should be natural and rap-ready (e.g., "Meri jaan", "Tere bina adhoora hoon")\n'
        '- You can include some English words/phrases for flavor, but Hindi should dominate (70-80% Hindi)\n'
        '- Section headers ([Intro], [Verse 1], [Hook], [Verse 2], [Bridge], [Outro]) always in English — use [Hook] instead of [Chorus] for the main refrain\n'
        '- Lyrics must be vivid, emotional, specific — no generic filler\n'
        '- Title: 2–4 words, bilingual style (e.g. "Dil ki Beat" or "Roshan Nights")\n\n'
        'Respond ONLY with this JSON (no markdown):\n'
        '{"title":"...","mood":"$mood","genre":"Hip-hop",'
        '"hindi_lyrics":"[Verse 1]\\nदेवनागरी पंक्ति\\n\\n[Hook]\\nदेवनागरी पंक्ति\\n\\n[Verse 2]\\nदेवनागरी पंक्ति\\n\\n[Bridge]\\nदेवनागरी पंक्ति\\n\\n[Outro]\\nदेवनागरी पंक्ति",'
        '"hinglish_lyrics":"[Verse 1]\\nHinglish line\\n\\n[Hook]\\nHinglish line\\n\\n[Verse 2]\\nHinglish line\\n\\n[Bridge]\\nHinglish line\\n\\n[Outro]\\nHinglish line",'
        '"english_lyrics":"[Verse 1]\\nline\\n\\n[Hook]\\nline\\n\\n[Verse 2]\\nline\\n\\n[Bridge]\\nline\\n\\n[Outro]\\nline"}';
  }

  String _buildEnglishDominantPrompt({
    required String mood,
    required String moodInfo,
    required String trackList,
    required bool isHistory,
    String? snippet,
  }) {
    final referenceInfo = isHistory 
        ? 'Listening history:\n$trackList\n\n'
        : 'Reference song: $trackList\n${snippet != null && snippet.isNotEmpty ? 'Lyric snippet: $snippet\n' : ''}';
    
    return 'You are an English hip-hop / rap songwriter with British accent and flow.\n\n'
        '$referenceInfo'
        '$moodInfo\n'
        'Rules:\n'
        '- Write COMPLETELY ORIGINAL lyrics in PURE ENGLISH only\n'
        '- Use British English spelling, vocabulary, and accent (e.g., "colour" not "color", "favourite" not "favorite")\n'
        '- Strong rhythm, end rhymes, internal rhymes where natural, and vivid poetry (imagery, wordplay, punchlines)\n'
        '- Use a consistent bar feel: similar syllable counts per line within each verse\n'
        '- NO Hindi words, NO Hinglish, NO Indian language mixing — pure English only\n'
        '- Section headers ([Intro], [Verse 1], [Hook], [Verse 2], [Bridge], [Outro]) always in English — use [Hook] instead of [Chorus] for the main refrain\n'
        '- Lyrics must be vivid, emotional, specific — no generic filler\n'
        '- Title: 2–4 words, English style (e.g. "London Nights" or "Mid rain")\n\n'
        'Respond ONLY with this JSON (no markdown):\n'
        '{"title":"...","mood":"$mood","genre":"Hip-hop",'
        '"hindi_lyrics":"","'
        '"hinglish_lyrics":"",'
        '"english_lyrics":"[Verse 1]\\nBritish English line\\n\\n[Hook]\\nBritish English line\\n\\n[Verse 2]\\nBritish English line\\n\\n[Bridge]\\nBritish English line\\n\\n[Outro]\\nBritish English line"}';
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: const Text('My Song'),
        centerTitle: true,
        backgroundColor: cs.inverseSurface,
        foregroundColor: cs.onInverseSurface,
        elevation: 0,
        actions: [
          if (_result != null)
            IconButton(
              icon: const Icon(Icons.copy_rounded),
              tooltip: 'Copy lyrics',
              onPressed: _copyToClipboard,
            ),
        ],
      ),

      // ────────────────────────────────────────────────────────────────────────
      // KEY LAYOUT: scrollable content above + fixed generate button below
      // ────────────────────────────────────────────────────────────────────────
      body: GestureDetector(
        // Tap anywhere outside the TextField → dismiss keyboard / unfocus
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.opaque,
        child: SafeArea(
          child: Column(
            children: [
              // ── All scrollable content lives here ──────────────────────────
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Header card
                      _HeaderCard(
                        recentTracks: _recentTracks,
                        mode: _generationMode,
                        selectedTrack: _selectedTrack,
                        onModeChanged: _setGenerationMode,
                        onTrackSelected: _selectTrack,
                        cs: cs,
                        tt: tt,
                      ),

                      const SizedBox(height: 24),

                      // Mood selector
                      _MoodSelector(
                        aiSuggestedMood: _aiSuggestedMood,
                        selectedMood: _selectedMood,
                        isMoodLoading: _isMoodLoading,
                        customPrompt: _customMoodPrompt,
                        onMoodSelected: (mood) => setState(() {
                          _selectedMood = _selectedMood == mood ? null : mood;
                        }),
                        onPromptChanged: (prompt) =>
                            setState(() => _customMoodPrompt = prompt),
                        cs: cs,
                        tt: tt,
                      ),

                      // Loading steps
                      if (_isLoading) ...[
                        const SizedBox(height: 16),
                        const _LoadingSteps(),
                      ],

                      // Error
                      if (_errorMessage != null) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: cs.errorContainer,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.error_outline,
                                  color: cs.error, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _errorMessage!,
                                  style: tt.bodySmall?.copyWith(
                                      color: cs.onErrorContainer),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      // Result card + post-generation actions
                      if (_result != null) ...[
                        const SizedBox(height: 28),
                        _ResultCard(
                          result: _result!,
                          onCopy: _copyToClipboard,
                          cs: cs,
                          tt: tt,
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _isLoading ? null : _openVoiceClone,
                          style: FilledButton.styleFrom(
                            padding:
                                const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                          icon: const Icon(Icons.record_voice_over_rounded),
                          label: const Text('Record My Voice'),
                        ),
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: _isLoading ? null : _generate,
                          style: OutlinedButton.styleFrom(
                            padding:
                                const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('Generate Another'),
                        ),
                      ],

                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),

              // ── FIXED GENERATE BUTTON — pinned to bottom, always visible ──
              Container(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
                decoration: BoxDecoration(
                  color: cs.surface,
                  border: Border(
                    top: BorderSide(
                      color: cs.outline.withValues(alpha: 0.15),
                      width: 1,
                    ),
                  ),
                ),
                child: AnimatedBuilder(
                  animation: _shimmerController,
                  builder: (context, _) => SizedBox(
                    height: 64,
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _isLoading ? null : _generate,
                      style: FilledButton.styleFrom(
                        backgroundColor: Color.lerp(
                          cs.primary,
                          cs.tertiary,
                          _isLoading ? _shimmerController.value : 0,
                        ),
                        foregroundColor: cs.onPrimary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                        elevation: _isLoading ? 0 : 4,
                      ),
                      icon: _isLoading
                          ? SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: cs.onPrimary,
                              ),
                            )
                          : const Icon(Icons.auto_awesome, size: 22),
                      label: Text(
                        _isLoading
                            ? 'Writing your song…'
                            : _generationMode == _GenerationMode.singleSong
                                ? 'Generate From This Song'
                                : 'Generate My Song',
                        style: tt.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: cs.onPrimary,
                        ),
                      ),
                    ),
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

// ─── HEADER CARD ──────────────────────────────────────────────────────────────
class _HeaderCard extends StatelessWidget {
  const _HeaderCard({
    required this.recentTracks,
    required this.mode,
    required this.selectedTrack,
    required this.onModeChanged,
    required this.onTrackSelected,
    required this.cs,
    required this.tt,
  });
  final List<RecentTrack> recentTracks;
  final _GenerationMode mode;
  final RecentTrack? selectedTrack;
  final Future<void> Function(_GenerationMode) onModeChanged;
  final Future<void> Function(RecentTrack) onTrackSelected;
  final ColorScheme cs;
  final TextTheme tt;

  @override
  Widget build(BuildContext context) {
    final visibleTracks = mode == _GenerationMode.singleSong
        ? recentTracks.take(3).toList()
        : recentTracks;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [cs.primaryContainer, cs.secondaryContainer],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.auto_awesome, color: cs.primary, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'AI Songwriting',
                      style: tt.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: cs.onPrimaryContainer,
                      ),
                    ),
                    Text(
                      'Hindi lyrics • Powered by Groq',
                      style: tt.bodySmall?.copyWith(
                        color: cs.onPrimaryContainer.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _ModeChip(
                label: 'One Song',
                isActive: mode == _GenerationMode.singleSong,
                onTap: () => onModeChanged(_GenerationMode.singleSong),
                cs: cs,
                tt: tt,
              ),
              _ModeChip(
                label: 'History',
                isActive: mode == _GenerationMode.history,
                onTap: () => onModeChanged(_GenerationMode.history),
                cs: cs,
                tt: tt,
              ),
            ],
          ),
          if (recentTracks.isNotEmpty) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                _emojiBadge(
                  mode == _GenerationMode.singleSong ? '🎧' : '📚',
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    mode == _GenerationMode.singleSong
                        ? 'Choose a reference song'
                        : 'Using ${recentTracks.length} tracks from your history',
                    style: tt.labelMedium?.copyWith(
                      color: cs.onPrimaryContainer.withValues(alpha: 0.8),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: visibleTracks.map((t) {
                final isSelected = mode == _GenerationMode.singleSong &&
                    selectedTrack?.trackName == t.trackName &&
                    selectedTrack?.artistName == t.artistName;
                return GestureDetector(
                  onTap: mode == _GenerationMode.singleSong
                      ? () => onTrackSelected(t)
                      : null,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? cs.primary.withValues(alpha: 0.2)
                          : cs.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isSelected
                            ? cs.primary
                            : cs.primary.withValues(alpha: 0.08),
                      ),
                    ),
                    child: Text(
                      '${t.trackName}${t.artistName.isEmpty ? '' : ' • ${t.artistName}'}',
                      style: tt.labelSmall?.copyWith(
                        color: cs.onPrimaryContainer,
                        fontWeight:
                            isSelected ? FontWeight.bold : FontWeight.normal,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                );
              }).toList(),
            ),
            if (mode == _GenerationMode.singleSong &&
                selectedTrack != null) ...[
              const SizedBox(height: 10),
              Text(
                'Reference: ${selectedTrack!.trackName} by ${selectedTrack!.artistName}',
                style: tt.bodySmall?.copyWith(
                  color: cs.onPrimaryContainer.withValues(alpha: 0.85),
                ),
              ),
            ],
          ] else ...[
            const SizedBox(height: 12),
            Text(
              'Play some songs first to build your taste profile.',
              style: tt.bodySmall?.copyWith(
                color: cs.onPrimaryContainer.withValues(alpha: 0.7),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.label,
    required this.isActive,
    required this.onTap,
    required this.cs,
    required this.tt,
  });
  final String label;
  final bool isActive;
  final VoidCallback onTap;
  final ColorScheme cs;
  final TextTheme tt;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isActive ? cs.primary : cs.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: isActive
                ? cs.primary
                : cs.primary.withValues(alpha: 0.18),
          ),
        ),
        child: Text(
          label,
          style: tt.labelMedium?.copyWith(
            color: isActive ? cs.onPrimary : cs.onPrimaryContainer,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

// ─── MOOD SELECTOR ────────────────────────────────────────────────────────────
class _MoodSelector extends StatefulWidget {
  const _MoodSelector({
    required this.aiSuggestedMood,
    required this.selectedMood,
    required this.isMoodLoading,
    required this.customPrompt,
    required this.onMoodSelected,
    required this.onPromptChanged,
    required this.cs,
    required this.tt,
  });
  final String? aiSuggestedMood;
  final String? selectedMood;
  final bool isMoodLoading;
  final String? customPrompt;
  final void Function(String) onMoodSelected;
  final void Function(String) onPromptChanged;
  final ColorScheme cs;
  final TextTheme tt;

  @override
  State<_MoodSelector> createState() => _MoodSelectorState();
}

class _MoodSelectorState extends State<_MoodSelector> {
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
  void didUpdateWidget(_MoodSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    final activeMood = widget.selectedMood ?? widget.aiSuggestedMood;
    if (activeMood != _lastActiveMood) {
      _lastActiveMood = activeMood;
      if (activeMood != null) {
        _promptController.text =
            widget.customPrompt ?? _getMoodPrompt(activeMood);
      }
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
        // Label row
        Row(
          children: [
            Text(
              'Mood',
              style: widget.tt.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 8),
            if (widget.isMoodLoading)
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: widget.cs.primary),
              )
            else if (widget.aiSuggestedMood != null &&
                widget.selectedMood == null)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: widget.cs.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'AI picked',
                  style: widget.tt.labelSmall
                      ?.copyWith(color: widget.cs.onPrimaryContainer),
                ),
              ),
            if (widget.selectedMood != null) ...[
              const Spacer(),
              GestureDetector(
                onTap: () => widget.onMoodSelected(widget.selectedMood!),
                child: Text(
                  'Reset to AI',
                  style: widget.tt.labelSmall?.copyWith(
                    color: widget.cs.primary,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),

        // Mood chips
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _moods.map((mood) {
            final emoji = _getMoodEmoji(mood);
            final isActive = activeMood == mood;
            return GestureDetector(
              onTap: () => widget.onMoodSelected(mood),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: isActive
                      ? widget.cs.primary
                      : widget.cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: isActive
                        ? widget.cs.primary
                        : widget.cs.outline.withValues(alpha: 0.3),
                    width: isActive ? 2 : 1,
                  ),
                ),
                // ── EMOJI FIX: render emoji in a plain TextStyle with no
                //    dependence on the pixel font. Twemoji gives us a
                //    consistent emoji widget while the mood label stays themed.
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _emojiBadge(emoji, size: 10),
                    const SizedBox(width: 8),
                    Text(
                      mood,
                      style: widget.tt.labelMedium?.copyWith(
                        color: isActive
                            ? widget.cs.onPrimary
                            : widget.cs.onSurface,
                        fontWeight:
                            isActive ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),

        // Custom prompt editor
        if (activeMood != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: widget.cs.primaryContainer.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: widget.cs.primary.withValues(alpha: 0.2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.edit_note,
                        size: 16, color: widget.cs.primary),
                    const SizedBox(width: 8),
                    Text(
                      'Customize prompt',
                      style: widget.tt.labelSmall?.copyWith(
                        color: widget.cs.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: widget.cs.secondaryContainer.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: widget.cs.secondary.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, size: 14, color: widget.cs.secondary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Prompt edits change style and imagery, but the song language follows your reference song.',
                          style: widget.tt.bodySmall?.copyWith(
                            color: widget.cs.onSurfaceVariant,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _promptController,
                  maxLines: 3,
                  minLines: 2,
                  onChanged: widget.onPromptChanged,
                  style: widget.tt.bodySmall
                      ?.copyWith(color: widget.cs.onSurface),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                          color: widget.cs.outline
                              .withValues(alpha: 0.3)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                          color: widget.cs.outline
                              .withValues(alpha: 0.3)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                          color: widget.cs.primary, width: 2),
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
    '✍️ Writing your Hindi lyrics…',
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
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: Text(
        _steps[_step],
        key: ValueKey(_step),
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
      ),
    );
  }
}

// ─── RESULT CARD ──────────────────────────────────────────────────────────────
class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.result,
    required this.onCopy,
    required this.cs,
    required this.tt,
  });
  final _SongResult result;
  final VoidCallback onCopy;
  final ColorScheme cs;
  final TextTheme tt;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '"${result.title}"',
                      style: tt.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: cs.onSurface,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy_rounded),
                    onPressed: onCopy,
                    color: cs.primary,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  _Chip(icon: Icons.mood, label: result.mood, cs: cs),
                  _Chip(
                      icon: Icons.library_music,
                      label: result.genre,
                      cs: cs),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: cs.primary.withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.star_rounded,
                            size: 12, color: cs.primary),
                        const SizedBox(width: 4),
                        Text(
                          '${result.dominantLanguage} dominant',
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.primaryContainer.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: cs.primary.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 18, color: cs.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Lyrics will be shown in the recording screen',
                        style: tt.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── CHIP ─────────────────────────────────────────────────────────────────────
class _Chip extends StatelessWidget {
  const _Chip(
      {required this.icon, required this.label, required this.cs});
  final IconData icon;
  final String label;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: cs.onSecondaryContainer),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: cs.onSecondaryContainer,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
