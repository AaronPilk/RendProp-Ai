#!/usr/bin/env python3
"""
Router — consistency-first, cost-aware provider selection with the hard per-job
cost cap enforced BEFORE every provider call.

Policy (from docs/AI-COST-MODEL.md §2):
  1. Deterministic-first — base "pro look" is on-device/free; the router is only
     ever invoked for PAID add-ons (declutter/restage) and the optional hero clip.
     There is no code path here that touches the base render.
  2. Masked inpaint for declutter — architecture preserved by construction.
  3. Restage via the cheapest structure-preserving route (Gemini direct), with an
     automatic one-tap fallback to Flux Kontext on fal if the primary errors.
  4. Model tiering for QC — Haiku by default, escalate to Sonnet ONLY when Haiku's
     confidence is low. Never Opus for QC.
  5. Hard per-job cost cap — every call is metered *before* it runs. We estimate
     the call's cost from providers/costs.py, check the running job total against
     MAX_GEN_COST_PER_JOB_CENTS, and abort (raise BudgetExceeded) if it would go
     over. Nothing is charged on an aborted call.

The router estimates → enforces → calls the provider → writes the cost_ledger row
→ updates the running budget. enhance.py orchestrates the room loop on top.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable

from config import ARCHITECTURE_LOCK, SETTINGS
from cost_ledger import CostLedger, LedgerError
from providers import anthropic_qc, costs, fal_client as fal, gemini
from providers.anthropic_qc import QCResult
from providers.base import ProviderError, ProviderResult

DECLUTTER_PROMPTEDIT = (
    "Remove all clutter, mess, boxes, cords, cables, laundry, dishes, and personal "
    "items so the room looks clean and tidy. Keep everything else identical. "
    + ARCHITECTURE_LOCK
)


# ── Budget guard ──────────────────────────────────────────────────────────────

class BudgetExceeded(Exception):
    """MAX_GEN_COST_PER_JOB_CENTS would be exceeded — raised before the call."""


class LedgerUnavailable(BudgetExceeded):
    """The cost ledger could not record earlier spend, so we stop spending.

    Deliberately a BudgetExceeded: `enhance.enhance_frame` already treats that as
    "abort this segment, ship the ORIGINAL" — exactly the right behaviour. Money
    we cannot account for is money we do not spend (audit F-G-07).
    """


@dataclass
class JobBudget:
    ceiling_cents: int = SETTINGS.max_gen_cost_per_job_cents
    spent_cents: float = 0.0

    def precheck(self, feature: str, estimate_cents: float) -> None:
        """Abort BEFORE a provider call if it would breach the per-job ceiling."""
        projected = round(self.spent_cents + estimate_cents, 4)
        if projected > self.ceiling_cents:
            raise BudgetExceeded(
                f"cost cap: '{feature}' (+{estimate_cents:.3f}¢) would bring job to "
                f"${projected/100:.2f} > MAX_GEN_COST_PER_JOB_CENTS "
                f"${self.ceiling_cents/100:.2f}. Aborting before the call; "
                f"segment ships as original."
            )

    def add(self, cents: float) -> None:
        self.spent_cents = round(self.spent_cents + cents, 4)

    @property
    def remaining_cents(self) -> float:
        return round(self.ceiling_cents - self.spent_cents, 4)


@dataclass
class JobContext:
    """Everything a routed call needs: identity, budget, ledger, route config."""
    job_id: str | None = None
    org_id: str | None = None
    budget: JobBudget = field(default_factory=JobBudget)
    ledger: CostLedger = field(default_factory=CostLedger)
    restage_route: str = SETTINGS.restage_route

    def hydrate_budget(self) -> None:
        """Seed spent_cents from the DB so restarts respect prior spend."""
        if self.job_id and self.ledger.enabled:
            self.budget.spent_cents = self.ledger.job_total_cents(self.job_id)


# ── Metering wrapper ──────────────────────────────────────────────────────────

def _guard_ledger(ctx: JobContext, feature: str) -> None:
    """Refuse to spend while the ledger is known-unrecordable (audit F-G-07)."""
    if getattr(ctx.ledger, "degraded", False):
        raise LedgerUnavailable(
            f"cost ledger is degraded ({ctx.ledger.spooled_rows} row(s) spooled) — "
            f"refusing to run a paid '{feature}' call we could not record. "
            f"Segment ships as original."
        )


def _meter(ctx: JobContext, feature: str, estimate_cents: float,
           produce: Callable[[], ProviderResult]) -> ProviderResult:
    """ledger guard → precheck (cap) → provider → ledger → budget → return.

    If the ledger fails AFTER a successful provider call, we keep the result (it
    has been paid for and the row is durably spooled) and let the latched
    `degraded` flag stop the NEXT call. Throwing the media away would waste the
    money twice.
    """
    _guard_ledger(ctx, feature)
    ctx.budget.precheck(feature, estimate_cents)          # may raise BudgetExceeded
    result = produce()                                    # the actual provider call
    try:
        ctx.ledger.record(
            feature=result.feature or feature, provider=result.provider, model=result.model,
            units=result.units, unit_cost_cents=result.unit_cost_cents,
            total_cents=result.total_cents, job_id=ctx.job_id, org_id=ctx.org_id, meta=result.meta,
        )
    except LedgerError as e:
        print(f"    ⚠ {e}")
    ctx.budget.add(result.total_cents)   # count it either way — it was spent
    return result


# ── Declutter (masked inpaint) ────────────────────────────────────────────────

def declutter(ctx: JobContext, image: bytes, mask: bytes | None = None, *,
              prompt: str | None = None) -> ProviderResult:
    """Declutter a room.

    Primary (safe): Flux Fill **masked inpaint** — everything outside the mask is
    mathematically untouched, so walls/windows can't move. Masks come from
    on-device segmentation (SAM-2 class) upstream — this component consumes them.

    Fallback (no mask): a prompt-only Nano Banana edit ("remove clutter, keep the
    room identical"), per the cost model. Architecture preservation is then only
    statistical — the QC drift judge still gates it.
    """
    if mask is not None:
        est = costs.declutter_cost_cents()
        return _meter(ctx, "declutter", est, lambda: fal.declutter_result(image, mask, prompt=prompt))

    est = costs.restage_cost_cents("gemini")  # same per-image cost class

    def produce() -> ProviderResult:
        pr = gemini.restage_result(image, prompt or DECLUTTER_PROMPTEDIT)
        pr.feature = "declutter"
        pr.meta = {**pr.meta, "masked_inpaint": False, "fallback": "gemini_prompt_edit"}
        return pr

    return _meter(ctx, "declutter", est, produce)


# ── Restage (Gemini primary, Kontext fallback) ────────────────────────────────

def _restage_primary(route: str, image: bytes, style_prompt: str) -> ProviderResult:
    if route == "gemini":
        return gemini.restage_result(image, style_prompt)
    if route == "fal":
        return fal.restage_fallback_result(image, style_prompt)
    if route == "kie":
        # KIE is the optional one-key multi-model fallback. Not wired here — raise
        # so the caller's fallback path picks up fal Kontext. Set RESTAGE_ROUTE to
        # gemini|fal to select a primary that's implemented.
        raise ProviderError("KIE restage route not implemented; use gemini|fal.")
    raise ProviderError(f"Unknown restage route '{route}'.")


def restage(ctx: JobContext, image: bytes, style_prompt: str, *, allow_fallback: bool = True) -> ProviderResult:
    """Restage via the configured route; auto-fallback to Flux Kontext on error."""
    route = ctx.restage_route
    try:
        est = costs.restage_cost_cents(route)
        return _meter(ctx, "restage", est, lambda: _restage_primary(route, image, style_prompt))
    except BudgetExceeded:
        raise  # cap breaches never silently fall back — they abort
    except ProviderError as e:
        if not allow_fallback or route == "fal":
            raise
        print(f"    ↪ restage[{route}] failed ({e}); falling back to fal Kontext")
        est = costs.restage_cost_cents("fal")
        return _meter(ctx, "restage", est, lambda: fal.restage_fallback_result(image, style_prompt))


# ── Hero clip ─────────────────────────────────────────────────────────────────

def hero_clip(ctx: JobContext, first_frame: bytes, prompt: str, seconds: int = 5) -> ProviderResult:
    """Animate the finished still into a hero clip (Seedance i2v)."""
    dur = max(2, min(12, int(round(seconds))))
    est = costs.hero_cost_cents(dur)
    return _meter(ctx, "hero", est, lambda: fal.hero_clip_result(first_frame, prompt, dur))


# ── Photo edits (twilight / sky replace / lawn repair) — Gemini image edit ────

PHOTO_EDIT_PROMPTS = {
    "twilight": (
        "Convert this daytime exterior real-estate photo into a stunning twilight/dusk shot: "
        "deep blue-to-warm-orange gradient sky, warm glowing interior window lights, subtle "
        "landscape/path lighting, professional dusk real-estate photography. Keep the house "
        "architecture, structure, landscaping, driveway, and composition EXACTLY the same — only "
        "change the sky and lighting. " + ARCHITECTURE_LOCK
    ),
    "sky": (
        "Replace the dull, grey, or overcast sky in this real-estate photo with a bright, clear "
        "blue sky with soft natural clouds. Keep the house, trees, and ground exactly the same and "
        "match the lighting, shadows, and reflections naturally. " + ARCHITECTURE_LOCK
    ),
    "lawn": (
        "Repair and green the lawn in this real-estate photo: lush, healthy, vibrant green grass; "
        "remove brown/dead patches, dirt, and weeds. Keep the house, hardscape, driveway, plants, "
        "and everything else identical. " + ARCHITECTURE_LOCK
    ),
}


def photo_edit(ctx: JobContext, image: bytes, edit: str) -> ProviderResult:
    """Single-image real-estate edit (twilight | sky | lawn) via Gemini image edit."""
    prompt = PHOTO_EDIT_PROMPTS.get(edit)
    if not prompt:
        raise ProviderError(f"Unknown photo edit '{edit}' (twilight|sky|lawn).")
    est = costs.photo_edit_cost_cents()

    def produce() -> ProviderResult:
        pr = gemini.restage_result(image, prompt)   # generic Gemini image edit
        pr.feature = "photo_edit"
        pr.meta = {**pr.meta, "edit": edit}
        return pr

    return _meter(ctx, "photo_edit", est, produce)


# ── "Smooth drone" render (Topaz Video AI on fal) ─────────────────────────────

def drone_render(ctx: JobContext, video: bytes, *, out_seconds: float, tier: str = "4k30",
                 model: str = "Proteus", upscale_factor: int = 2, target_fps: int = 60,
                 video_url: str | None = None) -> ProviderResult:
    """Interpolate → hi-fps + upscale → 4K + denoise: the cinematic drone glide."""
    est = costs.drone_render_cost_cents(out_seconds, tier)
    return _meter(ctx, "drone_render", est, lambda: fal.drone_render_result(
        video, out_seconds=out_seconds, tier=tier, model=model,
        upscale_factor=upscale_factor, target_fps=target_fps, video_url=video_url))


# ── QC drift judge (Haiku → Sonnet tiering) ───────────────────────────────────

def _record_qc(ctx: JobContext, r: QCResult, image_count: int) -> None:
    unit = round(r.cost_cents / image_count, 6) if image_count else r.cost_cents
    try:
        ctx.ledger.record(
            feature="qc", provider="anthropic", model=r.model, units=image_count,
            unit_cost_cents=unit, total_cents=r.cost_cents, job_id=ctx.job_id, org_id=ctx.org_id,
            meta={"structure": r.structure, "completeness": r.completeness, "artifacts": r.artifacts,
                  "confidence": r.confidence, "verdict": r.verdict, "escalated": r.escalated},
        )
    except LedgerError as e:
        print(f"    ⚠ {e}")
    ctx.budget.add(r.cost_cents)      # the judge call happened; it counts


def qc(ctx: JobContext, source_frames: list[bytes], enhanced_frames: list[bytes],
       plan: dict | None = None) -> QCResult:
    """Drift-judge SOURCE vs ENHANCED. Haiku first; escalate to Sonnet if unsure.

    Budget is enforced (flat estimate) before EACH model call; the ledger records
    the ACTUAL token-based cost after each call.
    """
    image_count = len(source_frames) + len(enhanced_frames)

    # Tier 1 — Haiku (the cheap judge; the rubric is too short to prompt-cache).
    _guard_ledger(ctx, "qc")
    ctx.budget.precheck("qc", costs.qc_estimate_cents(SETTINGS.anthropic_model_qc))
    result = anthropic_qc.judge(source_frames, enhanced_frames, plan,
                                model=SETTINGS.anthropic_model_qc)
    _record_qc(ctx, result, image_count)

    # Tier 2 — escalate to Sonnet ONLY when Haiku's confidence is low.
    if result.confidence < SETTINGS.qc_confidence_escalate:
        try:
            _guard_ledger(ctx, "qc-escalate")
            ctx.budget.precheck("qc", costs.qc_estimate_cents(SETTINGS.anthropic_model_escalate))
            escalated = anthropic_qc.judge(source_frames, enhanced_frames, plan,
                                           model=SETTINGS.anthropic_model_escalate)
            escalated.escalated = True
            _record_qc(ctx, escalated, image_count)
            return escalated
        except BudgetExceeded as e:
            # Out of budget to escalate — keep Haiku's (lower-confidence) verdict.
            print(f"    ⚠ QC escalation skipped: {e}")
    return result


def passes(result: QCResult) -> bool:
    """Gate: structural consistency clears the bar AND the judge says pass."""
    return result.verdict == "pass" and result.score >= SETTINGS.qc_pass_score
