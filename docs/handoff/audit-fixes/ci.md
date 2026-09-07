# HANDOFF — CI + supply-chain audit fixes (2026-09-07)

Branch `fix/ci` off `integrate/1.0.1`, built in a separate worktree. Four findings from
the external release audit, each fixed and verified against a real Postgres, a real
Deno, a real `npm`/`wrangler`, and a real `docker build` on this machine — not just
read. Exact commands and output are below so the numbers here can be re-checked.

## 1. CI was RED — `0022_app_events_purge_schedule.sql` needs pg_cron unconditionally

**Root cause:** `pg_cron` is a `shared_preload_libraries` extension — it must be
compiled into and loaded by the Postgres server at *start-up*, so it has no control
file on a plain `postgres:16` image (or most local installs). `create extension pg_cron`
there doesn't no-op, it **errors** ("extension \"pg_cron\" is not available"), which is
exactly what `db-migrations` hit in CI.

**Fix** (`services/supabase/migrations/0022_app_events_purge_schedule.sql`): wrapped the
extension-create and the `cron.schedule(...)` call in a guard —
`if exists (select 1 from pg_available_extensions where name = 'pg_cron')` before
attempting the extension, then `if exists (select 1 from pg_extension where extname =
'pg_cron')` (re-checked post-create, per the task's suggested shape) before touching the
`cron.*` tables. Either miss now ends in a `raise notice` naming exactly what happened
and what to do about it, instead of an error or a silent no-op. The purge function
itself, `public.purge_app_events()`, was already created unconditionally in `0020` —
untouched here — so the sweep can always be invoked by hand or from an external
scheduler regardless of whether pg_cron ever gets scheduled.

Documented as a **manual production gate** in two places: the migration's own header
comment, and a new §10 in `services/supabase/DEPLOYMENT.md` ("Scheduling the app_events
purge (pg_cron is a manual gate)") spelling out the 3-step fix (enable pg_cron in the
dashboard → re-run the migration → confirm `cron.job` has the row) and what happens if
it's skipped (unbounded table growth, silently — unless someone reads the migration log
for the `0022:` notice).

**Verified — full migration replay against a fresh, plain (non-Docker) Postgres 16.13
on this machine**, mirroring `db-migrations` exactly (`ci-bootstrap.sql`, then every
migration 0001→0023 in `LC_ALL=C` order, one transaction each):

```
$ createdb rendprop_auditfix
$ psql ... -f services/supabase/tests/ci-bootstrap.sql        # exit 0
$ for f in migrations/*.sql (LC_ALL=C sorted); psql -1 -f "$f"; done
== services/supabase/migrations/0022_app_events_purge_schedule.sql
NOTICE:  0022: pg_cron is NOT available on this Postgres — the nightly app_events
         purge was NOT scheduled. public.purge_app_events() (created unconditionally
         in 0020) still exists and can be invoked manually or from an external
         scheduler ... THIS IS A MANUAL GATE ...
== services/supabase/migrations/0023_coach_routes.sql
ALL_MIGRATIONS_EXIT=0
```

All 23 migrations applied cleanly — 0022 degrades loudly instead of failing.

**Invariants** (`services/supabase/tests/invariants.sql`): **181 of 181 passed**, 0
failures (`NOTICE: All 181 invariants passed.`).

Then, mirroring the CI job's *second* half — replaying the re-appliable migrations
(`0005b`, `0008b`, `0009`→`0023`, including `0022` a second time) on the now-migrated
database, to prove `0022` is idempotent: same loud notice, exit 0, no error. Invariants
re-run after that replay: **181 of 181 passed again**, identical count.

