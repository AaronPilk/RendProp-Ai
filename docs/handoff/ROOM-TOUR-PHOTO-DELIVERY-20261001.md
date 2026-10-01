# Room guidance and edited-photo delivery — 1 October 2026

## Release scope

Isolated branch `fix/room-tour-photo-delivery-20261001`, based on the delivered
TestFlight 35 source/documentation (`d4830fe`). This update improves the local
guided room-tour experiment and photo delivery in iOS and Studio. Build 36 is
the proposed internal TestFlight artifact; build 35 remains the verified available
artifact until the new Apple readback is recorded. No database migration or edge
function change is required. Production reconstruction remains disabled.

## What the supplied files establish

The owner supplied `Room tour 1`, `Room tour 1.1` and `Spacial capture 2.0`.
The two room-tour folders are byte-identical copies of the same 33-file capture,
not two independent tests. The session ran from 14:34:33 to 14:38:08 UTC. All
eight positions are partial, with photo counts **1, 1, 1, 2, 2, 0, 0, 1**.
Only the first two horizontal targets were captured. No upper/lower ring,
ceiling or floor target was saved. The first four positions are within 14 cm
of each other, rather than useful distinct viewpoints.

The actual target plan is **38 photos per viewpoint**: 12 horizontal, 12 upper,
12 lower, one ceiling and one floor. It was not a 32-photo plan. The old primary
Save/Next-position controls allowed leaving a viewpoint after one photograph;
the copy and repeated left-turn cues did not make the missing coverage clear.
Rejected poses were not saved, so this export cannot prove why each rejected
frame was rejected or certify tracking quality.

The separate walking capture contains a readable 301-frame manifest and records
1,970 motion-blur skips and 44 tracking skips. Some iCloud pose sidecars were
dataless placeholders whose reads stalled; their pose span was not assessed.
No paid reconstruction was submitted. Earlier spatial spend remains
**$22.11834445 of the $25 ceiling**; this update adds no GPU/provider spend.
The source exports were not modified.

## Guided room-tour changes

- Start with a slow look around and toward the floor. Stable, classified ARKit
  floor boundaries can suggest up to three numbered standing spots. Suggestions
  are inside the observed floor patch with boundary clearance and separation;
  they are not a complete room survey or furniture-aware walking route. The
  person checks the spot and path are clear. A manual clear-center fallback is
  always available, including when floor classification is unavailable.
- A floor suggestion requires three distinct observations over two seconds.
  Tracking loss, a replaced floor, or materially changed geometry removes stale
  suggestions before capture. Suggestions freeze once capturing begins.
- Capture runs automatically. The screen separates the camera preview from a
  readable guidance area, shows the target direction and steady dwell, and
  tracks walls, upper walls, lower walls, ceiling and floor. Gravity-based cues
  distinguish turning from tilting, reverse on overshoot and handle the poles.
  Returning the lens to its pivot is a separate translation instruction.
- Completion is prominent only after all 38 targets. Finishing early requires
  confirmation and remains visibly incomplete in the library and preview.
  One complete viewpoint can be enough; eight is a storage limit, not a goal.
- The preview offers tappable numbered saved-view markers at the measured
  directions of other complete, distinct viewpoints, only over photographed
  pixels. Missing coverage, nearly coincident origins and incomplete captures
  do not receive navigation markers. The existing position strip remains.

The target geometry and capture admission thresholds remain unchanged:
10 cm maximum pivot drift, 5° aim tolerance, 3°/second angular speed and
0.35 seconds steady dwell. Persisted v1 target strings are unchanged because
archive validation compares their complete values. This is still photographic
look-around and switching between saved views, not a reconstructed mesh,
collision-aware navigation, a dollhouse or a measurement certificate.

## Photo delivery and original preservation

### iPhone

New captures/imports retain their pre-Rendprop-enhancement image and immutable
AI outputs in a durable local version history. One current version appears in
the gallery; **Versions** opens earlier images. Superseding/hiding a gallery
photo does not delete inputs used by existing reels or prior disclosures.
Restyling uses the saved pre-furniture input across app relaunch; subsequent
edits remain available as versions but may not carry into a restyle.

**Photos → Export photos**, or open one photo → **Export photo**, offers:

- MLS, Zillow/web or Social destination.
- Current edits or retained originals; full available pixels and source framing
  by default; optional 4:3, 16:9 or 9:16 fit/crop with a preview. Fit adds borders;
  crop trims edges. Neither stretches nor upscales the image.
- Share/save to Files or Save to Photos. Files receives individual numbered
  JPEGs, paired verified originals and matching disclosure text files. This
  native export is not a ZIP. Save to Photos saves image files; the user must
  separately copy captions into the listing.
- Clean unbranded MLS images with disclosure captions. Web/social can include
  recorded alteration labels, including virtual staging and decluttering.

Original exports preserve the retained file's exact bytes. New phone captures
were already JPEG-encoded before enhancement; they are not RAW camera files.
AI output may have fewer pixels than the capture. Imported files may have been
edited outside Rendprop. Older `orig-*` filenames do not establish an unaltered
camera original: those earlier sources are explicitly marked unverified.
Metadata/write failures retain existing current versions and source files.
Account, session and workspace checks protect late edits and export callbacks.

### Studio

