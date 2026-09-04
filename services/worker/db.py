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

from datetime import datetime, timezone

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


def claim_next_job(max_attempts: int = 3) -> dict | None:
    """Grab one queued job and flip it to `processing`. Returns it, or None."""
    statuses = ",".join(SETTINGS.claim_statuses)
    for _ in range(max_attempts):
        candidates = select(
            "render_jobs",
            {"status": f"in.({statuses})", "order": "created_at.asc",
             "select": _CLAIM_SELECT, **_CLAIM_FILTERS},
            limit=1,
        )
        if not candidates:
            return None
        job = candidates[0]
        claimed = patch(
            "render_jobs",
            {"id": f"eq.{job['id']}", "status": f"in.({statuses})"},
            {"status": "processing", "started_at": now_iso(),
             "current_step": "claimed", "progress": 0.02, "error": None},
            prefer="return=representation",
        )
        if claimed:                      # we won the race
            return claimed[0]
        # else: contended — another worker took it; try the next candidate.
    return None


def release_job(job_id: str, note: str) -> None:
    """Hand a claimed job back (status → queued) WITHOUT failing it.

    Used when the worker discovers the job isn't its to render (asset in the
    renders bucket, upload unfinished). Conditional on `processing` so a job
    another actor already finished is never touched. The note goes in
    `current_step` (visible to ops); `error` stays null — this is not a failure.
    """
    try:
        patch("render_jobs",
              {"id": f"eq.{job_id}", "status": "eq.processing"},
              {"status": "queued", "started_at": None, "progress": 0,
               "current_step": f"skipped: {note}"[:200], "error": None})
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

def insert_render(row: dict, *, slug_retries: int = 5) -> dict:
    """Insert a renders row; on a collision, do the right thing per constraint.

    Two unique constraints can fire (audit F-G-14 — they used to be conflated):
      • `renders_slug_key`  — the random slug collided → regenerate and retry;
      • `uq_renders_job`    — this job ALREADY has a renders row (a re-run of a
        job that published before) → replace that row's media keys in place
        (same slug, so the share link the customer already has keeps working)
        instead of burning five slug retries and orphaning the fresh uploads.
    """
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

def record_cost(*, feature: str, provider: str, model: str | None, units: float,
                unit_cost_cents: float, total_cents: float,
                job_id: str | None, org_id: str | None, meta: dict | None = None) -> None:
    """Write one cost_ledger row and roll it up onto render_jobs.cost_cents."""
    row = {
        "job_id": job_id, "org_id": org_id, "feature": feature, "provider": provider,
        "model": model, "units": round(float(units), 4),
        "unit_cost_cents": round(float(unit_cost_cents), 6),
        "total_cents": round(float(total_cents), 4), "meta": meta or {},
    }
    # FAIL CLOSED (audit round 4). Provider spend that isn't recorded can't be
    # capped or billed, so an unavailable ledger used to mean unlimited
    # untracked spend. Retry briefly, then raise — the caller fails the job
    # rather than continuing to burn money off-ledger.
    last: Exception | None = None
    for attempt in range(3):
        try:
            insert("cost_ledger", row, prefer="return=minimal")
            if job_id:
                rollup_job(job_id)
            return
        except DBError as e:
            last = e
            print(f"    ⚠ cost_ledger write failed (attempt {attempt + 1}/3): {e}")
            time.sleep(1.5 * (attempt + 1))
    raise DBError(
        f"cost ledger unavailable after 3 attempts — refusing to continue "
        f"unmetered provider spend for job {job_id}: {last}"
    )


def job_total_cents(job_id: str) -> float:
    rows = select("cost_ledger", {"job_id": f"eq.{job_id}", "select": "total_cents"})
    return round(sum(float(r.get("total_cents", 0) or 0) for r in rows), 4)


def rollup_job(job_id: str) -> None:
    """render_jobs.cost_cents = round(SUM(cost_ledger.total_cents)) — race-safe."""
    total = job_total_cents(job_id)
    patch("render_jobs", {"id": f"eq.{job_id}"}, {"cost_cents": int(round(total))})
