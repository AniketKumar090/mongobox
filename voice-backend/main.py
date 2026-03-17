from __future__ import annotations

import json
import logging
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

import torch
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from starlette.background import BackgroundTask
from TTS.api import TTS


# ── Logging ────────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
)
log = logging.getLogger("mongobox-voice")

# ── App ────────────────────────────────────────────────────────────────────────
app = FastAPI(title="MongoBox Voice Backend", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Flutter on device/simulator
    allow_methods=["POST", "GET"],
    allow_headers=["*"],
)

# ── XTTS model (loaded once at startup) ────────────────────────────────────────
# XTTS-v2 is downloaded once to ~/.local/share/tts on first run.
_tts: TTS | None = None
_device: str = "cpu"



@app.on_event("startup")
def load_model() -> None:
    global _tts, _device
    _device = "cuda" if torch.cuda.is_available() else "cpu"
    log.info("Loading XTTS-v2 on %s …", _device)
    _tts = TTS("tts_models/multilingual/multi-dataset/xtts_v2").to(_device)
    log.info("XTTS-v2 ready ✓")


# ── Helpers ────────────────────────────────────────────────────────────────────

def _strip_section_tags(text: str) -> str:
    """Remove [Verse 1] / [Chorus] headers — keep only singable lines."""
    lines = [
        line
        for line in text.splitlines()
        if line.strip() and not re.match(r"^\\[", line.strip(), re.IGNORECASE)
    ]
    return "\n".join(lines)


def _chunk_lyrics(text: str, max_chars: int = 220) -> list[str]:
    """
    XTTS works best on short sentences (≤ ~250 chars).
    Split on newlines first, then hard-wrap long lines.
    """
    chunks: list[str] = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        while len(line) > max_chars:
            cut = line.rfind(" ", 0, max_chars)
            if cut == -1:
                cut = max_chars
            chunks.append(line[:cut].strip())
            line = line[cut:].strip()
        if line:
            chunks.append(line)
    return chunks


def _convert_to_ref_wav(src: str, dst: str) -> None:
    """
    Convert the uploaded recording to a 22050 Hz mono WAV reference for XTTS.
    Requires system ffmpeg:
      macOS:  brew install ffmpeg
      Ubuntu: sudo apt install ffmpeg
    """
    cmd = [
        "ffmpeg",
        "-y",
        "-i",
        src,
        "-ar",
        "22050",
        "-ac",
        "1",
        "-c:a",
        "pcm_s16le",
        dst,
        "-loglevel",
        "error",
    ]
    try:
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    except FileNotFoundError as exc:
        raise RuntimeError(
            "ffmpeg not found. Install it:\n"
            "  macOS:  brew install ffmpeg\n"
            "  Ubuntu: sudo apt install ffmpeg"
        ) from exc
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or "").strip()
        raise RuntimeError(f"ffmpeg conversion failed: {detail or 'unknown error'}") from exc


def _merge_wav_chunks(chunk_paths: list[str], out_path: str) -> None:
    """Concatenate multiple WAV files into one (all chunks must match format)."""
    import array
    import wave

    out_frames = array.array("h")
    params = None

    for p in chunk_paths:
        with wave.open(p, "rb") as wf:
            if wf.getsampwidth() != 2:
                raise RuntimeError("Unsupported WAV sample width; expected 16-bit PCM.")
            if params is None:
                params = wf.getparams()
            elif wf.getparams() != params:
                raise RuntimeError("WAV chunks have mismatched audio parameters; cannot merge.")
            raw = wf.readframes(wf.getnframes())
            out_frames.frombytes(raw)

    if params is None or not out_frames:
        raise RuntimeError("No audio chunks to merge.")

    with wave.open(out_path, "wb") as wf:
        wf.setparams(params)
        wf.writeframes(out_frames.tobytes())


