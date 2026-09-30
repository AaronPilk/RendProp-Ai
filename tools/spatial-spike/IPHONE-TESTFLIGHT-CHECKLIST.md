# iPhone checklist — one-room spatial recapture

**Updated September 30, 2026.** This test checks the improved motion-blur guidance
and collects a sharper room capture for reconstruction. It runs locally inside
the existing **Rendprop** app. It does not upload images, generate a 3D room,
publish a tour, or enable the production 3D service.

The current delivery candidate is the explicit spatial overlay: **1.0.3 (32)**,
successfully built and development-signed on September 30 for local installation.
Signature and bundle identity checks passed; installation is awaiting the owner's
confirmation and an unlocked phone. See the [build record](../../docs/handoff/CODEX-IOS-SPATIAL-PHONE-20260930.md).
Confirm the installed version before testing. No TestFlight upload or App Store Connect operation is
part of this delivery; the Settings entry still uses its existing “TestFlight”
label. An older build is not evidence for the current blur guard.

The integrated app requires **iOS 16+** and an iPhone supporting ARKit world
tracking. **LiDAR is not required.** Use the owner's iPhone 15 Pro first;
older-device performance is not yet proven. A simulator cannot perform this test.

## 1. Open and prepare

- Open **Rendprop → Settings → TestFlight lab → Spatial capture (TestFlight)**. This local entry works while the production 3D service is off; the normal Home 3D tile can remain hidden. If the lab entry is missing, report the installed app version/build. Do not delete or reinstall Rendprop to troubleshoot.
- Choose one private room in daylight and turn on its lights. Open blinds where practical. Avoid moving people, mirrors, blank walls as the only subject, and sensitive items such as mail, family photographs, or prescriptions. Use the previously captured room if practical so the change can be compared.
- The feature saves room photos and ARKit-estimated camera poses locally, excludes its capture storage from device backups, and makes no automatic upload. Keep enough free storage for several hundred images. Do not erase existing Rendprop data to make room.

## 2. Capture one room

1. Tap **Start new room** and allow camera access if prompted. Wait for normal tracking; limited-tracking frames are skipped.
2. Take small steps around the room with slow turns. Keep some of the same furniture, doorway, or corner in view as you move. Include upper wall corners, lower surfaces, and the floor; revisit corners from another position. Pause near bright windows until the picture settles. Standing in one spot and spinning does not provide the same coverage.
3. Follow the live guidance. **Slow down** means reduce your turning speed; **More light** means add light and move more slowly. **Hold steady** means motion or exposure measurements are unavailable. Such frames are skipped. Confirm that saving resumes when the warning clears; Stop remains available while the app waits.
4. Aim for **300–350 saved photos**, then stop once the room has overlapping coverage. The app saves at most two photos per second and skips blurry or repeated viewpoints, so the counter need not rise continuously. More photos alone do not prove coverage.
5. Tap **Stop and save**, then wait for validation to finish. Note the final photo count and message. At **400 photos or 10 minutes**, capture stops automatically and drains pending writes. A valid capture can still be exported after this normal limit; check coverage before using it. Do not deliberately fill the cap.

The current provisional guard warns at predicted rotational smear of **3 pixels**
and skips frames at **4 pixels**. Long exposure (about **1/60 second or longer**)
changes the warning to **More light**. Missing motion/exposure measurements or a
gap over 0.1 seconds are not treated as a sharp frame. These estimates do not
measure every cause of blur; inspect the exported photos as well.

## 3. Export and verify recovery

1. Tap **Export completed capture**. The app rereads the manifest, every JPEG, and every sidecar before opening the Files picker. It requires a complete capture, 20–400 photos, ARKit feature points, and the exact expected files. These are integrity minima, not the recommended capture target or a 3D-quality pass.
2. Copy the **entire UUID-named folder** to a local Files destination, preferably **On My iPhone**. Do not choose iCloud Drive or another cloud provider unless that transfer is specifically intended and authorized. If no local destination is available, report that instead of silently switching to cloud storage.
3. Tap **Done**, reopen the lab from Settings, then open **Saved captures**. Find the same attempt by its date, frame count, status, and UUID.
4. Close and relaunch Rendprop, return to **Saved captures**, and select that completed attempt again. Export should work after another full validation. The list's “complete (not yet verified)” label describes its stored status before this fresh check.
5. If there are more than 50 attempts, use **Previous / More** to reach other pages. Captures are shown in storage order, not newest-first.

The exported folder should contain `manifest.json`, `images/`, and `frames/`.
Keep the entire UUID folder together and unchanged, including every JSON sidecar;
the sidecars preserve exposure and camera motion needed for the quality check.
Do not move, rename, edit, or add files inside it. File validation is not proof
that reconstruction will succeed.

## 4. Small interruption check

After preserving the good capture, start a separate short attempt and leave the capture screen with **Done**, or background the app while recording. Reopen **Saved captures**: the attempt should remain present as **interrupted**, not as a completed room. Start a fresh attempt to retry; this experiment does not resume or merge interrupted rooms.

Expected failures are explicit:

- Denied camera permission: enable camera access in Settings to retry.
- Unsupported hardware or simulator: no AR preview, successful capture, or completed export.
- Too few photos/feature points, interruption, storage errors, or corrupt files: no successful export. Partial files remain preserved; do not delete the app or clear its data.
- A normal 400-photo/10-minute stop is exportable only after full validation. Historical attempts marked `limit_reached` remain blocked; the app does not relabel old incomplete captures.
- A saved-list error is an error, not proof that captures are gone. Screenshot it and report it.

## 5. Send back evidence

Send the app version/build, iPhone model, iOS version, capture UUID, saved photo
count, approximate recording duration, exported folder size, and whether export
worked after reopening/relaunching. Note the room's lighting and whether saving
resumed after slowing down or improving the light. Include screenshots of the
final capture message and Saved captures entry, plus any permission, interruption,
heat, responsiveness, or storage issue. Check a few full-resolution photos near
windows, doorways, and upper corners for visibly sharp edges and overlapping views.

Keep raw room imagery private. Retain the full capture folder and transfer it only through an agreed private method when requested; do not publish it or send it to a GPU provider yet.

**Next acceptance step:** run capture-quality checks on the new export before
any GPU allocation, then evaluate a source-bound reconstruction against fixed
held-out images and visual review. No prior room reconstruction was accepted.
This phone test alone does not establish a usable 3D model, navigable viewer
quality, or real-phone browser performance.

## Historical evidence

Build **1.0 (17)** stopped after zero or three frames with `Invalid c2w homogeneous
row` on September 10. The reproduction and repair are recorded in
[the pose-precision audit](capture-ios/POSE-PRECISION-FIX-2026-09-10.md), with
[historical delivery evidence](INTEGRATION-VERIFICATION.md). Those records describe
the earlier build; they are not the instructions or delivery receipt for this
recapture. Preserve those attempts alongside the new capture.
