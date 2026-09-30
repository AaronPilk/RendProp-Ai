# iPhone 3D capture delivery September 30 2026

The owner clarified that a usable Matterport-style 3D walkthrough is the primary
product goal. Further Home redesign and reel expansion are paused. The immediate
next test is a new room capture using the motion-blur guard already integrated
into main; the earlier delivered phone build did not contain that guard.

## Signed build ready

Rendprop **1.0.3 (32)** built successfully in Release using the explicit
`RendpropSpatialTestFlight` scheme and the existing local Apple Development
certificate/profile. Code-signature validation passed, and the bundle identity
remains `com.rendprop.app` with the existing team and Apple sign-in entitlement.
The command-line build number is 32; the repository's source specs remain 31.
This is a development-signed local-install candidate, not a TestFlight upload or
an App Store submission. No App Store Connect operation or provisioning update
was requested. Device installation is pending owner confirmation and unlock.

Source commit: `3f29adf5f5976856ddbce17c178ecc013814f8fc`.
Branch: `release/ios-spatial-phone-20260930`.
Build completed and signed receipt recorded at `2026-09-30T16:15:07Z`.
Executable SHA-256:
`2c831e47ec4b97452db17dac5034da8b7eff5ea260610104c11948bad1e5662d`.

Private local artifact and source-hash receipt:

- `/Users/pilksclaes/LocalRendpropAudits/ios-spatial-phone-20260930/DerivedData/Build/Products/Release-iphoneos/Rendprop.app`
- `/Users/pilksclaes/LocalRendpropAudits/ios-spatial-phone-20260930/signed-build-receipt.json`

A paired iPhone 15 Pro was visible. The read-only app-version query failed because
the phone was locked. No installation or camera operation has occurred.

## Phone test

Open **Settings → TestFlight lab → Spatial capture (TestFlight)**. The existing
entry label also appears in this local development build. The lab works while
the production runtime is off, saves photos and measured camera poses locally,
and makes no automatic upload or GPU call.

Use one room in daylight with lights on, slow translations, overlapping views,
and pauses at windows/corners. Aim for 300–350 accepted photos. The guard warns
at 3 px predicted rotational smear, skips at 4 px, and rejects unavailable
motion/exposure measurements. Then Stop and save, export the entire capture
folder, and verify it can reopen. Follow the [phone checklist](../../tools/spatial-spike/IPHONE-TESTFLIGHT-CHECKLIST.md).

These are provisional capture checks, not a reconstruction quality certificate.
Inspect the new images and run the independent adapter quality check before
renting a GPU. Keep the evaluation set fixed within each controlled experiment.

## Verification and accompanying repairs

- All 22 Phase 1 source/executable-Swift gates passed with no skips.
- Spatial portable checks passed: 161 capture/schema/JPEG assertions, 3,076 pose
  assertions, seven adversarial cases and eight JPEG resource cases. Quality
  selector/sampler checks and deliberate failure controls passed as expected.
- Ordinary JWT refresh no longer invalidates the identity of an in-flight
  Studio save. Nineteen executable auth/writer assertions pass; the old getter
  fails the lost-receipt negative control. Explicit sign-in/out and account
  changes still invalidate stale work.
- Reopening a completed saved video take reuses its verified joined movie.
  Forty-nine synthetic media checks pass; damaged, missing or mismatched cached
  joins rebuild without overwriting originals.
- This release was built for a generic physical iOS device and signed locally.
  No camera, AR tracking, phone installation or real-room quality is claimed.

The original standalone proof logs and receipts remain outside Git. The signed
build receipt binds the source files and build log. The broader native adoption
checks passed separately; anonymous-to-Apple transfer of production plans,
imported clip libraries and unfinished spatial journals remains a documented
gap and is not fixed here. For this controlled recapture, use the existing local
lab rather than the production upload queue.

## Reconstruction state and limits

All seven September 23–24 frozen-capture ablations remain NO-GO. No winning
runtime profile exists. Heavy motion blur was measured in the source capture;
the new phone capture must test whether the guard improves it. The original
September 23 folder contains no new blur-policy telemetry and has not been
silently rewritten or retrained.

The last reconciled total is **$19.98118436 of the $25 ceiling**. This work made
no GPU/provider call and changed no spatial runtime, worker, database or
generation flag. The automatic production queue remains disabled until accepted
output and its operational checks exist.

The local-footage reel patch is preserved separately on
`feat/ios-completion-20260930` at `904cab9`. It passed a 15-check encoded-media
regression but awaits full iOS/UI validation; it is excluded from this build.
