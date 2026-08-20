#!/usr/bin/env python3
"""
Central config for the Rendprop AI-enhancement pipeline.

One place to read every env var, guard value, model route, and the shared
"architecture is untouchable" prompt language. Everything downstream (providers,
router, ledger, orchestrator, CLI) imports from here so keys/models/caps are set
in exactly one spot.

Env is documented in `.env.example` and (in production) lives in Supabase Edge
Function secrets / the render-worker env — never in the iOS app.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

# ── .env loader (stdlib only) ─────────────────────────────────────────────────

def load_env(path: Path | None = None) -> None:
    """Populate os.environ from a .env file if present (does not override).

    Silent no-op when the file is missing so imports never crash — the pipeline
    reads real secrets from the process env in production. The CLI / orchestrator
    validate the specific keys they need at call time.
    """
    path = path or (Path(__file__).parent / ".env")
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, _, v = line.partition("=")
            os.environ.setdefault(k.strip(), v.strip())


load_env()


def _int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


def _float(name: str, default: float) -> float:
    try:
        return float(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


# ── Settings ──────────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class Settings:
    # Provider keys
    gemini_api_key: str = ""
    fal_key: str = ""
    anthropic_api_key: str = ""
    kie_api_key: str = ""

    # Supabase (service role — server-side only)
    supabase_url: str = ""
    supabase_service_role_key: str = ""

    # Model routes (swap without code changes as prices/models move)
    gemini_image_model: str = "gemini-2.5-flash-image"
    fal_declutter_model: str = "fal-ai/flux-pro/v1/fill"
    fal_restage_fallback_model: str = "fal-ai/flux-pro/kontext"
    fal_hero_model: str = "fal-ai/bytedance/seedance/v1/pro/fast/image-to-video"
    anthropic_model_qc: str = "claude-haiku-4-5"
    anthropic_model_escalate: str = "claude-sonnet-5"

    # Route selection per feature: "gemini" | "fal" | "kie" for restage.
    restage_route: str = "gemini"

    # Cost + quality guards
    qc_pass_score: int = 85
    qc_max_retries: int = 2
    qc_confidence_escalate: float = 0.75  # Haiku confidence below this → Sonnet
    max_gen_cost_per_job_cents: int = 2500

    # fal queue polling
    fal_poll_interval_s: float = 3.0
    fal_timeout_s: int = 600
    anthropic_version: str = "2023-06-01"

    @classmethod
    def from_env(cls) -> "Settings":
        return cls(
            gemini_api_key=os.environ.get("GEMINI_API_KEY", ""),
            fal_key=os.environ.get("FAL_KEY", ""),
            anthropic_api_key=os.environ.get("ANTHROPIC_API_KEY", ""),
            kie_api_key=os.environ.get("KIE_API_KEY", ""),
            supabase_url=os.environ.get("SUPABASE_URL", "").rstrip("/"),
            supabase_service_role_key=os.environ.get("SUPABASE_SERVICE_ROLE_KEY", ""),
            gemini_image_model=os.environ.get("GEMINI_IMAGE_MODEL", "gemini-2.5-flash-image"),
            fal_declutter_model=os.environ.get("FAL_DECLUTTER_MODEL", "fal-ai/flux-pro/v1/fill"),
            fal_restage_fallback_model=os.environ.get("FAL_RESTAGE_FALLBACK_MODEL", "fal-ai/flux-pro/kontext"),
            fal_hero_model=os.environ.get("FAL_HERO_MODEL", "fal-ai/bytedance/seedance/v1/pro/fast/image-to-video"),
            anthropic_model_qc=os.environ.get("ANTHROPIC_MODEL_QC", "claude-haiku-4-5"),
            anthropic_model_escalate=os.environ.get("ANTHROPIC_MODEL_ESCALATE", "claude-sonnet-5"),
            restage_route=os.environ.get("RESTAGE_ROUTE", "gemini"),
            qc_pass_score=_int("QC_PASS_SCORE", 85),
            qc_max_retries=_int("QC_MAX_RETRIES", 2),
            qc_confidence_escalate=_float("QC_CONFIDENCE_ESCALATE", 0.75),
            max_gen_cost_per_job_cents=_int("MAX_GEN_COST_PER_JOB_CENTS", 2500),
            fal_poll_interval_s=_float("FAL_POLL_INTERVAL_S", 3.0),
            fal_timeout_s=_int("FAL_TIMEOUT_S", 600),
            anthropic_version=os.environ.get("ANTHROPIC_VERSION", "2023-06-01"),
        )


SETTINGS = Settings.from_env()


# ── Shared prompt language ─────────────────────────────────────────────────────
# The paramount product rule, expressed once. Reused by every edit prompt and the
# QC judge so declutter/restage can only touch furniture & decor.

ARCHITECTURE_LOCK = (
    "CRITICAL, NON-NEGOTIABLE: keep the architecture pixel-identical. Do NOT move, "
    "add, remove, resize, or restyle walls, windows, doors, doorframes, floors, "
    "ceilings, stairs, built-in fixtures, cabinetry, countertops, the camera angle, "
    "the lens, the perspective, or the view through any window. Change FURNITURE and "
    "DECOR only. Never hide or alter property defects. Preserve the existing lighting "
    "direction and color temperature."
)

# Restage style prompts (kept from the original orchestrator).
STYLES = {
    "modern":       "clean-lined contemporary furniture, low-profile charcoal sectional, walnut and matte-black accents, minimal abstract wall art, modern area rug",
    "rustic":       "warm farmhouse furniture, natural woods, cozy layered textiles, vintage-style decor, warm earth tones",
    "minimalist":   "very few carefully chosen pieces, neutral palette, clean surfaces, airy negative space, simple line art",
    "scandinavian": "light oak furniture, soft whites and greys, hygge textures, simple functional pieces, green plants",
}


def style_prompt(style: str) -> str:
    """Full restage instruction for a named style, with the architecture lock."""
    desc = STYLES.get(style, style)
    return f"Virtually restage this room in {style} style: {desc}. {ARCHITECTURE_LOCK}"
