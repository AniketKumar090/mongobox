# MongoBox App Workflow

This document explains how MongoBox works end-to-end, including startup, feature flows, data flow, and where each part lives in code.

## 1. High-level architecture

MongoBox is a Flutter app with two primary runtime modes:

- Mobile (`kIsWeb == false`): lyric-based playback + party host/guest flow.
- Web (`kIsWeb == true`): shared queue host/guest UI in browser.

Core external systems:

- Firebase Realtime Database: shared party queue (`parties/{partyId}/queue`).
- YouTube Data API: song search metadata.
- LRCLIB: lyric-line to song/timestamp resolution (mobile lyric play).
- SharedPreferences: local recents/profile cache.

## 2. Entry and bootstrap flow

### App startup

1. `lib/main.dart`
1. `WidgetsFlutterBinding.ensureInitialized()`
1. Firebase app named `MongoBox` is initialized (if not already initialized)
1. `MyApp` is launched

### Runtime target selection

In `MyApp.home`:

- Web: `HomeScreen` (from `lib/screens/web/home_screen_web.dart` via conditional import)
- Mobile: `MobileLyricApp` -> `LyricHomeScreen`

## 3. Core runtime flows

```mermaid
flowchart TD
    A[App Launch] --> B{Platform?}
    B -->|Mobile| C[LyricHomeScreen]
    B -->|Web| D[Web HomeScreen]

    C --> C1[Lyric search and play]
    C --> C2[Host party]
    C --> C3[Join party]

    C1 --> E[PlaybackServiceMobile]
    E --> F[LRCLIB search/get]
    E --> G[YouTube search]
    E --> H[Rank candidates]
    H --> I[YouTubePlayer plays from start time]
    C1 --> J[LocalSuggestionsService stores recents]

    C2 --> K[HostPartyScreen]
    C3 --> L[JoinViaLinkScreen]
    L --> M[JoinPartyScreen]

    K --> N[SharedQueueService streamQueue]
    M --> O[SharedQueueService addSong]
    D --> N

    N --> P[Firebase Realtime DB path parties/{partyId}/queue]
    O --> P

    Q[Hosted web page /join-queue.html] --> O
```

## 4. Mobile flow details

## 4.1 Lyric Play (default mobile home)

File: `lib/screens/lyric_home_screen.dart`

### What user does

- Enters or dictates a lyric line.
- Taps `Find & play`.
- Selects from ranked candidates (if multiple).
- Song starts from resolved timestamp.

### What code does

1. Calls `PlaybackServiceMobile.resolveCandidates(query)`.
1. `PlaybackServiceMobile`:
   - Searches LRCLIB across multiple query variants.
   - Hydrates lyric candidates (`getById`) when synced lyrics are missing.
   - Computes best timestamp match for the lyric line.
   - Searches YouTube via `YoutubeMobileService`.
   - Filters short/reel-style videos.
   - Ranks and merges lyric-derived + YouTube-derived candidates.
1. Selected candidate returns `videoId`, `startTimeSeconds`, `trackName`, `artistName`.
1. `YoutubePlayerController.load(...)` plays the selected video from start time.
1. Recents are persisted using `LocalSuggestionsService`:
   - recent lines
   - recent tracks
   - recent search history

### Voice input path

- Uses `speech_to_text` in `LyricHomeScreen`.
- On final speech result, recognized text populates search field.

## 4.2 Host Party (mobile)

File: `lib/screens/host_party_screen.dart`

### What user does

- Opens host mode.
- Gets generated `partyId` and share link/QR.
- Watches queue updates in real time.
- Plays next or clears queue.
- Optionally searches and adds tracks directly.

### What code does

1. Generates party ID: `party_<timestamp>`.
1. Creates `SharedQueueService(partyId: generatedId)`.
1. Subscribes to `streamQueue()` for real-time updates from Firebase.
1. If queue has items, first item is auto-loaded into YouTube player.
1. Share link format:
   - `https://mongobox-79a1f.firebaseapp.com/join-queue.html?partyId=<id>`
1. Guest additions arrive through same Firebase path and reflect live.

## 4.3 Join Party (mobile guest)

Files:

- `lib/screens/join_via_link_screen.dart`
- `lib/screens/join_party_screen.dart`

### What user does

- Pastes/scans host link.
- App extracts `partyId`.
- Searches songs and taps `Add`.

### What code does

