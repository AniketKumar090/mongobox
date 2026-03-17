# MongoBox App Workflow

This document explains how MongoBox works end-to-end: bootstrap, key user flows, data flow, and where each piece lives in code.

## 1. High-level architecture

MongoBox is a Flutter app with two primary runtime modes:

- Mobile (iOS/Android): a "Lyric Play" hub that supports:
  - Lyric-line → find a song + start time → play YouTube
  - Party host/guest queue (Firebase Realtime Database)
  - AI lyric generation ("Generate Song")
  - Voice sample recording (local-only)
- Web: a "Jukebox" UI that plays YouTube in an iframe and shares the same party queue backend.

Core external systems:

- Firebase Realtime Database: shared party queue (`parties/{partyId}/queue`)
- YouTube Data API: search metadata (mobile via `.env`; web currently hard-codes a key)
- LRCLIB: lyric-line → song + timestamp resolution
- Groq OpenAI-compatible API: AI mood/language inference + lyric generation (requires `GROQ_API_KEY`)
- SharedPreferences: local recents/history cache (drives suggestions and AI inputs)

## 2. Entry and bootstrap

### App startup (`lib/main.dart`)

1. `WidgetsFlutterBinding.ensureInitialized()`
2. `.env` is loaded best-effort via `EnvConfig.load()` (`lib/services/env_config.dart`)
3. Firebase initializes a named app: `MongoBox` (`lib/firebase_options.dart`)
4. The root `MaterialApp` is launched

### Mode split (web vs mobile)

In `MyApp.build` (`lib/main.dart`):

- If `kIsWeb == true`: `HomeScreen` is `lib/screens/web/home_screen_web.dart`
- Else: `HomeScreen` is `MobileLyricApp` → `LyricHomeScreen`

## 3. Core runtime flows (overview)

```mermaid
flowchart TD
    A[Open MongoBox] --> B{Web?}
    B -->|Yes| W[Web Jukebox HomeScreen]
    B -->|No| M[Mobile LyricHomeScreen]

    M --> J1[Lyric-line play: Find & play]
    M --> J2[Party: Host a party]
    M --> J3[Party: Join a party]
    M --> S[Generate Song (AI)]

    J2 --> QH[Firebase queue: parties/{partyId}/queue]
    J3 --> QH
    W --> QH

    S --> V[Record voice sample (local)]
```

See `docs/SVJ_FLOW.md` for a deeper "SVJ" flow breakdown (Song / Voice / Jukebox).

## 4. Mobile flow details

The mobile app’s primary hub is `LyricHomeScreen` (`lib/screens/lyric_home_screen.dart`). From here the user can:

- Enter a lyric line and play from that line
- Host a party (share QR/link)
- Join a party (paste link or scan QR)
- Generate a new song (AI)
- Speak the current lyric line (on-device TTS)

### 4.1 Lyric-line → Find & play

Files:

- UI: `lib/screens/lyric_home_screen.dart`
- Orchestrator: `lib/services/playback_service_mobile.dart`
- LRCLIB: `lib/services/lyrics_service.dart`
- YouTube: `lib/services/youtube_mobile_service.dart`

What happens:

1. User enters a lyric line (or uses speech-to-text).
2. `PlaybackServiceMobile.resolveCandidates()`:
   - Queries LRCLIB (multiple query variants).
   - Hydrates missing synced lyrics via `LyricsService.getById(...)`.
   - Scores the best matching line and computes a start timestamp (with preroll).
   - Searches YouTube for best matching video IDs.
   - Reranks results using `SemanticRerankerService` (`lib/services/semantic_reranker_service.dart`).
3. The UI shows 1–N candidate songs; user selects one.
4. The app plays the selected video via `YoutubePlayerController`.
5. The search query and result are persisted via `LocalSuggestionsService` (recents/history).

Quota-saving mode:

- `YouTubeQuotaMonitor` (`lib/services/youtube_quota_monitor.dart`) decides if the app should prefer cached results.
- `LightweightSearchService` (`lib/services/lightweight_search_service.dart`) can return cached hits without making API calls.

On-device "Speak line":

- `TtsService` (`lib/services/tts_service.dart`) powers the speaker/stop button on the lyric input.

### 4.2 Party flow (host)

File: `lib/screens/host_party_screen.dart`

What happens:

1. `HostPartyScreen` creates a new party ID: `party_<epochMs>`.
2. It instantiates `SharedQueueService(partyId: _partyId)` and subscribes to `streamQueue()`.
3. The host plays the first queue item with `YoutubePlayerController`.
4. The host can search YouTube (mobile YouTube API key from `.env`) and add songs to the queue.
5. The host shares a join link of the form:

   - `https://mongobox-79a1f.firebaseapp.com/join-queue.html?partyId=<partyId>`

