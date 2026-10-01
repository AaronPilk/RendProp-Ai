# Handheld room-tour usability — 1 October 2026

## Delivery status

Candidate for internal TestFlight **1.0.3 (38)**, isolated branch
`fix/room-tour-usability-20261001`, based on `bb7a615`. Build37 remains the
latest verified delivery until build38's exact-source CI, signed archive,
single upload and Apple availability checks finish. No public App Store release,
spatial runtime activation, provider call or paid experiment is part of this change.

## Evidence from the owner's phone

The owner reported that Room tour 3 repeatedly demanded centimeter movements,
and mistook the next-photo target for a place to walk. Latest available Apple
beta screenshot feedback independently shows an 18 cm recovery instruction and
a purple target after only one photograph. The screenshot response identifies
an iPhone16_1 on iOS18.7.3, but contains no build relationship; it cannot prove
which installed build generated that feedback.

Room tour 3 saved four of 38 targets in one interrupted viewpoint. Room tour 4
saved **36 of 38** in one partial viewpoint: all 12 wall, 12 upper-wall and
12 lower-wall photographs, with neither straight-up ceiling nor straight-down
floor photograph. Room4 lasted **7 minutes 28 seconds**; the largest interval
between saved photographs was **65.94 seconds**. Accepted origin drift reached
9.32 cm under the old 10 cm gate. Both exports contain only accepted frames;
rejected-frame history and exact time spent following each recovery instruction
were not recorded, so these exports alone do not establish why each delay occurred.

All 145 declared Room4 files (27,978,098 bytes) validated. Read-only native
4096×2048 rendering preserved the original export and private copy byte for byte.
The report estimates 99.7774% spherical coverage and measures 95.8193% sampled
output-pixel coverage. These use different sampling definitions; neither means
that capture completed or stitching passed. The rendered result has visible
exposure boundaries, seams, close-object misalignment and missing polar pixels.
Customer photographs, poses, identifiers, signed screenshot URLs and raw feedback
remain in private local evidence outside Git.

## Capture behavior

- Start from any clear place with a useful view. Purple floor numbers are optional
  standing suggestions; exact arrival at a marker never gates Start.
- Floor suggestions stay fixed during their stability interval. Gradual boundary
  changes are compared with the interval's initial plan, including continued
  clearance of every proposed standing place.
- A **yellow camera target** means turn the phone toward the next photograph.
  Keep feet in place; do not walk toward it. Dead capture/preview buttons are
  hidden while photographs save automatically.
- The first fully admitted still photo sets the viewpoint's origin and heading.
  A Start tap no longer freezes the lens position before the person levels the
  phone. Once the first photo saves, the origin never follows subsequent motion.
- Handheld v2 permits up to **20 cm from that origin**, with **20 cm maximum
  separation between any pair of saved camera positions**. Legacy v1's 10 cm
  radius already allowed a worst-case 20 cm pair separation. V2 therefore allows
  more adjustment in one direction without widening that worst-case separation.
- Every photo still requires normal tracking, aim within 5°, angular speed no
  greater than 3°/second, estimated smear no greater than two pixels, and a
  0.35-second dwell. During dwell, camera positions must remain within 2.5 cm
  of one another; sample gaps over 0.15 seconds reset it.
- Out-of-bounds frames remain rejected. Brief excursions get a steady cue;
  sustained recovery uses one coarse instruction instead of changing local-axis
  centimeter commands. After three seconds of sustained recovery, a confirmation
  lets the user preserve that partial viewpoint and start a new one.
- All 38 real photos are still required. Ceiling/floor aim becomes **±80°**,
  rather than ±90°. Actual same-frame calibration must place the true pole
  inside the photograph with an 8% edge margin. High/low guidance says to tilt
  the phone with the back upright. Haptic feedback follows the durable saved
  photo count, so the user need not watch the screen at extreme angles.

## Versioned archive and preview contract

New captures declare schema2, capture policy
`station-handheld-20cm-span-v2-provisional`, target plan
`station-spherical-38-v2-handheld-provisional`, 0.20 m maximum pivot drift and
0.20 m maximum camera span. Unknown, incomplete, null, mismatched or inflated
profile declarations fail validation. Measured pose geometry is checked against
the declarations; a sidecar cannot lower a rounded drift value to bypass them.

Legacy schema1 archives retain their exact persisted 38-target definitions,
±90° poles, original 10 cm admission and omitted new fields. A synthetic archive
created by the prior committed implementation reopens, exports byte for byte,
and renders the identical PNG under this implementation. The preview cache binds
validated geometry profile, limits and target plan. A cache cannot bypass archive
validation. Missing pixels remain transparent and partial views stay partial.

The renderer still uses rotation-only projection. It does not correct parallax,
blend exposure, reconstruct a mesh or provide a Matterport-quality result.
Capture admission is a provisional phone usability experiment, not quality acceptance.

## Software verification

- Station policy/archive: **422 assertions** covering first anchor, walking/dwell,
  frame-write boundaries, legacy definitions, v2 span, calibration, malformed
  optics, tampering and a complete 38-photo synthetic archive.
- Native panorama: **63 assertions**.
- Actual preview-store/archive/renderer integration: **71 assertions**.
- Room survey, floor clearance, stability and navigation: **78 checks**.
- Legacy golden archive and PNG are unchanged. Synthetic fixtures contain only
  generated dummy identities, camera matrices, pixels and feature points.

Full device-target compilation, navigation-only UI checks, signed release archive
and all 12 exact-source CI jobs are separate release gates. Software checks never
operate a real camera or certify comfort, tracking, exposure, thermal behavior,
coverage or seams on the owner's phone.

## Next phone acceptance

Open **Home → Guided room tour**. Stand comfortably in one clear spot, point
straight ahead and Start without waiting for purple markers. Follow the yellow
camera target by turning/tilting the phone; short haptic taps confirm saved photos.
Keep the back upright for upper/lower/ceiling/floor photos. Complete one viewpoint
and review it before adding another. Compare completion time and comfort with
Room4; inspect ceiling/floor gaps and close-object seams. Export the new attempt
for read-only comparison. If recovery becomes persistent, the help action must
preserve the partial view before a new viewpoint begins.

Also reopen a previously saved v1 tour, close/reopen the app, and confirm original
photos and export still work. Guided room tours remain local to the phone until
exported; this build does not publish or synchronize them or enable spatial
reconstruction. Physical acceptance remains the owner's test.
