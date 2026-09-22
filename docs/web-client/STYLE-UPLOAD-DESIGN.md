# Lane F: offline style policies and resumable-upload design

Date: 2026-09-10. Architecture proposal, not a live feature or completed quality evaluation.

## Scope and evidence

Read the entire attached brief, `docs/GPT-AGENT-BRIEF.md`, and all five September market documents before source inspection. Source root: `/Users/pilksclaes/Rendprop AI/spatial-testflight-20260910`. Initial HEAD was `db3c0f9afb6fe7d3d6735d92e379b335e26c2a65`; root subsequently advanced it to `f14081d49d5fb40b1dde59562176692ddb2664c6`. A path-limited `git diff --name-only` between those commits returned no changes to the backend, worker and iOS upload/composer files examined below. Anchors refer to that unchanged source.

No source edits, account access, uploads, provider calls, paid generation, migrations, installs, builds, Apple actions, or deployments. Supabase and Cloudflare skills informed database-authority and browser-storage checks, not any service mutation. Public documentation was checked on the date above. File paths below are relative to the source root unless linked explicitly.

## 1. Reuse map and consequential gaps

| Existing component | Reuse and limit |
|---|---|
| `services/supabase/functions/ai-video/motion.ts:59,126,216,444,578,612` | Eight closed motion enums; frozen `REEL_MOTION_TEXT`; strict parser; private room-ranked allowlists; deterministic selector; guarded prompt builder. Do not edit the motion text or introduce free-form camera instructions. |
| `services/supabase/functions/ai-copy/shotlist.ts:119,135,146,150,368,545,659` | Integer 2–12-second shots, maximum 20 shots, caption maximum 5 words/28 characters, room classifier, ordering/apportionment. These are planner limits, not a guarantee every provider supports every duration. |
| `services/supabase/functions/ai-copy/agentreel.ts:88,215,304,427` | Fixed phrase-boundary windows and server-selected motion; answer parsing cannot move windows or invent photo IDs. Preserve this EDL, rather than independently re-planning it in browser/iOS. |
| `apps/ios/Rendprop/Render/ReelComposer.swift:67,248` | Consumes finished MP4 `Shot`s with seconds, speed and caption. Supports cut/dissolve/whip and off/lowerThird/punchCard/highlightBox caption treatments. It is not an agent-EDL executor; no music-beat or color-grade interface is present. |
| `services/supabase/functions/_shared/router.ts:258,293,342`; `_shared/providers/chain.ts:39` | Existing task routing, capabilities, plan/privacy ordering and failover. Style must not select a provider, enable a route or bypass the existing chain. Legacy fallback exists; do not infer all DB-route safeguards apply to every fallback. |
| `services/supabase/functions/_shared/ledger.ts:293`; `ai-copy/index.ts:847` | Add future style snapshot identity to existing cost metadata; do not create a second ledger. Success-cost recording is best effort and not a pre-spend reservation. |

The room-veto contract is currently fragmented. `ai-video/index.ts:1474` accepts an explicit valid motion enum without checking the room table. Automatic selection at 1479 does use it. `shotlist.ts:531,545` can choose a closing `pull_back` regardless of room and ultimately fall back across the full vocabulary. `agentreel.ts:278` uses another, eleven-class preference table, whereas `motion.ts:270` has sixteen room enums. Do not map coarse `entry` back into `hall` or `stairs`, or coarse `detail` back into `view`, without preserving the original room hint.

A read-only synthetic probe confirms two bathroom photos produce `tilt_down`, then `pull_back`; `motion.ts:481` excludes bathroom `pull_back` and both orbits. The enum parser separately accepts `orbit_left`. The latter is expected for an enum parser, but insufficient as the complete route safety gate. Also, unknown-room `NEUTRAL_MOVES` includes orbits; the comment that it is safe for every interior is not evidence of geometry preservation.

## 2. Minimal executable offline foundation

Proposed new modules: `services/supabase/functions/_shared/styles/{catalog,policy,compile,experiment}.ts`, with adjacent pure tests. These are suggested locations, not implemented files. Imports may reach pure motion/shotlist/agentreel constants, never serving `index.ts`, router, credentials, provider SDKs or database clients. Begin with a checked-in catalog, not a migration or admin screen.

### Versioned policy contract

Use a strict JSON schema with unknown-key rejection, deep immutable validated objects, no coercion, and stable canonical serialization. Separate a policy payload from its digest to avoid a self-referential hash. Bound catalog to 64 policies, IDs to lowercase ASCII slugs of 1–64 characters, versions to positive safe integers at most 1,000,000, descriptions to 500 characters, provenance entries to 16, and each motion ranking to distinct members of the existing eight-element enum. Reject booleans as numbers, NaN/infinities, missing required fields, duplicate `(id,version)` pairs, conflicting digests and executable/free-form prompt fields.

