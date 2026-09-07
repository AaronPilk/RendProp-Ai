# External release audit — worker fixes (2026-09-07)

Branch `fix/worker-leases` off `integrate/1.0.1`. Scope: `services/worker/`,
`services/pipeline/cost_spool.py`, `services/pipeline/cost_ledger.py`, one new
migration. Four fixes from the external release audit, each below at
file:line with how it was verified. None of this touches app/edge/iOS code.

This is additive to, not a redo of, `fd0446f` (already on `integrate/1.0.1`
before this branch), which fixed a *different* cost-ledger duplication cause
— `rollup_job()` re-driving `record_cost()`'s insert-retry loop — and
renumbered migrations so 0015 is the job-lease migration this doc references.
`db.py:729-734` still calls `rollup_job_best_effort()` lexically inside that
retry loop, but `rollup_job_best_effort()` (db.py:780-784) swallows its own
`DBError` and never raises, so a rollup failure can no longer drive a second
insert — confirmed by reading, not changed here.

---

## Fix 1 — `process_specific()` never really claimed the job (P0-8)

**Bug.** The webhook-triggered path (`worker.py`, invoked as
`python worker.py --job-id <id>`) PATCHed `render_jobs.status` directly and
never set `worker_id`, `lease_expires_at`, or incremented `attempts`. Two
consequences: the job lost "ownership" at its very first heartbeat (which
filters `worker_id = eq.<this worker>`, matching nothing), and if the process
died *before* that first heartbeat the job was **unreclaimable by anyone** —
a lease that was never set can never look expired. It also never checked
`source = 'worker'`, so an app-published job could in principle be claimed
here too.

**Fix.** `services/worker/worker.py:609-664` (`process_specific`) rewritten to
reuse the exact same CAS-plus-lease path the poll loop uses, rather than a
second claim implementation:
- `services/worker/db.py:235` `claim_next_job()` gained `*, job_id: str | None
  = None`; `services/worker/db.py:285` `_next_candidate()` takes the same
  parameter and merges an `{"id": "eq.<job_id>"}` filter into the same
  `select()` calls the poll loop's fresh/reclaim candidate search already
  uses — so a `--job-id` claim gets full `worker_id`/`lease_expires_at`/
  `attempts` and the same `source='worker'` + eligibility filters, for free,
  with no parallel logic to keep in sync.
- `process_specific()` now: loads the row, rejects non-`source='worker'` jobs
  outright (belt-and-braces — `claim_next_job`'s own filters would also
  refuse them), rejects an ineligible asset (renders-bucket / unfinished
  upload) the same way the poll loop would, then calls
  `db.claim_next_job(job_id=job_id)` and **refuses to proceed** (logs and
  returns, does not call `process_job`) if the claim comes back empty —
  someone else already owns the job, or it is no longer eligible.

**Verified by** `services/worker/tests/test_process_specific.py` (new),
importing the real `worker` module against a fake PostgREST and stubbing
`process_job` with a call recorder:
- `test_refuses_non_worker_source` — `source='app'` job: `process_job` never
  called, row untouched.
- `test_refuses_ineligible_asset` — asset in the renders bucket: same.
- `test_claims_with_full_lease_and_calls_process_job` — happy path: row ends
  up `status='processing'`, `worker_id` stamped, `lease_expires_at` set,
  `attempts == 1`, and `process_job` is called with the *claimed* (lease-
  bearing) row, not the pre-claim one.
- `test_refuses_when_already_claimed_live` — another worker holds a live
  lease: `process_job` never called, the live owner's `worker_id` /
  `lease_expires_at` / `attempts` are byte-for-byte unchanged (no theft).
- `test_missing_job_exits` — unknown job id raises `SystemExit` rather than
  falling through.

Run: `python3 services/worker/tests/test_process_specific.py` →
`✓ all process_specific tests passed` (exit 0).

---

## Fix 2 — a stale worker could overwrite a reclaimed job's state

**Bug.** `finish_job()`, `set_progress()`, `release_job()` and `fail_job()`
(`services/worker/db.py`, originally ~351/362/368) filtered a `render_jobs`
PATCH by `id` alone. Reproduction: worker A claims a job (e.g. via
`--job-id`), A's lease expires, worker B reclaims the same row (now also
`status='processing'`, just with B's `worker_id`), and A's later
`finish_job()`/`set_progress()` — an id+status filter matches B's row just as
well as it would have matched A's own — silently overwrites whatever B had
already written: B's progress, B's `ready` status, potentially re-publishing
or re-billing a render B is still actively producing.

