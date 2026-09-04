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
import re
import shutil
import signal
import sys
import threading
import time
import traceback
from uuid import uuid4

import db
import ffmpeg_render
import infra_costs
import r2
import settings
import stream
from enhance_bridge import EnhanceResult, run_enhancement, wants_enhancement
from settings import SETTINGS
from slugs import new_slug

_STOP = False


def _handle_signal(signum, _frame):
    """SIGTERM/SIGINT: stop the encode NOW and hand the job back to the queue.

    The old policy was "finish the current job", which can be 90 minutes — far
    past any orchestrator's 10–30s grace period, so the process was SIGKILLed
    mid-render and the job was orphaned at `processing` forever (audit F-G-05).
    Aborting and re-queueing loses at most one encode's work and keeps the queue
    healthy; the job is picked up by the next worker with its `attempts` intact.
    """
    global _STOP
    _STOP = True
    print(f"\n↩ signal {signum} received — aborting the current encode and "
          f"re-queueing the job…")
    ffmpeg_render.request_abort()


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


# ── lease heartbeat ───────────────────────────────────────────────────────────

class _Heartbeat:
    """Refresh the job's lease while we hold it (audit F-G-05).

    If a refresh reports that we no longer own the job — another worker reclaimed
    an expired lease, or the reaper failed it — `lost` is set and `process_job`
    stops: publishing then would create a SECOND renders row and bill the job
    twice. A no-op when the lease columns aren't deployed yet.
    """

    def __init__(self, job_id: str) -> None:
        self.job_id = job_id
        self.lost = threading.Event()
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True,
                                        name=f"heartbeat-{job_id[:8]}")

    def _run(self) -> None:
        while not self._stop.wait(db.HEARTBEAT_SECONDS):
            if not db.heartbeat(self.job_id):
                self.lost.set()
                print(f"    ⚠ lost the lease on job {self.job_id} — another worker owns "
                      f"it now; abandoning to avoid a double publish")
                ffmpeg_render.request_abort()
                return

    def __enter__(self) -> "_Heartbeat":
        if db.lease_supported():
            self._thread.start()
        return self

    def __exit__(self, *_exc) -> None:
        self._stop.set()
        if self._thread.is_alive():
            self._thread.join(timeout=2)

    def check(self) -> None:
        if self.lost.is_set():
            raise LeaseLost(f"lease on job {self.job_id} was taken over by another worker")


class LeaseLost(RuntimeError):
    """We no longer own this job — stop without failing it."""


# ── enhancement persistence ───────────────────────────────────────────────────

_AUTO_SEGMENT = re.compile(r"^segment-\d+(-\d+)?$")


def _caption_for(room: str) -> str | None:
    """`segment-7` is a slicing artefact, not a room name — don't show it.

    With chapters the label IS the room the agent tagged. Without them the
    pipeline names slices `segment-N` (audit F-G-16), and captioning a gallery
    photo "segment-7" looks broken to a buyer.
    """
    name = (room or "").strip()
    return None if (not name or _AUTO_SEGMENT.match(name)) else name


def _upload_enhancements(result: EnhanceResult, listing_id: str, render_id: str,
                         artifacts: "_Artifacts") -> tuple[list[dict], str | None]:
    """Upload enhanced stills (+hero) to R2. Returns (photo_rows, hero_key).

    Uploads only — the `photos` rows are written LATER, after the tour is
    actually published. Writing them here meant a failure at step 7/8 left DB
    rows pointing at objects the rollback had just deleted (audit F-G-21).
    Never raises: a failed add-on upload must not sink the published tour.
    """
    bucket = SETTINGS.r2_bucket_renders
    rows: list[dict] = []
    for i, still in enumerate(result.stills):
        try:
            enh_key = f"renders/{listing_id}/{render_id}-staged-{i}.jpg"
            r2.upload_file(still.enhanced_path, bucket, enh_key, "image/jpeg")
            artifacts.r2(bucket, enh_key)
            orig_key = None
            if still.source_path and os.path.exists(still.source_path):
                orig_key = f"renders/{listing_id}/{render_id}-staged-{i}-orig.jpg"
                r2.upload_file(still.source_path, bucket, orig_key, "image/jpeg")
                artifacts.r2(bucket, orig_key)
            rows.append({
                "listing_id": listing_id,
                "original_key": orig_key,
                "enhanced_key": enh_key,
                "is_staged": True,          # → mandatory "Virtually staged" disclosure
                "caption": _caption_for(still.room),
                "sort": i,
            })
        except Exception as e:  # noqa: BLE001
            print(f"    ⚠ enhanced still {i} upload failed (continuing): {e}")

    hero_key = None
    if result.hero_path:
        try:
            hero_key = f"renders/{listing_id}/{render_id}-hero.mp4"
            r2.upload_file(result.hero_path, bucket, hero_key, "video/mp4")
            artifacts.r2(bucket, hero_key)
            print(f"    ✓ hero clip → r2://{bucket}/{hero_key}")
        except Exception as e:  # noqa: BLE001
            print(f"    ⚠ hero upload failed (continuing): {e}")
            hero_key = None
    return rows, hero_key


