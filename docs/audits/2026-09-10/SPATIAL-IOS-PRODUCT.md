# Spatial iOS product implementation — source handoff

Updated 2026-09-11. Worktree `room-proof-next-block-20260910`, branch
`feat/spatial-product-20260911`. This document reports source work and specific
test evidence, not a deployed phone build or a successful room reconstruction.
Root release coordinator owns integrated build/UI receipts and deployment.

## Delivered source

- `apps/ios/Rendprop/RendpropApp.swift`: first-row **3D walkthrough** Home card,
  distinct from floor plans/video tours; existing zero/one/many listing chooser
  and anonymous workspace behavior retained. Background-session callback routed
  to the dedicated spatial coordinator.
- `Screens/SpatialTourView.swift`: branded listing-scoped room capture, upload
  receipts, backend job status, private hosted 3D preview, whole-room exclusion,
  revision-bound privacy review and published sharing. The product capture
  callback no longer ends at the diagnostic Files exporter.
- `Networking/SpatialModels.swift`, `APIClient.swift`, `LiveAPIClient.swift`,
  `MockAPIClient.swift`: exact snake_case DTOs and create/list/read/attach/start/
  review/publish/retry/cancel/resume routes. Offline mock returns an honest empty collection and
  refuses generation; it never manufactures a room/model URL.
- `Upload/SpatialUpload{State,Recovery,Coordinator}.swift`: protected atomic
  durable journal, stable operation IDs, background file URLSession transfers,
  maximum three transfers, task-ID callback fencing, same-ticket uncertain PUT
  reconciliation, authenticated server completion/attachment, then cloud start.
  Only server-attached bytes advance progress. Original captures stay saved.
- Shared capture sources are included in the normal iOS project as individual
  Swift files; standalone harness entry point/resources are not bundled. Product
  capture validates the existing archive before invoking its upload callback.

## Upload and account boundaries

Photos use the existing bounded private upload-v2 `kind: photo, role: capture`
route. Original manifest/sidecar JSON goes to the private spatial metadata API,
not a new arbitrary-data upload escape hatch. Before creating a cloud job the
client validates 20–400 unique linked frames, <=32 MiB JPEGs, <=2 GiB JPEG total,
<=1 MiB serialized sidecars, <=16 MiB serialized metadata total, <=64 KiB manifest,
precise measured poses and original JPEG dimensions.

The local journal is capped at 32 records and 4 MiB and protected until first
unlock; an unreadable journal stops new work without overwriting recovery data.
Every record belongs to a JWT subject. Ownership is checked before and after
awaited coordinator transitions, foreign-owner OS tasks are cancelled, stale OS
callbacks cannot finish replacement tasks, and account changes tear down private
viewer/review sheets. The shared general HTTP client's token-refresh semantics
remain a separate integration concern: these tests are not a complete native
account-switch/HTTP-race proof.

Scan itself captures the original owner and a presentation UUID. A late archive
verification callback must match both the still-active presentation and owner;
enqueue carries that original owner across asynchronous listing preparation.
Sign-out, switching accounts, dismissing, or starting another scan cannot adopt
an old completion into the currently displayed workspace. This does not add a
sign-in gate to capture; an unavailable cloud session preserves the local scan.

On uncertain transfers the coordinator asks `/complete` first. Only explicit
409/503 reconciliation responses can renew the original upload operation with
the SAME idempotency key and SAME ticket ID. No second paid ticket is silently
created. Three reconciliation cycles are allowed per explicit Resume action.
The v2 server/gateway, not the phone, decides whether a write may be replayed.

`urlSessionDidFinishEvents` does not immediately release iOS's wake callback:
metadata transitions and newly scheduled OS tasks receive a bounded 20-second
background drain. Longer work remains in the durable journal. Real suspended
phone/locked phone/network-change acceptance is still required.

Recovery buttons use server `can_retry`, `can_cancel`, `can_resume` and
`attempt_number` authority. A failed attempt derives one stable valid UUID from
scene ID + observed attempt number, so a screen rebuild/relaunch cannot mint a
second retry key for the same failure. `/retry` retains the same scene and all
uploaded inputs. A new failed attempt receives a different key. Three attempts
is the server maximum; waiting for the prior cloud deadline is displayed without
demanding another capture.

Stop durably marks the local receipt paused and stops OS transfers before asking
the server to cancel. If the request fails, the client does not claim the cloud
was stopped. Delayed callbacks cannot unpause that receipt. Explicit `/resume`
must return the same uploading scene before local scheduling restarts; confirmed
photo inputs and original captures are retained. The optional pause field remains
compatible with prior local journals.

Privacy approval now requires an actual `spatial-ready` native bridge message
for the exact open scene/artifact revision from the expected HTTPS origin's main
frame. Wrong scenes, revisions, subframes, schemes, hosts, ports and URL-load
events cannot unlock approval. `PlayerWebView` registers/removes the receiver with
its lifecycle; stale presentations cannot change the new review. The hosted
viewer emits only after its own graphics context submits a nonzero instanced
splat draw to the canvas and completes postrender, not after URL retrieval or a
promise that can resolve on failure. Runtime submit also checks the gate, beyond
button disabling. This prevents accidental approval without rendering; it is
still user attestation, not automatic detection of every private object.

