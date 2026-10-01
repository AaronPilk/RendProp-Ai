# Guided listing-photo capture — 1 October 2026

## Status

Implemented on isolated branch `fix/guided-photo-capture-20261001`, based on
the delivered internal TestFlight 34 source. Build 35 is reserved after GET-only
Apple inventory; archive, upload and availability are pending. This document
will record the actual delivery after Apple confirms it.

The owner confirmed that the Lakeview Drive listing photos were taken inside
Rendprop. The previous `CameraPicker` was a basic `UIImagePickerController`;
it did not use the video's explicit ultra-wide lens or offer leveling and
composition guidance. The five publicly linked listing images reviewed showed
cut-off room features, downward/slanted angles and uneven framing. The listing
exports do not establish the physical lens used; their original metadata was
not available.

## What changed

- Photos → Take a photo and Aerial intro → Take photo use the dedicated still
  camera, presented fullscreen. The video and spatial capture sessions are
  separate.
- Actual back ultra-wide and wide cameras provide **0.5× / 1×** selection at
  each physical device's zoom 1. Interior photos default to supported 0.5×;
  exterior photos default to 1×. A phone without ultra-wide has no 0.5× button.
- The photo session uses advertised resolution near 12MP, JPEG quality priority,
  device geometric distortion correction when supported, and continuous focus,
  exposure and white balance. It does not synthesize a wider room.
- The preview fits its camera frame rather than filling and cropping a portrait
  screen. Thirds follow the actual preview bounds. Gravity-driven controls rotate
  locally for landscape; the rest of the app retains its portrait orientation.
  The preview and shutter connections use the same frozen capture orientation.
- Simple guidance encourages landscape coverage from a corner, upright walls and
  space around the exterior. The level checks both horizon roll and upward/downward
  tilt, and cannot show green for an unavailable/face-up reading.
- Full-image review offers **Use photo** and **Retake**. Saving waits for the
  parent screen's result; a failure retains the captured image for retry.
- Permission, session interruption and unavailable hardware show actionable
  states. Foreground/lens/motion changes cannot replace a pending photo's token.
- Original and enhanced photo writes are atomic individually and paired: either
  both land or failed partial files are removed. Errors are visible. Late saves
  cannot select a cover or trigger automatic work in a changed account/workspace.

The camera keeps the captured UIImage in memory during review/retry; closing or
killing the app before a successful save discards that unsaved image. Original
and enhanced JPEG files remain in the existing listing directory after a
successful save. Existing card thumbnails still visually crop to fill; the
full-photo view preserves the complete saved frame.

## Software verification

- **105 passing executable checks** use the actual pure lens, resolution,
  orientation, level and phase policy, plus actual temporary-file success,
  collision and injected first/second write failures.
- Independent source review caught and corrected pending-shot foreground races,
  disabled Close after identity changes, and stale green level readings.
- **29 additional assertions** execute the actual extracted parent ingest and
  exterior-save functions across real asynchronous boundaries. Six negative
  controls removing individual account/session/workspace fences failed as
  expected. They cover exactly-once acknowledgements, overlap, partial batches,
  failed writes and retained local files without late cover/automatic-edit effects.
- Screenshot inspection caught truncated navigation text at the largest text
  size. Navigation/action fonts now fit their bounded controls while the main
  unavailable-state message retains full Dynamic Type scaling.
- Standalone camera typecheck against the real iOS SDK with iOS 16 deployment
  passed; application identity/theme dependencies were stubs for that check.
- Full Debug app build and **2 UI navigation tests passed**. The simulator has no
  camera; its tests exercise the honest unavailable state, exit/reopen and
  accessibility text, never a fabricated room or claimed lens-quality result.

Private evidence lives under
`/Users/pilksclaes/LocalRendpropAudits/guided-photo-capture-20261001/`.
`bash apps/ios/tests/run-photo-capture.sh` runs the pure/file checks; CI includes
them in its macOS offline audit job.

The first CI run passed 11 of 12 jobs and exposed an overly narrow opening-audio
sample in the existing browser export regression. Replaying its immutable MP4s
showed that the fixed export retained the 990 Hz opening tone, shifted by AAC
startup, while the old-await control missed the opening window. The check now
requires two adjacent 90ms samples within 0.53–0.74s; the old control must have
none. Amplitude, pitch, duration, leading silence, middle audio, transitions and
playback trace checks remain enforced. Production video-export code is unchanged.
The corrected browser regression passed locally with real synthetic MP4/AAC
exports and its old-await negative control. Final CI verification is pending.

## Phone acceptance

Install the delivered build once Apple readback is recorded, then:

1. Open a test home's **Photos → Take a photo**. Confirm 0.5× is selected on a
   phone with a back ultra-wide camera. From a corner, keep the phone upright
   and show the whole room. Compare 0.5× and 1× without moving the phone.
2. Try both landscape directions and portrait with rotation lock enabled. Check
   upright controls and photo orientation. Put recognizable objects at all four
   preview edges; verify the same edges survive review, saving and reopening.
3. Tilt down or sideways: the level must warn. Hold upright: it may turn green.
   Point at the floor: it must not claim a level room shot.
4. **Retake**, then **Use photo**. Reopen Photos and the full before/after view;
   confirm sharp details, full framing and both saved files. Card thumbnails may
   crop visually. Check an exterior via **Aerial intro → Take photo** starts 1×.
5. Deny Camera permission and check recovery through Settings. Test a call,
   background/foreground and rapid lens changes; a pending capture must finish
   into review or display an error that allows retry/close.
6. Complete the existing phone/Studio sync and account/team acceptance checklist
   in [CORE-READINESS-20261001.md](CORE-READINESS-20261001.md). This native fix does
   not replace those release gates.

Actual sensor field of view, preview-to-JPEG matching, lens selection, focus,
lighting quality and real interruptions remain physical-phone acceptance.
Spatial reconstruction remains off; this release changes no GPU spend, provider
configuration, database schema, prices or Apple subscription offers.

## Sources

- [Owner-linked Zillow listing](https://www.zillow.com/homedetails/1405-Lakeview-Dr-Pineville-NC-28134/6308990_zpid/).
- [Apple photo dimension contract](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/maxphotodimensions).
- [Apple advanced camera settings and lens correction](https://support.apple.com/en-ie/guide/iphone/iphb362b394e/ios).
- Installed iOS SDK headers for physical device types, geometric distortion
  correction, photo dimensions and capture-connection orientation. Apple Camera's
  own Settings preferences are not assumed to configure Rendprop's session.
