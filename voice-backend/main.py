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
import threading
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
_tts: TTS | None = None
_device: str = "cpu"
_fallback_tts_models: dict[str, TTS] = {}
_cancelled_clone_request_ids: set[str] = set()
_active_clone_request_ids: set[str] = set()
_clone_request_lock = threading.Lock()

# ── Indic transliteration (loaded lazily) ─────────────────────────────────────
_indic_trans = None  # indic_transliteration.sanscript module, if available


@dataclass(frozen=True)
class CloneRequestParams:
    request_id: str
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

    # Try loading indic_transliteration for Hinglish → Devanagari conversion
    global _indic_trans
    try:
        from indic_transliteration import sanscript
        _indic_trans = sanscript
        log.info("indic_transliteration loaded ✓ (Hinglish→Devanagari enabled)")
    except ImportError:
        log.warning(
            "indic_transliteration not installed — Hinglish will use phonetic respelling fallback.\n"
            "  Install with: pip install indic-transliteration"
        )


# ──────────────────────────────────────────────────────────────────────────────
# HINGLISH → DEVANAGARI  (the core accent fix)
# ──────────────────────────────────────────────────────────────────────────────

# Manual phonetic map for common Hinglish words/syllables that the library
# sometimes mis-handles. Applied as a pre-pass before library transliteration.
# Format: (regex_pattern, devanagari_replacement)
_HINGLISH_WORD_MAP: list[tuple[re.Pattern[str], str]] = [
    # Pronouns / common words
    (re.compile(r"\bmain\b", re.IGNORECASE), "मैं"),
    (re.compile(r"\bmeri\b", re.IGNORECASE), "मेरी"),
    (re.compile(r"\bmera\b", re.IGNORECASE), "मेरा"),
    (re.compile(r"\btere\b", re.IGNORECASE), "तेरे"),
    (re.compile(r"\bteri\b", re.IGNORECASE), "तेरी"),
    (re.compile(r"\btujhe\b", re.IGNORECASE), "तुझे"),
    (re.compile(r"\btum\b", re.IGNORECASE), "तुम"),
    (re.compile(r"\bhum\b", re.IGNORECASE), "हम"),
    (re.compile(r"\bwoh\b", re.IGNORECASE), "वो"),
    (re.compile(r"\bkoi\b", re.IGNORECASE), "कोई"),
    (re.compile(r"\bnahi\b", re.IGNORECASE), "नहीं"),
    (re.compile(r"\bnahin\b", re.IGNORECASE), "नहीं"),
    (re.compile(r"\bhai\b", re.IGNORECASE), "है"),
    (re.compile(r"\bho\b", re.IGNORECASE), "हो"),
    (re.compile(r"\bkar\b", re.IGNORECASE), "कर"),
    (re.compile(r"\bab\b", re.IGNORECASE), "अब"),
    (re.compile(r"\baaj\b", re.IGNORECASE), "आज"),
    (re.compile(r"\bkal\b", re.IGNORECASE), "कल"),
    (re.compile(r"\bek\b", re.IGNORECASE), "एक"),
    (re.compile(r"\baur\b", re.IGNORECASE), "और"),
    (re.compile(r"\bse\b", re.IGNORECASE), "से"),
    (re.compile(r"\bke\b", re.IGNORECASE), "के"),
    (re.compile(r"\bki\b", re.IGNORECASE), "की"),
    (re.compile(r"\bka\b", re.IGNORECASE), "का"),
    (re.compile(r"\bjo\b", re.IGNORECASE), "जो"),
    # Emotions / lyrics staples
    (re.compile(r"\bdil\b", re.IGNORECASE), "दिल"),
    (re.compile(r"\bjaan\b", re.IGNORECASE), "जान"),
    (re.compile(r"\byaar\b", re.IGNORECASE), "यार"),
    (re.compile(r"\bpyaar\b", re.IGNORECASE), "प्यार"),
    (re.compile(r"\bishq\b", re.IGNORECASE), "इश्क़"),
    (re.compile(r"\bmohabbat\b", re.IGNORECASE), "मोहब्बत"),
    (re.compile(r"\bzindagi\b", re.IGNORECASE), "ज़िंदगी"),
    (re.compile(r"\bsafar\b", re.IGNORECASE), "सफ़र"),
    (re.compile(r"\byaad\b", re.IGNORECASE), "याद"),
    (re.compile(r"\bkhuda\b", re.IGNORECASE), "ख़ुदा"),
    (re.compile(r"\bjannat\b", re.IGNORECASE), "जन्नत"),
    (re.compile(r"\bjunoon\b", re.IGNORECASE), "जुनून"),
    (re.compile(r"\braat\b", re.IGNORECASE), "रात"),
    (re.compile(r"\bbina\b", re.IGNORECASE), "बिना"),
    (re.compile(r"\baankhon\b", re.IGNORECASE), "आँखों"),
    (re.compile(r"\baankh\b", re.IGNORECASE), "आँख"),
    (re.compile(r"\brooh\b", re.IGNORECASE), "रूह"),
    (re.compile(r"\bnoor\b", re.IGNORECASE), "नूर"),
    (re.compile(r"\bchaand\b", re.IGNORECASE), "चाँद"),
    (re.compile(r"\bsuraj\b", re.IGNORECASE), "सूरज"),
    (re.compile(r"\bpani\b", re.IGNORECASE), "पानी"),
    (re.compile(r"\baag\b", re.IGNORECASE), "आग"),
    (re.compile(r"\bhawa\b", re.IGNORECASE), "हवा"),
    (re.compile(r"\bduniya\b", re.IGNORECASE), "दुनिया"),
    (re.compile(r"\bkhwab\b", re.IGNORECASE), "ख़्वाब"),
    (re.compile(r"\bsitara\b", re.IGNORECASE), "सितारा"),
    (re.compile(r"\btaara\b", re.IGNORECASE), "तारा"),
    (re.compile(r"\bsach\b", re.IGNORECASE), "सच"),
    (re.compile(r"\bjhooth\b", re.IGNORECASE), "झूठ"),
    (re.compile(r"\bwaqt\b", re.IGNORECASE), "वक़्त"),
    (re.compile(r"\bdard\b", re.IGNORECASE), "दर्द"),
    (re.compile(r"\bkhushi\b", re.IGNORECASE), "ख़ुशी"),
    (re.compile(r"\bgham\b", re.IGNORECASE), "ग़म"),
    (re.compile(r"\bsuno\b", re.IGNORECASE), "सुनो"),
    (re.compile(r"\bdekho\b", re.IGNORECASE), "देखो"),
    (re.compile(r"\bchalo\b", re.IGNORECASE), "चलो"),
    (re.compile(r"\brona\b", re.IGNORECASE), "रोना"),
    (re.compile(r"\bhona\b", re.IGNORECASE), "होना"),
    (re.compile(r"\bjana\b", re.IGNORECASE), "जाना"),
    (re.compile(r"\baana\b", re.IGNORECASE), "आना"),
    (re.compile(r"\brehna\b", re.IGNORECASE), "रहना"),
    (re.compile(r"\bsona\b", re.IGNORECASE), "सोना"),
    (re.compile(r"\bkhona\b", re.IGNORECASE), "खोना"),
    (re.compile(r"\bpana\b", re.IGNORECASE), "पाना"),
    (re.compile(r"\bdil se\b", re.IGNORECASE), "दिल से"),
    (re.compile(r"\bdil mein\b", re.IGNORECASE), "दिल में"),
    (re.compile(r"\bmere liye\b", re.IGNORECASE), "मेरे लिए"),
    (re.compile(r"\btere liye\b", re.IGNORECASE), "तेरे लिए"),
    (re.compile(r"\bkab\b", re.IGNORECASE), "कब"),
    (re.compile(r"\bkya\b", re.IGNORECASE), "क्या"),
    (re.compile(r"\bkaise\b", re.IGNORECASE), "कैसे"),
    (re.compile(r"\bkahan\b", re.IGNORECASE), "कहाँ"),
    (re.compile(r"\bkyun\b", re.IGNORECASE), "क्यों"),
    (re.compile(r"\bkuch\b", re.IGNORECASE), "कुछ"),
    (re.compile(r"\bsab\b", re.IGNORECASE), "सब"),
    (re.compile(r"\bsirf\b", re.IGNORECASE), "सिर्फ"),
    (re.compile(r"\bphir\b", re.IGNORECASE), "फिर"),
    (re.compile(r"\bbhi\b", re.IGNORECASE), "भी"),
    (re.compile(r"\btoh\b", re.IGNORECASE), "तो"),
    (re.compile(r"\bpar\b", re.IGNORECASE), "पर"),
    (re.compile(r"\bpas\b", re.IGNORECASE), "पास"),
    (re.compile(r"\baake\b", re.IGNORECASE), "आके"),
    (re.compile(r"\bjaake\b", re.IGNORECASE), "जाके"),
    (re.compile(r"\bhadh\b", re.IGNORECASE), "हद"),
    (re.compile(r"\bzaroor\b", re.IGNORECASE), "ज़रूर"),
    (re.compile(r"\bshayad\b", re.IGNORECASE), "शायद"),
    (re.compile(r"\bkabhi\b", re.IGNORECASE), "कभी"),
    (re.compile(r"\bsada\b", re.IGNORECASE), "सदा"),
    (re.compile(r"\bhamesha\b", re.IGNORECASE), "हमेशा"),
]