**A second pg_cron failure mode, found live and then fixed too:** partway through this
task, this shared machine's Postgres cluster picked up `shared_preload_libraries =
pg_cron` with `cron.database_name = rendprop_scratch` (evidently from another process
on the same box, not anything in this task) and was restarted. On a fresh database
after that, `pg_cron` was suddenly *catalog-available* — the first guard's `if exists
(select 1 from pg_available_extensions ...)` now took the "attempt it" branch — but
`create extension pg_cron` there is a **hard error**, `can only create extension in
database rendprop_scratch`: pg_cron pins its SQL objects to exactly one database
cluster-wide, and this wasn't it. That's a real, if exotic, failure shape ("available"
in the catalog but not actually usable here) that the original guard didn't cover, so
the whole `do $$ ... $$` block now also carries an `exception when others` fallback —
any pg_cron surprise, whatever the cause, degrades to the same loud `raise notice`
(printing `SQLSTATE`/`SQLERRM` for a human to act on) instead of aborting the migration.
Re-verified after adding it, against the database that hit the error:

```
NOTICE:  0022: pg_cron setup did not finish (P0001 — can only create extension in
         database rendprop_scratch) — the nightly app_events purge was NOT scheduled.
         ... THIS IS A MANUAL GATE: resolve whatever this reports on THIS server ...
EXIT=0
```

...and then re-ran the **entire** 0001→0023 replay + invariants + re-appliable-replay +
invariants sequence from scratch one more time end-to-end on this now-mutated cluster to
confirm nothing else regressed: all 23 migrations clean, **181/181 invariants**, both
before and after the re-appliable-migrations replay — identical to the numbers above.

## 2. CI never ran the Deno edge-function tests

`edge-functions` only ran `deno check` (typecheck). Checked every one of the 11
`*.test.ts` / `*_test.ts` files under `services/supabase/functions` by hand with
`~/.deno/bin/deno` (2.9.6) for hermeticity — none needs a live Supabase project, a real
provider key, or a live database; the handful that touch `Deno.env` do so to exercise
their *own* error/fallback path (e.g. `router: reportOutcome threw (swallowed): Missing
required env var: SUPABASE_URL` is an intentional negative-path assertion, not a leak).
The only network these tests need at all is Deno's normal fetch-and-cache of their
`https://deno.land/std@0.224.0/assert/...` / `jsr:@std/assert@1` imports.

Enabled the whole directory as one blanket run — confirmed with a **throwaway
`DENO_DIR`** (forcing a cold-cache fetch of every remote import, the worst case for a
CI runner) that it still passes hermetically:

```
$ DENO_DIR=/tmp/deno-dir-clean deno test --allow-all --node-modules-dir=auto .
ok | 216 passed | 0 failed (1-2s)
```

`--node-modules-dir=auto` is a CLI flag (not a committed `deno.json`) — enough for the
couple of source files with type-only `npm:@supabase/supabase-js@2` imports
(`_shared/router.ts`, `_shared/supabase.ts`, `_shared/ledger.ts`, `admin/index.ts`).
Wired into `.github/workflows/ci.yml`'s `edge-functions` job as a new "Run edge function
tests" step, right after the existing typecheck step; job renamed to "Supabase edge
functions (deno check + tests)".

**216 of 216 tests enabled and passing** across: `_shared/applejws.test.ts`,
`_shared/fairhousing.test.ts`, `_shared/http.test.ts`,
`_shared/providers/providers_test.ts`, `_shared/router.test.ts`,
`admin/funnel.test.ts`, `admin/probe.test.ts`, `ai-chapters/postprocess_test.ts`,
`apple-subscriptions/notify.test.ts`, `coach/actions_test.ts`, `events/events.test.ts`.

## 3. CI never ran the Python worker tests; the HDR test's skip was silent

`python-worker` only byte-compiled and checked pinning. Checked both files under
`services/worker/tests/` by hand:

- **`test_job_lease.py`** — stdlib-only, fully hermetic. It starts its own fake
  PostgREST (`fake_postgrest.py`) on `127.0.0.1:0` (an OS-assigned loopback port, no
  real network, no real Supabase) to exercise claim/lease/heartbeat/reap/release
  against `services/worker/db.py`. Ran it directly: **40 checks, all `ok`, exit 0.**
