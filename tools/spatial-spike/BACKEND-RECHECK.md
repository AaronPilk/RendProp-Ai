# Backend recheck — 2026-09-10

Release worktree: `/Users/pilksclaes/Rendprop AI/spatial-testflight-20260910`.
Checked HEAD `3643398`, approximately 17:44–17:53 UTC.

**21/21 Supabase function entry points typecheck successfully.** The safe Python
worker checks pass **22 distinct test functions and 140 assertions**, with zero
failures. **HDR tone mapping remains unverified**: the installed ffmpeg lacks
`zscale`, and that script skips all assertions. Its skip was explicitly rejected
by a separate gate that exited 1. This is not a fully green backend verification.

The standing brief and Supabase skill were read before checking. No backend
source was changed, staged, committed or deployed. Typechecking did not execute
function handlers. Python tests used synthetic files and, after explicit
authorization, owned loopback HTTP fixtures. No production database, provider
API, customer capture, credential file, Docker, GPU or Xcode command was used.
The root agent's already-completed 526-test typed Deno suite was not rerun.

## Supabase entry-point typechecks

Runtime: Deno 2.7.13, TypeScript 5.9.2, aarch64-apple-darwin.
Scope was exactly `services/supabase/functions/*/index.ts` (one directory level),
including imported dependency graphs. All 21 modules passed:

```text
admin adopt ai-chapters ai-copy ai-enhance ai-photo ai-video ai-voice
apple-subscriptions beacon coach events leads listings me portfolio
property renders team tours uploads
```

Failed modules: **none**. Command working directory was
`/Users/pilksclaes/Rendprop AI/spatial-testflight-20260910/services/supabase/functions`.
The executed shell loop was:

```sh
FAIL=0
BACKEND_TOTAL=0
BACKEND_PASS=0
for backend_entry in */index.ts; do
  backend_name=${backend_entry%/index.ts}
  BACKEND_TOTAL=$((BACKEND_TOTAL + 1))
  if (ulimit -f 2048; DENO_NO_PROMPT=1 deno check --node-modules-dir=auto --no-lock "$backend_entry") > "/tmp/rendprop-backend-types.WtBxKz/$backend_name.log" 2>&1; then
    BACKEND_PASS=$((BACKEND_PASS + 1))
    printf 'PASS %s\n' "$backend_name"
  else
    backend_status=$?
    FAIL=1
    printf 'FAIL %s exit=%s log=/tmp/rendprop-backend-types.WtBxKz/%s.log\n' "$backend_name" "$backend_status" "$backend_name"
  fi
done
printf 'SUMMARY total=%s passed=%s failed=%s\n' "$BACKEND_TOTAL" "$BACKEND_PASS" "$((BACKEND_TOTAL - BACKEND_PASS))"
[ "$BACKEND_TOTAL" -gt 0 ] || FAIL=1
exit "$FAIL"
```

Loop exit code: **0**. Summary: `total=21 passed=21 failed=0`.
Logs reside in `/tmp/rendprop-backend-types.WtBxKz`, one file per module, and
occupy 84 KiB. No Download, Initialize, warning or error messages appeared.
`--no-lock` prevented creating/changing a lockfile during this read-only check.
No tracked Supabase changes resulted. The only public documentation request was
the Supabase changelog index; no live Supabase project was queried.

## Python worker and pipeline results

These are the repository's standalone script test functions and their real
`check()` assertions, not pytest discovery counts. Their failure lists propagate
to nonzero exit codes. No separate pipeline test suite exists; the cost-spool
suite exercises `services/pipeline/cost_spool.py`.

| Suite | Test functions | Assertions passed | Exit | Evidence |
|---|---:|---:|---:|---|
| Cost spool | 3 | 23 | 0 | [cost-spool.log](/tmp/spatial-worker-tests.sj5kJ5/cost-spool.log) |
| Resource limits | 4 | 19 | 0 | [resource-limits.log](/tmp/spatial-worker-tests.sj5kJ5/resource-limits.log) |
| Job lease | 7 | 75 | 0 | [job-lease.log](/tmp/spatial-worker-tests.sj5kJ5/job-lease.log) |
| Process specific | 5 | 17 | 0 | [process-specific.log](/tmp/spatial-worker-tests.sj5kJ5/process-specific.log) |
| R2 timeouts, full suite | 3 | 6 | 0 | [r2-full.log](/tmp/spatial-worker-tests.sj5kJ5/r2-full.log) |
| **Total passing coverage** | **22** | **140** | | |
| HDR tone mapping | Procedural suite skipped | **0** | Script 0; rejection gate **1** | [hdr-tonemap.log](/tmp/spatial-worker-tests.sj5kJ5/hdr-tonemap.log) |