**Fix.** Every mutating helper now filters on **current ownership**, not just
the job id, and a lost claim is detected explicitly rather than falling
through as success:
- `services/worker/db.py:369` `_owned_filters(job_id)` — always requires
  `status = eq.processing`; when migration 0015's lease columns exist (this
  worktree's `lease_supported()` probe), also requires
  `worker_id = eq.<WORKER_ID>`.
- `services/worker/db.py:389` `_owned_patch(job_id, values)` — the one PATCH
  helper every mutator below now goes through; empty `return=representation`
  rows means zero rows matched, i.e. this worker no longer owns the job.
- `services/worker/db.py:46` new `JobNotOwned(RuntimeError)` — deliberately
  **not** a `DBError` subclass, so the pre-existing `except DBError:
  continue`-style advisory handlers elsewhere can't accidentally swallow a
  lost claim.
- `services/worker/db.py:432` `set_progress()` and `services/worker/db.py:460`
  `finish_job()` **raise `JobNotOwned`** on zero matched rows — these are the
  two checkpoints that must never continue silently: progress fires on every
  ffmpeg tick (the tightest ownership check available) and finish is the
  publish step.
- `services/worker/db.py:402` `release_job()` and `services/worker/db.py:479`
  `fail_job()` log-and-return on zero rows instead of raising — both are
  already terminal/cleanup calls with nothing further to protect.
- `services/worker/worker.py:128` `LeaseLost` is now `class LeaseLost(
  db.JobNotOwned)` (was a bare `RuntimeError`) so the heartbeat thread's own
  independent detection and the inline-mutation detection above are the same
  exception family; `services/worker/worker.py:512` catches
  `except db.JobNotOwned` (was `except LeaseLost`), so either source aborts
  the render the same way — stop, don't upload, don't call `fail_job()`
  again (it's itself ownership-scoped, so it would just no-op).
- `services/worker/ffmpeg_render.py:407` `_run_with_progress()` gained
  `except BaseException: _kill_group(proc); raise` so a `JobNotOwned` raised
  from inside the progress callback kills the ffmpeg child instead of leaving
  it running orphaned after the worker process moves on.

Deliberately left id-only (not ownership-scoped): `set_enhancement_result`
(advisory metadata, and scoping it would break its existing no-lease test
fixtures), `reap_stale_jobs` (system-level, ownership-agnostic by design),
`rollup_job`/`rollup_job_best_effort` (idempotent recomputation, order-
independent), `set_listing_status` (different table entirely).

**Verified by** `services/worker/tests/test_job_lease.py`, extended:
`test_stale_worker_cannot_mutate_reclaimed_job` (new) reproduces the exact
scenario — two independent `db` module instances as worker-a/worker-b,
worker-a claims, its lease is force-expired, worker-b reclaims, then:
worker-a's `set_progress`/`finish_job` raise `JobNotOwned`; worker-a's
`fail_job`/`release_job` log-and-noop and leave worker-b's row (status,
lease, worker_id, attempts) completely untouched; worker-b's own subsequent
calls succeed normally. Also `test_claim_by_job_id` (new) checks
`claim_next_job(job_id=...)` won't steal a job another worker holds a live
lease on, but does reclaim one whose lease has expired.

Run: `python3 services/worker/tests/test_job_lease.py` →
`✓ all job-lease tests passed` (exit 0).

---

## Fix 3 — resource controls (external release audit finding 4)

Four gaps, one file group, one env-configuration convention (all
`.env.example`-documented, fail-loud on a malformed value via the existing
`settings.py` `ConfigError` policy where applicable):

**3a. R2 had no connect/read timeout.** `services/worker/r2.py:40` `_client()`
previously built its boto3 `Config()` with no timeout at all — a hung R2
socket relied purely on the OS TCP stack, which can hang far longer than any
render job should wait.
- `services/worker/settings.py:211-212` added `r2_connect_timeout_s: float =
  10.0`, `r2_read_timeout_s: float = 60.0`; `services/worker/settings.py:277-
  278` reads them from `R2_CONNECT_TIMEOUT_S` / `R2_READ_TIMEOUT_S` through
  the pre-existing strict `_float()` validator (malformed → `ConfigError` →
  `SystemExit` at import, same as every other numeric setting in this file).
