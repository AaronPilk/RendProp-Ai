# Independent review of the isolated database gate

2026-09-10. Original inspected source: `38143db49c55e9131706c65d580fcf08ccf55091`.
Correction branch: `test/db-invariant-contract-20260910`.

## Conclusion

The initial failure is real **test-contract drift plus one unresolved budget-policy mismatch**, not a bootstrap/migration execution error. Do not call the whole database green, and do not change product quotas merely to satisfy stale tests.

Read-only evidence independently inspected: `/tmp/rendprop-db-audit-x9p57op3/receipt.json`, `identity.log`, `version.log`, and the complete relevant results in `invariants-initial.log`. The receipt records PostgreSQL 17.11, 36 migration commands with exit 0, the actual invariant command with exit 3, `accepted=false`, and the stop command with exit 0. Cluster identity was `/tmp/rendprop-db-audit-x9p57op3/cluster||rendprop_audit`: empty TCP listen address, correct private cluster and database. **This review did not start or connect to any database.**

The original gate printed **194 registered assertion rows: 188 true, 6 false**, then raised `INVARIANTS FAILED: 6 assertion(s) did not pass`. `invariants.sql:1860` counts `pass is distinct from true`; the exception at `:1862` causes psql's exit 3 under `ON_ERROR_STOP`. The runner's `run()` correctly rejects that exit at `tools/audit/run_database_regression.py:52`, then stops its own cluster in `finally` at `:95`. Replay and the runner's negative control were **not reached**, not passed.

The synthetic auth bootstrap supplies the roles, `auth.users`, JWT GUC helpers and default privileges the tests require (`services/supabase/tests/ci-bootstrap.sql:22`). These six failures are literal entitlement/route-value comparisons and a quota fixture matching newer seeds. Nothing in the failure evidence points to bootstrap auth semantics as their cause. Plain Postgres is still not actual hosted Supabase Auth or HTTP Data API proof.

## Exact original failures and diagnosis

References in this table are to the original `38143db` snapshot, before this test-only correction.

| Assertion | Original evidence | Independent diagnosis |
|---|---|---|
| 18: trial render cap expected 1 | `invariants.sql:165`; observed `trial=3 free=1` | **Stale test.** Migration `0032_seats_and_invites.sql:108–121` deliberately sets trial to 3 renders and free to 1. Paid 8/25/80 caps remain unchanged. |
| 19: trial/free feature matrix | `invariants.sql:179–189`; mismatches `trial, free` | **Stale test.** `0032:112` sets trial to 60 edits, 4 reels, 2 aerials, 1 Topaz, 1 seat, 1200¢ COGS ceiling; `:113` sets free to 5/0/0/0/1 and 300¢. Old test still expects identical 10/1/2/1/1 allowances. |
| 76: worker job #2 expected RP402 | `invariants.sql:622–630`; observed `no error raised` | **Stale fixture.** A three-render trial must permit #2. Its new boundary is #4, after three completed worker jobs. |
| 145: exactly two params rows | `invariants.sql:1332–1339`; observed three | **Stale test.** `0034_agent_reel_and_video_ladder.sql:69–76` intentionally adds the third Astra row with params for `copy.agent_reel`. |
| 154: Astra restricted to two tasks | `invariants.sql:1459–1463`; observed `copy.agent_reel (1)` | **Stale allowlist.** The new task is text-out edit decisions, not media generation; it belongs alongside shotlist/reel_script as seeded by `0034:69`. |
| 151: reasoning ceiling must exceed requested visible budget | `invariants.sql:1412–1422`; observed `copy.agent_reel ceiling=700 visible=700` | **Keep failing.** Seed `0034:71` supplies low reasoning and 700 total output tokens; actual caller `ai-copy/index.ts:220`, `:832` requests 700. `openai.ts:175` prioritizes the seed over caller, and `:196–201` sends that exact budget. This conflicts with the existing headroom rule; it is not caused by the bootstrap. |

