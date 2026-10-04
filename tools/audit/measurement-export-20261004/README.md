# Measurement export admission and provenance proof

Run from any directory with macOS/Xcode Command Line Tools:

```sh
bash tools/audit/measurement-export-20261004/run-controls.sh
```

This compiles the production Listing/measurement models and source-extracted
`FloorMeasurementExportSafety`, `FloorMeasurementProvenance`, PDF page/text loops,
PDF text draw method and legacy scan convex-hull calculation. Only the UI/PDF
renderer and file-output boundaries are synthetic. It writes no customer files,
uses no camera, network, credentials, provider or production APIs.

The 49 assertions cover current-vs-stale exported snapshots; source/geometry/unit
changes; account/workspace context; server/draft/listing identity; address changes;
CAS conflicts and older-snapshot listing-facts review without discarding pending local revisions; manual/phone source
labels; plan UTC date; every floor/room/wall record in the actual PDF loop; and
calculated closing-wall and square-footage limitations. Five isolated source
mutations must compile and fail their named runtime assertions. Source hashes and
logs are retained in each `/tmp/rendprop-measurement-export-*` directory.

The legacy actual hull test demonstrates an L with a 16 m² entered polygon has a
20 m² convex hull. The UI explicitly labels that older phone-scan number as a hull
estimate, rather than certified living area. UI source wiring checks ensure the
open export sheet rechecks its immutable rendered plan snapshot.

These checks do **not** verify UIKit rasterization, native PDF text wrapping or
camera accuracy. The retained and irregular native BetaPolishUITests plus rendered
PDF inspection are separate required evidence. The actual PDF loop also exercises six valid 40-character names and pagination. This checks drawing positions, not UIKit glyph rasterization. Worksheet source labels use
5 rows/page, 68-point rows and a 44-point source offset so valid wrapped names do
not collide with provenance. No tape/laser accuracy is claimed by manual entry.