- `services/worker/r2.py:59-60` passes both into `Config(connect_timeout=...,
  read_timeout=...)`.
- Verified by `services/worker/tests/test_r2_timeouts.py` (new): default
  10s/60s when unset, both overridable via env, a malformed value raises
  `SystemExit` at import. `python3 services/worker/tests/test_r2_timeouts.py`
  → `✓ all r2-timeout tests passed` (exit 0).

**3b. No pixel-count ceiling before decode.** `services/worker/ffmpeg_render.py:238`
`_check_pixel_limit(width, height)` (pure) raises `RenderError` when both
dimensions are known and their product exceeds `MAX_SOURCE_PIXELS`
(`services/worker/ffmpeg_render.py:167`, default 8192×8192 ≈ 67 MP — a real
8K source is ~33 MP, so this only catches genuinely absurd inputs). Called
from `services/worker/ffmpeg_render.py:256` `probe_source()` right after the
ffprobe metadata call resolves `width`/`height` and **before** `SourceInfo`
is returned to any caller that might decode a frame — refusal happens from
metadata alone, never from a real decode. `probe_source(..., enforce_limit=
False)` bypasses the check for re-probing the worker's *own* already-produced
output.
- Verified by `services/worker/tests/test_resource_limits.py` (new),
  section 2: pure-function edge cases (1080p passes, 0×0 unknown-dims is not
  flagged, an over-ceiling pair raises with both dimensions named in the
  message) plus a real-ffmpeg/ffprobe integration case — synthesizes a
  320×240 fixture, probes its real dimensions, lowers `MAX_SOURCE_PIXELS`
  below that, confirms `probe_source` now refuses it, confirms
  `enforce_limit=False` bypasses the refusal.

**3c. Output size was only ever estimated, never actually capped.** The disk
preflight (`services/worker/worker.py`, ~300) estimates required free space
*before* encoding; nothing checked what ffmpeg actually produced.
`services/worker/ffmpeg_render.py:621-632` `render()` now stats the finished
output file and raises `RenderError` if it exceeds `MAX_OUTPUT_BYTES`
(`services/worker/ffmpeg_render.py:174-175`, from `MAX_OUTPUT_MB`, default
8192 MB) — refusing to upload it rather than shipping an oversized render.
- Verified by `services/worker/tests/test_resource_limits.py`, section 3:
  real ffmpeg encode of a 2s synthetic clip succeeds under a generous 1 GiB
  cap, then the *same* render is refused under a deliberately absurd 10-byte
  cap with `MAX_OUTPUT_MB` named in the error message.

**3d. `FFMPEG_STALL_TIMEOUT_S <= 0` silently disabled stall detection.**
Previously a bare `int(os.environ.get(...))`, so `0` (or any negative value,
or operator error) turned off the no-progress watchdog entirely — a wedged
ffmpeg would then run for the *full* `FFMPEG_TIMEOUT_S` (90 min default)
before anything noticed.
`services/worker/ffmpeg_render.py:122` `_stall_timeout_from_env(default=300)`:
a non-positive or non-numeric value now means "use the default" (logged),
never "disabled." The **only** way to actually disable stall detection is the
explicit `FFMPEG_STALL_DISABLED=1` (`services/worker/ffmpeg_render.py:118`
`_env_flag`), which is deliberately loud in its own log line about the
tradeoff. `services/worker/ffmpeg_render.py:157` `STALL_TIMEOUT_S =
_stall_timeout_from_env(300)` replaces the old bare cast.
- Verified by `services/worker/tests/test_resource_limits.py`, section 1
  (pure, no ffmpeg needed): unset → default; `0` → default (not disabled);
  negative → default; non-numeric → default; a genuine positive value is
  honoured; `FFMPEG_STALL_DISABLED=1` is the only input that produces `0`
  (actually disabled), even when `FFMPEG_STALL_TIMEOUT_S=0` is *also* set;
  `FFMPEG_STALL_DISABLED=0` does not disable.

Run: `python3 services/worker/tests/test_resource_limits.py` →
`✓ all resource-limit tests passed` (exit 0, ffmpeg/ffprobe were available in
this sandbox so both integration sections ran for real rather than skipping).

`.env.example` documents all of 3a-3d under "ffmpeg limits" / the R2 section
(`services/worker/.env.example:13-22`, `:50-70`).

