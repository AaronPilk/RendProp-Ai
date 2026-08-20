#!/usr/bin/env python3
"""
Shared plumbing for provider adapters — stdlib only (no SDK install required, so
the pipeline runs anywhere Python does; swap for httpx if you prefer later).

Provides: JSON/HTTP request helpers, base64 data-URI encode, URL→bytes download,
a common ProviderResult, and typed errors the router can catch.
"""

from __future__ import annotations

import base64
import json
import urllib.error
import urllib.request
from dataclasses import dataclass, field


# ── Errors ────────────────────────────────────────────────────────────────────

class ProviderError(RuntimeError):
    """Any provider-side failure (HTTP error, bad payload, job failed)."""


class ProviderTimeout(ProviderError):
    """A queued/async job did not complete within the timeout."""


class MissingKey(ProviderError):
    """Required API key not configured — surfaced early with a clear message."""


# ── Result ────────────────────────────────────────────────────────────────────

@dataclass
class ProviderResult:
    """What an adapter hands back to the router.

    `data` is the produced media bytes (image or video). `unit_cost_cents` and
    `units` are the KNOWN unit economics for this call; `total_cents` is their
    product unless the adapter computed an exact figure (e.g. QC from tokens).
    `meta` is opaque JSON stored on the ledger row for debugging/auditing.
    """
    data: bytes = b""
    provider: str = ""
    model: str = ""
    feature: str = ""
    units: float = 1.0
    unit_cost_cents: float = 0.0
    total_cents: float = 0.0
    meta: dict = field(default_factory=dict)


# ── HTTP (stdlib) ─────────────────────────────────────────────────────────────

def request_json(
    url: str,
    *,
    method: str = "POST",
    payload: dict | None = None,
    headers: dict | None = None,
    timeout: int = 120,
) -> dict:
    """POST/GET JSON and parse a JSON response. Raises ProviderError on non-2xx."""
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = e.read().decode()[:2000]
        except Exception:  # noqa: BLE001
            pass
        raise ProviderError(f"HTTP {e.code} from {url}: {detail}") from e
    except urllib.error.URLError as e:
        raise ProviderError(f"Network error to {url}: {e.reason}") from e


def download_bytes(url: str, *, timeout: int = 120) -> bytes:
    """Fetch a media URL (fal output, etc.) into raw bytes."""
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read()
    except urllib.error.HTTPError as e:
        raise ProviderError(f"HTTP {e.code} downloading {url}") from e
    except urllib.error.URLError as e:
        raise ProviderError(f"Network error downloading {url}: {e.reason}") from e


# ── Encoding helpers ──────────────────────────────────────────────────────────

def b64(data: bytes) -> str:
    return base64.b64encode(data).decode()


def data_uri(data: bytes, mime: str = "image/jpeg") -> str:
    """fal + Gemini + Anthropic all accept base64 — pass local bytes with no host."""
    return f"data:{mime};base64,{b64(data)}"


def sniff_mime(data: bytes, default: str = "image/jpeg") -> str:
    """Best-effort image MIME from magic bytes (keeps payload media_type honest)."""
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return default