def _transliterate_hinglish_line(line: str) -> str:
    """
    Convert a Hinglish (Roman-script Hindi) line to Devanagari.

    Strategy (in order):
    1. Apply the hand-curated word map for high-frequency lyrics words.
    2. Try indic_transliteration library for any remaining Roman tokens.
    3. Leave unrecognised tokens (English words, punctuation) as-is.

    The result is a mixed Devanagari + English string that XTTS's Hindi
    tokenizer handles far better than pure Romanized text.
    """
    # Step 1: hand-curated replacements (full-word, case-insensitive)
    result = line
    for pattern, devanagari in _HINGLISH_WORD_MAP:
        result = pattern.sub(devanagari, result)

    # Step 2: library-based transliteration of remaining Roman tokens
    if _indic_trans is not None:
        tokens = result.split()
        converted: list[str] = []
        for token in tokens:
            # Only process tokens that are still purely ASCII alphabetic
            # (i.e. not already Devanagari and not punctuation/numbers)
            clean = re.sub(r"[^a-zA-Z]", "", token)
            if clean and token == clean:  # pure ASCII alpha token → transliterate
                try:
                    deva = _indic_trans.transliterate(
                        token,
                        _indic_trans.ITRANS,
                        _indic_trans.DEVANAGARI,
                    )
                    converted.append(deva)
                except Exception:
                    converted.append(token)
            else:
                converted.append(token)
        result = " ".join(converted)

    return result


