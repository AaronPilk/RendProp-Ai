# Viewer bundle and interrupted uploads — follow-up

September 11, 2026. Base commit `71f9eb77d866554d9902610f519ef0092cc019d4`.
Integration branch `fix/spatial-upload-release-recovery-20260911`.
**Integrated source fixes under final review. Not deployed, not a new TestFlight
build, not a whole-app GO.** Read the final checkpoint below before relying on
historical intermediate counts or failures in this chronological work log.

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

### Final peer-review follow-ups in progress

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
