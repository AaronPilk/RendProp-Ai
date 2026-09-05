#!/usr/bin/env python3
"""
Supabase (PostgREST) client for the render worker — service role.

Schema: the dedicated RendProp project keeps the tables in **`public`**
(`SUPABASE_DB_SCHEMA`, see settings.py). Every REST call carries
`Accept-Profile` (reads) and `Content-Profile` (writes) set to that schema so a
deliberately isolated schema is a one-line change. Both are sent on every
request — the one that doesn't apply is ignored — so there's a single code path.

Auth: PostgREST needs BOTH `apikey` and `Authorization: Bearer` set to the
service-role key (never shipped to the app — BACKEND-ARCHITECTURE.md §4).

Errors: EVERY failure surfaces as `DBError` — HTTP status errors AND transport
errors (`requests.RequestException`: DNS, connect/read timeout, reset). Callers
that treat a write as advisory (`set_progress`, `fail_job`, …) catch `DBError`;
before this a dropped connection during a progress PATCH unwound the whole
encode (audit F-G-06).

Job claiming is a lock-free optimistic update: SELECT one queued job, then PATCH
it filtered on `id=eq.<id>&status=in.(created,queued)`. If another worker already
flipped it to `processing`, the filter matches zero rows and we lose the race
cleanly — no double-processing without needing SELECT … FOR UPDATE.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import os
import socket
import sys
import time

import requests

from settings import SETTINGS
from slugs import new_slug


class DBError(RuntimeError):
    """Any Supabase/PostgREST failure (HTTP status or network transport)."""


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _url(table: str) -> str:
    return f"{SETTINGS.supabase_url}/rest/v1/{table}"


def _headers(prefer: str | None = None) -> dict:
    key = SETTINGS.supabase_service_role_key
    h = {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
        "Accept-Profile": SETTINGS.db_schema,   # reads
        "Content-Profile": SETTINGS.db_schema,  # writes
    }
    if prefer:
        h["Prefer"] = prefer
    return h


def _check(resp: requests.Response) -> None:
    if not resp.ok:
        raise DBError(f"PostgREST HTTP {resp.status_code} {resp.request.method} "
                      f"{resp.url}: {resp.text[:600]}")


def _json(resp: requests.Response):
    if resp.status_code == 204 or not resp.text:
        return []
    try:
        return resp.json()
    except ValueError:
        return []


def _request(method: str, table: str, **kw) -> requests.Response:
    """One place that talks HTTP. Maps transport failures onto DBError."""
    kw.setdefault("timeout", 30)
    try:
        return requests.request(method, _url(table), **kw)
    except requests.RequestException as e:
        raise DBError(f"network: {method} {table}: {e.__class__.__name__}: {e}") from e


# ── generic verbs ─────────────────────────────────────────────────────────────

def select(table: str, params: dict, *, limit: int | None = None) -> list:
    p = dict(params)
    if limit is not None:
        p["limit"] = limit
    r = _request("GET", table, headers=_headers(), params=p)
    _check(r)
    out = _json(r)
    return out if isinstance(out, list) else [out]


def insert(table: str, row: dict, *, prefer: str = "return=representation") -> list:
    r = _request("POST", table, headers=_headers(prefer), json=row)
    _check(r)
    return _json(r)


def patch(table: str, filters: dict, values: dict, *, prefer: str = "return=minimal") -> list:
    r = _request("PATCH", table, headers=_headers(prefer), params=filters, json=values)
    _check(r)
    return _json(r)


# ── job lifecycle ─────────────────────────────────────────────────────────────

# Only jobs whose capture asset is a finished upload in the private uploads
# bucket are the worker's to render. App-published assets live in the public
# `renders` bucket (already rendered on-device and published by
# /renders/publish-app): claiming one 404s on download and would then stamp a
# WORKING tour "failed" (audit F-G-13). The embedded-resource filter needs the
# render_jobs.capture_asset_id → capture_assets FK, which 0001_init.sql defines.
_CLAIM_SELECT = "*,capture_assets!inner(bucket,uploaded,kind)"
_CLAIM_FILTERS = {
    # Migration 0011: app-published jobs carry source='app' (created → ready in
    # the same request, or 'failed'); they are never the worker's to claim.
    "source": "eq.worker",
    "capture_assets.bucket": "eq.uploads",
    "capture_assets.uploaded": "is.true",
    "capture_assets.kind": "eq.video",
}


# ── lease / heartbeat / reaper (audit F-G-05) ────────────────────────────────
#
# Without a lease, ANY hard death (OOM, SIGKILL past the orchestrator's grace
# period, a Modal/Cloud Run timeout, a silently hung ffmpeg) leaves the job at
# status='processing' forever. Nothing re-queues it, the app polls a job that
# never finishes, and after three such orphans `create_render_job` raises RP429
# for every future publish in that org — permanently, until someone edits rows
# by hand.
#
# The lease is a wall-clock deadline on the claim. The owning worker refreshes it
# from a heartbeat thread; if the worker dies the deadline passes and the job is
# reclaimable. `attempts` bounds the retries so a poison input can't loop.
#
# The three columns (lease_expires_at, attempts, worker_id) need migration 0015 —
# see HANDOFF.md; this worktree does not own services/supabase. Until it is
# applied the worker DETECTS their absence once and runs exactly as before, with
# a loud warning, rather than 400-ing on every claim.

LEASE_SECONDS = max(60, int(os.environ.get("WORKER_LEASE_S", "600") or 600))
HEARTBEAT_SECONDS = max(10, min(int(os.environ.get("WORKER_HEARTBEAT_S", "60") or 60),
                                LEASE_SECONDS // 3))
MAX_JOB_ATTEMPTS = max(1, int(os.environ.get("WORKER_MAX_ATTEMPTS", "3") or 3))
WORKER_ID = os.environ.get("WORKER_ID") or f"{socket.gethostname()}:{os.getpid()}"

_LEASE_SUPPORTED: bool | None = None       # None = not probed yet


def _looks_like_missing_column(err: Exception) -> bool:
    m = str(err).lower()
    return ("42703" in m or "does not exist" in m or "unknown column" in m
            or "pgrst100" in m or "pgrst204" in m)


def lease_supported() -> bool:
    """Probe ONCE whether migration 0015's lease columns exist.

    A definite schema error latches the answer to False; a transient network or
    5xx failure does NOT (that would silently disable stuck-job recovery for the
    life of the process because Supabase blinked at startup).
    """
    global _LEASE_SUPPORTED
    if _LEASE_SUPPORTED is not None:
        return _LEASE_SUPPORTED
    try:
        select("render_jobs", {"select": "id,lease_expires_at,attempts,worker_id"}, limit=1)
        _LEASE_SUPPORTED = True
        print(f"    · job lease active: {LEASE_SECONDS}s, heartbeat {HEARTBEAT_SECONDS}s, "
              f"max {MAX_JOB_ATTEMPTS} attempts, worker_id={WORKER_ID}")
    except DBError as e:
        if _looks_like_missing_column(e):
            _LEASE_SUPPORTED = False
            print("    ⚠ render_jobs has no lease_expires_at/attempts/worker_id "
                  "(migration 0015 not applied) — NO stuck-job recovery: a worker that "
                  "dies mid-render leaves its job 'processing' forever. See HANDOFF.md.")
        else:
            print(f"    ⚠ could not probe for lease columns ({e}); will retry next claim")
            return False           # not latched — try again next time
    return bool(_LEASE_SUPPORTED)


def _lease_until(seconds: int | None = None) -> str:
    return (datetime.now(timezone.utc)
            + timedelta(seconds=seconds or LEASE_SECONDS)).isoformat()


def _claim_values(attempts: int | None) -> dict:
    values = {"status": "processing", "started_at": now_iso(),
              "current_step": "claimed", "progress": 0.02, "error": None}
    if lease_supported():
        values["lease_expires_at"] = _lease_until()
        values["worker_id"] = WORKER_ID
        values["attempts"] = int(attempts or 0) + 1
    return values


def claim_next_job(max_attempts: int = 3) -> dict | None:
    """Grab one claimable job and flip it to `processing`. Returns it, or None.

    Two candidate sources, in order:
      1. fresh work — status in (created, queued);
      2. RECLAIM — status='processing' whose lease has expired and whose
         `attempts` is still under the ceiling (its worker died).
    """
    statuses = ",".join(SETTINGS.claim_statuses)
    for _ in range(max_attempts):
        job = _next_candidate(statuses)
        if not job:
            return None
        # The condition is part of the UPDATE, so exactly one worker wins.
        # For a RECLAIM the condition must include "the lease is still expired",
        # not just status=processing: between our SELECT and this PATCH the
        # original owner may have come back and renewed. Without the
        # lease_expires_at filter we would steal a LIVE job and publish the same
        # tour twice.
        if job.get("_reclaim"):
            filters = {"id": f"eq.{job['id']}", "status": "eq.processing",
                       "lease_expires_at": f"lt.{now_iso()}"}
        else:
            filters = {"id": f"eq.{job['id']}", "status": f"in.({statuses})"}
        claimed = patch(
            "render_jobs", filters, _claim_values(job.get("attempts")),
            prefer="return=representation",
        )
        if claimed:                      # we won the race
            if job.get("_reclaim"):
                print(f"    ↻ reclaimed orphaned job {job['id']} "
                      f"(attempt {claimed[0].get('attempts')}/{MAX_JOB_ATTEMPTS}) — "
                      f"its previous worker ({job.get('worker_id')}) died mid-render")
            return claimed[0]
        # else: contended — another worker took it; try the next candidate.
    return None


def _next_candidate(statuses: str) -> dict | None:
    fresh = select(
        "render_jobs",
        {"status": f"in.({statuses})", "order": "created_at.asc",
         "select": _CLAIM_SELECT, **_CLAIM_FILTERS},
        limit=1,
    )
    if fresh:
        return fresh[0]
    if not lease_supported():
        return None
    stale = select(
        "render_jobs",
        {"status": "eq.processing", "lease_expires_at": f"lt.{now_iso()}",
         "attempts": f"lt.{MAX_JOB_ATTEMPTS}", "order": "created_at.asc",
         "select": _CLAIM_SELECT, **_CLAIM_FILTERS},
        limit=1,
    )
    if stale:
        return {**stale[0], "_reclaim": True}
    return None


def heartbeat(job_id: str) -> bool:
    """Extend this job's lease. False = we no longer own it (stop working).

    A zero-row result means the job is no longer `processing` under OUR
    worker_id — someone reaped or reclaimed it — so continuing would publish the
    same tour twice and bill it twice.
    """
    if not lease_supported():
        return True
    try:
        rows = patch("render_jobs",
                     {"id": f"eq.{job_id}", "status": "eq.processing",
                      "worker_id": f"eq.{WORKER_ID}"},
                     {"lease_expires_at": _lease_until()},
                     prefer="return=representation")
        return bool(rows)
    except DBError as e:
        # A blip must not drop the job — the lease still has time on it.
        print(f"    ⚠ heartbeat failed (lease still valid for now): {e}")
        return True


def reap_stale_jobs(limit: int = 20) -> int:
    """Fail jobs whose lease expired and whose attempts are exhausted (poison).

    Jobs still under the attempt ceiling are left alone: `claim_next_job`
    reclaims them. Returns how many were marked failed. Never raises.
    """
    if not lease_supported():
        return 0
    try:
        rows = select("render_jobs",
                      {"status": "eq.processing", "lease_expires_at": f"lt.{now_iso()}",
                       "attempts": f"gte.{MAX_JOB_ATTEMPTS}",
                       "select": "id,attempts,worker_id"},
                      limit=limit)
    except DBError as e:
        print(f"    ⚠ reaper query failed (continuing): {e}")
        return 0
    reaped = 0
    for row in rows:
        try:
            done = patch("render_jobs",
                         {"id": f"eq.{row['id']}", "status": "eq.processing"},
                         {"status": "failed", "current_step": "failed",
                          "finished_at": now_iso(),
                          "error": {"type": "poison", "step": "reaper",
                                    "message": (f"lease expired {row.get('attempts')} time(s); "
                                                f"giving up after {MAX_JOB_ATTEMPTS} attempts"),
                                    "last_worker": row.get("worker_id"), "ts": now_iso()}},
                         prefer="return=representation")
            if done:
                reaped += 1
                print(f"    ☠ reaped poison job {row['id']} after {MAX_JOB_ATTEMPTS} attempts")
        except DBError as e:
            print(f"    ⚠ could not reap job {row['id']}: {e}")
    return reaped


def release_job(job_id: str, note: str) -> None:
    """Hand a claimed job back (status → queued) WITHOUT failing it.

    Used when the worker discovers the job isn't its to render (asset in the
    renders bucket, upload unfinished) AND on graceful shutdown, so a SIGTERM
    mid-encode re-queues the job instead of orphaning it in `processing`
    (audit F-G-05). Conditional on `processing` so a job another actor already
    finished is never touched. The note goes in `current_step` (visible to ops);
    `error` stays null — this is not a failure.
    """
    values = {"status": "queued", "started_at": None, "progress": 0,
              "current_step": f"skipped: {note}"[:200], "error": None}
    if lease_supported():
        # Drop the lease with the claim so a reaper/reclaim never has to wait it out.
        values["lease_expires_at"] = None
        values["worker_id"] = None
    try:
        patch("render_jobs", {"id": f"eq.{job_id}", "status": "eq.processing"}, values)
    except DBError as e:
        print(f"    ⚠ could not release job {job_id}: {e}")


def set_progress(job_id: str, progress: float, step: str | None = None) -> None:
    values: dict = {"progress": round(max(0.0, min(1.0, progress)), 3)}
    if step:
        values["current_step"] = step
    try:
        patch("render_jobs", {"id": f"eq.{job_id}"}, values)
    except DBError as e:
        # Progress is advisory — never let it kill a render.
        print(f"    ⚠ progress update failed (continuing): {e}")


def finish_job(job_id: str) -> None:
    patch("render_jobs", {"id": f"eq.{job_id}"},
          {"status": "ready", "progress": 1.0, "current_step": "ready",
           "finished_at": now_iso(), "error": None})


def fail_job(job_id: str, error: dict) -> None:
    """Mark the job failed — but ONLY while it is still `processing`.

    The filter is part of the UPDATE so a job that another actor already moved
    on (e.g. `/renders/publish-app` published it → `ready`) is never overwritten
    with `failed` (audit F-G-13). Zero matched rows is logged, not an error.
    """
    try:
        rows = patch("render_jobs",
                     {"id": f"eq.{job_id}", "status": "eq.processing"},
                     {"status": "failed", "current_step": "failed",
                      "error": error, "finished_at": now_iso()},
                     prefer="return=representation")
        if not rows:
            print(f"    · job {job_id} was no longer 'processing' — left its status untouched")
    except DBError as e:
        print(f"    ⚠ could not mark job failed: {e}")


# ── related rows ──────────────────────────────────────────────────────────────

def fetch_listing(listing_id: str) -> dict | None:
    rows = select("listings",
                  {"id": f"eq.{listing_id}", "select": "id,org_id,space_type,status"})
    return rows[0] if rows else None


def fetch_asset(asset_id: str) -> dict | None:
    rows = select("capture_assets",
                  {"id": f"eq.{asset_id}",
                   "select": "id,listing_id,storage_key,duration_s,fps,width,height,"
                             "codec,is_drone,has_gyro,kind,bytes,bucket,uploaded"})
    return rows[0] if rows else None


def fetch_chapters(asset_id: str) -> list:
    """capture_chapters for an asset, ordered → pipeline segmentation input."""
    return select("capture_chapters",
                  {"asset_id": f"eq.{asset_id}", "order": "sort.asc,t_ms.asc",
                   "select": "label,t_ms,sort"})


def set_listing_status(listing_id: str, status: str) -> None:
    try:
        patch("listings", {"id": f"eq.{listing_id}"}, {"status": status})
    except DBError as e:
        print(f"    ⚠ listing status update failed (continuing): {e}")


# ── renders + photos ──────────────────────────────────────────────────────────

def set_enhancement_result(job_id: str, result: dict) -> bool:
    """Persist what the AI pipeline actually did, on `render_jobs`.

    Needs `render_jobs.enhancement_result jsonb` (migration 0016 — HANDOFF.md).
    Best-effort and column-optional: without it the worker warns ONCE and the
    tour publishes exactly as before. Never raises.
    """
    global _ENH_RESULT_SUPPORTED
    if _ENH_RESULT_SUPPORTED is False:
        return False
    try:
        patch("render_jobs", {"id": f"eq.{job_id}"}, {"enhancement_result": result})
        _ENH_RESULT_SUPPORTED = True
        return True
    except DBError as e:
        if _looks_like_missing_column(e):
            if _ENH_RESULT_SUPPORTED is None:
                print("    ⚠ render_jobs has no enhancement_result column (migration 0016 "
                      "not applied) — the add-on outcome/skip reason stays in the log only. "
                      "See HANDOFF.md.")
            _ENH_RESULT_SUPPORTED = False
        else:
            print(f"    ⚠ could not record enhancement_result (continuing): {e}")
        return False


_ENH_RESULT_SUPPORTED: bool | None = None
_RENDER_EXTRA_SUPPORTED: bool | None = None


def insert_render(row: dict, *, slug_retries: int = 5, extra: dict | None = None) -> dict:
    """Insert a renders row; on a collision, do the right thing per constraint.

    Two unique constraints can fire (audit F-G-14 — they used to be conflated):
      • `renders_slug_key`  — the random slug collided → regenerate and retry;
      • `uq_renders_job`    — this job ALREADY has a renders row (a re-run of a
        job that published before) → replace that row's media keys in place
        (same slug, so the share link the customer already has keeps working)
        instead of burning five slug retries and orphaning the fresh uploads.
    """
    # `extra` carries columns that only exist after a later migration (today:
    # renders.hero_key, migration 0016). Try WITH them once; on a missing-column
    # error drop them and insert the core row — a hero clip must never cost the
    # customer their tour.
    global _RENDER_EXTRA_SUPPORTED
    if extra and _RENDER_EXTRA_SUPPORTED is not False:
        try:
            out = insert("renders", {**row, **extra}, prefer="return=representation")
            if out:
                _RENDER_EXTRA_SUPPORTED = True
                return out[0]
        except DBError as e:
            if _looks_like_missing_column(e):
                if _RENDER_EXTRA_SUPPORTED is None:
                    print(f"    ⚠ renders has no {sorted(extra)} column(s) (migration 0016 "
                          f"not applied) — publishing without them. See HANDOFF.md.")
                _RENDER_EXTRA_SUPPORTED = False
            elif not ("409" in str(e).lower() or "duplicate key" in str(e).lower()
                      or "23505" in str(e)):
                raise
            # duplicate → fall through to the normal retry/replace path below

    for attempt in range(slug_retries):
        try:
            out = insert("renders", row, prefer="return=representation")
            if out:
                return out[0]
            raise DBError("insert renders returned no row")
        except DBError as e:
            msg = str(e).lower()
            is_dup = "409" in msg or "duplicate key" in msg or "23505" in msg
            if not is_dup:
                raise
            if "uq_renders_job" in msg or ("job_id" in msg and "slug" not in msg):
                existing = _replace_render_for_job(row)
                if existing:
                    return existing
                raise
            # Otherwise (renders_slug_key, or an ambiguous message): new slug.
            row = {**row, "slug": new_slug()}
    raise DBError(f"could not insert render after {slug_retries} slug attempts")


def _replace_render_for_job(row: dict) -> dict | None:
    """PATCH the existing renders row for row['job_id'] with the new media."""
    job_id = row.get("job_id")
    if not job_id:
        return None
    values = {k: v for k, v in row.items() if k not in ("id", "job_id", "listing_id", "slug")}
    out = patch("renders", {"job_id": f"eq.{job_id}"}, values, prefer="return=representation")
    if out:
        print(f"    · job {job_id} already had a renders row — replaced its media in place "
              f"(slug {out[0].get('slug')} unchanged)")
        return out[0]
    return None


def insert_photo(row: dict) -> None:
    """Best-effort insert of an enhanced/staged listing photo."""
    try:
        insert("photos", row, prefer="return=minimal")
    except DBError as e:
        print(f"    ⚠ photo row insert failed (continuing): {e}")


# ── cost ledger ───────────────────────────────────────────────────────────────
#
# POLICY (audit F-G-07 — this was inverted).
#
# Everything the WORKER meters is an ESTIMATE: `render` is a configurable
# cents-per-output-minute guess at encode compute, `stream_store` is a Cloudflare
# storage projection. Neither is money that has already left an account. The old
# code failed CLOSED on them: a Supabase blip after a 60-minute encode raised,
# `process_job` caught it, and the customer lost a finished tour over a
# bookkeeping line. That trade is backwards.
#
# So worker lines are BEST-EFFORT: bounded retries, then the row goes to the
# durable spool (`cost_spool`) to be reconciled later, and the render publishes.
# Nothing is silently dropped — every failure is spooled and alarmed.
#
# REAL provider spend is metered by services/pipeline/cost_ledger.py, which fails
# CLOSED in the way that matters: it retries, spools, and then stops the job from
# making further paid calls it could not record.

LEDGER_RETRY_ATTEMPTS = 3
LEDGER_RETRY_BACKOFF_S = (0.5, 2.0, 5.0)


def _load_cost_spool():
    """The spool lives in services/pipeline (shared with the AI ledger).

    Imported defensively: a worker whose pipeline dir is missing must still run
    (it just can't spool), and this module is imported before enhance_bridge puts
    the pipeline on sys.path.
    """
    try:
        pdir = SETTINGS.pipeline_dir
        if pdir and pdir not in sys.path:
            sys.path.append(pdir)
        import cost_spool  # type: ignore
        return cost_spool
    except Exception as e:  # noqa: BLE001
        print(f"    ⚠ cost spool unavailable ({e}) — unrecorded infra estimates "
              f"will only appear in the log")
        return None


_SPOOL = _load_cost_spool()


def _insert_cost_row(row: dict) -> None:
    insert("cost_ledger", row, prefer="return=minimal")


def record_cost(*, feature: str, provider: str, model: str | None, units: float,
                unit_cost_cents: float, total_cents: float,
                job_id: str | None, org_id: str | None,
                meta: dict | None = None) -> bool:
    """Best-effort cost_ledger row for a worker INFRA ESTIMATE. Never raises.

    Returns True when the row reached the database. On failure the row is
    spooled for reconciliation and an alarm is logged — the render continues.
    """
    row = {
        "job_id": job_id, "org_id": org_id, "feature": feature, "provider": provider,
        "model": model, "units": round(float(units), 4),
        "unit_cost_cents": round(float(unit_cost_cents), 6),
        "total_cents": round(float(total_cents), 4), "meta": meta or {},
    }
    last: Exception | None = None
    for attempt in range(LEDGER_RETRY_ATTEMPTS):
        try:
            _insert_cost_row(row)
            # Rollup is retried SEPARATELY and OUTSIDE this loop. rollup_job()
            # raises DBError of its own; leaving it inside the try meant a
            # failing rollup re-drove the loop and inserted the SAME ledger row
            # again — up to LEDGER_RETRY_ATTEMPTS times. render_jobs.cost_cents
            # then read 2-3x the real spend and pushed the org toward its
            # monthly COGS ceiling on money nobody spent.
            if job_id:
                rollup_job_best_effort(job_id)
            return True
        except DBError as e:
            last = e
            print(f"    ⚠ cost_ledger write failed for infra estimate "
                  f"{feature} (attempt {attempt + 1}/{LEDGER_RETRY_ATTEMPTS}): {e}")
            if attempt < LEDGER_RETRY_ATTEMPTS - 1:
                time.sleep(LEDGER_RETRY_BACKOFF_S[attempt])

    spooled = bool(_SPOOL and _SPOOL.append(row, source="worker", error=str(last),
                                            attempts=LEDGER_RETRY_ATTEMPTS))
    print(f"    ⚠ ALARM infra estimate {feature} ({row['total_cents']:.4f}¢) not recorded "
          f"after {LEDGER_RETRY_ATTEMPTS} attempts — "
          f"{'spooled for reconciliation' if spooled else 'NOT spooled (log only)'}. "
          f"The render continues: an estimate never kills a customer's tour.")
    return False


def flush_cost_spool(limit: int = 200) -> tuple[int, int]:
    """Re-try spooled cost rows (worker AND pipeline). Never raises."""
    if not _SPOOL:
        return 0, 0
    try:
        return _SPOOL.flush(_insert_cost_row, limit=limit)
    except Exception as e:  # noqa: BLE001
        print(f"    ⚠ cost spool flush failed (continuing): {e}")
        return 0, _SPOOL.pending_count()


def describe_cost_spool() -> str:
    return _SPOOL.describe() if _SPOOL else "unavailable"


def job_total_cents(job_id: str) -> float:
    rows = select("cost_ledger", {"job_id": f"eq.{job_id}", "select": "total_cents"})
    return round(sum(float(r.get("total_cents", 0) or 0) for r in rows), 4)


def rollup_job(job_id: str) -> None:
    """render_jobs.cost_cents = round(SUM(cost_ledger.total_cents)) — race-safe."""
    total = job_total_cents(job_id)
    patch("render_jobs", {"id": f"eq.{job_id}"}, {"cost_cents": int(round(total))})


def rollup_job_best_effort(job_id: str) -> None:
    try:
        rollup_job(job_id)
    except DBError as e:
        print(f"    ⚠ cost rollup failed (ledger rows are safe): {e}")