```ts
type StyleRef = { id: string; version: number; sha256: string };
type StylePolicyV1 = {
  schema_version: 1;
  id: string; version: number;
  status: "draft" | "approved" | "retired";
  grammar_version: "reel-motion-v1";
  planner_version: "existing-shotlist-and-agentreel-v1";
  photo_sequence: {
    timing: "preserve-planner";
    motion_rank: readonly ReelMotion[];
  };
  recorded_agent: { edl: "preserve-exact"; original_audio: "preserve" };
  presentation: {
    transition: "cut" | "dissolve";
    caption: "lowerThird" | "highlightBox";
    music: "none";
    grade: "identity";
  };
  intent: { opening_three_seconds: string; pacing: string };
  provenance: {
    basis: "generic-editorial-conventions";
    source_refs: readonly string[];
    copied_assets: false;
    review_status: "pending" | "reviewed";
  };
};
```

`intent` is explicitly non-executable documentation. It must never become a hidden prompt suffix. There is no duration override, beat grid, palette/LUT, music URL, arbitrary transition duration or face-lead adjustment in this first contract. Reject unsupported executable fields instead of accepting and silently ignoring them. A future implementation may widen the schema only through a new version and capability tests.

### Three generic seed policies

All begin as **drafts**, version 1, generic provenance with no copied template/music/assets and no creator impersonation. Neither a famous creator's name nor a scraped reel is a style ID. No actual creator footage was evaluated in this lane.

| ID | Presentation | Photo-sequence preference, before constraints | Intent only |
|---|---|---|---|
| `clear-tour` | cut, lowerThird | push_in, static_parallax, tilt_down, tilt_up, rack_focus, pull_back | Plain room hierarchy; immediately identifiable property context. |
| `editorial-calm` | dissolve, lowerThird | static_parallax, push_in, rack_focus, tilt_down, tilt_up, pull_back | Visually calm transitions and readable information. |
| `concise-highlights` | cut, highlightBox | tilt_down, push_in, static_parallax, rack_focus, tilt_up, pull_back | Clear emphasis on the current room's visible feature. |

All preserve planner timing and recorded-agent EDL exactly; music is none, grade identity. Thus `concise-highlights` does **not** currently mean faster clips, and `editorial-calm` does **not** currently mean slower speech or a changed hold duration. The first-three-second intent cannot override the agent's two-second face lead. The current caption ceiling remains 5 words/28 characters. More ambitious policies remain ineligible until their executor exists; do not advertise unsupported effects as applied.

### Pure interfaces and capability semantics

```ts
validateCatalog(raw: unknown): ValidatedCatalog;
resolveStyle(request: StyleRef | null, catalog: ValidatedCatalog,
  context: { purpose: "offline"; mode: "photo_sequence" | "recorded_agent" }):
  LegacyDecision | SelectedDecision;
compileStyle(decision: SelectedDecision, input: ValidatedPlannerOutput,
  capability: PlannerCapability): OfflineStylePlan;
```

An omitted style resolves to `legacy`, not automatically to a seed. Unknown ID/version/digest fails explicitly; never silently use latest. Drafts can compile only for offline evaluation. Approval and rollout are separate future decisions. Resolver output includes the immutable style snapshot/digest, input digest, planner/grammar identity and constraint notes; it contains no route/provider override.

Initial `OfflineStylePlan` must say `stage: "offline-plan"`, `rendered: false`, `live_api_applied: false`, return an exact immutable copy of the input EDL, and put caption/transition decisions in a separate presentation envelope. Do not mutate `photo_id`, timing, motion, caption content or original audio. Store source and output EDL canonical hashes; require equality. Motion ranking can be validated as vocabulary but is **not applied** in this first compiler. Report `motion_policy_stage: "deferred-room-contract"` and `room_safety: "unverified"`, not a fabricated changed-motion or safety-approved plan. Once an authoritative room-safety accessor is available, an input EDL that violates it must fail compilation; preserving legacy bytes must not become permission to label an unsafe plan approved.

### Safe motion application requires an explicit follow-up

Do not duplicate `ROOM_MOVES` or reverse-engineer it by sampling the selector. The narrow prerequisite is an approved read-only `allowedReelMotions(room)` accessor from the same private table, with a frozen snapshot/parity test; this need not change `REEL_MOTION_TEXT` or routing. No live accessor or route fix is delivered here.

