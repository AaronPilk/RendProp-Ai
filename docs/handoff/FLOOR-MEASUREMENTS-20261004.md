# Floor plan measurements — 4 October 2026

The later [outline and worksheet expansion](MEASUREMENT-OUTLINES-WORKSHEET-20261004.md)
adds irregular geometry and classified area calculations. The delivery and
receipts below describe the earlier rectangular-room implementation.

## Delivery state

Implemented on isolated branch `feat/floor-plan-measurements-20261004`, based on
`8bd5b85` from `fix/topaz-actual-output-cost-20261004`. The shared Claude checkout
and shared branches were not edited or force-pushed. The new native feature is
not in TestFlight 43 or App Store 42; no Apple submission, pricing, subscription
allowance, spatial GPU job or provider generation was performed for this work.

## Result

The existing Floor plan card leads with Measurements, followed by scan/upload.
Manual room dimensions work in furnished homes without LiDAR. The user can add
rooms/floors, enter feet/inches or metres, arrange/rotate rectangles, preview
2D/3D and export a 1600 × 1200 image or a landscape PDF. Height is optional;
unentered heights use a clearly labeled 2.4 m preview default. Room totals do not
change advertised living area. Door/window/wall-thickness detection and irregular
polygon authoring are not part of this version.

The optional public-API ARKit estimator returns a reviewed point-to-point
distance. It requests camera permission only in that tool, requires fresh normal
tracking, defaults to detected planes, labels estimated surfaces, and clears
points across tracking loss, reset, interruptions/backgrounding and dismissal.
No camera quality or distance-accuracy claim follows from simulator tests.

Scans and blueprint files remain independent. The typed plan is in Listing's
local archive and the existing `details.floor_measurements_v1` wire envelope.
Units, geometry, source and timestamps persist. Clearing the last room writes
an empty supported plan. Malformed/future raw data survives and cannot be
overwritten from an initially empty stale editor. Unchanged displayed dimensions
retain original precision, including the 0.1/100 m input boundaries. Shared 3D
walls are unioned to avoid duplicate surfaces. Both checked-in Xcode projects
register the two new native source files; project generation was not rerun.

Dynamic details decoding now retains exact keys rather than applying
`convertFromSnakeCase` to stored dictionary keys. Create replay accepts prior
fingerprints only while the typed plan contributes no independent edit. Dirty
and protected snapshots keep phone edits; clean remote absence is authoritative.
Account/session/workspace guards fence editing and exports. Photos save rechecks
context after permission and suppresses stale completion. No new schema is used.

Public `tours` JSON excludes the entire case-insensitive `floor_measurements_`
namespace. Draft layout data is private even if its listing has a public tour.
Other public facts and explicitly attached floor-plan media stay available.
Studio retains the wire but only shows attached floor-plan image/URL today;
native measurements are not editable in Studio. Existing whole-details PATCH
still lacks server revision/CAS protection against unseen concurrent office edits.

## Verification

- 191 Foundation model/precision/wall-geometry assertions pass; 71 existing
  listing-form assertions pass. The retained conversion, overlap, wire,
  precision and geometry negative controls detect their targeted regressions.
- Actual-source wire/AppModel tests pass 52 assertions and six copied-source
  negative controls. Existing Studio-sync/client-contact baselines pass 55/60.
- Actual Photos save/caller bodies pass nine held-async scenarios / 18 assertions,
  including permission, cancellation, denial, failed write and stale completion;
  three copied-source negative controls fail as expected.
- Public handler tests pass 5/5, including a deliberately bypassed filter control.
  The actual viewer passes 24 renderer cases across six space types in
  branded/unbranded/embed modes. Actual tours source typecheck passes.
- The actual Debug native UI case passes: two rooms, overlap rejection, unit
  conversion, reopening, image/PDF export, 3D preview, and deleting all rooms
  without resurrection. It uses a dedicated synthetic simulator/MockAPIClient;
  no camera, Photos save, real login, network sync or purchase occurs.
- Normal iPhone Release build and internal Debug build pass. These are unsigned
  compilation checks, not a TestFlight binary or physical-device acceptance.
- The actual exported PDF was reopened with pdfinfo and rendered with Poppler;
  one 842 × 632 pt page, legible room names/dimensions and disclosure. Native
  screenshots were inspected; the shared-wall artifact was fixed and rechecked.
- CI registers the new model, wire, export and public rendering checks. Public
  handler tests are included by the existing edge-test discovery.

The first PR secret scan mistook the literal schema name
`floor_measurements_v1` for an API key; its exact finding is documented in
`.gitleaksignore`, and the next scan passed. CI also discovered the Node-only
renderer check under Deno's `_test.mjs` filename convention; it was renamed to
`public-details-renderer-check.mjs` and remains explicitly run in the tour-host
Node job. The five public-handler tests remain in Deno's discovery.

The first UI attempt could not connect to the stale simulator testmanager socket.
Restarting that dedicated simulator resolved it. A later expanded test used a
ScrollView helper against a native Form; it was corrected to the frontmost
collection view. Its result bundle became incomplete when diagnostic collection
filled the disk. Only stopped, agent-generated intermediate/diagnostic files were
removed; command logs and a cleanup receipt remain. The corrected full UI case
passes with zero failures. Earlier failures are not represented as passes.

Private evidence is under `/Users/pilksclaes/LocalRendpropAudits/`:
`floor-plan-measurements-20261004` (native logs, screenshots, actual PDF, export
proof), and `floor-measurements-20261004` (model, geometry, wire and public-route
receipts). These are source-bound records, not customer or camera recordings.

## Backend deployment

The draft-measurement public-data filter is live in Supabase `tours` v48,
ACTIVE with `verify_jwt: true`, deployed from runtime commit `43cec70` at
2026-10-04 16:36:20 UTC. Readback matched all 13 submitted files with no extra
or missing files. The unsigned edge-function probe remained 401; the public
`estate-demo` listing remained 200 with no measurement namespace. These were
read-only probes, not a live customer measurement injection. The pre-existing
shared helper's already-audited, unused `assertPaidAiIdentity` export was also
included; `tours` does not invoke it. No migration or auth-policy change occurred.
See the [deployment receipt](../releases/FLOOR-MEASUREMENTS-20261004.json).

The native feature still needs a signed TestFlight build and real-phone checks.

## Next device acceptance

Use the [feature guide/checklist](../floor-plan-measurements.md). Compare AR
measurements against a tape on the owner's real phone. Confirm relaunch,
second-phone cloud retrieval, permission/interruption behavior and real Photos/
Files delivery. Keep treating room totals separately from advertised living area.
Manual geometry and the AR tool make no AI-provider calls or AI-credit debit;
the existing scan and spatial walkthrough remain different features.
