#!/usr/bin/env python3
"""
Anthropic adapter — the QC "drift judge" + room understanding.

This is the gate that makes enhanced media trustworthy: it compares SOURCE vs
ENHANCED frames and returns a 0–100 **structural-consistency score** (plus
completeness/artifact axes, a verdict, and self-reported confidence). Haiku 4.5
by default; the router escalates to Sonnet 5 only when Haiku's confidence is low.

Cost control baked in:
  • NOT prompt-cached: the rubric is ~540 tokens and Haiku's minimum cacheable
    prefix is ~4096, so a `cache_control` marker on it was inert. It has been
    removed (audit F-G-19) — docs/AI-COST-MODEL.md §"−90% cached rubric" is
    therefore aspirational, not current behaviour.
  • Output is capped (max_tokens) because structured JSON output is ~5× input cost.
  • ACTUAL cost is recomputed from response.usage (input/output/cache tokens) via
    costs.qc_actual_cents — so the ledger stores real money, not an estimate.

CITATIONS:
  https://platform.claude.com/docs/en/build-with-claude/prompt-caching
  (Messages API: system as list of blocks w/ cache_control; image blocks
   source.type base64/url; usage fields cache_read_input_tokens etc.)
"""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass, field

from config import SETTINGS
from providers import costs
from providers.base import MissingKey, ProviderError, b64, request_json, sniff_mime

API_URL = "https://api.anthropic.com/v1/messages"
QC_MAX_OUTPUT_TOKENS = 400  # structured JSON only — keep output cost down

# The rubric. Static across every call, but NOT prompt-cached — see the module
# docstring: it is well under Haiku's minimum cacheable prefix.
SYSTEM_RUBRIC = """You are Rendprop's structural-consistency judge for real-estate media.

Rendprop enhances listing photos/video by removing clutter (declutter) and adding
virtual furniture/decor (restage). The single inviolable product+legal rule is:

  ARCHITECTURE NEVER CHANGES. Walls, windows, doors, doorframes, floors, ceilings,
  stairs, built-in fixtures, cabinetry, countertops, the camera angle/lens, the
  perspective, room dimensions, and the view through any window MUST be identical
  between SOURCE and ENHANCED. Only free-standing FURNITURE and DECOR may differ.
  Hiding or altering a property DEFECT is also a failure (misrepresentation).

You are given one or more SOURCE frames (the true room) and the corresponding
ENHANCED frames (after AI editing). Judge the ENHANCED frames against the SOURCE.

Score three axes, each 0–100:
  1. structure  — Are ALL architectural elements, geometry, perspective, and the
                  window view identical? Any moved/added/removed/warped architecture
                  scores below 50. This is the headline consistency score.
  2. completeness — Was the intended edit fully applied? (declutter: is the clutter
                  actually gone and the surface plausibly filled? restage: is the
                  target style present and coherent?)
  3. artifacts  — Free of warping, smears, melted edges, duplicated objects,
                  impossible geometry, ghosting, or other generative failures?

Also report:
  • confidence (0.0–1.0): how sure you are in this judgement. Lower it when frames
    are ambiguous, low-res, motion-blurred, or the change is hard to verify.
  • verdict: "pass"  → structure high, no defect-hiding, edit clean & complete.
             "regen" → recoverable (incomplete edit, minor artifacts) — worth a retry.
             "fail"  → architecture changed or a defect was hidden — never ship.
  • feedback: one specific, actionable instruction the next regeneration should follow.

Reply with ONLY a compact JSON object, no prose, exactly these keys:
{"structure": <int>, "completeness": <int>, "artifacts": <int>,
 "confidence": <float>, "verdict": "pass|regen|fail", "feedback": "<string>"}"""


@dataclass
class QCResult:
    score: int                 # headline = structural consistency (0–100)
    structure: int
    completeness: int
    artifacts: int
    confidence: float
    verdict: str               # pass | regen | fail
    feedback: str
    model: str
    usage: dict = field(default_factory=dict)
    cost_cents: float = 0.0
    escalated: bool = False


def _img_block(data: bytes) -> dict:
    return {
        "type": "image",
        "source": {"type": "base64", "media_type": sniff_mime(data), "data": b64(data)},
    }


def _parse(text: str) -> dict:
    start, end = text.find("{"), text.rfind("}")
    if start == -1 or end == -1:
        raise ProviderError(f"QC judge returned non-JSON: {text[:400]}")
    try:
        obj = json.loads(text[start:end + 1])
    except ValueError as e:
        raise ProviderError(f"QC judge returned malformed JSON ({e}): {text[:400]}") from e
    if not isinstance(obj, dict):
        raise ProviderError(f"QC judge returned {type(obj).__name__}, not an object")
    return obj


# ── defensive coercion (audit F-G-19) ────────────────────────────────────────
# A judge that replies `"structure": "92"`, `95.0`, `"n/a"` or omits a key used
# to raise ValueError deep inside the loop and kill the enhancement pass. Every
# field now coerces, and ANY coercion failure downgrades the verdict — the gate
# must fail toward "regen"/"fail", never toward shipping an unjudged edit.

class _Coerce:
    def __init__(self) -> None:
        self.clean = True

    def score(self, raw: object, default: int = 0) -> int:
        try:
            return max(0, min(100, int(float(raw))))   # type: ignore[arg-type]
        except (TypeError, ValueError):
            self.clean = False
            return default

    def confidence(self, raw: object) -> float:
        try:
            return max(0.0, min(1.0, float(raw)))      # type: ignore[arg-type]
        except (TypeError, ValueError):
            self.clean = False
            return 0.0        # unknown confidence → the router escalates

    def verdict(self, raw: object) -> str:
        v = str(raw or "").strip().lower()
        if v in ("pass", "regen", "fail"):
            return v
        self.clean = False
        return "regen"