A later photo-sequence compiler intersects style preferences with the authoritative room list, scene restrictions and executor capability **after every selection/override**. A style preference is soft; vetoes are hard. If empty, select an explicitly approved safe fallback from the permitted set, record the substitution, or fail—never fall back to the global enum. Avoid repeated motion families only within that permitted set; repetition is preferable to violating geometry restrictions. For unknown/ambiguous rooms, propose a new conservative opt-in policy restricted to `push_in`/`static_parallax`, without changing legacy behavior. Those remain generative moves, not physically measured motion or a hallucination guarantee.

For recorded-agent mode, even that future motion selector must not replace existing EDL fields without a separately versioned planner decision. Agent limits remain: clip 6–180 seconds, face lead 2.0, face tail 1.5, face gap at least 1.2, B-roll window 1.6–3.5, total B-roll at most 55%, at most 12 windows, transcript at most 200 phrases. The current cleanup rounds timestamps to tenths; two distinct raw boundaries can collide after rounding, so add an explicit rounded-boundary regression instead of assuming raw monotonicity suffices.

Before future live wiring, apply input/output fair-housing gates on the server (`ai-copy/index.ts:787` and guarded copy), enforce organization authority, then attach policy identity to existing job/ledger metadata. Existing `enhancements.style` concerns another feature: use an unambiguous new `edit_policy` field, not that overloaded name. A style must not relax provider privacy, budget, membership, or disclosure rules. Published output must retain whether source footage was recorded versus generated; a style label is not such provenance.

## 3. Offline tests and honest A/B protocol

**Compile tests first.** Exhaustively cover all 16 room enums plus null, all 8 motion enums, all 3 policies and all 4 previous-motion families plus no previous family: 2,040 combinations for a future selector. Pin full motion-text content and `buildReelPrompt()` baseline bytes. Test unknown/prototype-like keys, malformed versions/digests, duplicate ranks, nonfinite values, oversized catalogs, mutation attempts and hash stability. For the initial immutable compiler, prove exact EDL equality and explicit non-application of unsupported motion/music/color/timing effects. Missing capability must be an error, not a successful render-shaped result.

Negative fixtures: bathroom explicit orbit; bathroom closer pull-back; hallway orbit; window-view orbit; exterior rack focus; unknown room containing prompt-like text; only-vetoed style ranking; alternating-family requirement with only one safe remaining choice; a six-second agent clip with no valid window; first window before 2 seconds; a 1.19-second face gap; 3.51-second cutaway; coverage above 55%; unknown/duplicate photo IDs; reordered/duplicate window IDs; all-empty matches; a blank-photo caption; timestamps that round to the same tenth; changed original audio; and a claimed effect without executor support. Some are intentionally adversarial inputs rejected by the new contract, not statements that every existing function already rejects them.

**Pre-register before generating or selecting outputs.** Suggested pilot: 24 listing packages, four each from six declared strata (tight rooms, reflective/window views, broad interiors, exterior transitions, clutter/detail, mixed/unknown labels). Predeclare exact fixture IDs/input hashes, rights, fixed eligibility/exclusion rules, one baseline snapshot, one candidate policy, planner/model/renderer versions, total duration and crop. There are 48 variant outputs and 72 paired judgments from three independent raters. This is a small exploratory pilot, not powered proof of market superiority. Initially use owned synthetic or already-cleared local media only; source-code fixtures cannot stand in for perceptual media.

Use deterministic seeded A/B assignment, counterbalance left/right per listing/rater, opaque file IDs and an evaluator bundle without style/provider names. Keep the mapping separate and hash its commitment before scoring. Hide codec/container metadata that could reveal variants in the review interface; do not claim blinding to visible stylistic differences. Require all raters to score before unblinding. Repeated fixtures, missing assets/ratings, invalid IDs, changed manifests or substituted outputs fail the protocol.

Rubric (1–5, equal weight unless predeclared otherwise): property fidelity, speech/visual match, pacing/coherence, caption legibility, first-three-second clarity, temporal stability. Add independent binary critical defects for invented/removed property facts, material geometry errors, privacy leakage, fair-housing violation and original-audio/timeline alteration. Any new critical defect blocks advancement regardless of preference. Proposed pilot decision: candidate preferred on at least 18/24 listings by majority of three raters, no new critical defect, and no lower median property-fidelity score. Ties do not count as wins. Report paired differences and all failures; do not stop early or test many styles and publish only the winner. These are proposed acceptance thresholds, not measured outcomes or population claims.

If the candidate compiles to the same executable output as baseline, report “no treatment contrast” and stop; do not manufacture an A/B win from renamed identical clips. Offline compilation and existing rendered-media review can happen without paid generation. New generated variants require a separately authorized, predeclared spend ceiling and provider/rights review. Cost ledger rows after a successful call do not enforce that ceiling.

