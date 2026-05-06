from __future__ import annotations

import logging
import mimetypes
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
import time
import uuid
from pathlib import Path

import requests
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from starlette.background import BackgroundTask


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
    allow_origins=["*"],
    allow_methods=["POST", "GET"],
    allow_headers=["*"],
)

_VOICEBOX_API_URL = os.environ.get("VOICEBOX_API_URL", "http://127.0.0.1:17493").strip().rstrip("/")
_VOICEBOX_CLIENT_ID = (os.environ.get("VOICEBOX_CLIENT_ID", "mongobox-backend") or "mongobox-backend").strip()
_VOICEBOX_HEALTH_TTL_SECONDS = 5.0

_cancelled_clone_request_ids: set[str] = set()
_active_clone_request_ids: set[str] = set()
_clone_request_lock = threading.Lock()
_artifact_root = Path(tempfile.gettempdir()) / "mongobox_voice_artifacts"
_artifact_ttl_seconds = 60 * 60 * 12
_voicebox_http = requests.Session()
_voicebox_health_cache = {
    "checked_at": 0.0,
    "available": False,
    "detail": "not checked",
}
_voicebox_health_lock = threading.Lock()


@dataclass(frozen=True)
class CloneRequestParams:
    request_id: str
    lyrics: str
    mood: str
    genre: str
    language: str
    tts_language_code: str
    reference_track_title: str
    reference_artist_name: str
    reference_lyric_snippet: str
    reference_transcript: str
    reference_video_id: str
    voicebox_profile_id: str


@dataclass(frozen=True)
class LyricChunk:
    text: str
    pause_ms: int = 0


@app.on_event("startup")
def load_model() -> None:
    available, detail = _voicebox_health_snapshot(force=True)
    if not available:
        log.warning(
            "Voicebox not reachable at startup (%s). "
            "Requests will fail until Voicebox is running at %s",
            detail,
            _VOICEBOX_API_URL,
        )
    else:
        log.info("Voicebox reachable at %s ✓", _VOICEBOX_API_URL)


# ── Helpers ────────────────────────────────────────────────────────────────────

def _strip_section_tags(text: str) -> str:
    lines = [
        line
        for line in text.splitlines()
        if line.strip() and not re.match(r"^\[", line.strip(), re.IGNORECASE)
    ]
    return "\n".join(lines)


