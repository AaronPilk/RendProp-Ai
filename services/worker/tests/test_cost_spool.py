#!/usr/bin/env python3
"""
Regression tests for services/pipeline/cost_spool.py (external release audit
finding 6):

  1. the spool defaults to a DURABLE path, not the system temp dir, with a
     warned (not silent) fallback when that path isn't writable on this host;
  2. `fcntl.flock`-based locking closes the race where a `flush()`'s
     read-then-rewrite can silently drop a row appended in the gap, and where
     two concurrent flushers could both submit the same pending row.

    python3 tests/test_cost_spool.py

Stdlib only and self-contained (imports services/pipeline/cost_spool.py the
same way services/worker/db.py does — by inserting that directory onto
sys.path); exits non-zero on the first failure.
"""

from __future__ import annotations

import os
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PIPELINE_DIR = HERE.parent.parent / "pipeline"
sys.path.insert(0, str(PIPELINE_DIR))

FAILURES: list[str] = []


def check(label: str, cond: bool, detail: str = "") -> None:
    print(f"  {'ok  ' if cond else 'FAIL'} {label}" + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        FAILURES.append(label)


def load_cost_spool(**env: str | None):
    """Import services/pipeline/cost_spool.py fresh with the given env."""
    sys.modules.pop("cost_spool", None)
    for k, v in env.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v
    import cost_spool as cs  # noqa: WPS433
    return cs


# ── 1. default path is durable; unwritable durable dir falls back (warned) ──

def test_default_path_durable_and_fallback() -> None:
    print("\n1. default spool path is a durable dir, with a warned temp-dir fallback")
    # Rooted under /var/tmp, NOT tempfile.gettempdir() (== /tmp here): the whole
    # point of this test is the durable-vs-ephemeral distinction, which
    # spool_is_durable() draws by checking against tempfile.gettempdir() — a
    # sandbox living under /tmp itself would confound that check regardless of
    # what the code under test does.
    with tempfile.TemporaryDirectory(prefix="rendprop-spool-", dir="/var/tmp") as tmp:
        # (a) the durable dir IS usable → that's the default, and it self-reports durable.
        durable = Path(tmp) / "durable"
        cs = load_cost_spool(COST_LEDGER_SPOOL=None, COST_LEDGER_SPOOL_DURABLE=None)
        cs.DEFAULT_DURABLE_DIR = str(durable)
        p = cs.spool_path()
        check("resolves under the (usable) durable dir", str(p).startswith(str(durable)), str(p))
        check("reported durable", cs.spool_is_durable() is True)

        # (b) the durable dir can NEVER be created here (its parent path component
        #     is a plain FILE, so mkdir(parents=True) always raises NotADirectoryError,
        #     deterministically — no dependence on the test runner's uid/permissions)
        #     → falls back to the temp dir and reports EPHEMERAL.
        blocker = Path(tmp) / "blocker"
        blocker.write_text("not a directory")
        unusable = blocker / "rendprop"
        cs2 = load_cost_spool(COST_LEDGER_SPOOL=None, COST_LEDGER_SPOOL_DURABLE=None)
        cs2.DEFAULT_DURABLE_DIR = str(unusable)
        p2 = cs2.spool_path()
        check("falls back to the temp dir when the durable dir is unusable",
              str(p2).startswith(tempfile.gettempdir()), str(p2))
        check("fallback is reported EPHEMERAL", cs2.spool_is_durable() is False)
        p2b = cs2.spool_path()
        check("fallback decision is cached (same path, no re-probe)", p2b == p2)

        # (c) an explicit COST_LEDGER_SPOOL always wins over the default...
        explicit = Path(tmp) / "explicit-spool.jsonl"
        cs3 = load_cost_spool(COST_LEDGER_SPOOL=str(explicit), COST_LEDGER_SPOOL_DURABLE=None)
        check("COST_LEDGER_SPOOL overrides the default", cs3.spool_path() == explicit)
        check("an explicit non-temp path is reported durable", cs3.spool_is_durable() is True)

        # ...and COST_LEDGER_SPOOL_DURABLE=1 is trusted outright, even pointed at
        # the temp dir (an operator override always wins over the heuristic).
        cs4 = load_cost_spool(COST_LEDGER_SPOOL=str(Path(tempfile.gettempdir()) / "x.jsonl"),
                              COST_LEDGER_SPOOL_DURABLE="1")
        check("COST_LEDGER_SPOOL_DURABLE=1 is trusted even over the temp dir",
              cs4.spool_is_durable() is True)


# ── 2. a concurrent append is never lost while another holder has the lock ──

def test_locking_blocks_concurrent_append() -> None:
    print("\n2. flock makes a concurrent append WAIT instead of racing the holder")
    with tempfile.TemporaryDirectory(prefix="rendprop-spool-") as tmp:
        cs = load_cost_spool(COST_LEDGER_SPOOL=str(Path(tmp) / "spool.jsonl"),
                             COST_LEDGER_SPOOL_DURABLE="1")
        path = cs.spool_path()

        check("seed append lands", cs.append({"idempotency_key": "seed", "n": 0}, source="worker"))
        check("one row pending before the race", cs.pending_count() == 1)

        with cs._locked(path):     # simulates "a flush is already in progress"
            done = threading.Event()

            def racer() -> None:
                cs.append({"idempotency_key": "race", "n": 1}, source="worker")
                done.set()

            t = threading.Thread(target=racer, daemon=True)
            t.start()
            time.sleep(0.2)
            check("a concurrent append BLOCKS while the lock is held", not done.is_set())

        t.join(timeout=2)
        check("the blocked append completes once the lock is released", done.is_set())
        check("BOTH rows are present — nothing lost", cs.pending_count() == 2)
        keys = {e["row"]["idempotency_key"] for e in cs.read_all()}
        check("both idempotency keys present", keys == {"seed", "race"}, str(keys))


# ── 3. flush() holds ONE lock across read + send + rewrite ───────────────────

def test_flush_holds_lock_across_read_send_rewrite() -> None:
    print("\n3. an append issued during a flush() survives — not lost to its rewrite")
    with tempfile.TemporaryDirectory(prefix="rendprop-spool-") as tmp:
        cs = load_cost_spool(COST_LEDGER_SPOOL=str(Path(tmp) / "spool.jsonl"),
                             COST_LEDGER_SPOOL_DURABLE="1")
        cs.append({"idempotency_key": "a", "n": 0}, source="worker")
        cs.append({"idempotency_key": "b", "n": 1}, source="worker")
        check("two rows pending", cs.pending_count() == 2)

        entered = threading.Event()     # set once flush() is inside send() (lock held)
        release = threading.Event()     # test lets send() return
        sent_rows: list[dict] = []

        def slow_send(row: dict) -> None:
            sent_rows.append(row)
            entered.set()
            release.wait(2)

        flusher_done = threading.Event()

        def run_flush() -> None:
            cs.flush(slow_send, limit=1)   # only entry 0 ("a") is sent
            flusher_done.set()

        ft = threading.Thread(target=run_flush, daemon=True)
        ft.start()
        check("flush reaches send() (lock acquired)", entered.wait(2))

        appended = threading.Event()

        def racer() -> None:
            cs.append({"idempotency_key": "c", "n": 2}, source="worker")
            appended.set()

        rt = threading.Thread(target=racer, daemon=True)
        rt.start()
        time.sleep(0.2)
        check("append issued WHILE flush holds the lock blocks", not appended.is_set())

        release.set()
        ft.join(timeout=2)
        rt.join(timeout=2)
        check("flush finished", flusher_done.is_set())
        check("the queued append completed once flush released the lock", appended.is_set())
        check("exactly one row was sent (limit=1)", len(sent_rows) == 1, str(sent_rows))

        keys = {e["row"]["idempotency_key"] for e in cs.read_all()}
        check("the row flush() sent is gone from the spool", "a" not in keys, str(keys))
        check("the row limit=1 didn't reach survives", "b" in keys, str(keys))
        check("the append issued mid-flush was NOT clobbered by the rewrite",
              "c" in keys, str(keys))


if __name__ == "__main__":
    test_default_path_durable_and_fallback()
    test_locking_blocks_concurrent_append()
    test_flush_holds_lock_across_read_send_rewrite()
    print()
    if FAILURES:
        print(f"✗ {len(FAILURES)} failure(s): {FAILURES}")
        sys.exit(1)
    print("✓ all cost-spool tests passed")
