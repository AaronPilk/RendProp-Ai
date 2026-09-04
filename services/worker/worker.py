#!/usr/bin/env python3
"""
Rendprop server-side RENDER WORKER — the queue consumer.

Turns an uploaded walkthrough into a published, hosted, scrubbable tour:

    poll render_jobs (created|queued)  →  claim (status=processing)
      1. download the capture from R2 `rendprop-uploads`
      2. ffmpeg render (mirror RenderEngine): retime · 60fps · ≤1280 ·
         all-intra H.264 · faststart · poster                → meter `render`
      3. (if enhancements) run the AI pipeline per room/segment:
         declutter / restage / hero                          → metered by pipeline
      4. upload mp4 + poster (+ enhanced stills) to R2 `rendprop-renders`
      5. register the mp4 to Cloudflare Stream (copy-from-URL) → stream_uid
      6. insert a `renders` row (slug, duration, keys, staged)
      7. job → ready, progress=1, finished_at                → meter `stream_store`
    failure anywhere → status=failed + error jsonb (base tour never lost to an add-on)

Run modes:
    python worker.py                 # long-running poller (default)
    RUN_ONCE=1 python worker.py      # process one job then exit (serverless/cron)
    python worker.py --once
    python worker.py --job-id <uuid> # process a specific job (webhook-triggered)

See README.md for local run + deploy (Modal / Cloud Run / container).
"""

from __future__ import annotations

import argparse
import os
import shutil
import signal
import sys
import time
import traceback
from uuid import uuid4

import db
import ffmpeg_render
import infra_costs
import r2
import stream
from enhance_bridge import EnhanceResult, run_enhancement, wants_enhancement
from settings import SETTINGS
from slugs import new_slug

_STOP = False


def _handle_signal(signum, _frame):
    global _STOP
    _STOP = True
    print(f"\n↩ signal {signum} received — finishing current job then exiting…")


# ── progress throttling ───────────────────────────────────────────────────────

def _make_progress(job_id: str, step: str, lo: float, hi: float):
    """Map a 0..1 sub-progress into [lo,hi] and PATCH the job, throttled."""
    last = -1.0

    def cb(frac: float) -> None:
        nonlocal last
        p = lo + (hi - lo) * max(0.0, min(1.0, frac))
        if abs(p - last) >= 0.02 or frac >= 1.0:
            last = p
            db.set_progress(job_id, p, step)

    return cb


# ── enhancement persistence ───────────────────────────────────────────────────

def _persist_enhancements(result: EnhanceResult, listing_id: str, render_id: str) -> str | None:
    """Upload enhanced stills (+hero) to R2 and record `photos` rows. Best-effort.

    Returns the hero clip's R2 key if uploaded, else None. Never raises — a failed
    add-on upload must not sink the published tour.
    """
    bucket = SETTINGS.r2_bucket_renders
    for i, still in enumerate(result.stills):
        try:
            enh_key = f"renders/{listing_id}/{render_id}-staged-{i}.jpg"
            r2.upload_file(still.enhanced_path, bucket, enh_key, "image/jpeg")
            orig_key = None
            if still.source_path and os.path.exists(still.source_path):
                orig_key = f"renders/{listing_id}/{render_id}-staged-{i}-orig.jpg"
                r2.upload_file(still.source_path, bucket, orig_key, "image/jpeg")
            db.insert_photo({
                "listing_id": listing_id,
                "original_key": orig_key,
                "enhanced_key": enh_key,
                "is_staged": True,          # → mandatory "Virtually staged" disclosure
                "caption": still.room,
                "sort": i,
            })
        except Exception as e:  # noqa: BLE001
            print(f"    ⚠ enhanced still {i} persist failed (continuing): {e}")

    hero_key = None
    if result.hero_path:
        try:
            hero_key = f"renders/{listing_id}/{render_id}-hero.mp4"
            r2.upload_file(result.hero_path, bucket, hero_key, "video/mp4")
            print(f"    ✓ hero clip → r2://{bucket}/{hero_key}")
            # TODO: no first-class column for the hero clip yet. Surface it via a
            # `media` table or a renders.hero_key column so the tour host can play
            # it. For now it lives in R2 and is logged here.
        except Exception as e:  # noqa: BLE001
            print(f"    ⚠ hero upload failed (continuing): {e}")
    return hero_key


