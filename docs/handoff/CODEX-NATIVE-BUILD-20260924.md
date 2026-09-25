# Native source/build handoff — 24 September 2026

## Status and source identity

The combined native source compiled successfully in both normal and explicit
spatial TestFlight configurations. These were unsigned generic-device Release
builds only. No simulator or camera was used; no archive, signed distribution,
TestFlight upload, App Store Connect change or physical-phone acceptance occurred.

Worktree: `studio-completion-20260924`; branch:
`feat/studio-completion-20260924`. At build time the base HEAD was
`186b25d19ad3e16373ea1c00c76218ab0664b659` with uncommitted reviewed changes.
The receipts bind the actual 116 source/spec hashes; the base commit alone is
not the built source. Both inventories match, and a later readback found no
changes to those 116 files. Documentation and web/backend changes are outside
that native inventory. Preserve these dated receipts when recording a later
release commit or archive.

`project.yml` still declares version 1.0.3/build 31. Build 31 was already delivered
from older source, as recorded in `CLAUDE-LIVE-DELIVERY-20260922.md`. These current
version numbers do not identify a new delivery. The owner must check the current
Apple inventory before choosing a new, unused build number.

## Source registration

`apps/ios/project.yml` now explicitly includes
`tools/spatial-spike/capture-ios/Sources/CaptureBlur.swift` alongside the seven
existing shared capture implementation files. The diagnostic standalone
`App.swift`, fixtures and scripts are excluded from the product registration.
Both generated projects were regenerated from their current specs:

- `apps/ios/Rendprop.xcodeproj/project.pbxproj`:
  `54121402cafe6cfbc60f2eeda15bcba2e94701ac6efbacb8fed1f17d4f239946`
- `apps/ios/RendpropSpatialTestFlight.xcodeproj/project.pbxproj`:
  `39d8414f55faf8878e43d3594e9e75e61ee2da9055003c0b5953f1fed13cd0ec`

The TestFlight overlay inherits `project.yml` and adds `SPATIAL_CAPTURE_LAB` for
its explicit local-capture entry. Regeneration preserved/restored the existing
`ProductionGuidance`, `ProductionPlan`, `ProductionPlanSyncStore`,
`ProductionPlanView`, `ProductionVideoLibrary` and `ProductionPlanUITests`
references. This is source registration, not evidence that those UI tests ran.
The bundle remains `com.rendprop.app`; no signing identity was changed.

## Exact unsigned build evidence

Both builds used `configuration=Release`, `destination=generic/platform=iOS`,
`CODE_SIGNING_ALLOWED=NO`, and exited 0. Existing compiler warnings remain in
the logs; these were not warning-free builds.

| Project / scheme | Receipt recorded (UTC) | Build log SHA-256 |
| --- | --- | --- |
| `Rendprop.xcodeproj` / `Rendprop` | 2026-09-24 23:35:03 | `4d15d004f3206c66f7dd337f34724733649d4319b996d182feda8cc252e34001` |
| `RendpropSpatialTestFlight.xcodeproj` / `RendpropSpatialTestFlight` | 2026-09-24 23:36:12 | `cea243b587815b35ddb44550eaade59ae3d877deb7e36e4cd9dc06f89c40a391` |

Private local evidence directory:
`/Users/pilksclaes/LocalRendpropAudits/studio-completion-20260924/spatial/`.

- `product-build-receipt.json` SHA-256:
  `21c35bd929d9c70d7d02b83835f900e806a2f412ffa27d8678d9b014f8c62ddd`.
- `testflight-build-receipt.json` SHA-256:
  `7eaf0134d1fb79ba5705a2199eeba328e86213a526295677646da3bc85b646f8`.
- Both receipts contain the full matching 116-file source inventory.
- Shared DerivedData was reused. The normal build succeeded, but a separate
  normal app binary hash was not retained. The final overlay executable SHA-256
  is `371df9d7857afff2a8cbb3801a1ffae50a4a27f32828f0f001c6116610ff6676`;
  its `Info.plist` SHA-256 is
  `a798316baf7514fabff27435923ea7c6d03eebcddcd02b841084567d2c59f34d`.

To repeat compilation from a reviewed checkout, regenerate each spec separately
and build its matching project/scheme with the settings above. Do not run an
archive or upload as a substitute for these unsigned checks.

## What the owner must do to ship this native source

1. Review and checkpoint the combined native changes, including both generated
   projects, then record the final release commit. Reconfirm its native source
   matches these receipts or rebuild changes. Reconcile concurrent developer
   work without replacing their project/source files wholesale.
2. Check the actual App Store Connect build inventory, select an unused build
   number, and keep the existing bundle identity, Apple-sign-in entitlements and
   signing team. For controlled local spatial capture use the explicitly named
   overlay; normal product distribution uses the normal project. The overlay
   does not enable a server runtime or certify reconstruction quality.
3. Produce a signed device archive, validate it, upload the chosen build to the
   intended TestFlight group, and record its commit, archive identity, build
   number and processing/distribution receipt. None of these steps has been done
   for this source.
4. Install that exact build on the owner's physical iPhone. Test normal capture,
   pause/resume and interruption recovery, multi-video import/upload and original
   preservation, then open the same named account/workspace in Studio and confirm
   the uploaded files and capture-plan changes arrive. Camera/AR behavior cannot
   be established by compilation or a simulator.
5. For local spatial capture, check readable status/instructions at large text,
   slow turns and brief pauses near windows, upper-wall/corner overlap, a warning
   clearing after slowing, recovery after tracking interruption, Stop/Done and
   export/reopen preservation. Inspect exported JPEG sharpness and coverage as
   well as calibration/full-rate telemetry. Motion thresholds remain provisional
   until checked against real captures, including dim light and translation.

The source includes pre-cadence quality validation, explicit unknown exposure/
motion states, fixed original held-out IDs, training-only seeds and pre-rental
quality/navigation gates. These changes do not establish a successful 3D output.
All activation gates remain closed by this work; the seven historical GPU runs
remain NO-GO. Any future reconstruction, runtime activation or quality acceptance
needs its own recorded decision and evidence.

Historical phone delivery and agency/spatial experiment documents are unchanged.
This handoff supplements them with the exact current compilation evidence.
