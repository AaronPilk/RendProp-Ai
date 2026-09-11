# Rendprop: active engineering and audit checkpoint

Updated 2026-09-10, evening Eastern. **Work in progress, not a whole-app GO.**
This file is the durable entry point for Claude and the parallel side chat.
Read the standing brief first; its production-data, provider, Apple and frozen
motion-prompt constraints remain in force. Never substitute an intended test
for an executed result. Every later checkpoint must preserve open findings.

## New block authorized — September10 evening

Read [`NEXT-BLOCK.md`](NEXT-BLOCK.md) for the owner's new one-room GPU approval,
parallel branch ownership and remaining decisions. The former missing-spend-
approval gate is superseded: USD25 total, one GPU, provider-enforced two-hour
lifetime, prepared dataset only, remote cleanup mandatory. Modal was selected
and authenticated; no trained-room result is claimed yet. Production and Apple
remain untouched. Later checkpoint counts below are historical evidence, not
proof of these new units.

## Read first: final tested and pushed code checkpoint

- **Branch:** `audit/full-regression-20260910`, pushed to `AaronPilk/RendProp-Ai`.
- **Latest tested code:** `a9b13b1f1b66fee1f52fdd566e7de82f8b272b3b`.
  Subsequent commits update documentation only; do not confuse them with a new
  application build or an additional test run.