# ── Cloudflare Stream registration ────────────────────────────────────────────

def _register_stream(video_key: str, listing_id: str, render_id: str) -> str | None:
    """Register the R2 mp4 to Stream via copy-from-URL. Returns UID or None."""
    if not SETTINGS.has_stream:
        print("    · Stream token absent — skipping; player will use the R2 mp4 url.")
        return None
    uid: str | None = None
    try:
        src = r2.presigned_get_url(SETTINGS.r2_bucket_renders, video_key)
        uid = stream.copy_from_url(src, name=f"{listing_id}/{render_id}",
                                   meta={"listing_id": listing_id, "render_id": render_id})
        print(f"    ✓ Stream registered uid={uid}")
        if SETTINGS.stream_require_ready:
            details = stream.poll_ready(uid)
            pb = stream.playback_urls(details)
            print(f"    ✓ Stream ready hls={pb.get('hls')}")
        return uid
    except Exception as e:  # noqa: BLE001 — Stream is optional; fall back to R2 mp4
        if uid:
            # Registration succeeded; only the readiness poll gave up. The UID
            # is real and Stream keeps transcoding — keep it rather than
            # orphaning a billed asset (the player uses the R2 mp4 first anyway).
            print(f"    ⚠ Stream readiness poll failed (keeping uid={uid}; player falls back to R2 mp4): {e}")
            return uid
        print(f"    ⚠ Stream registration failed (continuing with R2 mp4): {e}")
        return None


# ── asset eligibility ─────────────────────────────────────────────────────────

def _skip_reason(asset: dict) -> str | None:
    """Why this asset is not the worker's to render (None = go ahead)."""
    bucket = (asset.get("bucket") or "uploads")
    if bucket != "uploads":
        return (f"asset {asset.get('id')} lives in the '{bucket}' bucket (app-published tour), "
                "not in the uploads bucket — nothing for the worker to render")
    if asset.get("uploaded") is False:
        return f"asset {asset.get('id')} has not finished uploading"
    if asset.get("kind") not in (None, "video"):
        return f"asset {asset.get('id')} is a {asset.get('kind')}, not a video"
    return None


# ── the job ───────────────────────────────────────────────────────────────────