- **`test_hdr_tonemap.py`** — needs local `ffmpeg`/`ffprobe`; if the build lacks
  `zscale`/`tonemap` (libzimg) it was designed to skip rather than fail (it synthesises
  its own fixtures, no external assets). This machine's ffmpeg (6.1.1, `--enable-libzimg`)
  has both, so it ran for real: **21 checks, all `ok`, exit 0**, including the
  audit's original regression (untagged SDR no longer dies with
  `zscale: no path between colorspaces`; HDR sources are measurably tone-mapped, not
  just re-tagged).
- `services/pipeline` has **no `tests/` directory** — nothing to wire up there (it's
  stdlib-only glue exercised today through its own `cli.py` cost-test path).

**Important finding, handled rather than just noted:** both worker test files define
plain `test_*()` functions and are *collectible* by `pytest` — but their shared
`check()` helper only appends to a `FAILURES` list and never raises. Confirmed
empirically:

```
$ python3 -m pytest tests/test_job_lease.py -q
....
4 passed in 2.19s
```

`pytest` reports 4/4 passed regardless of what's inside those functions — only an
*unhandled exception* fails a pytest run, and `check()` is deliberately exception-free.
Running these under `pytest` would be exactly the "green CI hides a real bug" failure
mode the audit is worried about, so the new CI step invokes them as **plain scripts**
(`python3 services/worker/tests/test_job_lease.py`, matching their own docstrings) and
trusts each file's real exit code, not a test-runner's interpretation of it.

**Loud skip, `test_hdr_tonemap.py`:** added a `skip()` helper used at all three
early-return sites (no ffmpeg/ffprobe on PATH; ffmpeg missing zscale/tonemap; fixture
synthesis failed). It prints a `::warning::` GitHub Actions annotation — which surfaces
as a yellow warning on the Checks tab even though the job stays green — plus a
hard-to-miss `!!!`-banner for anyone reading raw logs, and now **names exactly which
filter is missing** rather than a generic "lacks zscale/tonemap". Verified all three
paths with a stubbed `ffmpeg` on `PATH`:

```
missing zscale+tonemap → ::warning::HDR tonemap test SKIPPED — this ffmpeg build is
  missing filter(s) ['zscale', 'tonemap'] (needs libzimg's...) ...
missing tonemap only   → ... missing filter(s) ['tonemap'] ...
no ffmpeg on PATH      → ::warning::HDR tonemap test SKIPPED — ffmpeg/ffprobe not on
  PATH — cannot verify the HDR path.
```
(exit 0 in every case — a skip, correctly, not a failure — but now impossible to miss.)

New CI step in `python-worker` also installs the pinned `services/worker/requirements.txt`
(the tests import `db.py` → `requests`; not previously installed in CI at all) and
`apt-get install ffmpeg`, rather than trusting whatever `ubuntu-latest` happens to
preinstall — verified end-to-end in a fresh Python 3.12 venv with only those pinned
packages: both test files, same counts as above (40 + 21 checks, exit 0 both).

## 4. Supply chain (audit finding 5 / P0-8)

### `services/edge/tour-host` — wrangler + workers-types