- **Latest completed hosted run:**
  [34546654166](https://github.com/AaronPilk/RendProp-Ai/actions/runs/34546654166),
  seven passing jobs and three failing jobs, overall FAILURE. Edge:602 tests;
  host:2,266 assertions plus12 self-tests. Both database jobs retain the AI
  headroom mismatch; the historical scanner findings remain classified/open.
- **Product delivery:** source fixes and this handoff are on GitHub. No
  production deployment, TestFlight upload or Apple review change was made.
- **Spatial outcome:** the app is live, but build18 only captures/exports.
  Hosted reconstruction of the owner's real room and a navigable viewer are
  still unfinished. Do not tell the owner to operate a local GPU as the product.

The detailed checkpoint history below preserves commands, corrections and
evidence. Earlier counts and source commits are historical, not competing
claims about the latest run. For the next engineer, continue with the ranked
open-work list rather than repeating completed tests as unfinished work.

## Integrated checkpoint history — September10 evening

Base combined checkpoint: **`68f39a24c9d685cc198dee3c899bf15a672716cd`** on
`audit/full-regression-20260910`. The app is live; these changes are source
repairs, **not a production deployment or a new TestFlight build**. Verdict for
the entire requested experience remains **NO-GO / unfinished**, not a claim
that every existing app feature fails. The owner should not have to operate a
GPU or export files to use the eventual spatial product.

Completed and independently reviewed in this branch:

- **Upload publication race repaired locally:** each single-PUT completion
  copies to its own fresh key; a conditional database update selects the only
  winner. Late complete/abort/mismatch handlers cannot overwrite or erase that
  winner. Multipart freezes the exact canonical manifest before assembly.
- **Same-ETag metadata race repaired:** promote with explicit verified
  Content-Type and `REPLACE`; opt into the pinned signer's `allHeaders` so the
  metadata is actually signed. The previous helper and an unsigned-replacement
  mutant both failed the new regression before the final 51-upload-test pass.
- **Stale-worker publication repaired locally:** migration0035 atomically
  fences owner, attempt and database-clock lease; render/photos/outcome/receipt/
  job/listing readiness commit together. Exact replays are read-only. Raw input
  must be a private completed video; duration/speed must be numeric and exactly
  representable at database precision. Migration0036 freezes completed uploads.
- **UX/disclosure repairs built and visually checked:** complete Ask AI label
  and 44-point target, reachable consent actions, corrected processor/data
  disclosures and version2 re-consent. Coach offline/account copy and the
  consent selector repair are integrated too.
- **Host/provider reliability:** bounded upstream response reads, immediate
  customer-page revocation behavior, incomplete OpenAI response rejection,
  bounded Stream fallback and fail-closed lease-schema discovery are integrated.
- **CI wiring:** actual 14-test worker publication wrapper, Ask AI source test,
  isolated PostgreSQL16 execution and seven-day receipt/log artifacts. No red
  invariant is skipped or converted into success. See `CI-PUBLICATION-GATES.md`.

Root-executed edge run on that base checkpoint: **598 tests,0 failures/ignored;21/21 entrypoint
checks; actual Turnstile fail-open mutant rejected**. Clean source remained
unchanged. Receipt `/tmp/rendprop-edge-audit-o5on_vp_/receipt.json`.
Root also reran all ten worker scripts on this same clean checkpoint:
**180 checks/tests pass**, including tiny real ffmpeg resource fixtures. This
does not include the unavailable local HDR/zscale path or a live provider call.

Latest actual disposable PostgreSQL17.11 run on `a81a143`: **38 migrations
apply,30 replay;22 worker checks pass four times;19 upload checks pass twice**.
Four actual removed-guard controls fail for the intended reasons; restored
functions pass again. Six paid-route outcomes and the team-entitlement
corruption control are detected. Cluster stopped successfully. **197/198
invariants still pass on both runs, overall exit1/accepted=false** for the
unchanged AI headroom mismatch. Receipt `/tmp/rendprop-db-audit-h9sm8997/receipt.json`.
The tested SQL/runner is integrated unchanged; `DATABASE-EXECUTED-RESULTS.md`
records commands, sources, limits and the earlier wrong-reason negative control.

**Correction:** the existing duration constraint already rejects `0.004`
rounding to zero. There was no demonstrated ready-zero-duration bug. The real
precision mismatch was `30.001` accepted then stored as `30.00`; that case now
fails explicitly, and removing the new guard demonstrably reintroduces it.

Remaining work includes the hosted real-room 3D pipeline, physical upload-cost
containment/orphan cleanup, durable worker artifact recovery, tenancy findings,
privacy/Terms reconciliation and device coverage. The ranked next-work list is
below. Reports preserve those residuals instead of marking entire historical
P0 categories FIXED based on these narrower publication repairs.

The tested code and unit branches were pushed. Intermediate tested code
**7b60ada** contains the subsequent timer-type and lazy-Deno.serve descriptor fixture
repairs are proven by actual GitHub run34546017429. **602 edge tests and all21
entrypoints pass on hosted Deno2.9.6**, and the local same-source gate also
passes602 with the Turnstile mutant detected. Its receipt is
`/tmp/rendprop-edge-audit-lszgf9yw/receipt.json`.

The third hosted workflow has **seven passing jobs and three failing jobs**;
overall FAILURE. Both database jobs report the retained headroom mismatch;
the new job completed all publication/replay/negative/stop steps on PostgreSQL
16.15 and retained verified receipt/log artifacts. Hosted worker evidence proves
199 checks/tests including19 actual HDR assertions. The scanner's six historical
hits are classified without values in `CI-RUN-34544905277.md`: four fixtures,
one intended bundled anon claim and one unresolved historical curl header.
No evidence establishes a privileged credential compromise; private triage and
rotation verification if real remain required for that unresolved hit. Follow
[`HOSTED-CI-20260910.md`](HOSTED-CI-20260910.md) for the exact run and corrections;
neither a push nor a green individual job is a whole-app release verdict.

Latest implemented/pushed code is **a9b13b1**: the public lead form now waits at
most15 seconds for headers plus JSON, requires `ok:true` and a UUID lead ID for
ordinary confirmation, preserves the intentional honeypot exception, prevents
double-submit and ignores late completion after timeout/retry. Failure retains
inputs and resets Turnstile; it does not claim an uncertain lead was never saved.
Root independently ran the full host typecheck/tests/assets:2,266 assertions+
12 self-tests pass, including418 assertions/31 actual emitted-form scenarios.
See `PUBLIC-LEAD-FORM.md`. Hosted CI run34546654166 now confirms this exact
source: lead-form/full host suite, clean install, typecheck,186.08KiB dry-run
bundle and zero production npm advisories pass. Edge again passes602 tests.
Seven jobs pass/three remain red for the documented database/scanner gates.

### Verified iOS checkpoint — approximately 19:42 Eastern

All28 baseline screenshots have now been visually reviewed. The resulting
Ask AI truncation repair and processor-disclosure/v2 re-consent correction
passed a **new clean Release build +2 focused UI tests,0skips,5 required images**
on `50c95d3`. Root inspected those5 images; label is complete, Coach opens,
corrected cards fit and agree/decline remain reachable. Exact receipt:
`/tmp/rendprop-noncamera-ui-3_d1cfjd/receipt.json`.
See `UI-VISUAL-REVIEW.md` and `AI-CONSENT-DISCLOSURE.md` for source changes,
10 portable checks/24 persistence assertions, and remaining privacy-policy and
device-matrix gaps. These changes are not in the owner's installed TestFlight18.

Historical combined-source edge receipt is `/tmp/rendprop-edge-audit-dpkovht9/receipt.json`,
source `50342c7`: **563 tests passed,0 failed/ignored;21 entrypoint typechecks passed;
actual Turnstile mutant failed as required**. Shared adapters and SQL are now
hashed too, and clean unchanged source is required for an accepted receipt.

The rebuilt consent + Reviewer + Main UI gate passed on `7d0b0ca`: **3 exact
tests,0 skips,24 required screenshot attachments (21 distinct required names)**.
Receipt `/tmp/rendprop-noncamera-ui-3hx5az4i/receipt.json`; Release build and exact
app/test artifacts are hashed. Root inspected all28 exported screenshots.
This proves interaction and screen reachability, not live backend behavior.
The separate disclosure correction and focused rebuilt result are above.

New reviewed units are integrated: `29b0f16` consent selector, `1c42bd8` Coach
offline/account copy, `b6c0d8a` bounded host upstream reads, `76fe6ee` unfinished
AI response rejection, and the database test/harness corrections. Four further
primitive-response fixtures passed without another adapter change; they are
additional coverage, not a newly reproduced product bug.

Actual isolated DB execution applied36 migrations and replayed28: **198
assertions per run;197 pass,1 fails** on both runs. Six real paid-route negative
outcomes pass; corrupt team data is rejected. Cluster stop exit0. Overall
runner remains exit1/accepted=false. See `DATABASE-EXECUTED-RESULTS.md` and
`/tmp/rendprop-db-audit-s_7bv818/receipt.json`. The runner's27 mocked control-flow
regressions also pass; those are not27 extra DB invariants.

Root independently reran the existing140 worker checks against integrated
source (including real tiny ffmpeg fixtures), all exit0, in addition to the32
new/repaired unittest cases. Host upstream:707 assertions/75 cases pass;
existing584 routes and557 unbranded assertions/12 self-tests pass.

The newer publication fixes and their expanded actual SQL evidence supersede
this checkpoint's former in-progress status. Migrations0035(worker) and0036
(uploads) are integrated development changes, not live database changes.
Pending Apple submission and installed TestFlight18 are untouched.

### Earlier checkpoints and repaired failures

`8111522` and the foundation/style branches were pushed to GitHub. Worker unit
`e388f019` and consent unit `b96896e` have now been independently reviewed and
merged into this audit branch. The worker test commands omitted by the existing
CI are wired in; missing HDR filters now fail instead of reporting green.
Fresh integrated non-camera UI verification **found a new failure**, using the committed
`tools/audit/run_noncamera_ui.py` (two exact tests, 21 required screenshots,
source/artifact receipt, no camera tests, no Apple upload). Source `d05bbec`
built successfully, but ReviewerWalk exited65: 0passed/1failed/0skipped,
“Consent scroll view is missing.” The actual accessibility hierarchy shows
the outer `aiConsent.root` ID masking the inner scroll ID. The later repair passed above;
the original assertion was not skipped or relaxed. MainWalk did not run after
this failure. Evidence: `/tmp/rendprop-noncamera-ui-jxozgi3w/Reviewer.xcresult`.
The earlier attempt stopped before compilation because XcodeGen changed
worktree-derived project IDs; that generated project was checkpointed first.

The upload-completion reproduction was independently rerun and reviewed against
the installed PostgREST client: **one intended failed invariant**, same-size
content replacement after completion. This is not an oversized-object proof.

The real capture is assembled outside Downloads under an owner-only local
directory. Independent synthetic review of its new wrapper found two boundary
bugs (nested output mutating an original capture tree, default dataset modes);
repairs in `869c30f` are now independently reviewed and integrated. Four new
regressions failed before repair, then passed. The owner's originals were not altered.

Worker reliability `5aa0678` and host revocation `7933f75` are integrated too.
Root reran the new Stream12/lease10 tests with a cleared environment: all22
passed. Root reran host584 route assertions and typecheck: both exit0. The
reaper6/prerequisite4 tests also passed independently. No production deployment.

An isolated local PostgreSQL17.11 cluster applied all36 migrations successfully.
The real invariant suite executed194 assertions, with6false/exit3. Five stale
test expectations and two additional unregistered bare-SELECT gates are being
corrected; the remaining token-headroom mismatch is not being hidden. The
cluster was stopped and retained. See the separate pushed branch
`audit/database-regression-20260910` for its runner and deployed-spatial inventory.

## Source and delivered work

- Installed internal TestFlight build: **1.0 (18)**, source `ed0131b`.
  Claude uploaded it. Independent local archive/signature checks and Apple
  read-only checks confirm internal availability; build16 remains attached to
  WAITING_FOR_REVIEW. See `docs/releases/TESTFLIGHT-18-20260910.md` and its JSON
  receipt. Five fresh same-source UI tests passed, zero skips, 22 required
  screens inspected **after** upload. The exported IPA signature was not checked.
- Web architecture/tokens/parity contracts: `c8d1283`, integrated. See
  `docs/web-client/ARCHITECTURE.md`, `PARITY.md`, `TENANCY-AUDIT.md`,
  `EDITOR-ASSESSMENT.md`, and `STYLE-UPLOAD-DESIGN.md`.
- Offline style library and bound blind-evaluation contracts: `76e4b7a`,
  integrated. No live style execution, provider calls or quality claims.
- Offline style CI job: `20f17cd`, integrated. Remote CI has not run; local
  Deno is2.7.13, CI's existing pin is2.9.6.
- Stable integration branch: `integration/web-editor-foundation-20260910`.
  Current audit checkpoint branch: `audit/full-regression-20260910`.

## Actual new verification

| Area | Executed result | Evidence / limit |
| --- | --- | --- |
| Supabase edge tests | **602 passed, zero failed/ignored** | Source7b60ada; both local and actual hosted runs, not live product routes |
| All edge entrypoints | **21/21 typechecks passed** | Cached imports, no route execution |
| Deliberately broken Turnstile | **Exit1 with real failed assertions** | Copied source changed to fail open; proves tests detect that defect |
| New audit-runner parser | **5 tests passed** | Names containing “ignored” are not skips; real skipped summaries are counted |
| Web contract/tokens | **14 passed** | 41 unique API methods/42 declarations,24 outside-protocol capabilities; zero browser-parity claims |
| Style library | **101 passed; seven real mutants failed** | 408 EDL-preservation combinations; no rendering or human quality study |
| Worker/hosting lane | **180 current Python checks/tests**;584 route assertions;557 unbranded +12 self-tests | Root reran all ten current worker scripts; supersedes former140+32 total after replacing unsafe-helper tests; no deployment |
| Hosted worker including HDR | **199 checks/tests, including19 real HDR assertions** | Eleven scripts; separate from local180, not199 live calls; HOSTED-WORKER-VERIFICATION.md |
| Bounded host upstream | **707 assertions /75 actual-handler cases** | Synthetic streams, aborts, byte caps and honest statuses; no production request |
| Public lead-form handler | **418 assertions /31 cases,0 skips** | Real emitted JS with stub DOM/fetch/timers; not a live CRM/browser session |
| Database replay | **197/198 pass, twice; overall FAIL** | All38 migrations +30 replays; one retained headroom mismatch, not live Supabase |
| Publication SQL | **22 worker checks ×4;19 upload checks ×2 pass** | Four actual removed guards detected and restored; not concurrent production HTTP |
| Database harness | **30 mocked-main +7 source tests pass** | Includes intentionally truncated suites, lost receipts, wrong-reason mutants and real SQL registration checks |
| Portable spatial suite | **63 Python +21 viewer tests pass** | Native115 capture assertions,3076 pose assertions and actual Swift→Python interop; no real-room reconstruction |
| Rebuilt non-camera iOS UI | **3 exact tests,0 skips,24 required attachments pass** | Source7d0b0ca; no camera/AR, new upload or App Store change |
| Focused repaired iOS UI | **2 exact tests,0 skips,5 required attachments pass** | Source50c95d3; root viewed all5; no iOS source changes since |
| Real owner capture | **256 JPEGs decoded and dataset prepared** | 14,654 usable initialization seeds; no GPU reconstruction or phone-room viewer yet |

Main edge receipt: `/tmp/rendprop-edge-audit-lszgf9yw/receipt.json`.
Earlier530-test receipt: `/tmp/rendprop-edge-audit-33zluacl/receipt.json`.
Main style receipt: `/tmp/rendprop-style-policy-verify-4a4985b890c82161/summary.json`.
Temporary evidence paths are not backups; source/scripts and this account are
committed, but logs/archive bytes must be retained separately if needed.
[`VERIFICATION-INDEX.json`](VERIFICATION-INDEX.json) durably records the selected
source hashes, counts, command results and receipt/log hashes. It is a curated
index, not a copy of raw logs, app artifacts, customer media or a deployment receipt.

Exact portable edge command, run from repo root:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 tools/audit/run_edge_regression.py
```

The first runner attempt correctly stayed red but had two harness mistakes:
the word “ignored” in test names was mistaken for a skip, and `deno check` was
given an unsupported `--cached-only` flag. Both are fixed; real summary parsing
has its own five tests, and the supported check command uses `--deny-import`.
Those first results were NOT product defects and NOT claimed as passes.

## Historical upload reproduction — repaired locally, not deployed

**P1, before the new per-attempt-key repair:** source-conditional copies did not
make completion publication immutable. The following lines describe the old
reviewed source, not the current handler. Current implementation, exact code
references and remaining cost/cleanup limits are in
[`upload-publication-immutability-20260910.md`](../../handoff/upload-publication-immutability-20260910.md).
`services/supabase/functions/uploads/index.ts:467–475` reads uploaded state;
`:614–617` copies before the DB compare-and-set; `:629–643` compares uploaded
only after the final object has already changed. The comment saying concurrent
completes copied identical bytes is not guaranteed.

Actual-route offline diagnostic: `tools/audit/uploads_completion_race_test.ts`.
It imports the real uploads route, intercepts `Deno.serve`, and replaces every
upstream with synthetic Auth/PostgREST/R2. No socket or real storage call occurs.
Both distinct four-byte sources match declared size/type and their own source
ETag. Request A copies AAAA; request B reads the still-incomplete asset and
HEAD-verifies BBBB; A commits uploaded=true; delayed B copies BBBB over A's final
key. Both calls return200, but the immutable-object assertion fails.

Pre-fix desired-contract test: **exit1, one executed assertion-failing test**,
“Final object was replaced after completion committed”, actual BBBB vs AAAA.
This was a recorded defect, not a passing release check. Earlier fixture
iteration used the wrong zero-row PostgREST response and was corrected before
claiming the actual invariant failure.

```sh
deno test --cached-only --no-config --no-lock --node-modules-dir=manual \
  --allow-env --deny-net --deny-run --deny-write \
  tools/audit/uploads_completion_race_test.ts
```

Implemented repair contract: storage writes must be fenced **before promotion**, with
immutable per-attempt destination keys and a DB-selected winning key, or a
durable completion state/lease plus a genuinely enforced destination fence.
A second SELECT, source ETag alone, or a post-copy uploaded CAS is insufficient.
Completion/abort/mismatch cleanup must use the same attempt identity so a stale
request cannot undo a winning completion. Do not deploy a speculative partial fix.

## Integrated units and remaining verification

- `b96896e` / `audit/ios-noncamera-ux-20260910`: consent tab-bar layout,
  accessibility IDs, strengthened ReviewerWalk, and full IOS-UX.md. Integrated;
  the actual new walk failed on its scroll identifier, as recorded above.
- `e388f01` and `5aa0678`: stale-job reaper snapshot fence;
  original6-test fixture failed4, patched6 pass. Verification prerequisites no
  longer report success with zero HDR assertions. Full WORKER-HOST.md includes
  historical stale-publication findings, superseded locally by
  `WORKER-PUBLISH-TRANSACTION.md`. Buffering and transient lease discovery
  are fixed locally; the separate host revocation repair is `7933f75`.
- `fbdcba2` plus `869c30f`: capture inspector, hash-bound private preparation
  and portable no-Xcode-build gate. Final63 Python/21viewer tests and native
  portable checks pass; root read all new code/tests and independent review
  found no remaining blocker in this bounded wrapper. Integrated, not reconstruction.

## Spatial: what actually happened and what is next

The owner confirmed capture works on the iPhone after build18. The product UI
still only saves/exports. This is not a missing hidden button: reconstruction
and an in-app navigable scene are not wired into this build.

The supplied manifest,256 frame sidecars and256 JPEGs were checked locally and
assembled into a new private working copy. Originals were not moved or modified.
513 source files /151,650,870 bytes; prepared dataset and provenance receipt are
under `/Users/pilksclaes/LocalSpatialExperiments/capture-handoff.sXFKTV/`.
**Never copy that private media or raw room geometry into Git.**

The chosen trainer needs Linux/NVIDIA CUDA; this Mac is M4 Pro. A real GPU run
with an approved host, financial ceiling and host TTL is still needed, followed
by PLY→SOG conversion and private phone-browser viewing. No GPU, external media
upload or paid provider was used. Phase B–E product work remains gated on the
owner seeing the real reconstructed room; the Phase A experiment is unfinished.

## Next work, not completion claims

1. **Deliver the real spatial product:** finish one private reconstructed-room
   proof, then hosted upload/job/executor/status/viewer/review/publication wiring
   in the brief's order. See `SPATIAL-DEPLOYED-GAP.md`. A deployed iOS app does
   not supply the missing reconstruction executor. No real-room artifact or
   approved compute destination/spend ceiling has been established.
2. **Close bounded-cost and cleanup gaps:** presigned upload transport still
   accepts oversized/replayed physical data; orphan candidates and failed
   cleanup need durable accounting/retry. Worker publication is now atomic,
   but crash artifacts and superseded media still need durable recovery.
3. **Resolve the actual red AI invariant:** agent-reel row ceiling700 equals
   visible maximum700. Measure maximum-shape EDLs and choose a deliberate
   budget/contract correction; do not raise cost or weaken `>` silently.
4. **Continue tenancy/adoption/deletion regression:** retained
   `docs/web-client/TENANCY-AUDIT.md` findings include adoption error handling,
   workspace selection, writable trust fields and refresh/idempotency gaps.
   Current unit/SQL checks do not replace multi-role live HTTP coverage.
5. **Finish UX/legal and media reliability:** reconcile public privacy/Terms
   with actual data flows (proposal in `PRIVACY-POLICY-RECONCILIATION.md`), fix
   remaining RenderEngine concurrency warnings. The browser lead-form timeout/
   confirmation contract is now repaired locally; live CRM/Turnstile delivery
   and server-side idempotency remain separate. Hosted HDR passes19 assertions;
   actual iPhone/Dolby Vision quality and device accessibility/layout coverage
   still need real-device evidence, without simulator camera attempts.
6. **Complete web/editor product after its contracts:** foundations are not
   browser parity. No actual web create→edit→review→publish→two-links walk ran.
7. **Release separately:** verify deployed migration/code parity, drain old
   upload handlers and worker binaries, run authorized test-environment round
   trips, and retain release receipts. Do not infer deployment from GitHub push.
   Pending Apple submission remains untouched.