The earlier malformed-R2-only check passed one function/one assertion. It is
superseded by the full R2 suite and **not counted twice** in these totals.
No test failures, skips or timeouts occurred in the five passing suites.

Resource-limit tests produced small synthetic CPU ffmpeg clips and checked real
probe/output-size enforcement. Job-lease and process-specific fixtures bind to
`127.0.0.1:0`, so the OS assigns a free port; a bind failure propagates and no
existing process is killed. Each fixture shuts down in `finally`. Tests replace
the real `process_job` with their existing recorder, so R2 transfers, Cloudflare
Stream, enhancement and actual job encoding are not reached. These tests do not
claim production concurrency or live-database verification.

Both exact worker and pipeline `.env` paths were checked for presence only and
were absent. Imports use those exact paths, not a parent-directory search.
Test processes clear the inherited environment. The localhost/client suites also
set `NETRC=/dev/null` and AWS configuration paths to `/dev/null` to prevent
implicit credential-file lookup, and disable EC2 metadata access.

### Exact Python test commands

All commands below used the release worktree root as their working directory.
The first two used the already-existing Python 3.12.14 verification environment.
Before each, `ulimit -f 8192` and `ulimit -t 45` bounded file/CPU output:

```sh
/usr/bin/env -i PATH=/opt/homebrew/bin:/usr/bin:/bin TMPDIR=/tmp/spatial-worker-tests.sj5kJ5 /tmp/spatial-training-verify.rUYL0A/venv/bin/python -I -B services/worker/tests/test_cost_spool.py > /tmp/spatial-worker-tests.sj5kJ5/cost-spool.log 2>&1

/usr/bin/env -i PATH=/opt/homebrew/bin:/usr/bin:/bin TMPDIR=/tmp/spatial-worker-tests.sj5kJ5 FFMPEG_TIMEOUT_S=30 FFPROBE_TIMEOUT_S=10 FFMPEG_POSTER_TIMEOUT_S=10 /tmp/spatial-training-verify.rUYL0A/venv/bin/python -I -B services/worker/tests/test_resource_limits.py > /tmp/spatial-worker-tests.sj5kJ5/resource-limits.log 2>&1
```

The next three used the fresh owned CPU environment described below. Before
each, `ulimit -f 2048` and `ulimit -t 45` applied. The wrapper also enforces a
60-second wall-clock timeout and propagates each child's exit code:

```sh
/usr/bin/env -i PATH=/usr/bin:/bin TMPDIR=/tmp/spatial-worker-tests.sj5kJ5 NETRC=/dev/null AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null BOTO_CONFIG=/dev/null AWS_EC2_METADATA_DISABLED=true COST_LEDGER_SPOOL=/tmp/spatial-worker-tests.sj5kJ5/job-lease.spool.jsonl /tmp/rendprop-worker-cpu.UyK8m6/venv/bin/python -I -B -c 'import subprocess, sys; raise SystemExit(subprocess.run([sys.executable, "-I", "-B", *sys.argv[1:]], timeout=60).returncode)' services/worker/tests/test_job_lease.py > /tmp/spatial-worker-tests.sj5kJ5/job-lease.log 2>&1

/usr/bin/env -i PATH=/usr/bin:/bin TMPDIR=/tmp/spatial-worker-tests.sj5kJ5 NETRC=/dev/null AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null BOTO_CONFIG=/dev/null AWS_EC2_METADATA_DISABLED=true COST_LEDGER_SPOOL=/tmp/spatial-worker-tests.sj5kJ5/process-specific.spool.jsonl /tmp/rendprop-worker-cpu.UyK8m6/venv/bin/python -I -B -c 'import subprocess, sys; raise SystemExit(subprocess.run([sys.executable, "-I", "-B", *sys.argv[1:]], timeout=60).returncode)' services/worker/tests/test_process_specific.py > /tmp/spatial-worker-tests.sj5kJ5/process-specific.log 2>&1

/usr/bin/env -i PATH=/usr/bin:/bin TMPDIR=/tmp/spatial-worker-tests.sj5kJ5 NETRC=/dev/null AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null BOTO_CONFIG=/dev/null AWS_EC2_METADATA_DISABLED=true COST_LEDGER_SPOOL=/tmp/spatial-worker-tests.sj5kJ5/r2-full.spool.jsonl /tmp/rendprop-worker-cpu.UyK8m6/venv/bin/python -I -B -c 'import subprocess, sys; raise SystemExit(subprocess.run([sys.executable, "-I", "-B", *sys.argv[1:]], timeout=60).returncode)' services/worker/tests/test_r2_timeouts.py > /tmp/spatial-worker-tests.sj5kJ5/r2-full.log 2>&1
```