def judge(
    source_frames: list[bytes],
    enhanced_frames: list[bytes],
    plan: dict | None = None,
    *,
    model: str | None = None,
) -> QCResult:
    """Compare SOURCE vs ENHANCED frames; return the drift-judge verdict.

    Up to a 4-image call (the cost model's unit). Cost is computed from the real
    token usage returned by the API.
    """
    if not SETTINGS.anthropic_api_key:
        raise MissingKey("ANTHROPIC_API_KEY is not set — cannot run QC.")
    model = model or SETTINGS.anthropic_model_qc

    content: list[dict] = [{
        "type": "text",
        "text": f"Edit plan for context: {json.dumps(plan or {})}\n\nSOURCE frame(s):",
    }]
    for f in source_frames:
        content.append(_img_block(f))
    content.append({"type": "text", "text": "ENHANCED frame(s) to judge:"})
    for f in enhanced_frames:
        content.append(_img_block(f))

    payload = {
        "model": model,
        "max_tokens": QC_MAX_OUTPUT_TOKENS,
        # NO cache_control: this rubric is ~540 tokens and Haiku's minimum
        # cacheable prefix is ~4096, so the marker never actually cached
        # anything — it just made the cost model claim a 90% discount that
        # never materialised (audit F-G-19). Padding 540 tokens up to 4096 to
        # save 90% of 540 would cost more than it saves. Re-add this only if the
        # rubric genuinely grows past the minimum.
        "system": [{"type": "text", "text": SYSTEM_RUBRIC}],
        "messages": [{"role": "user", "content": content}],
    }
    resp = request_json(API_URL, method="POST", payload=payload, headers={
        "x-api-key": SETTINGS.anthropic_api_key,
        "anthropic-version": SETTINGS.anthropic_version,
    }, timeout=120, retries=2)   # 429 / 529 overloaded only — never an ambiguous 5xx

    text = "".join(b.get("text", "") for b in resp.get("content", []))
    parsed = _parse(text)
    usage = resp.get("usage", {}) or {}
    c = _Coerce()
    structure = c.score(parsed.get("structure"))
    verdict = c.verdict(parsed.get("verdict"))
    feedback = str(parsed.get("feedback", "") or "")
    if not c.clean:
        # Something in the reply didn't parse. Never let that read as a pass.
        verdict = "regen" if verdict == "pass" else verdict
        feedback = (feedback + " (judge reply was partly unparseable; "
                    "treating as not-passed)").strip()
        print(f"    ⚠ QC judge reply had unparseable fields — verdict forced to "
              f"'{verdict}': {text[:200]}")
    return QCResult(
        score=structure,
        structure=structure,
        completeness=c.score(parsed.get("completeness")),
        artifacts=c.score(parsed.get("artifacts")),
        confidence=c.confidence(parsed.get("confidence")),
        verdict=verdict,
        feedback=feedback,
        model=model,
        usage=usage,
        cost_cents=costs.qc_actual_cents(model, usage),
    )


# ── Room understanding ────────────────────────────────────────────────────────

UNDERSTAND_RUBRIC = """You are Rendprop's room-understanding planner for real-estate media.
Given ONE room frame, identify the room and plan a safe enhancement. The
architecture (walls, windows, doors, floors, ceiling, fixtures, the window view)
is untouchable — plan to change FURNITURE and DECOR only, and never to hide a
property defect.

Reply with ONLY a compact JSON object, exactly these keys:
{"room_type": "<string>", "clutter_items": ["<removable clutter>", ...],
 "keep_identical": ["<architectural landmark to preserve>", ...],
 "notes": "<one short planning note>"}"""


@dataclass
class RoomPlan:
    room_type: str
    clutter_items: list
    keep_identical: list
    notes: str
    model: str
    usage: dict = field(default_factory=dict)
    cost_cents: float = 0.0


def understand_room(frame: bytes, *, model: str | None = None) -> RoomPlan:
    """Cheap Haiku pass: room type, clutter inventory, keep-list. Cached rubric."""
    if not SETTINGS.anthropic_api_key:
        raise MissingKey("ANTHROPIC_API_KEY is not set — cannot analyze room.")
    model = model or SETTINGS.anthropic_model_qc
    payload = {
        "model": model,
        "max_tokens": 300,
        "system": [{"type": "text", "text": UNDERSTAND_RUBRIC}],  # see note in judge()
        "messages": [{"role": "user", "content": [
            _img_block(frame),
            {"type": "text", "text": "Analyze this room frame."},
        ]}],
    }
    resp = request_json(API_URL, method="POST", payload=payload, headers={
        "x-api-key": SETTINGS.anthropic_api_key,
        "anthropic-version": SETTINGS.anthropic_version,
    }, timeout=120, retries=2)   # 429 / 529 overloaded only — never an ambiguous 5xx
    text = "".join(b.get("text", "") for b in resp.get("content", []))
    parsed = _parse(text)
    usage = resp.get("usage", {}) or {}
    def _as_list(raw: object) -> list:
        return list(raw) if isinstance(raw, (list, tuple)) else []

    return RoomPlan(
        room_type=str(parsed.get("room_type", "") or ""),
        clutter_items=_as_list(parsed.get("clutter_items")),
        keep_identical=_as_list(parsed.get("keep_identical")),
        notes=str(parsed.get("notes", "") or ""),
        model=model, usage=usage, cost_cents=costs.qc_actual_cents(model, usage),
    )
