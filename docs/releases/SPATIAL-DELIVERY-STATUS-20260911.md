# Spatial delivery status — September 11

## Phone delivery is still build 18

The owner's 12:52 PM screenshots show TestFlight **1.0 (18)** and the old Home
screen. This is expected: no newer binary has been uploaded by this task.
GitHub changes and local `build-for-testing` runs do not update the phone.
Labels such as `build3`, `build4` and `build6` in local verification log names
are verification-run labels, **not TestFlight build numbers**.

Fresh read-only App Store Connect check at **2026-09-11T16:55:57Z**:

- Newest uploaded Rendprop build: **18**, VALID, not expired.
- Upload timestamp: **2026-09-10T14:06:25-07:00**.
- The next newest builds are17,16,15,14; no19 is processing in this inventory.
- App Store version1.0: **WAITING_FOR_REVIEW**, attached build**16**.
- Exactly four GET requests succeeded: app lookup, newest builds, iOS versions,
  and the version's attached build. The read transport refused non-GET methods,
  request bodies and non-Apple origins. No Apple mutation was performed.

Do not tell the owner to refresh/reinstall TestFlight to obtain a binary that
has not been uploaded. Internal TestFlight delivery is already authorized by the
owner's later request; another approval is not required merely to repeat that
instruction. The pending App Review attachment/submission must remain unchanged.

## Live backend inventory — read-only September 11 check

The iOS-configured RendProp Supabase project was ACTIVE_HEALTHY. Its live
inventory returned **21 Edge Functions and no `spatial` function**. Migration
history returned35 records, ending at`0034_agent_reel_and_video_ladder`;
0035–0040 were not listed. Missing history alone would not rule out manually
applied SQL, so a separate read-only catalog query was also executed:

```sql
select table_name
from information_schema.tables
where table_schema = 'public'
  and table_name like 'spatial\_%' escape '\'
order by table_name;
```

That query returned an empty array at approximately**17:05UTC**. No customer
rows were queried and no DDL, function deployment or runtime setting changed.
The new source expects`spatial_jobs`,`spatial_inputs`,`spatial_runtime`,
`spatial_budget_windows` and`spatial_attempt_history` from migration0040.
This confirms a deployment gap in addition to the missing iOS binary. Merely
uploading a new binary would not make the automatic cloud path work.

## Billing correction — do not repeat the old blocker as current fact

The owner's newer screenshot of Modal workspace`aaronpilk` shows:

- Workspace usage limit: **USD42.50**.
- Current usage: approximately**USD1.10**, covered by credits.
- Current charges: **USD0**.
- Saved spend limit: **USD20**.

This shows apparent present headroom. The previous sandbox's terminal result,
“Container terminated due to reaching billing cycle spend limit,” describes
that **past run** and does not prove a current account block. No one needs to
raise this limit or buy a Team plan based on the displayed numbers alone.
These are screenshot observations, not an independent current settings API
readback or a guarantee that a new allocation will be admitted.

Fresh exact-app Modal1.5.3 read at **2026-09-11T16:45:29Z** returned **zero active
sandboxes**. The old sandbox remains terminated, exit137. Previous exact-app
provider-reported usage wasUSD1.09974939. No real-room artifact was collected.
No account limits, allocation markers or cloud resources were changed by these
readbacks. The existing **USD25 total one-room experiment ceiling** is unchanged;
the screenshot does not authorize unlimited or ongoing production spending.

## Source and remaining delivery work

Implemented source is pushed at **2612c7cc85bc8906287a11dc14c72e4b1105f238** on
`feat/spatial-product-20260911`. Local build6 succeeded. The Home3D card,
capture/background upload, job/retry flow, bounded worker, web viewer and privacy
review exist in code; that is not a deployed automatic service or finished room.

Remaining work before claiming the full feature works:

1. Produce and inspect a real model from the saved capture within the existing
   bounded experiment authority; preserve/reconcile prior allocation evidence.
