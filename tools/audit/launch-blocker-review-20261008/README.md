# Diagnostic launch-boundary reproductions

These are the command bodies exercised during the review of `f17d2bd` on 2026-10-08. They demonstrate existing defects; their execution is **not a passing release gate**. See `docs/handoff/CODEX-CLAUDE-LAUNCH-BLOCKERS-REVIEW-20261008.md` for observed values and required behavior after fixing them.

Use only an owned disposable PostgreSQL database bootstrapped with `services/supabase/tests/ci-bootstrap.sql`, all current migrations, and an explicit ceiling-mode configuration. The `services/supabase/tests/launch_blockers_pg.py` harness documents the local bootstrap/migration process. Do not execute these against Supabase or another hosted database. Each script uses synthetic fixtures in `BEGIN`/`ROLLBACK`; all clock boundaries are modeled by synthetic timestamps, not an actual wait. No provider is called.

Run with a local socket/port/database from that disposable instance:

```sh
psql -X --set=ON_ERROR_STOP=1 --host=LOCAL_SOCKET --port=LOCAL_PORT --dbname=LOCAL_DATABASE --file=tools/audit/launch-blocker-review-20261008/money-boundary.sql
psql -X --set=ON_ERROR_STOP=1 --host=LOCAL_SOCKET --port=LOCAL_PORT --dbname=LOCAL_DATABASE --file=tools/audit/launch-blocker-review-20261008/financial-retention-sandbox.sql
psql -X --set=ON_ERROR_STOP=1 --host=LOCAL_SOCKET --port=LOCAL_PORT --dbname=LOCAL_DATABASE --file=tools/audit/launch-blocker-review-20261008/sandbox-current-state.sql
```

- `money-boundary.sql`: mixed photo/video admission; trial video ignoring a zero sponsor pool; successful holds disappearing without ledger confirmation; unresolved liability across calendar rollover. Its assertions describe the defects in the reviewed snapshot and should be replaced by refusal/conservation assertions when fixes land.
- `financial-retention-sandbox.sql`: one payment receiving a fresh allocation at month-end; older active receipt after refund; stale trial response after paid upgrade; actual retention queue-to-consumer refusal.
- `sandbox-current-state.sql`: old expired receipt replay during a different valid trial and during a paid plan. Compare returned state against the current effective database plan and deadline.

The second and third scripts print diagnostic results rather than asserting corrected behavior. Convert each case into a regression test of the actual production admission/consumer after implementation. The prior private transcripts preserve the observed output. No network access, credential or billed generation is needed to reproduce these bugs.