def _prepare_hindi_text(text: str) -> str:
    """
    Full pipeline: for each non-header line in Hinglish lyrics, convert to
    Devanagari so XTTS synthesises with a genuine Hindi accent.
    """
    lines = text.splitlines()
    out: list[str] = []
    for line in lines:
        stripped = line.strip()
        if not stripped:
            out.append(line)
            continue
        # Leave section headers like [Verse 1] untouched
        if re.match(r"^\[", stripped):
            out.append(line)
            continue
        # Check if line is already mostly Devanagari — don't double-convert
        devanagari_count = sum(1 for ch in stripped if 0x0900 <= ord(ch) <= 0x097F)
        total_alpha = sum(1 for ch in stripped if ch.isalpha())
        if total_alpha > 0 and (devanagari_count / total_alpha) > 0.5:
            out.append(line)  # already Hindi script
        else:
            out.append(_transliterate_hinglish_line(line))
    converted = "\n".join(out)
    log.debug("Hindi text after transliteration:\n%s", converted)
    return converted


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
    request_id: str,
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
        request_id=(request_id or "").strip(),
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


def _mark_clone_request_active(request_id: str) -> None:
    if not request_id:
        return
    with _clone_request_lock:
        _cancelled_clone_request_ids.discard(request_id)
        _active_clone_request_ids.add(request_id)