## Frame-quality admission, not mapped coverage

`CaptureQuality.swift` evaluates a <=160-pixel luma grid using Laplacian
variance, luma variance and measured camera pose. `CaptureRecorder` samples its
existing single retained AR buffer on the existing serial queue. JPEGs, K,
camera-to-world poses and the AR session are not rotated or replaced.

Provisional thresholds: Laplacian variance 24, low-texture variance 36,
translation 0.035 m OR full three-axis rotation 3 degrees. Low texture warns
instead of rejecting blank painted walls; rejected blurry frames do not advance
the accepted baseline. Coaching and skip counters are recorded, and Stop remains
available. Optional manifest metadata declares policy
`luma-baseline-v1-provisional` and its thresholds.

**Calibration remains open.** Read-only replay of the latest private 153-frame
capture accepted 148 and rejected five duplicate baselines. It rejected zero
for blur/low texture/invalid pose. Laplacian p05/median/p95 were
308.08/763.76/1568.14, well above minimum24. This establishes that the gate does
not reject the entire real capture; it does NOT establish that it catches the
visually blurry frames. The conservative threshold may be too permissive.
JPEG-to-grayscale decoding cannot reproduce an unavailable original AR luma
plane, even though the selector and production sampler executed unmodified.

No RoomPlan-derived waypoint coverage, house-wide registration or real
reconstruction quality is implied by these checks.

## Executed proof

All below ran locally with no customer uploads, provider spend or Apple changes.
Fixtures/receipts remain private under the temporary paths listed; originals
were not rewritten and no customer pixels/poses were added to this repository.

| Command | Actual result | Receipt/evidence |
|---|---|---|
| `python3 tools/audit/run_spatial_client.py` | exit0; 68 actual production-model/state/recovery assertions; five compile-success mutants fail their targeted runtime assertion; restored source passes | `/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-spatial-client-6f6v1x7i/receipt.json` |
| `python3 tools/audit/run_capture_quality.py` | exit0; 31 selector assertions, 10 actual native CoreVideo sampler assertions, two compile-success targeted failing mutants | `/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-capture-quality-7smr5qao/receipt.json` |
| `bash tools/spatial-spike/capture-ios/verify.sh` | exit0; includes quality31+10+mutants, 115 geometry/schema/cadence/completion/native JPEG assertions, UI summary rejects10 invalid cases, seven archive adversarial cases, eight JPEG resource cases, 3,076 pose assertions with zero skipped | quality sub-receipt `/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-capture-quality-u1gk20yp/receipt.json`; pose fixture `spatial-pose-precision-5C2BD408-FCC0-4640-8648-A9CA0D190046` |
| `python3 tools/audit/replay_capture_quality.py <private-capture-directory>` | exit0; exactly153 decoded frames, 148 accepted, five baseline duplicates; aggregate metrics only | `/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-quality-replay-hkdmjmoe/receipt.json` |

The `FAIL: intentional ...` lines in the full capture gate are deliberate
negative controls whose expected nonzero exit is checked. They are followed by
restored positive controls; a compiler failure is never counted as proving the
mutant was detected. Each native harness records exact command exits and hashes
of the production source under test.

New non-camera XCTest:
`SpatialProductIntegrationTests/testHomeCardOpensListingScopedProductWithoutCameraOrFakeRoom`.
It opens the actual Home card/listing chooser/product screen and verifies the
honest empty/unsupported-capture state without launching an AR session. Root
coordinates its final execution with ReviewerWalk and MainWalk. Root's earlier
integrated build succeeded, but it does not cover subsequent edits unless the
final build receipt says so. No UI ready/review mock-artifact walk is claimed.

## Explicit remaining acceptance and product gaps

1. A real reconstructed private room must successfully render/navigate on the
   owner's iPhone. Client source/tests cannot substitute for this proof.
2. Real phone background transfer after screen exit, lock, Wi-Fi/cellular change,
   process termination and authentication changes still needs device evidence.
3. Region selection + actual artifact redaction is not an implemented iOS tool.
   Whole-room exclusion and keeping the room private are honest current controls;
   a visual overlay is not privacy protection of the downloadable model.
4. Provisional image-quality thresholds need sharper/blurrier device calibration.
5. The local journal caps at32 rows, including old queued receipts. There is no
   archival/pruning UI yet; long-running usage can eventually hit that cap.
6. Current mock tests do not supply a manufactured reconstructed-room success.
   Error/review/ready UI states need explicit controlled backend fixtures or a
   future clearly-labelled offline test fixture, not assertions over no work.
7. This source handoff is not a TestFlight upload or App Review change. Only
   root's release receipt can bind an archive/upload to this source.

## Integration boundary

Root reported build5 exit0, covering same-job recovery and renderer-success-bound
privacy approval. A final narrow Scan-time owner/presentation callback fence
landed afterward. `rg` found the actual handoff invocation/captured-owner usage;
`git diff --check` exited0. The client native harness passed68 assertions plus
five actual-source mutants against this last update. Root must record the final
post-fence build and fresh non-camera UI results; build5 alone does not cover
the last capture callback edit. No other app source edits are in progress here.
