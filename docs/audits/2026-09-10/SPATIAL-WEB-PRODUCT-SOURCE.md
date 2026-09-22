# Spatial web viewer — source implementation and verification

Observed 2026-09-11 16:10 UTC. Worktree `room-proof-next-block-20260910`, branch `feat/spatial-product-20260911`; base HEAD at this observation `cc9069a3be34e5fc4fbb99a8f7232b80d6f6d2cb`. The viewer changes were uncommitted when tested. Parent integration must bind the final commit separately. No deploy, TestFlight upload, Apple action, GPU rental or customer-media upload was performed by this work unit.

## What is built

- `services/edge/tour-host/src/spatial.ts`: inert `/s/:id` shell, no-store same-origin manifest/model proxy, bounded reads, cancellation, explicit errors, fixed upstream path, no redirects. Shell removes `#access` before loading the engine. Capability stays in memory and is sent only as an Authorization header to the scene endpoints.
- `src/spatial-manifest.ts`: the same bounded decoder runs in the Worker and is emitted into the browser module. No arbitrary model URL, storage key, original capture sidecar or credential is forwarded. Scene/revision UUIDs, bytes, hash, count, bounds, floor provenance and room poses are checked.
- `src/spatial-sog.ts`: pre-GPU stored-ZIP SOG-v2 admission. Encoded file <=32 MiB, <=500,000 splats, <=8 members, bounded metadata, internal texture references only, no deflate/ZIP64/duplicate entries, lossless single-chunk VP8L textures <=2048 pixels per dimension and <=8 Mi aggregate texture pixels. This bounds input envelopes; it is not a total browser/GPU resident-memory guarantee.
- `src/spatial-runtime.ts`: lazy PlayCanvas 2.22.1 with SHA-384 integrity pin; actual Gaussian splat decoding/rendering; fixed-height joystick/pointer/keyboard navigation; drag-to-look; reset; room anchors; top-down view that fits portrait bounds; explicit loading/access/integrity/decode/context-loss errors; accessible 44px controls, focus handling, Escape and tab containment; complete graphics/event/observer teardown.
- `src/player.ts` and `src/types.ts`: optional `Chapter.spatial_anchor = {scene_id, room_id}` and room entry buttons. Existing no-scan tours have no new entry. Video/HLS is detached/destroyed before opening WebGL and restored with time, scroll and focus on exit. Rapid reopening cancels stale metadata resume handlers. Unbranded source gate still passes.
- `scripts/check-spatial.mjs`, `scripts/check-spatial-browser.mjs`, `scripts/preview-spatial.mjs`: direct unit/adversarial checks and isolated real-browser verification using explicitly synthetic fixtures. `npm test` includes the new direct checks.

## Shared service contract

The backend owns authorization and privacy authority, not the browser. The iOS DTO returns `/s/:id#access=<15-minute capability>`. The hosted viewer fetches `/s/:id/manifest` and `/s/:id/model?revision=<artifact_revision>`, which proxy to `/spatial/:id/{manifest,model}`. The backend rechecks live membership, scene status and immutable artifact revision for each read. No capability means only a currently published, reviewed artifact is eligible. The Worker additionally rejects public manifests without `privacy_reviewed=true`.

Manifest fields:

```text
schema_version: 1
scene_id, artifact_revision: UUID
format: sog
bytes: integer 1..33554432
sha256: 64 lowercase hex characters
gaussian_count: integer 1..500000
bounds: {min: [x,y,z], max: [x,y,z]}
floor_y, eye_height
floor_source: capture_estimate | roomplan
navigation_bounds_source: capture_estimate
initial_camera: {position: [x,y,z], target: [x,y,z]}
rooms: [{id, label, position: [x,y,z], target: [x,y,z]}] (max 32)
provenance: captured | synthetic
privacy_reviewed: boolean
```

Positions are ARKit world coordinates, Y-up, with an identity splat entity. The pinned splat-transform 3.4.2 reader and SOG writer both use `Transform.PLY` internally; a plain PLY→SOG conversion without an extra `--rotate` preserves raw coordinates. PlayCanvas's SOG importer does not add a compensating 180-degree entity rotation. This is pinned-code inspection plus synthetic rendering, not a measured real-room orientation test.

Backend late binding attaches anchors to uniquely matching normalized room labels at tour read time. That permits a reviewed scan to appear on an already-published flythrough without re-rendering its video. Ambiguous labels should remain unbound. See the backend source report for its separate verification.