| | before | after |
|---|---|---|
| `wrangler` | `4.26.0` | `4.129.0` |
| `@cloudflare/workers-types` | `^4.20250712.0` | `^5.20260903.1` (wrangler 4.129.0 peers on `^5.x`) |
| `npm audit` (full) | **4 high** (miniflare, sharp, ws, wrangler — all resolve to "install wrangler@4.129.0") | **0 vulnerabilities** |
| `npm audit --omit=dev` (CI's actual gate) | 0 (already passing — these were dev-only) | 0 |

Stayed on the 4.x line (task asked for "a current 4.x", not a major bump) —
`4.129.0` is the newest 4.x on npm as of 2026-09-07 and is exactly what
`npm audit fix` recommends for every one of the 4 findings.

Verified in the real directory: `npm ci` clean install → `npm run typecheck` (0 errors)
→ `npm test` → **892 assertions, all passing** (531 unbranded-page + 361 route) → `npx
wrangler deploy --dry-run` bundles cleanly (157 KiB / 48 KiB gzip) → `npm audit` and
`npm audit --omit=dev` both **0 vulnerabilities**.

### `wrangler.toml` — stale `compatibility_date`

Bumped `2024-09-23` → `2026-09-07`. No `compatibility_flags` are set, so the date alone
governs every default runtime behaviour — bumping it blind would violate "do not change
runtime behaviour", so it was checked, not assumed:

1. `npm test` (892 assertions) passes identically at both dates.
2. Ran a **real local `wrangler dev`** (actual `workerd`, not just the bundler) at the
   old date, then at the new date, hit the same six routes (`/`, `/robots.txt`,
   `/f/nonexistent`, `/nope-does-not-exist`, `/a/somehandle`, `/terms`), and diffed full
   response headers. **Byte-identical status codes, headers, and ETags** at both dates.

Documented directly in `wrangler.toml` (what was checked, and how to re-check before
pushing the date further).

### `.github/workflows/ci.yml` — pin actions, deno-version, and the postgres image

Every `uses:` now pins an immutable 40-char commit SHA (with the version kept in a
trailing comment), resolved via `git ls-remote --tags` against each action's real repo
(the GitHub REST/web API were not reachable from this session; the git smart-HTTP
protocol was) — kept on the **same major line already in use**, just made immutable:

| action | before | after |
|---|---|---|
| `actions/checkout` | `@v4` | `@11d5960a326750d5838078e36cf38b85af677262` — v4.4.0 |
| `actions/setup-node` | `@v4` | `@49933ea5288caeca8642d1e84afbd3f7d6820020` — v4.4.0 |
| `denoland/setup-deno` | `@v2` | `@22d081ff2d3a40755e97629de92e3bcbfa7cf2ed` — v2.0.5 |
| `actions/setup-python` | `@v5` | `@a26af69be951a213d495a4c3e4e4022e16d87065` — v5.6.0 |
| `gitleaks/gitleaks-action` | `@v2` | `@ff98106e4c7b2bc287b24eaf42907196329070c7` — v2.3.9 |

`deno-version: v2.x` → `"2.9.6"` (exact — the latest 2.x release, and what all 216 edge
tests above were run against on this machine).

`postgres:16` → `postgres:16@sha256:f1c3376c26f2609ab9f29f71f824103fe2fcd8ee0346485cb6122a4f93df6f94`
— resolved live from Docker Hub's registry API (`registry-1.docker.io`, anonymous
pull token), confirmed to be the **multi-arch index** (includes `linux/amd64`, what
`ubuntu-latest` runs) by inspecting its manifest list, not a single-arch manifest. The
lookup command is left in a `ci.yml` comment for re-resolving later.

Nothing here could be smoke-tested by actually running a GitHub Actions job (no `act`,
no way to execute a workflow from this machine) — the SHAs were cross-checked against
their tags twice and the file was validated as parseable YAML
(`python3 -c "import yaml; yaml.safe_load(...)"`), but a first real PR run is the
genuine test of the pins.

### `services/worker/Dockerfile`

- **Base image** pinned by digest: `python:3.11-slim-bookworm` →
  `...@sha256:528257d48c1da0dcecc2e725d1ae34498d60c965f1241e39cd6a85a8859bdf84`
  (same registry-API method as postgres, confirmed multi-arch/linux-amd64).
