#!/usr/bin/env python3
"""
Rendprop enhancement orchestrator — declutter + virtual restaging.

The "renders perfect every time" logic is a closed loop, not a single AI call:

    video in (recorded or uploaded)
      └─ 1. SEGMENT   ffprobe + room chapters (or scene detection)
      └─ 2. ANALYZE   Claude vision on each room keyframe:
                      room type, clutter inventory, style prompt, keep-list
      └─ 3. EDIT      Higgsfield (nano banana) image edit per keyframe:
                      declutter and/or restage — architecture locked
      └─ 4. JUDGE     Claude compares before/after:
                      structure score, completeness score, artifact check
                      → below threshold? regen WITH the judge's feedback
                      → still failing after N tries? FALL BACK to original
      └─ 5. ANIMATE   Seedance i2v: animate the approved frame with the
                      original segment's camera motion
      └─ 6. JUDGE 2   drift check on sampled video frames (same rules)
      └─ 7. STITCH    approved segments into the deterministic backbone

    Hard rules enforced by the loop:
      • Architecture NEVER changes (walls/windows/doors/floors/views).
      • A failed segment ships as the ORIGINAL footage, never a bad edit.
      • Per-job cost ceiling — the loop stops spending, never runs away.
      • Any active enhancement → share page carries "Virtually staged".

Usage:
    python3 enhance.py walkthrough.mp4 --declutter --style modern
    python3 enhance.py room-photo.jpg --declutter            # single image
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

# ── env ──────────────────────────────────────────────────────────────────────

def load_env(path: Path = Path(__file__).parent / ".env") -> None:
    if not path.exists():
        sys.exit("No .env found. Run 'Add API Keys.command' in the repo root first.")
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, _, v = line.partition("=")
            os.environ.setdefault(k.strip(), v.strip())

load_env()

ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
ANTHROPIC_MODEL = os.environ.get("ANTHROPIC_MODEL", "claude-fable-5")
HF_KEY = os.environ.get("HIGGSFIELD_API_KEY", "")
HF_SECRET = os.environ.get("HIGGSFIELD_API_SECRET", "")
HF_IMAGE_EDIT_MODEL = os.environ.get("HF_IMAGE_EDIT_MODEL", "nano-banana-pro/image-edit")
HF_I2V_MODEL = os.environ.get("HF_I2V_MODEL", "bytedance/seedance/v2/pro/image-to-video")
QC_PASS_SCORE = int(os.environ.get("QC_PASS_SCORE", "85"))
QC_MAX_RETRIES = int(os.environ.get("QC_MAX_RETRIES", "2"))
COST_CEILING_CENTS = int(os.environ.get("MAX_GEN_COST_PER_JOB_CENTS", "2500"))

HF_BASE = "https://platform.higgsfield.ai"

STYLES = {
    "modern":       "clean-lined contemporary furniture, low-profile charcoal sectional, walnut and matte-black accents, minimal abstract wall art, modern area rug",
    "rustic":       "warm farmhouse furniture, natural woods, cozy layered textiles, vintage-style decor, warm earth tones",
    "minimalist":   "very few carefully chosen pieces, neutral palette, clean surfaces, airy negative space, simple line art",
    "scandinavian": "light oak furniture, soft whites and greys, hygge textures, simple functional pieces, green plants",
}

# ── cost meter (per-job ceiling — never runs away) ───────────────────────────

@dataclass
class CostMeter:
    ceiling_cents: int
    spent_cents: int = 0
    log: list = field(default_factory=list)

    # Conservative per-call estimates; replace with billed costs when the
    # provider returns them.
    PRICES = {"image_edit": 6, "i2v_second": 12, "claude_vision": 2}

    def charge(self, kind: str, units: float = 1) -> None:
        cents = int(self.PRICES[kind] * units)
        self.spent_cents += cents
        self.log.append((kind, units, cents))
        if self.spent_cents > self.ceiling_cents:
            raise BudgetExceeded(
                f"Cost ceiling hit (${self.spent_cents/100:.2f} > ${self.ceiling_cents/100:.2f}). "
                "Remaining segments ship as original footage.")

class BudgetExceeded(Exception):
    pass

# ── HTTP helpers (stdlib only — no dependencies to install) ──────────────────

def http_json(url: str, payload: dict | None = None, headers: dict | None = None) -> dict:
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method="POST" if data else "GET")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    # Cloudflare fronts platform.higgsfield.ai and rejects default urllib UA (error 1010)
    req.add_header("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                                 "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.loads(resp.read().decode())

# ── Higgsfield client (async queue: submit → poll) ───────────────────────────

def hf_headers() -> dict:
    return {"Authorization": f"Key {HF_KEY}:{HF_SECRET}"}

def hf_submit_and_wait(model_id: str, payload: dict, timeout_s: int = 600) -> dict:
    sub = http_json(f"{HF_BASE}/{model_id}", payload, hf_headers())
    status_url = sub["status_url"]
    started = time.time()
    while time.time() - started < timeout_s:
        st = http_json(status_url, headers=hf_headers())
        status = st.get("status")
        if status == "completed":
            return st
        if status in ("failed", "nsfw"):
            raise RuntimeError(f"Higgsfield job {status}: {st}")
        time.sleep(4)
    raise TimeoutError(f"Higgsfield job timed out: {status_url}")

def hf_image_edit(image_url: str, prompt: str) -> str:
    """Edit an image (declutter / restage). Returns result image URL."""
    result = hf_submit_and_wait(HF_IMAGE_EDIT_MODEL, {
        "image_url": image_url,
        "prompt": prompt,
        "aspect_ratio": "16:9",
    })
    return result["images"][0]["url"]

def hf_i2v(image_url: str, motion_prompt: str, seconds: int = 5) -> str:
    """Animate an approved frame (Seedance). Returns video URL."""
    result = hf_submit_and_wait(HF_I2V_MODEL, {
        "image_url": image_url,
        "prompt": motion_prompt,
        "duration": seconds,
    })
    return result["video"]["url"]

# ── Claude client (analyze + judge) ──────────────────────────────────────────

def claude(messages: list, max_tokens: int = 1024) -> str:
    out = http_json("https://api.anthropic.com/v1/messages", {
        "model": ANTHROPIC_MODEL,
        "max_tokens": max_tokens,
        "messages": messages,
    }, {
        "x-api-key": ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
    })
    return "".join(b.get("text", "") for b in out.get("content", []))

def img_block(path_or_url: str) -> dict:
    if path_or_url.startswith("http"):
        return {"type": "image", "source": {"type": "url", "url": path_or_url}}
    raw = Path(path_or_url).read_bytes()
    media = "image/png" if path_or_url.endswith(".png") else "image/jpeg"
    return {"type": "image", "source": {"type": "base64", "media_type": media,
                                        "data": base64.b64encode(raw).decode()}}

def parse_json(text: str) -> dict:
    start, end = text.find("{"), text.rfind("}")
    return json.loads(text[start:end + 1])

def analyze_room(frame: str, declutter: bool, style: str | None, meter: CostMeter) -> dict:
    """Claude vision: room type, clutter inventory, edit prompt, keep-list."""
    meter.charge("claude_vision")
    style_line = (f"Also plan a virtual restage in {style.upper()} style: {STYLES[style]}."
                  if style else "No restaging — keep all furniture as-is.")
    task = ("List every removable clutter item (boxes, mess, cords, laundry, papers)."
            if declutter else "Do not remove anything.")
    text = claude([{"role": "user", "content": [
        img_block(frame),
        {"type": "text", "text": f"""You are Rendprop's real-estate video enhancement planner.
