#!/usr/bin/env python3
"""
fal.ai adapter — declutter (Flux Fill masked inpaint), the hero clip (Seedance
1.0 Pro Fast i2v), and the restage fallback (Flux Kontext).

We speak fal's REST **queue** protocol directly with stdlib (submit → poll →
fetch result), so no SDK install is required. Auth is `Authorization: Key $FAL_KEY`.
Inputs are passed as base64 data URIs (fal accepts them for any *_url field), so
local frames need no public hosting for the API call itself.

Endpoints / schemas verified against fal docs (see module CITATIONS):
  • Declutter : fal-ai/flux-pro/v1/fill
        in  { prompt, image_url*, mask_url*, output_format }
        out { images:[{url,content_type}], seed, ... }
  • Hero clip : fal-ai/bytedance/seedance/v1/pro/fast/image-to-video
        in  { prompt*, image_url*, resolution:"1080p", duration:"5" (str 2..12) }
        out { video:{url}, seed }
  • Restage fb: fal-ai/flux-pro/kontext
        in  { prompt*, image_url* }   out { images:[{url}] }

CITATIONS:
  https://fal.ai/models/fal-ai/flux-pro/v1/fill/api
  https://fal.ai/models/fal-ai/bytedance/seedance/v1/pro/fast/image-to-video/api
  https://fal.ai/docs/documentation/model-apis/inference/queue

NOTE: this module is `providers.fal_client` (stdlib). It is intentionally NOT the
`fal_client` pip SDK; we don't import that package anywhere.
"""

from __future__ import annotations

import time

from config import SETTINGS
from providers import costs
from providers.base import (
    MissingKey,
    ProviderError,
    ProviderResult,
    ProviderTimeout,
    data_uri,
    download_bytes,
    request_json,
    sniff_mime,
)

QUEUE_BASE = "https://queue.fal.run"

# KNOWN unit costs (from providers/costs.py — the single table).
DECLUTTER_UNIT_COST_CENTS = costs.UNIT_COSTS_CENTS["declutter_flux_fill"]
RESTAGE_FALLBACK_UNIT_COST_CENTS = costs.UNIT_COSTS_CENTS["restage_fal_kontext"]
HERO_UNIT_COST_CENTS_PER_SEC = costs.UNIT_COSTS_CENTS["hero_seedance_per_s"]

# Default declutter fill instruction (the mask constrains it to clutter only).
DECLUTTER_FILL_PROMPT = (
    "Seamlessly fill the masked area so it matches the surrounding floor, wall, "
    "and surfaces. Photorealistic, consistent lighting, texture, and perspective. "
    "Empty, clean, uncluttered — no new furniture or objects."
)


def _headers() -> dict:
    if not SETTINGS.fal_key:
        raise MissingKey("FAL_KEY is not set — cannot call fal.ai.")
    return {"Authorization": f"Key {SETTINGS.fal_key}"}


def _run(model_id: str, arguments: dict, *, timeout_s: int | None = None) -> dict:
    """Submit to the fal queue, poll status, return the completed result JSON."""
    timeout_s = timeout_s or SETTINGS.fal_timeout_s
    submit = request_json(
        f"{QUEUE_BASE}/{model_id}", method="POST", payload=arguments, headers=_headers()
    )
    status_url = submit.get("status_url")
    response_url = submit.get("response_url")
    if not status_url or not response_url:
        # Some endpoints return the result inline on submit — accept that too.
        if submit.get("images") or submit.get("video"):
            return submit
        raise ProviderError(f"Unexpected fal submit response: {submit}")

    started = time.time()
    while time.time() - started < timeout_s:
        st = request_json(status_url, method="GET", headers=_headers())
        status = st.get("status")
        if status == "COMPLETED":
            return request_json(response_url, method="GET", headers=_headers())
        if status in ("FAILED", "ERROR"):
            raise ProviderError(f"fal job failed ({model_id}): {st}")
        time.sleep(SETTINGS.fal_poll_interval_s)
    raise ProviderTimeout(f"fal job timed out after {timeout_s}s: {model_id}")


