# Database runner control-flow regression tests — 2026-09-10

This unit adds only `tools/audit/test_database_runner.py` and this note. It does not modify the database runner or SQL. Test branch: `test/database-runner-safety-20260910`, based on integration audit commit `7d0b0ca3ab7fb579348480e40c43f89d5c222e31`. The runner repair is the separate root-owned commit **`ba59f3d94bb8189bb7f14ca88c20694eb607d922`**.

## Actual negative-before and positive-after

The tests execute the actual runner's `main()` with database subprocesses replaced by explicit mocks. Import-time subprocess calls and any unmocked `Popen` are forbidden. Source reads, synthetic small local logs, and mocked result-table parsing are real; no PostgreSQL process, SQL execution, network, provider, credential read, Xcode, or simulator is involved. Signal tests call the installed Python handler directly; they do not send an OS signal.

Commands from the test worktree, using its existing `python3`:

```sh
python3 tools/audit/test_database_runner.py --runner '/Users/pilksclaes/Rendprop AI/database-regression-20260910/tools/audit/run_database_regression.py' --source-ref 4c91340f5857d92804a43cd2775c2530242ee1b8 CoreRegressionTests
python3 tools/audit/test_database_runner.py --runner '/Users/pilksclaes/Rendprop AI/database-regression-20260910/tools/audit/run_database_regression.py' CoreRegressionTests
python3 tools/audit/test_database_runner.py --runner '/Users/pilksclaes/Rendprop AI/database-regression-20260910/tools/audit/run_database_regression.py'
python3 tools/audit/test_database_runner.py --runner '/Users/pilksclaes/Rendprop AI/database-regression-20260910/tools/audit/run_database_regression.py' -k DOES_NOT_EXIST
```

Results, in order:

1. Frozen old runner `4c91340`: **3 failed, 0 passed, 0 skipped; exit 1**. It accepted a shortened one-row suite, lost the whole receipt on stop failure, and omitted a timed-out command and its partial output.
2. Repaired actual file: **3 passed, 0 failed, 0 skipped; exit 0**, running the exact same three test methods.
3. Full repaired suite: **27 passed, 0 failed, 0 skipped; exit 0**. Parameterized subcases are not reported as extra tests.
4. Deliberately empty test selection: **0 tests; exit 1**. The gate explicitly refuses zero tests and any skipped tests; failures cannot be converted into a green command by the CLI wrapper.

Logs: `/tmp/rendprop-db-harness-review.Plxh03/permanent-before.log`, `permanent-core-after.log`, `permanent-after.log`, and `zero-selection.log`. Each log prints a unique retained directory containing only synthetic per-command logs/receipts. Old source SHA-256: `f2930feba63c17aa3a72768b0dcdd4ce1c75cd60f3c5ccc0c0163982354639df`; repaired actual source SHA-256: `4e9d38c17ab039e1eacda20709aa214e98a3855521cdfbbea066e31ece022aaa`.

## Coverage and limits

The expanded cases enforce the current 198-row contract, contiguous sequence IDs, all three required paid-plan/entitlement labels, unique names, identical ordered names after replay, and exit/footer consistency. Negative fixtures include 1/197/199 rows; missing/duplicate/renamed/reordered names; null or false results with dishonest green status; wrong failure counts; missing notices; and wrong command exits. A correctly reported null result remains a real red assertion while replay and paid negative evidence are collected—it never becomes `accepted=true`.

Receipt tests cover byte/text/empty timeout output and its hash, failed or timed-out stop, stale synthetic PID files, simultaneous original/cleanup errors, and signal handler restoration. They also check clean-source refusal before database commands, owned socket identity refusal before bootstrap, `/tmp` disk checking, sanitized connection environment, inclusion of all current test SQL plus runner hashes, and paid-negative marker/exit agreement.

These are **control-flow and evidence-accounting tests**, not 27 database invariants. Synthetic names beyond the three mandatory labels are intentionally invented, so this suite does not authenticate the other 195 SQL assertion identities or independently prove migration completeness. SQL predicates, RLS, actual process shutdown, real signals/kill races, hosted Supabase behavior, and the shared negative SQL's six outcomes still require the separate root-owned isolated database run. No mocked passing receipt is database acceptance evidence. The Supabase skill informed the strict separation between offline harness checks and database verification; no schema or live query was authorized here.

After integration with the repaired runner, the default command is `python3 tools/audit/test_database_runner.py`. `--source-ref` is only for an intentional historical negative control, and the runner path must identify trusted repository source. Running against a checkout without the repair is expected to fail rather than silently skip.
