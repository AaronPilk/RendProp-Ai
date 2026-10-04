# Floor plans and measurements

The Floor plan card includes Measurements alongside LiDAR scan and blueprint
upload. Measurements supports rectangular rooms and irregular wall outlines
with an area worksheet. The outline expansion is on
`feat/measurement-outlines-worksheet-20261004`; it needs a signed app build.
The earlier room-entry delivery is documented in
[its verification handoff](handoff/FLOOR-MEASUREMENTS-20261004.md).

## Using it

1. Open a listing → Floor plan → Enter measurements.
2. Choose feet/inches or metres, then add a named room. Enter its length and
   width from a tape or laser measure. Height is optional.
3. Add the other rooms. Place a room beside an existing room or drag it on the
   diagram. Rotate a room if needed. Overlapping rooms cannot be saved.
4. Select another floor or add a basement/next floor for a multilevel home.
5. Download the current floor as an image. The PDF contains all measured floors
   and an area worksheet; outlined areas also include a wall calculation record.
   A separate 3D preview uses the entered shapes and heights.

Changes save with the listing. Scan archives and uploaded blueprints stay
separate. This method works for furnished homes and on phones without LiDAR.
Plans support up to 24 rectangular rooms and 12 area outlines, with up to 64
corners per outline, subject to the saved-plan size limit. Doors, windows and
wall thickness are not inferred. Worksheet and room area totals never
overwrite the listing's advertised living area. Missing heights use a labeled
2.4 m default only in the 3D preview.

## Irregular outlines and the area worksheet

1. Choose **Draw a floor outline**, give it a name, and choose its floor and area
   type: Finished, Unfinished, Garage, Porch / deck, or Open below.
2. Start at a corner and enter each wall's length and direction. The drawing
   updates as you go. Cardinal and diagonal directions are available; Other
   angle accepts a bearing measured clockwise from the right.
3. Undo a wall or expand Review entered walls to change one. Leave the first
   outline at starting position 0, 0. Optional offsets position another outline
   beside it; positive X goes right and positive Y goes down.
4. Review the closing wall. Enter all walls to close it yourself, or review the
   computed straight edge back to the first corner. Computed edges remain
   explicitly labeled **Calculated closing wall — verify** in the editor,
   saved outline, worksheet, drawing and PDF wall record.
5. Save. The worksheet shows gross area, explicit deductions and net area.
   Garages, porches and unfinished areas are reported separately from finished
   areas. Concave and diagonal outlines work; crossed walls and overlapping
   solid areas cannot be saved. Shared edges are allowed.
6. For an opening such as open space below, create an **Open below** outline,
   select the finished outline to subtract it from, and place its corners inside
   that outline using the shared starting offsets. The opening must stay fully
   inside its parent and cannot touch its walls or overlap another deduction.
   It is deducted once. Deleting a parent explicitly confirms removal of its
   linked openings.

The worksheet chooses a basis for each floor: outlines when that floor has
outlines, otherwise entered room rectangles. Room rectangles can describe rooms
inside a building outline but never inflate its area total. A basement with
only room rectangles retains its separate room-area worksheet.

The image shows the selected floor. The PDF contains a drawing and worksheet
for every measured floor, plus each outline's wall lengths, bearings, perimeter,
area and calculated-edge note. Review this record against your measurements.
This feature does not certify appraisal living area or change advertised square
footage.

## Optional phone measurement

The ruler beside a dimension opens a point-to-point ARKit distance estimator.
Find a wall/floor surface, select the first endpoint, then the second, and use
the reviewed approximate value. Keep endpoints at the same height for length
or width. Detected surfaces are the default; estimated surfaces require an
explicit, labeled opt-in. Reset, tracking loss, interruptions and backgrounding
clear both endpoints. Denied permission and unsupported devices provide a
manual-entry path.

This is Rendprop's own tool built with public ARKit APIs; Apple's Measure app
is not embedded. Check phone estimates against a tape before using them in a
published plan. No simulator result certifies camera tracking or accuracy.

## Saving, syncing and sharing

The typed plan is saved in the local Listing archive and encoded into the
existing cloud `details.floor_measurements_v1` string. Its payload is version 1
for legacy rectangles or version 2 for outlines. It needs no migration.
The independent measurements survive ordinary listing edits, dirty-listing
merges and create replay. Unknown/future wire versions stay intact and block
this editor rather than being overwritten. Old app versions cannot edit
version-2 outlines, but retain their raw wire data. Editor saves update typed
and raw data together, including local snapshots. Removing every room and
outline saves an empty supported plan to prevent stale data from coming back.

Account, session revision and workspace changes invalidate pending editing
and exports. The complete details envelope is size-checked before saving and
before sending a request. The existing whole-details PATCH protocol still has
no server revision check: an unseen simultaneous office edit can conflict.
Offline race tests do not establish live conflict-free syncing.

Studio retains the measurement data but does not yet display/edit this geometry.
Export the plan image and attach it through Studio's existing floor
plan upload when you want it on a published listing. Draft measurement metadata
is excluded from the public tour payload by deployed `tours` v48; sharing an
exported image is a separate deliberate action. See the
[backend deployment receipt](releases/FLOOR-MEASUREMENTS-20261004.json).

Manual geometry, the AR estimator and exports make no AI-provider request and
do not debit AI credits. Normal account/storage infrastructure still applies.

## Owner phone checks

- Enter tape-measured dimensions in a furnished room, add a second room, arrange
  them, and reopen the listing after restarting the app.
- Try feet/inches and metres, optional height, another floor, rotation and a
  rejected overlap. Confirm the advertised square footage stays unchanged.
- Draw an L-shaped floor and an angled section. Compare the PDF wall record and
  area with your tape or laser measurements. Confirm calculated closing edges
  remain marked after reopening.
- Add a garage beside a finished outline and an open-below deduction inside it.
  Check category totals, gross-minus-deduction arithmetic and linked-opening
  deletion.
- Save the image to Photos and the PDF to Files; verify labels and dimensions.
- On a real phone, compare repeated AR estimates with a tape. Check poor light,
  reflective walls, furniture, permission denial, a phone call and backgrounding.
- Use the same account on a second phone to verify cloud retrieval; confirm
  account/workspace switching cannot apply an old edit. Studio image publication
  and raw measurement editing are different paths.