def _finish_clone_request(request_id: str) -> None:
    if not request_id:
        return
    with _clone_request_lock:
        _active_clone_request_ids.discard(request_id)
        _cancelled_clone_request_ids.discard(request_id)


def _cancel_clone_request(request_id: str) -> bool:
    trimmed = (request_id or "").strip()
    if not trimmed:
        return False
    with _clone_request_lock:
        _cancelled_clone_request_ids.add(trimmed)
        return trimmed in _active_clone_request_ids


def _is_clone_request_cancelled(request_id: str) -> bool:
    trimmed = (request_id or "").strip()
    if not trimmed:
        return False
    with _clone_request_lock:
        return trimmed in _cancelled_clone_request_ids


def _raise_if_clone_cancelled(request_id: str) -> None:
    if _is_clone_request_cancelled(request_id):
        raise RuntimeError("Clone request was cancelled.")


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
    _run_ffmpeg_wav_convert(src, dst, sample_rate=22050, channels=1)


def _normalize_generated_wav(src: str, dst: str) -> None:
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
        "en", "es", "fr", "de", "it", "pt", "pl", "tr", "ru",
        "nl", "cs", "ar", "zh", "ja", "hu", "ko", "hi",
    }

    if explicit_tts_code:
        prefix = explicit_tts_code.split("-", 1)[0]
        explicit_map = {
            "en": "en", "es": "es", "fr": "fr", "de": "de", "it": "it",
            "pt": "pt", "pl": "pl", "tr": "tr", "ru": "ru", "nl": "nl",
            "cs": "cs", "ar": "ar", "zh": "zh", "ja": "ja", "hu": "hu",
            "ko": "ko", "hi": "hi",
            "ur": "ar" if re.search(r"[\u0600-\u06FF]", combined_reference_text) else "hi",
            "pa": "hi", "bn": "hi", "ta": "hi", "te": "hi",
            "mr": "hi", "gu": "hi", "kn": "hi", "ml": "hi",
        }
        mapped = explicit_map.get(prefix)
        if mapped in supported_xtts_codes:
            return mapped

    if is_hindi:
        return "hi"

    combined_lower = combined_reference_text.lower()
    if normalized:
        hint_map = {
            "english": "en", "spanish": "es", "french": "fr", "german": "de",
            "italian": "it", "portuguese": "pt", "polish": "pl", "turkish": "tr",
            "russian": "ru", "dutch": "nl", "czech": "cs", "arabic": "ar",
            "chinese": "zh", "japanese": "ja", "hungarian": "hu", "korean": "ko",
            "hindi": "hi",
            "urdu": "ar" if re.search(r"[\u0600-\u06FF]", combined_reference_text) else "hi",
        }
        if normalized in hint_map:
            return hint_map[normalized]

    south_asian_markers = {
        "urdu": "ar" if re.search(r"[\u0600-\u06FF]", combined_reference_text) else "hi",
        "hindi": "hi", "bollywood": "hi", "hinglish": "hi",
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
        for part in [language_hint, genre_hint, reference_track_title,
                     reference_artist_name, reference_lyric_snippet]
        if part and part.strip()
    )
    if any(token in combined for token in ["urdu", "hindi", "bollywood", "ghazal", "qawwali", "desi", "hinglish"]):
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
    normalized = re.sub(r"[^a-z]+", " ", (accent_hint or "").strip().lower()).strip()
    if normalized in {"indian", "british", "american"}:
        return normalized
    if normalized in {"hindi", "urdu", "punjabi", "desi", "south asian"}:
        return "indian"

    combined = " ".join(
        part.lower()
        for part in [language_hint, genre_hint, reference_track_title,
                     reference_artist_name, reference_lyric_snippet]
        if part and part.strip()
    )
    if is_hindi:
        return "indian"
    if any(token in combined for token in ["urdu", "hindi", "bollywood", "ghazal", "qawwali", "desi", "hinglish"]):
        return "indian"
    return "indian"


