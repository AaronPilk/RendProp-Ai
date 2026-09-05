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
import time
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

# ── retry policy (audit F-G-08) ───────────────────────────────────────────────
#
# A transient 429 or an "overloaded" 529 on room 7 of 8 used to throw the whole
# enhancement pass away. Retries are now built in — but DELIBERATELY NARROW,
# because every POST here can create a BILLABLE generation:
#
#   • Retry-safe statuses are the ones that say, unambiguously, "I did not
#     process this": 408 (request timeout), 429 (rate limited), 503 (unavailable)
#     and Anthropic's 529 (overloaded). No job was created, so no charge.
#   • 500/502/504 are NOT retried on a mutating request: the upstream may have
#     completed the generation and lost the response, and a retry would pay for
#     it twice. They ARE retried for GETs, which are idempotent.
#   • Connection-level failures are retried only for GET, for the same reason.
#
# `retries=0` (the default) preserves the old single-shot behaviour; call sites
# opt in where it is safe.

RETRY_AFTER_STATUSES = frozenset({408, 429, 503, 529})
IDEMPOTENT_5XX = frozenset({500, 502, 504})
MAX_RETRY_SLEEP_S = 30.0


def _retry_sleep(attempt: int, retry_after: str | None) -> float:
    """Exponential backoff, capped, honouring a server-sent Retry-After."""
    if retry_after:
        try:
            return min(MAX_RETRY_SLEEP_S, max(0.0, float(retry_after.strip())))
        except (TypeError, ValueError):
            pass
    return min(MAX_RETRY_SLEEP_S, 1.0 * (2 ** attempt))


def request_json(
    url: str,
    *,
    method: str = "POST",
    payload: dict | None = None,
    headers: dict | None = None,
    timeout: int = 120,
    retries: int = 0,
) -> dict:
    """POST/GET JSON and parse a JSON response. Raises ProviderError on non-2xx.

    `retries` is the number of EXTRA attempts (so retries=2 → up to 3 requests),
    bounded and backed off. See the retry policy above for what is retried and
    why a mutating call is not retried on an ambiguous 5xx.
    """
    data = json.dumps(payload).encode() if payload is not None else None
    idempotent = method.upper() in ("GET", "HEAD")
    attempts = max(0, int(retries)) + 1
    last: ProviderError | None = None

    for attempt in range(attempts):
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
            last = ProviderError(f"HTTP {e.code} from {url}: {detail}")
            retryable = e.code in RETRY_AFTER_STATUSES or (
                idempotent and e.code in IDEMPOTENT_5XX)
            if not retryable or attempt == attempts - 1:
                raise last from e
            wait = _retry_sleep(attempt, (e.headers or {}).get("Retry-After"))
            print(f"    ↻ HTTP {e.code} from {url.split('?')[0]} — retry "
                  f"{attempt + 1}/{attempts - 1} in {wait:.1f}s")
            time.sleep(wait)
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            # A READ timeout surfaces as socket.timeout/TimeoutError (not URLError);
            # it must still be a ProviderError so the per-segment fallback catches it.
            reason = getattr(e, "reason", e)
            last = ProviderError(f"Network error to {url}: {e.__class__.__name__}: {reason}")
            if not idempotent or attempt == attempts - 1:
                raise last from e
            wait = _retry_sleep(attempt, None)
            print(f"    ↻ network error on GET {url.split('?')[0]} — retry "
                  f"{attempt + 1}/{attempts - 1} in {wait:.1f}s")
            time.sleep(wait)

    raise last or ProviderError(f"request to {url} failed")


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
    except (TimeoutError, OSError) as e:
        raise ProviderError(f"Network error downloading {url}: {e.__class__.__name__}: {e}") from e


def put_bytes(url: str, data: bytes, *, content_type: str = "application/octet-stream",
              timeout: int = 300) -> None:
    """PUT raw bytes to a (usually pre-signed) URL — used for CDN uploads.

    No auth header is added: the upload URL from a CDN "initiate" step already
    carries its own credentials. Raises ProviderError on non-2xx / network error.
    """
    req = urllib.request.Request(url, data=data, method="PUT")
    req.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            resp.read()
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = e.read().decode()[:2000]
        except Exception:  # noqa: BLE001
            pass
        raise ProviderError(f"HTTP {e.code} uploading to {url}: {detail}") from e
    except urllib.error.URLError as e:
        raise ProviderError(f"Network error uploading to {url}: {e.reason}") from e


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
