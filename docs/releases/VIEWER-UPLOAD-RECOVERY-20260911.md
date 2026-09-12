# Viewer bundle and interrupted uploads — follow-up

September 11, 2026. Base commit `71f9eb77d866554d9902610f519ef0092cc019d4`.
Integration branch `fix/spatial-upload-release-recovery-20260911`.
**Viewer/upload source fixes implemented and locally verified, including the
full app and three non-camera UI walks. Not deployed, not a new TestFlight
build, not a whole-app GO.** Read the final checkpoint below before relying on
historical intermediate counts or failures in this chronological work log.

**Final checkpoint:** source `ce15713ecd741a7c53fe6c35140b12c293b09785` is
pushed. [Hosted CI34663756381](https://github.com/AaronPilk/RendProp-Ai/actions/runs/34663756381)
passed8/10 jobs, including the actual Worker bundle and all753 Edge tests.
The two red DB jobs retain one pre-existing agent-reel token-headroom finding;
neither a schema failure nor an upload-restart failure is being hidden.
The deployed viewer was still the broken bundle at00:55:22UTC. Use the narrow
rollout instructions below; this GitHub push is not a production/phone update.

## Independently established

At `2026-09-11T23:38:11.419Z`, root fetched the public asset
`https://rendprop.com/spatial-viewer.js` with TLS verification, redirects forbidden,
20-second request timeout and a 1MiB streaming limit. No credential, customer
record or room media was involved.

- HTTP200, JavaScript Content-Type, exactly26,442bytes.
- SHA256 `cfc2a3ed5da478101618382ca23bd7ec12cc2ff635011ddb09e9999822ea66a5`.
- A fresh Node `vm.SourceTextModule` evaluated the browser module successfully.
- Invoking `decodeSpatialManifest` under a1-second VM execution limit threw
  exactly `ReferenceError: __name is not defined`; the reproduction asserted
  the error name/message and exited0. This is an accepted reproduction of a
  failing live asset, **not a viewer acceptance pass**.
- An independent agent fetched the same byte count/hash at23:37:56UTC and
  reproduced the same error with a valid synthetic manifest fixture.

The bug crosses a build boundary: `spatialModule()` serializes decoder functions
with `.toString()`. Wrangler can inject helper references into those functions
without shipping the helper inside the browser string. Merely importing source,
parsing the returned JavaScript or getting HTTP200 does not execute those helpers.

## Correction to prior proof

The previous private real-room preview imported `spatialPage`, `spatialModule`,
the manifest decoder and SOG guard directly through Deno. It proved that the
source could render the actual room locally, with the listed fixture substitutions.
It did **not** execute the emitted Wrangler artifact. The earlier phrase
"Real production viewer" overstated that proof and is corrected in the older
report and STATUS. The native training renders were also blurry, independently
of this browser bug; fixing serialization cannot restore missing room detail.

## Current implementation ownership

1. `fix/spatial-built-viewer-20260911`: viewer build configuration and a gate
   that actually runs the emitted Worker, requests its browser asset, then
   executes the decoders/runtime. The old/broken configuration must fail.
2. Backend upload recovery: preserve the physical-transfer budget, completion
   winner, exact ticket ownership and one idempotent replacement for an explicit
   Restart. Do not reset counters or blindly redispatch an uncertain write.
3. iOS upload recovery: preserve local media and recovery intent, distinguish
   Retry from Restart, expose errors for photos/video/spatial, and stop new
   scheduling on Pause without cancelling writes already dispatched.

These are implementation goals until replaced with commands/results below.
Source fixes must be integrated and tested together; a new client must not be
distributed before the corresponding recovery route/migration is deployed.

## Viewer fix ready in source, still failing live

Unit commit `0d88415d4c3bda74daa98a7ec2175af512528d92` is integrated as16b219f
and pushed on `fix/spatial-upload-release-recovery-20260911`.
`services/edge/tour-host/wrangler.toml:6` sets `keep_names = false` with the
serialization rationale. The new `scripts/check-spatial-built.mjs` invokes
the installed, lockfile-pinned Wrangler's actual dry-run, evaluates that Worker,
requests its browser asset, then executes both emitted validators in a fresh VM
without adding the missing helper. `npm test`, `predeploy` and the existing CI
job all reach the gate. This is intentionally distinct from WebGL acceptance.

Root ran `npm run predeploy` after integration:exit0, every prior host suite
green, **34 new built-byte assertions**, plus exact-reason negative control.
The broken-config child exited1 with `ReferenceError: __name is not defined`
and reproduced the live browser byte count/hash exactly. Full receipt:
`/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-spatial-built-SGTNyW/receipt.json`.

Root then ran the live-read-only gate:

```sh
cd services/edge/tour-host
node --experimental-vm-modules scripts/check-spatial-built.mjs \
  --asset-url https://rendprop.com/spatial-viewer.js
```

At23:46:09UTC this correctly exited1, same26,442bytes/hash and missing-helper
error. Receipt:
`/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-spatial-built-Lzf7ze/receipt.json`.
**Do not say deployed/fixed in production until a subsequent real deploy and
this same URL gate pass.** Do not enable spatial budgets as part of a viewer fix.

Detailed unit report:
[`SPATIAL-BUILT-VIEWER-FIX-20260911.md`](../audits/2026-09-10/SPATIAL-BUILT-VIEWER-FIX-20260911.md).

**Gate follow-up,00:07UTC September12 (September11 evening Eastern):**
Independent review correctly noted that Node's VM timeout is not an isolation
boundary. Remote/file-provided browser code is now required to SHA-match the
actual build from the reviewed local source **before** execution. A mismatch
is reported as deployment drift without evaluating supplied JavaScript. This
also makes a future live pass source-bound rather than merely "some script ran."
The documented preview command's loopback-only Deno permission remains a CLI
requirement; never rerun it with ambient unrestricted network permissions.

Root reran full `npm run predeploy`:exit0, **36 built-byte assertions**, exact
missing-`__name` control retained, plus a second deliberately throwing unmatched
script rejected at identity verification before its body executes. Worker and
browser hashes are unchanged. Receipt:
`/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-spatial-built-9vyLUH/receipt.json`.
Older34-assertion receipts above remain valid history; the current gate has36.
The live check now requires this source/lockfile's build dependencies and will
reject an older deployed asset as a hash mismatch before evaluating it.

## Unchanged limits and delivery gates

- No production data deletion, bulk ticket cancellation, feature enablement,
  new GPU allocation, Cloudflare/Supabase deployment or Apple action in this pass.
- The paired0039 deletion handler/migration and0041 provider journal remain
  separate deployment obligations. A tip handler dependency is not evidence
  that the older live handler is currently down. No production `DELETE /me`
  will be used as a test.
- The last known production spatial runtime is disabled with zero budgets.
  The deployed Modal controller is deliberately disabled; no new live readback
  of either is implied by this document.
- Training still has7000-iteration and1800-second ceilings in schema and code.
  A25000-step run requires deliberate reviewed changes, not just a larger CLI
  argument. More iterations are not established as sufficient for quality.
- The pending App Review submission and existing internal TestFlight builds are
  untouched. Source fixes do not update the owner's installed app.

## Root verification so far

Baseline at documentation-only commit `de5c4f9` (application source unchanged
from71f9eb7):

- `python3 tools/audit/run_edge_regression.py`:731 passed,0 failed/ignored,
  all22 function entrypoints typecheck; real fail-open Turnstile mutant rejected.
  Receipt `/tmp/rendprop-edge-audit-rgc1uo1t/receipt.json`.
- First clean-worktree launch correctly failed before tests because the runner
  requires preinstalled `node_modules` (`npm:@supabase/supabase-js@2` absent).
  Evidence retained at `/tmp/rendprop-edge-audit-e7q9x29r/receipt.json`.
  Ran `deno install --entrypoint --no-config --no-lock --node-modules-dir=auto
  */index.ts` from `services/supabase/functions`:9 packages reused from cache,
  zero package downloads, Supabase JS2.112.4. Then reran the unchanged runner
  with network denied. No failed launch is counted as a test pass.
- Pinned Python3.12.14: `-m unittest discover -s services/spatial-worker
  -p 'test_*.py' -v`:41 passed; training directory equivalent:98 passed.
  These are offline controller/training tests, not a new training run.
- Tour-host `npm ci --ignore-scripts --no-audit --no-fund`, typecheck and old
  `npm test`:557 unbranded assertions+12 self-tests,584 route,707 upstream,
  418 lead-form,57 legal,103 spatial assertions all pass. Their success does
  not close the emitted-code defect. New gate results will be recorded separately.
- Spike viewer clean lockfile install and `npm test`:21 passed, zero skips.

## Actual-room check through the fixed emitted Worker

The local preview tool now **requires** an emitted Worker path. It dynamically
imports that artifact and requests its real `fetch` handler for both the page
and `/spatial-viewer.js`; source imports only prevalidate private input files.
The tool checks unchanged bundle hash during preparation and prints bundle and
browser-payload hashes, never its local fixture credential.

Artifact supplied by the viewer unit's actual Wrangler4.129.0 dry run:

- Worker SHA256 `b0e1a36a73bd294822a33a3eb973457a7c0ccc51ce51a9b4e6a31a3a620e6ca3`.
- Browser payload26,118bytes, SHA256
  `c31b3d1c86fc65fd418a78343071b6f3c701627399c55c994d89420d20436517`.
- Exact local bundle:
  `/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-spatial-built-7MSKrs/bundle/index.js`.

Root ran:

```sh
deno check --unstable-sloppy-imports tools/audit/preview_spatial_room.ts
deno run --cached-only --allow-read --allow-net=127.0.0.1:8098 \
  tools/audit/preview_spatial_room.ts \
  /Users/pilksclaes/LocalSpatialExperiments/modal-room-20260911-01/preview-manifest-final.json \
  /Users/pilksclaes/LocalSpatialExperiments/modal-room-20260911-01/room.sog \
  /var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-spatial-built-7MSKrs/bundle/index.js \
  8098
```

The first typecheck exposed a generic `Uint8Array<ArrayBufferLike>` versus
WebCrypto `BufferSource` mismatch in the new helper. Corrected its argument to
`Uint8Array<ArrayBuffer>`; subsequent typecheck exited0, without a type cast.

Browser skill CLI was unavailable; the connected Chromium browser was used.
Observed actual room render and private-preview status after the runtime draw
gate, Top-down selected and visibly changed viewpoint, Starting view cleared
Top-down, drag visibly rotated the room, and Close removed the viewer.
Captured warning/error console lists were empty. An attempted Playwright
checkbox selector timed out; the fresh accessibility control was used instead.
The first Forward accessibility click did not establish measurable translation.
A second check used a393×852 browser viewport and the root gate's identical
emitted Worker (`rendprop-spatial-built-SGTNyW/bundle/index.js`). All viewer
controls and the wrapped private-preview status were visible without clipping;
keyboard activation of the actual Forward button visibly changed the viewpoint.
The second warning/error console list was also empty. This is a responsive
Chromium check, not physical-iPhone acceptance or a measured translation/FPS
benchmark. Images remain visibly blurry.

The only fixture substitutions remain the page's local capability and the
same SRI-pinned engine served from loopback. This check proves actual built
browser execution on local real-room input, **not live production auth,
publication, revocation, iPhone performance or acceptable reconstruction**.
Both temporary tabs were closed, the viewport override reset, and both preview
servers stopped (SIGINT130). No private room files were uploaded or committed.

A root subprocess assertion also verifies that the old source-only invocation
(manifest and model without a bundle argument) exits1 with the exact new usage
error before any `PRIVATE_LOCAL_PREVIEW` listener announcement.

## Upload implementation — intermediate evidence, not a deployment

Core iOS unit804f912 is integrated aseeb841b. Root ran
`python3 tools/audit/run_upload_recovery.py` against that exact clean source:
**96 assertions, ten successfully compiled mutants rejected for their intended
runtime assertion, restored source passed**. Receipt:
`/tmp/rendprop-upload-recovery-h62k9h93/receipt.json`.
This executes the actual recovery/journal/uploader/manager with injected
boundaries. It does not compile the whole LiveAPIClient or prove the UI.

The first full-app compile in the iOS implementation worktree found a real
transport-adapter error missed by that narrower native harness: the new restart
method supplied a String where the request builder requires its Idempotency
enum. That build exited65; it is not a pass. The fix and a repeated full build
are pending integration below.

Independent review also identified these follow-up cases, being corrected
before final integration:

- A killed app never enters the catch that sets a photo failure message; its
  durable unfinished record must still appear in Settings recovery.
- Initial video-ticket responses and actual OS dispatch need account-owner
  checks, not only restart/reconciliation callbacks.
- Cancel or starting another video while Restart awaits its response must not
  discard the saved parent/intent and forget the server-created child.
- An unreadable photo journal must not be overwritten with an empty record;
  photo-success notices and failed provenance linking need truthful, separately
  dismissible messages. The overwrite regression is in the96-assertion proof.

### Integrated server verification

Server unitb8a25c27c256c67de30a73ba9debf29737378f15 is integrated as873f456.
Root independently ran these on the integrated source, not the agent's tree:

| Command | Observed result | Receipt |
|---|---|---|
| `python3 tools/audit/test_upload_restart_db.py` |40 passed,0 failures/skips;2 intended SQL assertion failures; restored cases pass; owned socket-only PG17 stopped with exit0 |`/tmp/rendprop-upload-pg-n43vakvd/receipt.json`|
| `python3 tools/audit/verify_upload_restart.py` |122 handler/transport tests pass;2 copied-handler assertion failures;15 restored tests pass |`/tmp/rendprop-upload-restart-y2ufq8s6/receipt.json`|
| `python3 tools/audit/run_edge_regression.py` |753 pass,0 failures/skips;all22 entrypoints typecheck; fail-open Turnstile mutant rejected |`/tmp/rendprop-edge-audit-x_mc71fu/receipt.json`|
| `python3 tools/audit/verify_upload_transport.py --tsc <integration tour-host>/node_modules/typescript/bin/tsc --deno-dir /Users/pilksclaes/Library/Caches/deno` |122 pass;native Worker adapter typecheck passes; final-byte streaming mutant rejected |`/tmp/rendprop-upload-offline-yces8j8v/receipt.json`|

The122 upload tests are a subset of753, not additional distinct tests. The
40 PostgreSQL cases include20 existing transport cases plus20 restart cases;
they really execute migration0042 and its dependencies, not mocked SQL. Two
concurrency tests observe blocked PostgreSQL lock waiters before release.
They also execute0039 deletion inventory and0040 spatial attachment: both old
and replacement keys survive in the deletion payload, and an incomplete or
cancelled parent cannot attach as the room's completed input.

The service preserves old spent bytes, releases only unspent held bytes, and
atomically admits at most one direct replacement per parent. The limit is
three explicit restarts/four total attempts **per linked chain**, not universal
content deduplication. A delayed old copy cannot publish or overwrite its child.
Budget denial rolls back old cancellation and new admission together.

See the complete server contract, exact references, limits and rollout plan:
[`UPLOAD-EXPLICIT-RESTART-SERVER-2026-09-11.md`](../audits/2026-09-10/UPLOAD-EXPLICIT-RESTART-SERVER-2026-09-11.md).
Deployment order is **0042 → matching uploads renew/restart handler → paired
iOS client**. No deployment occurred here. The older anonymous-adoption actor
binding limitation is explicitly still open;0042 does not repair that identity
migration or magically deploy the0039 cleanup pairing.

### Integrated client verification

iOS follow-upd51714b is integrated as39da611; receipt-only503a9de as93d95dc.
The wire harness17de00c is integrated asf26bc62. Root reran all four native
checks on those combined application sources:

| Command | Observed result | Receipt |
|---|---|---|
| `python3 tools/audit/run_upload_recovery.py` |119 assertions;15 successfully compiled mutants rejected; restored source passes |`/tmp/rendprop-upload-recovery-ozcef5ol/receipt.json`|
| `python3 tools/audit/run_upload_restart_wire.py` |41 assertions;1 exact String→Idempotency compile rejection plus4 compiled runtime mutants; restored pass |`/tmp/rendprop-upload-restart-wire-r7k9w8wq/receipt.json`|
| `python3 tools/audit/run_spatial_coordinator_recovery.py` |12 assertions;3 compiled mutants rejected; restored pass |`/tmp/rendprop-spatial-restart-mnf_3876/receipt.json`|
| `python3 tools/audit/run_spatial_client.py` |75 assertions;6 compiled mutants rejected for their intended runtime assertions; restored pass |`/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-spatial-client-qrmcb2lx/receipt.json`|

The general manager is the actual compiled class with injected API/session
boundaries. The spatial coordinator gate copies only selected actual method
bodies and injects persistence, pump and OS boundaries; it is **not** a whole
iOS background-daemon proof. The API gate uses the actual request builder,
idempotency policy, adapter, mapper and DTO decoder, with only configuration and
execute injected; its runtime runs with network denied. Its narrower fake API
predecessor could not catch the new adapter's compile error.

The119-assertion pass includes app-death-shaped unfinished photo records,
suppression of currently active photo rows, protected corrupt receipts, stable
restart intent after lost responses, completion winners, actual video-manager
Cancel/new-begin races, anonymous bootstrap, delayed account-switched ticket and
OS callbacks, and stopping a photo batch's next dispatch after an owner change.
Settings now exposes explicit consent, wait/retry versus restart, exhaustion,
and truthful separately dismissible photo transfer/attachment messages.

Root's first integrated full-app/UI command used XcodeGen2.45.4 and the existing
dedicated synthetic simulator8D787CFB-B1F3-4950-854E-463126A68F92, with only
`SpatialProductIntegrationTests` selected. It **failed before any UI test ran**:
Swift could not type-check the inline photo-confirmation Binding setter at the
then-current `SettingsView.swift:467:128`. Exit65 and original result bundle:
`/tmp/rendprop-upload-recovery-app.kRcexp/build.log` and
`/tmp/rendprop-upload-recovery-app.kRcexp/SpatialProduct.xcresult`.
The actual LiveAPIClient error was resolved; this is a distinct UI compilation
failure, not an environment problem or a skipped test disguised as success.
Its view-expression correction and repeated full build are pending below.

The required `xcodegen generate` refreshed the tracked project references from
`project.yml`; that mechanical output is committed as9173b1f, including its
relative capture-source group and upload recovery source references. No source
media, signing settings, app version or provisioning profile changed.

Remaining transfer-adjacent limitation: retrying saved photo bytes does not
automatically replay a failed poster or disclosure attachment. The UI names
that distinction and preserves the original; transparent metadata reattachment
is not claimed fixed. The device's real Wi-Fi loss/background delivery and a
live linked replacement still need acceptance after the paired deployment.

## Final integration checkpoint — September 11 evening Eastern

The Settings correction took three further real build attempts, not a syntax
parse declared to be an app build:

1. `83e0a18`: exit65, the final local-data alert expression still exceeded
   Swift's type checker. Preserved `build-corrected.log` and
   `SpatialProduct-corrected.xcresult` under the same retained build directory.
2. `389b806`: split the unchanged modifier chain into opaque lifecycle/account/
   deletion/local-data stages. Type checking advanced and exposed a separate
   availability error: the new two-value `onChange` requires iOS17, whereas
   Rendprop supports iOS16. Exit65; `build-staged.log` and
   `SpatialProduct-staged.xcresult` preserved.
3. `2ed7a8a`: use the iOS16-compatible one-value observer, without raising the
   deployment target or removing any confirmation. The **full app and UI test
   target compiled**; the selected non-camera spatial product test executed
   and passed in22.077seconds. `xcresulttool` independently reports1 passed,
   0 failed,0 skipped,1 total, on the dedicated iPhone17Pro simulator/iOS26.4.1.

Exact final successful command at this checkpoint:

```sh
cd apps/ios
xcodebuild test -project Rendprop.xcodeproj -scheme Rendprop \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=8D787CFB-B1F3-4950-854E-463126A68F92' \
  -derivedDataPath /tmp/rendprop-upload-recovery-app.kRcexp/DerivedData \
  -resultBundlePath /tmp/rendprop-upload-recovery-app.kRcexp/SpatialProduct-compatible.xcresult \
  -only-testing:RendpropUITests/SpatialProductIntegrationTests \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 180 \
  -maximum-test-execution-time-allowance 300 CODE_SIGNING_ALLOWED=NO
```

Log `build-compatible.log` ends `TEST SUCCEEDED`; no zero-test pass is counted.
Root exported and visually inspected both retained screenshots: the purple
Home3Dcard is visible and opens the real listing-scoped product, not the lab;
the unsupported simulator shutter is disabled and no fake room/share button
appears. This is not camera, filled upload-recovery UI, actual iOS16 runtime,
real network interruption, or physical-iPhone acceptance. Existing unrelated
Swift warnings remain; a successful build is not a warning-free claim.

Fresh full edge receipt on clean `2ed7a8a`:
`/tmp/rendprop-edge-audit-c2zstshp/receipt.json` —753 passed,0 failures/skips,
22 entrypoints typechecked, intended fail-open mutant rejected. The122 upload
tests remain a subset, not an additional count.

Latest live viewer read at `2026-09-12T00:16:29Z` (September11 evening Eastern)
still returned the same26,442bytes/known-bad SHA256 listed above. The strengthened
gate **rejected at reviewed-source identity before executing supplied code**;
do not describe this later check as a new execution of the helper error.
Receipt:
`/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-spatial-built-RGcsAS/receipt.json`.

### Final peer-review follow-ups (resolved in source below)

The119-assertion native pass missed an actual dispatch-handoff bug in the new
video Restart: the method called `resume()` while its `restartingUpload` guard
was still true. The child and consent were durable, but the control left the
video paused with stale error text. A new regression must require actual child
OS dispatch without a second Resume; preserving only its journal is insufficient.
The iOS unit is correcting this, with a specific mutation control.

Review also found a retained-video workspace-mismatch no-op in Settings and an
unfenced photo-journal error after account change. Both are follow-up fixes,
not privilege escalation claims. Owner journals must remain intact. Broader
synthetic main/reviewer UI walks are running against `2ed7a8a`; their outcome
and the repeated final-source app build must be recorded before handoff.

### Final source fixes and independent reruns

The final iOS Swift application source is frozen at
`3063eb481b079ef9d44312e4331581b61c1a9d58` (tree
`0ecaf4c8063dad045bb547b516157e7418902e5c`). At this historical checkpoint,
subsequent commits were documentation only. Later corrections below regenerate
the internal TestFlight project and repair test/inventory files; do not extend
the earlier all-source equality claim to those later commits. All source/context through
`2ca9c7a6219393845382928fb448d6bead7d4a51` was pushed normally to GitHub and
the remote branch SHA read back exactly. No shared history was overwritten.

- `5e2843c` integrates the video Restart handoff fix. The parent/consumed intent
  is durable before releasing the duplicate-operation guard and immediately
  calling existing Resume, with no intervening await. Resume clears old errors;
  existing owner and dispatch fences remain. The regression requires a child
  OS task to start exactly once, not merely a changed journal entry.
- `3063eb4` integrates workspace-aware controls and stale-photo-read fences.
  Settings clears both pending confirmations on userID change, explains the
  mismatch, and disables retained video actions for the wrong owner. It keeps
  the original journal. Both a delayed read success and its failure ignore the
  old owner without clearing or replacing the current owner's list/banner.
- The independent reviewer rechecked all three fixes and found no remaining
  concrete blocker in those changed paths. This is not an all-codebase audit.

Final independent root receipts:

| Command | Result | Receipt |
|---|---|---|
| `python3 tools/audit/run_upload_recovery.py` |128 actual native assertions;18 successfully compiled mutants rejected for intended assertions; restored pass;9 hashed inputs unchanged |`/tmp/rendprop-upload-recovery-m29fqpf2/receipt.json`|
| `python3 tools/audit/run_upload_restart_wire.py` |41 actual-source wire assertions;5 intended controls rejected; restored pass |`/tmp/rendprop-upload-restart-wire-vudnm3me/receipt.json`|
| `python3 tools/audit/run_edge_regression.py` |753 passed,0 failures/skips;22 entrypoints pass; fail-open control rejected |`/tmp/rendprop-edge-audit-wrntzun0/receipt.json`|
| `xcodebuild build-for-testing` with the same project/scheme/destination as above, `FinalDerivedData`, `FinalCompile.xcresult`, Debug and `CODE_SIGNING_ALLOWED=NO` |exit0, `TEST BUILD SUCCEEDED` on final source |`/tmp/rendprop-upload-recovery-app.kRcexp/final-compile.log`|

The final simulator executable wrapper SHA256 is
`c3acec81685a405da85d04ba6a053d0c1862840a8524c412bcf6d9a33a178bb4`;
its **actual Debug application dylib** SHA256 is
`9c40e9b1959edefee78fc2e7c897dcb095d4cafbb9542218091a29c140acfa98`.
These identify local simulator artifacts, not a signed archive or phone build.
Full build warnings include pre-existing localized interpolation, redundant
nil-coalescing, deprecated Bluetooth naming and SDK/tool metadata warnings.
No warning-free claim is made.

The earlier `2ed7a8a` main and reviewer walks both finished successfully:
258.347 and362.102seconds respectively; `xcresulttool` asserts2 total/2 passed/
0 failed/0 skipped in `NonCameraWalks.xcresult`.25 attachments were exported.
That is intermediate-source coverage. The same walks plus the spatial product
test are now rerunning against the **separately built final application** in
`FinalDerivedData`; its final result must be recorded below.

The latest public viewer check at `2026-09-12T00:30:36.308Z` again returned the
same known-bad26,442-byte SHA. It correctly exits1 at source-hash verification,
without executing supplied code. Receipt:
`/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-spatial-built-EWNMud/receipt.json`.
**The live P0 is still outstanding until deployment.**

### Narrow rollout handoff (future work, not executed here)

1. Fetch the integration branch and inspect its exact source/context. Re-read
   section1 of the standing brief before any deployment. Do not deploy all22
   tip Edge Functions as a shortcut; unrelated handlers have paired migrations.
2. Tour-host can be released separately after its real `npm run predeploy`.
   After deploy, run the exact live-asset gate from this lockfile/source. A200
   homepage or legal page does not establish viewer acceptance. Require the
   reviewed browser SHA `c31b3d1c86fc65fd418a78343071b6f3c701627399c55c994d89420d20436517`
   and successful validator execution. Do not enable spatial budgets for this.
3. Upload recovery rollout is **0042 → matching uploads handler → paired iOS**.
   The gateway is not replaced by a direct-presigned fallback. Verify a bounded
   owned synthetic complete-winner and interrupted→linked-child flow on the
   actual deployment, including replay and spent/held-byte accounting. Do not
   bulk-abort outstanding tickets or infer live race behavior from unit tests.
4. Keep0039/me and0041/provider paired obligations explicit before broader
   spatial ingestion. Confirm cleanup scheduling/lifecycle externally; local
   SQL inventory tests cannot prove physical production cleanup occurred.
5. Only then prepare a separately authorized internal phone build and test
   Wi-Fi interruption, suspension/relaunch, owner change and the three-restart
   limit on device. Keep the current App Review submission untouched.
6. Reconstruction quality is a separate acceptance failure. No25000-step
   training, clamp increase, GPU spend or runtime/budget enablement happened in
   this pass. The existing real-room render is still not an acceptable tour.

## Final non-camera app verification and hosted CI follow-up

At20:45:40Eastern on September11, the **final-source** simulator run completed:
`FinalUI.xcresult` reports `Passed`,3 total,3 passed,0 failed,0 skipped. Root
checked those fields with `xcresulttool`, not merely the last line of a log.
The three selected tests are MainWalk (`RendpropUITests/testWalk`),
`ReviewerWalk/testReviewerWalk`, and `SpatialProductIntegrationTests`.
Elapsed test time645.313seconds. This supersedes the intermediate app walks
above; they are not extra distinct test cases to add to the count.

Exact final invocation, run from `apps/ios`:

```sh
xcodebuild test-without-building \
  -project Rendprop.xcodeproj -scheme Rendprop -configuration Debug \
  -destination 'platform=iOS Simulator,id=8D787CFB-B1F3-4950-854E-463126A68F92' \
  -derivedDataPath /tmp/rendprop-upload-recovery-app.kRcexp/FinalDerivedData \
  -resultBundlePath /tmp/rendprop-upload-recovery-app.kRcexp/FinalUI.xcresult \
  -only-testing:RendpropUITests/RendpropUITests/testWalk \
  -only-testing:RendpropUITests/ReviewerWalk/testReviewerWalk \
  -only-testing:RendpropUITests/SpatialProductIntegrationTests \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 480 \
  -maximum-test-execution-time-allowance 600 CODE_SIGNING_ALLOWED=NO
```

Receipt/log: `/tmp/rendprop-upload-recovery-app.kRcexp/final-ui.log` and
`FinalUI.xcresult`. The27 exported attachments and their name map are in
`/tmp/rendprop-upload-recovery-app.kRcexp/final-shots/manifest.json`.
Root visually inspected the final Settings, Home 3D card and room empty state.
Purple branding, the Home entry and disabled unsupported-device scan control
are visible. This does **not** test a camera, real phone, real network, live
backend, populated restart-error UI, provider, or actual account destruction.
The walks use MockAPI and generated synthetic photos; deletion confirmation is
cancelled. Do not relabel that as a real deletion or authentication test.

One small UX finding remains: `apps/ios/Rendprop/Screens/SpatialTourView.swift:29`
uses the `view.3d` symbol beside the text `3D walkthrough`; this SDK renders the
symbol as the literal `3D`, making the hero read `3D 3D walkthrough`. Replace the
hero symbol with a non-text room/cube glyph in the next UI polish unit and
snapshot it. It is not a reconstruction or navigation failure. It was not
silently patched after the final-source tests.

The generated internal project was stale: it omitted current recovery/spatial
source references. `xcodegen generate --spec project-spatial-testflight.yml`
regenerated it in `abc6824`; only the generated project changed. Root checked
the diff, required symbols and `plutil -lint`. No version, deployment-target,
signing, team, entitlement or compiler-condition change was made.

The following additional build exited0 with `BUILD SUCCEEDED` at20:46:04Eastern:

```sh
xcodebuild build -project RendpropSpatialTestFlight.xcodeproj \
  -scheme RendpropSpatialTestFlight -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/rendprop-upload-recovery-app.kRcexp/LabReleaseDerivedData \
  -resultBundlePath /tmp/rendprop-upload-recovery-app.kRcexp/LabReleaseCompile.xcresult \
  CODE_SIGNING_ALLOWED=NO
```

Log: `/tmp/rendprop-upload-recovery-app.kRcexp/lab-release-compile.log`.
**This is an unsigned compile, not an archive, install, upload or delivery.**
The internal spec still says build18. The last known uploaded build is19;
an authorized release operator must read current Apple state and allocate a
new build number before archiving. Nothing here overwrites the current review.

### Real hosted CI exposed environment and inventory gaps

Root dispatched the existing test-only workflow against pushed commit
`2ca9c7a6219393845382928fb448d6bead7d4a51`:

```sh
gh workflow run ci.yml --repo AaronPilk/RendProp-Ai \
  --ref fix/spatial-upload-release-recovery-20260911
```

[Run34662282586](https://github.com/AaronPilk/RendProp-Ai/actions/runs/34662282586)
failed5 of10 jobs. It did not deploy anything. Passing jobs were the real
Cloudflare Worker gate on Node22, Python render worker, offline source/consent
audit, style policy, and iOS static guard. The five failures were inspected:

1. **Edge:** Deno2.9.6 exposes `Deno.serve` with an accessor descriptor. The
   deletion fixture spread that descriptor and added `value`, an invalid
   accessor/data hybrid. All22 entrypoints passed;726 tests passed but the
  27-test deletion module failed to load. Commit `3eea3a0` replaces only that
   test descriptor and restores the original exactly. Production handler
   behavior was not changed. Local descriptor-shape harness passes27 tests
   each for data/accessor shapes and rejects2 specific mutants, then passes
  27 restored. Receipt `/tmp/rendprop-deletion-descriptor-rwbp61ga/receipt.json`.
   This shape simulation is not itself a claim of running hosted Deno2.9.6.
2. **Web inventory:**12 protocol methods were unmapped;11 were already missing
   at base71f9 (10 spatial methods and renewal), and this unit adds Restart.
   Commit `085d649` maps all12 honestly as planned web work, not built browser
   parity. Root passes16 inventory/contrast tests; all three CLI controls
   (`missing-upload`, `low-contrast`, `no-op-validator`) exit1 for their
   intended cause. There remain0 verified browser-parity/live tests.
3. **Database migrations:** every fresh migration, including0042, applied.
   One of198 global invariants fails: agent-reel Astra output ceiling700
   equals visible-answer allowance700, leaving no reasoning headroom.
   `services/supabase/tests/invariants.sql:1417–1433` deliberately preserves
   strict `ceiling > visible`; this predates this unit and is the owner's
   already-open provider-token decision. No cap increase or weaker assertion.
4. **Disposable PostgreSQL publication:** the same global invariant fails
   fresh and replay. Migration replay and publication positive/negative/
   restored cases pass, and the owned cluster stops. This is a second red job
   from the same token-configuration issue, not a new0042 migration failure.
5. **History scanner:** six historical matches need exact classification;
   subsequent scanner checkpoint below records the narrow handling and real
   control results. Do not interpret an uninspected match as a leaked credential.

After the descriptor and inventory repair, root reran the full local edge
command at085d649: **753 tests passed,0 failed/skipped,22 entrypoints passed,
intended Turnstile fail-open mutant rejected.** Receipt:
`/tmp/rendprop-edge-audit-sl4kplo_/receipt.json`. This includes the122 upload
tests; do not add them again. A fresh hosted run against the repaired commit,
not a rerun of the old SHA, is required for hosted-environment acceptance.

### Second hosted run: repairs verified, one new test failure exposed

Commit `26c9459c4493f66681e6483f157915eafb836147` was pushed normally and the
exact remote SHA read back. Root's integrated-history Gitleaks8.24.3 run passed:
297 scanned commits,13,186,787 bytes,0 findings. The exact six historical
fingerprints and independent same-path/new-commit negative control are documented
in [SECRET-SCAN-DISPOSITIONS.md](../audits/2026-09-11/SECRET-SCAN-DISPOSITIONS.md).
That review corrects the earlier claim about a possible Bearer credential on
launch-P2 line518: the cited example is an unauthenticated request/error, not
an exposed private header. No broad scanner exception, rule disablement,
credential rotation or history rewrite occurred.

Fresh [run34663177777](https://github.com/AaronPilk/RendProp-Ai/actions/runs/34663177777)
evaluated this exact pushed commit, not an old rerun. Seven jobs passed,
including the actual built Worker gate, web inventory and scanner. Both DB jobs
remained red; the fresh-migration log reports exactly the pre-existing
agent-reel headroom invariant above. The publication job replayed0042 and
passed positive/mutant/restored publication cases, then stopped its own cluster.

The Edge job passed all27 deletion tests on real hosted Deno2.9.6, confirming
the descriptor repair. It nevertheless finished **752 passed,1 failed**:
`_shared/applejws.test.ts:952`, the x5c base64URL rejection case, did not reject
as expected. This is a different finding, not the original deletion failure.
The follow-up must distinguish a randomized fixture assumption from actual
decoder-runtime behavior before changing code or claiming a green suite.

At `2026-09-12T00:55:22.780Z`, the latest live viewer read again returned
HTTP200,26,442 bytes, the same known-bad SHA256. The source-bound gate exited1
at identity mismatch before executing supplied code. Receipt:
`/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-spatial-built-VR4F2N/receipt.json`.
No tour-host deployment, iOS delivery, Apple change or budget enablement occurred.

### Deterministic fixture repair and final-source local proof

Integrated `ce15713ecd741a7c53fe6c35140b12c293b09785` fixes only the Apple JWS
test fixture, adds its asserting harness, and documents the finding. Production
`applejws.ts` is unchanged. The official Deno2.9.6 executable was checksum
verified, not installed over the system runtime. Both2.9.6 and2.7.13 reject
URL-only alphabet digits and accept the shared-alphabet unpadded control.
The failed CI certificate was not retained, so its exact bytes are not
replayable; the faulty random-fixture precondition is established from source.

The test now signs a valid, noncritical extension carrying four0xff bytes,
which guarantee a URL-only digit after URL encoding at any alignment. It
asserts that precondition and verifies the **same chain/payload** in standard
base64 before requiring the URL-encoded certificate to fail specifically at
certificate parsing. It does not regenerate until green or weaken verification.
Detailed explanation and source:
[EDGE-CI-APPLE-X5C-FIXTURE.md](../audits/2026-09-11/EDGE-CI-APPLE-X5C-FIXTURE.md).

Root independently ran after integration:

```sh
env PATH="/tmp/rendprop-deno296.EyhIbB:$PATH" \
  python3 tools/audit/run_edge_regression.py
python3 tools/audit/run_apple_x5c_fixture.py \
  --deno /tmp/rendprop-deno296.EyhIbB/deno
```

- Edge: **753 passed,0 failures/skips;22 entrypoint checks passed; deliberate
  Turnstile fail-open rejected**. Receipt `/tmp/rendprop-edge-audit-brjjpje8/receipt.json`.
- Certificate fixture: **37 actual tests pass,100 fresh-chain repetitions
  pass,3 actual-source mutants fail for the intended reason, restored37 pass**.
  Receipt `/tmp/rendprop-apple-x5c-9or6pf74/receipt.json`.
- The100 repetitions are a separate determinism harness, not100 new Edge cases.
  The37 certificate tests are already included in753.
- Final iOS application/UI source equality against3063eb4 remains verified by
  a root-directory diff of `apps/ios/Rendprop`, `RendpropUITests`, the main
  project and `project.yml`. The regenerated internal project was separately
  Release-built as recorded above. No later iOS edit invalidated those results.

Sourcece15713 was pushed normally and its exact remote SHA verified before a
fresh workflow dispatch. Final hosted-run outcome is recorded below.

### Independent hosted database artifact verification

The second run's `disposable-database-regression-1` artifact10287967170 was
downloaded and inspected independently at
`/tmp/rendprop-ci-db-artifact-ma3izw/rendprop-db-audit-85i0m988/`.
All110 log SHA256 values match the receipt; no command timed out. All44
fresh migration commands and36 replays exit0. Fresh and replay invariant logs
each contain198 rows:197 true, only155 false with `copy.agent_reel ceiling=700
visible=700`. Both exit3. Worker publication22 checks pass in four positive/
restored runs; upload publication19 checks pass in two positive/restored runs.
Four distinct deliberately broken publication/input cases exit3 at the
intended errors; restores pass. Shutdown exits0 and logs `server stopped`.
Receipt correctly remains `accepted:false`, `clusterStopped:true`.

Qualification: the legacy migration job stopped after its initial invariant
failure and skipped replay. Full replay evidence comes from the separate
disposable regression job, not that skipped step. No schema, token budget,
provider or runtime switch was changed to manufacture a green result.

## Final hosted outcome and handoff

[Run34663756381](https://github.com/AaronPilk/RendProp-Ai/actions/runs/34663756381)
completed against exact pushed source
`ce15713ecd741a7c53fe6c35140b12c293b09785`:

- **PASS:** Supabase Edge (753 tests,22 entrypoints), actual emitted Cloudflare
  Worker gate, Python render worker, web inventory/contrast contracts, offline
  evidence/consent gates, reel-style contracts, iOS static gates, history scanner.
- **FAIL:** fresh migration/global invariants and disposable PostgreSQL
  publication/global invariants. The first logs exactly the agent-reel700/700
  headroom violation; the second reports the same invariant-stage failures
  with0042 replay successful and owned-cluster stop successful. The detailed
  independently hashed previous-run DB artifact above covers unchanged DB
  source; the last code change was test-only Apple certificate fixture work.
- No tests were disabled, scanner rules removed, production signature checks
  relaxed, or provider budgets changed to reach those eight green jobs.

Independent peer review of the final certificate fixture confirms that the
four-byte alphabet guarantee is alignment-independent, the extension is signed,
and the same-chain positive control prevents invalid-certificate false greens.
The rejection checks401/`unauthorized` plus the `certificate parse` substring,
not equality of the complete error string.

### Next operator actions, in order

1. Fetch `fix/spatial-upload-release-recovery-20260911`. Review actual source
   diff from71f9eb7 rather than implementing a second copy from prose.
2. Release the viewer fix after predeploy and require the **live source-bound
   asset gate** to pass; a200 shell is insufficient. This does not need a new
   iOS build or spatial budget enablement.
3. Release **0042 + matching uploads handler** together, then run the bounded
   live interrupted-transfer/linked-child/replay fixture. Do not bulk-abort.
4. Prepare the paired internal phone build only after that backend acceptance.
   Freshly read Apple state, allocate a new build number, keep App Review
   unchanged, and test actual Wi-Fi loss/force quit/relaunch on the owner's phone.
5. Keep the separate open work explicit: agent-reel token headroom,0039/me and
  0041 worker rollout pairing, actual spatial cleanup, photo attachment retry,
   anonymous-adoption actor binding and the unacceptable real-room visual
   quality. No25000-step training or new GPU budget was authorized/executed here.

All final source changes are pushed on the isolated branch; documentation
commits afterce15713 do not change the source evaluated by the final hosted run.
No deployment, archive, TestFlight upload, App Review modification, new GPU
allocation or spatial runtime/budget enablement occurred during this follow-up.