def _record_enhancement_photos(rows: list[dict]) -> None:
    """Insert the `photos` rows for a tour that is now actually published."""
    for row in rows:
        db.insert_photo(row)
    if rows:
        print(f"    ✓ {len(rows)} enhanced still(s) recorded on the listing")


# ── uploaded-artifact ledger (audit F-G-21) ───────────────────────────────────

class _Artifacts:
    """Everything this job has already put somewhere that costs money.

    The mp4, poster, stills and the Stream copy are all created BEFORE the
    `renders` row exists. A failure at step 7/8 (or a hard kill) used to leave
    every one of them unreferenced: R2 objects nobody deletes and a Stream asset
    that keeps transcoding and billing with nothing pointing at it. On failure we
    now walk this list back — best-effort, never raising, so cleanup can't mask
    the original error.
    """

    def __init__(self) -> None:
        self.r2_keys: list[tuple[str, str]] = []     # (bucket, key)
        self.stream_uid: str | None = None
        self.published = False                        # renders row exists → keep everything

    def r2(self, bucket: str, key: str) -> None:
        self.r2_keys.append((bucket, key))

    def rollback(self, reason: str) -> None:
        if self.published:
            return
        if not (self.r2_keys or self.stream_uid):
            return
        print(f"    · cleaning up {len(self.r2_keys)} orphaned object(s)"
              f"{' + 1 Stream asset' if self.stream_uid else ''} after {reason}")
        for bucket, key in reversed(self.r2_keys):
            r2.delete_object(bucket, key)
        if self.stream_uid and SETTINGS.has_stream:
            stream.delete(self.stream_uid)


# ── Cloudflare Stream registration ────────────────────────────────────────────

def _register_stream(video_key: str, listing_id: str, render_id: str,
                     local_mp4: str | None = None) -> str | None:
    """Register the R2 mp4 to Stream. copy-from-URL first, direct upload second.

    `direct_upload` used to be dead code that the README described as the
    fallback (audit F-G-17). It is now actually wired: when Cloudflare cannot
    reach the presigned R2 url, we push the bytes ourselves. Stream stays
    optional — if both routes fail, the tour publishes with the R2 mp4.
    """
    if not SETTINGS.has_stream:
        print("    · Stream token absent — skipping; player will use the R2 mp4 url.")
        return None
    uid: str | None = None
    try:
        src = r2.presigned_get_url(SETTINGS.r2_bucket_renders, video_key)
        uid = stream.copy_from_url(src, name=f"{listing_id}/{render_id}",
                                   meta={"listing_id": listing_id, "render_id": render_id})
        print(f"    ✓ Stream registered uid={uid}")
    except Exception as e:  # noqa: BLE001 — Stream is optional
        print(f"    ⚠ Stream copy-from-URL failed: {e}")
        if local_mp4 and os.path.exists(local_mp4):
            try:
                uid = stream.direct_upload(local_mp4, name=f"{render_id}.mp4")
                print(f"    ✓ Stream direct upload succeeded uid={uid}")
            except Exception as e2:  # noqa: BLE001
                print(f"    ⚠ Stream direct upload also failed (continuing with R2 mp4): {e2}")
                return None
        else:
            return None

    if uid and SETTINGS.stream_require_ready:
        try:
            pb = stream.playback_urls(stream.poll_ready(uid))
            print(f"    ✓ Stream ready hls={pb.get('hls')}")
        except Exception as e:  # noqa: BLE001
            # Registration succeeded; only the readiness poll gave up. The UID
            # is real and Stream keeps transcoding — keep it rather than
            # orphaning a billed asset (the player uses the R2 mp4 first anyway).
            print(f"    ⚠ Stream readiness poll failed (keeping uid={uid}; "
                  f"player falls back to R2 mp4): {e}")
    return uid


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


# ── resource guards ───────────────────────────────────────────────────────────

MIN_FREE_DISK_FACTOR = max(1.2, float(os.environ.get("MIN_FREE_DISK_FACTOR", "2.5") or 2.5))


