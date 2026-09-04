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

DURABILITY CAVEAT, stated plainly: the default path lives under the system temp
dir, which on Cloud Run / Modal is tmpfs and does NOT survive the container. Set
COST_LEDGER_SPOOL to a path on a persistent volume for the guarantee to be real.
`spool_is_durable()` reports which of the two you have, and callers print it at
startup so nobody discovers it during an incident.

Format: one JSON object per line —
    {"ts": <unix>, "source": "pipeline"|"worker", "attempts": <int>,
     "last_error": "<str>", "row": {<cost_ledger row>}}
"""

from __future__ import annotations

import json
import os
import tempfile
import time
from pathlib import Path
from typing import Callable, Iterable

ENV_PATH = "COST_LEDGER_SPOOL"
ENV_DURABLE = "COST_LEDGER_SPOOL_DURABLE"   # set to 1 when it IS on a real volume
_DEFAULT_NAME = "rendprop-cost-ledger-spool.jsonl"

# A runaway spool means the ledger has been down for a long time; past this we
# stop growing the file and shout, rather than filling the disk.
MAX_SPOOL_ROWS = int(os.environ.get("COST_LEDGER_SPOOL_MAX_ROWS", "5000") or 5000)


def spool_path() -> Path:
    raw = (os.environ.get(ENV_PATH) or "").strip()
    return Path(raw) if raw else Path(tempfile.gettempdir()) / _DEFAULT_NAME


def spool_is_durable() -> bool:
    """True only when the operator has SAID this path survives a restart."""
    if (os.environ.get(ENV_DURABLE) or "").strip().lower() in ("1", "true", "yes", "on"):
        return True
    return bool((os.environ.get(ENV_PATH) or "").strip()) and not str(
        spool_path()).startswith(tempfile.gettempdir())


def describe() -> str:
    p = spool_path()
    kind = "durable" if spool_is_durable() else "EPHEMERAL (lost on container restart)"
    return f"{p} [{kind}], {pending_count()} row(s) pending"


def append(row: dict, *, source: str, error: str = "", attempts: int = 0) -> bool:
    """Append one un-persisted ledger row. Returns True if it reached the disk.

    A single `write()` of a short line to an O_APPEND fd is atomic on POSIX, so
    concurrent workers interleave whole lines rather than corrupting each other.
    """
    entry = {"ts": round(time.time(), 3), "source": source, "attempts": attempts,
             "last_error": str(error)[:500], "row": row}
    path = spool_path()
    try:
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

    `send` must raise on failure. The first failure stops the pass — if the DB
    is still down there is no point hammering it — and everything not yet
    persisted is written back. Bounded by `limit` so a huge backlog can't stall
    a worker loop; call it again to continue.
    """
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
