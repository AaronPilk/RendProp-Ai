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

## Implemented/in progress in this working tree

- iOS: Home3Dwalkthrough routing, exact API/Live/Mock DTOs, capture completion
  callback, persistent file-backed backgroundURLSession uploads, server job
  polling, review/exclusion and hosted viewer opening. Agent is finishing tests.
- Supabase: spatial job/input/budget schema and route implementation; service-only
  transitions, unique job/capture/idempotency identities, bounded private input
  tickets, fenced one-attempt worker, output sealing, revision-bound review and
  publication. Actual SQL/concurrency and route tests are in progress.
- Web: shared scene decoder, private/public same-origin media route, pinned lazy
  PlayCanvas, walking/joystick/top-down controls, late optional chapter binding.
  Agent is testing actual browser runtime with explicitly synthetic data.
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
   —20 tests, exit0. Controller contracts/bounds/lifecycle/output tests, noGPU.
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
