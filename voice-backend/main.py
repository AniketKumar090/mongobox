from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass

# Disable numba JIT cache if disk/cache dir is unwritable (avoids RuntimeError)
os.environ.setdefault("NUMBA_DISABLE_JIT_CACHE", "1")
import re
import shutil
import subprocess
import sys
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
_fallback_tts_models: dict[str, TTS] = {}


@dataclass(frozen=True)
class CloneRequestParams:
    lyrics: str
    mood: str
    genre: str
    language: str
    accent_hint: str
    tts_language_code: str
    espeak_voice: str
    coqui_model_hint: str
    is_hindi: bool
    reference_track_title: str
    reference_artist_name: str
    reference_lyric_snippet: str
    reference_video_id: str



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
        if line.strip() and not re.match(r"^\[", line.strip(), re.IGNORECASE)
    ]
    return "\n".join(lines)


def _parse_bool_flag(value: str) -> bool:
    return (value or "").strip().lower() in {"1", "true", "yes", "y", "on"}


def _parse_clone_request(
    *,
    lyrics: str,
    mood: str,
    genre: str,
    language: str,
    accent_hint: str,
    tts_language_code: str,
    espeak_voice: str,
    coqui_model_hint: str,
    is_hindi: str,
    reference_track_title: str,
    reference_artist_name: str,
    reference_lyric_snippet: str,
    reference_video_id: str,
) -> CloneRequestParams:
    return CloneRequestParams(
        lyrics=lyrics,
        mood=mood,
        genre=genre,
        language=language,
        accent_hint=accent_hint,
        tts_language_code=tts_language_code,
        espeak_voice=espeak_voice,
        coqui_model_hint=coqui_model_hint,
        is_hindi=_parse_bool_flag(is_hindi),
        reference_track_title=reference_track_title,
        reference_artist_name=reference_artist_name,
        reference_lyric_snippet=reference_lyric_snippet,
        reference_video_id=reference_video_id,
    )


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


