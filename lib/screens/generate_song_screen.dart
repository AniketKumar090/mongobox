import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../models/song_reference.dart';
import '../services/local_suggestions_service.dart';
import '../services/transliteration_service.dart';
import 'voice_sample_screen.dart';

// ─── MOOD OPTIONS ─────────────────────────────────────────────────────────────
const _moods = [
  ('🔥', 'Energetic'),
  ('💜', 'Melancholic'),
  ('✨', 'Euphoric'),
  ('🌙', 'Dreamy'),
  ('💔', 'Heartbreak'),
  ('😤', 'Intense'),
  ('🌊', 'Chill'),
  ('🥰', 'Romantic'),
];

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
  final String hindiLyrics;       // Devanagari
  final String englishLyrics;     // English
  final String mood;
  final String genre;
  final String dominantLanguage;  // 'Hindi' or 'English'
  final SongReference? referenceSong;
  final String? hinglishLyrics;   // Romanised Hindi, loaded async

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

// Which lyrics panel to show
enum _LyricsView { devanagari, hinglish, both }

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

  // Mood — AI-suggested or user-overridden
  String? _aiSuggestedMood;
  String? _selectedMood;

  _SongResult? _result;
  bool _isLoading = false;
  bool _isMoodLoading = false;
  String? _errorMessage;

  // Hinglish toggle
  bool _isRomanizing = false;
  _LyricsView _lyricsView = _LyricsView.both;

  final _transliterationService = TransliterationService();
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

  // ── Load tracks + auto-detect mood via Groq ───────────────────────────────
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
    } catch (_) {
      // Mood is optional — swallow errors
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
      _lyricsView = _LyricsView.both;
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
      _lyricsView = _LyricsView.both;
      _isMoodLoading = _analysisTracks.isNotEmpty;
    });
    if (_generationMode == _GenerationMode.singleSong) {
      await _refreshMoodSuggestion();
    }
  }

  // ── Groq: detect mood ─────────────────────────────────────────────────────
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
    final valid = _moods.map((m) => m.$2).toList();
    return valid.firstWhere(
      (m) => raw.toLowerCase().contains(m.toLowerCase()),
      orElse: () => 'Chill',
    );
  }

  // ── GENERATE BILINGUAL SONG ───────────────────────────────────────────────
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

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _result = null;
      _lyricsView = _LyricsView.both;
    });

    final trackList = referenceTracks
        .take(20)
        .map((t) => '${t.trackName} – ${t.artistName}')
        .join('\n');
    final selectedReference = _selectedTrack;

    final prompt = _generationMode == _GenerationMode.singleSong
        ? _buildSingleSongPrompt(
            mood: mood,
            reference: selectedReference!,
          )
        : _buildHistoryPrompt(
            mood: mood,
            trackList: trackList,
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
                      'You are a bilingual Hindi-English songwriter. '
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

      final result = _SongResult(
        title: parsed['title'] as String? ?? 'Untitled',
        hindiLyrics: parsed['hindi_lyrics'] as String? ?? '',
        englishLyrics: parsed['english_lyrics'] as String? ?? '',
        mood: parsed['mood'] as String? ?? mood,
        genre: parsed['genre'] as String? ?? '',
        dominantLanguage: 'Hindi',
        referenceSong: selectedReference == null
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
        _isRomanizing = true;
        _lyricsView = _LyricsView.devanagari;
      });

      _romanizeInBackground(result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  /// Transliterate Hindi Devanagari → Hinglish in background.
  Future<void> _romanizeInBackground(_SongResult result) async {
    try {
      final hinglish = await _transliterationService.transliterateLyrics(
        result.hindiLyrics,
        'Hindi',
      );
      if (!mounted) return;
      setState(() {
        _result = _SongResult(
          title: result.title,
          hindiLyrics: result.hindiLyrics,
          englishLyrics: result.englishLyrics,
          mood: result.mood,
          genre: result.genre,
          dominantLanguage: result.dominantLanguage,
          referenceSong: result.referenceSong,
          hinglishLyrics: hinglish,
        );
        _lyricsView = _LyricsView.both;
        _isRomanizing = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isRomanizing = false);
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
        ),
      ),
    );
  }

  // ── Bilingual prompt builders ─────────────────────────────────────────────

  String _buildHistoryPrompt({
    required String mood,
    required String trackList,
  }) {
    return 'You are a bilingual Hindi-English songwriter.\n\n'
        'Listening history:\n$trackList\n\n'
        'Requested mood: $mood\n\n'
        'Rules:\n'
        '- Write COMPLETELY ORIGINAL bilingual lyrics inspired by the listening style above\n'
        '- Use Hindi (Devanagari) for Verse 1, Verse 2 and Bridge; use English for Chorus and Outro\n'
        '- Hindi lines MUST use Devanagari script only. No Roman Hindi.\n'
        '- English lines must be natural, colloquial English — not a translation of Hindi lines\n'
        '- Section headers ([Verse 1], [Chorus], [Bridge], [Outro]) always in English\n'
        '- Lyrics must be vivid, emotional, specific — no generic filler\n'
        '- Title: 2–4 words, bilingual style (e.g. "दिल की Beat" or "Roshan Nights")\n\n'
        'Respond ONLY with this JSON (no markdown):\n'
        '{"title":"...","mood":"$mood","genre":"Genre",'
        '"hindi_lyrics":"[Verse 1]\\nपंक्ति\\n\\n[Chorus]\\nपंक्ति\\n\\n[Verse 2]\\nपंक्ति\\n\\n[Bridge]\\nपंक्ति\\n\\n[Outro]\\nपंक्ति",'
        '"english_lyrics":"[Verse 1]\\nline\\n\\n[Chorus]\\nline\\n\\n[Verse 2]\\nline\\n\\n[Bridge]\\nline\\n\\n[Outro]\\nline"}';
  }

  String _buildSingleSongPrompt({
    required String mood,
    required RecentTrack reference,
  }) {
    final snippet = reference.lyricSnippet.trim();
    return 'You are a bilingual Hindi-English songwriter.\n\n'
        'Reference song: ${reference.trackName} by ${reference.artistName}\n'
        '${snippet.isEmpty ? '' : 'Lyric snippet: $snippet\n'}\n'
        'Requested mood: $mood\n\n'
        'Rules:\n'
        '- Study the emotional tone, imagery, pacing and genre of the reference\n'
        '- Write a COMPLETELY ORIGINAL bilingual song inspired by that reference\n'
        '- Do NOT copy, translate, or closely mimic any line from the reference\n'
        '- Do NOT mention the reference song or artist name\n'
        '- Use Hindi (Devanagari) for Verse 1, Verse 2 and Bridge; use English for Chorus and Outro\n'
        '- Hindi lines MUST use Devanagari script only. No Roman Hindi.\n'
        '- English lines must be natural, colloquial English — not a translation\n'
        '- Section headers ([Verse 1], [Chorus], [Bridge], [Outro]) always in English\n'
        '- Lyrics must be vivid, emotional, specific — no generic filler\n'
        '- Title: 2–4 words, bilingual style (e.g. "दिल की Beat" or "Roshan Nights")\n\n'
        'Respond ONLY with this JSON (no markdown):\n'
        '{"title":"...","mood":"$mood","genre":"Genre",'
        '"hindi_lyrics":"[Verse 1]\\nपंक्ति\\n\\n[Chorus]\\nपंक्ति\\n\\n[Verse 2]\\nपंक्ति\\n\\n[Bridge]\\nपंक्ति\\n\\n[Outro]\\nपंक्ति",'
        '"english_lyrics":"[Verse 1]\\nline\\n\\n[Chorus]\\nline\\n\\n[Verse 2]\\nline\\n\\n[Bridge]\\nline\\n\\n[Outro]\\nline"}';
  }

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
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Header card ─────────────────────────────────────────────
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

              // ── Mood selector ───────────────────────────────────────────
              _MoodSelector(
                aiSuggestedMood: _aiSuggestedMood,
                selectedMood: _selectedMood,
                isMoodLoading: _isMoodLoading,
                onMoodSelected: (mood) => setState(() {
                  _selectedMood = _selectedMood == mood ? null : mood;
                }),
                cs: cs,
                tt: tt,
              ),

              const SizedBox(height: 24),

              // ── Generate button ─────────────────────────────────────────
              AnimatedBuilder(
                animation: _shimmerController,
                builder: (context, _) => SizedBox(
                  height: 64,
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

              // ── Loading steps ───────────────────────────────────────────
              if (_isLoading) ...[
                const SizedBox(height: 16),
                const _LoadingSteps(),
              ],

              // ── Error ───────────────────────────────────────────────────
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
                      Icon(Icons.error_outline, color: cs.error, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: tt.bodySmall?.copyWith(
                            color: cs.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // ── Result ──────────────────────────────────────────────────
              if (_result != null) ...[
                const SizedBox(height: 28),
                _ResultCard(
                  result: _result!,
                  lyricsView: _lyricsView,
                  isRomanizing: _isRomanizing,
                  onViewChanged: (v) => setState(() => _lyricsView = v),
                  onCopy: _copyToClipboard,
                  cs: cs,
                  tt: tt,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _isLoading ? null : _openVoiceClone,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.record_voice_over_rounded),
                  label: const Text('Record My Voice'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _isLoading ? null : _generate,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Generate Another'),
                ),
              ],

              const SizedBox(height: 40),
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
            Text(
              mode == _GenerationMode.singleSong
                  ? 'Choose a reference song'
                  : 'Using ${recentTracks.length} tracks from your history',
              style: tt.labelMedium?.copyWith(
                color: cs.onPrimaryContainer.withValues(alpha: 0.8),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: recentTracks.take(6).map((t) {
                final isSelected = mode == _GenerationMode.singleSong &&
                    selectedTrack?.trackName == t.trackName &&
                    selectedTrack?.artistName == t.artistName;
                return GestureDetector(
                  onTap: () => onTrackSelected(t),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
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
            if (mode == _GenerationMode.singleSong && selectedTrack != null) ...[
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
            color: isActive ? cs.primary : cs.primary.withValues(alpha: 0.18),
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
class _MoodSelector extends StatelessWidget {
  const _MoodSelector({
    required this.aiSuggestedMood,
    required this.selectedMood,
    required this.isMoodLoading,
    required this.onMoodSelected,
    required this.cs,
    required this.tt,
  });
  final String? aiSuggestedMood;
  final String? selectedMood;
  final bool isMoodLoading;
  final void Function(String) onMoodSelected;
  final ColorScheme cs;
  final TextTheme tt;

  @override
  Widget build(BuildContext context) {
    final activeMood = selectedMood ?? aiSuggestedMood;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Mood',
              style: tt.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 8),
            if (isMoodLoading)
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
              )
            else if (aiSuggestedMood != null && selectedMood == null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'AI picked',
                  style: tt.labelSmall?.copyWith(color: cs.onPrimaryContainer),
                ),
              ),
            if (selectedMood != null) ...[
              const Spacer(),
              GestureDetector(
                onTap: () => onMoodSelected(selectedMood!),
                child: Text(
                  'Reset to AI',
                  style: tt.labelSmall?.copyWith(
                    color: cs.primary,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _moods.map((m) {
            final isActive = activeMood == m.$2;
            return GestureDetector(
              onTap: () => onMoodSelected(m.$2),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: isActive ? cs.primary : cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: isActive ? cs.primary : cs.outline.withValues(alpha: 0.3),
                    width: isActive ? 2 : 1,
                  ),
                ),
                child: Text(
                  '${m.$1} ${m.$2}',
                  style: tt.labelMedium?.copyWith(
                    color: isActive ? cs.onPrimary : cs.onSurface,
                    fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
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
enum _LyricsTab { hindi, english }

class _ResultCard extends StatefulWidget {
  const _ResultCard({
    required this.result,
    required this.lyricsView,
    required this.isRomanizing,
    required this.onViewChanged,
    required this.onCopy,
    required this.cs,
    required this.tt,
  });
  final _SongResult result;
  final _LyricsView lyricsView;
  final bool isRomanizing;
  final ValueChanged<_LyricsView> onViewChanged;
  final VoidCallback onCopy;
  final ColorScheme cs;
  final TextTheme tt;

  @override
  State<_ResultCard> createState() => _ResultCardState();
}

class _ResultCardState extends State<_ResultCard> {
  late _LyricsTab _activeTab;

  @override
  void initState() {
    super.initState();
    _activeTab = widget.result.dominantLanguage == 'Hindi'
        ? _LyricsTab.hindi
        : _LyricsTab.english;
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final cs = widget.cs;
    final tt = widget.tt;
    final hasHinglish = result.hinglishLyrics != null;
    final isDominantHindi = result.dominantLanguage == 'Hindi';

    return Column(
      children: [
        // ── Header ────────────────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
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
                  if (widget.isRomanizing)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: cs.primary),
                      ),
                    ),
                  IconButton(
                    icon: const Icon(Icons.copy_rounded),
                    onPressed: widget.onCopy,
                    color: cs.primary,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  _Chip(icon: Icons.mood, label: result.mood, cs: cs),
                  _Chip(icon: Icons.library_music, label: result.genre, cs: cs),
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

              // ── Language tabs ────────────────────────────────────────────
              const SizedBox(height: 14),
              Row(
                children: [
                  _LangTab(
                    label: 'हिंदी',
                    sublabel: isDominantHindi ? 'dominant' : null,
                    isActive: _activeTab == _LyricsTab.hindi,
                    onTap: () => setState(() => _activeTab = _LyricsTab.hindi),
                    cs: cs,
                    tt: tt,
                  ),
                  const SizedBox(width: 8),
                  _LangTab(
                    label: 'English',
                    sublabel: !isDominantHindi ? 'dominant' : null,
                    isActive: _activeTab == _LyricsTab.english,
                    onTap: () =>
                        setState(() => _activeTab = _LyricsTab.english),
                    cs: cs,
                    tt: tt,
                  ),
                ],
              ),

              // ── Hinglish toggle (Hindi tab only) ─────────────────────────
              if (_activeTab == _LyricsTab.hindi && hasHinglish) ...[
                const SizedBox(height: 10),
                SegmentedButton<_LyricsView>(
                  segments: const [
                    ButtonSegment(
                        value: _LyricsView.devanagari,
                        label: Text('देवनागरी')),
                    ButtonSegment(
                        value: _LyricsView.hinglish,
                        label: Text('Hinglish')),
                    ButtonSegment(
                        value: _LyricsView.both, label: Text('Both')),
                  ],
                  selected: {widget.lyricsView},
                  onSelectionChanged: (s) => widget.onViewChanged(s.first),
                ),
              ],
            ],
          ),
        ),

        // ── Lyrics body ────────────────────────────────────────────────────
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
            borderRadius:
                const BorderRadius.vertical(bottom: Radius.circular(20)),
            border: Border(
                top: BorderSide(color: cs.outline.withValues(alpha: 0.15))),
          ),
          child: _activeTab == _LyricsTab.english
              ? _LyricsLines(
                  lines: result.englishLyrics.split('\n'),
                  cs: cs,
                  tt: tt,
                )
              : _LyricsBody(
                  devanagari: result.hindiLyrics,
                  hinglish: result.hinglishLyrics,
                  view: hasHinglish
                      ? widget.lyricsView
                      : _LyricsView.devanagari,
                  cs: cs,
                  tt: tt,
                ),
        ),
      ],
    );
  }
}

// ── Language tab button ────────────────────────────────────────────────────────
class _LangTab extends StatelessWidget {
  const _LangTab({
    required this.label,
    required this.sublabel,
    required this.isActive,
    required this.onTap,
    required this.cs,
    required this.tt,
  });
  final String label;
  final String? sublabel;
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
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? cs.primary : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isActive
                ? cs.primary
                : cs.outline.withValues(alpha: 0.3),
            width: isActive ? 2 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: tt.labelLarge?.copyWith(
                color: isActive ? cs.onPrimary : cs.onSurface,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (sublabel != null) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isActive
                      ? Colors.white.withValues(alpha: 0.25)
                      : cs.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  sublabel!,
                  style: TextStyle(
                    fontSize: 9,
                    color: isActive ? cs.onPrimary : cs.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─── PLAIN LYRICS LINES (English) ─────────────────────────────────────────────
class _LyricsLines extends StatelessWidget {
  const _LyricsLines({
    required this.lines,
    required this.cs,
    required this.tt,
  });
  final List<String> lines;
  final ColorScheme cs;
  final TextTheme tt;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: lines.map((line) {
        if (line.trim().isEmpty) return const SizedBox(height: 4);
        final isHeader = RegExp(
          r'^\[(Verse|Chorus|Bridge|Outro|Pre-Chorus)',
          caseSensitive: false,
        ).hasMatch(line.trim());
        if (isHeader) {
          return Padding(
            padding: const EdgeInsets.only(top: 20, bottom: 4),
            child: Text(
              line.trim(),
              style: tt.labelLarge?.copyWith(
                color: cs.primary,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(
            line,
            style: tt.bodyMedium?.copyWith(color: cs.onSurface, height: 1.7),
          ),
        );
      }).toList(),
    );
  }
}

// ─── HINDI LYRICS RENDERER (Devanagari + optional Hinglish) ───────────────────
class _LyricsBody extends StatelessWidget {
  const _LyricsBody({
    required this.devanagari,
    required this.hinglish,
    required this.view,
    required this.cs,
    required this.tt,
  });
  final String devanagari;
  final String? hinglish;
  final _LyricsView view;
  final ColorScheme cs;
  final TextTheme tt;

  @override
  Widget build(BuildContext context) {
    final devLines = devanagari.split('\n');
    final hinLines = hinglish?.split('\n');
    final primaryLines =
        (view == _LyricsView.hinglish && hinLines != null) ? hinLines : devLines;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: List.generate(primaryLines.length, (i) {
        final line = primaryLines[i];
        final isHeader = RegExp(
          r'^\[(Verse|Chorus|Bridge|Outro|Pre-Chorus)',
          caseSensitive: false,
        ).hasMatch(line.trim());

        if (isHeader) {
          return Padding(
            padding: const EdgeInsets.only(top: 20, bottom: 4),
            child: Text(
              line.trim(),
              style: tt.labelLarge?.copyWith(
                color: cs.primary,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          );
        }
        if (line.trim().isEmpty) return const SizedBox(height: 4);

        if (view != _LyricsView.both || hinLines == null) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(line,
                style: tt.bodyMedium
                    ?.copyWith(color: cs.onSurface, height: 1.7)),
          );
        }

        // Both: Devanagari on top, Hinglish muted below
        final hinLine = i < hinLines.length ? hinLines[i] : '';
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(devLines[i],
                  style: tt.bodyMedium
                      ?.copyWith(color: cs.onSurface, height: 1.65)),
              if (hinLine.trim().isNotEmpty &&
                  hinLine.trim() != devLines[i].trim())
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    hinLine,
                    style: tt.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant, height: 1.4),
                  ),
                ),
            ],
          ),
        );
      }),
    );
  }
}

// ─── CHIP ─────────────────────────────────────────────────────────────────────
class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label, required this.cs});
  final IconData icon;
  final String label;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
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