def _first_image_bytes(result: dict) -> bytes:
    images = result.get("images") or []
    if not images or not images[0].get("url"):
        raise ProviderError(f"fal result had no image url: {result}")
    return download_bytes(images[0]["url"])


def _video_bytes(result: dict) -> bytes:
    video = result.get("video") or {}
    if not video.get("url"):
        raise ProviderError(f"fal result had no video url: {result}")
    return download_bytes(video["url"], timeout=SETTINGS.fal_timeout_s)


# ── Public adapters ───────────────────────────────────────────────────────────

def declutter(image: bytes, mask: bytes, *, prompt: str | None = None) -> bytes:
    """Masked inpaint declutter. `mask` marks the clutter (white = repaint).

    Architecture is preserved BY CONSTRUCTION: everything outside the mask is
    mathematically untouched. Returns the edited image bytes.
    """
    result = _run(SETTINGS.fal_declutter_model, {
        "prompt": prompt or DECLUTTER_FILL_PROMPT,
        "image_url": data_uri(image, sniff_mime(image)),
        "mask_url": data_uri(mask, sniff_mime(mask, "image/png")),
        "output_format": "jpeg",
    })
    return _first_image_bytes(result)


def declutter_result(image: bytes, mask: bytes, *, prompt: str | None = None) -> ProviderResult:
    """declutter() with the cost/meta envelope the router logs to the ledger."""
    data = declutter(image, mask, prompt=prompt)
    return ProviderResult(
        data=data, provider="fal", model=SETTINGS.fal_declutter_model, feature="declutter",
        units=1, unit_cost_cents=DECLUTTER_UNIT_COST_CENTS, total_cents=DECLUTTER_UNIT_COST_CENTS,
        meta={"masked_inpaint": True},
    )


def restage_fallback(image: bytes, style_prompt: str) -> bytes:
    """Prompt-based restage fallback via Flux Kontext (one-tap alt to Gemini)."""
    result = _run(SETTINGS.fal_restage_fallback_model, {
        "prompt": style_prompt,
        "image_url": data_uri(image, sniff_mime(image)),
        "output_format": "jpeg",
    })
    return _first_image_bytes(result)


def restage_fallback_result(image: bytes, style_prompt: str) -> ProviderResult:
    data = restage_fallback(image, style_prompt)
    return ProviderResult(
        data=data, provider="fal", model=SETTINGS.fal_restage_fallback_model, feature="restage",
        units=1, unit_cost_cents=RESTAGE_FALLBACK_UNIT_COST_CENTS,
        total_cents=RESTAGE_FALLBACK_UNIT_COST_CENTS, meta={"fallback": "flux_kontext"},
    )


def hero_clip(first_frame: bytes, prompt: str, seconds: int = 5) -> bytes:
    """Animate the FINISHED (decluttered/staged) still into a 2–12s hero clip.

    Feeding the corrected frame in means the video inherits the fixed room — no
    architecture regeneration. Returns MP4 bytes.
    """
    dur = max(2, min(12, int(round(seconds))))
    result = _run(SETTINGS.fal_hero_model, {
        "prompt": prompt,
        "image_url": data_uri(first_frame, sniff_mime(first_frame)),
        "resolution": "1080p",
        "duration": str(dur),
    })
    return _video_bytes(result)


def hero_clip_result(first_frame: bytes, prompt: str, seconds: int = 5) -> ProviderResult:
    dur = max(2, min(12, int(round(seconds))))
    data = hero_clip(first_frame, prompt, dur)
    total = costs.hero_cost_cents(dur)
    return ProviderResult(
        data=data, provider="fal", model=SETTINGS.fal_hero_model, feature="hero",
        units=dur, unit_cost_cents=HERO_UNIT_COST_CENTS_PER_SEC, total_cents=total,
        meta={"seconds": dur, "resolution": "1080p"},
    )
