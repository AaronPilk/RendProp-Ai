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
import os
import re
import subprocess
import sys
from pathlib import Path

import router
from config import SETTINGS, STYLES, style_prompt
from cost_ledger import CostLedger
from providers import anthropic_qc, costs
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


def _attempt_estimate_cents(ctx: JobContext, declutter: bool, style: str | None) -> float:
    """What ONE full attempt costs: every edit PLUS the QC that must judge it.

    Prechecking per call meant an edit could be paid for and then discarded
    because the *QC* precheck tipped over the cap — money spent for nothing
    (audit F-G-20). The bundle is checked once, up front, so an attempt is either
    fully affordable or never started.
    """
    est = 0.0
    if declutter:
        est += costs.declutter_cost_cents()
    if style:
        est += costs.restage_cost_cents(ctx.restage_route)
    est += costs.qc_estimate_cents(SETTINGS.anthropic_model_qc)
    return round(est, 4)


def enhance_frame(ctx: JobContext, source: bytes, declutter: bool, style: str | None,
                  *, mask: bytes | None = None, plan: dict | None = None) -> dict:
    """Edit a single frame, QC-gate it, regen up to the cap, else fall back."""
    last_qc = None
    feedback = ""
    bundle = _attempt_estimate_cents(ctx, declutter, style)
    for attempt in range(1 + SETTINGS.qc_max_retries):
        try:
            # Whole-attempt affordability check BEFORE the first paid call.
            ctx.budget.precheck("attempt", bundle)
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
    """Optional Claude room-understanding pass.

    It is a PAID Anthropic call, so it goes through the same gates as every other
    one: the ledger-degraded guard and a budget precheck (audit F-G-20 — this
    call used to reach Anthropic with no precheck at all). Its cost is added to
    the budget even if the ledger write itself failed: the money was spent.
    """
    if not analyze:
        return None
    try:
        router._guard_ledger(ctx, "qc-understand")
        ctx.budget.precheck("qc", costs.qc_estimate_cents(SETTINGS.anthropic_model_qc))
        rp = anthropic_qc.understand_room(frame)
    except BudgetExceeded as e:
        print(f"    ⚠ room understanding skipped: {e}")
        return None
    except ProviderError as e:
        print(f"    ⚠ room understanding skipped: {e}")
        return None
    try:
        ctx.ledger.record(feature="qc", provider="anthropic", model=rp.model, units=1,
                          unit_cost_cents=rp.cost_cents, total_cents=rp.cost_cents,
                          job_id=ctx.job_id, org_id=ctx.org_id,
                          meta={"phase": "understand", "room_type": rp.room_type})
    except ProviderError as e:      # includes LedgerError — row is spooled
        print(f"    ⚠ {e}")
    ctx.budget.add(rp.cost_cents)
    return {"room_type": rp.room_type, "clutter_items": rp.clutter_items,
            "keep_identical": rp.keep_identical}


# ── ffmpeg helpers (video mode) ───────────────────────────────────────────────
# Every subprocess here carries a wall-clock timeout: the input is
# customer-uploaded media, and a stuck demuxer used to block the worker forever.

FFPROBE_TIMEOUT_S = int(os.environ.get("FFPROBE_TIMEOUT_S", "60"))
KEYFRAME_TIMEOUT_S = int(os.environ.get("FFMPEG_KEYFRAME_TIMEOUT_S", "120"))
FFMPEG_BIN = os.environ.get("FFMPEG_BIN", "ffmpeg")
FFPROBE_BIN = os.environ.get("FFPROBE_BIN", "ffprobe")

# Providers cap image size (Anthropic: 5 MB / ~1568 px is the useful max); a
# 4K keyframe is wasted tokens. Long edge for extracted keyframes.
KEYFRAME_LONG_EDGE = int(os.environ.get("KEYFRAME_LONG_EDGE", "1568"))

_HDR_TRANSFERS = {"smpte2084", "arib-std-b67"}
_ZSCALE_TRANSFER = {"smpte2084": "smpte2084", "arib-std-b67": "arib-std-b67"}
_ZSCALE_PRIMARIES = {"bt2020": "2020", "bt709": "709"}
_ZSCALE_MATRIX = {"bt2020nc": "2020_ncl", "bt2020c": "2020_cl", "bt709": "709"}


def _run(cmd: list, timeout: int = KEYFRAME_TIMEOUT_S) -> None:
    subprocess.run(cmd, check=True, capture_output=True, timeout=timeout)