def process_job(job: dict) -> None:
    job_id = job["id"]
    listing_id = job.get("listing_id")
    asset_id = job.get("capture_asset_id")
    enhancements = job.get("enhancements") or {}
    workdir = os.path.join(SETTINGS.workdir, job_id)
    os.makedirs(workdir, exist_ok=True)
    step = "load"

    print(f"\n=== job {job_id} (listing={listing_id} asset={asset_id} "
          f"tier={job.get('tier')} enhancements={enhancements}) ===")

    try:
        # 1. Resolve listing (→ org_id) + capture asset.
        db.set_progress(job_id, 0.05, "loading")
        listing = db.fetch_listing(listing_id) if listing_id else None
        if not listing:
            raise RuntimeError(f"listing {listing_id} not found")
        org_id = listing.get("org_id")

        if not asset_id:
            raise RuntimeError("job has no capture_asset_id")
        asset = db.fetch_asset(asset_id)
        if not asset:
            raise RuntimeError(f"capture_asset {asset_id} not found")
        # Only raw captures in the private uploads bucket are this worker's job.
        # App-published assets live in the public `renders` bucket (the app
        # rendered them on-device and /renders/publish-app already published
        # them); claiming one would 404 on download and then mark a WORKING tour
        # "failed" (audit F-G-13). The claim query excludes them; this is the
        # belt-and-braces for the --job-id path and older PostgREST versions.
        skip = _skip_reason(asset)
        if skip:
            print(f"    · skipping job {job_id}: {skip}")
            db.release_job(job_id, skip)
            return
        storage_key = asset.get("storage_key")
        if not storage_key:
            raise RuntimeError(f"capture_asset {asset_id} has no storage_key")
        is_drone = bool(asset.get("is_drone"))

        # 2. Download the raw capture from R2 uploads.
        step = "download"
        db.set_progress(job_id, 0.10, "downloading")
        local_in = os.path.join(workdir, "capture" + os.path.splitext(storage_key)[1])
        r2.download_file(SETTINGS.r2_bucket_uploads, storage_key, local_in)
        print(f"    ✓ downloaded r2://{SETTINGS.r2_bucket_uploads}/{storage_key}")

        # 3. ffmpeg render (mirror RenderEngine).
        step = "encode"
        out_mp4, poster, duration_s, speed_factor = ffmpeg_render.render(
            local_in, is_drone, workdir=workdir,
            progress=_make_progress(job_id, "encoding", 0.15, 0.55),
        )
        print(f"    ✓ encoded {duration_s}s @ {speed_factor}× → {out_mp4}")
        rl = infra_costs.render_line(duration_s, preset=SETTINGS.encode_preset,
                                     bitrate=SETTINGS.encode_bitrate)
        db.record_cost(feature=rl.feature, provider=rl.provider, model=rl.model,
                       units=rl.units, unit_cost_cents=rl.unit_cost_cents,
                       total_cents=rl.total_cents, job_id=job_id, org_id=org_id, meta=rl.meta)

        # 4. AI enhancement (optional add-ons; never fails the base tour).
        #    wants_enhancement() normalises the style first: the app sends
        #    style:"as_is" on every plain job, which is NOT a restage request.
        step = "enhance"
        enh = EnhanceResult(ran=False, reason="no enhancements requested")
        if wants_enhancement(enhancements):
            db.set_progress(job_id, 0.58, "enhancing")
            chapters = db.fetch_chapters(asset_id)
            enh = run_enhancement(
                input_video=local_in, workdir=workdir, enhancements=enhancements,
                db_chapters=chapters, job_id=job_id, org_id=org_id,
            )
            print(f"    · enhancement: ran={enh.ran} staged={enh.staged} "
                  f"reason='{enh.reason}' spent={enh.spent_cents:.2f}¢")

        # 5. Upload mp4 + poster to R2 renders (keys per BACKEND-ARCHITECTURE §3).
        step = "upload"
        db.set_progress(job_id, 0.80, "uploading")
        render_id = str(uuid4())
        video_key = f"renders/{listing_id}/{render_id}.mp4"
        poster_key = f"renders/{listing_id}/{render_id}-poster.jpg"
        r2.upload_file(out_mp4, SETTINGS.r2_bucket_renders, video_key, "video/mp4")
        r2.upload_file(poster, SETTINGS.r2_bucket_renders, poster_key, "image/jpeg")
        print(f"    ✓ uploaded tour + poster → r2://{SETTINGS.r2_bucket_renders}/{video_key}")

        if enh.ran:
            _persist_enhancements(enh, listing_id, render_id)

        # 6. Register to Cloudflare Stream (optional).
        step = "stream"
        db.set_progress(job_id, 0.90, "registering stream")
        stream_uid = _register_stream(video_key, listing_id, render_id)

        # 7. Insert the renders row (the published tour).
        step = "publish"
        db.set_progress(job_id, 0.94, "publishing")
        render_row = db.insert_render({
            "id": render_id,
            "job_id": job_id,
            "listing_id": listing_id,
            "slug": new_slug(),
            "duration_s": duration_s,
            "speed_factor": speed_factor,
            "video_key": video_key,
            "stream_uid": stream_uid,
            "poster_key": poster_key,
            "staged": bool(enh.staged),
            "published_at": db.now_iso(),
        })
        slug = render_row.get("slug")
        print(f"    ✓ published render {render_id} slug={slug} staged={enh.staged}")

        # 8. Stream storage cost + final rollup.
        sl = infra_costs.stream_store_line(duration_s, stream_uid=stream_uid)
        db.record_cost(feature=sl.feature, provider=sl.provider, model=sl.model,
                       units=sl.units, unit_cost_cents=sl.unit_cost_cents,
                       total_cents=sl.total_cents, job_id=job_id, org_id=org_id, meta=sl.meta)
        db.rollup_job(job_id)

        # 9. Flip the listing to ready + finish the job.
        db.set_listing_status(listing_id, "ready")
        db.finish_job(job_id)
        print(f"=== job {job_id} READY → /f/{slug} ===")

    except Exception as e:  # noqa: BLE001 — any failure marks the job failed
        print(f"    ✗ job {job_id} failed at step '{step}': {e}")
        traceback.print_exc()
        db.fail_job(job_id, {
            "message": str(e),
            "step": step,
            "type": e.__class__.__name__,
            "ts": db.now_iso(),
        })
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