Proposed harness subcommands: `validate`, `pair`, `score`, `summarize`; all operate on local manifest data, have no generation entry point, and reject unknown arguments. Run with network/environment/process permissions denied. Add an intentional malformed-manifest control that must exit 1 before the valid fixture run exits 0. Emit planned/rendered/rated counts separately. No new style harness is implemented or claimed tested here.

## 4. Two-gigabyte upload: extend the existing mechanism

The correct transport is already present: `services/supabase/functions/uploads/index.ts`, `_shared/r2.ts`, and the iOS `UploadManager`, `UploadStore`, `DirectUploader`. Do not add a second storage system merely to obtain a resumable-upload library.

Current code accepts video up to **12 GiB**, photo up to **50 MiB**, poster up to **10 MiB**; maximum **200** photos per batch and **256** requested part URLs per call (`uploads/index.ts:176–200`). Video uses multipart when explicitly requested or **strictly greater than** 64 MiB (`:782`), not at equality. `choosePartSize` (`_shared/r2.ts:242`) starts at 32 MiB. Thus **2 GiB = 64 parts**; decimal **2 GB = 60 parts**. The iOS engine has three concurrent transfers, i.e. potentially 96 MiB of part slices in addition to the source file. These are arithmetic/source observations, not a measured network benchmark.

