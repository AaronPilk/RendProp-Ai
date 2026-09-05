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

def parse_env_line(line: str) -> tuple[str, str] | None:
    """One dotenv line → (key, value), or None for blanks/comments.

    Mirrors services/worker/settings.py. Handles ``export KEY=v``, quoted values,
    and inline ``# comments`` (audit F-G-11: ``MAX_GEN_COST_PER_JOB_CENTS=2500 # cap``
    used to be read as the string ``'2500 # cap'`` → int() failed → the default
    silently applied, so the one knob bounding AI spend did nothing from .env).
    """
    s = line.strip()
    if not s or s.startswith("#") or "=" not in s:
        return None
    if s.startswith("export "):
        s = s[len("export "):].lstrip()
    k, _, v = s.partition("=")
    k = k.strip()
    if not k or any(ch.isspace() for ch in k):
        return None
    v = v.strip()
    if v[:1] in ('"', "'"):
        q = v[0]
        end = v.find(q, 1)
        v = v[1:end] if end != -1 else v[1:]
    else:
        for i, ch in enumerate(v):
            if ch == "#" and (i == 0 or v[i - 1].isspace()):
                v = v[:i].rstrip()
                break
    return k, v


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
        kv = parse_env_line(line)
        if kv:
            os.environ.setdefault(kv[0], kv[1])


load_env()


class ConfigError(RuntimeError):
    """An env var is SET but unusable — never silently defaulted (audit F-G-11).

    MAX_GEN_COST_PER_JOB_CENTS is the ONLY thing bounding AI spend on an
    unattended job. A warning that scrolls past while the default quietly
    applies is not a guard. Mirrors services/worker/settings.ConfigError; the
    worker validates the same four names in its startup preflight, so in the
    worker path this raise is a backstop, not the first line of defence.
    """


def _range(name: str, value: float, raw: str, lo: float | None, hi: float | None) -> None:
    if lo is not None and value < lo:
        raise ConfigError(f"{name}={raw!r} is below the minimum {lo}")
    if hi is not None and value > hi:
        raise ConfigError(f"{name}={raw!r} is above the maximum {hi}")


def _int(name: str, default: int, *, lo: int | None = None, hi: int | None = None) -> int:
    """Parse an int env var. Unset/blank → default. Malformed → ConfigError."""
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    try:
        value = int(raw.strip())
    except (TypeError, ValueError):
        raise ConfigError(
            f"{name}={raw.strip()!r} is not an integer (default would have been "
            f"{default}). Fix the value — it is NOT being defaulted."
        ) from None
    _range(name, value, raw.strip(), lo, hi)
    return value


def _float(name: str, default: float, *, lo: float | None = None, hi: float | None = None) -> float:
    """Parse a float env var. Unset/blank → default. Malformed → ConfigError."""
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    try:
        value = float(raw.strip())
    except (TypeError, ValueError):
        raise ConfigError(
            f"{name}={raw.strip()!r} is not a number (default would have been "
            f"{default}). Fix the value — it is NOT being defaulted."
        ) from None
    _range(name, value, raw.strip(), lo, hi)
    return value


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
            qc_pass_score=_int("QC_PASS_SCORE", 85, lo=0, hi=100),
            qc_max_retries=_int("QC_MAX_RETRIES", 2, lo=0, hi=10),
            qc_confidence_escalate=_float("QC_CONFIDENCE_ESCALATE", 0.75, lo=0.0, hi=1.0),
            max_gen_cost_per_job_cents=_int("MAX_GEN_COST_PER_JOB_CENTS", 2500, lo=1, hi=1_000_000),
            fal_poll_interval_s=_float("FAL_POLL_INTERVAL_S", 3.0, lo=0.5, hi=60),
            fal_timeout_s=_int("FAL_TIMEOUT_S", 600, lo=10, hi=7200),
            anthropic_version=os.environ.get("ANTHROPIC_VERSION", "2023-06-01"),
        )


try:
    SETTINGS = Settings.from_env()
except ConfigError as _cfg_err:            # noqa: F841 — re-raised below
    # LOUD. A ConfigError (not SystemExit) so the worker's enhance_bridge, which
    # imports this module inside a try/except, degrades to "pipeline import
    # failed: …" and still ships the customer's base tour — while the worker's
    # own startup preflight has already refused to run with this .env at all.
    print(f"FATAL: bad AI-pipeline configuration: {_cfg_err}\n"
          f"       See services/pipeline/.env.example — the value is NOT defaulted.")
    raise


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


# Values that mean "leave the room as it is" — never a restage. The app sends
# "as_is" on every plain job (DesignStyle.asIs), so this must be recognised
# everywhere a style is read (audit F-G-02: any truthy string used to trigger a
# paid Gemini restage per room).
NO_RESTAGE_STYLES = frozenset({"", "as_is", "as-is", "asis", "none", "null", "original", "off"})


def normalize_style(raw: object) -> str | None:
    """Canonical restage style or None for "no restage".

    Raises ValueError for a non-empty style that is not in STYLES so callers can
    skip (worker) or refuse (CLI) instead of embedding an arbitrary string in a
    prompt that is then billed.
    """
    s = str(raw or "").strip().lower().replace(" ", "_")
    if s in NO_RESTAGE_STYLES:
        return None
    if s not in STYLES:
        raise ValueError(f"unknown restage style {raw!r}; expected one of {sorted(STYLES)} or as_is")
    return s


def style_prompt(style: str) -> str:
    """Full restage instruction for a named style, with the architecture lock.

    Only known styles are accepted — an unknown one used to be interpolated
    verbatim into the prompt ("Virtually restage this room in as_is style: as_is").
    """
    canon = normalize_style(style)
    if canon is None:
        raise ValueError("style_prompt() called for a no-restage style")
    return f"Virtually restage this room in {canon} style: {STYLES[canon]}. {ARCHITECTURE_LOCK}"
