# WH-03 — fenced worker publication implementation

Base: `7d0b0ca3ab7fb579348480e40c43f89d5c222e31`, branch `fix/worker-publish-transaction-20260910`. This unit changes worker code and adds migration 0035. **No deployment or live database/storage operation was performed.** SQL runtime verification belongs to the coordinating agent's disposable PostgreSQL lane; do not call the production finding closed merely because the Python tests pass.

## Reproduced before editing

The actual old `db._replace_render_for_job()` patched `renders` by `job_id` without a lease or owner predicate. The existing loopback diagnostic put J1 at `ready`, owned by worker B, with `worker-B-output.mp4`. Calling the real helper as worker A replaced it with `worker-A-stale.mp4`; the job still said worker B/ready. `tests/reproduce_stale_publish.py` exited **1** with `AssertionError: stale publisher changed the newer owner output`.

The former real worker called `insert_render()`, then separate enhancement-result/photo/listing writes, then `finish_job()`. A heartbeat before publication did not protect the later render write, and failure between these writes could leave public media with a non-ready job. The removed `finish_job()` was owner-scoped but ran after the unscoped render replacement, too late to prevent it.

## Current implementation and consumer trace

- `services/supabase/migrations/0035_worker_publish_transaction.sql:13`: `publish_worker_render(uuid,text,integer,jsonb,jsonb,jsonb)` is one `SECURITY INVOKER` transaction, with an empty search path, explicit service-role identity check (`:44`), and EXECUTE revoked from public/anon/authenticated (`:189`). No user JWT supplies publication ownership.
- `0035:63`: resolve and lock the live listing first, then lock the job. This follows the listing-to-render lock direction used by the soft-delete trigger in `0011_app_publish_and_lifecycle.sql:596`, rather than opposing it. A deleted listing cannot be revived by this RPC.
- `0035:69`: require `source=worker`, matching worker id, and matching claimed attempt. For a new publication also require `processing` and an unexpired lease against **`clock_timestamp()`**, after locks (`:94`), plus an uploaded raw capture for that listing (`:98`). Database-clock checks after media/photo writes (`:169`) and after the final job/listing writes (`:182`) roll the transaction back if a wait outlasts the lease.
- `0035:78`: a ready job only accepts an exact replay of its stored request/owner/attempt/result receipt. Replays make no writes, including when the former lease has expired. A changed output or unreceipted ready job is an explicit conflict. This is not a general “ready means success” shortcut.
- `0035:114`: enforce duration/speed/key shape and measured outcome, restrict keys to the listing and attempt's UUID prefix, bound the envelope to 256 KiB and at most 100 photos. `0035:126` may replace a **pre-existing partial render** only for the current live claim, preserving its id and slug. A new render's random slug collision has a bounded five-attempt transaction-local retry; another unique constraint is not swallowed.
- `0035:152–185`: insert successfully uploaded enhancement photo rows, write the enhancement outcome and exact `worker_publish_receipt`, and set job/listing readiness in the same transaction as the render. Any write failure rolls all these writes back. The receipt is not a new external cleanup queue.
- `services/worker/db.py:541`: a legacy/unowned snapshot is refused before worker media work. `:548` calls only the RPC, retrying an ambiguous response once with the same frozen payload. `:579–596` validates UUID/time shape, job/listing identity, measured staging, media/scalars, ready status, and exact request/result receipt before success. A 2xx or partial body alone is insufficient.
- `services/worker/worker.py:452`: the actual process now publishes through that helper, including outcome and photos. `:475` marks artifacts published only after a validated receipt. No active `insert_render`, `_replace_render_for_job`, `set_enhancement_result`, `insert_photo`, `set_listing_status`, or `finish_job` helper remains; those unsafe alternates were removed.
- `worker.py:504`: explicit/uncertain publication failure preserves uploaded artifacts, performs no separate job-failure write, and rethrows so `--once`/`--job-id` exit nonzero. The existing run loop catches errors for later retry. A stale-owner refusal follows the existing abandonment path without touching the new owner's row or artifacts.

Actual consumers remain compatible: `/renders/:job_id` reads job status and then `renders` by job (`services/supabase/functions/renders/index.ts:217`, `:225`); `/tours/:slug` reads published `renders` and rejects deleted listings (`functions/tours/index.ts:326`, `:334`). The worker's old schema had no job output column; the additive receipt now binds the output to its attempt. Public response fields and the existing customer slug are unchanged. Render durations/speeds already round to two decimals in `services/worker/ffmpeg_render.py:637`, matching the database numeric columns.

## Verification actually executed

All worker commands used the isolated worktree and its existing `.venv`, a cleared environment, no `.env` files, synthetic provider/storage operations, and loopback-only fake PostgREST where existing tests require it. No production request was made.

```sh
env -i PATH=/opt/homebrew/bin:/usr/bin:/bin HOME=/Users/pilksclaes \
  services/worker/.venv/bin/python services/worker/tests/reproduce_stale_publish.py
```

