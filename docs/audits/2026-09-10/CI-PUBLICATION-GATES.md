# CI: actual worker publication, disposable SQL, and Ask AI source gates

Date: 2026-09-10. Branch: `ci/actual-worker-disposable-sql-20260910`, based on `audit/full-regression-20260910` at `0525bb1dac5a2d7bcadc1cbc4b06dda3261bd9fa`.

## Narrow change

Only `.github/workflows/ci.yml` and this report change. The existing nine jobs remain; no trigger, deployment, provider, app, migration, fixture, or database-runner source changes. Existing checkout/setup actions retain their full SHA pins.

- `audit-harnesses` adds the actual `node --test tests/phase1/ask-ai-label.test.mjs` command (`ci.yml:34`). This is a source contract, not proof that a label is visually untruncated or a touch target works on device.
- `python-worker` adds the actual `services/worker/tests/reproduce_stale_publish.py` wrapper alongside the existing worker checks. At this source base it executes 14 tests against the real worker/helper with synthetic RPC responses, refusing failures, skips, or an unexpected count (`reproduce_stale_publish.py:1–11`). It does not prove PostgreSQL fencing; the separate job below does that work when executed.
- New `db-publication-regression` job (`ci.yml:243`) uses Ubuntu 24.04, the existing pinned Python setup at 3.12, explicit `postgresql-16` and `postgresql-client-16` packages, and `/usr/lib/postgresql/16/bin`. It asserts executable existence **and major-version 16 output for all four** `initdb`, `pg_ctl`, `psql`, `createdb` binaries. Security patch versions may advance; this is a major-version pin, not an immutable OS/package snapshot.

## Database isolation and honest red result

The job invokes `python3 tools/audit/run_database_regression.py` directly, with no exit-code conversion, `continue-on-error`, fixture count override, or skip condition. It is independent of the existing `db-migrations` TCP service (`rendprop` on localhost); it neither connects to nor reuses that service. Its job permissions are `contents: read` and it references no production secrets.

The runner remains byte-identical to the base: SHA-256 `df9ec8916f04611ee452d027c89c3d6292a7707a51080af5b89e105c5d576828`. It requires a clean checkout and at least 1 GiB free, creates a new `/tmp/rendprop-db-audit-*` cluster, limits child environment variables, uses a private Unix socket, disables TCP listening, verifies the exact data-directory/database identity, and stops only its own cluster (`tools/audit/run_database_regression.py:47–66,90–109,185–208`). Those guards are unchanged. `initdb` is run as the ordinary runner user, not with `sudo`.

The known Astra headroom mismatch remains a **red gate**: historical execution reported 197/198 assertions passing on both passes, not overall acceptance; see [DATABASE-EXECUTED-RESULTS.md](DATABASE-EXECUTED-RESULTS.md). The runner continues from a structurally valid red invariant report through replay, paid-route controls, real worker/upload publication fixtures, deliberately broken guards, restored positive fixtures and the entitlement negative control, before its final nonzero result. SQL/load failures still abort. CI does not hardcode publication-fixture counts; their runner/source owns those expectations. No token budget, entitlement predicate or runtime route is changed to make CI green.

## Failure evidence, without cluster data

`actions/upload-artifact` v4.6.2 is pinned to `ea165f8d65b6e75b540449e92b4886f43607fa02`, independently resolved from the [official tag](https://github.com/actions/upload-artifact/tree/v4.6.2) using:

```sh
git -c credential.helper= -c core.askPass= ls-remote --refs https://github.com/actions/upload-artifact.git refs/tags/v4.6.2
# ea165f8d65b6e75b540449e92b4886f43607fa02  refs/tags/v4.6.2
```

The `always()` artifact step retains only `/tmp/rendprop-db-audit-*/receipt.json` and **top-level** `*.log`, for seven days. There is no cluster-directory, socket, raw PostgreSQL-file, repository, credential, or customer-media glob. Artifact absence is an error after a successful runner; after failed/skipped preflight it warns, preserving the original failure rather than inventing a second database result. An upload failure is not softened. Runner/job cancellation or infrastructure failure can still prevent artifact collection; `always()` is not a durability guarantee.

Primary references checked on the audit date: [Ubuntu's PostgreSQL 16 package](https://packages.ubuntu.com/noble/postgresql-16), [versioned client binary paths](https://packages.ubuntu.com/noble/amd64/postgresql-client-16/filelist), [PostgreSQL 16 initdb ownership requirements](https://www.postgresql.org/docs/16/app-initdb.html), and the [pinned upload action's retention, path and missing-file inputs](https://github.com/actions/upload-artifact/tree/v4.6.2#usage). No package or action was installed/executed locally. The Supabase skill informed the isolation review; no Supabase project access occurred.

## Actual local checks

Evidence directory: `/tmp/rendprop-ci-publication.9pYDq1` (small synthetic logs and the temporary checker; no database cluster).
Local versions: Ruby 4.0.5 / Psych 5.3.1, Node 25.9.0, and the reused worker interpreter Python 3.14.4. These checks do not substitute for the configured CI Node 22 / Python 3.12 runtimes.

| Command/check | Actual result |
| --- | --- |
| `ruby /tmp/rendprop-ci-publication.9pYDq1/check-workflow.rb --baseline` | Original workflow deliberately rejected, exit 1: four missing-wiring findings; `before.log`. |
| `ruby /tmp/rendprop-ci-publication.9pYDq1/check-workflow.rb` | 160 workflow/source/shell checks passed, exit 0; `workflow.log`. Parses actual YAML with Ruby Psych, rejects duplicate mapping keys, preserves all existing job definitions except the two exact additions, checks pins/paths/failure semantics, and runs Bash syntax checks on actual run blocks. |
| Actual database run block under `/bin/bash -e -o pipefail`, using an inert temporary `python3` stub | Returned the supplied 0, 1 and 73 statuses unchanged. No PostgreSQL program or SQL ran. Included in the workflow checker count. |
| `env -i PATH=/usr/bin:/bin PYTHONDONTWRITEBYTECODE=1 '/Users/pilksclaes/Rendprop AI/worker-host-audit-20260910/services/worker/.venv/bin/python' services/worker/tests/reproduce_stale_publish.py` | 14 passed, zero skipped, exit 0; `worker.log`. Actual current worker/pipeline files and an already-installed interpreter; `.env` absence checked before import. RPC/storage/encode operations are test mocks, not real publishes. |
| `node --test tests/phase1/ask-ai-label.test.mjs` | 1 passed, zero failed/skipped, exit 0; `ask-ai.log`. |
| `python3 tools/audit/test_database_runner.py` | 30 mocked runner-control tests passed, zero skipped, exit 0; `runner-control.log`. This is not database execution. |
| `git diff --check` | Exit 0. |

**Remote CI is unexecuted.** No Actions dispatch, PostgreSQL installation/start, live database, provider, Apple or deployment action occurred. Local YAML/Psych and Bash validation are not GitHub's workflow validator or an Ubuntu execution. Remote apt availability, runner package contents, PostgreSQL 16 migration behavior, action permissions/artifact collection and the complete multi-job CI result still require a future authorized run. The SQL gate is expected to remain red until the real invariant mismatch is resolved, not bypassed.
