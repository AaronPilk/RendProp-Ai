#!/usr/bin/env python3
"""
Regression tests for `worker.process_specific()` — the webhook-triggered claim
path (external release audit P0-8).

Before this fix, `process_specific()` PATCHed status only: no `worker_id`, no
`lease_expires_at`, no `attempts`, and no `source='worker'` check. This exercises
the fixed version against a fake PostgREST, monkeypatching `worker.process_job`
to a recorder so the claim/refusal logic is verified in isolation from an actual
encode (which needs a real capture file — covered instead by
tests/test_hdr_tonemap.py and the manual smoke test in ffmpeg_render.py).

    python3 tests/test_process_specific.py

Stdlib only (imports the real `worker` module, which needs boto3/requests —
see services/worker/requirements.txt — but makes no network calls here: R2/
Stream are never reached because `process_job` itself is replaced).
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


def fresh_db() -> fake_postgrest.FakeDB:
    db = fake_postgrest.FakeDB(lease_columns=True)
    db.tables["capture_assets"] = [
        {"id": "asset-ok", "listing_id": "L1", "storage_key": "uploads/o/l/a.mov",
         "bucket": "uploads", "uploaded": True, "kind": "video", "bytes": 1000},
        {"id": "asset-app", "listing_id": "L1", "storage_key": "renders/o/l/a.mp4",
         "bucket": "renders", "uploaded": True, "kind": "video", "bytes": 1000},
    ]
    db.tables["listings"] = [{"id": "L1", "org_id": "O1", "space_type": "home",
                              "status": "processing"}]
    return db


def load_worker_module(base_url: str):
    """Import services/worker/worker.py (and its `db`) fresh against a fake URL."""
    for mod in ("worker", "db", "settings"):
        sys.modules.pop(mod, None)
    os.environ["SUPABASE_URL"] = base_url
    os.environ["SUPABASE_SERVICE_ROLE_KEY"] = "test-key"
    os.environ["WORKER_ID"] = "test-worker"
    os.environ["WORKER_LEASE_S"] = "600"
    os.environ["WORKER_MAX_ATTEMPTS"] = "3"
    # worker.py's module-level SETTINGS.from_env() only fails loudly on the AI
    # cost/QC guards (validate_shared_guards, called from _preflight — not from
    # import, and process_specific() never calls _preflight()), so importing it
    # against fake/blank R2 + Stream config is safe here: process_job is
    # replaced before anything would try to actually use them.
    import worker as worker_module  # noqa: WPS433
    return worker_module


class _Recorder:
    """Stand-in for worker.process_job that records what it was called with."""

    def __init__(self) -> None:
        self.calls: list[dict] = []

    def __call__(self, job: dict) -> None:
        self.calls.append(job)


# ── 1. source != 'worker' is refused, without ever attempting a claim ───────

def test_refuses_non_worker_source() -> None:
    print("\n1. process_specific refuses a job whose source is not 'worker' (P0-8)")
    fdb = fresh_db()
    server, url = fake_postgrest.start(fdb)
    try:
        w = load_worker_module(url)
        fdb.tables["render_jobs"] = [
            {"id": "A1", "listing_id": "L1", "capture_asset_id": "asset-app",
             "status": "created", "source": "app", "attempts": 0,
             "created_at": "2026-01-01T00:00:00Z"},
        ]
        rec = _Recorder()
        w.process_job = rec
        w.process_specific("A1")
        check("process_job was never called", len(rec.calls) == 0, str(rec.calls))
        check("the job row was not claimed", fdb.tables["render_jobs"][0]["status"] == "created")
        check("no worker_id was stamped", fdb.tables["render_jobs"][0].get("worker_id") is None)
    finally:
        server.shutdown()


# ── 2. an ineligible asset (renders bucket / unfinished upload) is refused ───

def test_refuses_ineligible_asset() -> None:
    print("\n2. process_specific refuses a job whose asset isn't the worker's to render")
    fdb = fresh_db()
    server, url = fake_postgrest.start(fdb)
    try:
        w = load_worker_module(url)
        # source='worker' but the asset lives in the renders bucket — mislabelled
        # source must not matter; the asset check is belt-and-braces here too.
        fdb.tables["render_jobs"] = [
            {"id": "A2", "listing_id": "L1", "capture_asset_id": "asset-app",
             "status": "created", "source": "worker", "attempts": 0,
             "created_at": "2026-01-01T00:00:00Z"},
        ]
        rec = _Recorder()
        w.process_job = rec
        w.process_specific("A2")
        check("process_job was never called", len(rec.calls) == 0, str(rec.calls))
        check("the job row was not claimed", fdb.tables["render_jobs"][0]["status"] == "created")
    finally:
        server.shutdown()


# ── 3. the happy path claims through the SAME CAS-plus-lease path ───────────

def test_claims_with_full_lease_and_calls_process_job() -> None:
    print("\n3. process_specific claims with a real lease/worker_id/attempts, "
          "then calls process_job with the CLAIMED row")
    fdb = fresh_db()
    server, url = fake_postgrest.start(fdb)
    try:
        w = load_worker_module(url)
        fdb.tables["render_jobs"] = [
            {"id": "J1", "listing_id": "L1", "capture_asset_id": "asset-ok",
             "status": "queued", "source": "worker", "attempts": 0,
             "created_at": "2026-01-01T00:00:00Z"},
        ]
        rec = _Recorder()
        w.process_job = rec
        w.process_specific("J1")

        row = fdb.tables["render_jobs"][0]
        check("status flipped to processing", row["status"] == "processing")
        check("worker_id stamped (THE fix: the old claim never set this)",
              row.get("worker_id") == "test-worker")
        check("a real lease was set (THE fix: the old claim never set this)",
              bool(row.get("lease_expires_at")))
        check("attempts incremented (THE fix: the old claim never set this)",
              row.get("attempts") == 1)
        check("process_job was called exactly once", len(rec.calls) == 1, str(rec.calls))
        check("process_job was called with the CLAIMED row (has the lease fields)",
              bool(rec.calls) and rec.calls[0].get("worker_id") == "test-worker")
    finally:
        server.shutdown()


# ── 4. already claimed by someone else (live lease) → refuse, don't steal ───

def test_refuses_when_already_claimed_live() -> None:
    print("\n4. process_specific refuses a job another worker already owns "
          "(refuse to proceed if the claim fails — P0-8)")
    fdb = fresh_db()
    server, url = fake_postgrest.start(fdb)
    try:
        w = load_worker_module(url)
        live_lease = iso(600)
        fdb.tables["render_jobs"] = [
            {"id": "J2", "listing_id": "L1", "capture_asset_id": "asset-ok",
             "status": "processing", "source": "worker", "attempts": 1,
             "worker_id": "other-worker", "lease_expires_at": live_lease,
             "created_at": "2026-01-01T00:00:00Z"},
        ]
        rec = _Recorder()
        w.process_job = rec
        w.process_specific("J2")
        check("process_job was never called — refused rather than stealing a live job",
              len(rec.calls) == 0, str(rec.calls))
        check("the live job's owner is unchanged",
              fdb.tables["render_jobs"][0]["worker_id"] == "other-worker")
        check("the live job's lease is byte-for-byte unchanged",
              fdb.tables["render_jobs"][0]["lease_expires_at"] == live_lease)
        check("attempts was not incremented", fdb.tables["render_jobs"][0]["attempts"] == 1)
    finally:
        server.shutdown()


# ── 5. a job_id that doesn't exist exits loudly rather than proceeding ──────

def test_missing_job_exits() -> None:
    print("\n5. process_specific exits (does not proceed) for an unknown job id")
    fdb = fresh_db()
    server, url = fake_postgrest.start(fdb)
    try:
        w = load_worker_module(url)
        rec = _Recorder()
        w.process_job = rec
        try:
            w.process_specific("does-not-exist")
            check("raises SystemExit for an unknown job id", False, "did not raise")
        except SystemExit:
            check("raises SystemExit for an unknown job id", True)
        check("process_job was never called", len(rec.calls) == 0, str(rec.calls))
    finally:
        server.shutdown()


if __name__ == "__main__":
    test_refuses_non_worker_source()
    test_refuses_ineligible_asset()
    test_claims_with_full_lease_and_calls_process_job()
    test_refuses_when_already_claimed_live()
    test_missing_job_exits()
    print()
    if FAILURES:
        print(f"✗ {len(FAILURES)} failure(s): {FAILURES}")
        sys.exit(1)
    print("✓ all process_specific tests passed")