### Remaining HDR verification gap

The attempted command, under the initial file/CPU limits, was:

```sh
/usr/bin/env -i PATH=/opt/homebrew/bin:/usr/bin:/bin TMPDIR=/tmp/spatial-worker-tests.sj5kJ5 FFMPEG_TIMEOUT_S=30 FFPROBE_TIMEOUT_S=10 FFMPEG_POSTER_TIMEOUT_S=10 /tmp/spatial-training-verify.rUYL0A/venv/bin/python -I -B services/worker/tests/test_hdr_tonemap.py > /tmp/spatial-worker-tests.sj5kJ5/hdr-tonemap.log 2>&1
```

It exited 0 while explicitly reporting `SKIPPED — 0 assertions ran` because
`/opt/homebrew/bin/ffmpeg` lacks the `zscale` filter. There was no alternate
ffmpeg/ffprobe in the bundled dependency `bin` directory, no bundled
`imageio-ffmpeg` package, and no `/opt/homebrew/opt/ffmpeg-full` installation.
No new ffmpeg binary was installed. The following recheck gate was executed and
correctly exited **1**, proving the skip is not accepted as a pass:

```sh
FAIL=0
if rg -q 'SKIPPED|0 assertions ran' /tmp/spatial-worker-tests.sj5kJ5/hdr-tonemap.log; then
  printf 'FAIL: HDR tonemap was skipped; zero assertions is not a passing backend check.\n'
  FAIL=1
fi
exit "$FAIL"
```

Verifying the HDR output still requires an ffmpeg build with both `zscale`
(libzimg) and `tonemap`, then rerunning the unchanged suite. This is an
environment-dependent verification gap, not an observed HDR rendering failure.

## Owned dependency environment and footprint

The existing three Python environments lacked boto3, botocore and requests.
After explicit authorization to add minimal CPU test dependencies, a **new**
Python 3.12.14 venv was created at `/tmp/rendprop-worker-cpu.UyK8m6/venv`.
No shared Python environment was modified. The four direct packages match the
repository's exact worker requirement pins:

```text
boto3==1.35.99
botocore==1.35.99
requests==2.32.3
urllib3==2.2.3
```

Resolved transitives were then installed with exact versions and `--no-deps`:
`certifi==2026.7.22`, `charset-normalizer==3.5.1`, `idna==3.19`,
`jmespath==1.1.0`, `python-dateutil==2.9.0.post0`, `s3transfer==0.10.4`,
`six==1.17.0`. The resolver record is
`/tmp/rendprop-worker-cpu.UyK8m6/resolution.json`; install/resolve logs are in
the same directory. Pip used the public PyPI index, an empty inherited
environment, `PIP_CONFIG_FILE=/dev/null`, `--no-cache-dir` and `--no-compile`.
`pip check` exited 0 with `No broken requirements found.` This temporary test
environment is not a production dependency upgrade or committed lockfile change.

The entire owned environment plus logs occupies **39,584 KiB (38.7 MiB)**,
below the authorized 100 MB ceiling. Free disk was about 3.0 GiB before setup
and 2.9 GiB afterward, above the 2 GiB minimum. Deno logs occupy 84 KiB and
Python test logs 36 KiB. No heavy build, GPU package, media download or output
over 100 MB was created. Temporary verification files are preserved for review.
