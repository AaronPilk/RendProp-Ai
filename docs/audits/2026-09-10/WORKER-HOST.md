# Render worker and public hosting — independent regression audit

2026-09-10. Base source: `de4b0b1cfd5475b3439350bd21ede9c28cfc7d33`.
Isolated branch: `audit/worker-host-20260910`.
Worktree: `/Users/pilksclaes/Rendprop AI/worker-host-audit-20260910`.

## Outcome and scope

**Not a full-backend GO.** The hosting bundle builds and its existing assertions pass. A real reaper race is fixed locally with failing-before/passing-after evidence. Stale-worker publishing, Stream fallback buffering, revocation caching, and durable cleanup still require work. No deployment was performed. These edits are not in the owner's installed build 18.

Read the standing brief completely. Cloudflare, Workers best-practices, Wrangler and Supabase skills guided config/reference retrieval, isolated local verification and the reaper compare-and-set change. No protected motion text, AI route, Apple state, provider settings or production data changed. No camera simulator test was attempted.

Verification used synthetic fixtures and a loopback fake PostgREST. It did **not** prove real Postgres concurrency, real Supabase authorization, Cloudflare deployed configuration, R2/Stream integration, ffmpeg's production container, or browser interaction. No customer media was read or uploaded. See the integration audit for other lanes.

Evidence directory: `/tmp/rendprop-worker-host-audit.VukmCV` (ephemeral). The exact outcomes below are durable in this document; new regression tests are committed source. Public package versions and public docs were queried; credentials and local `.env`/`.dev.vars` were not copied into the isolated checkout. Test subprocesses received an allowlisted environment and Wrangler used an empty isolated home.

## Commands actually executed

Host commands ran from `services/edge/tour-host` in the isolated worktree:

| Command | Actual result |
|---|---|
| `npm ci --ignore-scripts --no-audit --no-fund` | Exit 0, 41 packages installed from committed lock. Install lifecycle scripts deliberately disabled. |
| `npm run typecheck` | Exit 0. |
| `npm test` | Exit 0; 557 unbranded assertions over 15 renders + 12 gate self-tests; 361 route assertions. |
| `npm run check:assets` | Exit 0; two required demo videos present and under the checker cap. |
| `node_modules/.bin/wrangler deploy --dry-run --outdir /tmp/rendprop-worker-host-audit.VukmCV/bundle` | Exit 0, Wrangler 4.129.0; 181.00 KiB script / 56.13 KiB gzip; read 45 static files; explicitly exited without deploying. |
| `npm audit --json` | **Exit 1**, 3 high entries; details below. |

Installed Python dependencies only in `services/worker/.venv` with `python3 -m venv .venv` then `.venv/bin/python -m pip install -r requirements.txt` (exit 0). This Mac interpreter is Python 3.14, not the Dockerfile's Python 3.11: this is a local regression run, not a container reproducibility claim.

Worker commands used `.venv/bin/python tests/<file>.py`, a credential-free environment, and a 300-second outer timeout:

| File | Actual result |
|---|---|
| `test_job_lease.py` | Exit 0; 75 explicit check lines. |
| `test_process_specific.py` | Exit 0; 17 explicit check lines. |
| `test_cost_spool.py` | Exit 0; 23 explicit check lines. |
| `test_r2_timeouts.py` | Exit 0; 6 explicit check lines. |
| `test_resource_limits.py` | Exit 0; 19 explicit check lines, including actual small ffmpeg encodes and an intentionally tiny output cap. |
| `test_reaper_snapshot.py` (new) | Original code: **exit 1, 4 failed / 6 tests**. Patched code: exit 0, 6 passed, 0 skips. |
| `test_verification_prerequisites.py` (new) | Exit 0, 4 passed, 0 skips; expected missing-prerequisite branches are asserted, not silently accepted. |
| `test_hdr_tonemap.py` | **NOT VERIFIED**: installed ffmpeg lacks `zscale`. Original test misleadingly exited 0 with 0 assertions; patched test exits 1 with 0 assertions. Both installed ffmpeg/ffmpeg@8 builds were inspected; neither supplies zscale. |

Thus **140 pre-existing explicit checks + 10 new unittest cases passed**, with no skips in those passing suites. HDR has **zero executed media assertions**, not a pass. `run_checks.py` is an outer evidence harness; it exits 1 because HDR prerequisites and the dependency audit are not green. It does not relabel those failures as success.

