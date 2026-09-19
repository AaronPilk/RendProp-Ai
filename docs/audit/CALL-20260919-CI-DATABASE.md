# Database CI follow-up — 2026-09-19

The first pushed candidate (`a6826e2`) passed all new reflection tests in the
PostgreSQL16 service container: **51 SQL assertions, 0055 replay, 51 assertions
again; 46 real parallel transactions with 43 checks**. The Supabase edge job passed
**802 tests** and typechecked every function.

- [PostgreSQL16 service job](https://github.com/AaronPilk/RendProp-Ai/actions/runs/35472247190/job/105975199557)
- [Supabase edge job](https://github.com/AaronPilk/RendProp-Ai/actions/runs/35472247190/job/105975199550)

The same run exposed four older invariant failures and an unsupported historical
replay order. A separate fresh local database using only migrations0001–0054 and
invariants with bytes verified against `7bcc624` reproduced exactly the same
failures. The cluster was stopped. Its receipt is
`/tmp/rendprop-erase-pg-ujune1mg/receipt.json`.

| Existing failure | Cause and bounded response |
|---|---|
|131 — admin reads plan entitlements|Test expected 6 rows before 0050 added brokerage. Test now asserts the exact seven known plan names; no grants or plan values changed.|
|142 — six app tasks have exact legacy rows|Real fallback regression:0052 appended prose to photo rows' `note`, while `router.ts` still queries exact `note='legacy'`. 0056_active_photo_fallback marks the six already-enabled Gemini3.1 photo routes. The runtime requires enabled=true and full eligibility, and fails closed rather than using hardcoded photo constants. Model IDs, prices and enabled flags stay unchanged; disabled rows are untouched. The invariant retains exact equality.|
|155 — Astra answer headroom|Existing documented kept-red condition: agent-reel token ceiling 700 equals visible answer 700; invariant intentionally requires greater. The existing exact-name exception, ceiling and assertion remain unchanged.|
|249 — notification RPC privileges|The broad name query also included0053/0054's invoker redaction trigger. Test now distinguishes callable RPCs from trigger functions, checks all 11 RPCs are service-only definers, and verifies redaction remains an invoker bound to the enabled before-update outbox trigger.|
|Replay0050 after0051|0051 replaces an overload; replaying0050 backwards makes its unqualified `COMMENT ON FUNCTION` ambiguous. Migrations0001–0054 remain untouched. The replay harness builds a second fresh database, applies each replayable migration twice at its historical schema point, then applies later migrations in order.|

`legacy_photo_fallback.sql` reconstructs the 0052 failure inside a rolled-back
transaction: exact lookup finds 0 photo fallback rows before repair, 6 afterward.
It applies 0056 twice, compares every non-note route field against the snapshot, and compares every disabled row in full. A disabled-only task stays unavailable after another migration replay.
CI also replays 0055 and 0056 explicitly on the fully migrated database.

The database-runner control-flow suite passes31 tests, including a new assertion
that0050's second application precedes0051 and that final invariants run against
the second database. The invariant-source suite passes 9 tests. New production
scope is limited to 0056 and the photo fallback/refund paths; no old migration, provider enablement, customer media,
App Store setting, pricing value or global spatial flag was changed.

Original container logs are retained outside Git at
`/tmp/call-db-container-full-35472247190.log` and
`/tmp/call-edge-full-35472247190.log`. The full candidate still requires the next
CI result; the first run's successful reflection checks are evidence of those
checks alone, not a claim that the whole run passed.

An initial uncommitted draft that restored markers on disabled photo rows was
rejected in review and deleted. The historical resolver forcibly returns legacy
rows as enabled, so that proposal would have made disabled rows runnable despite
leaving their database boolean unchanged. It was never committed or deployed.

The accepted repair covers the entire `photo.*` namespace. The six active Gemini3.1 rows keep
their existing 6.7¢ price, models, enabled flags and all other non-note fields.
Flag-off fallback additionally applies plan, capabilities, retirement and privacy
checks. Missing or ineligible photo authorization produces503 before any provider
call; the actual ai-photo handler returns both quota meters once on that path.
Existing non-photo forced-enabled legacy resolution and hardcoded fallback remain
unchanged and are covered as a stated scope limitation.

Native PostgreSQL17 receipt `/tmp/rendprop-erase-pg-7hngt2gu/receipt.json` passed:
all migrations0001–0056; explicit0055/0056 replay;51 reflection SQL assertions
twice;46 real parallel transactions with43 checks; active-photo exact lookup and
immutability checks; a second database with historical-point double application
of every replayable migration,266 invariants with only the unchanged155 kept red,
and reflection/fallback checks afterward. The owned cluster is stopped. This is
local proof; the next pushed candidate still needs PostgreSQL16 CI confirmation.

Independent review also found that inherited prompt-object keys (`constructor`
and `__proto__`) could produce an unrecognized photo task and bypass an initial
six-task predicate. The final handler validates the eight supported edit modes
before quota, and the fail-closed resolver covers every `photo.*` task. Executable
regressions exercise both inherited keys, an unknown edit, and missing/disabled
routes for future photo tasks with the router flag both on and off. User-facing
503 text describes a temporarily unavailable photo tool without provider jargon.

Independent actual-handler proof retained outside Git at
`/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-photo-route-proof-auz65vvv/`
(`baseline-receipt.json`, `fixed-receipt.json`, frozen source hashes, `proof.mjs`).
Both7bcc624 and the intermediate six-task candidate accepted the two inherited
names with empty routes:200, two mocked quota debits and one mocked provider call.
The final fix returns400 before quota or provider for those inputs; ordinary
`sky` with missing authorization returns503 and refunds both meters once. This is
an existing input bug plus a bypass of the intermediate boundary, not a claim
that the current repair introduced malformed-edit acceptance. All external
network and provider calls in this reproducer were mocked.

Final local verification after the namespace/input/refund repair: **850 edge tests
passed,0 failed**, including48 new executable photo fallback/handler tests;
16 existing router tests also pass. The separate actual-photo audit matrix passes
309 assertions, and `deno check` passes for ai-photo. The canonical committed
regression entrypoint is
`services/supabase/functions/_shared/photo_route_fallback_test.ts` (normal edge CI
automatically discovers it). Full local edge output is retained at
`/tmp/call-edge-active-photo-final.log`. No live provider or production database
was called by these checks.

CI run35473762115 at155aa0e passed the PostgreSQL16 service-container job,
including fresh migration replay, active-photo immutability checks, reflection
51+51 assertions,46 parallel transactions/43 checks, historical double replay and
both266-invariant runs with only155 kept red. The edge job passed all850 tests and
function typechecks. Logs: `/tmp/call-service-db-35473762115.log` and
`/tmp/call-edge-35473762115.log`.

The separate disposable publication runner then failed its first negative fixture:
`negative_astra_paid_gates.sql` correctly refused `rendprop_replay`, because it
accepts only the owned `rendprop_audit` database. This was introduced by the new
second-database harness: its connection remained on the replay database after
inventory checks. The bounded repair restores the original owned audit connection
before paid/publication negative controls. No database-name guard, SQL assertion
or migration was weakened. A new control-flow regression fails specifically at
`negative-paid-gates` against155aa0e and passes after repair (32 runner tests).
Full native verification and subsequent CI confirmation are recorded separately.
