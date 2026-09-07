#!/usr/bin/env python3
"""
Durable local spool for `cost_ledger` rows that could not be persisted (F-G-07).

Money that has ALREADY LEFT THE BUILDING must never be forgotten because
Supabase blinked. When a ledger write exhausts its retries the row is appended
here as one JSON line and re-tried later; it is removed only once the database
has accepted it. Two consumers share this file:

  • services/pipeline/cost_ledger.CostLedger — REAL provider spend (Gemini, fal,
    Anthropic). Losing one of these means unmetered, uncapped, unbilled money.
  • services/worker/db.record_cost — infra ESTIMATES (encode compute, Stream
    storage). These are best-effort by policy, but there's no reason to drop
    them either, so they spool too.

Stdlib only (the pipeline installs nothing) and deliberately importable from
both halves without dragging in `config`/`settings`.

DURABILITY: the default is now `DEFAULT_DURABLE_DIR` (a conventional Linux
persistent-data path), NOT the system temp dir (external release audit finding
6 — the old default lived under `tempfile.gettempdir()`, which on Cloud Run /
Modal is tmpfs and does NOT survive the container, and nothing said so unless
you already knew to check). If that directory cannot be created/written on this
host, `spool_path()` falls back to the temp dir and prints a warning ONCE —
loud, not silent — rather than pretending the durable path worked. Set
COST_LEDGER_SPOOL to override with a different persistent volume path.
`spool_is_durable()` reports which of the two you actually got, and callers
print it at startup so nobody discovers it during an incident.

CONCURRENCY: `append()` and `flush()` both hold an exclusive `fcntl.flock` on a
`.lock` sibling of the spool file for their full critical section (finding 6).
Without it, `flush()`'s read-then-rewrite is two separate operations: a
concurrent `append()` landing between them is silently dropped when the
rewrite's `os.replace` overwrites the file with only the pre-append snapshot.
And two concurrent flushers (two threads on one host, or two worker processes
sharing one host/volume) can both read the same pending rows and both submit
each one to `cost_ledger` — a real double-charge, not just a lost append. The
lock only coordinates within ONE host's view of ONE file, though: it cannot
stop two SEPARATE hosts, each with their own local (or separately-mounted)
spool file, from independently retrying "the same" charge. Closing that
cross-host gap needs a DB-side guarantee — see `idempotency_key` below and
migration 0025_cost_ledger_idempotency.sql.

IDEMPOTENCY: every row's `idempotency_key` (added by the caller — see
`services/worker/db.record_cost` / `services/pipeline/cost_ledger.CostLedger.record`
— once, when the row is first built, unchanged across every retry and every
spool/flush replay of that SAME charge) is backed by a unique index from
migration 0025. A resubmission of a charge that already landed — from this
host's own retry, or from a different host retrying the same spooled entry —
now gets rejected by the database (409/23505) instead of silently duplicating,
and both `record_cost` and `CostLedger._insert_once` treat that specific
rejection as success rather than a failure to spool-and-retry forever.

Format: one JSON object per line —
    {"ts": <unix>, "source": "pipeline"|"worker", "attempts": <int>,
     "last_error": "<str>", "row": {<cost_ledger row, incl. idempotency_key>}}
"""

from __future__ import annotations

import contextlib
import fcntl
import json
import os
import tempfile
import time
from pathlib import Path
from typing import Callable, Iterable, Iterator

ENV_PATH = "COST_LEDGER_SPOOL"
ENV_DURABLE = "COST_LEDGER_SPOOL_DURABLE"   # set to 1 when it IS on a real volume
_DEFAULT_NAME = "rendprop-cost-ledger-spool.jsonl"
# Conventional Linux path for a service's persistent local state — tried BEFORE
# falling back to the temp dir. Matches what services/worker/.env.example has
# long suggested operators set COST_LEDGER_SPOOL to; this just makes that the
# default instead of an example the operator has to know to copy.
DEFAULT_DURABLE_DIR = "/var/lib/rendprop"

# A runaway spool means the ledger has been down for a long time; past this we
# stop growing the file and shout, rather than filling the disk.
MAX_SPOOL_ROWS = int(os.environ.get("COST_LEDGER_SPOOL_MAX_ROWS", "5000") or 5000)