def _parse_clone_request(
    *,
    request_id: str,
    lyrics: str,
    mood: str,
    genre: str,
    language: str,
    tts_language_code: str,
    reference_track_title: str,
    reference_artist_name: str,
    reference_lyric_snippet: str,
    reference_transcript: str,
    reference_video_id: str,
    voicebox_profile_id: str,
) -> CloneRequestParams:
    return CloneRequestParams(
        request_id=(request_id or "").strip(),
        lyrics=lyrics,
        mood=mood,
        genre=genre,
        language=language,
        tts_language_code=tts_language_code,
        reference_track_title=reference_track_title,
        reference_artist_name=reference_artist_name,
        reference_lyric_snippet=reference_lyric_snippet,
        reference_transcript=reference_transcript,
        reference_video_id=(reference_video_id or "").strip(),
        voicebox_profile_id=(voicebox_profile_id or "").strip(),
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


def _cleanup_stale_artifacts() -> None:
    try:
        _artifact_root.mkdir(parents=True, exist_ok=True)
        current_time = time.time()
        for child in _artifact_root.iterdir():
            try:
                if not child.is_dir():
                    continue
                age = current_time - child.stat().st_mtime
                if age > _artifact_ttl_seconds:
                    shutil.rmtree(child, ignore_errors=True)
            except OSError:
                continue
    except OSError:
        return


def _artifact_key(request_id: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9_-]+", "_", (request_id or "").strip())
    cleaned = cleaned.strip("_")[:80]
    return cleaned or uuid.uuid4().hex


def _persist_request_artifact(src_path: str, request_id: str, file_name: str) -> str | None:
    try:
        _cleanup_stale_artifacts()
        key = _artifact_key(request_id)
        artifact_dir = _artifact_root / key
        artifact_dir.mkdir(parents=True, exist_ok=True)
        dest = artifact_dir / file_name
        shutil.copy2(src_path, dest)
        return f"/artifacts/{key}/{file_name}"
    except OSError as exc:
        log.warning("Could not persist artifact %s: %s", file_name, exc)
        return None


def _header_safe(value: str) -> str:
    """Return an HTTP-header-safe string (latin-1 encodable, ASCII punctuation)."""
    normalized = (
        (value or "")
        .replace("—", "-")
        .replace("–", "-")
        .replace("…", "...")
    )
    return normalized.encode("latin-1", "ignore").decode("latin-1")


_VOICEBOX_SUPPORTED_LANGS = {
    "zh", "en", "ja", "ko", "de", "fr", "ru", "pt", "es", "it",
    "he", "ar", "da", "el", "fi", "hi", "ms", "nl", "no", "pl",
    "sv", "sw", "tr",
}
_VOICEBOX_QWEN_LANGS = {"zh", "en", "ja", "ko", "de", "fr", "ru", "pt", "es", "it"}


def _voicebox_headers() -> dict[str, str]:
    return {"X-Voicebox-Client-Id": _VOICEBOX_CLIENT_ID}


def _voicebox_error_detail(response: requests.Response) -> str:
    try:
        payload = response.json()
        if isinstance(payload, dict):
            detail = payload.get("detail")
            if isinstance(detail, list):
                bits = []
                for item in detail:
                    if isinstance(item, dict):
                        msg = str(item.get("msg") or "").strip()
                        if msg:
                            bits.append(msg)
                if bits:
                    return "; ".join(bits)
            if detail:
                return str(detail)
            for key in ("error", "message", "status"):
                value = payload.get(key)
                if value:
                    return str(value)
    except ValueError:
        pass
    text = (response.text or "").strip()
    return text or response.reason or "unknown error"


def _voicebox_response(
    method: str,
    path: str,
    *,
    accepted_statuses: tuple[int, ...] = (200,),
    timeout: float | tuple[float, float] = 30.0,
    json_body: dict | None = None,
    data: dict | None = None,
    files: dict | None = None,
    stream: bool = False,
) -> requests.Response:
    url = path if path.startswith(("http://", "https://")) else f"{_VOICEBOX_API_URL}{path}"
    try:
        response = _voicebox_http.request(
            method=method,
            url=url,
            headers=_voicebox_headers(),
            json=json_body,
            data=data,
            files=files,
            timeout=timeout,
            stream=stream,
        )
    except requests.RequestException as exc:
        raise RuntimeError(
            f"Could not reach Voicebox at {_VOICEBOX_API_URL}. "
            "Start Voicebox or point VOICEBOX_API_URL at a reachable server."
        ) from exc

    if response.status_code not in accepted_statuses:
        detail = _voicebox_error_detail(response)
        response.close()
        raise RuntimeError(
            f"Voicebox {method.upper()} {path} failed "
            f"({response.status_code}): {detail}"
        )
    return response


def _voicebox_json(
    method: str,
    path: str,
    *,
    accepted_statuses: tuple[int, ...] = (200,),
    timeout: float | tuple[float, float] = 30.0,
    json_body: dict | None = None,
    data: dict | None = None,
    files: dict | None = None,
) -> dict | list:
    response = _voicebox_response(
        method,
        path,
        accepted_statuses=accepted_statuses,
        timeout=timeout,
        json_body=json_body,
        data=data,
        files=files,
    )
    try:
        payload = response.json()
    finally:
        response.close()
    if payload is None:
        return {}
    if not isinstance(payload, (dict, list)):
        raise RuntimeError(f"Voicebox returned an unexpected payload for {path}.")
    return payload


def _voicebox_health_snapshot(force: bool = False) -> tuple[bool, str]:
    if not _VOICEBOX_API_URL:
        return False, "VOICEBOX_API_URL is empty."

    with _voicebox_health_lock:
        now = time.time()
        if (
            not force
            and now - float(_voicebox_health_cache["checked_at"]) < _VOICEBOX_HEALTH_TTL_SECONDS
        ):
            return bool(_voicebox_health_cache["available"]), str(_voicebox_health_cache["detail"])

        try:
            response = _voicebox_response(
                "GET",
                "/health",
                accepted_statuses=(200,),
                timeout=(1.0, 2.0),
            )
            payload = response.json()
            response.close()
            available = isinstance(payload, dict) and payload.get("status") in {"ok", "healthy"}
            detail = "ok" if available else "Voicebox health check returned a non-ok status."
        except Exception as exc:
            available = False
            detail = str(exc)

        _voicebox_health_cache["checked_at"] = now
        _voicebox_health_cache["available"] = available
        _voicebox_health_cache["detail"] = detail
        return available, detail


def _require_voicebox_available() -> None:
    available, detail = _voicebox_health_snapshot(force=True)
    if not available:
        raise RuntimeError(detail)


def _is_hindi_family_language_hint(language: str) -> bool:
    normalized = re.sub(r"[^a-z]+", " ", (language or "").strip().lower()).strip()
    return normalized in {
        "hindi",
        "hinglish",
        "urdu",
        "punjabi",
        "bengali",
        "tamil",
        "telugu",
        "marathi",
        "gujarati",
        "kannada",
        "malayalam",
    }


def _coerce_voicebox_language(
    *,
    language_hint: str,
    tts_language_code: str,
    detected_lang: str,
    is_hindi: bool,
) -> str:
    explicit_tts_code = re.sub(r"[^a-z\-]+", "", (tts_language_code or "").strip().lower())
    explicit_prefix = explicit_tts_code.split("-", 1)[0] if explicit_tts_code else ""
    if explicit_prefix in _VOICEBOX_SUPPORTED_LANGS:
        return explicit_prefix

    normalized = re.sub(r"[^a-z]+", " ", (language_hint or "").strip().lower()).strip()
    hint_map = {
        "english": "en",
        "american": "en",
        "british": "en",
        "hindi": "hi",
        "hinglish": "hi",
        "urdu": "ar",
        "arabic": "ar",
        "japanese": "ja",
        "korean": "ko",
        "german": "de",
        "french": "fr",
        "spanish": "es",
        "italian": "it",
        "portuguese": "pt",
        "russian": "ru",
        "swahili": "sw",
        "swedish": "sv",
        "turkish": "tr",
        "malay": "ms",
    }
    mapped = hint_map.get(normalized)
    if mapped in _VOICEBOX_SUPPORTED_LANGS:
        return mapped

    if detected_lang in _VOICEBOX_SUPPORTED_LANGS:
        return detected_lang

    return "hi" if is_hindi else "en"


def _voicebox_engine_for_language(language_code: str) -> str:
     return "chatterbox"


def _voicebox_profile_name(profile_name: str = "") -> str:
    cleaned = re.sub(r"\s+", " ", (profile_name or "").strip())
    if cleaned:
        return cleaned[:100]
    return f"MongoBox Voice {uuid.uuid4().hex[:8]}"


def _voicebox_get_profile(profile_id: str) -> dict | None:
    trimmed = (profile_id or "").strip()
    if not trimmed:
        return None

    response = _voicebox_response(
        "GET",
        f"/profiles/{trimmed}",
        accepted_statuses=(200, 404),
        timeout=(2.0, 6.0),
    )
    try:
        if response.status_code == 404:
            return None
        payload = response.json()
    finally:
        response.close()

    return payload if isinstance(payload, dict) else None


def _voicebox_transcribe_audio(sample_path: str, *, request_id: str = "") -> str:
    _raise_if_clone_cancelled(request_id)
    mime_type = mimetypes.guess_type(sample_path)[0] or "application/octet-stream"
    with open(sample_path, "rb") as handle:
        payload = _voicebox_json(
            "POST",
            "/transcribe",
            files={"file": (Path(sample_path).name, handle, mime_type)},
            timeout=(10.0, 300.0),
        )
    _raise_if_clone_cancelled(request_id)
    if isinstance(payload, dict):
        return str(payload.get("text") or "").strip()
    return ""


def _voicebox_create_profile(*, profile_name: str, language_code: str) -> dict:
    base_name = _voicebox_profile_name(profile_name)
    body = {
        "name": base_name,
        "description": "Created by MongoBox from a recorded voice sample.",
        "language": language_code,
        "default_engine": _voicebox_engine_for_language(language_code),
    }
    try:
        payload = _voicebox_json(
            "POST",
            "/profiles",
            json_body=body,
            timeout=(4.0, 15.0),
        )
        if isinstance(payload, dict):
            return payload
    except Exception as exc:
        if "already exists" not in str(exc).lower():
            raise

    body["name"] = f"{base_name} {uuid.uuid4().hex[:6]}"
    payload = _voicebox_json(
        "POST",
        "/profiles",
        json_body=body,
        timeout=(4.0, 15.0),
    )
    if not isinstance(payload, dict):
        raise RuntimeError("Voicebox profile creation returned an unexpected payload.")
    return payload
def _ensure_voicebox_profile(
    *,
    sample_path: str,
    preferred_profile_id: str,
    profile_name: str,
    language_code: str,
    reference_text: str,
    request_id: str,
) -> dict:
    _require_voicebox_available()
    _raise_if_clone_cancelled(request_id)

    # ── Convert to WAV if needed (.m4a from iPhone fails Voicebox /transcribe) ──
    if not sample_path.lower().endswith(".wav"):
        converted = sample_path + "_ref.wav"
        _run_ffmpeg_wav_convert(sample_path, converted, sample_rate=22050, channels=1)
        sample_path = converted
        log.info("Converted voice sample to WAV for Voicebox: %s", converted)

    transcript = (reference_text or "").strip()
    if not transcript:
        transcript = _voicebox_transcribe_audio(sample_path, request_id=request_id)
    if not transcript:
        transcript = "MongoBox recorded voice sample"
    transcript = transcript[:1000].strip()

    existing_profile = _voicebox_get_profile(preferred_profile_id)
    if existing_profile is not None:
        profile = existing_profile
    else:
        profile = _voicebox_create_profile(
            profile_name=profile_name,
            language_code=language_code,
        )

    profile_id = str(profile.get("id") or "").strip()
    if not profile_id:
        raise RuntimeError("Voicebox profile creation did not return a profile id.")

    _raise_if_clone_cancelled(request_id)
    mime_type = mimetypes.guess_type(sample_path)[0] or "application/octet-stream"
    with open(sample_path, "rb") as handle:
        _voicebox_json(
            "POST",
            f"/profiles/{profile_id}/samples",
            data={"reference_text": transcript},
            files={"file": (Path(sample_path).name, handle, mime_type)},
            timeout=(10.0, 300.0),
        )
    _raise_if_clone_cancelled(request_id)

    return {
        "profile_id": profile_id,
        "profile_name": str(profile.get("name") or _voicebox_profile_name(profile_name)),
        "reference_text": transcript,
        "language": language_code,
        "engine": _voicebox_engine_for_language(language_code),
    }


def _group_chunks_for_voicebox(
    chunks: list[LyricChunk],
    *,
    max_chars: int = 4500,
) -> list[LyricChunk]:
    grouped: list[LyricChunk] = []
    buffer_lines: list[str] = []
    buffer_chars = 0
    buffer_pause_ms = 0

    for chunk in chunks:
        text = chunk.text.strip()
        if not text:
            continue

        extra_chars = len(text) + (1 if buffer_lines else 0)
        if buffer_lines and buffer_chars + extra_chars > max_chars:
            grouped.append(LyricChunk("\n".join(buffer_lines), buffer_pause_ms))
            buffer_lines = [text]
            buffer_chars = len(text)
        else:
            buffer_lines.append(text)
            buffer_chars += extra_chars
        buffer_pause_ms = chunk.pause_ms

    if buffer_lines:
        grouped.append(LyricChunk("\n".join(buffer_lines), buffer_pause_ms))
    return grouped


def _voicebox_download_audio(
    *,
    generation_id: str,
    out_path: str,
    request_id: str,
    timeout_seconds: float = 180.0,
) -> None:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        _raise_if_clone_cancelled(request_id)
        response = _voicebox_response(
            "GET",
            f"/audio/{generation_id}",
            accepted_statuses=(200, 404),
            timeout=(5.0, 60.0),
            stream=True,
        )
        if response.status_code == 200:
            try:
                with open(out_path, "wb") as handle:
                    for chunk in response.iter_content(chunk_size=1024 * 512):
                        if chunk:
                            _raise_if_clone_cancelled(request_id)
                            handle.write(chunk)
            finally:
                response.close()

            if os.path.getsize(out_path) <= 0:
                raise RuntimeError("Voicebox returned an empty audio file.")
            return

        response.close()
        time.sleep(0.75)

    raise RuntimeError(
        f"Voicebox generation {generation_id} did not become downloadable in time."
    )


def _synthesise_with_voicebox(
    *,
    chunks: list[LyricChunk],
    sample_path: str,
    preferred_profile_id: str,
    language_code: str,
    profile_name: str,
    reference_text: str,
    tmp_dir: str,
    request_id: str,
) -> tuple[list[str], list[int], str, dict]:
    grouped_chunks = _group_chunks_for_voicebox(chunks)
    if not grouped_chunks:
        raise RuntimeError("No lyric chunks available for Voicebox synthesis.")

    profile = _ensure_voicebox_profile(
        sample_path=sample_path,
        preferred_profile_id=preferred_profile_id,
        profile_name=profile_name,
        language_code=language_code,
        reference_text=reference_text,
        request_id=request_id,
    )
    engine = "chatterbox"

    chunk_wavs: list[str] = []
    pause_ms_by_chunk: list[int] = []
    for index, chunk in enumerate(grouped_chunks):
        _raise_if_clone_cancelled(request_id)
        body = {
            "profile_id": profile["profile_id"],
            "text": chunk.text,
            "language": language_code,
            "engine": engine,
            "max_chunk_chars": 1200,
            "crossfade_ms": 80,
            "normalize": True,
        }
        try:
            generation = _voicebox_json(
                "POST",
                "/generate",
                json_body=body,
                timeout=(15.0, 900.0),
            )
        except RuntimeError as exc:
            if "language" not in str(exc).lower():
                raise
            body.pop("language", None)
            generation = _voicebox_json(
                "POST",
                "/generate",
                json_body=body,
                timeout=(15.0, 900.0),
            )

        if not isinstance(generation, dict):
            raise RuntimeError("Voicebox generation returned an unexpected payload.")

        generation_id = str(generation.get("id") or "").strip()
        if not generation_id:
            raise RuntimeError("Voicebox generation did not return an id.")

        raw_chunk = os.path.join(tmp_dir, f"voicebox_raw_{index:03d}.wav")
        normalized_chunk = os.path.join(tmp_dir, f"voicebox_chunk_{index:03d}.wav")
        _voicebox_download_audio(
            generation_id=generation_id,
            out_path=raw_chunk,
            request_id=request_id,
        )
        _normalize_generated_wav(raw_chunk, normalized_chunk)
        chunk_wavs.append(normalized_chunk)
        pause_ms_by_chunk.append(chunk.pause_ms)

    synthesis_engine = f"voicebox:{engine}:{profile['profile_id']}"
    return chunk_wavs, pause_ms_by_chunk, synthesis_engine, profile


@app.get("/artifacts/{artifact_key}/{file_name:path}", include_in_schema=False)
def get_artifact(artifact_key: str, file_name: str) -> FileResponse:
    safe_key = _artifact_key(artifact_key)
    artifact_dir = (_artifact_root / safe_key).resolve()
    target = (artifact_dir / file_name).resolve()

    if artifact_dir != target.parent:
        raise HTTPException(404, "Artifact not found.")
    if not target.exists() or not target.is_file():
        raise HTTPException(404, "Artifact not found.")

    media_type = "audio/wav" if target.suffix.lower() == ".wav" else "application/octet-stream"
    return FileResponse(str(target), media_type=media_type)


def _preferred_pause_ms(text: str, *, is_line_end: bool) -> int:
    trimmed = text.strip()
    if not trimmed:
        return 0
    if re.search(r"[.!?…]['\"\)]?$", trimmed):
        return 240
    if re.search(r"[,;:]['\"\)]?$", trimmed):
        return 150
    if is_line_end:
        return 180
    return 100


def _split_long_phrase(phrase: str, max_chars: int) -> list[str]:
    remainder = re.sub(r"\s+", " ", phrase).strip()
    pieces: list[str] = []

    while len(remainder) > max_chars:
        window = remainder[:max_chars]
        cut = max(
            window.rfind(" - "),
            window.rfind(", "),
            window.rfind("; "),
            window.rfind(": "),
            window.rfind(" and "),
            window.rfind(" but "),
            window.rfind(" then "),
            window.rfind(" so "),
            window.rfind(" ", max_chars // 2),
        )
        if cut <= 0:
            cut = window.rfind(" ")
        if cut <= 0:
            cut = max_chars

        piece = remainder[:cut].strip()
        if piece:
            pieces.append(piece)
        remainder = remainder[cut:].strip()

    if remainder:
        pieces.append(remainder)
    return pieces


def _split_line_into_phrases(line: str) -> list[str]:
    normalized = re.sub(r"\s+", " ", line).strip()
    if not normalized:
        return []

    raw_parts = re.split(r"(?<=[,;:!?…])\s+|(?<=\.)\s+", normalized)
    phrases: list[str] = []
    for part in raw_parts:
        cleaned = part.strip()
        if not cleaned:
            continue
        phrases.extend(_split_long_phrase(cleaned, max_chars=140))
    return phrases


def _flush_chunk(
    chunks: list[LyricChunk],
    buffer: str,
    *,
    is_line_end: bool,
) -> str:
    cleaned = buffer.strip()
    if cleaned:
        chunks.append(LyricChunk(cleaned, _preferred_pause_ms(cleaned, is_line_end=is_line_end)))
    return ""


def _chunk_lyrics(text: str, max_chars: int = 170) -> list[LyricChunk]:
    chunks: list[LyricChunk] = []
    buffer = ""

    for line in text.splitlines():
        line = line.strip()
        if not line:
            buffer = _flush_chunk(chunks, buffer, is_line_end=True)
            continue

        phrases = _split_line_into_phrases(line)
        for index, phrase in enumerate(phrases):
            is_last_phrase = index == len(phrases) - 1
            candidate = phrase if not buffer else f"{buffer} {phrase}"

            if len(candidate) <= max_chars:
                buffer = candidate
                continue

            buffer = _flush_chunk(chunks, buffer, is_line_end=False)
            if len(phrase) <= max_chars:
                buffer = phrase
                continue

            pieces = _split_long_phrase(phrase, max_chars=max_chars)
            for piece_index, piece in enumerate(pieces):
                is_piece_last = piece_index == len(pieces) - 1
                should_end_line = is_last_phrase and is_piece_last
                chunks.append(
                    LyricChunk(
                        piece,
                        _preferred_pause_ms(piece, is_line_end=should_end_line),
                    )
                )
            buffer = ""

        buffer = _flush_chunk(chunks, buffer, is_line_end=True)

    return chunks


def _run_ffmpeg_wav_convert(src: str, dst: str, sample_rate: int, channels: int = 1) -> None:
    cmd = [
        "ffmpeg", "-y", "-i", src,
        "-ar", str(sample_rate),
        "-ac", str(channels),
        "-c:a", "pcm_s16le",
        dst,
        "-loglevel", "error",
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


def _normalize_generated_wav(src: str, dst: str) -> None:
    _run_ffmpeg_wav_convert(src, dst, sample_rate=24000, channels=1)


def _merge_wav_chunks(
    chunk_paths: list[str],
    out_path: str,
    *,
    pause_ms_by_chunk: list[int] | None = None,
    crossfade_ms: int = 18,
) -> None:
    import array
    import wave

    out_frames = array.array("h")
    format_params = None
    framerate = None
    channels = 1

    for index, p in enumerate(chunk_paths):
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
                framerate = current_format[2]
                channels = current_format[0]
            elif current_format != format_params:
                raise RuntimeError("WAV chunks have mismatched audio parameters; cannot merge.")
            raw = wf.readframes(wf.getnframes())
            chunk_frames = array.array("h")
            chunk_frames.frombytes(raw)

            if not out_frames:
                out_frames.extend(chunk_frames)
            else:
                overlap = min(
                    len(out_frames),
                    len(chunk_frames),
                    max(int((framerate or 24000) * crossfade_ms / 1000) * channels, 0),
                )
                if overlap > 0:
                    start = len(out_frames) - overlap
                    for i in range(overlap):
                        ratio = (i + 1) / overlap
                        mixed = int(
                            (out_frames[start + i] * (1.0 - ratio))
                            + (chunk_frames[i] * ratio)
                        )
                        out_frames[start + i] = mixed
                    out_frames.extend(chunk_frames[overlap:])
                else:
                    out_frames.extend(chunk_frames)

            if (
                pause_ms_by_chunk is not None
                and index < len(pause_ms_by_chunk)
                and index < len(chunk_paths) - 1
            ):
                pause_ms = max(pause_ms_by_chunk[index], 0)
                silence_frames = int(((framerate or 24000) * pause_ms / 1000)) * channels
                if silence_frames > 0:
                    out_frames.extend([0] * silence_frames)

    if format_params is None or not out_frames:
        raise RuntimeError("No audio chunks to merge.")

    with wave.open(out_path, "wb") as wf:
        wf.setnchannels(format_params[0])
        wf.setsampwidth(format_params[1])
        wf.setframerate(format_params[2])
        wf.setcomptype(format_params[3], format_params[4])
        wf.writeframes(out_frames.tobytes())


# ── Language detection ─────────────────────────────────────────────────────────

def _detect_language_code(text: str) -> str:
    counts: dict[str, int] = {
        "devanagari": 0, "arabic": 0, "hangul": 0,
        "hiragana": 0, "cjk": 0, "cyrillic": 0,
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
        "devanagari": "hi", "arabic": "ar", "hangul": "ko",
        "hiragana": "ja", "cjk": "zh", "cyrillic": "ru",
    }
    best = max(counts, key=counts.get)
    return script_to_lang[best] if counts[best] >= 5 else "en"


@app.post("/clone/cancel")
async def cancel_clone(request_id: str = Form(...)) -> dict:
    trimmed = (request_id or "").strip()
    if not trimmed:
        raise HTTPException(400, "request_id is required.")
    was_active = _cancel_clone_request(trimmed)
    return {"status": "ok", "request_id": trimmed, "was_active": was_active}


@app.post("/voicebox/profile/bootstrap")
def bootstrap_voicebox_profile(
    voice_sample: UploadFile = File(...),
    profile_id: str = Form(""),
    profile_name: str = Form(""),
    language: str = Form(""),
    reference_text: str = Form(""),
    request_id: str = Form(""),
) -> dict:
    available, detail = _voicebox_health_snapshot(force=True)
    if not available:
        raise HTTPException(503, detail)

    tmp_dir = tempfile.mkdtemp(prefix="mongobox_voicebox_profile_")
    try:
        suffix = Path(voice_sample.filename or "voice_sample").suffix or ".bin"
        sample_path = os.path.join(tmp_dir, f"voice_sample{suffix}")
        with open(sample_path, "wb") as handle:
            shutil.copyfileobj(voice_sample.file, handle)

        is_hindi = _is_hindi_family_language_hint(language)
        voicebox_language = _coerce_voicebox_language(
            language_hint=language,
            tts_language_code="",
            detected_lang="hi" if is_hindi else "en",
            is_hindi=is_hindi,
        )
        profile = _ensure_voicebox_profile(
            sample_path=sample_path,
            preferred_profile_id=profile_id,
            profile_name=profile_name,
            language_code=voicebox_language,
            reference_text=reference_text,
            request_id=(request_id or "").strip(),
        )
        return {
            "status": "ok",
            "profile_id": profile["profile_id"],
            "profile_name": profile["profile_name"],
            "language": profile["language"],
            "engine": profile["engine"],
            "reference_text": profile["reference_text"],
        }
    except HTTPException:
        raise
    except Exception as exc:
        log.exception("Voicebox profile bootstrap failed: %s", exc)
        raise HTTPException(500, str(exc)) from exc
    finally:
        try:
            shutil.rmtree(tmp_dir, ignore_errors=True)
        finally:
            try:
                voice_sample.file.close()
            except Exception:
                pass


# ── Background music extraction ────────────────────────────────────────────────

def _download_youtube_audio(video_id: str, out_path: str, tmp_dir: str) -> bool:
    """Download best audio from YouTube using yt-dlp and convert to WAV."""
    video_id = (video_id or "").strip()
    if not video_id:
        return False

    url = f"https://www.youtube.com/watch?v={video_id}"
    template = os.path.join(tmp_dir, "yt_audio.%(ext)s")
    cmd = [
        sys.executable, "-m", "yt_dlp",
        "-f", "bestaudio/best",
        "-o", template,
        "--no-playlist",
        "--no-warnings",
        "--geo-bypass",
        url,
    ]
    log.info("Downloading YouTube audio for video_id=%s", video_id)
    try:
        result = subprocess.run(
            cmd, check=True, capture_output=True, text=True,
            timeout=180, cwd=tmp_dir,
        )
        log.debug("yt-dlp stdout: %s", result.stdout[-300:] if result.stdout else "")
    except FileNotFoundError:
        log.warning("yt-dlp not found. Install with: pip install yt-dlp")
        return False
    except subprocess.CalledProcessError as e:
        log.warning("yt-dlp failed for %s: %s", video_id, (e.stderr or "")[-300:])
        return False
    except subprocess.TimeoutExpired:
        log.warning("yt-dlp timed out for video_id=%s", video_id)
        return False

    import glob
    downloaded = [
        f for f in glob.glob(os.path.join(tmp_dir, "yt_audio.*"))
        if os.path.isfile(f)
    ]
    if not downloaded:
        log.warning("yt-dlp ran but produced no output file for video_id=%s", video_id)
        return False

    try:
        _run_ffmpeg_wav_convert(downloaded[0], out_path, sample_rate=44100, channels=2)
        log.info("YouTube audio downloaded and converted: %s", out_path)
        return True
    except Exception as e:
        log.warning("ffmpeg conversion of yt audio failed: %s", e)
        return False


def _separate_instrumental(audio_path: str, out_dir: str) -> str | None:
    """
    Run Demucs vocal separation and return the path to no_vocals.wav.
    Tries htdemucs_ft first, then htdemucs, then mdx_extra as fallback.
    Walks the full output tree to find the stem regardless of version-specific
    subdirectory structure.
    """
    demucs_out = os.path.join(out_dir, "demucs_out")
    os.makedirs(demucs_out, exist_ok=True)
    missing_torchcodec = False

    for model_name in ["htdemucs_ft", "htdemucs", "mdx_extra"]:
        log.info("Trying Demucs model: %s", model_name)
        cmd = [
            sys.executable, "-m", "demucs",
            "-n", model_name,
            "--two-stems", "vocals",
            "-o", demucs_out,
            audio_path,
        ]
        try:
            result = subprocess.run(
                cmd, check=True, capture_output=True,
                text=True, timeout=900, cwd=out_dir,
            )
            log.info(
                "Demucs %s finished. stdout tail: %s",
                model_name,
                (result.stdout or "")[-300:],
            )
        except FileNotFoundError:
            log.warning("demucs not found. Install with: pip install demucs")
            return None
        except subprocess.CalledProcessError as e:
            stderr_tail = (e.stderr or "")[-400:]
            log.warning(
                "Demucs %s failed (exit %d): %s",
                model_name, e.returncode,
                stderr_tail,
            )
            if "TorchCodec is required" in stderr_tail:
                missing_torchcodec = True
                log.error(
                    "Demucs requires torchcodec for audio export. Install it with: "
                    "python -m pip install -r requirements.txt"
                )
                break
            continue
        except subprocess.TimeoutExpired:
            log.warning("Demucs %s timed out", model_name)
            continue

        # Walk the full output tree — demucs versions differ in subdir depth
        for root, _, files in os.walk(demucs_out):
            if "no_vocals.wav" in files:
                found = os.path.join(root, "no_vocals.wav")
                log.info("Instrumental stem found: %s", found)
                return found

        log.warning(
            "Demucs %s ran but no_vocals.wav not found. Tree: %s",
            model_name,
            [(r, f) for r, _, f in os.walk(demucs_out)],
        )

    if missing_torchcodec:
        log.error(
            "Background music extraction aborted because torchcodec is missing. "
            "Demucs output tree: %s",
            [(r, f) for r, _, f in os.walk(demucs_out)],
        )
    else:
        log.error(
            "All Demucs models failed. Full output tree: %s",
            [(r, f) for r, _, f in os.walk(demucs_out)],
        )
    return None


def _get_wav_duration_seconds(path: str) -> float:
    import wave
    with wave.open(path, "rb") as wf:
        frames = wf.getnframes()
        rate = wf.getframerate()
        return frames / float(rate) if rate else 0.0


# ── NOTE: _mix_vocal_with_instrumental is intentionally removed. ───────────────
# The backend now always returns voice-only WAV + instrumental as a separate
# streamable artifact URL. This gives the Flutter client full independent
# volume control over vocals and background music via two separate AudioPlayers.


# ── Main clone endpoint ────────────────────────────────────────────────────────

@app.post("/clone")
def clone_voice(
    voice_sample: UploadFile = File(...),
    request_id: str = Form(""),
    lyrics: str = Form(...),
    mood: str = Form(""),
    genre: str = Form(""),
    language: str = Form(""),
    tts_language_code: str = Form(""),
    reference_track_title: str = Form(""),
    reference_artist_name: str = Form(""),
    reference_lyric_snippet: str = Form(""),
    reference_transcript: str = Form(""),
    reference_video_id: str = Form(""),
    voicebox_profile_id: str = Form(""),
) -> FileResponse:
    if not lyrics.strip():
        raise HTTPException(400, "Lyrics must not be empty.")

    params = _parse_clone_request(
        request_id=request_id,
        lyrics=lyrics,
        mood=mood,
        genre=genre,
        language=language,
        tts_language_code=tts_language_code,
        reference_track_title=reference_track_title,
        reference_artist_name=reference_artist_name,
        reference_lyric_snippet=reference_lyric_snippet,
        reference_transcript=reference_transcript,
        reference_video_id=reference_video_id,
        voicebox_profile_id=voicebox_profile_id,
    )
    _mark_clone_request_active(params.request_id)

    log.info(
        "Clone request received: request_id=%s language=%s "
        "mood=%s genre=%s reference=%s/%s video_id=%s voicebox_profile_id=%s",
        params.request_id or "(none)",
        params.language or "-",
        params.mood or "-",
        params.genre or "-",
        params.reference_track_title or "-",
        params.reference_artist_name or "-",
        params.reference_video_id or "(none)",
        params.voicebox_profile_id or "(none)",
    )

    tmp_dir = tempfile.mkdtemp(prefix="mongobox_")
    try:
        # 1) Save uploaded voice sample
        suffix = Path(voice_sample.filename or "voice_sample").suffix or ".bin"
        src_path = os.path.join(tmp_dir, f"voice_sample{suffix}")
        with open(src_path, "wb") as fh:
            shutil.copyfileobj(voice_sample.file, fh)
        log.info("Received voice sample: %s (%d bytes)", suffix, os.path.getsize(src_path))
        _raise_if_clone_cancelled(params.request_id)

        clean_lyrics = _strip_section_tags(params.lyrics)
        chunks = _chunk_lyrics(clean_lyrics)
        if not chunks:
            raise HTTPException(400, "Lyrics are empty after stripping section tags.")

        detected_lang = _detect_language_code(clean_lyrics)
        hindi_hint = _is_hindi_family_language_hint(params.language)
        voicebox_language = _coerce_voicebox_language(
            language_hint=params.language,
            tts_language_code=params.tts_language_code,
            detected_lang=detected_lang,
            is_hindi=hindi_hint,
        )
        log.info(
            "Pipeline: chunks=%d voicebox_language=%s (detected_script=%s)",
            len(chunks),
            voicebox_language,
            detected_lang,
        )

        try:
            chunk_wavs, pause_ms_by_chunk, synthesis_engine, _ = _synthesise_with_voicebox(
                chunks=chunks,
                sample_path=src_path,
                preferred_profile_id=params.voicebox_profile_id,
                language_code=voicebox_language,
                profile_name=f"{params.language or 'MongoBox'} Voice",
                reference_text=params.reference_transcript,
                tmp_dir=tmp_dir,
                request_id=params.request_id,
            )
        except RuntimeError as exc:
            raise HTTPException(503, f"Voicebox unavailable: {exc}") from exc

        log.info(
            "Voicebox synthesis complete: engine=%s language=%s profile_hint=%s",
            synthesis_engine,
            voicebox_language,
            params.voicebox_profile_id or "(create or reuse)",
        )

        # 5) Merge chunks
        _raise_if_clone_cancelled(params.request_id)
        final_wav = os.path.join(tmp_dir, "cloned_voice.wav")
        if len(chunk_wavs) == 1:
            shutil.copy(chunk_wavs[0], final_wav)
        else:
            _merge_wav_chunks(
                chunk_wavs,
                final_wav,
                pause_ms_by_chunk=pause_ms_by_chunk,
            )
        log.info(
            "Voice synthesis complete: engine=%s bytes=%d",
            synthesis_engine, os.path.getsize(final_wav),
        )

        # 6) Background music extraction — always return as separate stream.
        #    We never bake the mix into the vocal WAV so the Flutter client
        #    can give the user independent volume control over both tracks.
        music_url = ""
        music_label = ""

        video_id = params.reference_video_id
        if video_id:
            log.info("Background music pipeline starting for video_id=%s", video_id)
            _raise_if_clone_cancelled(params.request_id)

            yt_wav = os.path.join(tmp_dir, "yt_reference.wav")
            downloaded = _download_youtube_audio(video_id, yt_wav, tmp_dir)

            if downloaded:
                _raise_if_clone_cancelled(params.request_id)
                log.info("Starting Demucs vocal separation…")
                inst_path = _separate_instrumental(yt_wav, tmp_dir)

                if inst_path:
                    _raise_if_clone_cancelled(params.request_id)
                    artifact_url = _persist_request_artifact(
                        inst_path,
                        params.request_id,
                        "instrumental.wav",
                    )
                    if artifact_url:
                        music_url = artifact_url
                        music_label = "Original instrumental - adjust volume below"
                        log.info("Background instrumental prepared as separate stream ✓")
                    else:
                        log.warning(
                            "Instrumental extracted but could not be persisted — returning voice-only"
                        )
                else:
                    log.warning(
                        "Demucs separation produced no output — returning voice-only"
                    )
            else:
                log.warning(
                    "YouTube download failed for video_id=%s — returning voice-only",
                    video_id,
                )
        else:
            log.info("No reference_video_id provided — skipping background music pipeline")

        # mix_status is always "voice_only" now — the Flutter client handles
        # mixing in real-time using two independent AudioPlayer instances.
        mix_status = "voice_only"

        log.info(
            "Request complete: mix_status=%s has_music=%s audio_bytes=%d engine=%s",
            mix_status,
            bool(music_url),
            os.path.getsize(final_wav),
            synthesis_engine,
        )

        return FileResponse(
            final_wav,
            media_type="audio/wav",
            headers={
                "X-MongoBox-Mix-Status": _header_safe(mix_status),
                "X-MongoBox-Mix-Label": _header_safe(""),
                "X-MongoBox-Music-Url": _header_safe(music_url),
                "X-MongoBox-Music-Label": _header_safe(music_label),
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


# ── BPM & Health endpoints ─────────────────────────────────────────────────────

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
    voicebox_available, voicebox_detail = _voicebox_health_snapshot()
    return {
        "status": "ok",
        "voicebox_api_url": _VOICEBOX_API_URL,
        "voicebox_available": voicebox_available,
        "voicebox_detail": voicebox_detail,
    }


@app.get("/healthz", include_in_schema=False)
def healthz() -> dict:
    return health()