_INDIAN_EN_REPLACEMENTS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\bthis\b", re.IGNORECASE), "dis"),
    (re.compile(r"\bthat\b", re.IGNORECASE), "dat"),
    (re.compile(r"\bthese\b", re.IGNORECASE), "dese"),
    (re.compile(r"\bthose\b", re.IGNORECASE), "dose"),
    (re.compile(r"\bthink\b", re.IGNORECASE), "tink"),
    (re.compile(r"\bthing\b", re.IGNORECASE), "ting"),
    (re.compile(r"\bthree\b", re.IGNORECASE), "tree"),
    (re.compile(r"\bthrough\b", re.IGNORECASE), "troo"),
    (re.compile(r"\bwith\b", re.IGNORECASE), "wit"),
    (re.compile(r"\bvery\b", re.IGNORECASE), "wery"),
    (re.compile(r"\blove\b", re.IGNORECASE), "luv"),
]


def _shape_english_pronunciation(text: str, accent: str) -> str:
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
    request_id: str,
) -> list[str]:
    if _tts is None:
        raise RuntimeError("XTTS model is not loaded yet.")

    chunk_wavs: list[str] = []
    for i, chunk in enumerate(chunks):
        _raise_if_clone_cancelled(request_id)
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
        _raise_if_clone_cancelled(request_id)
        normalized_chunk = os.path.join(tmp_dir, f"chunk_{i:03d}.wav")
        _normalize_generated_wav(out_chunk, normalized_chunk)
        chunk_wavs.append(normalized_chunk)
    return chunk_wavs


def _synthesise_chunks_with_coqui_model(
    *,
    chunks: list[str],
    model_name: str,
    tmp_dir: str,
    request_id: str,
) -> list[str]:
    model = _get_or_load_tts_model(model_name)
    chunk_wavs: list[str] = []
    for i, chunk in enumerate(chunks):
        _raise_if_clone_cancelled(request_id)
        out_chunk = os.path.join(tmp_dir, f"chunk_{i:03d}_fallback_raw.wav")
        model.tts_to_file(text=chunk, file_path=out_chunk)
        _raise_if_clone_cancelled(request_id)
        normalized_chunk = os.path.join(tmp_dir, f"chunk_{i:03d}_fallback.wav")
        _normalize_generated_wav(out_chunk, normalized_chunk)
        chunk_wavs.append(normalized_chunk)
    return chunk_wavs


def _synthesise_chunks_with_espeak(
    *,
    chunks: list[str],
    espeak_voice: str,
    tmp_dir: str,
    request_id: str,
) -> list[str]:
    voice = (espeak_voice or "").strip() or "en-gb"
    chunk_wavs: list[str] = []
    for i, chunk in enumerate(chunks):
        _raise_if_clone_cancelled(request_id)
        raw_chunk = os.path.join(tmp_dir, f"chunk_{i:03d}_espeak_raw.wav")
        cmd = ["espeak-ng", "-v", voice, "-w", raw_chunk, chunk]
        try:
            subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL,
                           stderr=subprocess.PIPE, text=True)
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
        _raise_if_clone_cancelled(request_id)
        chunk_wavs.append(normalized_chunk)
    return chunk_wavs


@app.post("/clone/cancel")
async def cancel_clone(request_id: str = Form(...)) -> dict:
    trimmed = (request_id or "").strip()
    if not trimmed:
        raise HTTPException(400, "request_id is required.")

    was_active = _cancel_clone_request(trimmed)
    return {"status": "ok", "request_id": trimmed, "was_active": was_active}


