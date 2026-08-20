#!/usr/bin/env python3
"""
Supabase (PostgREST) client for the render worker — service role, `rendprop`
schema.

IMPORTANT: the Rendprop tables live in a Postgres schema named **rendprop**, not
`public`. Every REST call therefore carries `Accept-Profile: rendprop` (reads)
and `Content-Profile: rendprop` (writes). We send both on every request — the one
that doesn't apply is ignored — so there's a single code path.

Auth: PostgREST needs BOTH `apikey` and `Authorization: Bearer` set to the
service-role key (never shipped to the app — BACKEND-ARCHITECTURE.md §4).

Job claiming is a lock-free optimistic update: SELECT one queued job, then PATCH
it filtered on `id=eq.<id>&status=in.(created,queued)`. If another worker already
flipped it to `processing`, the filter matches zero rows and we lose the race
cleanly — no double-processing without needing SELECT … FOR UPDATE.
"""

from __future__ import annotations

from datetime import datetime, timezone

import requests

from settings import SETTINGS
from slugs import new_slug


class DBError(RuntimeError):
    """Any Supabase/PostgREST failure."""


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
        "Accept-Profile": SETTINGS.db_schema,   # reads target rendprop
        "Content-Profile": SETTINGS.db_schema,  # writes target rendprop
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


# ── generic verbs ─────────────────────────────────────────────────────────────

def select(table: str, params: dict, *, limit: int | None = None) -> list:
    p = dict(params)
    if limit is not None:
        p["limit"] = limit
    r = requests.get(_url(table), headers=_headers(), params=p, timeout=30)
    _check(r)
    out = _json(r)
    return out if isinstance(out, list) else [out]


def insert(table: str, row: dict, *, prefer: str = "return=representation") -> list:
    r = requests.post(_url(table), headers=_headers(prefer), json=row, timeout=30)
    _check(r)
    return _json(r)


def patch(table: str, filters: dict, values: dict, *, prefer: str = "return=minimal") -> list:
    r = requests.patch(_url(table), headers=_headers(prefer), params=filters, json=values, timeout=30)
    _check(r)
    return _json(r)


# ── job lifecycle ─────────────────────────────────────────────────────────────

def claim_next_job(max_attempts: int = 3) -> dict | None:
    """Grab one queued job and flip it to `processing`. Returns it, or None."""
    statuses = ",".join(SETTINGS.claim_statuses)
    for _ in range(max_attempts):
        candidates = select(
            "render_jobs",
            {"status": f"in.({statuses})", "order": "created_at.asc", "select": "*"},
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
    try:
        patch("render_jobs", {"id": f"eq.{job_id}"},
              {"status": "failed", "current_step": "failed",
               "error": error, "finished_at": now_iso()})
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
                             "codec,is_drone,has_gyro,kind,bytes"})
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
    """Insert a renders row, regenerating the slug on a unique collision."""
    for attempt in range(slug_retries):
        try:
            out = insert("renders", row, prefer="return=representation")
            if out:
                return out[0]
            raise DBError("insert renders returned no row")
        except DBError as e:
            if "409" in str(e) or "duplicate key" in str(e).lower():
                row = {**row, "slug": new_slug()}
                continue
            raise
    raise DBError(f"could not insert render after {slug_retries} slug attempts")


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
    try:
        insert("cost_ledger", row, prefer="return=minimal")
        if job_id:
            rollup_job(job_id)
    except DBError as e:
        print(f"    ⚠ cost_ledger write failed (continuing): {e}")


def job_total_cents(job_id: str) -> float:
    rows = select("cost_ledger", {"job_id": f"eq.{job_id}", "select": "total_cents"})
    return round(sum(float(r.get("total_cents", 0) or 0) for r in rows), 4)


def rollup_job(job_id: str) -> None:
    """render_jobs.cost_cents = round(SUM(cost_ledger.total_cents)) — race-safe."""
    total = job_total_cents(job_id)
    patch("render_jobs", {"id": f"eq.{job_id}"}, {"cost_cents": int(round(total))})
