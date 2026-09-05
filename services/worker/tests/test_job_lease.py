#!/usr/bin/env python3
"""
Regression tests for the claim / lease / heartbeat / reaper path (audit F-G-05,
F-G-13) against a fake PostgREST.

    python3 tests/test_job_lease.py

Stdlib only and self-contained — the repo has no Python test runner installed, so
this is a plain script that exits non-zero on the first failure.
"""

from __future__ import annotations

import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))

import fake_postgrest  # noqa: E402

FAILURES: list[str] = []


def check(label: str, cond: bool, detail: str = "") -> None:
    print(f"  {'ok  ' if cond else 'FAIL'} {label}" + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        FAILURES.append(label)


def iso(delta_s: int = 0) -> str:
    return (datetime.now(timezone.utc) + timedelta(seconds=delta_s)).isoformat()


def fresh_db(**kw) -> fake_postgrest.FakeDB:
    db = fake_postgrest.FakeDB(**kw)
    db.tables["capture_assets"] = [
        {"id": "asset-ok", "listing_id": "L1", "storage_key": "uploads/o/l/a.mov",
         "bucket": "uploads", "uploaded": True, "kind": "video", "bytes": 1000},
        {"id": "asset-app", "listing_id": "L1", "storage_key": "renders/o/l/a.mp4",
         "bucket": "renders", "uploaded": True, "kind": "video", "bytes": 1000},
    ]
    db.tables["listings"] = [{"id": "L1", "org_id": "O1", "space_type": "home",
                              "status": "processing"}]
    return db


def load_db_module(base_url: str):
    """Import services/worker/db.py fresh against a given Supabase URL."""
    for mod in ("db", "settings"):
        sys.modules.pop(mod, None)
    os.environ["SUPABASE_URL"] = base_url
    os.environ["SUPABASE_SERVICE_ROLE_KEY"] = "test-key"
    os.environ["WORKER_ID"] = "test-worker"
    os.environ["WORKER_LEASE_S"] = "600"
    os.environ["WORKER_MAX_ATTEMPTS"] = "3"
    import db as db_module  # noqa: WPS433
    return db_module


# ── 1. lease columns present ─────────────────────────────────────────────────

def test_with_lease() -> None:
    print("\n1. render_jobs HAS lease columns (migration 0015 applied)")
    fdb = fresh_db(lease_columns=True)
    server, url = fake_postgrest.start(fdb)
    try:
        db = load_db_module(url)
        fdb.tables["render_jobs"] = [
            {"id": "J1", "listing_id": "L1", "capture_asset_id": "asset-ok",
             "status": "queued", "source": "worker", "attempts": 0,
             "created_at": "2026-01-01T00:00:00Z"},
        ]
        check("lease columns detected", db.lease_supported() is True)

        job = db.claim_next_job()
        check("claims the queued job", job is not None and job["id"] == "J1")
        row = fdb.tables["render_jobs"][0]
        check("claim sets status=processing", row["status"] == "processing")
        check("claim sets a lease", bool(row.get("lease_expires_at")))
        check("claim stamps worker_id", row.get("worker_id") == "test-worker")
        check("claim increments attempts to 1", row.get("attempts") == 1, str(row.get("attempts")))

        nearly_expired = iso(1)                   # pretend time nearly ran out
        row["lease_expires_at"] = nearly_expired
        check("heartbeat renews the lease", db.heartbeat("J1") is True)
        renewed = fdb.tables["render_jobs"][0]["lease_expires_at"]
        check("lease actually moved forward", renewed > nearly_expired,
              f"{nearly_expired} -> {renewed}")

        # Another worker stole it: heartbeat must report the loss, not lie.
        row["worker_id"] = "somebody-else"
        check("heartbeat reports a lost lease", db.heartbeat("J1") is False)
        row["worker_id"] = "test-worker"

        # ── reclaim: the owning worker died, lease expired, attempts < max ──
        row.update(status="processing", lease_expires_at=iso(-60), attempts=1)
        reclaimed = db.claim_next_job()
        check("reclaims an expired lease", reclaimed is not None and reclaimed["id"] == "J1")
        check("reclaim increments attempts to 2", fdb.tables["render_jobs"][0]["attempts"] == 2,
              str(fdb.tables["render_jobs"][0]["attempts"]))

        # RACE: the original owner renews between our SELECT and our PATCH. The
        # reclaim must lose cleanly rather than steal a live job (double publish).
        row.update(status="processing", lease_expires_at=iso(-60), attempts=1,
                   worker_id="other-worker")
        _orig_patch = db.patch

        def _renew_then_patch(table, filters, values, **kw):
            if table == "render_jobs" and "lease_expires_at" in filters:
                row["lease_expires_at"] = iso(600)      # owner came back first
            return _orig_patch(table, filters, values, **kw)

        db.patch = _renew_then_patch
        try:
            check("reclaim LOSES to a lease renewed mid-race",
                  db.claim_next_job() is None)
            check("the live job kept its owner", row.get("worker_id") == "other-worker")
            check("attempts not incremented by the lost race", row.get("attempts") == 1,
                  str(row.get("attempts")))
        finally:
            db.patch = _orig_patch

        # ── reaper: attempts exhausted → poison, freeing the in-flight slot ──
        row.update(status="processing", lease_expires_at=iso(-60), attempts=3)
        check("reaper fails exactly one poison job", db.reap_stale_jobs() == 1)
        check("poison job is failed", row["status"] == "failed")
        check("poison error is typed", (row.get("error") or {}).get("type") == "poison",
              str(row.get("error")))

        # A live lease must be left completely alone.
        row.update(status="processing", lease_expires_at=iso(600), attempts=3, error=None)
        check("reaper leaves a LIVE lease alone", db.reap_stale_jobs() == 0)
        check("live job still processing", row["status"] == "processing")

        # release_job (shutdown / not-ours) re-queues and drops the lease.
        row.update(status="processing", worker_id="test-worker", lease_expires_at=iso(600))
        db.release_job("J1", "worker shutdown during encode")
        check("release re-queues", row["status"] == "queued")
        check("release clears the lease", row.get("lease_expires_at") is None)
        check("release does NOT set error", row.get("error") is None)
    finally:
        server.shutdown()


# ── 2. lease columns absent (pre-migration) ──────────────────────────────────

def test_without_lease() -> None:
    print("\n2. render_jobs has NO lease columns (migration 0015 not applied)")
    fdb = fresh_db(lease_columns=False)
    server, url = fake_postgrest.start(fdb)
    try:
        db = load_db_module(url)
        fdb.tables["render_jobs"] = [
            {"id": "J2", "listing_id": "L1", "capture_asset_id": "asset-ok",
             "status": "created", "source": "worker", "created_at": "2026-01-01T00:00:00Z"},
        ]
        check("lease support detected as absent", db.lease_supported() is False)
        job = db.claim_next_job()
        check("still claims normally", job is not None and job["id"] == "J2")
        row = fdb.tables["render_jobs"][0]
        check("claim wrote no lease columns",
              not any(c in row for c in fake_postgrest.LEASE_COLUMNS), str(row))
        check("heartbeat is a no-op that reports success", db.heartbeat("J2") is True)
        check("reaper is a no-op", db.reap_stale_jobs() == 0)
    finally:
        server.shutdown()


# ── 3. F-G-13: never downgrade a working tour, never claim app jobs ──────────

def test_claim_scope_and_fail_guard() -> None:
    print("\n3. claim scope + fail_job guard (F-G-13)")
    fdb = fresh_db(lease_columns=True)
    server, url = fake_postgrest.start(fdb)
    try:
        db = load_db_module(url)
        fdb.tables["render_jobs"] = [
            # app-published: source='app' AND its asset lives in the renders bucket
            {"id": "A1", "listing_id": "L1", "capture_asset_id": "asset-app",
             "status": "created", "source": "app", "attempts": 0,
             "created_at": "2026-01-01T00:00:00Z"},
        ]
        check("does NOT claim an app-published job", db.claim_next_job() is None)

        # Same asset but mislabelled source: the embedded bucket filter still saves us.
        fdb.tables["render_jobs"][0]["source"] = "worker"
        check("does NOT claim a renders-bucket asset even when source='worker'",
              db.claim_next_job() is None)

        # fail_job must never overwrite a tour that another actor published.
        fdb.tables["render_jobs"] = [
            {"id": "R1", "listing_id": "L1", "capture_asset_id": "asset-ok",
             "status": "ready", "source": "worker", "attempts": 1,
             "created_at": "2026-01-01T00:00:00Z"},
        ]
        db.fail_job("R1", {"message": "download 404", "step": "download"})
        check("fail_job leaves a READY job alone", fdb.tables["render_jobs"][0]["status"] == "ready")
        check("fail_job did not stamp an error", fdb.tables["render_jobs"][0].get("error") is None)

        fdb.tables["render_jobs"][0]["status"] = "processing"
        db.fail_job("R1", {"message": "download 404", "step": "download"})
        check("fail_job DOES fail a processing job",
              fdb.tables["render_jobs"][0]["status"] == "failed")
    finally:
        server.shutdown()


# ── 4. F-G-09: outcome persistence degrades cleanly before migration 0016 ────

def test_enhancement_result_optional() -> None:
    print("\n4. enhancement_result / hero_key are column-optional (F-G-09)")

    # (a) columns present
    fdb = fresh_db(lease_columns=True)
    server, url = fake_postgrest.start(fdb)
    try:
        db = load_db_module(url)
        fdb.tables["render_jobs"] = [{"id": "J9", "status": "processing"}]
        check("writes enhancement_result when the column exists",
              db.set_enhancement_result("J9", {"ran": True, "staged": True}) is True)
        check("value landed",
              (fdb.tables["render_jobs"][0].get("enhancement_result") or {}).get("staged") is True)
        row = db.insert_render({"id": "R9", "job_id": "J9", "listing_id": "L1",
                                "slug": "abc", "video_key": "v", "poster_key": "p"},
                               extra={"hero_key": "renders/L1/R9-hero.mp4"})
        check("hero_key persisted when the column exists",
              row.get("hero_key") == "renders/L1/R9-hero.mp4", str(row))
    finally:
        server.shutdown()

    # (b) pre-0015 database
    fdb = fresh_db(lease_columns=True, unknown_columns=("enhancement_result", "hero_key"))
    server, url = fake_postgrest.start(fdb)
    try:
        db = load_db_module(url)
        fdb.tables["render_jobs"] = [{"id": "J9", "status": "processing"}]
        check("reports False without the column",
              db.set_enhancement_result("J9", {"ran": True}) is False)
        check("job row is untouched",
              "enhancement_result" not in fdb.tables["render_jobs"][0])
        check("second call is silent and cached",
              db.set_enhancement_result("J9", {"ran": True}) is False)
        row = db.insert_render({"id": "R9", "job_id": "J9", "listing_id": "L1",
                                "slug": "abc", "video_key": "v", "poster_key": "p"},
                               extra={"hero_key": "renders/L1/R9-hero.mp4"})
        check("the TOUR still publishes without hero_key",
              row.get("id") == "R9" and "hero_key" not in row, str(row))
    finally:
        server.shutdown()


if __name__ == "__main__":
    test_with_lease()
    test_without_lease()
    test_claim_scope_and_fail_guard()
    test_enhancement_result_optional()
    print()
    if FAILURES:
        print(f"✗ {len(FAILURES)} failure(s): {FAILURES}")
        sys.exit(1)
    print("✓ all job-lease tests passed")