_default_dir_state: bool | None = None   # None = not probed yet
_warned_ephemeral = False


def _default_dir_usable() -> bool:
    """Probe ONCE whether DEFAULT_DURABLE_DIR can actually be written here."""
    global _default_dir_state
    if _default_dir_state is not None:
        return _default_dir_state
    d = Path(DEFAULT_DURABLE_DIR)
    try:
        d.mkdir(parents=True, exist_ok=True)
        probe = d / f".probe-{os.getpid()}"
        probe.touch()
        probe.unlink()
        _default_dir_state = True
    except OSError:
        _default_dir_state = False
    return _default_dir_state


def _warn_ephemeral_fallback() -> None:
    global _warned_ephemeral
    if _warned_ephemeral:
        return
    _warned_ephemeral = True
    print(f"    ⚠ cost spool: {DEFAULT_DURABLE_DIR} is not writable on this host — "
          f"falling back to {tempfile.gettempdir()} (EPHEMERAL: rows here are LOST "
          f"on a container restart). Set COST_LEDGER_SPOOL to a path on a real "
          f"persistent volume.")


def spool_path() -> Path:
    raw = (os.environ.get(ENV_PATH) or "").strip()
    if raw:
        return Path(raw)
    if _default_dir_usable():
        return Path(DEFAULT_DURABLE_DIR) / _DEFAULT_NAME
    _warn_ephemeral_fallback()
    return Path(tempfile.gettempdir()) / _DEFAULT_NAME


def _lock_path(path: Path) -> Path:
    return path.with_name(path.name + ".lock")