def probe_source(video: Path) -> dict:
    """{duration, color_transfer, color_primaries, color_space, pix_fmt} of the
    first video stream (strings lower-cased, '' when unknown)."""
    out = subprocess.run(
        [FFPROBE_BIN, "-v", "error", "-select_streams", "v:0", "-show_entries",
         "format=duration:stream=pix_fmt,color_transfer,color_primaries,color_space",
         "-of", "json", str(video)],
        capture_output=True, text=True, timeout=FFPROBE_TIMEOUT_S,
    )
    if out.returncode != 0:
        raise RuntimeError(f"ffprobe failed for {video}: {out.stderr.strip()[:300]}")
    data = json.loads(out.stdout or "{}")
    stream = (data.get("streams") or [{}])[0]

    def s(k: str) -> str:
        v = stream.get(k)
        return str(v).strip().lower() if v not in (None, "unknown") else ""

    try:
        duration = float((data.get("format") or {}).get("duration"))
    except (TypeError, ValueError):
        raise RuntimeError(f"ffprobe returned no duration for {video}")
    return {"duration": duration, "pix_fmt": s("pix_fmt"), "color_transfer": s("color_transfer"),
            "color_primaries": s("color_primaries"), "color_space": s("color_space")}


def probe_duration(video: Path) -> float:
    return probe_source(video)["duration"]


def _is_hdr(info: dict) -> bool:
    if info.get("color_transfer") in _HDR_TRANSFERS:
        return True
    pf = info.get("pix_fmt") or ""
    return info.get("color_primaries") == "bt2020" and any(b in pf for b in ("10", "12", "16"))


def keyframe_vf(info: dict | None) -> str:
    """Filter for extracted keyframes: downscale, plus an HDR→SDR tone-map when
    (and only when) the source is PQ/HLG — a raw 10-bit HLG frame saved as JPEG
    is the grey, washed-out image Gemini/Claude would otherwise be judging
    (audit F-G-03). Mirrors services/worker/ffmpeg_render.hdr_tonemap_chain."""
    chain = [f"scale=w='min({KEYFRAME_LONG_EDGE},iw)':h='min({KEYFRAME_LONG_EDGE},ih)'"
             ":force_original_aspect_ratio=decrease:force_divisible_by=2"]
    if info and _is_hdr(info) and os.environ.get("TONEMAP_HDR", "1").strip().lower() not in ("0", "false", "no", "off"):
        tin = _ZSCALE_TRANSFER.get(info.get("color_transfer", ""), "arib-std-b67")
        pin = _ZSCALE_PRIMARIES.get(info.get("color_primaries", ""), "2020")
        min_ = _ZSCALE_MATRIX.get(info.get("color_space", ""), "2020_ncl")
        curve = (os.environ.get("TONEMAP_CURVE", "mobius").strip().lower()
                 or "mobius")
        if curve not in ("none", "clip", "linear", "gamma", "reinhard", "hable", "mobius"):
            curve = "mobius"
        npl = os.environ.get("TONEMAP_NPL", "100").strip() or "100"
        try:
            float(npl)
        except ValueError:
            npl = "100"
        chain += [
            f"zscale=tin={tin}:pin={pin}:min={min_}:t=linear:npl={npl}",
            "format=gbrpf32le",
            "zscale=p=bt709",
            f"tonemap=tonemap={curve}:desat=0",
            "zscale=t=bt709:m=bt709:r=tv",
        ]
    chain.append("format=yuvj420p")
    return ",".join(chain)


def extract_keyframe(video: Path, t: float, out: Path, info: dict | None = None) -> Path:
    _run([FFMPEG_BIN, "-y", "-hide_banner", "-nostdin", "-ss", f"{t:.2f}", "-i", str(video),
          "-vf", keyframe_vf(info), "-frames:v", "1", "-q:v", "2", str(out)])
    if not out.exists():
        raise FileNotFoundError(f"no keyframe produced at {t:.2f}s ({out.name}) — past the end of the clip?")
    return out


def _safe_name(name, fallback: str) -> str:
    """Chapter/room labels are user-controlled and get used to build file paths
    (extract_keyframe writes ``workdir / f"{name}.jpg"``). Slugify to a bounded,
    separator-free token so a label like ``../../etc`` or an absolute path can't
    escape the workdir (path traversal / arbitrary write, worse because the
    worker container runs the pipeline)."""
    slug = re.sub(r"[^A-Za-z0-9_-]", "_", str(name)).strip("_")[:64]
    return slug or fallback


def segment_video(video: Path, chapters: list | None, duration: float | None = None) -> list:
    """Room segments from chapter tags (the app records them), else 8s slices.

    Chapter names are suffixed with their index when two tags share a slug
    (two "Bedroom" tags used to overwrite each other's stills). Chapters past
    the end of the clip are dropped rather than producing an empty segment.
    """
    dur = duration if duration is not None else probe_duration(video)
    if chapters:
        segs = []
        seen: dict[str, int] = {}
        valid = [c for c in chapters if isinstance(c, dict) and isinstance(c.get("t"), (int, float)) and 0 <= c["t"] < dur]
        for i, c in enumerate(valid):
            start = float(c["t"])
            end = float(valid[i + 1]["t"]) if i + 1 < len(valid) else dur
            if end <= start:
                continue
            name = _safe_name(c.get("name"), f"segment-{i + 1}")
            n = seen.get(name, 0) + 1
            seen[name] = n
            if n > 1:
                name = f"{name}-{n}"
            segs.append({"name": name, "start": start, "end": end})
        if segs:
            return segs
    return _auto_segments(dur)