---

## Fix 4 — cost-ledger spool durability, locking, and idempotency (external release audit finding 6)

**Bugs, all in `services/pipeline/cost_spool.py`:**
1. The spool defaulted to the system temp dir — ephemeral, and on Cloud
   Run/Modal-style hosts typically tmpfs, gone on restart, taking unflushed
   cost rows with it.
2. `flush()` read the whole file, sent each row, then rewrote the file with
   whatever failed to send — read → [network calls] → rewrite, with **no
   lock**. A concurrent `append()` landing inside that window was silently
   dropped by the rewrite (lost row), and two processes flushing at once
   could each successfully submit the same row (duplicate charge).
3. `cost_ledger` (`0001_init.sql:141`) had no idempotency key at all, so nothing
   downstream could even detect a duplicate submission, let alone prevent one.

**Fixes:**
- **Durable-by-default path.** `services/pipeline/cost_spool.py:77`
  `DEFAULT_DURABLE_DIR = "/var/lib/rendprop"`; `services/pipeline/
  cost_spool.py:87` `_default_dir_usable()` probes it once (mkdir + touch +
  unlink) and `services/pipeline/cost_spool.py:115` `spool_path()` now
  prefers it over the temp dir whenever `COST_LEDGER_SPOOL` isn't set
  explicitly, falling back to the temp dir with a one-time logged warning
  (`services/pipeline/cost_spool.py:104` `_warn_ephemeral_fallback()`) only
  when `/var/lib/rendprop` genuinely isn't writable on the host.
- **Same-host locking.** `services/pipeline/cost_spool.py:125-146`
  `_lock_path()` / `_locked()` take an exclusive `fcntl.flock` on a separate
  `.lock` sibling file (not the spool file itself — flock releases on *any*
  close of *any* fd on the locked file, so locking the file you also
  open/close repeatedly for reads would be self-defeating). `append()`
  (`:170`) and the **entire** read → send-loop → rewrite critical section of
  `flush()` (`:252`) now run inside `with _locked(path):`, closing the
  drop/duplicate window on one host. Explicitly documented as insufficient
  across separate hosts — that gap is what the idempotency key below is for.
- **Idempotency key.** `services/worker/db.py:723`
  (`record_cost`) and `services/pipeline/cost_ledger.py:140`
  (`CostLedger.record`) each generate `"idempotency_key": str(uuid4())`
  **once**, before the row's first attempt — every retry and every later
  spool/flush replay of that same logical charge carries the identical key.
- **Migration** `services/supabase/migrations/0025_cost_ledger_idempotency.sql`
  (0023 and 0024 already existed; the task named 0025 explicitly) adds
  `cost_ledger.idempotency_key` (nullable — no backfill needed) and a
  **partial** unique index `uq_cost_ledger_idempotency ... where
  idempotency_key is not null` — safe on a table that already has rows,
  since Postgres never treats two NULLs as equal in a unique index, so every
  pre-migration row is automatically exempt while every new row (always
  populated) is fully covered.
- **Making the key actually PREVENT duplicates, not just detect them.**
  `services/worker/db.py:678` `_insert_cost_row()` and `services/pipeline/
  cost_ledger.py:190` `_insert_once()` both now catch the resulting
  duplicate-key error (409 / `duplicate key` / SQLSTATE `23505` — matched via
  the shared `services/worker/db.py:182` `_looks_like_duplicate_key()` /
  `services/pipeline/cost_ledger.py:59` `_is_duplicate_key_error()` helpers)
  and treat it as **success**, not failure. This is the piece that makes the
  index load-bearing: without it, an already-landed charge would keep
  re-raising on every retry and permanently wedge `flush()`'s
  first-failure-stops-the-pass loop behind a row that can now never
  "succeed" any other way.

**Verified by:**
- `services/worker/tests/test_cost_spool.py` (new) — durable-path selection
  and ephemeral-fallback-with-warning; `fcntl.flock` genuinely blocks a
  concurrent `append()` while a lock is held (measured via a background
  thread and a timing assertion, not just a mock); `flush()` holds its lock
  across the full read → send → rewrite section, so a real append issued
  mid-flush survives instead of being clobbered by the rewrite.
