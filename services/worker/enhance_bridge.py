#!/usr/bin/env python3
"""
Bridge from the render worker to the existing AI-enhancement pipeline
(services/pipeline): declutter / restage / hero, with the pipeline's own
consistency-first closed loop, provider routing, QC drift-judge, and — crucially
— its per-call cost metering. We DON'T re-implement any of that; we call it.

Two glue jobs:
  1. Make the pipeline importable: it uses top-level imports (`import router`,
     `from config import ...`), so we append its dir to sys.path. Worker modules
     keep priority (they're on sys.path[0]); none share a name with the pipeline.
  2. Route the pipeline's cost_ledger writes to the worker's schema
     (`SETTINGS.db_schema`, `public` on the dedicated project). The pipeline's
     CostLedger targets PostgREST without a schema profile; we monkeypatch its
     `_headers()` — the single Supabase-touching method — to add
     `Accept-Profile`/`Content-Profile`. Contained to this process; the pipeline
     files are untouched on disk.

Style normalisation (audit F-G-02): the app sends `style:"as_is"` on EVERY plain
job. Any of as_is / as-is / asis / none / "" means "no restage" and must never
reach the pipeline; an unknown style is skipped with a reason rather than being
interpolated into a paid prompt. `wants_enhancement()` is the single predicate
the worker uses to decide whether to call the pipeline at all.

Design choice (product): the base scrubbable tour is the core deliverable. AI
add-ons are exactly that — add-ons. If enhancement can't run (missing provider
keys) or crashes, we DON'T fail the whole render; we log a reason, publish the
base tour, and surface the reason on the job. A paid add-on that silently no-ops
is a billing/QA signal, not a reason to lose the customer's tour.

Enhanced STILLS (one per room) + an optional hero clip are the pipeline's output
(it enhances keyframes, not a re-encoded walkthrough — matching the cost model).
The worker persists them; `staged` on the render is driven by whether any segment
actually enhanced (→ mandatory "Virtually staged" disclosure).
"""

from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass, field
from pathlib import Path

from settings import SETTINGS

# Mirrors services/pipeline/config.py (NO_RESTAGE_STYLES / STYLES). Kept local so
# the worker can normalise BEFORE importing the pipeline (which may be absent).
NO_RESTAGE_STYLES = frozenset({"", "as_is", "as-is", "asis", "none", "null", "original", "off"})
KNOWN_STYLES = frozenset({"modern", "rustic", "minimalist", "scandinavian"})


def normalize_style(raw: object) -> tuple[str | None, str | None]:
    """→ (style, problem). style None = no restage. problem set = unknown style."""
    s = str(raw or "").strip().lower().replace(" ", "_")
    if s in NO_RESTAGE_STYLES:
        return None, None
    known = KNOWN_STYLES
    try:  # prefer the pipeline's authoritative list when importable
        pdir = SETTINGS.pipeline_dir
        if pdir not in sys.path:
            sys.path.append(pdir)
        from config import STYLES as _pl_styles  # type: ignore
        known = frozenset(_pl_styles)
    except Exception:  # noqa: BLE001 — fall back to the local mirror
        pass
    if s not in known:
        return None, f"unknown style {raw!r} (expected one of {sorted(known)} or as_is)"
    return s, None


def wants_enhancement(enhancements: dict | None) -> bool:
    """True when the job asks for declutter / a restage style / a hero clip.

    A no-restage style (`as_is`…) alone → False (nothing to run, nothing to
    bill). An UNKNOWN style still returns True so run_enhancement() can record
    the "skipped: unknown style" reason instead of silently ignoring it.
    """
    e = enhancements or {}
    style, problem = normalize_style(e.get("style"))
    return bool(e.get("declutter")) or style is not None or problem is not None or bool(e.get("hero"))


@dataclass
class EnhancedStill:
    room: str
    source_path: str      # extracted keyframe (the "before")
    enhanced_path: str     # the AI-enhanced "after"


@dataclass
class EnhanceResult:
    ran: bool = False
    staged: bool = False
    reason: str = ""
    spent_cents: float = 0.0
    stills: list[EnhancedStill] = field(default_factory=list)
    hero_path: str | None = None
    manifest: dict = field(default_factory=dict)


def _missing_keys(declutter: bool, style: str | None, hero: bool, route: str) -> list[str]:
    """Which required provider keys are absent for the requested enhancements."""
    need: set[str] = set()
    edits = declutter or bool(style)
    if edits:
        need.add("ANTHROPIC_API_KEY")                 # QC drift-judge runs on every edit
        if declutter or route == "gemini":
            need.add("GEMINI_API_KEY")                # prompt-edit declutter + gemini restage
        if route == "fal":
            need.add("FAL_KEY")
    if hero:
        need.add("FAL_KEY")                           # Seedance i2v
    return [k for k in sorted(need) if not os.environ.get(k)]


