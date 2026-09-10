# Phase A local iPhone capture

This local capture implementation supplies the input for the one-room spatial
spike. The owner chose delivery inside the existing Rendprop TestFlight app
(`com.rendprop.app`), using the explicit `SPATIAL_CAPTURE_LAB` build overlay.
The normal Rendprop project does not include the shared capture implementation.
The capture feature adds no production-service imports, credentials, analytics,
networking, account/purchase gate, or package dependency.

The standalone diagnostic app remains available as
`com.rendprop.spatialspike.capture`, but is **not** the selected TestFlight target.
These local verification scripts do not sign for distribution or upload anything.

## Rendprop TestFlight integration

`apps/ios/project-spatial-testflight.yml` owns the opted-in build. Its explicit
shared source list is `Sources/SpatialCaptureViewController.swift`,
`Sources/CaptureControls.swift`, `Sources/CaptureModel.swift`,
`Sources/CaptureRecorder.swift`, `Sources/CaptureArchive.swift`, and `Sources/RasterWriter.swift` from this
directory. Never include `Sources/App.swift`: its standalone `@main AppDelegate`
would collide with Rendprop's existing app entry point. Do not add this whole
directory or its scripts/tests as resources.

`apps/ios/Rendprop/Capture/SpatialCaptureLabView.swift` is entirely fenced by
`#if SPATIAL_CAPTURE_LAB`. It exposes `SpatialCaptureLabView()` for a Settings
full-screen cover, with an experimental local-only description and a labelled
**Done** action. The wrapper needs no environment object, account, entitlement,
network client, or production-service dependency. The overlay preserves
Rendprop's existing minimum OS, icon, privacy manifest and global capabilities;
do not copy the standalone app's ARKit-required capability into the normal app.

Done closes the controller synchronously before dismissing. SwiftUI teardown and
UIKit removal also close it idempotently. Closing while preparing or recording
requests `interrupted`, pauses/detaches/releases the AR session, restores the
previous idle-timer value, and preserves all files. An already-requested stop/save
continues draining without changing its requested status. A terminal `closed`
control state prevents late permission, recorder-start, completion, or export
callbacks from starting a renderer or presenting a picker after dismissal.
Reopening creates a fresh controller and a fresh capture epoch; it never resumes
an interrupted room. Interactive dismissal is disabled, but Done always remains
available. No RoomPlan session is shared or changed by this Phase A integration.

**Saved captures** reopens local attempts after dismissal or app relaunch. Its
50-entry pages show creation date, frame count, stored status, and the capture's
UUID in storage order; Previous/More reaches all pages without retaining an
unbounded list. Unreadable attempts remain visible, and a listing error is not
reported as an empty archive. Selecting any attempt re-reads its manifest and
validates all JPEGs/sidecars before export; incomplete or corrupt attempts cannot
be exported as completed captures. There is no erase action or network request.

Export also requires the exact declared file set: `manifest.json`, `images/`,
`frames/`, and their contiguous frame files. Symlinks, extra/orphan files (including
desktop-added metadata), missing files, and unexpected directories prevent export;
they are preserved, never deleted or silently excluded. Manifest reads are bounded
to 256 KiB and sidecars to 16 MiB before JSON decoding. The sidecar bound is tested
with the recorder's maximum 50,000 points, full-width IDs, and finite Float extremes.
These are static saved-file integrity checks, not an atomic snapshot or a security
guarantee against another process mutating files between validation and copying.

The Captures parent directory is excluded from backups before any capture files
are written. The flag is re-applied and read back when existing captures are
listed or exported; failure prevents capture/export instead of silently relaxing
the local-storage promise. Preserve important captures with an explicit export:
these diagnostic files intentionally do not participate in device backups.

## Build and verification

For the standalone diagnostic target, run `bash verify.sh --build`. The script asserts that new
symbols exist, compiles the portable Swift checks, confirms an intentional failing
assertion exits nonzero, runs the positive and negative checks, and builds an
unsigned Release iPhone app with XcodeGen in a unique `/tmp` DerivedData directory.
The built bundle is checked for the intended identifier, minimum OS, ARKit
capability, app icon, privacy manifest, and absence of source/script resources. Omit
`--build` for just the checks. No device is installed, launched, or scanned by the
script. A successful build or synthetic raster test is not a physical room proof.