## Actual results

Commands run from `services/edge/tour-host` unless noted:

| Command | Observed result |
| --- | --- |
| `node node_modules/typescript/bin/tsc --noEmit` | Exit 0, with current Workers types 5.20260911.1. Reused existing TypeScript dependency via ignored local symlink; not a clean-install proof. |
| `npm test` | Exit 0: 557 unbranded + 584 routes + 707 upstream + 418 lead-form + 57 legal + 103 spatial = **2,426 assertions**, plus 12 existing gate self-tests. |
| `node scripts/check-spatial.mjs --negative-control` | Exit 1 as required: oversized manifest is deliberately submitted as acceptable and rejected. |
| `node scripts/check-spatial-browser.mjs <bundled-playwright-index.mjs>` | Exit 0: **62 actual headless Chromium assertions**. Actual nonempty WebGL instanced draw, navigation, portrait layout, artifact failures, private-fragment handling, context-loss teardown and real MP4 detach/resume. |
| `git diff --check -- services/edge/tour-host` | Exit 0. |

Browser input was `/tmp/rendprop-spatial-viewer.dCoSW8/SYNTHETIC-NOT-A-ROOM.sog` (2,048 colored synthetic splats), not a captured room. The video was `/tmp/rendprop-spatial-browser.C67PoS/SYNTHETIC-NOT-A-TOUR.mp4`, an eight-second generated test pattern. Preview bound only `127.0.0.1:8794`, served the actual Worker/player source and stubbed only the synthetic backend host. The same pinned engine bytes were served locally with the same SRI; CDN availability was not tested by that run.

Exact reproduction using existing local fixtures/dependencies:

```sh
node scripts/preview-spatial.mjs \
  /tmp/rendprop-spatial-viewer.dCoSW8/SYNTHETIC-NOT-A-ROOM.sog \
  '/Users/pilksclaes/Rendprop AI/spatial-phase-a/tools/spatial-spike/viewer/node_modules/playcanvas/build/playcanvas.min.js' \
  /tmp/rendprop-spatial-browser.C67PoS/SYNTHETIC-NOT-A-TOUR.mp4
# In a second terminal:
node scripts/check-spatial-browser.mjs \
  /Users/pilksclaes/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright/index.mjs
```

Logs: `/tmp/rendprop-spatial-product-host-final.log`, `/tmp/rendprop-spatial-product-browser.log`, `/tmp/rendprop-spatial-product-negative.log`. Browser screenshot `/tmp/rendprop-spatial-product-mobile.png` was visually inspected: synthetic colored splats and purple controls are visible. Temporary files are not durable receipts and contain no real room media.

If temporary fixtures are gone, `tools/spatial-spike/viewer/make-synthetic-fixture.mjs` and that directory's README document rebuilding the labelled 2,048-splat sphere with pinned `splat-transform` on CPU. A new labelled video fixture can be generated with `ffmpeg -f lavfi -i testsrc2=size=320x180:rate=15 -t 8 -an -c:v libx264 -pix_fmt yuv420p -movflags +faststart <new-private-directory>/SYNTHETIC-NOT-A-TOUR.mp4`. These are regeneration instructions, not a claim that a new conversion was run in this unit. Do not substitute a real customer's scan into a synthetic fixture path.

An earlier expanded browser run failed waiting for private-preview text because the harness navigated only to a different URL fragment on the same document. The harness was corrected to navigate through `about:blank`; the final full run above passed. This earlier failed test is not presented as a product pass. Native-browser automation was unavailable; no system permissions were changed. Tests used an isolated headless browser, not the user's existing tabs.

## What this does not prove or finish