# ── Language detection helper ──────────────────────────────────────────────────
# XTTS-v2 supported languages:
#   en, es, fr, de, it, pt, pl, tr, ru, nl, cs, ar, zh, ja, hu, ko, hi
def _detect_language_code(text: str) -> str:
    """Heuristic Unicode-script detection, falls back to 'en'."""
    counts: dict[str, int] = {
        "devanagari": 0,
        "arabic": 0,
        "hangul": 0,
        "hiragana": 0,
        "cjk": 0,
        "cyrillic": 0,
    }
    for ch in text:
        cp = ord(ch)
        if 0x0900 <= cp <= 0x097F:
            counts["devanagari"] += 1
        elif 0x0600 <= cp <= 0x06FF:
            counts["arabic"] += 1
        elif 0xAC00 <= cp <= 0xD7AF:
            counts["hangul"] += 1
        elif 0x3040 <= cp <= 0x30FF:
            counts["hiragana"] += 1
        elif 0x4E00 <= cp <= 0x9FFF:
            counts["cjk"] += 1
        elif 0x0400 <= cp <= 0x04FF:
            counts["cyrillic"] += 1

    script_to_lang = {
        "devanagari": "hi",
        "arabic": "ar",
        "hangul": "ko",
        "hiragana": "ja",
        "cjk": "zh",
        "cyrillic": "ru",
    }
    best = max(counts, key=counts.get)
    return script_to_lang[best] if counts[best] >= 5 else "en"


# ── Main endpoint ──────────────────────────────────────────────────────────────

@app.post("/clone")
async def clone_voice(
    voice_sample: UploadFile = File(..., description="Voice sample (.m4a from Flutter recorder)"),
    lyrics: str = Form(..., description="Raw lyrics text (may include section tags)"),
    mood: str = Form("", description="Song mood e.g. Chill"),
    genre: str = Form("", description="Song genre e.g. Lo-fi"),
) -> FileResponse:
    """
    Clone user voice with lyrics.
    """
    if _tts is None:
        raise HTTPException(503, "Model not loaded yet — try again in a moment.")

    if not lyrics.strip():
        raise HTTPException(400, "Lyrics must not be empty.")

    tmp_dir = tempfile.mkdtemp(prefix="mongobox_")
    try:
        # 1) Save upload
        suffix = Path(voice_sample.filename or "voice_sample").suffix or ".bin"
        src_path = os.path.join(tmp_dir, f"voice_sample{suffix}")
        with open(src_path, "wb") as fh:
            shutil.copyfileobj(voice_sample.file, fh)
        log.info("Received voice sample: %s (%d bytes)", suffix, os.path.getsize(src_path))

        # 2) Convert to XTTS reference WAV
        ref_wav = os.path.join(tmp_dir, "reference.wav")
        _convert_to_ref_wav(src_path, ref_wav)

        # 3) Clean + chunk lyrics
        clean_lyrics = _strip_section_tags(lyrics)
        chunks = _chunk_lyrics(clean_lyrics)
        if not chunks:
            raise HTTPException(400, "Lyrics are empty after stripping section tags.")

        detected_lang = _detect_language_code(clean_lyrics)
        log.info(
            "Clone request: chunks=%d lang=%s mood=%s genre=%s",
            len(chunks),
            detected_lang,
            mood or "-",
            genre or "-",
        )

        # 4) XTTS inference (one wav per chunk)
        chunk_wavs: list[str] = []
        for i, chunk in enumerate(chunks):
            out_chunk = os.path.join(tmp_dir, f"chunk_{i:03d}.wav")
            _tts.tts_to_file(
                text=chunk,
                speaker_wav=ref_wav,
                language=detected_lang,
                file_path=out_chunk,
            )
            chunk_wavs.append(out_chunk)

        # 5) Merge
        final_wav = os.path.join(tmp_dir, "cloned_voice.wav")
        if len(chunk_wavs) == 1:
            shutil.copy(chunk_wavs[0], final_wav)
        else:
            _merge_wav_chunks(chunk_wavs, final_wav)

        log.info("Pipeline complete: audio_bytes=%d", os.path.getsize(final_wav))

        # 6) Return WAV file
        return FileResponse(
            final_wav,
            media_type="audio/wav",
            background=BackgroundTask(shutil.rmtree, tmp_dir, ignore_errors=True),
        )

    except HTTPException:
        raise
    except Exception as exc:
        log.exception("Pipeline error: %s", exc)
        raise HTTPException(500, str(exc)) from exc
    finally:
        try:
            await voice_sample.close()
        except Exception:
            pass


# ── Health check ───────────────────────────────────────────────────────────────
@app.get("/health")
def health() -> dict:
    return {
        "status": "ok",
        "model_loaded": _tts is not None,
        "device": _device,
        "cuda": torch.cuda.is_available(),
    }


@app.get("/healthz", include_in_schema=False)
def healthz() -> dict:
    return health()
