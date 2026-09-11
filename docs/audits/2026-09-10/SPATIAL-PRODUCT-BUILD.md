# Spatial product integration — September11

## Current task and authority

Owner explicitly requested all of: real-room reconstruction on their phone;
automatic capture upload and cloud generation with recovery and bounded cost;
Home feature card, in-app web 3D navigation, privacy review and sharing; integrated
tests and an internal TestFlight build with the submitted App Review version
unchanged. The earlier PhaseA-only stop instruction is superseded for engineering
work. No customer must run a GPU or export a folder to use the product.

Integration branch: `feat/spatial-product-20260911`.
Worktree: `room-proof-next-block-20260910`.
Do not confuse this un-deployed integration with the owner's installed build18.

## Source integrated before spatial changes

Cherry-picked, preserving original audit branches:

- Upload transportv2 (sourceb8162c6) and migration0037.
- Anonymous adoption recovery16a04ce,9469b4b,8429ee0 and migration0038.
- RenderEngine queue confinementc44f3f1.
- Privacy disclosurea2d8935.

Migration0039 remains reserved for the deletion worktree's uncommitted work.
The new spatial service uses0040; do not deploy the whole migration series until
the deletion migration is integrated and spatial external objects are covered.

## Implemented in this working tree — not deployed

- iOS: Home3Dwalkthrough routing, exact API/Live/Mock DTOs, capture completion
  callback, persistent file-backed backgroundURLSession uploads, server job
  polling, review/exclusion and hosted viewer opening. Explicit retry reuses the
  same saved capture with a stable operation key; cancel pauses the background
  journal before the cloud call; explicit resume reactivates it. Review requires
  a main-frame, exact-origin, exact-revision viewer-ready message after an actual
  nonempty WebGL frame, not just opening a URL.
- Supabase: spatial job/input/budget schema and route implementation; service-only
  transitions, unique job/capture/idempotency identities, bounded private input
  tickets, fenced one-attempt worker, output sealing, revision-bound review and
  publication. Up to three explicit paid attempts per capture preserve old
  attempt snapshots; they cannot overlap an unconfirmed previous GPU lifetime.
  Cancel/resume retains inputs and undispatched reservations. A separate expiry
  RPC and owned status reads stop indefinitely stale processing status.
- Web: shared scene decoder, private/public same-origin media route, pinned lazy
  PlayCanvas, walking/joystick/top-down controls, late optional chapter binding.
  Actual browser runtime tests use explicitly synthetic data. A bounded SOG ZIP/
  WebP predecoder rejects missing/external textures and oversized decode inputs
  before PlayCanvas allocation. This is not a measured iPhone memory ceiling.
- Cloud: deployable Modal scheduled controller definition and measured-pose
  adapter reuse. Validates private input inventory before GPU allocation,
  provider-enforced TTL/resource limits, no GPU credentials, denied network after
  dependency setup, lease-loss termination, one bounded output upload and server
  completion. No provider deployment/allocation has occurred for this source.
- Experiment diagnostics: incremental disk-bounded logs, durable numeric stage
  exits, classified terminal readback and recorded diagnostic-copy failures.

This is source progress, NOT an end-to-end feature completion claim. Region
redaction requests must remain private until real derivative processing exists;
an overlay or a checked checkbox does not remove data from a downloaded model.
Floor and navigation bounds from this capture format are explicitly estimates;
there is no claim of collision geometry or measured floorplan distances.

## Actual fresh checks so far

1. `python -m unittest discover -s tools/spatial-spike/training -p test_modal_room.py`
   —29 tests, exit0. Real local stream/receipt behavior; mocked provider boundary.
2. `python -m unittest discover -s services/spatial-worker -p 'test_*.py'`
   —31 tests, exit0. Controller contracts/bounds/lifecycle/output tests, noGPU.
   Logs: `/tmp/rendprop-spatial-worker-final2-20260911.log` and
   `/tmp/rendprop-spatial-diagnostics-final-20260911.log`.
3. Imported `services/spatial-worker/app.py` with actual pinned Modal1.5.3 SDK
   —exit0, no allocation/deployment. This checks SDK declaration shape, not cloud
   image build or runtime success.
4. Symbol grep then `xcodegen generate` and `xcodebuild build-for-testing
   -project Rendprop.xcodeproj -scheme Rendprop
   -destination 'platform=iOS Simulator,id=CC58F5C6-C811-4FEB-889A-EF10CE1E7A0E'
   -derivedDataPath /tmp/rendprop-spatial-product-derived-20260911
   CODE_SIGNING_ALLOWED=NO` —exit0, **TEST BUILD SUCCEEDED**.
   Log: `/tmp/rendprop-spatial-product-build-20260911.log`.
   This initial compile is before the subsequent AuthStore environment-object
   runtime correction and does not substitute for UI execution or final rebuild.

Initial build attempt intentionally stopped at the symbol gate because paths
were accidentally relative to the wrong working directory (exit2); corrected
paths were verified before the actual build above. Do not count that as a build.

### Subsequent executed evidence