def _run_ffmpeg_wav_convert(src: str, dst: str, sample_rate: int, channels: int = 1) -> None:
    """Convert audio to a normalized PCM WAV format with ffmpeg."""
    cmd = [
        "ffmpeg",
        "-y",
        "-i",
        src,
        "-ar",
        str(sample_rate),
        "-ac",
        str(channels),
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


def _convert_to_ref_wav(src: str, dst: str) -> None:
    """
    Convert the uploaded recording to a 22050 Hz mono WAV reference for XTTS.
    Requires system ffmpeg:
      macOS:  brew install ffmpeg
      Ubuntu: sudo apt install ffmpeg
    """
    _run_ffmpeg_wav_convert(src, dst, sample_rate=22050, channels=1)


def _normalize_generated_wav(src: str, dst: str) -> None:
    """Normalize XTTS output to a consistent mergeable WAV format."""
    _run_ffmpeg_wav_convert(src, dst, sample_rate=24000, channels=1)


def _merge_wav_chunks(chunk_paths: list[str], out_path: str) -> None:
    """Concatenate multiple WAV files into one (all chunks must match format)."""
    import array
    import wave

    out_frames = array.array("h")
    format_params = None

    for p in chunk_paths:
        with wave.open(p, "rb") as wf:
            if wf.getsampwidth() != 2:
                raise RuntimeError("Unsupported WAV sample width; expected 16-bit PCM.")
            current_format = (
                wf.getnchannels(),
                wf.getsampwidth(),
                wf.getframerate(),
                wf.getcomptype(),
                wf.getcompname(),
            )
            if format_params is None:
                format_params = current_format
            elif current_format != format_params:
                raise RuntimeError("WAV chunks have mismatched audio parameters; cannot merge.")
            raw = wf.readframes(wf.getnframes())
            out_frames.frombytes(raw)

    if format_params is None or not out_frames:
        raise RuntimeError("No audio chunks to merge.")

    with wave.open(out_path, "wb") as wf:
        wf.setnchannels(format_params[0])
        wf.setsampwidth(format_params[1])
        wf.setframerate(format_params[2])
        wf.setcomptype(format_params[3], format_params[4])
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


def _resolve_language_code(
    language_hint: str,
    text: str,
    genre_hint: str = "",
    reference_track_title: str = "",
    reference_artist_name: str = "",
    reference_lyric_snippet: str = "",
    tts_language_code: str = "",
    is_hindi: bool = False,
) -> str:
    explicit_tts_code = re.sub(r"[^a-z\-]+", "", (tts_language_code or "").strip().lower())
    normalized = re.sub(r"[^a-z]+", " ", (language_hint or "").strip().lower()).strip()
    combined_reference_text = "\n".join(
        part
        for part in [
            text,
            reference_lyric_snippet,
            reference_track_title,
            reference_artist_name,
            genre_hint,
        ]
        if part and part.strip()
    )

    supported_xtts_codes = {
        "en",
        "es",
        "fr",
        "de",
        "it",
        "pt",
        "pl",
        "tr",
        "ru",
        "nl",
        "cs",
        "ar",
        "zh",
        "ja",
        "hu",
        "ko",
        "hi",
    }

    if explicit_tts_code:
        prefix = explicit_tts_code.split("-", 1)[0]
        explicit_map = {
            "en": "en",
            "es": "es",
            "fr": "fr",
            "de": "de",
            "it": "it",
            "pt": "pt",
            "pl": "pl",
            "tr": "tr",
            "ru": "ru",
            "nl": "nl",
            "cs": "cs",
            "ar": "ar",
            "zh": "zh",
            "ja": "ja",
            "hu": "hu",
            "ko": "ko",
            "hi": "hi",
            "ur": "ar" if re.search(r"[\u0600-\u06FF]", combined_reference_text) else "hi",
            "pa": "hi",
            "bn": "hi",
            "ta": "hi",
            "te": "hi",
            "mr": "hi",
            "gu": "hi",
            "kn": "hi",
            "ml": "hi",
        }
        mapped = explicit_map.get(prefix)
        if mapped in supported_xtts_codes:
            return mapped

    if is_hindi:
        return "hi"

    combined_lower = combined_reference_text.lower()
    if normalized:
        hint_map = {
            "english": "en",
            "spanish": "es",
            "french": "fr",
            "german": "de",
            "italian": "it",
            "portuguese": "pt",
            "polish": "pl",
            "turkish": "tr",
            "russian": "ru",
            "dutch": "nl",
            "czech": "cs",
            "arabic": "ar",
            "chinese": "zh",
            "japanese": "ja",
            "hungarian": "hu",
            "korean": "ko",
            "hindi": "hi",
            # XTTS-v2 does not expose Urdu directly. Use the closest supported
            # language based on the script used by the generated lyrics.
            "urdu": "ar" if re.search(r"[\u0600-\u06FF]", combined_reference_text) else "hi",
        }
        if normalized in hint_map:
            return hint_map[normalized]

    south_asian_markers = {
        "urdu": "ar" if re.search(r"[\u0600-\u06FF]", combined_reference_text) else "hi",
        "hindi": "hi",
        "bollywood": "hi",
        "ghazal": "ar" if re.search(r"[\u0600-\u06FF]", combined_reference_text) else "hi",
        "qawwali": "ar" if re.search(r"[\u0600-\u06FF]", combined_reference_text) else "hi",
    }
    for token, lang_code in south_asian_markers.items():
        if token in combined_lower:
            return lang_code

    return _detect_language_code(combined_reference_text)


def _resolve_pronunciation_profile(
    language_hint: str,
    genre_hint: str,
    reference_track_title: str,
    reference_artist_name: str,
    reference_lyric_snippet: str,
) -> str:
    combined = " ".join(
        part.lower()
        for part in [
            language_hint,
            genre_hint,
            reference_track_title,
            reference_artist_name,
            reference_lyric_snippet,
        ]
        if part and part.strip()
    )
    if any(token in combined for token in ["urdu", "hindi", "bollywood", "ghazal", "qawwali", "desi"]):
        return "south_asian"
    return "default"


def _resolve_accent_hint(
    accent_hint: str,
    language_hint: str,
    genre_hint: str,
    reference_track_title: str,
    reference_artist_name: str,
    reference_lyric_snippet: str,
    is_hindi: bool = False,
) -> str:
    """
    Best-effort accent resolver.

    We can't truly "extract" an artist's accent from metadata, but we can use
    metadata as a heuristic hint for English pronunciation shaping.
    """
    normalized = re.sub(r"[^a-z]+", " ", (accent_hint or "").strip().lower()).strip()
    if normalized in {"indian", "british", "american"}:
        return normalized
    if normalized in {"hindi", "urdu", "punjabi", "desi", "south asian"}:
        return "indian"

    combined = " ".join(
        part.lower()
        for part in [
            language_hint,
            genre_hint,
            reference_track_title,
            reference_artist_name,
            reference_lyric_snippet,
        ]
        if part and part.strip()
    )
    if is_hindi:
        return "indian"
    # If metadata suggests South Asian content, prefer Indian.
    if any(token in combined for token in ["urdu", "hindi", "bollywood", "ghazal", "qawwali", "desi"]):
        return "indian"

    # Default (requested): Indian accent when uncertain.
    return "indian"


_INDIAN_EN_REPLACEMENTS: list[tuple[re.Pattern[str], str]] = [
    # "th" becomes closer to "t/d" often; we avoid changing inside common proper nouns.
    (re.compile(r"\bthis\b", re.IGNORECASE), "dis"),
    (re.compile(r"\bthat\b", re.IGNORECASE), "dat"),
    (re.compile(r"\bthese\b", re.IGNORECASE), "dese"),
    (re.compile(r"\bthose\b", re.IGNORECASE), "dose"),
    (re.compile(r"\bthink\b", re.IGNORECASE), "tink"),
    (re.compile(r"\bthing\b", re.IGNORECASE), "ting"),
    (re.compile(r"\bthree\b", re.IGNORECASE), "tree"),
    (re.compile(r"\bthrough\b", re.IGNORECASE), "troo"),
    (re.compile(r"\bwith\b", re.IGNORECASE), "wit"),
    # Soft "v/w" confusion: nudge "v" -> "w" in some high-frequency words only.
    (re.compile(r"\bvery\b", re.IGNORECASE), "wery"),
    (re.compile(r"\blove\b", re.IGNORECASE), "luv"),
]


def _shape_english_pronunciation(text: str, accent: str) -> str:
    """
    Nudge pronunciation by respelling a few English tokens.

    This is deliberately conservative to avoid mangling lyrics. It's only used
    when XTTS language is English.
    """
    if accent != "indian":
        return text
    shaped = text
    for pattern, replacement in _INDIAN_EN_REPLACEMENTS:
        shaped = pattern.sub(replacement, shaped)
    return shaped


def _get_or_load_tts_model(model_name: str) -> TTS:
    model_key = (model_name or "").strip()
    if not model_key:
        raise RuntimeError("No Coqui model hint was provided for fallback synthesis.")

    model = _fallback_tts_models.get(model_key)
    if model is not None:
        return model

    log.info("Loading fallback TTS model %s …", model_key)
    model = TTS(model_key)
    try:
        model = model.to(_device)
    except Exception:
        log.info("Fallback model %s stays on its default device", model_key)
    _fallback_tts_models[model_key] = model
    return model


def _synthesise_chunks_with_xtts(
    *,
    chunks: list[str],
    speaker_wav: str,
    xtts_language: str,
    accent: str,
    tmp_dir: str,
) -> list[str]:
    if _tts is None:
        raise RuntimeError("XTTS model is not loaded yet.")

    chunk_wavs: list[str] = []
    for i, chunk in enumerate(chunks):
        spoken_chunk = (
            _shape_english_pronunciation(chunk, accent=accent)
            if xtts_language == "en"
            else chunk
        )
        out_chunk = os.path.join(tmp_dir, f"chunk_{i:03d}_raw.wav")
        _tts.tts_to_file(
            text=spoken_chunk,
            speaker_wav=speaker_wav,
            language=xtts_language,
            file_path=out_chunk,
        )
        normalized_chunk = os.path.join(tmp_dir, f"chunk_{i:03d}.wav")
        _normalize_generated_wav(out_chunk, normalized_chunk)
        chunk_wavs.append(normalized_chunk)
    return chunk_wavs


def _synthesise_chunks_with_coqui_model(
    *,
    chunks: list[str],
    model_name: str,
    tmp_dir: str,
) -> list[str]:
    model = _get_or_load_tts_model(model_name)
    chunk_wavs: list[str] = []
    for i, chunk in enumerate(chunks):
        out_chunk = os.path.join(tmp_dir, f"chunk_{i:03d}_fallback_raw.wav")
        model.tts_to_file(text=chunk, file_path=out_chunk)
        normalized_chunk = os.path.join(tmp_dir, f"chunk_{i:03d}_fallback.wav")
        _normalize_generated_wav(out_chunk, normalized_chunk)
        chunk_wavs.append(normalized_chunk)
    return chunk_wavs


def _synthesise_chunks_with_espeak(
    *,
    chunks: list[str],
    espeak_voice: str,
    tmp_dir: str,
) -> list[str]:
    voice = (espeak_voice or "").strip() or "en-gb"
    chunk_wavs: list[str] = []
    for i, chunk in enumerate(chunks):
        raw_chunk = os.path.join(tmp_dir, f"chunk_{i:03d}_espeak_raw.wav")
        cmd = ["espeak-ng", "-v", voice, "-w", raw_chunk, chunk]
        try:
            subprocess.run(
                cmd,
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )
        except FileNotFoundError as exc:
            raise RuntimeError(
                "espeak-ng not found. Install it:\n"
                "  macOS: brew install espeak-ng\n"
                "  Ubuntu: sudo apt install espeak-ng"
            ) from exc
        except subprocess.CalledProcessError as exc:
            detail = (exc.stderr or "").strip()
            raise RuntimeError(f"espeak-ng synthesis failed: {detail or 'unknown error'}") from exc

        normalized_chunk = os.path.join(tmp_dir, f"chunk_{i:03d}_espeak.wav")
        _normalize_generated_wav(raw_chunk, normalized_chunk)
        chunk_wavs.append(normalized_chunk)
    return chunk_wavs


# ── Option B: extract instrumental from reference song & mix ────────────────────

def _download_youtube_audio(video_id: str, out_path: str, tmp_dir: str) -> bool:
    """Download audio from YouTube via yt-dlp. Returns True on success."""
    if not video_id or not video_id.strip():
        return False
    url = f"https://www.youtube.com/watch?v={video_id.strip()}"
    template = os.path.join(tmp_dir, "yt_audio.%(ext)s")
    cmd = [
        sys.executable, "-m", "yt_dlp",
        "-x",
        "--audio-format", "best",
        "-o", template,
        "--no-playlist",
        "--no-warnings",
        "--geo-bypass",
        url,
    ]
    try:
        subprocess.run(cmd, check=True, capture_output=True, text=True, timeout=180, cwd=tmp_dir)
        import glob
        for f in glob.glob(os.path.join(tmp_dir, "yt_audio.*")):
            if os.path.isfile(f):
                if f.lower().endswith(".wav"):
                    shutil.move(f, out_path)
                else:
                    _run_ffmpeg_wav_convert(f, out_path, sample_rate=44100, channels=1)
                return True
        return False
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        log.warning("yt-dlp download failed for %s: %s", video_id, e)
        return False


def _separate_instrumental(audio_path: str, out_dir: str) -> str | None:
    """Run Demucs to extract no_vocals stem. Returns path to no_vocals.wav or None."""
    demucs_out = os.path.join(out_dir, "demucs_out")
    cmd = [
        sys.executable, "-m", "demucs",
        "-n", "htdemucs",
        "--two-stems", "vocals",
        "-o", demucs_out,
        audio_path,
    ]
    try:
        subprocess.run(cmd, check=True, capture_output=True, text=True, timeout=600, cwd=out_dir)
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        log.warning("Demucs separation failed: %s", e)
        return None

    # Demucs outputs: demucs_out/htdemucs/<track_name>/no_vocals.wav
    base = os.path.splitext(os.path.basename(audio_path))[0]
    for model_dir in ["htdemucs", "htdemucs_ft"]:
        track_dir = os.path.join(demucs_out, model_dir, base)
        no_vocals = os.path.join(track_dir, "no_vocals.wav")
        if os.path.isfile(no_vocals):
            return no_vocals
    # Fallback: any no_vocals.wav under demucs_out
    for root, _, files in os.walk(demucs_out):
        if "no_vocals.wav" in files:
            return os.path.join(root, "no_vocals.wav")
    return None


def _get_wav_duration_seconds(path: str) -> float:
    import wave
    with wave.open(path, "rb") as wf:
        frames = wf.getnframes()
        rate = wf.getframerate()
        return frames / float(rate) if rate else 0.0


def _mix_vocal_with_instrumental(
    vocal_path: str,
    instrumental_path: str,
    out_path: str,
    vocal_gain: float = 0.64,
    instrumental_gain: float = 1.18,
) -> None:
    """
    Mix cloned vocal with extracted instrumental.
    Trims instrumental to vocal length. Output 44100 Hz mono.

    Keeps the bed at least as present as the vocal: attenuate the clone slightly
    and boost the instrumental before amix (plain amix tends to sound vocal-heavy).
    """
    duration = _get_wav_duration_seconds(vocal_path)
    if duration <= 0:
        shutil.copy(vocal_path, out_path)
        return

    # Convert vocal to 44100 for mixing (XTTS is 24k)
    vocal_44 = out_path + ".vocal_44.wav"
    _run_ffmpeg_wav_convert(vocal_path, vocal_44, sample_rate=44100, channels=1)

    # Trim instrumental to vocal length, convert to 44100 mono (gain applied in filter graph)
    inst_44 = out_path + ".inst_44.wav"
    cmd = [
        "ffmpeg", "-y",
        "-i", instrumental_path,
        "-t", str(duration),
        "-ar", "44100",
        "-ac", "1",
        "-c:a", "pcm_s16le",
        inst_44,
        "-loglevel", "error",
    ]
    subprocess.run(cmd, check=True, capture_output=True, timeout=60)

    # Mix: weighted amix so background is not quieter than the cloned vocal
    mix = (
        f"[0:a]volume={vocal_gain}[v];"
        f"[1:a]volume={instrumental_gain}[i];"
        "[v][i]amix=inputs=2:duration=first:dropout_transition=0"
    )
    cmd = [
        "ffmpeg", "-y",
        "-i", vocal_44,
        "-i", inst_44,
        "-filter_complex", mix,
        "-ac", "1",
        "-c:a", "pcm_s16le",
        out_path,
        "-loglevel", "error",
    ]
    subprocess.run(cmd, check=True, capture_output=True, timeout=60)
    for p in [vocal_44, inst_44]:
        try:
            os.remove(p)
        except OSError:
            pass


# ── Main endpoint ──────────────────────────────────────────────────────────────

@app.post("/clone")
async def clone_voice(
    voice_sample: UploadFile = File(..., description="Voice sample (.m4a from Flutter recorder)"),
    lyrics: str = Form(..., description="Raw lyrics text (may include section tags)"),
    mood: str = Form("", description="Song mood e.g. Chill"),
    genre: str = Form("", description="Song genre e.g. Lo-fi"),
    language: str = Form("", description="Requested song language e.g. Urdu"),
    accent_hint: str = Form("", description="Pronunciation/accent hint e.g. indian/british/american"),
    tts_language_code: str = Form("", description="Explicit TTS language code e.g. hi-IN or en-GB"),
    espeak_voice: str = Form("", description="eSpeak-NG voice id used for last-resort synthesis"),
    coqui_model_hint: str = Form("", description="Fallback Coqui model name if XTTS cannot be used"),
    is_hindi: str = Form("", description="Convenience boolean for Hindi or other South-Asian flows"),
    reference_track_title: str = Form("", description="Reference song title used for lyric generation"),
    reference_artist_name: str = Form("", description="Reference artist name used for lyric generation"),
    reference_lyric_snippet: str = Form("", description="Reference lyric snippet used for lyric generation"),
    reference_video_id: str = Form("", description="Reference video id"),
) -> FileResponse:
    """
    Clone user voice with lyrics.
    """
    if not lyrics.strip():
        raise HTTPException(400, "Lyrics must not be empty.")

    params = _parse_clone_request(
        lyrics=lyrics,
        mood=mood,
        genre=genre,
        language=language,
        accent_hint=accent_hint,
        tts_language_code=tts_language_code,
        espeak_voice=espeak_voice,
        coqui_model_hint=coqui_model_hint,
        is_hindi=is_hindi,
        reference_track_title=reference_track_title,
        reference_artist_name=reference_artist_name,
        reference_lyric_snippet=reference_lyric_snippet,
        reference_video_id=reference_video_id,
    )

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
        clean_lyrics = _strip_section_tags(params.lyrics)
        chunks = _chunk_lyrics(clean_lyrics)
        if not chunks:
            raise HTTPException(400, "Lyrics are empty after stripping section tags.")

        detected_lang = _resolve_language_code(
            params.language,
            clean_lyrics,
            genre_hint=params.genre,
            reference_track_title=params.reference_track_title,
            reference_artist_name=params.reference_artist_name,
            reference_lyric_snippet=params.reference_lyric_snippet,
            tts_language_code=params.tts_language_code,
            is_hindi=params.is_hindi,
        )
        pronunciation_profile = _resolve_pronunciation_profile(
            params.language,
            params.genre,
            params.reference_track_title,
            params.reference_artist_name,
            params.reference_lyric_snippet,
        )
        accent = _resolve_accent_hint(
            params.accent_hint,
            params.language,
            params.genre,
            params.reference_track_title,
            params.reference_artist_name,
            params.reference_lyric_snippet,
            is_hindi=params.is_hindi,
        )
        log.info(
            "Clone request: chunks=%d lang=%s accent=%s pronunciation_profile=%s requested_language=%s tts_language_code=%s espeak_voice=%s coqui_model_hint=%s is_hindi=%s mood=%s genre=%s reference=%s / %s video=%s",
            len(chunks),
            detected_lang,
            accent,
            pronunciation_profile,
            params.language or "-",
            params.tts_language_code or "-",
            params.espeak_voice or "-",
            params.coqui_model_hint or "-",
            params.is_hindi,
            params.mood or "-",
            params.genre or "-",
            params.reference_track_title or "-",
            params.reference_artist_name or "-",
            params.reference_video_id or "-",
        )

        # 4) Synthesis: prefer XTTS voice cloning, then degrade gracefully.
        chunk_wavs: list[str]
        synthesis_engine = "xtts_v2"
        try:
            chunk_wavs = _synthesise_chunks_with_xtts(
                chunks=chunks,
                speaker_wav=ref_wav,
                xtts_language=detected_lang,
                accent=accent,
                tmp_dir=tmp_dir,
            )
        except Exception as xtts_exc:
            log.warning("XTTS synthesis failed (%s); attempting fallbacks", xtts_exc)
            fallback_model = (params.coqui_model_hint or "").strip()
            can_try_fallback_model = (
                fallback_model and "xtts_v2" not in fallback_model.lower()
            )

            if can_try_fallback_model:
                try:
                    chunk_wavs = _synthesise_chunks_with_coqui_model(
                        chunks=chunks,
                        model_name=fallback_model,
                        tmp_dir=tmp_dir,
                    )
                    synthesis_engine = fallback_model
                except Exception as fallback_exc:
                    log.warning(
                        "Fallback Coqui model failed (%s); trying eSpeak-NG",
                        fallback_exc,
                    )
                    espeak_fallback_voice = (
                        (params.espeak_voice or "").strip()
                        or ("hi" if params.is_hindi else "en-gb")
                    )
                    chunk_wavs = _synthesise_chunks_with_espeak(
                        chunks=chunks,
                        espeak_voice=espeak_fallback_voice,
                        tmp_dir=tmp_dir,
                    )
                    synthesis_engine = f"espeak:{espeak_fallback_voice}"
            else:
                espeak_fallback_voice = (
                    (params.espeak_voice or "").strip()
                    or ("hi" if params.is_hindi else "en-gb")
                )
                chunk_wavs = _synthesise_chunks_with_espeak(
                    chunks=chunks,
                    espeak_voice=espeak_fallback_voice,
                    tmp_dir=tmp_dir,
                )
                synthesis_engine = f"espeak:{espeak_fallback_voice}"

        # 5) Merge
        final_wav = os.path.join(tmp_dir, "cloned_voice.wav")
        if len(chunk_wavs) == 1:
            shutil.copy(chunk_wavs[0], final_wav)
        else:
            _merge_wav_chunks(chunk_wavs, final_wav)

        mix_status = "voice_only"
        mix_label = ""

        # 5b) Option B: if reference video ID provided, extract instrumental & mix
        video_id = (params.reference_video_id or "").strip()
        if video_id:
            yt_wav = os.path.join(tmp_dir, "yt_reference.wav")
            if _download_youtube_audio(video_id, yt_wav, tmp_dir):
                inst_path = _separate_instrumental(yt_wav, tmp_dir)
                if inst_path:
                    mixed_wav = os.path.join(tmp_dir, "cloned_mixed.wav")
                    _mix_vocal_with_instrumental(final_wav, inst_path, mixed_wav)
                    final_wav = mixed_wav
                    mix_status = "mixed"
                    mix_label = "Original instrumental mixed into preview"
                    log.info("Mixed cloned voice with extracted instrumental")
                else:
                    log.warning("Demucs separation failed; returning voice-only")
            else:
                log.warning("YouTube download failed; returning voice-only")

        log.info(
            "Pipeline complete: audio_bytes=%d synthesis_engine=%s",
            os.path.getsize(final_wav),
            synthesis_engine,
        )

        # 6) Return WAV file
        return FileResponse(
            final_wav,
            media_type="audio/wav",
            headers={
                "X-MongoBox-Mix-Status": mix_status,
                "X-MongoBox-Mix-Label": mix_label,
            },
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
def _detect_bpm(audio_path: str) -> float | None:
    """Detect BPM of audio file using librosa. Returns BPM or None on failure."""
    try:
        import librosa
        y, sr = librosa.load(audio_path, sr=22050, mono=True, duration=60)
        tempo, _ = librosa.beat.beat_track(y=y, sr=sr)
        if isinstance(tempo, (list, tuple)):
            tempo = float(tempo[0]) if tempo else 0.0
        else:
            tempo = float(tempo)
        return round(tempo, 1) if 50 <= tempo <= 220 else None
    except Exception as e:
        log.warning("BPM detection failed: %s", e)
        return None


@app.get("/analyze-bpm")
def analyze_bpm(video_id: str = "") -> dict:
    """
    Detect BPM of a YouTube track by video_id.
    Downloads audio, runs beat tracking, returns {"bpm": float} or {"bpm": null, "error": "..."}.
    """
    video_id = (video_id or "").strip()
    if not video_id:
        return {"bpm": None, "error": "video_id required"}
    tmp_dir = tempfile.mkdtemp(prefix="mongobox_bpm_")
    try:
        yt_wav = os.path.join(tmp_dir, "audio.wav")
        if not _download_youtube_audio(video_id, yt_wav, tmp_dir):
            return {"bpm": None, "error": "Could not download audio"}
        bpm = _detect_bpm(yt_wav)
        return {"bpm": bpm}
    except Exception as e:
        log.exception("BPM endpoint error: %s", e)
        return {"bpm": None, "error": str(e)}
    finally:
        try:
            shutil.rmtree(tmp_dir, ignore_errors=True)
        except OSError:
            pass


@app.get("/bpm")
def get_bpm(video_id: str = "") -> dict:
    """
    Detect BPM of a YouTube track by video_id.
    Downloads audio, runs beat tracking, returns {"bpm": float} or {"bpm": null, "error": "..."}.
    """
    video_id = (video_id or "").strip()
    if not video_id:
        return {"bpm": None, "error": "video_id required"}
    tmp_dir = tempfile.mkdtemp(prefix="mongobox_bpm_")
    try:
        yt_wav = os.path.join(tmp_dir, "audio.wav")
        if not _download_youtube_audio(video_id, yt_wav, tmp_dir):
            return {"bpm": None, "error": "Could not download audio"}
        bpm = _detect_bpm(yt_wav)
        return {"bpm": bpm}
    except Exception as e:
        log.exception("BPM endpoint error: %s", e)
        return {"bpm": None, "error": str(e)}
    finally:
        try:
            shutil.rmtree(tmp_dir, ignore_errors=True)
        except OSError:
            pass


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