Before testing edits, `rg` confirmed `selected ownership snapshot`, `test_heartbeat_renewal_wins_before_patch`, `unavailable`, and `prerequisites` in the actual files. `git diff --check` passed.

## Fixed locally

### WH-01 — P1: reaper could kill a renewed live job

**Before:** `services/worker/db.py:341` selected expired/exhausted jobs, but the subsequent PATCH checked only `id` and `status=processing`. A heartbeat between SELECT and PATCH left status unchanged and therefore lost to the reaper. The currently encoded customer tour was marked poison even though its owner had renewed.

**Implemented:** `services/worker/db.py:344` selects the lease snapshot and `services/worker/db.py:352` matches all of `lease_expires_at`, `attempts`, `worker_id`, `id` and processing status in the same PATCH. Null legacy owners use `is.null`. This is ordinary PostgREST row filtering, not a read-then-unconditional-write. Any changed snapshot wins the race and the reaper gets zero rows.

```python
{"id": f"eq.{row['id']}", "status": "eq.processing",
 "lease_expires_at": f"eq.{row['lease_expires_at']}",
 "attempts": f"eq.{row['attempts']}",
 "worker_id": (f"eq.{row['worker_id']}"
               if row.get("worker_id") is not None else "is.null")}
```

**Proof:** `services/worker/tests/test_reaper_snapshot.py:26` injects mutations after the real SELECT response and before the real db PATCH. Renewal, owner change, attempt change and changed-but-still-expired deadline all fail against the original code and pass after the fix. Unchanged poison and legacy null-owner poison still reap. Logs: `reaper-before.log` and `reaper-after.log`. Fake PostgREST tests do not replace the eventual isolated real-DB race acceptance test.

### WH-02 — P2: media tests could report green without doing the work

**Implemented:** `services/worker/tests/test_hdr_tonemap.py:124` returns 1 for unavailable verification instead of an exit-0 warning. `:63` rejects a failed signalstats subprocess and `:69` rejects missing measurements rather than returning zeroes. `services/worker/tests/test_resource_limits.py:120` and `:162` record failures for absent binaries; fixture synthesis failures now fail at `:134` / `:176`, and fixture subprocesses have 300-second timeouts.

`services/worker/tests/test_verification_prerequisites.py:14` covers missing HDR binaries, both resource prerequisite failures, empty stats and failed stats. The production HDR fallback itself is **not** changed or certified by this test fix.

## Remaining issues, ranked, with concrete reproductions and repair contracts

### WH-03 — P1: a stale worker can still replace a newer worker's published media

`services/worker/worker.py:443` checks progress/heartbeat before publishing; `services/worker/db.py:587` / `:603` insert without job ownership; unique-job conflicts call `_replace_render_for_job` at `:611`. Its PATCH at `:627` filters only by `job_id`. The later ownership-checked `finish_job` cannot undo an already changed `renders` row. Enhancement outcome writes at `services/worker/db.py:551` and listing status writes at `services/worker/worker.py:508` also lack the same atomic ownership boundary.

**Reproduction:** worker A passes its checkpoint, pauses; B reclaims, renders and finishes; A resumes into duplicate-job replacement. The local probe calls the actual `_replace_render_for_job` against loopback fake PostgREST with B already `ready`. Observed:

```text
result_video_key=worker-A-stale.mp4 current_owner=worker-B current_status=ready
AssertionError: stale publisher changed the newer owner output
```

Command, exit 1: from `services/worker`, `.venv/bin/python tests/reproduce_stale_publish.py`. The durable diagnostic is deliberately not named `test_*`; it fails while the finding remains open and is not a passing acceptance suite.

**Required fix, not applied:** one service-role-only `publish_worker_render` RPC must lock the job row, verify source=worker, processing status, exact attempt fencing token and unexpired lease using DB time, then insert/replace the render, record outcomes, update listing state and mark the job ready in the **same transaction**. Revoke function execution from PUBLIC/anon/authenticated. An `assert_owned()` query followed by today's REST insert is not sufficient.

Core transaction condition, not a complete migration:

```sql
select * into j from public.render_jobs where id = p_job_id for update;
if j.id is null or j.source <> 'worker' or j.status <> 'processing'
   or j.worker_id is distinct from p_worker_id
   or j.attempts is distinct from p_attempt
   or j.lease_expires_at is null or j.lease_expires_at <= clock_timestamp() then
  raise exception 'job_not_owned';
end if;
-- Validate artifact ownership/keys, then publish + finish within this lock.
-- Do not expose arbitrary media keys through a caller-writable public RPC.
```

