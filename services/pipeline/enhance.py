#!/usr/bin/env python3
"""
Rendprop enhancement orchestrator — declutter + virtual restage + optional hero
clip, with a consistency-first closed loop and a hard per-job cost cap.

The "renders perfect every time" logic is a closed loop, not a single AI call:

    image or video in
      └─ 1. UNDERSTAND  (optional) Claude Haiku: room type + clutter + keep-list
      └─ 2. EDIT        declutter (masked inpaint → Flux Fill; architecture locked
                        by construction) then restage (Gemini "Nano Banana")
      └─ 3. JUDGE       Claude drift judge compares SOURCE vs ENHANCED:
                        structural-consistency score → pass / regen (capped) / fail
      └─ 4. FALLBACK    still failing after QC_MAX_RETRIES → ship the ORIGINAL
      └─ 5. HERO        (optional) animate the finished still into one hero clip
                        (Seedance i2v) — the corrected frame is the first frame,
                        so the video inherits the fixed room

    Hard rules enforced by the loop:
      • Architecture NEVER changes (walls/windows/doors/floors/views). Furniture
        & decor only. QC gates every result.
      • A failed segment ships as the ORIGINAL, never a bad edit.
      • MAX_GEN_COST_PER_JOB_CENTS is checked BEFORE every provider call (router)
        — the loop stops spending, never runs away.
      • Any active enhancement → the share page carries "Virtually staged".

Every provider call writes a cost_ledger row and rolls up render_jobs.cost_cents.
Masks (for masked-inpaint declutter) come from on-device segmentation upstream;
this component consumes a mask if given, else uses the prompt-edit declutter
fallback. Per-segment i2v stitching is the downstream render worker's job — here
`hero` is one marketing clip, matching the cost model.

Usage:
    python3 enhance.py room.jpg --declutter --style modern
    python3 enhance.py room.jpg --declutter --mask mask.png --style modern
    python3 enhance.py walkthrough.mp4 --declutter --style modern --hero
    python3 enhance.py walkthrough.mp4 --style scandinavian --chapters chapters.json
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

import router
from config import SETTINGS, STYLES, style_prompt
from cost_ledger import CostLedger
from providers import anthropic_qc
from providers.base import ProviderError
from router import BudgetExceeded, JobBudget, JobContext

HERO_MOTION = ("smooth steady walkthrough glide forward through the room, cinematic "
               "gimbal motion, keep the room geometry and architecture identical")


# ── per-frame closed loop (edit → judge → retry → fallback) ───────────────────

def _apply_edits(ctx: JobContext, source: bytes, declutter: bool, style: str | None,
                 mask: bytes | None, feedback: str) -> bytes:
    """Run the requested edits in order: declutter → restage. Returns bytes."""
    img = source
    if declutter:
        prompt = None
        if feedback:
            prompt = router.DECLUTTER_PROMPTEDIT + f" Fix from last attempt: {feedback}"
        img = router.declutter(ctx, img, mask, prompt=prompt).data
    if style:
        sp = style_prompt(style)
        if feedback:
            sp += f" Fix from last attempt: {feedback}"
        img = router.restage(ctx, img, sp).data
    return img


def enhance_frame(ctx: JobContext, source: bytes, declutter: bool, style: str | None,
                  *, mask: bytes | None = None, plan: dict | None = None) -> dict:
    """Edit a single frame, QC-gate it, regen up to the cap, else fall back."""
    last_qc = None
    feedback = ""
    for attempt in range(1 + SETTINGS.qc_max_retries):
        try:
            enhanced = _apply_edits(ctx, source, declutter, style, mask, feedback)
            last_qc = router.qc(ctx, [source], [enhanced], plan)
        except BudgetExceeded as e:
            print(f"    ⚠ {e}")
            return {"status": "fallback_original", "data": source, "reason": "budget"}
        print(f"    attempt {attempt + 1}: structure={last_qc.structure} "
              f"complete={last_qc.completeness} artifacts={last_qc.artifacts} "
              f"conf={last_qc.confidence:.2f} model={last_qc.model} → {last_qc.verdict}")
        if router.passes(last_qc):
            return {"status": "enhanced", "data": enhanced, "qc": last_qc}
        feedback = last_qc.feedback

    print("    ✗ QC never passed — segment ships as ORIGINAL (never a bad edit).")
    return {"status": "fallback_original", "data": source, "qc": last_qc}


def _maybe_analyze(ctx: JobContext, frame: bytes, analyze: bool) -> dict | None:
    if not analyze:
        return None
    try:
        rp = anthropic_qc.understand_room(frame)
        ctx.ledger.record(feature="qc", provider="anthropic", model=rp.model, units=1,
                          unit_cost_cents=rp.cost_cents, total_cents=rp.cost_cents,
                          job_id=ctx.job_id, org_id=ctx.org_id,
                          meta={"phase": "understand", "room_type": rp.room_type})
        ctx.budget.add(rp.cost_cents)
        return {"room_type": rp.room_type, "clutter_items": rp.clutter_items,
                "keep_identical": rp.keep_identical}
    except ProviderError as e:
        print(f"    ⚠ room understanding skipped: {e}")
        return None


# ── ffmpeg helpers (video mode) ───────────────────────────────────────────────

def _run(cmd: list) -> None:
    subprocess.run(cmd, check=True, capture_output=True)


def probe_duration(video: Path) -> float:
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                          "-of", "csv=p=0", str(video)], capture_output=True, text=True)
    return float(out.stdout.strip())


def extract_keyframe(video: Path, t: float, out: Path) -> Path:
    _run(["ffmpeg", "-y", "-ss", f"{t:.2f}", "-i", str(video),
          "-frames:v", "1", "-q:v", "2", str(out)])
    return out


def _safe_name(name, fallback: str) -> str:
    """Chapter/room labels are user-controlled and get used to build file paths
    (extract_keyframe writes ``workdir / f"{name}.jpg"``). Slugify to a bounded,
    separator-free token so a label like ``../../etc`` or an absolute path can't
    escape the workdir (path traversal / arbitrary write, worse because the
    worker container runs the pipeline)."""
    slug = re.sub(r"[^A-Za-z0-9_-]", "_", str(name)).strip("_")[:64]
    return slug or fallback


def segment_video(video: Path, chapters: list | None) -> list:
    """Room segments from chapter tags (the app records them), else 8s slices."""
    dur = probe_duration(video)
    if chapters:
        segs = []
        for i, c in enumerate(chapters):
            start = c["t"]
            end = chapters[i + 1]["t"] if i + 1 < len(chapters) else dur
            segs.append({"name": _safe_name(c.get("name"), f"segment-{i + 1}"), "start": start, "end": end})
        return segs
    return [{"name": f"segment-{i + 1}", "start": t, "end": min(t + 8, dur)}
            for i, t in enumerate(range(0, int(dur), 8))]


# ── orchestrators ─────────────────────────────────────────────────────────────

def new_context(job_id: str | None = None, org_id: str | None = None) -> JobContext:
    ctx = JobContext(job_id=job_id, org_id=org_id,
                     budget=JobBudget(SETTINGS.max_gen_cost_per_job_cents),
                     ledger=CostLedger())
    ctx.hydrate_budget()
    mode = "Supabase" if ctx.ledger.enabled else "local (no DB)"
    print(f"→ cost ledger: {mode}; cap ${SETTINGS.max_gen_cost_per_job_cents/100:.2f}; "
          f"already spent ${ctx.budget.spent_cents/100:.2f}")
    return ctx


def enhance_image(image_path: Path, declutter: bool, style: str | None, *,
                  mask_path: Path | None, hero: bool, hero_seconds: int, analyze: bool,
                  workdir: Path, job_id: str | None, org_id: str | None) -> dict:
    ctx = new_context(job_id, org_id)
    source = image_path.read_bytes()
    mask = mask_path.read_bytes() if mask_path else None
    plan = _maybe_analyze(ctx, source, analyze)

    out = enhance_frame(ctx, source, declutter, style, mask=mask, plan=plan)
    result_path = workdir / f"{image_path.stem}-enhanced.jpg"
    result_path.write_bytes(out["data"])
    manifest = _finish(ctx, [{"name": image_path.name, **_strip(out)}],
                       declutter, style, workdir)

    if hero and out["status"] == "enhanced":
        _make_hero(ctx, out["data"], hero_seconds, workdir, manifest)
        (workdir / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"  enhanced image → {result_path}")
    return manifest


def enhance_video(video: Path, declutter: bool, style: str | None, *,
                  chapters: list | None, hero: bool, hero_seconds: int, analyze: bool,
                  workdir: Path, job_id: str | None, org_id: str | None) -> dict:
    ctx = new_context(job_id, org_id)
    segments = segment_video(video, chapters)
    print(f"→ {len(segments)} room segments")
    results = []
    hero_frame: bytes | None = None
    for seg in segments:
        print(f"\n■ {seg['name']} ({seg['start']:.0f}s–{seg['end']:.0f}s)")
        mid = (seg["start"] + seg["end"]) / 2
        frame = extract_keyframe(video, mid, workdir / f"{seg['name']}.jpg")
        source = frame.read_bytes()
        plan = _maybe_analyze(ctx, source, analyze)
        out = enhance_frame(ctx, source, declutter, style, plan=plan)
        (workdir / f"{seg['name']}-enhanced.jpg").write_bytes(out["data"])
        if out["status"] == "enhanced" and hero_frame is None:
            hero_frame = out["data"]  # first good frame seeds the single hero clip
        results.append({**seg, **_strip(out)})

    manifest = _finish(ctx, results, declutter, style, workdir, video=str(video))
    if hero and hero_frame is not None:
        _make_hero(ctx, hero_frame, hero_seconds, workdir, manifest)
        (workdir / "manifest.json").write_text(json.dumps(manifest, indent=2))
    return manifest


def _make_hero(ctx: JobContext, frame: bytes, seconds: int, workdir: Path, manifest: dict) -> None:
    try:
        clip = router.hero_clip(ctx, frame, HERO_MOTION, seconds)
        (workdir / "hero.mp4").write_bytes(clip.data)
        manifest["hero_clip"] = str(workdir / "hero.mp4")
        manifest["spent_cents"] = ctx.budget.spent_cents
        print(f"  hero clip ({seconds}s) → {workdir / 'hero.mp4'}")
    except BudgetExceeded as e:
        print(f"  ⚠ hero skipped: {e}")
    except ProviderError as e:
        print(f"  ⚠ hero failed: {e}")


def _strip(out: dict) -> dict:
    """Drop raw bytes from a per-frame result before it goes in the manifest."""
    keep = {k: v for k, v in out.items() if k != "data"}
    if "qc" in keep and keep["qc"] is not None:
        q = keep["qc"]
        keep["qc"] = {"structure": q.structure, "completeness": q.completeness,
                      "artifacts": q.artifacts, "confidence": q.confidence,
                      "verdict": q.verdict, "model": q.model, "cost_cents": q.cost_cents}
    return keep


def _finish(ctx: JobContext, segments: list, declutter: bool, style: str | None,
            workdir: Path, video: str | None = None) -> dict:
    staged = any(s["status"] == "enhanced" for s in segments)
    manifest = {
        "video": video, "declutter": declutter, "style": style,
        "virtually_staged": staged,      # → mandatory "Virtually staged" disclosure
        "spent_cents": ctx.budget.spent_cents,
        "cost_cap_cents": ctx.budget.ceiling_cents,
        "ledger_rows": len(ctx.ledger.rows),
        "segments": segments,
    }
    (workdir / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"\n✓ Done. Spent ~${ctx.budget.spent_cents/100:.2f} "
          f"(cap ${ctx.budget.ceiling_cents/100:.2f}). Manifest: {workdir/'manifest.json'}")
    if staged:
        print("  NOTE: enhancements active → share page MUST show 'Virtually staged'.")
    return manifest


# ── CLI ───────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(description="Rendprop declutter/restage/hero orchestrator")
    ap.add_argument("input", help="room image, walkthrough video, or nothing for --help")
    ap.add_argument("--declutter", action="store_true")
    ap.add_argument("--style", choices=list(STYLES), default=None)
    ap.add_argument("--mask", help="declutter mask (white = clutter to remove); image mode")
    ap.add_argument("--hero", action="store_true", help="also generate one hero clip")
    ap.add_argument("--hero-seconds", type=int, default=5)
    ap.add_argument("--analyze", action="store_true", help="run Claude room understanding first")
    ap.add_argument("--chapters", help="JSON: [{\"name\":\"Kitchen\",\"t\":42.5}]")
    ap.add_argument("--workdir", default="out")
    ap.add_argument("--job-id", default=None, help="render_jobs.id for the cost ledger")
    ap.add_argument("--org-id", default=None, help="orgs.id for the cost ledger")
    args = ap.parse_args()

    if not (args.declutter or args.style):
        sys.exit("Pick at least one: --declutter and/or --style modern|rustic|minimalist|scandinavian")

    workdir = Path(args.workdir)
    workdir.mkdir(parents=True, exist_ok=True)
    inp = Path(args.input)

    if inp.suffix.lower() in (".jpg", ".jpeg", ".png", ".webp"):
        enhance_image(inp, args.declutter, args.style,
                      mask_path=Path(args.mask) if args.mask else None,
                      hero=args.hero, hero_seconds=args.hero_seconds, analyze=args.analyze,
                      workdir=workdir, job_id=args.job_id, org_id=args.org_id)
    else:
        chapters = json.loads(Path(args.chapters).read_text()) if args.chapters else None
        enhance_video(inp, args.declutter, args.style, chapters=chapters,
                      hero=args.hero, hero_seconds=args.hero_seconds, analyze=args.analyze,
                      workdir=workdir, job_id=args.job_id, org_id=args.org_id)


if __name__ == "__main__":
    main()
