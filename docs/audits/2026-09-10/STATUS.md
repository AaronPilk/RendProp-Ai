# Rendprop: active engineering and audit checkpoint

Updated 2026-09-10, evening Eastern. **Work in progress, not a whole-app GO.**
This file is the durable entry point for Claude and the parallel side chat.
Read the standing brief first; its production-data, provider, Apple and frozen
motion-prompt constraints remain in force. Never substitute an intended test
for an executed result. Every later checkpoint must preserve open findings.

### Current integration checkpoint

`8111522` and the foundation/style branches were pushed to GitHub. Worker unit
`e388f019` and consent unit `b96896e` have now been independently reviewed and
merged into this audit branch. The worker test commands omitted by the existing
CI are wired in; missing HDR filters now fail instead of reporting green.
Fresh integrated non-camera UI verification **found a new failure**, using the committed
`tools/audit/run_noncamera_ui.py` (two exact tests, 21 required screenshots,
source/artifact receipt, no camera tests, no Apple upload). Source `d05bbec`
built successfully, but ReviewerWalk exited65: 0passed/1failed/0skipped,
“Consent scroll view is missing.” The actual accessibility hierarchy shows
the outer `aiConsent.root` ID masking the inner scroll ID. A repair is underway;
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
| Supabase edge tests | **526 passed, zero failed/ignored** | Actual tests, network denied and process environment cleared; not live routes |
| All edge entrypoints | **21/21 typechecks passed** | Cached imports, no route execution |
| Deliberately broken Turnstile | **Exit1 with real failed assertions** | Copied source changed to fail open; proves tests detect that defect |
| New audit-runner parser | **5 tests passed** | Names containing “ignored” are not skips; real skipped summaries are counted |
| Web contract/tokens | **14 passed** | 41 unique API methods/42 declarations,24 outside-protocol capabilities; zero browser-parity claims |
| Style library | **101 passed; seven real mutants failed** | 408 EDL-preservation combinations; no rendering or human quality study |
| Worker/hosting lane | 140 existing Python checks +32 unittest cases;584 route assertions;557 unbranded +12 self-tests | New fixes integrated; root independently reran32 cases and584 routes; no deployment |
| Real owner capture | **256 JPEGs decoded and dataset prepared** | 14,654 usable initialization seeds; no GPU reconstruction or phone-room viewer yet |

Main edge receipt: `/tmp/rendprop-edge-audit-l_pqliup/receipt.json`.
Main style receipt: `/tmp/rendprop-style-policy-verify-4a4985b890c82161/summary.json`.
Temporary evidence paths are not backups; source/scripts and this account are
committed, but logs/archive bytes must be retained separately if needed.

Exact portable edge command, run from repo root:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 tools/audit/run_edge_regression.py
```

The first runner attempt correctly stayed red but had two harness mistakes:
the word “ignored” in test names was mistaken for a skip, and `deno check` was
given an unsupported `--cached-only` flag. Both are fixed; real summary parsing
has its own five tests, and the supported check command uses `--deny-import`.
Those first results were NOT product defects and NOT claimed as passes.

## New confirmed open upload finding

**P1: source-conditional copies do not make completion publication immutable.**
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

Current desired-contract test: **exit1, one executed assertion-failing test**,
“Final object was replaced after completion committed”, actual BBBB vs AAAA.
This is a recorded open defect, not a passing release check. Earlier fixture
iteration used the wrong zero-row PostgREST response and was corrected before
claiming the actual invariant failure.

```sh
deno test --cached-only --no-config --no-lock --node-modules-dir=manual \
  --allow-env --deny-net --deny-run --deny-write \
  tools/audit/uploads_completion_race_test.ts
```

Repair contract: storage writes must be fenced **before promotion**, with
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
  still-open stale-publication findings. Buffering and transient lease discovery
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

1. Repair the measured consent accessibility-ID collision, then rerun
   ReviewerWalk+Main with the new consent screenshots. No redundant camera tests.
2. Integrate the reviewed Coach copy repair and database-test corrections;
   keep the spatial handoff/private-data boundary intact.
3. Continue backend state-machine/deletion/spend and anonymous/team regression.
   Existing TENANCY-AUDIT findings remain open;526 unit tests do not close them.
4. Resolve durable upload/approval/tenancy contracts before claiming a complete
   web UI. No real-browser create→edit→review→publish→two-links walk has occurred.
5. Keep this checkpoint and per-lane reports current and push unit branches
   without force-pushing or changing the pending Apple submission.
