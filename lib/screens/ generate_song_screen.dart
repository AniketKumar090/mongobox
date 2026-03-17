import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../services/local_suggestions_service.dart';
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
    required this.lyrics,
    required this.mood,
    required this.genre,
    required this.language,
  });
  final String title;
  final String lyrics;
  final String mood;
  final String genre;
  final String language;

  String get fullText =>
      '"$title"\nLanguage: $language\nMood: $mood | Genre: $genre\n\n$lyrics';
}

// ─── SCREEN ───────────────────────────────────────────────────────────────────
class GenerateSongScreen extends StatefulWidget {
  const GenerateSongScreen({super.key});

  @override
  State<GenerateSongScreen> createState() => _GenerateSongScreenState();
}

class _GenerateSongScreenState extends State<GenerateSongScreen>
    with SingleTickerProviderStateMixin {

  List<RecentTrack> _recentTracks = [];
  String? _aiSuggestedMood;
  String? _aiSuggestedLanguage;
  String? _selectedMood; // null = use AI suggestion
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

  // ── STEP 1: Load tracks + auto-detect mood via Groq ──────────────────────
  Future<void> _loadTracksAndSuggestMood() async {
    final service = await LocalSuggestionsService.create();
    if (!mounted) return;
    final tracks = service.getRecentTracks();
    setState(() {
      _recentTracks = tracks;
      _isMoodLoading = tracks.isNotEmpty;
    });
    if (tracks.isEmpty) return;

    Future<void> updateMood() async {
      try {
        final mood = await _detectMood(tracks);
        if (!mounted) return;
        setState(() => _aiSuggestedMood = mood);
      } catch (_) {
        // Ignore: mood is optional.
      } finally {
        if (mounted) setState(() => _isMoodLoading = false);
      }
    }

    Future<void> updateLanguage() async {
      try {
        final language = await _detectLanguage(tracks);
        if (!mounted) return;
        setState(() => _aiSuggestedLanguage = language);
      } catch (_) {
        // Ignore: language is optional (fallback to English).
      }
    }

    await Future.wait([updateMood(), updateLanguage()]);
  }

  // ── Groq: detect mood from track list (fast, 10 tokens) ──────────────────
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
                    'You are a music mood analyst. Reply with ONLY one word from this list: Energetic, Melancholic, Euphoric, Dreamy, Heartbreak, Intense, Chill, Romantic. No punctuation, nothing else.',
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
    final raw =
        (data['choices'][0]['message']['content'] as String).trim();

    final valid = _moods.map((m) => m.$2).toList();
    return valid.firstWhere(
      (m) => raw.toLowerCase().contains(m.toLowerCase()),
      orElse: () => 'Chill',
    );
  }

  // ── Groq: detect dominant language from lyric snippets ───────────────────
  Future<String> _detectLanguage(List<RecentTrack> tracks) async {
    final apiKey = dotenv.env['GROQ_API_KEY'] ?? '';

    final snippets = tracks
        .map((t) => t.lyricSnippet.trim())
        .where((s) => s.isNotEmpty)
        .map((s) => s.replaceAll(RegExp(r'\s+'), ' '))
        .map((s) => s.length > 90 ? s.substring(0, 90) : s)
        .take(10)
        .toList();

    final fallbackFromScript =
        _guessLanguageFromUnicodeSample(snippets.join('\n'));

    if (apiKey.isEmpty) {
      if (fallbackFromScript != null) return fallbackFromScript;
      throw Exception('GROQ_API_KEY not set');
    }

    final titles = tracks
        .map((t) => '${t.trackName} – ${t.artistName}'.trim())
        .where((s) => s.isNotEmpty)
        .take(10)
        .toList();

    final sample = [
      if (snippets.isNotEmpty) 'Lyric snippets:\n- ${snippets.join('\n- ')}',
      if (titles.isNotEmpty) 'Track titles:\n- ${titles.join('\n- ')}',
    ].join('\n\n');

    final response = await http
        .post(
          Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          body: json.encode({
            'model': 'llama-3.3-70b-versatile',
            'max_tokens': 8,
            'temperature': 0,
            'messages': [
              {
                'role': 'system',
                'content':
                    'You are a language classifier for song lyrics. Reply with ONLY the dominant language name in English (examples: Hindi, Spanish, Japanese, Korean, Arabic, French, Portuguese, Bengali, Tamil, Telugu, Marathi, Urdu, Indonesian, Turkish, Vietnamese, Thai, German, Italian, Russian, Chinese, English). If uncertain, reply English. No punctuation, no extra text.',
              },
              {
                'role': 'user',
                'content': sample.isEmpty
                    ? 'Dominant language:'
                    : 'What is the dominant language in this listening history sample?\n\n$sample',
              },
            ],
          }),
        )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) throw Exception('Language detection failed');

    final data = json.decode(response.body);
    final raw =
        (data['choices'][0]['message']['content'] as String).trim();

    // Keep it as a short label, avoid accidental extra words.
    final cleaned = raw
        .split(RegExp(r'[\n,;/]+'))
        .first
        .trim()
        .replaceAll(RegExp(r"[^A-Za-z '-]"), '')
        .trim();

    if (cleaned.isEmpty) return 'English';
    // Title-case-ish for consistency in UI.
    final normalized = cleaned
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .map((p) =>
            p.length == 1 ? p.toUpperCase() : '${p[0].toUpperCase()}${p.substring(1).toLowerCase()}')
        .join(' ');

    if (normalized.toLowerCase() == 'english' &&
        fallbackFromScript != null &&
        fallbackFromScript.toLowerCase() != 'english') {
      return fallbackFromScript;
    }
    return normalized;
  }

  String? _guessLanguageFromUnicodeSample(String text) {
    if (text.trim().isEmpty) return null;

    int countDevanagari = 0;
    int countBengali = 0;
    int countGurmukhi = 0;
    int countGujarati = 0;
    int countTamil = 0;
    int countTelugu = 0;
    int countKannada = 0;
    int countMalayalam = 0;
    int countArabic = 0;
    int countHangul = 0;
    int countHiraganaKatakana = 0;
    int countCjk = 0;
    int countCyrillic = 0;
    int countThai = 0;

    for (final rune in text.runes) {
      if (rune >= 0x0900 && rune <= 0x097F) countDevanagari++;
      if (rune >= 0x0980 && rune <= 0x09FF) countBengali++;
      if (rune >= 0x0A00 && rune <= 0x0A7F) countGurmukhi++;
      if (rune >= 0x0A80 && rune <= 0x0AFF) countGujarati++;
      if (rune >= 0x0B80 && rune <= 0x0BFF) countTamil++;
      if (rune >= 0x0C00 && rune <= 0x0C7F) countTelugu++;
      if (rune >= 0x0C80 && rune <= 0x0CFF) countKannada++;
      if (rune >= 0x0D00 && rune <= 0x0D7F) countMalayalam++;
      if ((rune >= 0x0600 && rune <= 0x06FF) ||
          (rune >= 0x0750 && rune <= 0x077F) ||
          (rune >= 0x08A0 && rune <= 0x08FF)) {
        countArabic++;
      }
      if ((rune >= 0x1100 && rune <= 0x11FF) ||
          (rune >= 0xAC00 && rune <= 0xD7AF)) {
        countHangul++;
      }
      if ((rune >= 0x3040 && rune <= 0x309F) ||
          (rune >= 0x30A0 && rune <= 0x30FF)) {
        countHiraganaKatakana++;
      }
      if (rune >= 0x4E00 && rune <= 0x9FFF) countCjk++;
      if (rune >= 0x0400 && rune <= 0x04FF) countCyrillic++;
      if (rune >= 0x0E00 && rune <= 0x0E7F) countThai++;
    }

    final map = <String, int>{
      'Hindi': countDevanagari,
      'Bengali': countBengali,
      'Punjabi': countGurmukhi,
      'Gujarati': countGujarati,
      'Tamil': countTamil,
      'Telugu': countTelugu,
      'Kannada': countKannada,
      'Malayalam': countMalayalam,
      'Arabic': countArabic,
      'Russian': countCyrillic,
      'Thai': countThai,
    };

    String? bestLang;
    var bestCount = 0;
    map.forEach((lang, count) {
      if (count > bestCount) {
        bestCount = count;
        bestLang = lang;
      }
    });

    // Japanese/Korean/Chinese need special handling.
    if (countHangul > bestCount) {
      bestCount = countHangul;
      bestLang = 'Korean';
    }
    if (countHiraganaKatakana > bestCount) {
      bestCount = countHiraganaKatakana;
      bestLang = 'Japanese';
    }
    if (countCjk > bestCount && countHiraganaKatakana == 0) {
      bestCount = countCjk;
      bestLang = 'Chinese';
    }

    // Require a meaningful amount of non-Latin signal.
    if (bestLang == null || bestCount < 8) return null;
    return bestLang;
  }

  // ── STEP 2: Generate full lyrics via Groq ────────────────────────────────
  Future<void> _generate() async {
    if (_isLoading) return;
    if (_recentTracks.isEmpty) {
      setState(() {
        _errorMessage = 'No listening history yet. Play a few songs first!';
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

    final trackList = _recentTracks
        .take(20)
        .map((t) => '${t.trackName} – ${t.artistName}')
        .join('\n');

    String language = _aiSuggestedLanguage ?? 'English';
    try {
      if (_aiSuggestedLanguage == null) {
        language = await _detectLanguage(_recentTracks);
        if (mounted) setState(() => _aiSuggestedLanguage = language);
      }
    } catch (_) {
      // Ignore: fallback stays English.
    }

    final prompt =
        'You are a professional songwriter. Analyze this listening history and write an original song.\n\n'
        'Listening history:\n$trackList\n\n'
        'Requested mood: $mood\n\n'
        'Requested language: $language\n\n'
        'Rules:\n'
        '- Write COMPLETELY ORIGINAL lyrics — do not reference the songs above\n'
        '- Match the energy, themes, and style of what they listen to\n'
        '- Write ALL lyric lines in $language (keep section headers like [Verse 1] in English)\n'
        '- Do not switch languages mid-song\n'
        '- Structure: [Verse 1], [Chorus], [Verse 2], [Bridge], [Outro]\n'
        '- Lyrics must be vivid, emotional, specific — no generic lines\n'
        '- Title: 2–4 words, evocative\n\n'
        'Respond ONLY with this JSON (no markdown, no extra text):\n'
        '{"title":"Song Title","mood":"$mood","genre":"Genre / Sub-genre","language":"$language","lyrics":"[Verse 1]\\nline\\nline\\n\\n[Chorus]\\nline\\nline\\n\\n[Verse 2]\\nline\\nline\\n\\n[Bridge]\\nline\\nline\\n\\n[Outro]\\nline\\nline"}';

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
              'max_tokens': 1024,
              'temperature': 0.9,
              'messages': [
                {
                  'role': 'system',
                  'content':
                      'You are a creative songwriter. Always respond with valid JSON only. No markdown.',
                },
                {'role': 'user', 'content': prompt},
              ],
            }),
          )
          .timeout(const Duration(seconds: 30));

      if (!mounted) return;

      if (response.statusCode != 200) {
        throw Exception(
            'Groq API error ${response.statusCode}: ${response.body}');
      }

      final data = json.decode(response.body);
      final raw =
          (data['choices'][0]['message']['content'] as String)
              .replaceAll(RegExp(r'```json\s*'), '')
              .replaceAll(RegExp(r'```\s*'), '')
              .trim();

      final parsed = json.decode(raw) as Map<String, dynamic>;

      setState(() {
        _result = _SongResult(
          title: parsed['title'] as String? ?? 'Untitled',
          lyrics: parsed['lyrics'] as String? ?? '',
          mood: parsed['mood'] as String? ?? mood,
          genre: parsed['genre'] as String? ?? '',
          language: parsed['language'] as String? ?? language,
        );
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Lyrics copied!'),
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
          lyrics: r.lyrics,
          mood: r.mood,
          genre: r.genre,
        ),
      ),
    );
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
          padding:
              const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [

              // ── Header card ─────────────────────────────────────────────
              _HeaderCard(recentTracks: _recentTracks, cs: cs, tt: tt),

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
                          style: tt.bodySmall
                              ?.copyWith(color: cs.onErrorContainer),
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
                    result: _result!, cs: cs, tt: tt, onCopy: _copyToClipboard),
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
                  label: const Text('Record my voice'),
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
                  label: const Text('Generate another'),
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
  const _HeaderCard(
      {required this.recentTracks, required this.cs, required this.tt});
  final List<RecentTrack> recentTracks;
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
                child:
                    Icon(Icons.auto_awesome, color: cs.primary, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('AI Songwriting',
                        style: tt.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: cs.onPrimaryContainer)),
                    Text('Powered by Groq · Free & instant',
                        style: tt.bodySmall?.copyWith(
                            color: cs.onPrimaryContainer
                                .withValues(alpha: 0.7))),
                  ],
                ),
              ),
            ],
          ),
          if (recentTracks.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              'Using ${recentTracks.length} tracks from your history',
              style: tt.labelMedium?.copyWith(
                  color: cs.onPrimaryContainer.withValues(alpha: 0.8)),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: recentTracks.take(5).map((t) {
                return Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(t.trackName,
                      style: tt.labelSmall
                          ?.copyWith(color: cs.onPrimaryContainer),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                );
              }).toList(),
            ),
          ] else ...[
            const SizedBox(height: 12),
            Text('Play some songs first to build your taste profile.',
                style: tt.bodySmall?.copyWith(
                    color: cs.onPrimaryContainer.withValues(alpha: 0.7))),
          ],
        ],
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
            Text('Mood',
                style: tt.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            if (isMoodLoading)
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: cs.primary),
              )
            else if (aiSuggestedMood != null && selectedMood == null)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('AI picked',
                    style: tt.labelSmall
                        ?.copyWith(color: cs.onPrimaryContainer)),
              ),
            if (selectedMood != null) ...[
              const Spacer(),
              GestureDetector(
                onTap: () => onMoodSelected(selectedMood!),
                child: Text('Reset to AI',
                    style: tt.labelSmall?.copyWith(
                        color: cs.primary,
                        decoration: TextDecoration.underline)),
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
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: isActive
                      ? cs.primary
                      : cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: isActive
                        ? cs.primary
                        : cs.outline.withValues(alpha: 0.3),
                    width: isActive ? 2 : 1,
                  ),
                ),
                child: Text(
                  '${m.$1} ${m.$2}',
                  style: tt.labelMedium?.copyWith(
                    color: isActive ? cs.onPrimary : cs.onSurface,
                    fontWeight: isActive
                        ? FontWeight.bold
                        : FontWeight.normal,
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
    '✍️ Crafting your lyrics…',
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
    required this.cs,
    required this.tt,
    required this.onCopy,
  });

  final _SongResult result;
  final ColorScheme cs;
  final TextTheme tt;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('"${result.title}"',
                        style: tt.headlineSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: cs.onSurface)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy_rounded),
                    onPressed: onCopy,
                    color: cs.primary,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  _Chip(icon: Icons.mood, label: result.mood, cs: cs),
                  _Chip(
                      icon: Icons.library_music,
                      label: result.genre,
                      cs: cs),
                  _Chip(
                      icon: Icons.language,
                      label: result.language,
                      cs: cs),
                ],
              ),
            ],
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
            borderRadius:
                const BorderRadius.vertical(bottom: Radius.circular(20)),
            border: Border(
                top: BorderSide(
                    color: cs.outline.withValues(alpha: 0.15))),
          ),
          child: _LyricsBody(lyrics: result.lyrics, cs: cs, tt: tt),
        ),
      ],
    );
  }
}

// ─── LYRICS RENDERER ──────────────────────────────────────────────────────────
class _LyricsBody extends StatelessWidget {
  const _LyricsBody(
      {required this.lyrics, required this.cs, required this.tt});
  final String lyrics;
  final ColorScheme cs;
  final TextTheme tt;

  @override
  Widget build(BuildContext context) {
    final lines = lyrics.split('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: lines.map((line) {
        final isSection = RegExp(
          r'^\[(Verse|Chorus|Bridge|Outro|Pre-Chorus)',
          caseSensitive: false,
        ).hasMatch(line.trim());

        if (isSection) {
          return Padding(
            padding: const EdgeInsets.only(top: 20, bottom: 4),
            child: Text(line.trim(),
                style: tt.labelLarge?.copyWith(
                    color: cs.primary,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5)),
          );
        }
        if (line.trim().isEmpty) return const SizedBox(height: 4);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(line,
              style: tt.bodyMedium
                  ?.copyWith(color: cs.onSurface, height: 1.7)),
        );
      }).toList(),
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
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  color: cs.onSecondaryContainer,
                  fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}