- **apt packages**: `--no-install-recommends` was already present (kept). Added exact
  version pins — `ffmpeg=7:5.1.9-0+deb12u1`, `ca-certificates=20250419~deb12u1` —
  resolved from the **live Debian archive this exact base image's `sources.list`
  actually points at** (`bookworm` main + `bookworm-security`; security carried the
  newer `ca-certificates` build, and the official Debian image enables both suites by
  default, so that's genuinely what an unpinned install resolves to today). Documented
  the real caveat: Debian's live archive keeps only the newest build per suite, so once
  a `deb12u2` ships this pin will 404 and the build will fail *closed* — intentional,
  matching `requirements.txt`'s own "bump deliberately, rebuild, re-test" philosophy,
  not a bug to route around. True immutability across security updates would need
  pinning the apt *source* to a `snapshot.debian.org` date — a bigger change, not done
  here.
- **pip / `--require-hashes`**: NOT added. `requirements.txt` pins every package with
  exact `==` but carries no `--hash` lines. Tested directly (fresh venv, no cache):

  ```
  $ pip install --require-hashes -r requirements.txt
  ERROR: Hashes are required in --require-hashes mode, but they are missing from some
  requirements. ... boto3==1.35.99 --hash=sha256:83e560faaec38a956dfb3d62e05e1703ee50432b45b788c09e25107c5058bd71
  ```
  exit 1 — adding the flag today would simply break the build. Generating real hashes
  needs a `--hash` line for **all 11 packages in the resolved closure** (the 4 pinned
  directly — boto3, botocore, requests, urllib3 — plus their transitive jmespath,
  s3transfer, python-dateutil, charset-normalizer, idna, certifi, six), normally via
  `pip-compile --generate-hashes` (pip-tools, against a `requirements.in`) or `pip
  download` + `pip hash` per package, then **re-generating on every version bump**.
  That's a real workflow change (a lockfile-generation step that doesn't exist today),
  flagged here as a follow-up rather than done blind.

**Verified with an actual `docker build`**, not just a syntax read — `dockerd` came up
on this machine, so the real thing was tested rather than assumed:

```
$ docker build -f services/worker/Dockerfile -t rendprop-worker services/
...
Setting up ffmpeg (7:5.1.9-0+deb12u1) ...          # exact pin, confirmed installed
... (apt layer) DONE 32.4s
```
The apt layer (base image digest + both exact version pins) built successfully outright
— proof the digest and both version strings are real and correct right now. The
subsequent `pip install` step (bit-for-bit unchanged from before this fix) failed only
in *this sandbox* on a container-networking detail (this VM's outbound proxy isn't
reachable from inside an isolated build container without extra plumbing this sandbox
needs, not something the real Dockerfile does or should carry) — confirmed by re-running
the **exact same, unmodified** `pip install -r requirements.txt` inside a container
started from the same pinned base image with `--network host` and the sandbox's proxy
made reachable: it resolved and installed all 11 packages at the expected exact
versions with zero errors. Then ran the **entire Dockerfile end-to-end** (via a
throwaway copy with two extra diagnostic-only lines — never present in the committed
file — that inject this sandbox's proxy CA before the `pip install` step) to full
completion:

```
Successfully installed boto3-1.35.99 botocore-1.35.99 certifi-2026.7.22
  charset-normalizer-3.5.1 idna-3.19 jmespath-1.1.0 python-dateutil-2.9.0.post0
  requests-2.32.3 s3transfer-0.10.4 six-1.17.0 urllib3-2.2.3
... exporting to image ... DONE
```
Smoke-tested the resulting image: runs as `appuser` (non-root, confirmed), `ffmpeg
-version` reports exactly `5.1.9-0+deb12u1` with `--enable-libzimg` and both
`zscale`/`tonemap` present in `-filters`, and `python -c "import boto3, ...; import
settings"` (the worker's own config module) imports cleanly. The diagnostic copy and
its throwaway image were deleted afterward; the committed `Dockerfile` never carried
the proxy workaround.

## What could not be verified from here

- The GitHub Actions SHA pins were cross-checked against their tags via `git
  ls-remote` but never executed inside an actual GitHub Actions runner (no `act`
  available) — the real test is the first CI run on this branch.
- `wrangler.toml`'s compat-date bump was verified for *this Worker's* observable
  behaviour (identical `wrangler dev` responses, real test suite) but not against a
  live Cloudflare deploy (no account credentials in this sandbox) — a preview deploy is
  the fully authoritative check before this goes to production.
- Hash-pinning `services/worker/requirements.txt` (`--require-hashes`) was
  deliberately not attempted — see above; it's flagged as follow-up work, not done.
- Exact apt version pins in the Dockerfile were resolved from Debian's *live* archive
  today and proven installable by an actual `docker build` right now — but by design
  (see caveat above) they will need a deliberate bump whenever Debian ships the next
  `ffmpeg`/`ca-certificates` security update, at which point the build will fail until
  someone re-runs the two lookup commands left in the Dockerfile's comment.