def _check_free_space(workdir: str, source_bytes) -> None:
    """Refuse the job when the source + its all-intra output won't fit.

    Uploads are capped at 12 GB and the all-intra output is itself multi-GB. On a
    host whose /tmp is in memory (Cloud Run) that is an OOM kill, which — before
    the lease — orphaned the job at `processing` forever (audit F-G-18/F-G-05).
    A clear, retryable failure beats a silent kill.
    """
    try:
        need = float(source_bytes or 0) * MIN_FREE_DISK_FACTOR
    except (TypeError, ValueError):
        return
    if need <= 0:
        return                     # asset row has no size — nothing to check against
    try:
        free = shutil.disk_usage(workdir).free
    except OSError:
        return
    if free < need:
        raise RuntimeError(
            f"not enough scratch space in {workdir}: {free / 1e9:.1f} GB free, need "
            f"~{need / 1e9:.1f} GB ({MIN_FREE_DISK_FACTOR:g}x the {float(source_bytes) / 1e9:.1f} GB "
            f"source for the download plus the all-intra output). Give the worker a "
            f"disk-backed volume or a larger instance."
        )


# ── the job ───────────────────────────────────────────────────────────────────

def process_job(job: dict) -> None:
    job_id = job["id"]
    listing_id = job.get("listing_id")
    asset_id = job.get("capture_asset_id")
    enhancements = job.get("enhancements") or {}
    workdir = os.path.join(SETTINGS.workdir, job_id)
    os.makedirs(workdir, exist_ok=True)

    print(f"\n=== job {job_id} (listing={listing_id} asset={asset_id} "
          f"tier={job.get('tier')} enhancements={enhancements}) ===")

    # The abort latch is process-wide and is set by BOTH a shutdown signal and a
    # lost lease. Clear it before a new job or the previous job's abort would
    # instantly kill this one — but never clear it while we are shutting down.
    if not _STOP:
        ffmpeg_render.clear_abort()

    with _Heartbeat(job_id) as hb:
        _process_job_inner(job, job_id, listing_id, asset_id, enhancements, workdir, hb)


def _process_job_inner(job: dict, job_id: str, listing_id, asset_id, enhancements: dict,
                       workdir: str, hb: "_Heartbeat") -> None:
    step = "load"
    artifacts = _Artifacts()
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
        _check_free_space(workdir, asset.get("bytes"))
        local_in = os.path.join(workdir, "capture" + os.path.splitext(storage_key)[1])
        r2.download_file(SETTINGS.r2_bucket_uploads, storage_key, local_in)
        print(f"    ✓ downloaded r2://{SETTINGS.r2_bucket_uploads}/{storage_key}")

        # 3. ffmpeg render (mirror RenderEngine).
        step = "encode"
        hb.check()
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
        hb.check()          # never start PAID work on a job we no longer own
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
        artifacts.r2(SETTINGS.r2_bucket_renders, video_key)
        r2.upload_file(poster, SETTINGS.r2_bucket_renders, poster_key, "image/jpeg")
        artifacts.r2(SETTINGS.r2_bucket_renders, poster_key)
        print(f"    ✓ uploaded tour + poster → r2://{SETTINGS.r2_bucket_renders}/{video_key}")

        photo_rows: list[dict] = []
        hero_key = None
        if enh.ran:
            photo_rows, hero_key = _upload_enhancements(enh, listing_id, render_id, artifacts)

        # 6. Register to Cloudflare Stream (optional).
        step = "stream"
        db.set_progress(job_id, 0.90, "registering stream")
        stream_uid = _register_stream(video_key, listing_id, render_id, local_mp4=out_mp4)
        artifacts.stream_uid = stream_uid

        # 7. Insert the renders row (the published tour).
        step = "publish"
        hb.check()          # never publish twice
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
        }, extra={"hero_key": hero_key} if hero_key else None)
        artifacts.published = True     # everything above is now referenced
        _record_enhancement_photos(photo_rows)
        slug = render_row.get("slug")
        print(f"    ✓ published render {render_id} slug={slug} staged={enh.staged}")

        # Record what the AI pipeline actually DID, so ops (and the status
        # screen) can tell a skipped add-on from one that ran — and so
        # `renders.staged` can be driven by OUTCOME instead of the request
        # toggles (audit F-G-01 #2 / F-G-09). Needs migration 0016; without it
        # this logs one warning per job and changes nothing else.
        db.set_enhancement_result(job_id, {
            "ran": bool(enh.ran),
            "staged": bool(enh.staged),
            "reason": enh.reason,
            "spent_cents": round(float(enh.spent_cents or 0), 4),
            "stills": len(enh.stills),
            "hero_key": hero_key,
            "segments": [
                {"name": seg.get("name"), "status": seg.get("status"),
                 "reason": seg.get("reason")}
                for seg in (enh.manifest.get("segments") or [])
            ],
            "ts": db.now_iso(),
        })

        # 8. Stream storage cost + final rollup.
        #    Only when Stream actually holds the asset: with no token (or a failed
        #    copy) `stream_uid` is None and there is nothing stored, so booking a
        #    storage line inflated COGS for every job (audit F-G-17).
        if stream_uid:
            sl = infra_costs.stream_store_line(duration_s, stream_uid=stream_uid)
            db.record_cost(feature=sl.feature, provider=sl.provider, model=sl.model,
                           units=sl.units, unit_cost_cents=sl.unit_cost_cents,
                           total_cents=sl.total_cents, job_id=job_id, org_id=org_id, meta=sl.meta)
        db.rollup_job_best_effort(job_id)
        db.flush_cost_spool()          # opportunistic: retire any spooled rows

        # 9. Flip the listing to ready + finish the job.
        db.set_listing_status(listing_id, "ready")
        db.finish_job(job_id)
        print(f"=== job {job_id} READY → /f/{slug} ===")

    except LeaseLost as e:
        # Another worker owns the job now. Touch NOTHING — not even to fail it.
        print(f"    ↩ job {job_id} abandoned at step '{step}': {e}")
        # Do NOT roll back: the worker that owns the job now may be using or
        # about to reference these very objects.
    except ffmpeg_render.RenderAborted as e:
        # Shutdown, not failure: hand the job back so the next worker retries it.
        print(f"    ↩ job {job_id} aborted at step '{step}': {e} — re-queueing")
        db.release_job(job_id, f"worker shutdown during {step}")
        artifacts.rollback("shutdown")
    except Exception as e:  # noqa: BLE001 — any failure marks the job failed
        print(f"    ✗ job {job_id} failed at step '{step}': {e}")
        traceback.print_exc()
        db.fail_job(job_id, {
            "message": str(e),
            "step": step,
            "type": e.__class__.__name__,
            "ts": db.now_iso(),
        })
        artifacts.rollback("failure")
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