1. **Not deployed, not in TestFlight.** This source does not change build 18 already installed on the phone. Parent must finish backend/worker integration and deployment gates before claiming an end-to-end phone test is available.
2. **No trained user room was rendered.** The prior GPU sandbox was terminated by the provider's billing-cycle spend limit; its final state is documented separately. Synthetic success is not reconstruction quality, correct scale/orientation, held-out fidelity or camera hardware proof.
3. **No iPhone Safari/WebKit performance or memory proof.** The test browser is Chromium. Actual iPhone 15 Pro remains the acceptance device. No simulator camera test was attempted.
4. **Top-down is not a geometry-cutaway dollhouse.** It is an overhead orthographic view. Navigation bounds are estimates, not wall collision. There is no raycast measurement feature; the UI says so.
5. **Actual region redaction processing remains a backend pipeline gate.** This viewer never publicly serves an original and pretends CSS blur is protection. Requested redactions must prevent publication until a processed immutable artifact exists. Explicit no-redaction-needed review is a separate backend path.
6. **MP4 restoration was tested; real HLS restoration was not.** Source tears down hls.js and guards delayed attachment while spatial view is open, but a real HLS/MSE network stream was not exercised here.
7. **Provider, secret, deployed RLS, lifecycle and cron settings are not verified by these tests.** The stubbed backend harness proves local contracts/behavior, not a deployed production database or storage state.
8. **This is one scene at a time, not a multi-floor editing product.** Multi-room anchors are supported within a manifest; multi-floor reconstruction, redaction editing and true collision/measurement tools require additional units.

## Source hashes at verification

```text
750e13483bd08c541c969a103dd663bc3c9368ed438fbc204d513419613c3c93  src/spatial-manifest.ts
26076ad01b69455344126418360608bba4a5e60b15c9829eb391032e248e7cb7  src/spatial-runtime.ts
f4a75590d0dbb3020a3a988161677a4005971b3604dff8a7169dfd794de054ae  src/spatial-sog.ts
160a18439c61023ed590f83422a66c0b7d571e2acd62bbcf0e4fda533c5ee5cf  src/spatial.ts
c0d54953b2ccecd06bf523a3c8b185a252ec60e9ed3d57b3634f9e683af5b39e  scripts/check-spatial-browser.mjs
eda241ca66c54b587554bce5304ff72b5f1754104b6ef88ea13fbfaf7e85e4c7  scripts/check-spatial.mjs
10e19093f4dc898a44b0ff8a013fd1ef125d908718358832bbc864e69c2f1165  src/player.ts
```

## Independent cross-layer review — findings at 16:20 UTC

This was a subsequent read-only review of the concurrently implemented backend, controller and iOS source. These findings were sent to the owning agents; they are **not marked fixed by this report**. Line references describe the source as inspected, before any follow-up integration edits.

### 1. P1 — Abandoned uploads permanently consume all three room slots

Evidence: `services/supabase/migrations/0040_spatial_jobs.sql:116` counts `uploading`, `queued`, and `processing` jobs against the organization limit. `spatial_expire` at lines 207–208 only expires `processing` jobs. `services/supabase/functions/spatial/index.ts:449` through the action dispatch at 474 offers inputs/start/review/publish, but no cancel/abandon operation.

Reproduction: create three valid capture jobs, stop before attaching/starting them, then remove the local capture or reinstall the app. A fourth create receives 429 indefinitely. No GPU or production request was run to reproduce; this follows directly from the SQL transitions. Add an explicit authorized cancellation and/or bounded uploading expiry that releases the active slot and journals input cleanup. Do not interpret cancellation as authorization for an automatic second paid attempt.

Related recovery gap: `unique(listing_id,capture_id)` at migration line 35 and create replay at 110–114 return the old failed row for the same saved capture; `spatial_start` line 169 refuses failed jobs. The current iOS failure message at `apps/ios/Rendprop/Screens/SpatialTourView.swift:173` says to refresh for recovery, but there is no retry transition. A provider failure should not force the customer to physically rescan just to obtain a new capture ID. An explicit, separately budgeted retry must be fenced from any still-live previous attempt.

### 2. P1 — Backend can mark a scene complete that the viewer rejects

Evidence: backend `services/supabase/functions/spatial/contract.ts:188`–200 permits floors below bounds if eye height is inside, and permits any nonzero target distance. Lines 215–217 allow room IDs up to 80 characters and labels with control characters. Web `services/edge/tour-host/src/spatial-manifest.ts:38` bounds vectors, lines 45–50 require target distance >=.01 and floor within bounds, and lines 61–62 cap room IDs at 64 and reject control characters. Backend room creation at `spatial/index.ts:410`–422 accepts internal newlines in a room label, which the worker preserves in `services/spatial-worker/modal_provider.py:33`.

An actual `deno eval --no-check` imported **both current functions**, applied four changes to an otherwise valid captured manifest, asserted backend acceptance and viewer rejection, and exited 0 with:

```text
control-character-label: backend accepted, actual viewer rejected
65-char-room-id: backend accepted, actual viewer rejected
sub-centimetre-target: backend accepted, actual viewer rejected
floor-below-bounds: backend accepted, actual viewer rejected
```

The concrete mutations were `rooms[0].label="Kitchen\nprivate"`, `rooms[0].id="x".repeat(65)`, initial position `[0,0,3]` with target `[0,0,3.001]`, and `floor_y=-2.1` with `bounds.min[1]=-2` and `eye_height=1.6`. Fix by aligning server admission with the exact viewer schema and adding shared parity fixtures, not by weakening the viewer to accept invalid geometry.

The model itself is only length/hash-bound on the backend (`spatial/index.ts:250`–270); completion validates the manifest and HEAD metadata (`362`–367), not the SOG envelope. The controller copies the converter output after size/count checks (`modal_provider.py:108`–120). A corrupt or unsupported but correctly hashed output can therefore be persisted as review-ready and then fail the browser's pre-GPU SOG check. Run the same bounded format admission before completion, and prove it with the actual converter output. This is a correctness gap, not a claim that an ordinary client can invoke the worker-only completion route.

### 3. P1 — Privacy review's preview gate does not prove the scene loaded

Evidence: `apps/ios/Rendprop/Screens/SpatialTourView.swift:333`–337 sets `openedRevision` immediately after retrieving the job DTO and URL. The checkbox/publish button gate at 299–307 trusts that value. Submission at 346–352 sends `approved=true` and empty redactions.

Reproduction: fetch the DTO, then make the engine/model fail (expired access, CDN failure, unsupported graphics), dismiss the preview error, check the attestation and publish. The UI currently permits it although no room rendered. Add a hosted-viewer ready callback carrying the exact scene and artifact revision; enable the attestation only after the verified model actually starts rendering. The web `.loaded` promise currently resolves after handled errors too, so promise settlement alone is not proof; use verified `ready` state/event. This remains a human privacy attestation, not an automated guarantee that every sensitive object was noticed.

### 4. P1 — Cloud provider/cleanup receipt disappears after the controller exits

Evidence: `services/spatial-worker/worker.py:320`–321 wraps execution in `TemporaryDirectory`; `modal_provider.py:46`–65 writes sandbox identity into a receipt beneath it; cleanup state is saved there at 139–160. `0040_spatial_jobs.sql:24`–33 stores worker/lease identity but no provider sandbox ID or cleanup result.

Reproduction: force sandbox directory removal or terminate/poll to fail. The job reports a failure code, then the controller's temporary directory is removed, discarding the sandbox identity and detailed cleanup receipt required for a later sweep. The provider TTL still bounds runtime; this is not evidence that a sandbox is currently live. Persist the scoped provider-attempt identity and cleanup/reconciliation state in the control plane before media transfer, and retain it through terminal failures. The same requirement applies when CREATE returned an ambiguous response.

### 5. P2 — Runtime lifetime configuration admits values the provider cannot execute

Evidence: `0040_spatial_jobs.sql:9` permits `max_seconds` as low as 60. `services/spatial-worker/modal_provider.py:58` requires at least 2,400 seconds still remaining before allocation. With `max_seconds=600`, a queued job reserves its full cost ceiling, is claimed, and deterministically fails `insufficient_job_lifetime` without reconstruction. Default 7,200 is compatible. Make configuration admission agree with the actual setup/training/conversion deadline model and distinguish a pre-allocation failure from an invoice-backed cost.

### Feature/deployment gates, not claimed hidden defects

- **Region redaction is not implemented end-to-end.** iOS only offers keep-private/whole-room exclusion (`SpatialTourView.swift:302`–311) and always submits `redactions: []` (347). The SQL correctly refuses publication with nonempty redaction requests (`0040:303`–318). This is fail-closed but does not satisfy the full requested region-editing product.
- **Cloud bootstrap has not been reproduced.** `services/spatial-worker/app.py:14`–26 defines the controller image/source inventory; `setup_service.sh:4` invokes the inherited CUDA setup and installs the pinned converter. `tools/spatial-spike/training/modal_setup.sh:20` still resolves floating transitive Python requirements and `ninja`, and apt packages are unpinned. The README at `services/spatial-worker/README.md:80`–86 acknowledges this. Importing the Modal application and mocking provider calls do not prove a successful image build or CUDA run.
- **Operational settings remain manual gates.** No provider account spending limit, deployment, outer JWT gateway, secret, R2 lifecycle, cleanup cron or live database configuration was changed or verified in this review. The scheduler's explicit enable flag and disabled/zero-budget database defaults are deliberate release controls, not bugs to bypass.

