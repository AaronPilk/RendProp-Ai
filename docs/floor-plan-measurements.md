# Floor plans and measurements

The Floor plan card now includes Measurements alongside the existing LiDAR scan
and blueprint upload. This is an iOS implementation on
`feat/floor-plan-measurements-20261004`; it is not in TestFlight 43 or App Store
build 42. See the [verification handoff](handoff/FLOOR-MEASUREMENTS-20261004.md).

## Using it

1. Open a listing → Floor plan → Enter measurements.
2. Choose feet/inches or metres, then add a named room. Enter its length and
   width from a tape or laser measure. Height is optional.
3. Add the other rooms. Place a room beside an existing room or drag it on the
   diagram. Rotate a room if needed. Overlapping rooms cannot be saved.
4. Select another floor or add a basement/next floor for a multilevel home.
5. Download the current floor as an image or PDF. A separate 3D room layout
   previews the entered rectangular rooms.

Changes save with the listing. Scan archives and uploaded blueprints stay
separate. This method works for furnished homes and on phones without LiDAR.
The first version supports up to 24 rectangular rooms/sections across a plan.
Irregular rooms can be represented as separately named rectangular sections;
doors, windows and wall thickness are not inferred. Room area totals never
overwrite the listing's advertised living area. Missing heights use a labeled
2.4 m default only in the 3D preview.

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
existing cloud `details.floor_measurements_v1` string. It needs no migration.
The independent measurements survive ordinary listing edits, dirty-listing
merges and create replay. Unknown/future wire versions stay intact and block
this editor rather than being overwritten. Removing every room saves an empty
supported plan to prevent an old raw value from coming back.

Account, session revision and workspace changes invalidate pending editing
and exports. The complete details envelope is size-checked before saving and
before sending a request. The existing whole-details PATCH protocol still has
no server revision check: an unseen simultaneous office edit can conflict.
Offline race tests do not establish live conflict-free syncing.

Studio retains the measurement data but does not yet display/edit these room
layouts. Export the plan image and attach it through Studio's existing floor
plan upload when you want it on a published listing. Draft measurement metadata
must be excluded from the public tour payload; sharing an exported image is a
separate deliberate action.

Manual geometry, the AR estimator and exports make no AI-provider request and
do not debit AI credits. Normal account/storage infrastructure still applies.

## Owner phone checks

- Enter tape-measured dimensions in a furnished room, add a second room, arrange
  them, and reopen the listing after restarting the app.
- Try feet/inches and metres, optional height, another floor, rotation and a
  rejected overlap. Confirm the advertised square footage stays unchanged.
- Save the image to Photos and the PDF to Files; verify labels and dimensions.
- On a real phone, compare repeated AR estimates with a tape. Check poor light,
  reflective walls, furniture, permission denial, a phone call and backgrounding.
- Use the same account on a second phone to verify cloud retrieval; confirm
  account/workspace switching cannot apply an old edit. Studio image publication
  and raw measurement editing are different paths.
