# Rendprop 1.0.4 (75) — internal spatial TestFlight

Build **75** is available in the existing **Rendprop team** internal TestFlight group. Apple readback confirms **VALID**, **INTERNAL_ONLY**, **IN_BETA_TESTING**, external state **NOT_APPLICABLE**, group membership and the exact testing notes. This artifact cannot be submitted to the App Store. Submitted **1.0.4 (74)** remains **WAITING_FOR_REVIEW**, with **AFTER_APPROVAL** automatic release; no App Store attachment, metadata, review or account was changed.

## What to test

- Home **3D plans**, or a real listing's **3D floor plan**, opens the existing **Measurements & plans** screen. **Start scan** opens RoomPlan on a LiDAR-capable iPhone. Test real room capture, saved 2D/3D previews and exports. Manual outline and blueprint tools remain inside this experimental screen. A successful rescan replaces the saved plan after confirmation.
- Home **Guided room tour**, or Settings **TestFlight lab**, provides existing local capture experiments. Guided capture takes 38 photos per viewpoint and creates a photographic look-around preview. Walking capture saves photos and poses locally. These previews are not accepted Matterport-style geometry or published 3D tours.
- The separate Measurements and Aerial cards remain Coming soon. No paid reconstruction provider, production spatial capability or server flag was enabled. The regular App Store project remains build 74.

## Source and verification

Signed source: `8b1f090cb9edc7167841b2179c8a47955aecb63f` on `testflight/spatial75-20261014`. The six-file change adds lab-only RoomPlan entry points, updates the explicit spatial overlay to 75, regenerates only its project, and adds scoped boundary tests. The normal project and bundled 55-second introduction are unchanged.

Current source-bound public/lab route and background-boundary checks passed. Floor-plan routing includes four compiled negative controls; preserved Aerial boundaries include five. A new signed physical-device Release archive passed signature, build/version, actual compiler lab flag, DEBUG absence, lab-source inventory, dSYM UUID and exact introduction asset checks. One Xcode internal-only export/upload succeeded; no fallback upload or duplicate archive was used. Automatic archive development signing is recorded separately from Apple's accepted internal distribution. Xcode did not retain an exported IPA, so no exported-IPA byte verification is claimed.

The companion JSON binds exact source, archive, delivery and activation receipts. All 128 preserved native evidence files match their original hashes. These are targeted checks and a new signed archive, not a claim that a fresh full CI run or physical scanning passed.

## Physical acceptance still to perform

iPhone Mirroring currently reports that the phone is in use. Build 75 installation, its on-phone entry points and real room/model quality have therefore not been accepted on the phone in this release record. TestFlight delivery is verified through Apple readback. Actual scan quality, tracking, dimensions and model/export usability remain the purpose of this experimental build.