For an optional coordinated standalone development run, generate its project with
`xcodegen generate`, open `SpatialSpikeCapture.xcodeproj`, select the owner's
development team and the intended iPhone, and run this separate app. There is no
provisioning team hardcoded. A real ARKit world-tracking iPhone is necessary;
LiDAR is not required for this Phase A harness. Do not replace or reinstall the
shipping Rendprop app. The minimum deployment target is iOS 15.0, matching the
newest API required by this harness (`UIButton.Configuration`). The target is
iPhone-only and declares `arm64` and `arkit` required capabilities. Runtime
`ARWorldTrackingConfiguration.isSupported` is checked **before** asking for
camera access or allocating an AR renderer. No LiDAR-only API is used.

This is an intended compatibility range, not proof of performance on every older
iPhone. The currently available simulator runtime is iOS 26.4; minimum-iOS-15
deployment can be checked by compilation, not by an iOS 15 runtime test here.
Physical capture, sustained memory/thermal behavior, camera permission handling,
and export still require a coordinated device run, initially on the owner's
iPhone 15 Pro through TestFlight. That physical AR validation follows delivery;
it is not a pre-upload gate. No simulator can supply AR room evidence.

For asserting simulator UI checks, supply a **separately owned disposable**
simulator UUID to `bash verify-ui.sh <UUID>`. The script builds/tests Release in a
unique temporary directory and requires exactly three passes, zero failures, and
zero skips or expected failures, overall `Passed`, and a total of three tests in
the result bundle. Before trusting results, its checker must reject ten known
invalid summaries in subprocess tests. It never creates, erases, or shuts down a
simulator. Tests cover idle controls, unsupported start without a camera prompt
or AR preview, and relaunch without inventing saved frames. Portable checks cover
the actual start/stop/save/export control policy, including rejecting restart
during saving or export validation. Neither set asserts successful physical
capture or real export; the app contains no mock-completion launch mode.

## Packaging and privacy

The standalone app icon is an unchanged copy of the owned Rendprop
`apps/ios/Rendprop/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png`.
No third-party design asset or SDK was added. There are no app entitlements,
sign-in, associated domains, background capture, or hardcoded signing team.

The standalone `Resources/PrivacyInfo.xcprivacy` declares no tracking and no collected data: room
images, poses, device product identifier, and OS version stay in this app's local
Documents directory until the operator deliberately exports them. The app makes
no network request. Export invokes the system document picker; choose a local
destination unless another transfer destination has been authorized.

The current required-reason API audit found no listed API in app source. Reading
the app's own JPEG **file size** uses `URLResourceKey.fileSizeKey`; it does not
read file timestamps, disk capacity, system uptime, or UserDefaults. `Date()` is
wall-clock time and `uname` records a hardware product type, not a serial or UDID.
The accessed-API array is therefore empty, not copied from the shipping app.
Re-audit this declaration whenever storage or timing code changes.

## One-room operator run

1. Clear moving people from the room, turn on adequate light, and keep the phone
   steady while tracking initializes. Tap **Start new room**.
2. Walk slowly around the room looking at the walls, floor, objects, and corners
   from overlapping viewpoints. Translation matters; standing in place and
   spinning does not establish useful baselines. Avoid mirrors and motion blur.
3. Aim for roughly 150–250 saved images, then tap **Stop and save**. At most one
   normal-tracking frame is selected every 0.5 seconds. The stop control always
   remains available, including when tracking is limited.
4. **Export completed capture** validates every file before presenting the system
   folder-copy picker. Copy the entire UUID directory to the Mac by a user-chosen
   local method. Reopen **Saved captures** to export a prior completed room after
   closing or relaunching. The standalone diagnostic target additionally exposes
   Documents/Captures through Finder file sharing; Rendprop does not need to expose
   its other documents. Do not upload room images
   anywhere until the owner has selected the GPU destination and authorized it.

There are hard caps of 400 frames, ten minutes, and 50,000 feature points per
frame. Hitting a cap preserves files with `limit_reached` or `failed`, which is
not exportable as successful input. Stop normally before reaching a cap.

