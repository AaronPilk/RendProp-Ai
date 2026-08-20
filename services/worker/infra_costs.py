#!/usr/bin/env python3
"""
Infra cost table for the render worker — the non-AI half of the ledger.

The AI unit economics (declutter/restage/hero/qc) live in the pipeline's
`providers/costs.py` and are metered there when the worker calls the pipeline.
This file covers the two things the *worker itself* is responsible for:

  • render   — server-side encode compute (the ffmpeg pass). The base render is
               FREE on-device; the server path exists for 4K/AI/Stream hosting,
               so this is real GPU/CPU time on the worker host (Modal / Cloud
               Run / container). No public vendor "per render" number exists, so
               it's a configurable per-output-minute estimate — override
               RENDER_COMPUTE_CENTS_PER_MIN once you have real infra bills.
  • stream_store — Cloudflare Stream STORAGE at $0.005 / stored minute
               (AI-COST-MODEL.md §3 → 0.5¢/min). Logged once at publish as the
               first month's storage unit. (Delivery — $0.001/min watched — is
               metered per view by the beacon/metering path, NOT here.)

Money is in cents to match the DB (`cost_ledger`, `render_jobs.cost_cents`).
Numbers are read from SETTINGS so they're env-overridable in one spot.
"""

from __future__ import annotations

from dataclasses import dataclass

from settings import SETTINGS


@dataclass
class CostLine:
    feature: str          # cost_ledger.feature: render | stream_store
    provider: str         # cost_ledger.provider
    model: str            # cost_ledger.model (free text)
    units: float          # minutes
    unit_cost_cents: float
    total_cents: float
    meta: dict


def _minutes(seconds: float) -> float:
    return round(max(0.0, float(seconds)) / 60.0, 4)


def render_line(duration_s: float, *, preset: str, bitrate: str) -> CostLine:
    """Server encode compute for one render, priced per output minute."""
    minutes = _minutes(duration_s)
    unit = SETTINGS.render_compute_cents_per_min
    return CostLine(
        feature="render",
        provider=SETTINGS.render_compute_provider,
        model=f"ffmpeg-h264-allintra:{preset}@{bitrate}",
        units=minutes,
        unit_cost_cents=round(unit, 6),
        total_cents=round(minutes * unit, 4),
        meta={
            "kind": "server_encode_compute",
            "note": "configurable estimate; set RENDER_COMPUTE_CENTS_PER_MIN from real infra bills",
            "duration_s": round(float(duration_s), 2),
        },
    )


def stream_store_line(duration_s: float, *, stream_uid: str | None) -> CostLine:
    """Cloudflare Stream storage for one published render (first month)."""
    minutes = _minutes(duration_s)
    unit = SETTINGS.stream_store_cents_per_min
    return CostLine(
        feature="stream_store",
        provider="cloudflare",
        model="stream",
        units=minutes,
        unit_cost_cents=round(unit, 6),
        total_cents=round(minutes * unit, 4),
        meta={
            "kind": "stream_storage_per_month",
            "note": "recurs monthly; logged once at publish. Delivery metered per-view elsewhere.",
            "stream_uid": stream_uid,
            "duration_s": round(float(duration_s), 2),
        },
    )
