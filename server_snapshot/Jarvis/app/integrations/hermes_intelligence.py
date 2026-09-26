from __future__ import annotations

import time
from pathlib import Path
from urllib.parse import urlparse

import httpx

from app.core.settings import settings


class HermesIntelligenceError(RuntimeError):
    """Safe Jarvis-facing Hermes integration error."""


class HermesIntelligenceTimeout(HermesIntelligenceError):
    """Hermes intelligence request timed out."""


def _base_url() -> str:
    """
    Return the configured Hermes API URL.

    Security invariant:
    Jarvis may only talk to Hermes over the certified local listener.
    """
    raw = str(settings.hermes_api_base_url).strip().rstrip("/")
    parsed = urlparse(raw)

    if parsed.scheme != "http":
        raise HermesIntelligenceError("HERMES_API_SCHEME_NOT_ALLOWED")

    if parsed.hostname != "127.0.0.1":
        raise HermesIntelligenceError("HERMES_API_NOT_LOOPBACK")

    if parsed.port != 8642:
        raise HermesIntelligenceError("HERMES_API_PORT_NOT_ALLOWED")

    return raw


def _read_api_key() -> str:
    """
    Read the dedicated SYSTEM-readable Jarvis/Hermes credential.

    The credential is deliberately not stored in the Jarvis project .env.
    """
    path = Path(settings.hermes_api_key_file)

    if not path.is_file():
        raise HermesIntelligenceError("HERMES_API_KEY_FILE_MISSING")

    key = path.read_text(encoding="ascii").strip()

    if len(key) < 16:
        raise HermesIntelligenceError("HERMES_API_KEY_INVALID")

    return key


def _headers() -> dict[str, str]:
    return {
        "Authorization": f"Bearer {_read_api_key()}",
        "Content-Type": "application/json",
    }


async def health() -> dict:
    """
    Read-only authenticated Hermes availability check.

    Never returns credential material or raw upstream exception text.
    """
    started = time.perf_counter()

    try:
        timeout = httpx.Timeout(10.0, connect=3.0)

        async with httpx.AsyncClient(timeout=timeout) as client:
            response = await client.get(
                f"{_base_url()}/v1/models",
                headers=_headers(),
            )

            response.raise_for_status()
            payload = response.json()

        models = [
            item.get("id")
            for item in payload.get("data", [])
            if isinstance(item, dict) and item.get("id")
        ]

        if not models:
            raise HermesIntelligenceError("HERMES_NO_MODELS")

        return {
            "status": "ok",
            "models": models,
            "latency_ms": round(
                (time.perf_counter() - started) * 1000,
                2,
            ),
        }

    except Exception as exc:
        return {
            "status": "degraded",
            "error": type(exc).__name__,
            "latency_ms": round(
                (time.perf_counter() - started) * 1000,
                2,
            ),
        }


async def query(prompt: str) -> dict:
    """
    Submit a reasoning/research request to the restricted Hermes worker.

    Hermes API toolsets are independently restricted to web_search/web_extract.
    This function exposes no OS, file, execution, MT5, or Kronos action path.
    """
    prompt = prompt.strip()

    if not prompt:
        raise HermesIntelligenceError("EMPTY_PROMPT")

    if len(prompt) > settings.hermes_prompt_max_chars:
        raise HermesIntelligenceError("PROMPT_TOO_LARGE")

    payload = {
        "model": settings.hermes_api_model,
        "messages": [
            {
                "role": "system",
                "content": (
                    "You are the read-only intelligence worker for Abutron Jarvis. "
                    "Provide analysis, diagnostics, research, and explanations only. "
                    "Do not claim that you executed, changed, restarted, deployed, "
                    "traded, modified, or controlled any production system."
                ),
            },
            {
                "role": "user",
                "content": prompt,
            },
        ],
        "stream": False,
    }

    started = time.perf_counter()

    try:
        timeout = httpx.Timeout(
            float(settings.hermes_api_timeout_seconds),
            connect=5.0,
        )

        async with httpx.AsyncClient(timeout=timeout) as client:
            response = await client.post(
                f"{_base_url()}/v1/chat/completions",
                headers=_headers(),
                json=payload,
            )

            response.raise_for_status()
            data = response.json()

    except httpx.TimeoutException as exc:
        raise HermesIntelligenceTimeout(
            "HERMES_REQUEST_TIMEOUT"
        ) from exc

    except httpx.HTTPStatusError as exc:
        raise HermesIntelligenceError(
            f"HERMES_HTTP_{exc.response.status_code}"
        ) from exc

    except httpx.HTTPError as exc:
        raise HermesIntelligenceError(
            "HERMES_TRANSPORT_ERROR"
        ) from exc

    choices = data.get("choices") or []

    if not choices:
        raise HermesIntelligenceError("HERMES_EMPTY_RESPONSE")

    message = choices[0].get("message") or {}
    answer = message.get("content")

    if not isinstance(answer, str) or not answer.strip():
        raise HermesIntelligenceError("HERMES_INVALID_RESPONSE")

    return {
        "provider": "hermes",
        "model": data.get("model") or settings.hermes_api_model,
        "answer": answer.strip(),
        "latency_ms": round(
            (time.perf_counter() - started) * 1000,
            2,
        ),
    }