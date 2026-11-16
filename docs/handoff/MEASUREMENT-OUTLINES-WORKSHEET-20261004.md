# Irregular outlines and area worksheet — 4 October 2026

## Delivery

Implemented on `feat/measurement-outlines-worksheet-20261004`, based on
`c2824e5` from the beta-feedback branch. This extends the prior
[room measurements delivery](FLOOR-MEASUREMENTS-20261004.md). The shared Claude
checkout and shared branches were not edited or force-pushed.

This is native app source, not a signed TestFlight build. No Apple submission,
backend deployment, migration, provider generation, spatial GPU job or pricing
change was performed for this expansion. Manual measurements and exports make
no AI-provider requests and debit no AI credits.

## Behavior

- Enter wall lengths and directions to build a straight-edge outline, including
  concave L shapes, diagonals and custom bearings. Review entered walls, change
  one, or undo a wall. Pending wall input cannot be silently omitted by Save.
- Enter all walls to close the shape, or review the calculated straight closing
  edge. Its calculated status persists and appears in the editor, worksheet,
  drawing and PDF wall record. Unchanged dimensions retain full precision;
  metadata-only edits retain the exact saved vertex coordinates.
- Classify each outline as finished, unfinished, garage, porch/deck or open
  below. Open-below areas require an explicitly selected finished parent on the
  same floor and must lie fully inside it. They are deducted once. Deleting the
  parent explicitly confirms deletion of its linked openings.
- The worksheet shows gross, deductions and net, keeping non-finished areas
  separate. Each floor uses outlines if present, otherwise rectangular rooms.
  Room annotations on an outlined floor do not inflate the building area.
- Export a selected-floor image and an all-floors PDF with drawings, worksheets
  and each outline's wall lengths, bearings, perimeter and closing-wall basis.
  Preview the entered polygon geometry in 3D. Room rectangles, scan and blueprint
  upload remain available.

Crossed walls, degenerate outlines, overlapping solid interiors, overlapping
deductions and invalid parent relationships cannot be saved. Shared solid
boundaries are allowed. Limits are 24 rooms, 12 outlines and 64 corners per
outline, subject to the existing 10,000-byte plan / 16,000-byte details envelope.
Entered geometry is not a certification of appraisal living area, and never
updates advertised square footage. Doors, windows and wall thickness are not
inferred; unentered heights use the labeled 2.4 m preview default.

## Storage and compatibility

The existing `details.floor_measurements_v1` wire key remains unchanged. Outline
payloads use inner version 2 and require an explicit outlines array. Old version
1 plans remain readable. A frozen prior-build decoder rejects version 2 for
editing while retaining its exact raw wire through a snapshot write; the new
decoder can recover it. Editor saves mirror the typed plan into raw details in
the same model mutation, including when the last outline is removed.

Actual create/PATCH/DTO/snapshot/replay/fingerprint/dirty-listing paths carry the
plan. Account/session/workspace changes fence stale edits and exports. Existing
whole-details PATCH still lacks a server revision check against unseen
simultaneous edits; offline race checks do not prove conflict-free live sync.
Studio retains the raw plan but does not yet edit/display native geometry.
Attach the exported image through its existing floor-plan upload for publication.

The deployed public `tours` filter already excludes the measurement namespace.
Additional v2 route/renderer tests verify private geometry is absent from public
JSON and HTML; publishing an attached image remains an explicit separate action.

## Verification

- 628 Foundation model assertions, including analytical area, concave/diagonal
  geometry, independent occupancy comparisons, overlap rejection, worksheet
  arithmetic, compatibility and precision. Six compiled negative controls reach
  their intended runtime assertions; compilation failures do not count as passes.
  Aggregate perimeters over 100 m use a separate bounded formatter; individual
  wall entry keeps its 100 m limit. A valid 40 × 20 m outline reports 120 m.
- Actual outline-editor method bodies pass 17 scenarios / 108 assertions. Three
  compiled controls detect lost original vertices, rounded untouched wall
  vectors and a missing pending-wall save guard.
- Actual sync/editor-save source passes 97 assertions with ten compiled
  controls, including outline-only drafts, local raw mirroring, dirty snapshots,
  create replay, clearing geometry mid-PATCH and frozen old-reader roundtrips.