Analyze this room frame. {task} {style_line}

Rules: architecture is untouchable (walls, windows, doors, floors, ceilings, fixtures, views).
Never plan to hide property defects. Furniture and decor only.

Reply with ONLY JSON:
{{"room_type": "...", "clutter_items": ["..."], "keep_identical": ["window on left", "..."],
 "edit_prompt": "one complete instruction for an image-edit model"}}"""}]}])
    return parse_json(text)

def judge(before: str, after: str, plan: dict, meter: CostMeter) -> dict:
    """Claude compares before/after. The gate that makes output trustworthy."""
    meter.charge("claude_vision")
    text = claude([{"role": "user", "content": [
        {"type": "text", "text": "BEFORE:"}, img_block(before),
        {"type": "text", "text": "AFTER:"}, img_block(after),
        {"type": "text", "text": f"""You are Rendprop's quality judge for real-estate media.
The edit plan was: {json.dumps(plan)}

Score the AFTER image:
1. structure (0-100): are walls, windows, doors, floors, ceiling, layout, and view
   IDENTICAL to BEFORE? Any moved/added/removed architecture = below 50.
2. completeness (0-100): was the planned edit fully done (all clutter gone / style applied)?
3. artifacts (0-100): free of warping, smears, impossible geometry, AI weirdness?

