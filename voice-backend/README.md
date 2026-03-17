# MongoBox Voice Backend

FastAPI server that accepts a voice sample + lyrics and returns a cloned-voice
WAV using **Coqui XTTS-v2** (free, runs locally).

## Features

- Loads **XTTS-v2** once at startup (first run downloads ~2 GB model).
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

Returns: `audio/wav`

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

## Tools

```bash
python analyze_voice.py path/to/voice_sample.m4a
python test_pipeline.py --synthetic
python test_pipeline.py --sample path/to/voice_sample.m4a
```
