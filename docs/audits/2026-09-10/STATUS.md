# Rendprop: active engineering and audit checkpoint

Updated 2026-09-10, evening Eastern. **Work in progress, not a whole-app GO.**
This file is the durable entry point for Claude and the parallel side chat.
Read the standing brief first; its production-data, provider, Apple and frozen
motion-prompt constraints remain in force. Never substitute an intended test
for an executed result. Every later checkpoint must preserve open findings.

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
| Worker/hosting lane | Agent reports 140 Python checks +10 new tests;557 unbranded +361 route assertions +12 self-tests | Root integration/review pending below; no deployment |
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

## Units awaiting root integration

- `b96896e` / `audit/ios-noncamera-ux-20260910`: consent tab-bar layout,
  accessibility IDs, strengthened ReviewerWalk, and full IOS-UX.md. Syntax
  parsed; new UI walk **not run yet**. Only the existing overlap is visually proven.
- `e388f01` / `audit/worker-host-20260910`: stale-job reaper snapshot fence;
  original6-test fixture failed4, patched6 pass. Verification prerequisites no
  longer report success with zero HDR assertions. Full WORKER-HOST.md includes
  still-open stale-publication, buffering and cache-revocation findings.
- `feat/spatial-local-handoff-20260910`: capture inspector, hash-bound private
  preparation and portable no-Xcode-build gate. Agent reports59 Python tests,
  21 viewer tests and native portable checks passed; changes awaiting review/commit.

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

1. Independently review/integrate the completed worker and consent units; run
   ReviewerWalk+Main only, with the new consent screenshots. No redundant camera tests.
2. Review/commit the spatial handoff unit and preserve its private-data boundary.
3. Continue backend state-machine/deletion/spend and anonymous/team regression.
   Existing TENANCY-AUDIT findings remain open;526 unit tests do not close them.
4. Resolve durable upload/approval/tenancy contracts before claiming a complete
   web UI. No real-browser create→edit→review→publish→two-links walk has occurred.
5. Keep this checkpoint and per-lane reports current and push unit branches
   without force-pushing or changing the pending Apple submission.
