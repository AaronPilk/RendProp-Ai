# Actual database execution — September 10, 2026

This is a local **disposable PostgreSQL17.11** result, not a hosted Supabase
attestation. No existing database, customer records, credentials, provider or
Apple service was used. Overall result remains **FAIL / exit1**.

## Latest expanded publication run — 19:53 Eastern

Root executed clean source **`a81a1432bac21a19b25c82f2ace396c67fa08cef`** on
`ci/publication-database-fixtures-20260910`. The tested SQL/runner was merged
unchanged into `audit/full-regression-20260910`; later CI wiring does not change
the SQL. Command: `PYTHONDONTWRITEBYTECODE=1 python3 tools/audit/run_database_regression.py`.
Receipt: `/tmp/rendprop-db-audit-h9sm8997/receipt.json`.

| Executed gate | Result |
| --- | --- |
| Apply38 migrations, including0035 and0036 | All exit0 |
| Replay30 migrations | All exit0 |
| Initial/replayed198 invariants |197 pass, same1 fails on each pass |
| Worker publication fixture |22 registered checks pass on four runs |
| Upload publication fixture |19 registered checks pass on two runs |
| Actually remove worker owner/attempt predicates |Exit3, `stale A accepted`; original restored and positive fixture passes |
| Actually remove raw-video predicate |Exit3, `photo capture accepted as raw video`; original restored and positive fixture passes |
| Actually remove scalar JSON-type/precision guards |Exit3, `noncanonical scalar accepted` for30.001; original restored and positive fixture passes |
| Actually disable upload publication trigger |Exit3, `Missing publication rejection: completed: uploaded = false`; original restored and positive fixture passes |
| Paid-route data controls |Six expected real SQL outcomes pass |
| Corrupt team entitlement in actual synthetic table |Real invariant suite rejects it, exit3 |
| Stop only the owned cluster |Exit0, PID gone, `clusterStopped=true` |
| Overall runner |**Exit1, `accepted=false`**, preserving the headroom mismatch |

The current runner also passes30 mocked control-flow tests. These include
missing fixture markers, a mutant exiting0 and a mutant failing for the wrong
reason. Those are not30 additional executed SQL assertions. Database-clock
expiry tests exercise delayed writes/triggers; they are not an internet
multi-client load test or a production PostgREST/R2 transaction.

### Corrected negative-control interpretation

The preceding attempt on `b0d0621` retained evidence in
`/tmp/rendprop-db-audit-_5nqavoh/receipt.json`. Removing scalar guards first tried
`duration_s=0.004`; PostgreSQL's **existing** `chk_renders_duration`
(`0006_p0_rpcs.sql:371`) already rejected its rounded0.00 with23514. The runner
correctly rejected this as **the wrong negative-control failure**, stopped its
cluster and returned1. It did not finish the upload fixture on that run.

There is no demonstrated ready-zero-duration defect. The actual input mismatch
is30.001 becoming30.00 while still satisfying the old bounds. The fixture now
tries that case first; the latest run above proves the removed precision guard
accepts it, and the repaired function rejects it with WP003. The grouped scalar
check also covers0.004,2.004 speed, numeric strings and a boolean. Do not present
the failed intermediate run as a successful negative control.

## Earlier publication-transaction run — 19:45 Eastern

Source `4e44afff6ceb71a17e86da74600342c3aedb9b91`, clean branch
`ci/publication-database-fixtures-20260910`. Same command below. Actual receipt:
`/tmp/rendprop-db-audit-8e9l3gmm/receipt.json`.

- All38 migrations through0036 applied;30 replayed; every migration exit0.
- Both invariant runs retain197/198 pass, with the same token-headroom failure.
- **20 worker transaction assertions and19 upload trigger assertions passed,
  each twice** (initial fixture and after restoring deliberately broken guards).
- Worker ownership/attempt predicates were actually disabled in the owned
  database: the real fixture failed `stale A accepted`, exit3. Original0035
  restored; the20-check fixture passed again.
- Upload publication trigger was actually disabled in that database: the real
  fixture failed `Missing publication rejection: completed: uploaded = false`,
  exit3. Original0036 restored; the19-check fixture passed again.
- Six paid-route negative outcomes and the corrupted team-entitlement control
  passed. Exact owned cluster stopped, exit0, PID gone. Receipt accepted=false
  and overall runner exit1 honestly preserve the unrelated headroom defect.
- Updated runner's30 mocked safety/control-flow tests passed. They are not30
  additional real database assertions.