Backgrounding, a phone call, AR session interruption, or ARKit relocalization
ends this capture with `interrupted`; there is no resume or merge in Phase A.
Start a new UUID capture after returning. A crash leaves the prior directory and
`recording` manifest intact for diagnosis; the app never treats it as complete.
The app does not delete previous attempts. These are intentional spike limits,
not the resumable multi-room behavior required in Phase B.

## Files and coordinate contract

Each capture UUID is one AR world-coordinate epoch:

```
<session UUID>/
  manifest.json
  images/000001.jpg
  frames/000001.json
  ...
```

`manifest.json` has format `rendprop-arkit-capture`, schema version `1`, status,
session identifier, coordinate conventions, device/OS description, cadence/caps,
saved byte count, feature-point observation count, skipped-frame counts, and an
ordered `frames` array of relative JSON sidecar paths. The training adapter must
require `status == "complete"`; app export additionally requires at least 20
saved images and one feature-point observation. These are file-validity minima,
not a reconstruction-quality guarantee. The training adapter separately requires
at least 100 distinct usable seed points and 5 cm of camera translation, along
with its strict camera/image checks. The `device_model` also includes the device's
hardware product identifier from `uname` (for example `iPhone17,3`), not a serial,
UDID, user-assigned device name, or other persistent personal identifier.

Each sidecar stores `image` relative to the capture root, `session_id`,
`camera_to_world`, `intrinsics`, `image_resolution` (`width`, `height`),
`timestamp`, `tracking_state` (`state`, nullable `reason`),
`raw_feature_points` (`id` decimal string, `position` world XYZ), exposure duration
in seconds, exposure offset in EV, and world mapping status. Only `.normal`
tracking frames are admitted; raw feature-point absence is an empty array.
UInt64 point IDs are strings to avoid JavaScript number precision loss.

The JPEG contains the native sensor raster of `ARFrame.capturedImage`. It is
never rotated, mirrored, resized, or cropped to match the portrait preview.
The actual JPEG EXIF orientation is explicitly **1** and checked after encoding.
Color converts from the captured pixel buffer to sRGB at JPEG quality 0.92.
There is no original EXIF dictionary copy (which could contain unrelated data).
Raster width/height must exactly match `ARCamera.imageResolution`, and remain
constant throughout the capture; the per-frame K remains copied verbatim.

Both matrices are **nested mathematical rows**, serialized as
`json[row][column] = simdMatrix[column][row]`. `camera_to_world` is the raw
`ARCamera.transform`: right-handed world coordinates, gravity-aligned Y up,
metres; native camera X right, Y up, Z backward (visible points lie along -Z).
There is no transpose, inversion, axis change, pose optimization, world
recentering, display transform, half-pixel adjustment, or intrinsics scaling in
capture. A training camera convention change belongs solely in the documented
adapter. The local SDK describes the intrinsic origin at the upper-left pixel's
center while Apple's web wording says image top-left; preserving K numerically
avoids silently imposing an unverified half-pixel correction.

Image, camera, and estimated ARKit feature points are copied from the **same
ARFrame** before asynchronous disk work. Points are initialization hints; ARKit
does not promise point-cloud stability or a complete surface model. Pose drift,
weak texture, blur, rolling shutter, autofocus/calibration behavior, and limited
point coverage still need to be evaluated on the actual room.

## Memory and write behavior

A serial AR delegate queue only admits a frame if a nonblocking single-slot
semaphore is available. Disk encoding runs on a separate serial queue. At most
one captured pixel buffer plus its metadata is retained by the exporter; full
`ARFrame` objects are never retained. Other candidate frames are counted as busy
and skipped. Core Image uses one context without intermediate caching; each
write and each validation pass uses an autorelease pool. The cap bounds stored
sidecar count and prevents an unbounded capture.

Native image safety limits are **8192 pixels per axis, 16,777,216 total pixels,
and 64 MiB encoded per JPEG**. The preferred 30 fps, at-most-1920-wide video
format is unchanged. These limits also admit 3840×2160 and 4032×3024 dimensions;
this is policy coverage, not proof those formats are available on every phone.
The local ARKit SDK declares the first supported video format as the default,
without a universal numeric maximum. The selected configuration is therefore
checked before starting AR, including the fallback when no preferred format is
found. An oversized future/default format fails visibly and preserves the
attempt; no image is resized, cropped, or recalibrated to make it fit. The same
dimension policy runs before native encoding and on frame/export validation.

