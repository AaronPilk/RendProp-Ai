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


def load_db_module(base_url: str, *, worker_id: str = "test-worker"):
    """Import services/worker/db.py fresh against a given Supabase URL.

    `worker_id` lets a test simulate TWO INDEPENDENT workers against the same
    fake backend: two calls with different `worker_id`s each re-execute the
    module fresh (module-level WORKER_ID is bound at import time), returning
    two distinct module objects that never share Python-level state — only the
    fake HTTP server's table rows, exactly like two real worker processes.
    """
    for mod in ("db", "settings"):
        sys.modules.pop(mod, None)
    os.environ["SUPABASE_URL"] = base_url
    os.environ["SUPABASE_SERVICE_ROLE_KEY"] = "test-key"
    os.environ["WORKER_ID"] = worker_id
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
        # worker_id="test-worker" matches this test's `db` module (see
        # load_db_module) — a REAL job would have this set from claim_next_job;
        # test_stale_worker_cannot_mutate_reclaimed_job below covers the case
        # where it does NOT match.
        fdb.tables["render_jobs"] = [
            {"id": "R1", "listing_id": "L1", "capture_asset_id": "asset-ok",
             "status": "ready", "source": "worker", "attempts": 1, "worker_id": "test-worker",
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


# ── 4. Publication requires the transaction, without a legacy write path ───

def test_publication_requires_transaction() -> None:
    # The old optional writes were the unfenced alternate path. Actual helper
    # tests and the disposable-Postgres fixture now cover publication itself.
    print("\n4. atomic publication has no unsafe legacy helper")
    db = load_db_module("http://127.0.0.1:1")  # Structural check; no request.
    for name in ("insert_render", "_replace_render_for_job", "set_enhancement_result",
                 "set_listing_status", "finish_job", "insert_photo"):
        check(f"unsafe publication helper {name} removed", not hasattr(db, name))
    check("atomic publication helper exists", callable(db.publish_worker_render))


# ── 5. Fix 2: a stale worker must not be able to mutate a reclaimed job ─────
#      another worker reclaimed out from under it.

def test_stale_worker_cannot_mutate_reclaimed_job() -> None:
    print("\n5. a stale worker cannot progress/fail/release a job "
          "reclaimed by another worker (external release audit — Fix 2)")
    fdb = fresh_db(lease_columns=True)
    server, url = fake_postgrest.start(fdb)
    try:
        fdb.tables["render_jobs"] = [
            {"id": "J5", "listing_id": "L1", "capture_asset_id": "asset-ok",
             "status": "queued", "source": "worker", "attempts": 0,
             "created_at": "2026-01-01T00:00:00Z"},
        ]
        row = fdb.tables["render_jobs"][0]

        worker_a = load_db_module(url, worker_id="worker-a")
        job = worker_a.claim_next_job()
        check("worker A claims the job", job is not None and job.get("id") == "J5")
        check("worker A is recorded as the owner", row.get("worker_id") == "worker-a")

        # Worker A's lease expires; worker B reclaims it. A fresh db module with
        # a different WORKER_ID, same fake backend — exactly like two separate
        # worker processes/hosts sharing one Supabase project.
        row["lease_expires_at"] = iso(-60)
        worker_b = load_db_module(url, worker_id="worker-b")
        reclaimed = worker_b.claim_next_job()
        check("worker B reclaims the expired lease", reclaimed is not None and reclaimed.get("id") == "J5")
        check("worker B is now the owner", row.get("worker_id") == "worker-b")
        b_lease = row.get("lease_expires_at")
        b_attempts = row.get("attempts")

        # Worker A — unaware its lease is gone — keeps trying to work the job.
        # Every ownership-scoped mutation must refuse, and the two that are
        # "must-stop" checkpoint (set_progress) must RAISE
        # JobNotOwned rather than silently doing nothing.
        try:
            worker_a.set_progress("J5", 0.5, "encoding")
            check("set_progress raises JobNotOwned for the stale owner", False, "did not raise")
        except worker_a.JobNotOwned:
            check("set_progress raises JobNotOwned for the stale owner", True)
        check("worker B's current_step untouched by A's set_progress",
              row.get("current_step") != "encoding", str(row.get("current_step")))

        # fail_job and release_job are terminal/cleanup calls: they log and
        # return quietly on a lost claim rather than raising, but they must
        # STILL never touch worker B's row.
        worker_a.fail_job("J5", {"message": "boom", "step": "encode"})
        check("fail_job left worker B's row alone", row["status"] == "processing", str(row["status"]))
        check("fail_job did not stamp worker B's row with an error",
              row.get("error") is None, str(row.get("error")))

        worker_a.release_job("J5", "worker A thinks it should requeue")
        check("release_job did NOT requeue worker B's live job out from under it",
              row["status"] == "processing", str(row["status"]))
        check("release_job did not clear worker B's lease",
              row.get("worker_id") == "worker-b" and row.get("lease_expires_at") == b_lease)
        check("release_job did not touch attempts", row.get("attempts") == b_attempts)

        # Worker B, the ACTUAL owner, can still do every one of these normally.
        worker_b.set_progress("J5", 0.9, "uploading")
        check("worker B's own set_progress works", row.get("current_step") == "uploading")
        # Finishing/publishing is now one RPC. The SQL fixture establishes its
        # atomicity; this fake table store cannot prove a database transaction.
    finally:
        server.shutdown()


# ── 6. audit P0-8: claiming a SPECIFIC job (webhook path) is the same ────────
#      CAS-plus-lease claim as the poll loop, not a second weaker one.

def test_claim_by_job_id() -> None:
    print("\n6. db.claim_next_job(job_id=...) — the webhook claim path — is "
          "lease-safe and scope-safe (external release audit P0-8)")
    fdb = fresh_db(lease_columns=True)
    server, url = fake_postgrest.start(fdb)
    try:
        db = load_db_module(url)

        # (a) normal case: claims exactly that job, with a real lease.
        fdb.tables["render_jobs"] = [
            {"id": "J6", "listing_id": "L1", "capture_asset_id": "asset-ok",
             "status": "queued", "source": "worker", "attempts": 0,
             "created_at": "2026-01-01T00:00:00Z"},
        ]
        claimed = db.claim_next_job(job_id="J6")
        check("claims the named job", claimed is not None and claimed["id"] == "J6")
        row = fdb.tables["render_jobs"][0]
        check("sets status=processing", row["status"] == "processing")
        check("stamps worker_id (was never set by the OLD process_specific claim)",
              row.get("worker_id") == "test-worker")
        check("sets a real lease (was never set by the OLD process_specific claim)",
              bool(row.get("lease_expires_at")))
        check("increments attempts (was never set by the OLD process_specific claim)",
              row.get("attempts") == 1)

        # (b) a job_id whose asset makes it ineligible (app-published bucket) is
        # refused, matching the poll loop's own _CLAIM_FILTERS — a job_id handed
        # straight in does not bypass the eligibility filters.
        fdb.tables["render_jobs"] = [
            {"id": "J7", "listing_id": "L1", "capture_asset_id": "asset-app",
             "status": "queued", "source": "worker", "attempts": 0,
             "created_at": "2026-01-01T00:00:00Z"},
        ]
        check("refuses a job_id whose asset lives in the renders bucket",
              db.claim_next_job(job_id="J7") is None)
        check("did not mutate the refused job",
              fdb.tables["render_jobs"][0]["status"] == "queued")

        # (c) a job_id already claimed (live lease, different worker) is refused —
        # the CAS still loses cleanly rather than stealing a live job.
        fdb.tables["render_jobs"] = [
            {"id": "J8", "listing_id": "L1", "capture_asset_id": "asset-ok",
             "status": "processing", "source": "worker", "attempts": 1,
             "worker_id": "someone-else", "lease_expires_at": iso(600),
             "created_at": "2026-01-01T00:00:00Z"},
        ]
        check("refuses a job_id another worker already owns (live lease)",
              db.claim_next_job(job_id="J8") is None)
        check("did not steal the live job",
              fdb.tables["render_jobs"][0]["worker_id"] == "someone-else")

        # (d) a job_id with an expired lease IS reclaimable by job_id, same as
        # the poll loop's reclaim path.
        fdb.tables["render_jobs"][0].update(lease_expires_at=iso(-60))
        reclaimed = db.claim_next_job(job_id="J8")
        check("reclaims a job_id with an expired lease", reclaimed is not None and reclaimed["id"] == "J8")
        check("reclaim stamps the new owner", fdb.tables["render_jobs"][0]["worker_id"] == "test-worker")
    finally:
        server.shutdown()


# ── 7. audit finding 6: cost_ledger idempotency (worker side) ────────────────

def test_record_cost_idempotency() -> None:
    print("\n7. record_cost() carries a stable idempotency_key; a duplicate-key "
          "response is treated as success, not failure (external release audit finding 6)")
    fdb = fresh_db(lease_columns=True)
    server, url = fake_postgrest.start(fdb)
    try:
        db = load_db_module(url)

        # _insert_cost_row: a genuine duplicate-key error must NOT raise —
        # otherwise a row that already landed gets endlessly re-spooled and
        # wedges cost_spool.flush() behind it forever.
        seen: list[dict] = []

        def fake_insert_dup(table, row, prefer="return=minimal"):
            seen.append(row)
            raise db.DBError(
                'PostgREST HTTP 409 POST cost_ledger: {"code":"23505","message":'
                '"duplicate key value violates unique constraint '
                '\\"uq_cost_ledger_idempotency\\""}'
            )

        orig_insert = db.insert
        db.insert = fake_insert_dup
        try:
            db._insert_cost_row({"idempotency_key": "dup-1", "total_cents": 1.0})
            check("a duplicate-key error from insert() does not raise", True)
        except db.DBError:
            check("a duplicate-key error from insert() does not raise", False, "raised")
        finally:
            db.insert = orig_insert
        check("insert() was actually called with the row", len(seen) == 1)

        # A DIFFERENT failure (not a duplicate key) must still raise normally —
        # this is not a blanket "swallow all errors" change.
        def fake_insert_other(table, row, prefer="return=minimal"):
            raise db.DBError("PostgREST HTTP 500 POST cost_ledger: internal error")

        db.insert = fake_insert_other
        try:
            db._insert_cost_row({"idempotency_key": "x", "total_cents": 1.0})
            check("a non-duplicate error still raises", False, "did not raise")
        except db.DBError:
            check("a non-duplicate error still raises", True)
        finally:
            db.insert = orig_insert

        # record_cost(): the row it builds carries a real, non-empty
        # idempotency_key, generated before any attempt.
        captured: list[dict] = []

        def capture_insert(table, row, prefer="return=minimal"):
            captured.append(dict(row))
            return []

        db.insert = capture_insert
        try:
            ok = db.record_cost(feature="render", provider="modal", model=None,
                                units=1.0, unit_cost_cents=0.5, total_cents=0.5,
                                job_id=None, org_id=None)
        finally:
            db.insert = orig_insert
        check("record_cost reports success", ok is True)
        check("exactly one insert attempt (first one succeeded)", len(captured) == 1)
        key = captured[0].get("idempotency_key") if captured else None
        check("the row carries a non-empty idempotency_key", bool(key), str(key))

        # Two separate record_cost() calls (two distinct logical charges) get
        # DIFFERENT keys — this is not a constant/shared value.
        captured2: list[dict] = []
        db.insert = lambda table, row, prefer="return=minimal": (captured2.append(dict(row)) or [])
        try:
            db.record_cost(feature="stream_store", provider="cloudflare", model=None,
                           units=1.0, unit_cost_cents=0.5, total_cents=0.5,
                           job_id=None, org_id=None)
        finally:
            db.insert = orig_insert
        check("a second, separate charge gets a DIFFERENT idempotency_key",
              captured2 and captured2[0].get("idempotency_key") != key,
              f"{captured2[0].get('idempotency_key') if captured2 else None} vs {key}")
    finally:
        server.shutdown()


if __name__ == "__main__":
    test_with_lease()
    test_without_lease()
    test_claim_scope_and_fail_guard()
    test_publication_requires_transaction()
    test_stale_worker_cannot_mutate_reclaimed_job()
    test_claim_by_job_id()
    test_record_cost_idempotency()
    print()
    if FAILURES:
        print(f"✗ {len(FAILURES)} failure(s): {FAILURES}")
        sys.exit(1)
    print("✓ all job-lease tests passed")