- `services/worker/tests/test_job_lease.py`'s `test_record_cost_idempotency`
  (new) — `_insert_cost_row` swallows a duplicate-key `DBError` as success
  but still re-raises a genuine other error; `record_cost` always populates a
  non-empty `idempotency_key`; two separate `record_cost` calls get two
  *different* keys (never accidentally shared across unrelated charges).
- The migration itself, replayed for real rather than only checked for valid
  SQL: a fresh local Postgres 16 database, bootstrapped with this repo's own
  `services/supabase/tests/ci-bootstrap.sql` (the same Supabase-role/auth
  baseline CI uses), replaying every migration 0001→0025 in order — all
  succeeded. This repo's own migration invariants suite
  (`services/supabase/tests/`) then ran clean: **181/181 passed**. The
  "re-appliable" subset of migrations (0005b/0008b/0009 onward, per this
  repo's own CI convention — 0001-0008 are frozen non-idempotent history)
  was replayed a **second** time against the already-migrated database and
  came back as pure no-ops (`NOTICE: ... already exists, skipping`),
  confirming `add column if not exists` / `create ... if not exists`
  actually hold. Finally, manual `insert`s directly against
  `cost_ledger` confirmed the partial-unique-index semantics match what the
  Python duplicate-key detectors expect: two NULL `idempotency_key` rows
  coexist without conflict; two rows sharing one real key are rejected with
  a `23505 duplicate key value violates unique constraint
  "uq_cost_ledger_idempotency"` error — the exact string
  `_looks_like_duplicate_key()` / `_is_duplicate_key_error()` match on.

Run: `python3 services/worker/tests/test_cost_spool.py` →
`✓ all cost-spool tests passed` (exit 0).

---

## Full test run (this worktree)

```
python3 services/worker/tests/test_job_lease.py        # ✓ (extended: +3 new cases)
python3 services/worker/tests/test_hdr_tonemap.py       # ✓ (pre-existing, unaffected — run as a regression check)
python3 services/worker/tests/test_cost_spool.py        # ✓ (new)
python3 services/worker/tests/test_process_specific.py # ✓ (new)
python3 services/worker/tests/test_resource_limits.py  # ✓ (new)
python3 services/worker/tests/test_r2_timeouts.py      # ✓ (new)
```

All six exit 0 with a final `✓ ...` line. Each is a standalone script
(matching this repo's own `python3 tests/test_x.py` convention, not a pytest
suite): they use a local `check()`/`FAILURES` accumulator inspected only in
each file's own `if __name__ == "__main__":` block, and `sys.exit(1)` on any
failure — **`python -m pytest` on these files reports a false green** (it
collects the `test_*` functions and reports them "passed" without ever
consulting `FAILURES` or running the `__main__` block that does), so
`python3 <file>` is the only signal that means anything here. This was true
before this change and is unrelated to it; noting it because
`.github/workflows/ci.yml`'s `python-worker` job currently only byte-compiles
the worker and checks that `requirements.txt` stays exactly pinned — **it
does not invoke this test suite at all**, pytest-false-green or otherwise.
Neither the pytest false-green nor the missing CI invocation was in scope for
this task; both are flagged here rather than fixed.

Also run, mirroring what the `python-worker` CI job actually checks:
`python3 -m compileall services/worker services/pipeline` (clean) and a grep
confirming `services/worker/requirements.txt` still has no unpinned (`>=`)
dependency.

## What was not, and could not be, verified here

- No multi-host or real production network conditions were exercised for the
  cost-spool locking fix — only single-host `threading` simulations against
  a real `fcntl.flock` on a real filesystem, and the migration's unique
  index (which *is* the cross-host guarantee) verified directly against real
  Postgres. The `.env.example` and this doc both say explicitly that
  `fcntl.flock` only ever coordinates one host's view of one file.
  Wall-clock retry/backoff timing under real R2/Supabase outages, and the
  new R2 timeouts actually firing against a genuinely hung socket, were not
  exercised (would need a real or fault-injecting network, not available
  here) — only the resolved `boto3.Config` values were asserted.
- `MAX_SOURCE_PIXELS` and `MAX_OUTPUT_MB` were verified against real ffmpeg/
  ffprobe encodes available in this sandbox, but only at the small scale a
  fast test can afford (a 320×240 fixture, a 2-second clip) — not against an
  actual 8K source or a multi-gigabyte render.
- The local scratch Postgres database used to replay the 0001-0025 migration
  chain lives outside this git worktree (sandbox-only) and is not part of
  this commit.