Acceptance: actual two-worker barrier race at publish; losing attempt updates **zero** render/listing/photo rows, makes no additional paid calls, leaves winner's bytes/hash/slug unchanged, and persists cleanup for its own unused attempt artifacts. Also test repeated WORKER_ID values across restarts; attempt identity must be fenced, not only a process name.

### WH-04 — P1: Stream fallback buffers an entire potentially multi-GB render

`services/worker/stream.py:92` uses Requests `files=...`; `services/worker/worker.py:268` automatically calls it if copy-by-URL fails. Requests prepares the multipart body by reading the file into memory. The output ceiling is 8 GiB (`services/worker/ffmpeg_render.py:174`) and there is no direct-upload size guard. A transient Stream copy failure can therefore turn an otherwise completed tour into an OOM/retry loop.

**Safe proof:** `.venv/bin/python tests/reproduce_stream_buffering.py` prepared a Request from a synthetic 1 MiB BytesIO without sending it. Observed `prepared_body_type=bytes`, `prepared_body_bytes=1048750`, all 1048576 input bytes consumed, zero network requests. Streaming invariant assertion exits 1. This demonstrates the library behavior; no multi-GB allocation was attempted.

The endpoint itself only documents basic form uploads for files **smaller than 200 MB**; larger uploads need tus. [Cloudflare basic uploads](https://developers.cloudflare.com/stream/uploading-videos/upload-video-file/).

**Repair:** first guard basic-upload size before `open()` and before constructing `files`, falling back to the already-uploaded R2 MP4 with an explicit diagnostic; implement bounded resumable tus separately. A conservative interim body could be:

```python
MAX_BUFFERED_STREAM_BYTES = 16 * 1024 * 1024  # explicit worker memory budget
size = os.path.getsize(file_path)
if size <= 0 or size > MAX_BUFFERED_STREAM_BYTES:
    raise StreamError("basic Stream fallback exceeds its memory budget; use R2 playback or tus")
```

That 16 MiB value is a proposed safety budget, **not** a provider limit or implemented policy. Tests must ensure an over-cap synthetic stat never opens/reads the file and the worker still publishes R2 playback. Tus needs offset reconciliation, cancellation, per-job deadline, and orphan persistence.

### WH-05 — P1 against an immediate-revocation promise: edge/browser HTML survives revocation

`services/edge/tour-host/src/index.ts:288` returns cached HTML before checking the tours route. Successful HTML sets public browser and shared-cache TTL at `:321`; configured TTL is 60 seconds (`wrangler.toml:61`). Portfolios have the same pattern (`index.ts:369`, `:391`). A revoked/deleted/unpublished tour can still expose its previously rendered address, photos and links until those caches expire. Existing open pages or downloaded files cannot be remotely erased; this finding concerns new requests.

**Actual-module reproduction:** from `services/edge/tour-host`, `node scripts/reproduce-cache-revocation.mjs` caches a synthetic non-demo tour, flips the stub upstream to 404, then requests the same tour again. Observed `secondStatus=200`, `upstreamCalls=1`, `Cache-Control=public, max-age=60, s-maxage=60`. Expected 404 assertion exits 1. No customer route was fetched or revoked.

**Repair:** for customer content, return `Cache-Control: no-store` and bypass old edge-cache reads/writes, or require an authoritative live publication/version check before every cached response, with cache keys bound to the version. Keep synthetic demo caching separate. Merely changing the environment TTL to zero does **not** bypass existing cache hits. Purge old cache entries on rollout where supported, but do not rely on a purge alone for correctness. Coordinate upstream and media revocation policy: disabling HTML does not revoke an already issued public media URL.

### WH-06 — P1/P2: artifact cleanup is memory-only and best-effort

`services/worker/worker.py:213` stores created R2 keys and Stream UID only in `_Artifacts`. Rollback at `:228` ignores deletion false results; `services/worker/r2.py:95` and `services/worker/stream.py:117` log then return false on cleanup failure. Lost-ownership handling at `worker.py:512` deliberately avoids cleanup. A crash after upload, lost response to Stream registration, or cleanup outage has no durable worker-attempt cleanup queue. The account-deletion tombstone is not proof this separate job-attempt queue exists.

Reproduction: upload succeeds; persist nothing except Python memory; terminate process before publish, or make mocked cleanup return false. Restart has neither the old UID nor pending object inventory. Static reasoning, **not** a crash against live infrastructure.

**Repair:** durable per-attempt artifact records with planned deterministic keys before upload, registered UIDs on receipt, reference-aware cleanup status/retry/last_error; publication transaction marks referenced artifacts. Reconcile ambiguous Stream registration with provider metadata. Never delete objects referenced by the winner. Account lifecycle and R2 prefix lifecycle settings remain manual checks, not proof of this missing queue.

### WH-07 — P2: current bounds do not yet bound every resource path

The old claim that ffmpeg has no timeouts is false now. Probe/poster timeouts and process-group total/stall watchdogs exist (`services/worker/ffmpeg_render.py:116`, `:439`, `:456`, `:572`). Pixel and post-encode output caps pass real small-fixture tests. However:

- Output size is checked **after** encoding (`ffmpeg_render.py:616` / `:628`), so it does not stop disk filling during encoding. Scratch preflight is only `source_bytes * 2.5` (`worker.py:308`), which badly underestimates a long, highly compressed input expanded to 14 Mbps all-intra.
- R2 connect/read socket deadlines exist (`r2.py:60`), but no total transfer deadline/cancellation/byte watchdog surrounds `download_file` / `upload_file` at `:66` / `:77`. A slow connection that remains active can outlast a nominal socket timeout.
- No explicit ffmpeg decoder/encoder thread or RSS cap is in `_encode_cmd` (`ffmpeg_render.py:382`). Container memory/CPU/scratch-volume settings are not proven by the Dockerfile alone.
- Shared scratch is keyed only by job ID (`worker.py:343`), finally removes that directory (`:537`), and startup sweeps by directory age (`:551`). Multiple worker processes on one shared work volume can collide; total job time includes transfer/enhancement after/before the encode timeout, so directory age alone does not prove no live owner. Treat multi-process/shared-volume deployment as unsupported until per-attempt directories and active leases govern cleanup.

Repair: encoded-byte/disk-free watchdog during encode, verified total source limit on transfer, explicit CPU/memory/concurrency budgets in deployment, per-attempt scratch IDs, and live lease check before abandoned-directory cleanup. Preserve the successful existing timeout and abort tests.

### WH-08 — P2: transient lease discovery failure can still claim without a lease

`services/worker/db.py:214` returns false on a transient schema probe failure; `_claim_values` at `:228` omits lease/owner/attempt fields whenever false. A successful queued-job SELECT, failed metadata probe, successful PATCH can therefore claim a job without ownership stamps. A subsequent successful probe can make that job appear not-owned immediately, or leave it unreclaimable if lease is null. This is distinct from the correctly implemented fresh claim CAS.

Repair: before accepting any production job require confirmed lease schema. A transient probe raises a retryable error and prevents claim. Remove or explicitly opt in to legacy no-lease mode; never degrade into it on a transport failure. Acceptance: mock probe 503 followed by healthy PATCH and assert PATCH is never attempted, then retry successfully after probe recovers. Static finding; this particular branch was not dynamically reproduced in this pass.

### WH-09 — P2: dependency pinning is only partial, and runtime advisories are not dev-only

Host lock is committed, and all installed Wrangler/Miniflare/sharp/ws nodes are marked dev dependencies. Current versions: Wrangler 4.129.0, Miniflare 5.20260903.0-alpha, sharp 0.35.2, ws 8.21.0. npm audit now returns **three high entries**, sharp → Miniflare → Wrangler, from one current sharp/libheif advisory; it does **not** currently list ws. npm reports Wrangler 4.131.0 as the available fix. [Advisory](https://github.com/advisories/GHSA-rgj7-g3m4-5g8c).

More importantly, inspected emitted `bundle/index.js.map` with an assertion that no source contains `node_modules`: all six sources are first-party demo/html/legal/player/portfolio/index. The emitted script has no external dependency import. Thus these npm entries affect the local dev/build toolchain, **not the deployed Worker code inspected here**. This is not an excuse to leave the dev tools vulnerable; upgrade the exact Wrangler pin deliberately, regenerate the lock and rerun the same gates. No npm upgrade was made in this unit.

The Python worker is different: Requests and urllib3 are runtime packages. `services/worker/requirements.txt:10` pins four direct dependencies, not the seven transitive dependencies or artifact hashes. `Dockerfile:21` pins the base digest and `:42` pins direct apt package versions, but its live apt repository and transitive resolution are not a fully reproducible closure. No Docker build was performed.

Requests 2.32.3 (`requirements.txt:12`) is in the affected range `<2.32.4` of the maintainer's netrc advisory. [Requests advisory](https://github.com/psf/requests/security/advisories/GHSA-9hjg-9r4m-mvj7). Exploitability here would require the advisory's malicious URL/trusted-environment prerequisites; this pass did not demonstrate such a route or inspect netrc data. Do not invent a confirmed credential exposure. Upgrade to a tested current patched version, resolve compatible boto3/botocore/urllib3 versions together, lock/hash the full Python 3.11 Linux dependency closure and scan that resolved image. Do not blindly pin an advisory's minimum version and assume all later issues are covered.

### WH-10 — P2: public-host failures can hang or misreport unavailable as not-found

`services/edge/tour-host/src/index.ts:239` has no application timeout/abort signal and `:345` / `:378` buffer JSON without a byte ceiling. An upstream stall holds the request until platform/client cancellation; a malformed oversized response can consume excess memory. Portfolio upstream errors are collapsed to a cacheable 404 at `:384`, so a backend outage can tell a real agent their portfolio does not exist. Lead-form browser fetch at `services/edge/tour-host/src/player.ts:1613` has no timeout and can leave “Sending...” disabled indefinitely. Its success branch accepts any 2xx even if JSON is malformed/empty (`:1615`, `:1626`).

Repair: one bounded upstream fetch helper with `AbortSignal.timeout(...)`, a decoded-byte-limited reader, required-field validation and typed transient errors. Portfolio transport/5xx errors should return branded 502/503 `no-store`; reserve 404 for a real absent portfolio. Browser lead submit needs an abort deadline, retry enabled on failure, and exact expected response validation before success; retain a pending operation identity if the backend supports idempotent retries. No live stall or lead submission was performed.

## Important old findings that are no longer accurate

- **Worker claim is no longer plain SELECT then unconditional PATCH.** Both poll and explicit `--job-id` flow use conditional status updates with returned rows and lease stamps (`services/worker/db.py:235`, `worker.py:611`). Existing tests pass; the separate publication/lease-discovery/reaper issues above remain.
- **ffmpeg timeouts/resource checks exist.** Do not repeat “none” from an old audit. Missing pieces are listed under WH-07, and HDR execution remains unverified on this host.
- **Turnstile is no longer fail-open by default.** `services/supabase/functions/leads/turnstile.ts:49` rejects missing secret unless explicit `TURNSTILE_OPTIONAL=1`. Live secret presence and absence of that override are manual gates; parent lane owns direct verifier testing. Frontend site-key configuration alone proves neither.
- **A Python/host CI file and local tests exist.** `.github/workflows/ci.yml:204` has a worker job. Its current run list at `:255` covers only job lease and HDR; it omits four pre-existing suites and both new ones. Parent integration should add those explicit commands. Do not report “no tests/CI.”
- **Both demo MP4s are now tracked by Git.** `git ls-files` confirms them; `scripts/check-assets.mjs:4` still describes them as untracked. The existing asset test passes on this clean worktree, so the old clean-clone-media-missing claim is stale documentation, not a reproduced defect.

## Acceptance still required

1. Isolated real-Postgres race tests for reaper and transactional publication, including deadline changes and reused process IDs. No production corruption tests.
2. A known zscale-capable Linux image running all HDR assertions; demonstrate failing negative controls there, not only a warning banner on this Mac.
3. Large-media transfer/render fixtures with bounded RAM/scratch/time; no customer media or paid calls required.
4. Real browser viewer/lead UI tests with mocked backend responses and then an owner-approved test tenant end-to-end. Current HTML assertions are not browser clicks, rendering/accessibility proof, or customer delivery.
5. Manual deployment inventory: actual worker image/replicas/volumes, scheduler/reaper execution, Stream/R2 credentials/lifecycle/cleanup drain, Turnstile secret and optional flag, Cloudflare cache policy/redirect settings. This lane neither changed nor verified those dashboard settings.

The narrow code changes in this unit are ready for independent review. The unresolved issues above are explicit engineering work, not a blanket “everything tested” statement.