1. `JoinViaLinkScreen` parses URL query param `partyId`.
1. If found, navigates to `JoinPartyScreen(partyId: ...)`.
1. `JoinPartyScreen` searches with `YoutubeMobileService`.
1. On add, pushes `Song` to Firebase queue through `SharedQueueService`.

Fallback behavior:

- If no valid `partyId`, link can be opened externally.

## 5. Web flow details

## 5.1 Flutter web home screen

File: `lib/screens/web/home_screen_web.dart`

### Mode split

- If URL contains `partyId`, behaves as guest view for that party.
- Otherwise creates a new party ID and behaves as host.

### Capabilities

- Real-time queue sync via `SharedQueueService`.
- YouTube search and add to queue.
- Embedded playback using an HTML iframe.
- QR dialog with shareable join link.

## 5.2 Hosted join page (`join-queue.html`)

Files:

- `web/join-queue.html` (Firebase hosting target)
- `join-queue.html` (older/local variant)

Production behavior (`web/join-queue.html`):

1. Reads `partyId` from URL.
1. Initializes Firebase JS SDK.
1. Searches YouTube Data API.
1. Pushes selected songs to `parties/{partyId}/queue`.
1. Host apps (mobile/web) receive updates live via Realtime Database stream.

Hosting routes are configured in `firebase.json` so `/join-queue.html` serves this page.

## 6. Service-by-service responsibilities

### `SharedQueueService` (`lib/services/shared_queue_service.dart`)

- Single source of truth for shared queue in Firebase.
- Party-scoped path: `parties/{partyId}/queue`.
- APIs:
  - `streamQueue()`
  - `addSong(...)`
  - `remove(key)`
  - `clear()`
- Caches instances per `partyId` to reuse service objects.

### `YoutubeMobileService` (`lib/services/youtube_mobile_service.dart`)

- YouTube search wrapper for mobile screens.
- Adds filtering for short-form/non-song results.
- Fetches durations from `videos` endpoint for better filtering.
- Caches query results.

### `LyricsService` (`lib/services/lyrics_service.dart`)

- LRCLIB client (`/api/search`, `/api/get/{id}`).
- Computes text similarity and best timed lyric line match.
- Converts matched lyric entry to playable start timestamp.

### `PlaybackServiceMobile` (`lib/services/playback_service_mobile.dart`)

- Orchestrator from lyric input -> ranked playable options.
- Merges LRCLIB-informed and YouTube fallback candidates.
- Applies confidence scoring and start-time preroll.

### `LocalSuggestionsService` (`lib/services/local_suggestions_service.dart`)

- Persists local recent lines/tracks/searches using SharedPreferences.
- Drives suggestion chips/history in `LyricHomeScreen`.

## 7. Data model and storage

### Firebase Realtime Database

Path:

- `parties/{partyId}/queue/{pushKey}`

Song fields (typical):

- `id` (YouTube video ID)
- `title`
- `artist`
- `thumbnail`
- optional web-only `addedAt`

### Local storage (SharedPreferences)

- Lyric recents/searches/tracks (`LocalSuggestionsService`)
- Guest profile (`GuestProfileService`, currently optional flow)
- Legacy local queue (`LocalQueueService`, not in active main flow)

## 8. Screen map

Active main screens:

- `LyricHomeScreen` (mobile default)
- `HostPartyScreen`
- `JoinViaLinkScreen`
- `JoinPartyScreen`
- `web/HomeScreen` (Flutter web)

Available but not currently in primary launch flow:

- `GuestInfoScreen`
- `LoginScreen` (sign-in removed)
- `SuggestSongScreen` in `QR_landing_page.dart` (standalone/legacy)
- `YouTubeService` and `LocalQueueService` (legacy/simple variants)

## 9. End-to-end example (host + guest)

1. Host opens app and taps `Host a party`.
1. App creates `party_...` and starts streaming Firebase queue.
1. Host shares link/QR with `partyId` in query string.
1. Guest opens link in app or browser page.
1. Guest searches YouTube and taps `Add`.
1. Song is pushed to `parties/{partyId}/queue`.
1. Host queue updates instantly from `streamQueue()`.
1. Host playback points at first queue item; `Next` removes it.

## 10. Operational notes

- Firebase app name is fixed as `MongoBox`; all queue operations depend on this initialization in `main.dart`.
- Web and mobile share the same Realtime Database queue path and YouTube API key pattern.
- Logs are verbose by design (debug-heavy) across host/guest and queue services.

