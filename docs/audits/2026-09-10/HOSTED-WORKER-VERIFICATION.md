# Hosted worker and tour-host verification — 68f39a2

Evidence collected read-only from GitHub Actions run **34544905277**, attempt **1**, for exact source **68f39a24c9d685cc198dee3c899bf15a672716cd**. Both reviewed jobs checked out this SHA (each downloaded job log, line 107). No workflow was dispatched or retried, no code or production configuration changed, and no provider/deployment request was made while collecting this evidence. The only repository change in this unit is this report.

**The two jobs succeeded; the full CI run did not.** GitHub's run-level conclusion is `failure`. The edge-functions, secret-scan, and two database jobs failed; their reasons are outside this worker/host log review. Do not call this evidence a green release or a green full CI run. [Run 34544905277](https://github.com/AaronPilk/RendProp-Ai/actions/runs/34544905277)

| Reviewed job | GitHub conclusion | UTC start → completion |
| --- | --- | --- |
| [Render worker (python), 103095319116](https://github.com/AaronPilk/RendProp-Ai/actions/runs/34544905277/job/103095319116) | success | 2026-09-11 00:04:29 → 00:05:31 |
| [Cloudflare Worker (tour-host), 103095319075](https://github.com/AaronPilk/RendProp-Ai/actions/runs/34544905277/job/103095319075) | success | 2026-09-11 00:04:29 → 00:04:51 |

These timestamps correspond to September 10, approximately 8:04–8:05 PM Eastern. GitHub's individual step API results also show success for the test/build/audit steps; no required step in either reviewed job was skipped.

## Commands used to collect the evidence

```sh
gh api repos/AaronPilk/RendProp-Ai/actions/runs/34544905277
gh api repos/AaronPilk/RendProp-Ai/actions/jobs/103095319116
gh api repos/AaronPilk/RendProp-Ai/actions/jobs/103095319075
gh run view 34544905277 --repo AaronPilk/RendProp-Ai --job 103095319116 --log
gh run view 34544905277 --repo AaronPilk/RendProp-Ai --job 103095319075 --log
gh api repos/AaronPilk/RendProp-Ai/actions/runs/34544905277/artifacts
```

API output was restricted to job/run identity, status, timestamps, steps and artifact metadata. Downloaded logs are retained locally at `/tmp/rendprop-hosted-worker.qO7kh4/worker.log` and `host.log`. This report omits environment binding values and does not embed the complete logs. Their SHA-256 hashes:

```text
worker.log  393f9c7d3b469ac7fb1b904a504835d917ad034a7c13eee1eadf172d5e66db42
host.log    00a133dd42d3c2fe2e1050858a23cddfca0681207dda91ad0d73ccc26653ec39
```

Line numbers below refer to those exact `gh run view --log` files. `/tmp` copies are temporary; the GitHub job links and this committed report are the durable references, subject to GitHub's log-retention policy.

## Python worker: commands and exact execution counts

Workflow definition: `.github/workflows/ci.yml:290–351` at the audited SHA. Hosted environment: **Ubuntu 24.04.5**, runner image **20260907.300.1**, **CPython 3.12.14** (`worker.log:12,17,121`).

Successful setup gates:

- `python -m compileall -q services/worker services/pipeline` — byte compilation completed successfully. This is not execution of every pipeline function.
- Requirements gate — printed `all worker requirements are pinned`; this gate specifically checks for prohibited `>=` requirements, not every possible form of an unpinned transitive dependency.
- `pip install --disable-pip-version-check -r services/worker/requirements.txt` and `sudo apt-get update -qq && sudo apt-get install -y -qq ffmpeg` — installation step succeeded.
- APT recorded **`ffmpeg (7:6.1.1-3ubuntu5)`** at `worker.log:481,618` (FFmpeg 6.1.1 package). The job did **not** print `ffmpeg -version`, the resolved executable path, or its binary hash, so the installed package version is the exact version evidence available; an independently bound runtime-binary receipt is not present.

The test step uses `/usr/bin/bash -e` (`worker.log:645`): a nonzero script would stop the step. Each command below is `python3 services/worker/tests/<script>`, in the listed execution order. Counts were independently calculated from the actual `ok` assertion lines or unittest result footers, not copied from workflow comments.

| Script | Observed executed count | Evidence in worker.log |
| --- | ---: | --- |
| `test_job_lease.py` | 69 explicit checks | checks 657–750; success 752 |
| `reproduce_stale_publish.py` | 14 unittest tests | result 769; OK 771 |
| `test_reaper_snapshot.py` | 6 unittest tests | result 798; OK 800 |
| `test_verification_prerequisites.py` | 4 unittest tests | result 815; OK 817 |
| `test_stream_fallback.py` | 12 unittest tests | result 842; OK 844 |
| `test_lease_probe_fail_closed.py` | 10 unittest tests | result 861; OK 863 |
| `test_process_specific.py` | 17 explicit checks | checks 877–905; success 907 |
| `test_cost_spool.py` | 23 explicit checks | checks 910–938; success 940 |
| `test_r2_timeouts.py` | 6 explicit checks | checks 943–952; success 954 |
| `test_resource_limits.py` | 19 explicit checks | checks 957–986; success 988 |
| `test_hdr_tonemap.py` | 19 explicit checks | checks 999–1021; success 1023 |

Total: **153 explicit checks + 46 unittest tests = 199 mixed checks/test cases across 11 scripts, zero skipped tests.** This does not mean 199 SQL, real-provider, or camera tests. SQL transaction behavior is verified by the separate disposable-database job; these worker tests exercise the actual Python paths with synthetic/loopback external services and real local media tools where specified.

### HDR was exercised, not a zero-assertion green

The earlier log text `0 assertions ran: ffmpeg/ffprobe not on PATH` (`worker.log:819–826`) belongs to the deliberate prerequisite negative control. `test_verification_prerequisites.py:14–16` mocks `shutil.which` to return nothing and **asserts `hdr.main() == 1`**. The same suite asserts two missing-resource prerequisite failures and rejects empty/failed signalstats (`:18–33`). Those expected diagnostics are not a skipped HDR test or proof of a working encode.

The **separate final command**, `test_hdr_tonemap.py`, subsequently generated fixtures and ran the real worker `_encode_cmd` (`test_hdr_tonemap.py:109–114,146–163`). It emitted nonempty measured signalstats and **19 passing checks** at `worker.log:990–1023`:

- Tagged and untagged SDR: 3 checks each — no tone-map chain, successful encode, reference-matching mean luma/saturation. **6 checks.**
- PQ and HLG HDR: 5 checks each — tone-map chain applied, successful encode, saturation at least 70% of reference, mean luma at least 70% of reference, and bt709 transfer tag. **10 checks.**
- `TONEMAP_HDR=0`: no tone-map chain, successful encode, measurably lower saturation than tone-mapped PQ. **3 checks.**

The observed measurements (0–255 scale; averaged and rounded to one decimal by the test) were:

| Fixture/output | Encode result | Tone-mapped | YAVG | YMAX | SATAVG |
| --- | --- | --- | ---: | ---: | ---: |
| SDR source reference | source measurement | no | 103.4 | 253.0 | 39.1 |
| Tagged SDR encode | rc=0 | no | 103.4 | 253.1 | 39.1 |
| Untagged SDR encode | rc=0 | no | 103.4 | 253.1 | 39.1 |
| PQ HDR encode | rc=0 | yes | 100.0 | 206.1 | 35.0 |
| HLG HDR encode | rc=0 | yes | 99.7 | 206.9 | 35.5 |
| PQ opt-out encode | rc=0 | no | 79.6 | 133.9 | 9.5 |

The source gate returns nonzero when binaries/filters/fixtures are unavailable (`test_hdr_tonemap.py:124–151`) and rejects empty signalstats (`:54–76`). This is genuine synthetic HDR→SDR encode evidence. It is **not** a visual evaluation of real iPhone footage, Dolby Vision dynamic metadata, every camera/device, or bit-for-bit preservation of compressed SDR video. The fixture is 640×360, two seconds; the worker is invoked at speed 2.0.

## Cloudflare tour-host: clean install, checks and dry-run

Workflow definition: `.github/workflows/ci.yml:81–118`. Hosted Node **22.23.2**, npm **10.9.8** (`host.log:122–123`). An npm download cache was restored; `npm ci` still performed a clean lockfile-driven installation. This was not a cold-network dependency fetch proof.

| Command / gate | Actual output and result | Evidence in host.log |
| --- | --- | --- |
| `npm ci` | success; added **42 packages**, audited **43**; **3 high-severity vulnerabilities** in dev-inclusive tree | 135–150 |
| `npm run typecheck` | `tsc --noEmit`; success | 152–158 |
| `npm test`: unbranded renderer | **557 assertions over 15 renders + 12 gate self-tests**; passed | 168 |
| `npm test`: route checks | **584 assertions**; passed | 169 |
| `npm test`: upstream checks | **707 assertions / 75 cases / 0 skipped**; passed | 170 |
| `npx wrangler deploy --dry-run --outdir /tmp/wrangler-dry` | Wrangler **4.129.0**; **45** asset files read; **184.28 KiB**, gzip **57.23 KiB**; explicit `--dry-run: exiting now.`; success | 171–185 |
| `npm audit --omit=dev --audit-level=high` | **found 0 vulnerabilities**; success | 189–193 |

Host tests therefore report **1,848 assertions plus 12 gate self-tests**, not 1,860 browser/device interactions. They exercise actual renderers/routes against fixtures. `npm test` runs the three scripts named in `package.json:12`; this CI job does not separately run `npm run check:assets` (`package.json:16–17`). The dry-run read of 45 asset files is not a replacement assertion for that script.

### Dependency and deployed-bundle proof boundaries

The hosted logs do **not** list individual advisory IDs or affected packages for the three dev-inclusive high advisories. It would be incorrect to reuse the earlier audit's four-advisory count or identify today's three solely from those summary lines.

Separate source inspection at **68f39a2** supports the tooling-only classification: `services/edge/tour-host/package.json:19–23` contains only devDependencies, and its lockfile marks Wrangler **4.129.0**, Miniflare **5.20260903.0-alpha**, sharp **0.35.2**, and ws **8.21.0** as `dev: true`. Miniflare is a Wrangler dependency and depends on sharp/ws. The inspected `src/*.ts` import declarations are local application modules, not Miniflare/sharp/ws. These facts and the zero-production-advisory result are narrower than proof about any live deployment.

**This run did not retain a Worker bundle, source map, esbuild metafile, SBOM, or deployed-script digest.** The artifact API lists only `disposable-database-regression-1` and `gitleaks-results.sarif`. Bundle composition cannot be independently read back from this run's artifacts, and no live Cloudflare Worker was downloaded or compared. The supported conclusion is “the clean hosted dry-run bundled successfully, and the production npm graph audit found zero advisories,” **not** “this proves exactly which bytes/dependencies are currently deployed.” Cloudflare skill guidance was used to preserve that distinction; no Cloudflare API or deployment was invoked during this evidence collection.

## Bottom line

The prior local Mac HDR capability gap is now complemented by successful **hosted Linux synthetic HDR runtime evidence on 68f39a2**. Worker regression commands and clean tour-host install/typecheck/tests/dry-run/production audit also succeeded on that exact source. The full CI run remains red, current production deployment identity is unverified by these jobs, and real-camera/AR behavior still requires the user's device testing.