AI Photo Studio distinguishes the current editing image from its original.
**Continue editing this result** supports declutter → stage. A further staging
style uses the same pre-staging input, including after another edit; the UI
previews that input and the resulting disclosures describe only changes actually
present. **Download photo/photos → destination → Download photo package** saves
a ZIP of JPEGs, verified originals, captions and file/crop provenance.
Original frame/full available output is the default. Optional 4:3, 16:9, 3:2,
1:1, 4:5 and 9:16 crops are previewed and do not upscale.

Existing photos remain downloadable without a paired original. An ambiguous
legacy paired source is included as an original only after the user reviews it.
No original is invented. Preview/export work aborts on account/workspace change.

### Boundaries that remain

Version and pre-staging history persists on the iPhone; Studio's pre-staging
history lasts during its open editing session. There is not yet a shared typed
version-history contract. Existing gallery cloud uploads remain append-only:
local supersession/hiding does not unpublish earlier remote photos. Uploaded
current/original pairs and captions use the existing cloud path, but this does
not certify cross-device version selection or restyling after a Studio reload.
The download does not automatically create a public original URL.

## Advertising disclosures

There is no universal MLS watermark or mandated aspect ratio. Clean MLS exports
avoid overlays forbidden by some MLSs; separate captions describe alterations.
Users still add the appropriate MLS fields/captions and check actual property
accuracy. A label does not permit concealing defects or altering permanent facts.
California advertising can additionally require conspicuous disclosure and a
public original URL/QR; this download alone does not supply that public link or
certify compliance.

Primary references checked for this update:

- [California BPC 10140.8](https://leginfo.legislature.ca.gov/faces/codes_displaySection.xhtml?lawCode=BPC&sectionNum=10140.8.)
- [CRMLS altered-image FAQ](https://go.crmls.org/wp-content/uploads/2026/02/2026_Digitally_Altered_Images_FAQs_v1.pdf)
- [Stellar photo rules](https://www.stellarmls.com/photorules)
- [Zillow photo transparency](https://www.zillow.com/news/ai-generated-listing-photos-and-why-transparency-matters/)

## Claude handoff review

`docs/handoff/CLAUDE-DECLUTTER-AND-AUTH-GATE-20261001.md` was read in full from
Claude's checkout before implementation. Commit `0071443` is not included in
build 35 and was not cherry-picked. Its proposed stage-base path could point at
a file then deleted by supersession; copying an intermediate edited image into
the next `orig-*` file did not preserve the actual root. Deleting predecessor
photo IDs/files could also strand existing reel inputs. This update implements
retained immutable versions instead.

The unrelated mandatory Apple-only gate is not included. Its free-trial abuse
premise is stale: migration `20261001143615_subscription_confirmed_trial_start.sql`
already gives a new free org no trial timestamp or plan source, and trial
activation requires Apple subscription confirmation. Replacing the whole older
app file would also lose the newer workspace/account recovery changes. No App
Store review, pricing, offer, sign-in configuration or subscription change was
made for this photo/capture update.

## Software evidence and phone acceptance

Current software evidence includes 222 station-policy checks, 70 room-planning
and saved-view checks, 292 local photo-history/file/geometry checks, 24 real UIKit
photo-render/export checks, 62 checks executing the actual edit orchestration,
and 29 actual ingress/exterior-save checks. Regression mutants reject the
old direction, wrong original input, original drift, lost disclosures and removed
identity fences. Studio's 423 unit tests/build and seven actual browser workflows
pass with real JPEG/ZIP inspection, including restyling after an intervening edit.
Both normal and lab Debug app variants compiled. All five selected navigation
tests passed; normal and largest-text screenshots were inspected. Independent
testing of the actual SceneKit viewer caught stale marker positions after a
camera turn. Marker projection now uses the current viewing angles directly,
with the same explicit rotation and vertical field of view as the camera.
The actual UIKit/SceneKit viewer then passed 37 synthetic checks, including
pre-render alignment, mixed turn/tilt projection, tap selection, alpha masks,
partial-scan exclusion and failed-image clearing. Four negative controls rejected
the previous projection, missing alpha/completion gates and stale image content.
These are software/synthetic
media checks; none demonstrates real floor detection or camera quality.

Private receipts are under
`/Users/pilksclaes/LocalRendpropAudits/room-tour-photo-delivery-20261001/`
and `/Users/pilksclaes/LocalRendpropAudits/photo-delivery-20261001/`.
CI runs the photo-history, room-guidance and real-browser download checks.
Release availability, exact-source CI and deployment readback will be recorded
here and in a separate build-36 receipt after delivery.

On the real phone, check:

1. Floor recognition, numbered spot alignment, manual fallback, understandable
   turn/tilt/pivot cues and all 38 automatically saved photos at one spot.
2. Early-stop labels, complete-tour preview, seams and tapping a second distinct
   saved viewpoint. A partial eight-photo export must remain visibly partial.
3. A call/background during capture, saved-tour reopening, safe export and storage.
4. New photo → declutter → stage → restyle → relaunch; verify original, earlier
   versions, current grid selection and any existing reel inputs remain intact.
5. Single/batch Files and Photos delivery, correct dimensions/crop, clean MLS
   images, captions and optional visible staging/declutter labels. Check the
   actual destination MLS's rules before advertising.

Physical-phone acceptance remains the owner's responsibility. No simulator
camera, real room, external client account or provider generation was fabricated.