def _map_chapters(db_chapters: list) -> list | None:
    """capture_chapters [{label,t_ms}] → pipeline segments [{name, t(seconds)}]."""
    if not db_chapters:
        return None
    out = []
    for c in db_chapters:
        try:
            out.append({"name": c.get("label") or "Room", "t": float(c["t_ms"]) / 1000.0})
        except (KeyError, TypeError, ValueError):
            continue
    return out or None


def run_enhancement(
    *,
    input_video: str,
    workdir: str,
    enhancements: dict,
    db_chapters: list,
    job_id: str | None,
    org_id: str | None,
) -> EnhanceResult:
    """Run the pipeline over the raw walkthrough. Never raises — returns a result."""
    declutter = bool(enhancements.get("declutter"))
    # Normalise FIRST: "as_is" (what the app sends on every plain job) is not a
    # restage request, and an unknown style is a skip, never a paid prompt.
    style, style_problem = normalize_style(enhancements.get("style"))
    if style_problem:
        return EnhanceResult(ran=False, reason=f"skipped: {style_problem}")
    hero = bool(enhancements.get("hero"))
    analyze = bool(enhancements.get("analyze"))
    route = os.environ.get("RESTAGE_ROUTE", "gemini")

    if not (declutter or style or hero):
        return EnhanceResult(ran=False, reason="no enhancements requested")

    missing = _missing_keys(declutter, style, hero, route)
    if missing:
        return EnhanceResult(ran=False, reason=f"skipped: missing provider keys {missing}")

    # ── make the pipeline importable + reroute its ledger to `rendprop` ──
    try:
        pdir = SETTINGS.pipeline_dir
        if pdir not in sys.path:
            sys.path.append(pdir)
        import cost_ledger as pl_ledger  # pipeline module

        if not getattr(pl_ledger.CostLedger, "_rendprop_patched", False):
            _orig = pl_ledger.CostLedger._headers

            def _profiled(self, prefer: str = "return=representation", _orig=_orig):
                h = _orig(self, prefer)
                h["Accept-Profile"] = SETTINGS.db_schema
                h["Content-Profile"] = SETTINGS.db_schema
                return h

            pl_ledger.CostLedger._headers = _profiled
            pl_ledger.CostLedger._rendprop_patched = True

        import enhance as pl_enhance  # noqa: WPS433 (lazy on purpose)
    except Exception as e:  # noqa: BLE001 — import/config problems shouldn't kill the tour
        return EnhanceResult(ran=False, reason=f"pipeline import failed: {e}")

    enh_dir = os.path.join(workdir, "enhance")
    os.makedirs(enh_dir, exist_ok=True)
    chapters = _map_chapters(db_chapters)

    reason = "ok"
    try:
        manifest = pl_enhance.enhance_video(
            Path(input_video), declutter, style,
            chapters=chapters, hero=hero, hero_seconds=SETTINGS.hero_seconds,
            analyze=analyze, workdir=Path(enh_dir), job_id=job_id, org_id=org_id,
        )
    except Exception as e:  # noqa: BLE001 — provider/QC failure → ship base tour
        # The pipeline now isolates per-segment failures, so an exception here
        # is something outside the loop (context setup, disk, hero). Segments
        # that already passed QC were PAID for — harvest them from the manifest
        # the pipeline writes as it goes rather than discarding them (F-G-08).
        manifest = _read_manifest(enh_dir)
        if manifest is None:
            return EnhanceResult(ran=False, reason=f"enhancement error: {e}")
        reason = f"partial: {e}"

    # Collect the enhanced stills that actually passed QC (status == "enhanced").
    stills: list[EnhancedStill] = []
    errors = 0
    for seg in manifest.get("segments", []):
        if seg.get("status") == "error":
            errors += 1
        if seg.get("status") != "enhanced":
            continue
        name = seg.get("name", "room")
        enhanced = os.path.join(enh_dir, f"{name}-enhanced.jpg")
        source = os.path.join(enh_dir, f"{name}.jpg")
        if os.path.exists(enhanced):
            stills.append(EnhancedStill(
                room=name, enhanced_path=enhanced,
                source_path=source if os.path.exists(source) else "",
            ))
    if errors and reason == "ok":
        reason = f"ok ({errors} segment(s) failed and shipped as original)"

    hero_path = manifest.get("hero_clip")
    if hero_path and not os.path.exists(hero_path):
        hero_path = None

    return EnhanceResult(
        ran=True,
        staged=bool(manifest.get("virtually_staged")) and bool(stills),
        reason=reason,
        spent_cents=float(manifest.get("spent_cents", 0) or 0),
        stills=stills,
        hero_path=hero_path,
        manifest=manifest,
    )


def _read_manifest(enh_dir: str) -> dict | None:
    """The pipeline's manifest.json, if it got far enough to write one."""
    path = os.path.join(enh_dir, "manifest.json")
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None