### Properties independently confirmed in code

- Viewer MACs bind scene, revision and actor, expire within 15 minutes and use HMAC verification (`spatial/capability.ts:53`–85). Each private artifact request rechecks workspace access (`spatial/index.ts:153`–161; migration `spatial_access` at 85–94).
- Public artifact access checks current ready/approved/not-excluded/published status, exact review revision and empty redactions, then a live listing and organization (`spatial/index.ts:163`–185). Re-review/exclusion resets publication in the same SQL update (`0040:305`–307). Already downloaded scene bytes cannot be retroactively unseen; no contrary claim is made.
- Scene output is an immutable revision key, service-written with If-None-Match and bound hash/length (`spatial/storage.ts:61`–73); model GET uses the stored ETag (`94`–103). No client-selected original URL is used.
- Spatial input photos use private `role:"capture"` from `SpatialUploadCoordinator.swift:227`–229. The public tour gallery filters the public renders bucket and gallery key prefix (`tours/index.ts:125`–131), so it does not automatically expose raw scan frames.
- The pose adapter flips camera convention, not world axes (`prepare_capture.py:104`–109); trainer explicitly disables world normalization and pose optimization (`run_training.py:24`). Provider starts the viewer along the camera's projected negative-Z direction with Y-up (`modal_provider.py:12`–33). No contradictory world rotation was found, but actual asymmetric real-room orientation remains a required runtime proof.

## Follow-up fixes and fresh verification

The findings above are historical observations, not an assertion that concurrent fixes remain absent. After root authorized the follow-up:

- **Rendered-preview signal implemented in web source.** The viewer emits `window.webkit?.messageHandlers?.spatialViewer?.postMessage({type:'spatial-ready', scene_id, artifact_revision})` only after its own WebGL context submits a nonzero instanced splat draw to the default framebuffer and PlayCanvas completes `postrender` without context loss. It temporarily observes only that context's draw calls, then restores them; it does not use global hooks, `readPixels` or private engine counters. The 90-second loading deadline now also covers waiting for that first rendered frame. Native iOS must separately validate exact scene/revision, main frame and expected HTTPS origin before unlocking attestation. The iOS agent owns that receiving-side implementation and tests; this web report does not claim their result.
- **Actual browser verification increased to 69 assertions**, exit 0. The model response was deliberately held; no ready message occurred before model transfer. A valid scene emitted one event with the exact scene and revision after an actual nonzero draw. Public-private mismatch, short transfer, bad hash and bad SOG count emitted zero events. Existing movement/layout/context-loss/video restoration checks also passed.
- **Targeted fault injection passed as a negative control:** `node scripts/check-spatial-browser.mjs <playwright-index.mjs> --negative-control` injects a premature message into the actual served runtime. Exit 1 occurred at `AssertionError: no native ready message before model transfer`, not an unrelated browser launch failure. Logs: `/tmp/rendprop-spatial-ready-browser.log`, `/tmp/rendprop-spatial-ready-negative.log`.
- **Whole host suite rerun:** `npm test`, exit 0, 2,426 assertions plus 12 gate self-tests. TypeScript exit 0. `git diff --check` exit 0. Log: `/tmp/rendprop-spatial-ready-host.log`.
- **The four backend/viewer schema mismatches were independently rechecked after the backend agent's edit.** Actual Deno imports now accept a valid shared manifest and reject all four malformed variants before completion: control-character label, 65-character room ID, sub-centimetre target and floor below bounds. This closes those specific source mismatches; it does not prove actual cloud converter output or deployed behavior. Cancellation/retry/provider-journal changes were being made by other agents and were not re-audited in this follow-up.

Updated SHA-256 for the bridge-tested files (supersedes their earlier hashes):

```text
51c435a8040f693de9863b5d5dac875d87234fb7521b91cc5edff6afe34acf1d  src/spatial-runtime.ts
9b2ddb3ee14c9826cb751b526eb1ed01d9d79bf174fb4185f6dffc3814f4de52  scripts/check-spatial-browser.mjs
```

No feature deployment, Apple action, provider allocation, customer-media transfer or Git commit was performed by this follow-up.
