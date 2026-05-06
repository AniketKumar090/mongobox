# MongoBox Voice Backend

FastAPI server that accepts a voice sample + lyrics and returns a cloned-voice
WAV via **Voicebox** only. Cloning always goes through your Voicebox server at
`VOICEBOX_API_URL`; this repo does not run NeuTTS or on-device synthesis.

## Features

- Proxies synthesis to Voicebox while keeping the MongoBox `POST /clone`
  contract used by Flutter.
- `POST /voicebox/profile/bootstrap` creates or updates a Voicebox profile from
  the recorded sample (call this from the recording screen, then pass
  `voicebox_profile_id` into `/clone`).
- Strips `[Verse]` section tags, chunks long lyrics, merges WAV chunks.
- Optional background stem: when `reference_video_id` is set, downloads audio,
  runs **Demucs**, and exposes instrumental as a separate URL header (Flutter
  mixes with two players).

## Prerequisites

- Python 3.10+
- **ffmpeg** (for WAV normalization and yt-dlp conversions)
- A running **Voicebox** instance reachable at `VOICEBOX_API_URL` (default
  `http://127.0.0.1:17493`)

## Quick start

```bash
cd voice-backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
export VOICEBOX_API_URL=http://127.0.0.1:17493   # your Voicebox URL
python start.py --host 0.0.0.0
```

`start.py` sets `MONGOBOX_TTS_ENGINE=voicebox` by default.

## API

### `POST /clone`

`multipart/form-data`:

- `voice_sample` (file, required)
- `lyrics` (text, required)
- `mood`, `genre`, `language`, `tts_language_code` (optional)
- `reference_*` fields for context / YouTube instrumental (`reference_video_id`)
- `voicebox_profile_id` (optional): reuse profile from bootstrap

If Voicebox is unreachable, responds **503** with a clear message.

### `POST /voicebox/profile/bootstrap`

Prepares a Voicebox profile from `voice_sample`. See form fields in `main.py`.

### `GET /health`

```json
{
  "status": "ok",
  "voicebox_api_url": "http://127.0.0.1:17493",
  "voicebox_available": true,
  "voicebox_detail": "ok"
}
```

## Flutter

Point `VOICE_BACKEND_URL` (and `VOICE_BACKEND_DEVICE_URL` on a physical iPhone)
at this FastAPI server. Ensure Voicebox is running wherever `VOICEBOX_API_URL`
on the backend host resolves.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `Voicebox unavailable` / 503 on `/clone` | Start Voicebox; check `VOICEBOX_API_URL` and firewall. |
| Demucs / yt-dlp errors | `pip install -r requirements.txt` in the same venv; install **ffmpeg**. |
| Numba cache errors | `NUMBA_DISABLE_JIT_CACHE=1` is set in `start.py` / `main.py` by default. |