Data path:

- `SharedQueueService` writes/streams `parties/<partyId>/queue` in Firebase Realtime Database.

### 4.3 Party flow (guest)

Files:

- Join link / QR entry: `lib/screens/join_via_link_screen.dart`
- Guest add-to-queue UI: `lib/screens/join_party_screen.dart`

What happens:

1. Guest pastes the host’s join link, or scans the QR code.
2. `JoinViaLinkScreen` extracts `partyId` from the `partyId=...` query param.
3. If `partyId` exists, it routes in-app to `JoinPartyScreen(partyId: ...)`.
4. Guest searches YouTube and taps "Add" to push a song to the shared Firebase queue via `SharedQueueService`.

## 5. Web flow details (Jukebox)

File: `lib/screens/web/home_screen_web.dart`

What happens:

1. The web app chooses a party ID:
   - If `?partyId=...` exists in the browser URL: guest mode.
   - Else: it generates a new party ID (host mode).
2. It subscribes to `SharedQueueService(partyId).streamQueue()`.
3. It plays YouTube using an iframe (`HtmlElementView`).
4. Search uses the YouTube Data API directly from the browser.

Operational note:

- The web screen currently contains a hard-coded YouTube API key string. Mobile uses `YOUTUBE_API_KEY` from `.env`.

## 6. AI "Generate Song" flow (S)

File: `lib/screens/ generate_song_screen.dart` (note the leading space in the filename)

What happens:

1. Loads recent listening history from `LocalSuggestionsService`.
2. Calls Groq’s OpenAI-compatible endpoint (requires `GROQ_API_KEY`) to:
   - Infer a suggested mood and language from recent tracks
   - Generate a structured JSON response containing `{title, lyrics, mood, genre, language}`
3. Displays the generated song and allows copying to clipboard.
4. Offers a "Record my voice" button that navigates to the voice sample screen.

## 7. Voice sample flow (V)

File: `lib/screens/voice_sample_screen.dart`

What happens:

1. Requests microphone permission (`permission_handler`).
2. Records a short `m4a` sample to the temporary directory (`record`).
3. Allows local playback (`just_audio`).
4. No network requests are made from this screen.

Implementation note:

- `VoiceSongScreen` (`lib/screens/voice_song_screen.dart`) and `voice-backend/` exist, but the post-record "clone/generate" step is currently not invoked from the recording UI.

## 8. Data model and storage

### Firebase Realtime Database

Path:

- `parties/<partyId>/queue/<pushKey>`

Song fields (typical):

- `id` (YouTube video ID)
- `title`
- `artist`
- `thumbnail`

### Local storage (SharedPreferences)

- Recents: lyric lines, track history, recent searches (`LocalSuggestionsService`)

## 9. Environment variables and keys

MongoBox uses a mixture of runtime `.env` keys and compile-time defines.

`.env` (mobile):

- `YOUTUBE_API_KEY` (required for mobile YouTube search)
- `GROQ_API_KEY` (required for `GenerateSongScreen`)
- `ANTHROPIC_API_KEY` (only used by the unused/experimental `LyricsService.generatePersonalSong`)

Compile-time:

- `VOICE_BACKEND_URL` is read by `VoiceSongScreen` (not currently reachable from voice recording UI).

## 10. Screen and service map (quick reference)

Primary screens:

- `lib/screens/lyric_home_screen.dart` (mobile hub)
- `lib/screens/host_party_screen.dart` (host)
- `lib/screens/join_via_link_screen.dart` → `lib/screens/join_party_screen.dart` (guest)
- `lib/screens/web/home_screen_web.dart` (web jukebox)
- `lib/screens/ generate_song_screen.dart` (AI lyrics generation)
- `lib/screens/voice_sample_screen.dart` (voice recording + playback)

Primary services:

- `lib/services/shared_queue_service.dart` (Firebase queue)
- `lib/services/youtube_mobile_service.dart` (mobile YouTube API)
- `lib/services/lyrics_service.dart` (LRCLIB + experimental Anthropic lyrics generation)
- `lib/services/playback_service_mobile.dart` (lyric-line → playable options)
- `lib/services/local_suggestions_service.dart` (local recents/history)
- `lib/services/tts_service.dart` (on-device TTS)

## 11. Operational notes / footguns

- Firebase app name is fixed as `MongoBox`; `SharedQueueService` uses `Firebase.app("MongoBox")`.
- `lib/screens/ generate_song_screen.dart` has a leading space in the filename; keep imports consistent (or rename it as a cleanup task).
- Web YouTube search currently uses a hard-coded API key; mobile reads from `.env`.