Direct R2 part URLs expire after one hour; staging PUT URLs after 900 seconds. R2's documented bounds are 5 MiB minimum except the final part, 5 GiB maximum per part and 10,000 parts; unfinished multipart uploads default to expiration after seven days, configurable by lifecycle. This project's deployed lifecycle was not inspected. A multipart ETag is not a whole-file SHA-256. [Cloudflare multipart documentation](https://developers.cloudflare.com/r2/objects/upload-objects/)

### Blocking gaps for a reliable browser promise

1. **Local journal loss.** `UploadStore.swift:19–38` silently drops failed persistence and conflates absent/corrupt loads. `UploadManager.swift:608` reconciles background tasks and its local receipts, not server/R2 parts. There is no `ListParts`/session-status recovery endpoint in the inspected uploads/R2 files. Browser IndexedDB needs explicit persistence/error handling, plus server receipts for recovery after local loss.
2. **Weak upload identity.** `UploadManager.swift:691` derives ticket identity from path and size; source SHA-256 is asynchronous and can be absent. `uploads/index.ts:940` compares size/kind/bucket/MIME, not content; an idempotency mismatch releases the old key at `:1012`. Same-path/same-size replacement must not merge two files' parts.
3. **Incomplete verification.** Completion checks full part numbering and HEAD size/content type (`uploads/index.ts:458–631`), with useful replay/reassembly recovery. A client-declared SHA is not server-verified payload identity or successful video decode. Separate `uploaded` from `verified-media` before downstream paid processing.
4. **Retry and foreground assumptions.** Parts retry five times after an initial attempt; network restoration resets retry counts and some URL-fetch failures loop on a five-second timer (`UploadManager.swift:660,1006,1038`). Add a total deadline and classified failure budget. `NWPathMonitor` connectivity is not evidence a hotel captive portal permits R2. Foreground photo batches (`:1140`) are not a durable 400-photo queue. A malformed single-PUT response can fall into simulation (`:744`); the browser's live contract must fail closed instead.
5. **Browser-specific access.** Configure exact authorized web origins and expose `ETag`; URL validity alone does not satisfy CORS. R2 documents that expired presigned responses omit CORS headers, so JS may see a network error rather than readable 403 details. Refresh just before expiry, and never interpret every opaque error as permission to retry forever. [Cloudflare CORS documentation](https://developers.cloudflare.com/r2/buckets/cors/)

Do not promise uploading continues after every tab/browser shutdown. Background Fetch is limited/experimental and documented principally for downloads; Background Sync is not a long-running-transfer guarantee. Promise durable recovery when the app reopens, with file re-selection where required. [MDN background-transfer constraints](https://developer.mozilla.org/en-US/docs/Web/API/Background_Fetch_API)

### Proposed same-backend versioned interfaces

Add a versioned status/reconcile operation to existing `/uploads`, backed by authenticated asset access and R2 `ListParts`, not arbitrary bucket/key input. Return server asset/session ID, immutable file fingerprint, part size/count, persisted/remote receipts, state, generation and absolute expiry. Paginate receipts; validate returned count/part sizes. Keep `/part-urls`, `/complete`, `/abort`; enforce role/tenant access on every operation using the existing asset gate (`uploads/index.ts:167`). No browser service-role key. New durable rows need explicit grants/RLS and cross-tenant tests; documentation alone does not prove deployed policies. [Supabase security configuration](https://supabase.com/docs/guides/security/product-security)

Persist a random operation ID **before** requesting a ticket. Bind it to org/listing, asset role, byte count, MIME and a verified local streaming-content fingerprint; for a changed immutable request return 409 rather than silently reusing it. Version this behavior for existing clients. Store part receipts, not long-lived signed URLs. Use bounded `Blob.slice` transfers, not a 2 GiB `arrayBuffer` or duplicated full-file IndexedDB cache. A restored File handle requires available permission; fallback is explicit re-selection and fingerprint comparison. Do not auto-resume merely because name/size match.

State machine: `selected → fingerprinting → ticketed → transferring → verifying → ready`, with `paused`, `source-needed`, `permission-lost`, `expired` and terminal `failed` states. Display confirmed bytes separately from current in-flight bytes. Auth refresh is the existing session mechanism; a revoked organization role is terminal, not an anonymous/new-workspace retry. Two tabs/devices need an upload generation/CAS rule so a stale completion cannot commit a superseded session. Proposed 72-hour session ceiling is a product choice requiring confirmation against actual lifecycle—not a current deployed promise. Do not automatically purchase/render on upload completion.

### Jobs and finalization

Reuse `/renders` and `create_render_job` (`services/supabase/migrations/0015_job_lease.sql:93`): it verifies uploaded asset ownership and serializes org quota decisions. Current idempotent replay matches listing/key, not complete request equivalence. Add immutable input/EDL/style fingerprints and mismatch rejection in a versioned contract.

`services/worker/db.py:165` defaults to a 600-second lease, 60-second heartbeat and three attempts; actual configured values are unverified. Progress/finish are ownership guarded (`:432,459`), but `_replace_render_for_job` (`:611`) patches by job ID without the lease owner. Worker upload/ownership checks and insert are separate operations. Design atomic lease-generation-fenced finalization; testing a check immediately before write is not proof against a reclaimed-worker race. Detecting absent lease columns currently falls back to legacy operation, so deployment readiness must verify the schema rather than assume it.

Byte-identical publishing across browser/iOS/worker requires sharing one canonical final artifact or a deliberately pinned single final renderer. Separate client encoders cannot be called byte-identical merely because they share an EDL. Preserve current app-publish versus worker-render distinction until that architecture is decided.

### Specific upload fault fixtures, without allocating 2 GiB

Use a lazy synthetic range source that reports 2 GiB but generates only the requested bounded chunk. Assert 64 exact 32-MiB ranges, unique coverage, no overlap and exact total; test decimal 2 GB separately. Inject disconnect mid-part, receipt lost after successful PUT, browser restart, corrupt/quota-failed journal, missing source permission, same-name/same-size changed file, just-expired URL/CORS-opaque error, auth expiry, revoked role, tenant switch, duplicate/missing/forged ETags, concurrent tabs, complete response loss, object-assembled/database-patch failure, lifecycle expiry, 64-MiB threshold equality, final short reads and a stale worker finalizing after reclaim. Use local fakes, fixed clocks and deterministic retry injection; fail on any real service/provider invocation. A real multi-hour hotel-Wi-Fi transfer, browser matrix, codec verification, storage CORS and worker deployment remain unproved.

## Verification actually performed

Existing installed Deno `2.7.13`; no dependencies installed. Command from source root:

```sh
DENO_NO_PROMPT=1 deno test --cached-only --no-lock --node-modules-dir=manual --allow-read --deny-net services/supabase/functions/ai-video/motion_test.ts services/supabase/functions/ai-copy/shotlist_test.ts services/supabase/functions/ai-copy/agentreel_test.ts
```

Result: **106 passed, 0 failed, exit 0**. Full log: `/tmp/rendprop-style-upload-design.JEaRMU/existing-planner-tests.log`. The shell captured the actual command result and exited with it; it did not mask failure with `tail`.

Synthetic observation command:

```sh
DENO_NO_PROMPT=1 deno run --cached-only --no-lock --node-modules-dir=manual --deny-net /tmp/rendprop-style-upload-design.JEaRMU/contract-probe.ts
```

Result: exit 0; `/tmp/rendprop-style-upload-design.JEaRMU/contract-probe.log` records the bathroom mismatch described above. This is an observation, not a new passing safety validator. No style-catalog test suite, blind study, provider output, real 2-GiB upload or runtime RLS test was executed. Existing planner tests passing does not repair or cover the cross-module room-veto gap.