- Seven public-route tests and 48 actual renderer cases cover version-1/2
  privacy across six business types and three branding modes. A deliberately
  bypassed namespace filter reaches the intended privacy failure.

- Actual native Debug UI checks pass both the new outline workflow and retained
  rectangular-room workflow: two tests, zero failures. They cover 16 m² concave
  area minus a 1 m² opening, closing-wall provenance, renaming, saving/reopening,
  image/PDF export, 3D preview and linked-parent deletion without resurrection.
- The actual four-page 842 × 632 pt iOS PDF was reopened with pdfinfo, checked
  with pdftotext and rendered with Poppler. All pages were visually inspected:
  drawing, worksheet and both wall records are legible, with correct arithmetic,
  named deduction parent and calculated closing-wall basis. Native screenshots
  were inspected too. The aggregate perimeter correction additionally has
  current-source model/editor receipts.
- Both checked-in Xcode projects register the new worksheet source and pass
  plist validation. CI registers all new model/editor/sync controls and retains
  their source-hashed receipts. Check the PR's current-head status before merging;
  local UI checks are not a substitute for that CI or a signed release.
- The normal iPhone Release build passes against the final runtime source.
  This is an unsigned compilation check, not an uploaded TestFlight binary.

The first native attempt failed because automated typing inserted new offsets
before existing digits. The corrected test explicitly sets the trailing caret
and asserts both exact field values before saving. Its full rerun passes;
the failed run is retained, not represented as a pass. No production coordinate
validation was weakened for the test.

The first PR-25 secret scan flagged the public schema field name
`floor_measurements_v1` in the stable-key regression assertion and frozen
older-reader fixture. Both exact historical findings are recorded in
`.gitleaksignore`; no credential, path-wide exception or disabled scan is involved.
Its failed log is retained separately from the current-head CI results.

Private receipts are under
`/Users/pilksclaes/LocalRendpropAudits/measurement-outlines-20261004/`, including
`outline-workflow-2.xcresult`, `perimeter-final-receipt.json`, `sync-proof/`,
`outline-editor/`, `native-attachments/` and `export-inspection/receipt.json`.

## Audit follow-up source — 4 October 2026

The current audit branch adds read-only export freshness checks against the
latest listing revision, identity, source provenance and workspace context.
Unresolved shared-edit conflicts block stale sharing without deleting pending
local measurements. The open export sheet carries its rendered plan snapshot;
a harmless date normalization alone does not invalidate it.

PNG areas identify entered dimensions or phone estimates, and exports include
the plan's last-updated date plus schematic/not-to-scale/not-survey limitations.
PDFs retain every room's dimensions and source even on outlined floors, with
separate full wall records and calculated-edge labels. Worksheet tables use five
rows per page with separate source positions for wrapped maximum-length names.
The older RoomPlan area is now explicitly labeled a scan hull estimate; the
actual L-shaped 16 m² outline has a 20 m² convex hull, which is not certified
living area. The feature guide explains decimal feet versus separate inches.

The export-admission/source/PDF-loop runner executes 49 assertions and five
compiled regression controls. It verifies the actual page and text loops with
inert drawing boundaries; it does not claim UIKit rasterization or camera
accuracy. The prior Photos-write permission/cancellation proof also still passes
18 assertions and its three compiled controls. Both gates are in CI. Current
native rendering evidence and final signed delivery belong in the overall audit
receipt; the historical four-page PDF evidence above is not a claim about a new
signed build.

Measurements now have a dedicated compare-and-set source path instead of an
unconditional whole-details update, plus load-shared/restore-local conflict UI.
This requires its new backend migration and signed app delivery. No deployment
or Apple upload is claimed by this follow-up. See the updated
[feature guide](../floor-plan-measurements.md) for current behavior and phone
checks.

## Phone acceptance

Use the [feature guide](../floor-plan-measurements.md). Enter a tape-measured
L shape, add a garage and open-below deduction, review the PDF calculation record,
restart the app and retrieve the listing on a second phone. Verify real Photos/
Files delivery and AR estimates against a tape. These manual UI tests use a
synthetic simulator fixture and cannot certify real-camera tracking or accuracy.

Apex-style curved walls, proprietary Apex file import and Bluetooth laser
integration are separate work; this delivery supports entered straight,
diagonal and concave outlines.
