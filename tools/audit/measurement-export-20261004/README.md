# Measurement export admission and provenance proof

Run from any directory with macOS/Xcode Command Line Tools:

```sh
bash tools/audit/measurement-export-20261004/run-controls.sh
```

This compiles the production Listing/measurement models and source-extracted
`FloorMeasurementExportSafety`, `FloorMeasurementProvenance`, PDF page/text loops,
PDF text draw method, Letter page layout/transform, and legacy scan convex-hull calculation. Only the UI/PDF
renderer and file-output boundaries are synthetic. It writes no customer files,
uses no camera, network, credentials, provider or production APIs.

The 82 assertions cover current-vs-stale exported snapshots; source/geometry/unit
changes; account/workspace context; server/draft/listing identity; address changes;
CAS conflicts and older-snapshot listing-facts review without discarding pending local revisions; manual/phone source
labels; plan UTC date; every floor/room/wall record in the actual PDF loop; and
calculated closing-wall and square-footage limitations. The actual PDF renderer
constructor uses US Letter landscape (792 × 612 points). Real CoreGraphics affine
math verifies every extracted drawing rectangle fits within physical margins,
with one balanced graphics transform per page. A conditional floor-scoped phone
ruler note states straight 3D point-to-point distance, same-height endpoints for
horizontal dimensions, and tape verification. Both PNG construction paths are
bound to the same production note in source. Mutable authentication and workspace
state doubles exercise the real `CloudMediaAccessContext`: sign-out, changed actor,
session revision and workspace all invalidate a captured context. Eleven isolated source
mutations must compile and fail their named runtime assertions. Source hashes and
logs are retained in each `/tmp/rendprop-measurement-export-*` directory.

The legacy actual hull test demonstrates an L with a 16 m² entered polygon has a
20 m² convex hull. The UI explicitly labels that older phone-scan number as a hull
estimate, rather than certified living area. UI source wiring checks ensure the
open export sheet rechecks its immutable rendered plan snapshot.

The negative-control wrapper uses portable `grep -F -q` so macOS CI does not
require ripgrep. A control must exit with status 1 and its exact intended runtime
assertion; compiler/tool failures cannot satisfy the control.

These checks do **not** verify UIKit rasterization, native PDF text wrapping or
camera accuracy. The retained and irregular native BetaPolishUITests plus rendered
PDF inspection are separate required evidence. The actual PDF loop also exercises six valid 40-character names and pagination. This checks drawing positions, not UIKit glyph rasterization. Worksheet source labels use
5 rows/page, 68-point rows and a 44-point source offset so valid wrapped names do
not collide with provenance. No tape/laser accuracy is claimed by manual entry.