This verifies bounded SQL behavior, not live PostgREST/R2 publication or a
production rollout. Cross-review then found two additional worker RPC input
guards (noncanonical numeric precision, photo-backed worker job) and a single-copy
MIME metadata race; those follow-ups were still being implemented at this
checkpoint. Do not use the20/19 result to claim those later changes passed.

## Exact source, command and evidence

Source: `ba59f3d94bb8189bb7f14ca88c20694eb607d922`, clean before execution.
Branch: `audit/database-regression-20260910`.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 tools/audit/run_database_regression.py
```

Evidence: `/tmp/rendprop-db-audit-s_7bv818/receipt.json`. The receipt includes
per-command exits/log hashes, all migration and test SQL hashes, and the runner
hash. The synthetic database/data/logs are retained privately for diagnosis.
The runner verified the exact new cluster identity and an empty TCP listen
address before executing SQL. It stopped that cluster successfully afterward.

| Gate | Actual result |
| --- | --- |
| Bootstrap + all36 migrations, through0034 | Every command exit0 |
| Initial invariant suite | 198 assertions;197 passed,1 failed; psql exit3 |
| Replay28 replayable migrations | Every command exit0 |
| Replayed invariant suite | Same198 names/order;197 passed, same1 failed; exit3 |
| Actual paid-route mutations | Six expected outcomes over baseline/two negative fixtures; exit0; transaction rolled back |
| Deliberately corrupt actual team entitlement | Real invariant suite rejected it, exit3 |
| Stop exact owned cluster | Exit0; PID file gone; receipt `clusterStopped=true` |
| Overall acceptance | `accepted=false`; runner exit1, not a green report |

The paid-route negative fixture changes the synthetic `copy.agent_reel` row to
free and then changes its first-seat identity while retaining three total Astra
rows. It executes the **same included SQL predicates** as the main suite. This
detects both a free-tier exposure and the previous count-only/bare-SELECT issue.
The team mutation is likewise actual synthetic table data, not mocked output.

## Remaining red assertion

Assertion155: **each astra ceiling clears its route's visible answer and stays
under the code clamp**.

Actual values from the SQL result:

- `copy.shotlist`: ceiling2400, caller-visible maximum1600 — passes.
- `copy.reel_script`: ceiling1200, caller-visible maximum700 — passes.
- `copy.agent_reel`: ceiling700, caller-visible maximum700 — fails strict `>`.

`services/supabase/migrations/0034_agent_reel_and_video_ladder.sql` seeds the
700-token route ceiling. `services/supabase/tests/invariants.sql` retains the
existing headroom predicate; it was **not** changed to `>=` to get a pass.
The Responses adapter lets the row ceiling override the caller's token limit.

This proves a **configuration/invariant mismatch**, not that every real reel is
truncated. A maximum answer size is not a measured minimum, and no paid response
was generated in this run. The next evidence must cover maximum-shape valid EDLs.
Explicit Responses `status=incomplete` rejection has since been implemented and
tested; see `OPENAI-RESPONSE-COMPLETION.md`. That repair does not resolve this
budget mismatch. Do not silently raise token budgets, rewrite model choices or
label the whole pipeline verified.

## What changed in the tests (not the product policy)

The first run against38143db applied all36 migrations but had194 registered
assertions and six failures. Five failures were stale expectations superseded
by0032/0034: trial render quota, feature entitlements, worker quota fixture,
number of parameterized routes, and Astra task allowlist. They now assert the
current exact seeded contracts, not a weakened wildcard. The worker fixture
completes each of the three trial jobs before submitting the fourth, so the
monthly quota is exercised without accidentally testing the in-flight cap.

Two paid-plan checks were plain SELECTs, absent from `_inv` and the terminal
failure count. They are now registered and share SQL with the negative fixture.
Seven source-wiring tests pass; those are additional static checks, not database
execution. The independent review and patch are documented in
`DATABASE-INVARIANT-REVIEW.md`.

The harness was independently challenged with shortened result tables, timeout
and failed-stop fixtures. It now requires198 unique, contiguous registered
assertions, explicit paid-gate names, matching identities after replay, matching
exit/footer, and treats null as failure. It records timeout partial output and
writes the terminal receipt even when cleanup fails. These changes do not make
a failed product invariant pass.

## Coverage limits

The bootstrap supplies a minimal synthetic Auth schema and roles. SQL policy,
RPC and migration assertions are valuable but do **not** prove live JWT
verification, PostgREST behavior, concurrent HTTP requests, production secrets,
deployed migration parity, rate-limit cron, backup/restore, actual R2/Stream
cleanup or hosted task scheduling. The bounded upload/worker publication defects
are repaired and covered locally above; physical upload-cost containment,
durable artifact cleanup and deployment verification remain open. No “all
backends green” or release GO follows from this run.
