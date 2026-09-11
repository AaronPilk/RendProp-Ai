# Viewer bundle and interrupted uploads — follow-up

September 11, 2026. Base commit `71f9eb77d866554d9902610f519ef0092cc019d4`.
Integration branch `fix/spatial-upload-release-recovery-20260911`.
**Work in progress. Not deployed, not a new TestFlight build, not a whole-app GO.**

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
The Forward accessibility click did not establish measurable translation; no
translation/FPS/physical-iPhone claim is made. Images remain visibly blurry.

The only fixture substitutions remain the page's local capability and the
same SRI-pinned engine served from loopback. This check proves actual built
browser execution on local real-room input, **not live production auth,
publication, revocation, iPhone performance or acceptable reconstruction**.
The temporary tab was closed and server stopped (SIGINT130). No private room
files were uploaded or committed.

Upload implementation and independent integration results remain pending.
