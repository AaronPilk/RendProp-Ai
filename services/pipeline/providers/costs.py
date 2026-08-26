#!/usr/bin/env python3
"""
THE cost-config table — single source of truth for AI unit economics.

Frontier prices drop monthly. When they do, edit THIS FILE ONLY. Every estimate,
every pre-call budget check, and every cost_ledger row derives its numbers here.

All money is in **integer/decimal cents** to match the DB (`cost_ledger`,
`render_jobs.cost_cents`). Sources are the grounded figures in
docs/AI-COST-MODEL.md (late-2025/2026 vendor pricing):

  • Restage — Gemini 2.5 Flash Image ("Nano Banana"): 1290 output tok/img ×
    $30 / 1M tok = $0.0387 ≈ $0.039/img  (Google direct, cheapest route).
  • Restage fallback — Flux Kontext [pro] on fal: ~$0.04/img.
  • Restage at-scale / one-key fallback — KIE route: ~$0.09/img.
  • Declutter — Flux Fill/Kontext masked inpaint on fal: ~$0.04/img.
  • Hero clip — Seedance 1.0 Pro Fast (1080p i2v) on fal: ~$0.24 / 5s clip
    → 4.8¢/second (billed per second so 5–10s clips scale linearly).
  • QC drift judge — Claude Haiku 4.5 ~$0.009 / 4-image call; escalate to
    Sonnet 5 ~$0.017 / 4-image call. Actual cost is recomputed from returned
    token usage (see ANTHROPIC_RATES_CENTS_PER_1K) — these flats are only the
    conservative PRE-call estimate used by the budget gate.
"""

from __future__ import annotations

# ── Flat per-unit costs (cents) ───────────────────────────────────────────────
# Keys are stable logical names; values update as prices move.
UNIT_COSTS_CENTS: dict[str, float] = {
    # image generations — per image
    "restage_gemini":        3.9,   # Gemini 2.5 Flash Image (direct)
    "restage_fal_kontext":   4.0,   # Flux Kontext [pro] (fal fallback)
    "restage_kie":           9.0,   # KIE one-key route (at scale / fallback)
    "declutter_flux_fill":   4.0,   # Flux Fill masked inpaint (fal)
    "photo_edit_gemini":     3.9,   # twilight / sky replace / lawn repair (Gemini image edit)
    "upscale_realesrgan":    1.0,   # optional low-res upscale
    # video — per SECOND of generated/rendered clip
    "hero_seedance_per_s":   4.8,   # Seedance 1.0 Pro Fast 1080p ($0.24 / 5s)
    # "smooth drone" render — Topaz Video AI on fal, billed per SECOND of OUTPUT
    # (interpolate→hi-fps + upscale + denoise). fal: $0.02/s→1080p, $0.08/s>1080p,
    # ×2 for 60fps output. See docs research (Aug 2026).
    "drone_render_1080p60_per_s":  4.0,   # $0.04/s
    "drone_render_4k30_per_s":     8.0,   # $0.08/s
    "drone_render_4k60_per_s":    16.0,   # $0.16/s (premium buttery)
    # QC — flat per 4-image call (PRE-call estimate only)
    "qc_haiku_call":         0.9,
    "qc_sonnet_call":        1.7,
}

# Route name (config) → restage unit-cost key.
RESTAGE_ROUTE_COST = {
    "gemini": "restage_gemini",
    "fal":    "restage_fal_kontext",
    "kie":    "restage_kie",
}

# ── Anthropic token pricing (cents per 1,000 tokens) ──────────────────────────
# For ACTUAL post-call QC metering from response.usage. Mirrors platform pricing:
#   Haiku 4.5 : $1 in / $0.10 cache-read / $1.25 5m cache-write / $5 out  (per 1M)
#   Sonnet 5  : $2 in / $0.20 cache-read / $2.50 5m cache-write / $10 out (per 1M)
ANTHROPIC_RATES_CENTS_PER_1K: dict[str, dict[str, float]] = {
    "claude-haiku-4-5": {
        "input": 0.10, "cache_read": 0.01, "cache_write_5m": 0.125, "output": 0.50,
    },
    "claude-sonnet-5": {
        "input": 0.20, "cache_read": 0.02, "cache_write_5m": 0.25, "output": 1.00,
    },
}
# Safe default if an unrecognized model id is passed (treat as Haiku-class).
_DEFAULT_ANTHROPIC_RATE = ANTHROPIC_RATES_CENTS_PER_1K["claude-haiku-4-5"]


