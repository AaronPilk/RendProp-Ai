# iPhone TestFlight checklist — private spatial capture experiment

**Field-test update, 2026-09-10:** the owner installed **1.0 (17)** and observed
capture stopping after zero or three saved frames with `Invalid c2w homogeneous
row.` A local fix exists in commit `f789abc`; it has **not** been uploaded to
TestFlight. Do not treat retrying build 17 as testing the fix, and do not delete
or reinstall Rendprop. Preserve the attempts. See
`capture-ios/POSE-PRECISION-FIX-2026-09-10.md` for the reproduction and evidence.

The procedure below is the acceptance checklist for a fresh capture once an
updated internal build is separately authorized and delivered. The owner's
Apple freeze remains in effect. Build 17's historical delivery details are in
`INTEGRATION-VERIFICATION.md`; that record is not a new release action or a claim
that the physical capture passed.

This is an experimental, local one-room capture inside the existing **Rendprop** app—not a separate app or a finished spatial-tour product. The integrated app requires **iOS 16+** and an iPhone supporting ARKit world tracking. **LiDAR is not required.** Start with the owner's iPhone 15 Pro; older-device performance is not yet proven.

## 1. Open and prepare

- Open **Rendprop → Settings → Spatial capture (TestFlight)**. If the entry is missing, report the installed app version/build; do not delete or reinstall Rendprop to troubleshoot.
- Choose one private room with good, steady lighting. Avoid moving people, mirrors, blank walls as the only subject, and sensitive items such as mail, family photographs, or prescriptions.
- The feature saves room photos and ARKit-estimated camera poses locally, excludes its capture storage from device backups, and makes no automatic upload. Keep enough free storage for several hundred images. Do not erase existing Rendprop data to make room.

## 2. Capture one room

1. Tap **Start new room** and allow camera access if prompted. Wait for normal tracking; limited-tracking frames are skipped.
2. Walk slowly around the room, looking toward walls, floor, furniture, and corners from overlapping viewpoints. Move your position—not just rotate in place. Avoid fast turns and blur.
3. Aim for **150–250 saved frames**. The app saves at most two frames per second. Do not reach the **400-frame or 10-minute** limits.
4. Tap **Stop and save**, then wait for validation to finish. Stop remains available during limited tracking. Note the final frame count and any message.

## 3. Export and verify recovery

1. Tap **Export completed capture**. The app checks the manifest, every JPEG, and every sidecar before opening the Files picker.
2. Copy the **entire UUID-named folder** to a local Files destination, preferably **On My iPhone**. Do not choose iCloud Drive or another cloud provider unless that transfer is specifically intended and authorized. If no local destination is available, report that instead of silently switching to cloud storage.
3. Tap **Done**, reopen the lab from Settings, then open **Saved captures**. Find the same attempt by its date, frame count, status, and UUID.
4. Close and relaunch Rendprop, return to **Saved captures**, and select that completed attempt again. Export should work after another full validation. The list's “complete (not yet verified)” label describes its stored status before this fresh check.
5. If there are more than 50 attempts, use **Previous / More** to reach other pages. Captures are shown in storage order, not newest-first.

The exported folder should contain `manifest.json`, `images/`, and `frames/`. Keep these together and unchanged. File validation is not proof that reconstruction will succeed.

## 4. Small interruption check

After preserving the good capture, start a separate short attempt and leave the capture screen with **Done**, or background the app while recording. Reopen **Saved captures**: the attempt should remain present as **interrupted**, not as a completed room. Start a fresh attempt to retry; this experiment does not resume or merge interrupted rooms.

Expected failures are explicit:

- Denied camera permission: enable camera access in Settings to retry.
- Unsupported hardware or simulator: no AR preview, successful capture, or completed export.
- Too few frames/feature points, interruption, cap reached, storage errors, or corrupt files: no successful export. Partial files remain preserved; do not delete the app or clear its data.
- A saved-list error is an error, not proof that captures are gone. Screenshot it and report it.

## 5. Send back evidence

Send the app version/build, iPhone model, iOS version, capture UUID, saved frame count, approximate recording duration, exported folder size, and whether export worked after reopening/relaunching. Include screenshots of the final capture message and Saved captures entry, plus any permission, interruption, heat, responsiveness, or storage issue.

Keep raw room imagery private. Retain the full capture folder and transfer it only through an agreed private method when requested; do not publish it or send it to a GPU provider yet.

**Still unproven:** GPU reconstruction using these recorded poses, PLY/SOG output, navigable viewer quality, and real-phone browser frame rate. This test collects the evidence needed for that next step; it does not deliver finished spatial tours.
