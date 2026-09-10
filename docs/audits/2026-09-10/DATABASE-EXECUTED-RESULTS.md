# Actual database execution — September 10, 2026

This is a local **disposable PostgreSQL17.11** result, not a hosted Supabase
attestation. No existing database, customer records, credentials, provider or
Apple service was used. Overall result remains **FAIL / exit1**.

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
was generated in this run. The next evidence must cover maximum-shape valid EDLs
and explicit Responses `status=incomplete` handling. Do not silently raise token
budgets, rewrite model choices or label the whole pipeline verified.

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
cleanup or hosted task scheduling. Existing upload and stale-worker publication
findings remain open. No “all backends green” or release GO follows from this run.
