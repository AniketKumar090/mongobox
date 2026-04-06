# MongoBox Voice Backend

FastAPI server that accepts a voice sample + lyrics and returns a cloned-voice
WAV using **NeuTTS** (free, runs locally).

## Features

- Loads a default **NeuTTS** backbone once at startup, then lazy-loads other
  supported backbones on demand.
- Keeps the same `POST /clone` contract used by the Flutter app.
- Accepts the Flutter-recorded `.m4a` (or `.wav`) as `voice_sample`.
- Converts input to a mono WAV reference via system `ffmpeg`.
- Best-effort local transcription of the reference sample for NeuTTS prompting
  when the app does not provide a transcript yet.
- Strips `[Verse 1]` / `[Chorus]` tags, chunks long lyrics, then merges WAV
  chunks.
- **Option B**: when `reference_video_id` is provided, downloads the reference
  song from YouTube, extracts the instrumental stem with **Demucs**, clones the
  user voice, and returns a mixed track.
- Falls back to `espeak` / `espeak-ng` when the requested language does not yet
  have a NeuTTS backbone in this backend.

## Current language behavior

- NeuTTS is the primary engine for English, Spanish, German, and French flows.
- Hindi-family flows still keep the transliteration pipeline, but synthesis
  falls back to eSpeak because NeuTTS does not currently ship a Hindi backbone
  in this backend.

## Prerequisites

- Python 3.10+
- `ffmpeg`
  - macOS: `brew install ffmpeg`
  - Ubuntu/Debian: `sudo apt install ffmpeg`
- `espeak` or `espeak-ng`
  - macOS: `brew install espeak`
  - Ubuntu/Debian: `sudo apt install espeak-ng`

## Quick start

```bash
cd voice-backend
python -m venv .venv
source .venv/bin/activate
python start.py
```

## API

### `POST /clone`

`multipart/form-data`:

- `voice_sample` (file, required): `.m4a` / `.wav`
- `lyrics` (text, required)
- `mood` (text, optional)
- `genre` (text, optional)
- `language` (text, optional): requested lyric language, for example `Urdu`
- `accent_hint` (text, optional): pronunciation hint for English lyrics, one of
  `indian`, `british`, `american`
- `tts_language_code` (text, optional): explicit TTS locale, for example
  `en-GB`
- `espeak_voice` (text, optional): eSpeak voice id used as fallback, for
  example `hi` or `en-gb`
- `coqui_model_hint` (text, optional): ignored by the NeuTTS backend but still
  accepted for compatibility with the Flutter client
- `is_hindi` (text, optional): boolean convenience flag (`1` or `0`) for Hindi
  and related flows
- `reference_track_title` (text, optional): source song title for pronunciation
  guidance
- `reference_artist_name` (text, optional): source singer or artist for
  pronunciation guidance
- `reference_lyric_snippet` (text, optional): lyric snippet from the selected
  song
- `reference_transcript` (text, optional): transcript of the uploaded voice
  sample. If omitted, the backend attempts local transcription.
- `reference_video_id` (text, optional): YouTube video ID of the reference
  song. When provided, the backend downloads the track, extracts the
  instrumental with Demucs, mixes it with the cloned vocals, and returns a
  single blended WAV.

Returns: `audio/wav` (voice-only if no `reference_video_id`, or voice plus
instrumental mixed when provided)

### `POST /clone/cancel`

`multipart/form-data`:

- `request_id` (text, required): the active clone request id to cancel

### `GET /health`

Returns JSON similar to:

```json
{
  "status": "ok",
  "model_loaded": true,
  "device": "cpu",
  "cuda": false,
  "engine": "neutts",
  "loaded_backbones": ["neuphonic/neutts-air"]
}
```

## Flutter configuration

`VoiceSongScreen` posts to `VOICE_BACKEND_URL/clone`. You can set it via
`--dart-define`:

```bash
flutter run --dart-define=VOICE_BACKEND_URL=http://127.0.0.1:8000
```

Platform notes:

- iOS Simulator: `127.0.0.1`
- Android Emulator: `10.0.2.2`
- Physical device: your machine LAN IP (for example `http://192.168.1.42:8000`)

## Troubleshooting

| Error | Fix |
|-------|-----|
| `RuntimeError: cannot cache function... no locator available` | Numba or librosa cache issue. Set `NUMBA_DISABLE_JIT_CACHE=1` before starting. |
| `Reference transcription failed` | The backend will keep going, but quality may drop. Restart after dependencies finish installing, or send `reference_transcript` from the app later. |
| `FileNotFoundError: yt-dlp` or `demucs` | Ensure deps are installed in the same venv: `pip install -r requirements.txt` |
| `No space left on device` | Free disk space. Model downloads and temp audio files need writable storage. |
| `eSpeak was not found` | Install `espeak` or `espeak-ng`, then restart the backend. |

## Notes

- The first run can take a while because NeuTTS weights and the optional local
  reference transcription model may download.
- This backend keeps the existing Flutter contract stable while swapping the
  primary synthesis engine under the hood.