Before edit: old diagnostic failed as described above. After edit: its replacement entrypoint runs the **actual** DB-helper/process regression suite and asserts exactly **14 tests, zero failures, zero skipped**, exit **0**. Removal of the old helper alone cannot satisfy this gate. Coverage includes exact retry, changed-payload/stale RPC rejection, 13 malformed 2xx receipt/identity variants, legacy/foreign claim rejection before HTTP, and actual process success/uncertain/stale/known-rejection branches. All HTTP sends are replaced with a fail-fast sentinel in these new tests. These mocks establish the Python call path, not SQL isolation.

Existing affected scripts also exited **0**:

| Script under `services/worker/tests` | Executed checks |
| --- | ---: |
| `test_job_lease.py` | 69 |
| `test_process_specific.py` | 17 |
| `test_cost_spool.py` | 23 |
| `test_resource_limits.py` | 19 |
| `test_r2_timeouts.py` | 6 |
| `test_reaper_snapshot.py` | 6 unittest tests |
| `test_verification_prerequisites.py` | 4 unittest tests |
| `test_stream_fallback.py` | 12 unittest tests |
| `test_lease_probe_fail_closed.py` | 10 unittest tests |

The first five total **134** explicit assertions. The next four total **32** unittest tests. With the new 14-test suite that is **180 executed checks/tests**, not 180 SQL or live-provider tests. The lease test formerly exercised pre-0016 optional outcome/hero writes and a separate finish helper. Those obsolete publication checks were replaced by an explicit no-unsafe-helper contract and the new worker/SQL suites; six separate-finish checks were removed, not silently counted as still executing.

Logs: `/tmp/rendprop-worker-publish.Gi3gUt/` (`python-final.log`, `job-lease.log`, and per-script logs). Original negative-before log: `/tmp/rendprop-openai-completion.MLnVNn/stale-publish-before.log`. `git diff --check` passed. Temporary logs are evidence from this run, not deployment receipts.

The final frozen-source rerun is recorded in `/tmp/rendprop-worker-publish.Gi3gUt/source-bound-results.json` with separate `bound-*.log` outputs. The runner hashes every tracked and non-ignored source file before and after all ten commands, asserts that the complete path/content manifest is unchanged, requires each exact test/check count and zero skips, and records the aggregate digest and command exit codes. This binds the entire worktree source, including the SQL that still needs runtime execution, rather than just the edited Python files.

### SQL fixture prepared, NOT executed by this agent

`services/supabase/tests/worker_publish_transaction.sql` refuses every database except root's socket-only `rendprop_audit` at `/tmp/rendprop-db-audit-*/cluster`. It runs all fixture/trigger changes inside a rolled-back transaction, with ON_ERROR_STOP enabled. Expected gate: exactly **20** registered assertions and `WORKER_PUBLISH_TRANSACTION_PASS_20`.

It invokes the real RPC under postgres-without-service-role, anon, authenticated, and service_role. Positive and rejection paths cover current owner, late A while B processes and after B wins, same worker id/old attempt, exact replay, changed ready payload, legacy partial replacement preserving id/slug, expired lease, app source, deleted listing, photo-write rollback, forced final-job-write rollback, and forced database-clock expiry during both a delayed insert and a delayed final job update. The final-update case was added after independent parent review caught that a pre-update time check alone could expire during that update's trigger. A successful runtime gate still must be reported by the coordinating agent; authored SQL is not runtime proof.

## Deployment order and open limits

1. Independently run the migration plus this fixture and migration replay in a new disposable database. Inspect actual service-role grants/schema and RPC availability before rollout.
2. Apply 0035 through the approved migration process **before** the new worker. Drain/stop old worker binaries before treating publication fencing as deployed: an old binary with service-role credentials can still use its former direct table writes. This patch is not a new database prohibition on all possible service-role writes.
3. Verify a controlled worker publication and exact replay in an authorized test environment, including the real PostgREST JSON response and deployment revision. No such environment call happened here.

**Not fixed by this unit:** durable remote-artifact cleanup after a crash or lost/uncertain response; cleanup of superseded legacy media/old photos; pre-publication provider spend by an eventually stale worker; process-restart recovery of a not-yet-committed payload; full lease fencing of advisory heartbeat/progress/failure/release paths when process worker ids are deliberately reused; post-publication cost-spool durability/configuration. Infra cost estimates still run best-effort after publication and can be reconciled separately. No model, route, token/cost cap, Apple submission, or deployment settings were changed.

The transaction deliberately no longer publishes on pre-0015/pre-0016 schema. Existing claim probing can identify legacy schemas, but a legacy claim is refused before rendering by the new process. A missing 0035 RPC is an explicit publication failure, not a reason to restore unfenced writes. The current listing-ready transition retains prior worker semantics; this unit is not a redesign of archived/expired listing lifecycle.