# ── Estimators (used by the router's budget gate + the CLI estimate cmd) ──────

def restage_cost_cents(route: str = "gemini") -> float:
    return UNIT_COSTS_CENTS[RESTAGE_ROUTE_COST.get(route, "restage_gemini")]


def declutter_cost_cents() -> float:
    return UNIT_COSTS_CENTS["declutter_flux_fill"]


def hero_cost_cents(seconds: float) -> float:
    return round(UNIT_COSTS_CENTS["hero_seedance_per_s"] * float(seconds), 4)


def photo_edit_cost_cents() -> float:
    """Twilight / sky-replace / lawn-repair — one Gemini image edit per photo."""
    return UNIT_COSTS_CENTS["photo_edit_gemini"]


# "Smooth drone" render tiers → per-output-second cost key.
DRONE_RENDER_TIERS = {
    "1080p60": "drone_render_1080p60_per_s",
    "4k30":    "drone_render_4k30_per_s",
    "4k60":    "drone_render_4k60_per_s",
}


def drone_render_cost_cents(out_seconds: float, tier: str = "4k30") -> float:
    """Topaz render cost = per-output-second rate × output duration."""
    key = DRONE_RENDER_TIERS.get(tier, "drone_render_4k30_per_s")
    return round(UNIT_COSTS_CENTS[key] * float(out_seconds), 4)


def qc_estimate_cents(model: str) -> float:
    """Conservative flat estimate for the pre-call budget check."""
    if "sonnet" in model:
        return UNIT_COSTS_CENTS["qc_sonnet_call"]
    return UNIT_COSTS_CENTS["qc_haiku_call"]


def qc_actual_cents(model: str, usage: dict) -> float:
    """Real QC cost from an Anthropic response.usage block.

    usage keys (any missing → 0): input_tokens, output_tokens,
    cache_read_input_tokens, cache_creation_input_tokens.
    """
    r = ANTHROPIC_RATES_CENTS_PER_1K.get(model, _DEFAULT_ANTHROPIC_RATE)
    inp = usage.get("input_tokens", 0) or 0
    out = usage.get("output_tokens", 0) or 0
    cread = usage.get("cache_read_input_tokens", 0) or 0
    cwrite = usage.get("cache_creation_input_tokens", 0) or 0
    cents = (
        inp * r["input"]
        + out * r["output"]
        + cread * r["cache_read"]
        + cwrite * r["cache_write_5m"]
    ) / 1000.0
    return round(cents, 6)


def estimate_job(
    *,
    rooms: int,
    declutter: bool,
    restage: bool,
    hero: bool,
    hero_seconds: float = 5.0,
    restage_route: str = "gemini",
    qc_model: str = "claude-haiku-4-5",
    qc_per_enhanced_room: bool = True,
) -> dict:
    """Projected cost breakdown for a whole listing — powers `cli.py estimate`.

    QC is charged once per enhanced room (declutter and restage share one drift
    check on the final frame, matching the orchestrator loop).
    """
    lines: list[dict] = []

    def add(feature: str, units: float, unit_cents: float) -> None:
        lines.append({
            "feature": feature,
            "units": round(units, 4),
            "unit_cost_cents": round(unit_cents, 6),
            "total_cents": round(units * unit_cents, 4),
        })

    if declutter:
        add("declutter", rooms, declutter_cost_cents())
    if restage:
        add("restage", rooms, restage_cost_cents(restage_route))
    if hero:
        add("hero", hero_seconds, UNIT_COSTS_CENTS["hero_seedance_per_s"])
    if qc_per_enhanced_room and (declutter or restage):
        add("qc", rooms, qc_estimate_cents(qc_model))

    total = round(sum(l["total_cents"] for l in lines), 4)
    return {"lines": lines, "total_cents": total, "rooms": rooms}