- Native client:68 assertions and five compiled/runtime negative controls.
  `/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-spatial-client-6f6v1x7i/receipt.json`.
  Final change binds Scan-time owner and presentation identity through the
  completion callback and listing preparation; a late old-account callback
  cannot import its room into a newly signed-in account.
- Capture gate:31 quality assertions,10 actual CoreVideo raster assertions,
  two quality mutants,115 geometry/native-JPEG assertions,7 archive adversarial,
  8 JPEG-resource and3,076 pose precision assertions. Exact commands/receipts:
  [`SPATIAL-IOS-PRODUCT.md`](SPATIAL-IOS-PRODUCT.md).
- Latest private153-frame replay:148 accepted,5 baseline duplicates skipped,
  zero blur rejections at provisional cutoff24. This proves the gate is not
  rejecting every frame; **it does not solve the visibly blurry-frame issue**.
  Decoded-JPEG grayscale is not the original ARKit Y plane. No originals changed.
- PostgreSQL:69 actual assertions passed after apply/replay/restoration;
  deliberate publication mutant failed; three parallel cases observed real
  row-lock waits (budget, claim, same-key retry). Receipt:
  `/tmp/rendprop-spatial-db-dmp7_mcp/receipt.json`.
- A previous expanded SQL run passed68 assertions but its wrapper expected41,
  so the wrapper correctly exited1; do not call it green. The corrected run
  above added the short-runtime configuration assertion and retry race.
- Edge:25 actual-handler/contract tests,0 ignored; output-digest mutant failed.
  `/tmp/rendprop-spatial-edge-kqb0u1f2/receipt.json`. Recovery routes are present
  but do not yet have additional dedicated HTTP fixture coverage; actual SQL
  recovery behavior is covered by the69-assertion run.
- Viewer:2,426 host assertions+12 self-tests;69 actual Chromium checks; an
  injected premature-ready event fails the targeted runtime assertion. Four
  backend/browser admission discrepancies were reproduced then independently
  confirmed rejected after the fix. See
  [`SPATIAL-WEB-PRODUCT-SOURCE.md`](SPATIAL-WEB-PRODUCT-SOURCE.md).
- Mock-auth isolation:actual extracted production Swift methods,6 assertions;
  old compiled source fails and fixed source passes. Receipt:
  `/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-mock-auth-wnkhz3y8/receipt.json`.
- ReviewerWalk passed1/1 on build3:
  `/tmp/rendprop-spatial-reviewer2-20260911.xcresult`.
- MainWalk and SpatialProductIntegration passed2/2 on build4:
  `/tmp/rendprop-spatial-main4-20260911.xcresult`.
- The original combined UI run failed the owner-console assertion and later
  ended interrupted/mixed-source (exit73). It is not valid positive evidence.
  Mock UI auth refresh isolation was fixed; the fresh main walk above passed.
- Build5 log: `/tmp/rendprop-spatial-product-build5-20260911.log`, exit0,
  TEST BUILD SUCCEEDED. It includes retry/cancel and rendered-preview attestation.
  Build6 log: `/tmp/rendprop-spatial-product-build6-20260911.log`, exit0,
  TEST BUILD SUCCEEDED, includes the later scan-time owner fence.
  Do not reuse build3/4 walkthroughs as proof of these
  subsequent changes. No source-bound archive or upload is claimed.

## Real-room / deployment facts still open

- Latest153-frame capture is privately validated/prepared, NOT reconstructed.
- Prior256-frame run ended because Modal's billing-cycle spend limit was reached;
  exact terminal readback reconfirmed September11. No current reconstructed model
  was obtained from that run. Prior measured experiment usage~USD1.10.
- No account spend-limit change, new GPU, service deployment or Apple operation in
  this integration block yet. The owner's previous USD25 one-room ceiling is not
  ongoing production spending authority.
- SQL operational budgets ship disabled/zero. The conservative code ceiling is
  USD6 reserved per attempt (oneL4 lifetime plus a bounded CPU controller), NOT a
  claim that typical rooms costUSD6 or that USD6 was spent. Actual provider costs
  require reconciliation. No subscription/plan gate was invented.
- Need actual source-bound full app/UI tests, native background delivery test,
  first real cloud run, phone navigation/quality acceptance, region derivative
  processing, cleanup coverage and a release review before a finished-feature
  TestFlight upload. Pending App Review submission remains untouched.

### Remaining concrete implementation work

- Integrate0039 deletion intent and enumerate spatial current/history outputs,
  private input metadata and queued provider cleanup before production enablement.
- Persist provider sandbox identity and cleanup reconciliation outside the CPU
  controller's TemporaryDirectory. Local stage receipts improve diagnosis but
  currently disappear with that directory; provider TTL is not a deletion receipt.
- Implement actual region-redaction derivatives/editor; current UI supports
  whole-room exclusion or approval of an unchanged room, not selective blur.
- Add dedicated recovery HTTP tests, different-key retry/cancel-versus-claim
  race coverage, final WebKit/native background transfer checks and source-bound
  final UI/archive gates. No TestFlight upload has occurred in this block.