# Chapter-less fallback bounds (audit F-G-16). A 10-minute walk sliced every 8s
# is 75 keyframes → 75 Gemini + 75 QC cycles, roughly $8–20 of provider spend, and
# 75 "photos" rows captioned segment-1…75 — for a job whose customer never tagged
# a single room. One sample per NO_CHAPTER_SPACING_S, at most NO_CHAPTER_MAX, is
# a representative walkthrough sample at bounded cost.
NO_CHAPTER_SPACING_S = max(5.0, float(os.environ.get("NO_CHAPTER_SPACING_S", "30") or 30))
NO_CHAPTER_MAX = max(1, int(os.environ.get("NO_CHAPTER_MAX_SEGMENTS", "12") or 12))


def _auto_segments(dur: float) -> list:
    """Bounded, evenly-spaced samples when the capture carries no room tags."""
    if dur <= 0:
        return []
    count = max(1, min(NO_CHAPTER_MAX, int(dur // NO_CHAPTER_SPACING_S) or 1))
    width = dur / count
    segs = [{"name": f"segment-{i + 1}", "start": i * width,
             "end": min((i + 1) * width, dur)} for i in range(count)]
    if count == NO_CHAPTER_MAX and dur > NO_CHAPTER_MAX * NO_CHAPTER_SPACING_S:
        print(f"    · no room tags: sampling {count} keyframes across {dur:.0f}s "
              f"(capped by NO_CHAPTER_MAX_SEGMENTS) instead of one every "
              f"{NO_CHAPTER_SPACING_S:.0f}s — bounds the per-job AI spend")
    return segs


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


# Failures that are LOCAL to one segment. A refusal from Gemini, a fal timeout,
# an Anthropic overload, a keyframe past EOF, or an unparsable judge reply on
# room 7 of 8 must not throw away rooms 1–6 (already paid for) — audit F-G-08.
_SEGMENT_ERRORS = (ProviderError, ValueError, OSError, subprocess.CalledProcessError,
                   subprocess.TimeoutExpired)


def enhance_video(video: Path, declutter: bool, style: str | None, *,
                  chapters: list | None, hero: bool, hero_seconds: int, analyze: bool,
                  workdir: Path, job_id: str | None, org_id: str | None) -> dict:
    ctx = new_context(job_id, org_id)
    info = probe_source(video)
    if _is_hdr(info):
        print(f"→ HDR source (transfer={info['color_transfer'] or '?'}) — keyframes tone-mapped to SDR")
    segments = segment_video(video, chapters, duration=info["duration"])
    print(f"→ {len(segments)} room segments")
    results = []
    hero_frame: bytes | None = None
    for seg in segments:
        print(f"\n■ {seg['name']} ({seg['start']:.0f}s–{seg['end']:.0f}s)")
        mid = (seg["start"] + seg["end"]) / 2
        try:
            frame = extract_keyframe(video, mid, workdir / f"{seg['name']}.jpg", info)
            source = frame.read_bytes()
            plan = _maybe_analyze(ctx, source, analyze)
            out = enhance_frame(ctx, source, declutter, style, plan=plan)
            (workdir / f"{seg['name']}-enhanced.jpg").write_bytes(out["data"])
        except _SEGMENT_ERRORS as e:
            print(f"    ✗ segment failed and ships as ORIGINAL: {e.__class__.__name__}: {e}")
            results.append({**seg, "status": "error", "reason": f"{e.__class__.__name__}: {str(e)[:300]}"})
            # Keep the manifest current so a later crash can't lose the record.
            _write_manifest(ctx, results, declutter, style, workdir, video=str(video))
            continue
        if out["status"] == "enhanced" and hero_frame is None:
            hero_frame = out["data"]  # first good frame seeds the single hero clip
        results.append({**seg, **_strip(out)})
        _write_manifest(ctx, results, declutter, style, workdir, video=str(video))

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


def _build_manifest(ctx: JobContext, segments: list, declutter: bool, style: str | None,
                    video: str | None) -> dict:
    staged = any(s.get("status") == "enhanced" for s in segments)
    return {
        "video": video, "declutter": declutter, "style": style,
        "virtually_staged": staged,      # → mandatory "Virtually staged" disclosure
        "spent_cents": ctx.budget.spent_cents,
        "cost_cap_cents": ctx.budget.ceiling_cents,
        "ledger_rows": len(ctx.ledger.rows),
        "segments": segments,
    }


def _write_manifest(ctx: JobContext, segments: list, declutter: bool, style: str | None,
                    workdir: Path, video: str | None = None) -> None:
    """Incremental manifest so paid results survive a later crash (the worker
    harvests manifest.json even when enhance_video() raises)."""
    try:
        (workdir / "manifest.json").write_text(
            json.dumps(_build_manifest(ctx, segments, declutter, style, video), indent=2))
    except OSError as e:
        print(f"    ⚠ could not write manifest: {e}")


def _finish(ctx: JobContext, segments: list, declutter: bool, style: str | None,
            workdir: Path, video: str | None = None) -> dict:
    staged = any(s.get("status") == "enhanced" for s in segments)
    manifest = _build_manifest(ctx, segments, declutter, style, video)
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