@contextlib.contextmanager
def _locked(path: Path) -> Iterator[None]:
    """Exclusive advisory lock scoped to this spool file's critical section.

    A SEPARATE `.lock` file, not the spool file itself: flock is released by
    ANY close of ANY fd referring to that file, so locking the file we also
    read/rewrite with plain `open()`/`Path.write_text()` calls elsewhere in the
    same process could drop the lock out from under us the moment one of those
    unrelated fds closes. A dedicated lock file has no other opens against it.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(_lock_path(path), os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def spool_is_durable() -> bool:
    """True when this spool's rows survive a container restart.

    Explicit COST_LEDGER_SPOOL_DURABLE=1 is trusted outright — the operator is
    asserting the path they gave IS a real volume. Otherwise: durable unless
    `spool_path()` actually resolved to the ephemeral temp-dir fallback, which
    happens either because COST_LEDGER_SPOOL was never set and
    DEFAULT_DURABLE_DIR isn't writable here, or because COST_LEDGER_SPOOL was
    itself pointed at the temp dir (almost certainly a mistake).
    """
    if (os.environ.get(ENV_DURABLE) or "").strip().lower() in ("1", "true", "yes", "on"):
        return True
    return not str(spool_path()).startswith(tempfile.gettempdir())


def describe() -> str:
    p = spool_path()
    kind = "durable" if spool_is_durable() else "EPHEMERAL (lost on container restart)"
    return f"{p} [{kind}], {pending_count()} row(s) pending"


def append(row: dict, *, source: str, error: str = "", attempts: int = 0) -> bool:
    """Append one un-persisted ledger row. Returns True if it reached the disk.

    A single `write()` of a short line to an O_APPEND fd is atomic on POSIX, so
    concurrent appenders interleave whole lines rather than corrupting each
    other even without a lock — but `flush()` doesn't just append, it reads
    the whole file and then REWRITES it (to drop the rows it successfully
    sent), and that is NOT atomic with respect to a concurrent append: a row
    appended between the read and the rewrite would be silently dropped when
    the rewrite replaces the file with only what it read. The shared `_locked`
    critical section (same `.lock` file `flush()` uses) is what actually
    prevents that (audit finding 6).

    `row` is expected to already carry a stable `idempotency_key` (the caller
    generates it once, before any attempt — see `services/worker/db.record_cost`
    / `CostLedger.record`), unchanged by anything here, so a resubmission of
    this exact spooled entry is detectable at the database (migration 0025).
    """
    entry = {"ts": round(time.time(), 3), "source": source, "attempts": attempts,
             "last_error": str(error)[:500], "row": row}
    path = spool_path()
    try:
        with _locked(path):
            if pending_count() >= MAX_SPOOL_ROWS:
                print(f"    ⚠ ALARM cost spool is full ({MAX_SPOOL_ROWS} rows) at {path} — "
                      f"the ledger has been unavailable for a long time; DROPPING nothing but "
                      f"refusing to grow. Fix the ledger and flush.")
                return False
            path.parent.mkdir(parents=True, exist_ok=True)
            with open(path, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(entry, separators=(",", ":")) + "\n")
                fh.flush()
                os.fsync(fh.fileno())     # the whole point is surviving a hard kill
        return True
    except OSError as e:
        print(f"    ⚠ ALARM could not spool a cost row to {path}: {e}")
        return False


def read_all() -> list[dict]:
    path = spool_path()
    if not path.exists():
        return []
    out: list[dict] = []
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue           # a torn line is not worth failing a flush over
            if isinstance(entry, dict) and isinstance(entry.get("row"), dict):
                out.append(entry)
    except OSError as e:
        print(f"    ⚠ could not read cost spool {path}: {e}")
    return out


def _rewrite(entries: Iterable[dict]) -> None:
    path = spool_path()
    tmp = path.with_suffix(path.suffix + ".tmp")
    try:
        body = "".join(json.dumps(e, separators=(",", ":")) + "\n" for e in entries)
        tmp.write_text(body, encoding="utf-8")
        os.replace(tmp, path)      # atomic swap
    except OSError as e:
        print(f"    ⚠ could not rewrite cost spool {path}: {e}")


def pending_count() -> int:
    path = spool_path()
    if not path.exists():
        return 0
    try:
        with open(path, "rb") as fh:
            return sum(1 for line in fh if line.strip())
    except OSError:
        return 0


def flush(send: Callable[[dict], None], *, limit: int = 200) -> tuple[int, int]:
    """Re-try spooled rows with `send(row)`. Returns (persisted, still_pending).

    `send` must raise on failure — UNLESS the failure is "already recorded"
    (a duplicate-key response for this row's `idempotency_key`), which both
    `services/worker/db._insert_cost_row` and
    `services/pipeline/cost_ledger.CostLedger._insert_once` now treat as
    success rather than raising, so it counts as sent and is dropped from the
    spool. Any OTHER failure stops the pass — if the DB is still down there is
    no point hammering it — and everything not yet persisted is written back.
    Bounded by `limit` so a huge backlog can't stall a worker loop; call it
    again to continue.

    The read, every `send`, and the rewrite all happen under ONE hold of this
    spool's lock (audit finding 6): without it, two concurrent flushers (two
    threads on one host, or two processes sharing one host/volume) would both
    read the same pending rows and could both successfully submit the same
    one — the idempotency key then turns that into a harmless 409 rather than
    a duplicate charge, but taking the lock avoids even attempting the
    redundant submit when it's avoidable on this host. See the module
    docstring for what the lock can and cannot coordinate across hosts.
    """
    path = spool_path()
    try:
        with _locked(path):
            entries = read_all()
            if not entries:
                return 0, 0
            sent = 0
            remaining: list[dict] = []
            stopped = False
            for i, entry in enumerate(entries):
                if stopped or i >= limit:
                    remaining.append(entry)
                    continue
                try:
                    send(entry["row"])
                    sent += 1
                except Exception as e:      # noqa: BLE001 — any transport/HTTP failure
                    entry["attempts"] = int(entry.get("attempts", 0)) + 1
                    entry["last_error"] = str(e)[:500]
                    remaining.append(entry)
                    stopped = True
            _rewrite(remaining)
            if sent:
                print(f"    ✓ cost spool: {sent} previously-unrecorded row(s) persisted "
                      f"({len(remaining)} still pending)")
            return sent, len(remaining)
    except OSError as e:
        print(f"    ⚠ cost spool flush could not acquire its lock ({e}); will retry next time")
        return 0, pending_count()
