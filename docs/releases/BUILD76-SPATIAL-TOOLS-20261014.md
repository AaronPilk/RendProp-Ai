# Rendprop 1.0.4 (76) — spatial tools TestFlight

Build **76** is available in the existing **Rendprop team** internal TestFlight group. Apple confirms **VALID**, **INTERNAL_ONLY**, **IN_BETA_TESTING**, external state **NOT_APPLICABLE**, group membership and exact testing notes. App Store **1.0.4 (74)** remains **WAITING_FOR_REVIEW**, with **AFTER_APPROVAL** automatic release. No App Store review, attachment, metadata or account was changed.

## Two tools, consistent entries

**Floor plans & measurements** replaces the duplicate Floor plans, Measurements and 3D plans cards on Home and listings. Its screen offers phone scanning, manual room dimensions and existing-plan upload. RoomPlan scanning requires LiDAR and produces simplified room geometry and top-down plans. Manual entry starts with a named room's length and width; irregular building outlines sit under Advanced. Existing geometry, measurement forms, saves, context checks, rescan confirmation, imports and exports are preserved.

**3D tours** opens one hub from Home, a listing or Settings → TestFlight lab. Guided capture, saved photographic previews and exports work independently of the cloud capability. Walking capture is a separate advanced option that saves overlapping photos and camera positions. Both local libraries are device-wide, not yet attached to the selected listing or published. The separate listing-scoped cloud workflow appears only after a fresh enabled server answer; no reconstruction provider was enabled by this release.

Test 3D tours first: capture one well-lit room from one viewpoint, finish its 38 photos, preview, reopen, switch saved viewpoints and export the original scan. The look-around preview and walking dataset do not establish completed Matterport-style geometry. Real reconstruction and measurement quality still require physical testing.

## Source and evidence

Signed source: `7a8c08a84030dbf26d38c53eabd2c554837e08d1`, branch `testflight/spatial76-20261014`. Normal/lab route checks passed with six compiled negative controls, alongside bounded background-admission checks. Native UX checks passed 16 runs; independent source review checked 12 fences and rejected six altered-source bypasses. Measurement models passed 628 assertions. Twelve measurement functions/forms and the existing RoomPlan capture, geometry and presentation/export bodies match the prior build.

A new signed physical-device Release archive passed build/version, signature, actual lab compiler flag, DEBUG absence, dSYM UUID and exact bundled introduction asset checks. One Xcode internal-only export/upload succeeded. Xcode retained no exported IPA, so no exported-package byte proof is claimed. The companion JSON binds source, scoped test receipts, archive, upload, activation and Apple readback. These checks do not claim a fresh full CI or physical camera pass.

iPhone Mirroring returned ScreenCaptureKit capture error -3811. Build 76 installation, its actual phone screens, capture usability, dimensions, tracking and model/preview/export quality remain pending physical acceptance. Subsequent photo-import, listing-order and Leads-tab feedback arrived after this upload and belongs to a following build.