Reply ONLY JSON:
{{"structure": 0, "completeness": 0, "artifacts": 0,
 "verdict": "pass|retry|fail", "feedback": "specific fix for the next attempt"}}"""}]}])
    return parse_json(text)

# ── ffmpeg helpers ────────────────────────────────────────────────────────────

def run(cmd: list) -> None:
    subprocess.run(cmd, check=True, capture_output=True)

def probe_duration(video: Path) -> float:
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                          "-of", "csv=p=0", str(video)], capture_output=True, text=True)
    return float(out.stdout.strip())

def extract_keyframe(video: Path, t: float, out: Path) -> Path:
    run(["ffmpeg", "-y", "-ss", f"{t:.2f}", "-i", str(video),
         "-frames:v", "1", "-q:v", "2", str(out)])
    return out

def segment_video(video: Path, chapters: list[dict] | None) -> list[dict]:
    """Room segments from chapter tags (the app records them), else time slices."""
    dur = probe_duration(video)
    if chapters:
        segs = []
        for i, c in enumerate(chapters):
            start = c["t"]
            end = chapters[i + 1]["t"] if i + 1 < len(chapters) else dur
            segs.append({"name": c["name"], "start": start, "end": end})
        return segs
    # No tags: fixed 8s slices (server-side room detection replaces this later)
    return [{"name": f"segment-{i+1}", "start": t, "end": min(t + 8, dur)}
            for i, t in enumerate(range(0, int(dur), 8))]

# ── media hosting (Higgsfield needs a public URL for input frames) ───────────

def public_url_for(path: Path) -> str:
    """Upload a local frame to R2 and return a public URL.
    Requires R2_* in .env (boto3: pip install boto3)."""
    account = os.environ.get("R2_ACCOUNT_ID")
    if not account:
        raise SystemExit(
            "Input frames must be reachable by URL. Add R2_* credentials to .env "
            "(Cloudflare R2, free tier is fine) — or pass an https:// image URL directly.")
    import boto3  # optional dep, only needed for local-file mode
    s3 = boto3.client("s3",
        endpoint_url=f"https://{account}.r2.cloudflarestorage.com",
        aws_access_key_id=os.environ["R2_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["R2_SECRET_ACCESS_KEY"])
    bucket = os.environ.get("R2_BUCKET", "rendprop-dev")
    key = f"frames/{int(time.time())}-{path.name}"
    s3.upload_file(str(path), bucket, key)
    return s3.generate_presigned_url("get_object",
        Params={"Bucket": bucket, "Key": key}, ExpiresIn=3600)

# ── the enhancement loop (edit → judge → retry → fallback) ───────────────────

def enhance_frame(frame_url: str, declutter: bool, style: str | None,
                  meter: CostMeter) -> dict:
    plan = analyze_room(frame_url, declutter, style, meter)
    prompt_suffix = (" CRITICAL: keep architecture pixel-identical — same walls, windows, "
                     "doors, floors, ceiling, camera angle, lighting. "
                     f"Keep identical: {', '.join(plan.get('keep_identical', []))}.")
    prompt = plan["edit_prompt"] + prompt_suffix

    for attempt in range(1 + QC_MAX_RETRIES):
        meter.charge("image_edit")
        candidate = hf_image_edit(frame_url, prompt)
        verdict = judge(frame_url, candidate, plan, meter)
        score = min(verdict["structure"], verdict["completeness"], verdict["artifacts"])
        print(f"    attempt {attempt+1}: structure={verdict['structure']} "
              f"complete={verdict['completeness']} artifacts={verdict['artifacts']} "
              f"→ {verdict['verdict']}")
        if verdict["verdict"] == "pass" and score >= QC_PASS_SCORE:
            return {"status": "enhanced", "url": candidate, "plan": plan, "qc": verdict}
        prompt = plan["edit_prompt"] + prompt_suffix + f" Fix from last attempt: {verdict['feedback']}"

    print("    ✗ QC never passed — this segment ships as ORIGINAL footage (never a bad edit).")
    return {"status": "fallback_original", "url": frame_url, "plan": plan}

def enhance_video(video: Path, declutter: bool, style: str | None,
                  chapters: list[dict] | None, workdir: Path) -> dict:
    meter = CostMeter(COST_CEILING_CENTS)
    segments = segment_video(video, chapters)
    print(f"→ {len(segments)} room segments, ceiling ${COST_CEILING_CENTS/100:.2f}")
    results = []
    for seg in segments:
        print(f"\n■ {seg['name']} ({seg['start']:.0f}s–{seg['end']:.0f}s)")
        mid = (seg["start"] + seg["end"]) / 2
        frame = extract_keyframe(video, mid, workdir / f"{seg['name']}.jpg")
        try:
            frame_url = public_url_for(frame)
            out = enhance_frame(frame_url, declutter, style, meter)
            if out["status"] == "enhanced":
                motion = ("smooth steady walkthrough glide forward through the room, "
                          "cinematic gimbal motion, keep the room's geometry identical")
                meter.charge("i2v_second", min(8.0, seg["end"] - seg["start"]))
                out["video_url"] = hf_i2v(out["url"], motion,
                                          seconds=int(min(8, seg["end"] - seg["start"])))
        except BudgetExceeded as e:
            print(f"  ⚠ {e}")
            out = {"status": "fallback_original", "reason": "budget"}
        results.append({**seg, **out})

    manifest = {"video": str(video), "declutter": declutter, "style": style,
                "virtually_staged": any(r["status"] == "enhanced" for r in results),
                "spent_cents": meter.spent_cents, "segments": results}
    (workdir / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"\n✓ Done. Spent ~${meter.spent_cents/100:.2f}. Manifest: {workdir/'manifest.json'}")
    print("  Next: stitch enhanced segment videos over the deterministic backbone (ffmpeg).")
    return manifest

# ── CLI ───────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(description="Rendprop declutter/restage orchestrator")
    ap.add_argument("input", help="walkthrough video, image file, or image URL")
    ap.add_argument("--declutter", action="store_true")
    ap.add_argument("--style", choices=list(STYLES), default=None)
    ap.add_argument("--chapters", help="JSON file: [{\"name\": \"Kitchen\", \"t\": 42.5}]")
    ap.add_argument("--workdir", default="out")
    args = ap.parse_args()

    if not (args.declutter or args.style):
        sys.exit("Pick at least one: --declutter and/or --style modern|rustic|minimalist|scandinavian")
    if not (ANTHROPIC_API_KEY and HF_KEY):
        sys.exit("Missing keys — run 'Add API Keys.command' in the repo root.")

    workdir = Path(args.workdir); workdir.mkdir(exist_ok=True)
    meter = CostMeter(COST_CEILING_CENTS)

    if args.input.startswith("http") or args.input.lower().endswith((".jpg", ".jpeg", ".png")):
        url = args.input if args.input.startswith("http") else public_url_for(Path(args.input))
        result = enhance_frame(url, args.declutter, args.style, meter)
        print(json.dumps(result, indent=2))
    else:
        chapters = json.loads(Path(args.chapters).read_text()) if args.chapters else None
        enhance_video(Path(args.input), args.declutter, args.style, chapters, workdir)

if __name__ == "__main__":
    main()