The pixel cap corresponds to at most 64 MiB of tightly packed 8-bit RGBA raster;
the encoded cap generously allows four bytes per pixel at that ceiling for the
quality-0.92 JPEG encoder. These are input/raster bounds, **not** a guarantee of
total ImageIO/ARKit process memory or performance on older iPhones. JPEG files
are read in bounded chunks before ImageIO receives their data. Decoded-image
caching is disabled during metadata inspection; one JPEG image, 8-bit depth, orientation 1, calibrated dimensions,
axis and pixel count are required before full decode. The decoded dimensions
and depth are then checked again. Count/read-limit arithmetic rejects overflow.

Portable JPEG-resource tests use sparse padding and edited small JPEG headers.
They exercise the production metadata preflight without decoding an excessive
raster; they do not prove camera output, physical-device memory, or room quality.

An image is encoded to a unique partial path and validated, then renamed into
place. The paired sidecar is written atomically next, then the manifest advances
atomically last. Stopping closes frame admission immediately and waits for the
single pending write before finalizing status. Storage errors fail closed and
preserve partial files. Orphan or partial files are diagnostic evidence and are
never named as successful frames in a final manifest.

## Existing RoomPlan integration findings (no shipping changes)

The shipping `RoomScanController` lives at
`apps/ios/Rendprop/Screens/FlythroughDetailView.swift:9821`. It owns one
`RoomCaptureView`, keeps the AR session alive between rooms with
`stop(pauseARSession: false)` on iOS 17+, then merges with `StructureBuilder`.
This harness only runs ARKit; it neither subclasses nor replaces that controller.

Apple permits passing an existing `ARSession` to `RoomCaptureSession(arSession:)`
or `RoomCaptureView(frame:arSession:)` on iOS 17+. A later integration must observe
that one session rather than create another, coordinate the single AR session
delegate, and retain the world coordinate space across rooms. Backgrounding and
relocalization require explicit treatment; continuing the object alone does not
prove coordinate continuity. No such production integration is part of Phase A.

Primary references checked against Apple's docs and the installed iPhoneOS 26.4 SDK:

- [Native image resolution and sensor orientation](https://developer.apple.com/documentation/arkit/arcamera/imageresolution?language=objc)
- [ARCamera transform convention](https://developer.apple.com/documentation/arkit/arcamera/transform?changes=__3)
- [ARCamera intrinsics](https://developer.apple.com/documentation/arkit/arcamera/intrinsics?changes=__5)
- [Session frame data](https://developer.apple.com/documentation/arkit/arframe)
- [ARKit interruption behavior](https://developer.apple.com/documentation/arkit/arsessionobserver/sessioninterruptionended(_:))
- [Do not pause inside interruption callback](https://developer.apple.com/documentation/arkit/arsessionobserver/sessionwasinterrupted(_:))
- [One AR session across RoomPlan rooms](https://developer.apple.com/documentation/roomplan/scanning-the-rooms-of-a-single-structure)
- [Core Image contexts and image export](https://developer.apple.com/documentation/coreimage/cicontext)
- [ARKit support and camera permission](https://developer.apple.com/documentation/arkit/verifying-device-support-and-user-permission)
- [UIKit button configuration introduced with iOS 15](https://developer.apple.com/videos/play/wwdc2021/10064/)
- [Required-reason API categories](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
- [File-size resource key](https://developer.apple.com/documentation/foundation/urlresourcekey/filesizekey)
- [SwiftUI controller teardown before removal](https://developer.apple.com/documentation/swiftui/uiviewcontrollerrepresentable/dismantleuiviewcontroller(_:coordinator:))
- [Interactive versus programmatic dismissal](https://developer.apple.com/documentation/swiftui/view/interactivedismissdisabled(_:))
- [Backup exclusion resource flag](https://developer.apple.com/documentation/foundation/urlresourcevalues/isexcludedfrombackup)

## Still required for Phase A acceptance

A real room capture and manual transfer; training using the saved poses without
SfM; PLY and SOG artifacts; and navigation in a physical phone browser. Record
actual frame count, phone/OS, image bytes, training minutes, GPU model, PLY bytes,
SOG bytes, and phone browser FPS. Neither this app nor its tests supply or claim
any of those measurements.
