# MongoBox Voice Backend

FastAPI server that accepts a voice sample + lyrics and returns a cloned-voice
WAV using **Coqui XTTS-v2** (free, runs locally).

## Features

- Loads **XTTS-v2** once at startup (first run downloads ~2 GB model).
- **Option B**: When `reference_video_id` is provided, downloads the reference song from YouTube, extracts the instrumental stem with **Demucs**, clones the user voice with XTTS, and returns a **mixed track** (cloned vocals + original instrumental). Requires `yt-dlp` and `demucs` (see requirements).
- Accepts the Flutter-recorded `.m4a` (or `.wav`) as `voice_sample`.
- Converts input to a 22050 Hz mono WAV reference via system `ffmpeg`.
- Strips `[Verse 1]` / `[Chorus]` tags, chunks long lyrics, then merges WAV chunks.
- Returns `audio/wav` bytes (Flutter saves `cloned_voice.wav` and plays it).

## Prerequisites

- Python 3.10+
- `ffmpeg`
  - macOS: `brew install ffmpeg`
  - Ubuntu/Debian: `sudo apt install ffmpeg`

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
- `accent_hint` (text, optional): pronunciation hint for English lyrics, one of `indian`, `british`, `american` (defaults to `indian`)
- `tts_language_code` (text, optional): explicit TTS locale, for example `hi-IN` or `en-GB`
- `espeak_voice` (text, optional): eSpeak-NG voice id used as the last fallback, for example `hi` or `en-gb`
- `coqui_model_hint` (text, optional): fallback Coqui model name if XTTS voice cloning fails
- `is_hindi` (text, optional): boolean convenience flag (`1` or `0`) for Hindi and related flows
- `reference_track_title` (text, optional): source song title for pronunciation guidance
- `reference_artist_name` (text, optional): source singer/artist for pronunciation guidance
- `reference_lyric_snippet` (text, optional): lyric snippet from the selected song
- `reference_video_id` (text, optional): YouTube video ID of the reference song. When provided, the backend downloads the track, extracts the instrumental with Demucs, mixes it with the cloned vocals, and returns a single blended WAV. First run downloads the Demucs model (~1 GB).

Returns: `audio/wav` (voice-only if no `reference_video_id`, or voice+instrumental mixed when provided)

### `POST /clone/cancel`

`multipart/form-data`:

- `request_id` (text, required): the active clone request id to cancel

Language behavior:

- XTTS-v2 is still the primary engine and now honors Flutter's explicit `tts_language_code`.
- If XTTS cannot synthesize, the backend tries the provided `coqui_model_hint`.
- If that also fails, it falls back to `espeak-ng` with the provided `espeak_voice`.

### `GET /health`

Returns JSON:

```json
{ "status": "ok", "model_loaded": true, "device": "cpu", "cuda": false }
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
- Physical device: your machine LAN IP (e.g. `http://192.168.1.42:8000`)

## Troubleshooting

| Error | Fix |
|-------|-----|
| `RuntimeError: cannot cache function... no locator available` | Numba/librosa cache issue. Set `NUMBA_DISABLE_JIT_CACHE=1` before starting (already done in `start.py`). If running uvicorn directly, run: `NUMBA_DISABLE_JIT_CACHE=1 uvicorn main:app --host 127.0.0.1 --port 8000` |
| `FileNotFoundError: yt-dlp` or `demucs` | The backend uses `python -m yt_dlp` and `python -m demucs` so they run in the same environment. Ensure deps are installed: `pip install -r requirements.txt` |
| `No space left on device` | Free disk space. Numba and model downloads need writable temp/cache dirs. |
| Python version mismatch | Use a venv: `python -m venv .venv && source .venv/bin/activate` then `pip install -r requirements.txt` and `python start.py` |

## Tools

```bash
python analyze_voice.py path/to/voice_sample.m4a
python test_pipeline.py --synthetic
python test_pipeline.py --sample path/to/voice_sample.m4a
```