# ── loop / entrypoints ────────────────────────────────────────────────────────

def _preflight() -> None:
    problems = []
    if not SETTINGS.has_supabase:
        problems.append("SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY")
    if not SETTINGS.has_r2:
        problems.append("CLOUDFLARE_ACCOUNT_ID + R2_ACCESS_KEY_ID + R2_SECRET_ACCESS_KEY")
    if problems:
        sys.exit("FATAL: missing required config: " + "; ".join(problems)
                 + "\nSee services/worker/.env.example.")
    print(f"→ worker up. schema={SETTINGS.db_schema} "
          f"stream={'on' if SETTINGS.has_stream else 'off (R2 mp4 only)'} "
          f"pipeline={SETTINGS.pipeline_dir}")


def process_one() -> bool:
    """Claim + process a single job. Returns True if a job was processed."""
    job = db.claim_next_job()
    if not job:
        return False
    process_job(job)
    return True


def process_specific(job_id: str) -> None:
    """Process a specific job by id (webhook trigger).

    The claim is a COMPARE-AND-SET, matching claim_next_job(). The previous
    read-then-write let two simultaneous webhook invocations both observe
    `queued` and both proceed to render, upload, publish and charge the same job
    (audit round 4). The status filter is part of the UPDATE, so exactly one
    caller can win; a zero-row result means someone else already owns it.
    """
    rows = db.select("render_jobs", {"id": f"eq.{job_id}", "select": "*"})
    if not rows:
        sys.exit(f"job {job_id} not found")
    job = rows[0]

    # Don't even claim a job whose asset isn't ours to render (app-published
    # `renders`-bucket asset, unfinished upload) — claiming would flip an app
    # job's status underneath /renders/publish-app.
    if job.get("capture_asset_id"):
        asset = db.fetch_asset(job["capture_asset_id"])
        skip = _skip_reason(asset) if asset else None
        if skip:
            print(f"job {job_id}: {skip} — nothing to do")
            return

    statuses = ",".join(SETTINGS.claim_statuses)
    claimed = db.patch(
        "render_jobs",
        {"id": f"eq.{job_id}", "status": f"in.({statuses})"},
        {"status": "processing", "started_at": db.now_iso(),
         "current_step": "claimed", "progress": 0.02, "error": None},
        prefer="return=representation",
    )
    if not claimed:
        print(f"job {job_id} is already claimed or finished (status={job.get('status')}) — nothing to do")
        return
    process_job(claimed[0])


def run_loop() -> None:
    idle_logged = False
    while not _STOP:
        try:
            worked = process_one()
        except Exception as e:  # noqa: BLE001 — the loop must survive a bad job
            print(f"⚠ loop error (continuing): {e}")
            worked = False
        if worked:
            idle_logged = False
            continue
        if not idle_logged:
            print(f"· idle — polling every {SETTINGS.poll_interval_s}s")
            idle_logged = True
        for _ in range(int(max(1, SETTINGS.poll_interval_s))):
            if _STOP:
                break
            time.sleep(1)
    print("↩ worker stopped.")


def main() -> None:
    ap = argparse.ArgumentParser(description="Rendprop render worker")
    ap.add_argument("--once", action="store_true", help="process one job then exit")
    ap.add_argument("--job-id", default=None, help="process a specific render_jobs.id")
    args = ap.parse_args()

    signal.signal(signal.SIGINT, _handle_signal)
    signal.signal(signal.SIGTERM, _handle_signal)
    os.makedirs(SETTINGS.workdir, exist_ok=True)
    _preflight()

    if args.job_id:
        process_specific(args.job_id)
    elif args.once or SETTINGS.run_once:
        if not process_one():
            print("· no queued jobs.")
    else:
        run_loop()


if __name__ == "__main__":
    main()