# ── loop / entrypoints ────────────────────────────────────────────────────────

def _sweep_stale_workdirs() -> None:
    """Delete per-job scratch dirs left behind by a SIGKILL (audit F-G-21).

    `process_job` removes its own workdir in a `finally`, but a hard kill skips
    that — and a 12 GB capture plus a multi-GB all-intra output per orphan fills
    the disk (or, on an in-memory /tmp, the RAM) until the container is replaced.
    Anything older than the encode ceiling cannot belong to a live job.
    """
    root = SETTINGS.workdir
    cutoff = time.time() - max(3600, ffmpeg_render.RENDER_TIMEOUT_S)
    freed = 0
    try:
        entries = os.listdir(root)
    except OSError:
        return
    for name in entries:
        path = os.path.join(root, name)
        try:
            if not os.path.isdir(path) or os.path.getmtime(path) > cutoff:
                continue
            shutil.rmtree(path, ignore_errors=True)
            freed += 1
        except OSError:
            continue
    if freed:
        print(f"· swept {freed} stale workdir(s) from {root}")


def _preflight() -> None:
    problems = []
    if not SETTINGS.has_supabase:
        problems.append("SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY")
    if not SETTINGS.has_r2:
        problems.append("CLOUDFLARE_ACCOUNT_ID + R2_ACCESS_KEY_ID + R2_SECRET_ACCESS_KEY")
    if problems:
        sys.exit("FATAL: missing required config: " + "; ".join(problems)
                 + "\nSee services/worker/.env.example.")

    # FAIL LOUD on a mistyped AI-spend guard (audit F-G-11). These live in the
    # same .env and are read by services/pipeline; a cap that silently reverts to
    # its default is the failure mode that lets an unattended bill run away, so
    # the worker refuses to start rather than run with a guard the operator
    # believes is set.
    try:
        in_force = settings.validate_shared_guards()
    except settings.ConfigError as e:
        sys.exit(f"FATAL: bad AI-spend guard: {e}\nSee services/worker/.env.example.")

    print(f"→ worker up. schema={SETTINGS.db_schema} "
          f"stream={'on' if SETTINGS.has_stream else 'off (R2 mp4 only)'} "
          f"pipeline={SETTINGS.pipeline_dir}")
    print("  guards: " + (", ".join(in_force) if in_force else "all at defaults"))
    # Say out loud whether unrecorded spend would actually survive a restart —
    # nobody should discover that during an incident (audit F-G-07).
    print(f"  cost spool: {db.describe_cost_spool()}")
    db.flush_cost_spool()


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


REAP_INTERVAL_S = max(30.0, float(os.environ.get("REAP_INTERVAL_S", "120") or 120))


def run_loop() -> None:
    idle_logged = False
    next_reap = 0.0
    while not _STOP:
        # Reaper: fail jobs whose lease expired and whose attempts are spent, so
        # orphans stop counting against the org's 3-in-flight cap (audit F-G-05).
        # Reclaimable ones are picked up by claim_next_job itself.
        now = time.monotonic()
        if now >= next_reap:
            next_reap = now + REAP_INTERVAL_S
            try:
                db.reap_stale_jobs()
            except Exception as e:  # noqa: BLE001 — never let the reaper stop the loop
                print(f"⚠ reaper error (continuing): {e}")
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
    _sweep_stale_workdirs()
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