2. Finish durable provider cleanup records, integrate deletion cleanup for
   current/historical spatial artifacts and implement actual selective privacy
   redaction. Whole-room exclusion is implemented; selective blur is not.
3. Deploy and verify the automatic private cloud path, including real file
   transfer, job completion, result retrieval and bounded provider usage.
4. Complete source-bound final UI/release verification; archive/export/upload an
   internal-only binary; read back Apple processing and internal availability
   while confirming the App Review build remains unchanged.
5. Owner tests physical capture, background transfer and real-room navigation on
   iPhone15Pro. Simulator checks cannot prove those camera/device outcomes.

## Final frozen-source non-camera UI verification — completed

The final run finished at **13:06Eastern**. It used the existing build6 outputs
from source`2612c7c`, no rebuild, no parallel testing, and the isolated simulator
`8D787CFB-B1F3-4950-854E-463126A68F92` (iPhone17Pro, iOS26.4.1).
All three selected tests passed; no failures, skipped tests or expected failures.

```sh
xcodebuild test-without-building \
  -xctestrun /tmp/rendprop-spatial-product-derived-20260911/Build/Products/Rendprop_iphonesimulator26.4-arm64.xctestrun \
  -destination 'platform=iOS Simulator,id=8D787CFB-B1F3-4950-854E-463126A68F92' \
  -parallel-testing-enabled NO \
  -only-testing:RendpropUITests/ReviewerWalk/testReviewerWalk \
  -only-testing:RendpropUITests/RendpropUITests/testWalk \
  -only-testing:RendpropUITests/SpatialProductIntegrationTests/testHomeCardOpensListingScopedProductWithoutCameraOrFakeRoom \
  -resultBundlePath /tmp/rendprop-spatial-final-walks-20260911.2VD3vK/FinalWalks.xcresult
```

Actual log: `TEST EXECUTE SUCCEEDED`, three tests, zero failures. Individual
durations: main265.181s, reviewer358.761s, spatial entry21.426s. Root independently
read the completed result using:

```sh
xcrun xcresulttool get test-results summary \
  --path /tmp/rendprop-spatial-final-walks-20260911.2VD3vK/FinalWalks.xcresult
```

Output: `result: Passed`, `totalTestCount: 3`, `passedTests: 3`, `failedTests: 0`,
`skippedTests: 0`, `expectedFailures: 0`.

The spatial test verifies the actual Home card opens the listing-scoped product,
not the export-only lab; it checks truthful unsupported-camera/empty-room states,
refresh and return to Home. This mock-backed test **does not** execute a camera,
cloud reconstruction, background transfer on hardware, or real-room navigation.
The older build3/build4 walks are no longer needed as proof of this final source.
No application or test source changed during this run; this report is docs-only.

Root visually inspected both exported screenshots under the evidence folder:

- `spatial-attachments/3D19ACF9-1B2C-421A-B640-98D0AAEEEC00.png`: new purple
  Home card appears next to Make a tour, with complete title and subtitle.
- `spatial-attachments/9ECCB892-C338-484D-B53E-F6838CBC4371.png`: listing-scoped
  room screen, Wi-Fi toggle, truthful unsupported-device message and empty state.

Minor visual follow-up: `SpatialTourView.swift:28` uses the`view.3d` SF Symbol
beside the text`3D walkthrough`, which renders as **“3D 3D walkthrough”** on this
OS. Replace the hero symbol with a distinct spatial glyph and visually verify
it in a later source-bound build. This cosmetic issue was not silently edited
after freezing the test source. These images are simulator evidence, not proof
of a changed TestFlight app. Evidence under`/tmp` is not guaranteed durable.

The owner does not need to rescan, operate a GPU, change billing again, or alter
the pending Apple submission to solve the missing-update issue. Engineering
still owes the actual cloud result and uploaded phone build.
