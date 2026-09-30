# Matterport capture research and the Rendprop product implication

Researched September 30, 2026, following the owner's request to investigate
stationary circular capture. This is a researched recommendation, not a shipped
capture mode, a proprietary algorithm reconstruction, or a physical-phone test.
The ongoing fixed-cohort spatial experiments remain separately recorded in
`CODEX-SPATIAL-CAPTURE2-20260930.md`.

## What Matterport documents

The official smartphone guide, updated June 3, 2026, describes holding the camera
at a stable position and moving around it while following on-screen targets.
The camera rotates at that position rather than swinging around the operator's
body. Simple scanning uses one rotation; Complete uses three for middle, upper
and lower coverage. Simple can still blur ceilings/floors because coverage is
limited. Images are stitched at each position; then the operator moves, captures
again and checks alignment. Compatible phones can additionally use LiDAR. This
supports the owner's proposed interaction, with multiple positions per room.
[Smartphone guide](https://support.matterport.com/s/article/Getting-Started-Matterport-for-iPhone?language=en_US)

The scan-path guide, updated June 9, 2026, calls for overlapping positions with
clear line of sight and a maximum spacing guideline of 5–8 feet. This is not a
required distance: scan closer where needed, including 1–2 feet before and after
doorway thresholds. Pro3 has separate guidance for large open spaces. The guide
recommends at least two positions even in a small room. Missing areas and
misalignment should be checked before leaving. Exact distances are their
guidance, not yet validated Rendprop thresholds.
[Scan-path guide](https://support.matterport.com/s/article/How-to-Determine-the-Scan-Path?language=en_US)

The rendering distinction matters as much as the capture motion. Matterport's
developer documentation defines the normal Inside View as an aligned panorama;
panoramic image data is distinct from the 3D mesh shown in Dollhouse and Floorplan
views. Its current Sweep API exposes panorama positions, rotations and neighboring
scan locations. These public contracts establish the distinction without claiming
knowledge of every internal renderer or reconstruction algorithm.
[Viewer terminology](https://matterport.github.io/showcase-sdk/sdk_vocabulary.html)
and [current Sweep API](https://matterport.github.io/developer-docs/reference/sweep/).

Depth is not interchangeable across their devices. Pro3 measures it with LiDAR;
their image-only workflows can synthesize depth using Cortex. Matterport explicitly
supports importing spherical panoramas as aligned 3D scans, subject to successful
processing. A normal cylindrical phone panorama is not automatically a complete
spherical capture. Their proprietary processing is not provided by a Blender
installation or by copying their capture instructions.
[Pro3 FAQ](https://support.matterport.com/s/article/FAQ-Pro3-Camera?language=en_US)
and [spherical image import](https://support.matterport.com/s/article/Import-360-Spherical-Images?language=en_US).

## Comparison with the code actually reviewed

The integrated iOS source was reviewed at
`aedf861a6e4a35d2b552390b7e9ffc029fc39454` in the separate release checkout.

- `tools/spatial-spike/capture-ios/Sources/SpatialCaptureViewController.swift`
  starts ordinary AR world tracking with autofocus and a bounded video raster.
- `CaptureRecorder.swift` saves ARFrame images, camera transforms, calibration,
  timing, motion estimates and sparse ARKit feature points. This spatial capture
  path does not currently save LiDAR depth maps or a dense scene mesh.
- `apps/ios/Rendprop/Screens/FlythroughDetailView.swift` has a separate RoomPlan
  room/structure export. That is existing useful functionality, but it is not a
  synchronized panoramic-image/depth capture system for the current spatial tour.
- The current tested walkthrough displays a Gaussian reconstruction. Defects in
  that reconstruction affect the room view itself. There is no implemented
  station-based panorama layer in the spatial capture path inspected here.

This failed reconstruction does not establish an inherent Gaussian-rendering
quality limit. The original method demonstrates high-quality novel views; adding
panoramas changes the viewing strategy rather than proving Gaussian splatting
cannot work.
[Original 3D Gaussian Splatting research](https://repo-sam.inria.fr/fungraph/3d-gaussian-splatting/)

These are source observations. They do not establish hardware behavior on a
phone, and simulator testing cannot validate the camera, depth or capture UX.

## Recommended direction

Build guided scan positions as the main property-tour interaction:

1. Show where to stand and a single clear instruction.
2. Guide a steady sweep with automatic capture when each target is sharp and
   aligned; request upper/lower coverage where needed.
3. Preview the stitched result and require a useful connection to previous scans.
4. Guide the next position, including doorway connections and missed areas.
5. Present sharp photographic panoramas when looking around, with real aligned
   geometry for spatial context, floor plans, dollhouse views and navigation.

This is a product recommendation inferred from the evidence. A set of linked
panoramas alone must not be labeled as a verified geometric reconstruction or
used to imply measurement accuracy. Stitching quality, depth/geometry alignment,
registration recovery, room coverage, memory and iPhone performance need their
own acceptance tests. Save both raw captures and derived outputs so defects can
be diagnosed without sending an agent back to the property.

Use existing local saving, upload recovery, access control, viewer hosting and
cost controls. Introduce an explicit capture format/version for scan positions,
panorama assets and synchronized depth where supported; do not silently reinterpret
existing walking datasets. The current scan and controlled SfM work remain useful
for identifying pose/alignment problems, but cannot by themselves validate this
new capture protocol. Do not enable production based on this research alone.

Stationary rotation is not a drop-in fix for the existing image-only SfM pipeline.
COLMAP's guidance calls for translated viewpoints and overlapping images. Multiple
scan positions, useful connections between them, and validated depth/geometry
registration remain necessary; one sweep in the middle cannot observe surfaces
hidden behind furniture.
[COLMAP capture guidance](https://colmap.github.io/tutorial.html)

Blender is optional for later manual authoring or export. It is not a required
component of this proposed capture, alignment, panoramic viewing and geometry
workflow. The owner should be able to finish a property tour in Rendprop without
operating a separate 3D editor.

## Smallest useful validation sequence

Before broad implementation, prove one complete station can produce a clear
spherical panorama from saved original frames. Inspect nearby furniture seams,
exposure changes, ceiling/floor coverage and moving-object artifacts. Keep the
originals and explicit missing-coverage information; do not fill property details
with invented content. Determine the needed targets and lens orientation through
physical-phone testing rather than hard-coding Matterport's ring count.

Then connect multiple stations across one room and a doorway. Validate depth or
geometry registration, recovery after tracking loss, and navigation between
physically connected positions. Existing RoomPlan output may contribute geometry,
but sharing a coordinate frame and timestamps must be demonstrated, not assumed.

Only after those work, join the result to the existing account, upload/recovery,
listing and hosted-viewer flows. Verify scale separately before making measurement
claims. The owner performs physical camera tests; local replay and UI tests cover
the software that can be verified without camera access. This sequence describes
future work and does not authorize additional paid computation.
