# iPhone 3D capture delivery September 30 2026

The owner clarified that a usable Matterport-style 3D walkthrough is the primary
product goal. Further Home redesign and reel expansion are paused. The immediate
next test is a new room capture using the motion-blur guard already integrated
into main; the earlier delivered phone build did not contain that guard.

## Available in TestFlight

Rendprop **1.0.3 (32)** is available in the existing internal **Rendprop team**
TestFlight group, verified at **2026-09-30 18:32:11 UTC**. Apple reports `VALID`,
`INTERNAL_ONLY`, `IN_BETA_TESTING`, not expired, and confirms that exact build in
the group's relationship. Build ID: `e51f5e2e-102f-4a5b-9a12-c8db59b0b350`.

The owner explicitly requested this TestFlight upload, superseding the earlier
App Store Connect restriction for this operation. One upload succeeded at
18:29:03 UTC. Apple records uploadedDate as 18:30:01 UTC. Testing notes for this
build were updated and read back. No new tester invitation, group-membership
write, App Store version attachment or App Review submission occurred.

The Release archive uses the explicit `RendpropSpatialTestFlight` scheme from
`79ee6834ae680424e831879cd5330ad861cd3f2e` on
`release/ios-spatial-phone-20260930`. Its 115 source-file hashes match the earlier
signed native source `3f29adf`. The archive explicitly overrides the build number
to 32; committed source specs remain 31. Export enforces internal testing only
and disables automatic build renumbering. Existing bundle/team identity and
Apple sign-in entitlement were verified, as were the strict code signature,
capture-lab compilation flag, blur-source inclusion and resource exclusions.

Archive executable SHA-256:
`5e56bc4c79246109b9f5d92a99bb28c74d98cf591ab0651d0937506a7df6297f`.
The [delivery receipt](../releases/TESTFLIGHT-32-20260930.json) records Apple state,
artifact hashes and evidence limits. Private archive, source manifest, sanitized
upload log and Apple readbacks are retained under
`/Users/pilksclaes/LocalRendpropAudits/ios-spatial-phone-20260930/testflight/`.

The earlier 16:15 UTC development-signed local candidate and its
`signed-build-receipt.json` remain historical evidence in the parent directory.
No direct phone installation occurred. Actual installation and camera acceptance
remain unverified; the owner can now update through TestFlight.

## Phone test

Update to **1.0.3 (32)** in TestFlight, then open
**Settings → TestFlight lab → Spatial capture (TestFlight)**. The lab works while
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

- All 12 CI jobs passed for the archived source `79ee683`.
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
- The PR's initial CI run passed the native gates but exposed a brittle Studio
  export test: its whip appeared two frames later than one exact sample time.
  The fixture now requires the actual spatial transition within the existing
  bounded timing window and intact shots before/after. All 16 local browser
  checks pass, and a no-whip renderer negative control fails as intended. This
  changes test code only; the signed native artifact remains unchanged.

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