# ── Option B: extract instrumental from reference song & mix ────────────────────

def _download_youtube_audio(video_id: str, out_path: str, tmp_dir: str) -> bool:
    if not video_id or not video_id.strip():
        return False
    url = f"https://www.youtube.com/watch?v={video_id.strip()}"
    template = os.path.join(tmp_dir, "yt_audio.%(ext)s")
    cmd = [
        sys.executable, "-m", "yt_dlp",
        "-x", "--audio-format", "best",
        "-o", template,
        "--no-playlist", "--no-warnings", "--geo-bypass", url,
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
    demucs_out = os.path.join(out_dir, "demucs_out")
    cmd = [
        sys.executable, "-m", "demucs",
        "-n", "htdemucs", "--two-stems", "vocals",
        "-o", demucs_out, audio_path,
    ]
    try:
        subprocess.run(cmd, check=True, capture_output=True, text=True, timeout=600, cwd=out_dir)
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        log.warning("Demucs separation failed: %s", e)
        return None

    base = os.path.splitext(os.path.basename(audio_path))[0]
    for model_dir in ["htdemucs", "htdemucs_ft"]:
        track_dir = os.path.join(demucs_out, model_dir, base)
        no_vocals = os.path.join(track_dir, "no_vocals.wav")
        if os.path.isfile(no_vocals):
            return no_vocals
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
    duration = _get_wav_duration_seconds(vocal_path)
    if duration <= 0:
        shutil.copy(vocal_path, out_path)
        return

    vocal_44 = out_path + ".vocal_44.wav"
    _run_ffmpeg_wav_convert(vocal_path, vocal_44, sample_rate=44100, channels=1)

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
def clone_voice(
    voice_sample: UploadFile = File(...),
    request_id: str = Form(""),
    lyrics: str = Form(...),
    mood: str = Form(""),
    genre: str = Form(""),
    language: str = Form(""),
    accent_hint: str = Form(""),
    tts_language_code: str = Form(""),
    espeak_voice: str = Form(""),
    coqui_model_hint: str = Form(""),
    is_hindi: str = Form(""),
    reference_track_title: str = Form(""),
    reference_artist_name: str = Form(""),
    reference_lyric_snippet: str = Form(""),
    reference_video_id: str = Form(""),
) -> FileResponse:
    if not lyrics.strip():
        raise HTTPException(400, "Lyrics must not be empty.")

    params = _parse_clone_request(
        request_id=request_id,
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
    _mark_clone_request_active(params.request_id)

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
        _raise_if_clone_cancelled(params.request_id)

        # 3) ── KEY FIX: Convert Hinglish → Devanagari BEFORE stripping tags ──
        #    We do this on the raw lyrics so section tags are still present as
        #    context, then strip them afterwards.
        working_lyrics = params.lyrics
        if params.is_hindi:
            log.info("is_hindi=True — transliterating Hinglish → Devanagari")
            working_lyrics = _prepare_hindi_text(working_lyrics)

        clean_lyrics = _strip_section_tags(working_lyrics)
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
        # After transliteration the text will contain Devanagari — confirm lang
        if params.is_hindi and detected_lang != "hi":
            log.warning("Language resolved to %s despite is_hindi=True — overriding to 'hi'", detected_lang)
            detected_lang = "hi"

        pronunciation_profile = _resolve_pronunciation_profile(
            params.language, params.genre,
            params.reference_track_title, params.reference_artist_name,
            params.reference_lyric_snippet,
        )
        accent = _resolve_accent_hint(
            params.accent_hint, params.language, params.genre,
            params.reference_track_title, params.reference_artist_name,
            params.reference_lyric_snippet,
            is_hindi=params.is_hindi,
        )
        log.info(
            "Clone request: chunks=%d lang=%s accent=%s is_hindi=%s mood=%s genre=%s reference=%s/%s",
            len(chunks), detected_lang, accent, params.is_hindi,
            params.mood or "-", params.genre or "-",
            params.reference_track_title or "-", params.reference_artist_name or "-",
        )

        # 4) Synthesis
        chunk_wavs: list[str]
        synthesis_engine = "xtts_v2"
        try:
            chunk_wavs = _synthesise_chunks_with_xtts(
                chunks=chunks,
                speaker_wav=ref_wav,
                xtts_language=detected_lang,
                accent=accent,
                tmp_dir=tmp_dir,
                request_id=params.request_id,
            )
        except Exception as xtts_exc:
            log.warning("XTTS synthesis failed (%s); attempting fallbacks", xtts_exc)
            fallback_model = (params.coqui_model_hint or "").strip()
            can_try_fallback_model = fallback_model and "xtts_v2" not in fallback_model.lower()

            if can_try_fallback_model:
                try:
                    chunk_wavs = _synthesise_chunks_with_coqui_model(
                        chunks=chunks,
                        model_name=fallback_model,
                        tmp_dir=tmp_dir,
                        request_id=params.request_id,
                    )
                    synthesis_engine = fallback_model
                except Exception as fallback_exc:
                    log.warning("Fallback Coqui model failed (%s); trying eSpeak-NG", fallback_exc)
                    espeak_fallback_voice = (params.espeak_voice or "").strip() or ("hi" if params.is_hindi else "en-gb")
                    chunk_wavs = _synthesise_chunks_with_espeak(
                        chunks=chunks,
                        espeak_voice=espeak_fallback_voice,
                        tmp_dir=tmp_dir,
                        request_id=params.request_id,
                    )
                    synthesis_engine = f"espeak:{espeak_fallback_voice}"
            else:
                espeak_fallback_voice = (params.espeak_voice or "").strip() or ("hi" if params.is_hindi else "en-gb")
                chunk_wavs = _synthesise_chunks_with_espeak(
                    chunks=chunks,
                    espeak_voice=espeak_fallback_voice,
                    tmp_dir=tmp_dir,
                    request_id=params.request_id,
                )
                synthesis_engine = f"espeak:{espeak_fallback_voice}"

        # 5) Merge
        _raise_if_clone_cancelled(params.request_id)
        final_wav = os.path.join(tmp_dir, "cloned_voice.wav")
        if len(chunk_wavs) == 1:
            shutil.copy(chunk_wavs[0], final_wav)
        else:
            _merge_wav_chunks(chunk_wavs, final_wav)

        mix_status = "voice_only"
        mix_label = ""

        # 5b) Optional: extract instrumental & mix
        video_id = (params.reference_video_id or "").strip()
        if video_id:
            _raise_if_clone_cancelled(params.request_id)
            yt_wav = os.path.join(tmp_dir, "yt_reference.wav")
            if _download_youtube_audio(video_id, yt_wav, tmp_dir):
                _raise_if_clone_cancelled(params.request_id)
                inst_path = _separate_instrumental(yt_wav, tmp_dir)
                if inst_path:
                    _raise_if_clone_cancelled(params.request_id)
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
            os.path.getsize(final_wav), synthesis_engine,
        )

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
        if str(exc) == "Clone request was cancelled.":
            log.info("Clone request cancelled by client")
            raise HTTPException(499, "Clone request cancelled.") from exc
        log.exception("Pipeline error: %s", exc)
        raise HTTPException(500, str(exc)) from exc
    finally:
        _finish_clone_request(params.request_id)
        try:
            voice_sample.file.close()
        except Exception:
            pass


# ── BPM & Health endpoints (unchanged) ────────────────────────────────────────

def _detect_bpm(audio_path: str) -> float | None:
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
    return analyze_bpm(video_id)


@app.get("/health")
def health() -> dict:
    return {
        "status": "ok",
        "model_loaded": _tts is not None,
        "device": _device,
        "cuda": torch.cuda.is_available(),
        "hindi_transliteration": _indic_trans is not None,
    }


@app.get("/healthz", include_in_schema=False)
def healthz() -> dict:
    return health()