The sixth item does **not** prove that every live reel is truncated: a 700-token requested maximum is not a measured minimum response size. It does show that the promised visible allowance and reasoning do not have separate headroom. OpenAI documents reasoning and visible output sharing the output limit; incomplete results can occur when the budget is exhausted. [Official reasoning guide](https://developers.openai.com/api/docs/guides/reasoning). No paid model call or real-output benchmark was performed here.

Narrow next step for that item: test a full twelve-window reply and the adapter's `status=incomplete`/`max_output_tokens` response handling with synthetic fixtures; obtain an explicit budget/quality decision before changing the seeded ceiling. Current `openai.ts:210–216` accepts text without checking completion status. Do not simply change the assertion from `>` to `>=`, remove agent-reel from it, disable its row, or increase a vendor budget in an audit test patch.

## Separate verification defect: two plan checks only printed

Original `services/supabase/tests/invariants.sql:1372` and `:1378` are bare SELECT statements, missing `insert into _inv(name, pass, note)`. One already prints false (`both gpt-6-astra rows...`) but is not among the six counted failures. Therefore those two checks could never enforce their contract even if every registered check passed. This is a test-gate defect, not proof that current production exposes Astra to free users.

The correction registers both checks and requires exactly three explicit seats: OpenAI/Astra position 1 on shotlist + reel_script gated to Starter, and agent_reel gated to Pro. An aggregate count of three arbitrary paid rows is insufficient.

## Test-only changes made

- `services/supabase/tests/invariants.sql`: independent literal entitlement matrix updated to exact current seeds, including renders/COGS/price; expected rows are LEFT JOINed so missing plans cannot disappear from the comparison. Trial worker jobs #1/#2/#3 are each asserted to succeed and completed inside the isolated fixture before #4 must raise RP402. This matters because `0015_job_lease.sql:198` checks max-three-in-flight **before** monthly RP402 at `:211`. No production function or plan row was changed.
- Same file: params allowlist requires exactly the three first-seat OpenAI/Astra task identities; text-out task allowlist includes agent_reel. The existing two-route shift/contiguity checks remain about the two routes actually shifted in 0030. The strict `ceiling > visible and ceiling <= 8000` assertion remains intact and is expected to keep reporting agent_reel.
- `services/supabase/tests/invariant_astra_paid_gates.sql`: both paid-tier predicates are real registered assertions. `invariants.sql` includes this file using psql `\ir`.
- `services/supabase/tests/negative_astra_paid_gates.sql`: guarded to the disposable `rendprop_audit`, empty TCP listeners, `/tmp/rendprop-db-audit-*/cluster` identity. It runs the **same included predicates** on the baseline, an agent-reel free-tier mutation, then a wrong first-seat position with the total row count still three. It asserts six exact outcomes, then rolls back. A missing `INSERT` fails its required row count. An error closes the psql transaction without commit. **Authored, not executed by this subagent.**
- `tools/audit/test_database_invariant_sources.py`: source-wiring tests only. Checks real INSERT/SELECT adjacency, exact task/plan predicates, include wiring, current trial literals and preserved strict headroom. Negative controls remove registrations, weaken `>` and restore old trial values; each must be rejected.

No migration, provider adapter, routing row, runtime secret, Apple setting or database was modified by this correction unit. Supabase and Postgres skills guided the migration-vs-test distinction and privilege/test-scope review; no schema change was authorized or attempted.

## What actually ran after editing

```text
env -i PATH=/opt/homebrew/bin:/usr/bin:/bin PYTHONDONTWRITEBYTECODE=1 \
  /opt/homebrew/bin/python3 tools/audit/test_database_invariant_sources.py
Ran 7 tests in 0.001s — OK; 0 skips; exit 0.
git diff --check — exit 0.
```

These are **seven source-wiring tests, not seven SQL/database tests**. They do not parse or execute PostgreSQL. `rg` confirmed the new loop, #4 RP402 assertion, gate include and unchanged headroom predicate before running them. Corrected SQL must still be run by the root agent in its explicitly isolated harness.

## Root integration requirements

1. Hash/include both newly added SQL files in the database evidence source manifest. A receipt for `invariants.sql` alone no longer covers its included predicates.
2. Run `negative_astra_paid_gates.sql` separately on the owned disposable cluster with `ON_ERROR_STOP=1`. Require its explicit six-outcome success marker and exit 0; do not infer success from SQL output alone.
3. Run initial and replayed invariants. Static expected registered count is **198** (original 194 + two now-registered checks + two additional allowed worker jobs), with the agent-reel headroom failure still expected. This count/result is a prediction until the real isolated rerun, not verification evidence.
4. Preserve the full failed rows and never label accepted=true merely because the remaining failure is known. Keep replay evidence separate from an all-green release verdict.

The original runner has one unrelated evidence-resilience improvement worth retaining: receipt writing should survive a stop-command error and subprocess timeouts, not depend on the successful path through `run("stop", ...)`. It is not the cause of the observed invariant failure; this run did stop successfully. The root owns that runner change.
