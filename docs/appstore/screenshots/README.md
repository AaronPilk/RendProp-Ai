# App Store screenshots — 6.9-inch set

App Store Connect requires **one** iPhone size and auto-scales the rest. Rendprop ships the
**6.9-inch** set: **1320 × 2868 portrait**, 3–10 images. The app is iPhone-only
(`TARGETED_DEVICE_FAMILY = 1`), so **there is no iPad set**.

The set is captured automatically, not by hand — `Cmd+S` in the Simulator gives you a
1320 × 2868 PNG too, but it gives you a different clock in every shot and no record of
which build produced them.

| File | Screen | Notes |
|---|---|---|
| `s01-home-showroom.png` | Home, scrolled to "Make something" | Every tool in one grid — the hero shot. |
| `s02-sample-tour.png` | The scroll-to-fly-through player | Home → "See it in action", the hosted demo, scrubbed a few seconds in. |
| `s03-new-home.png` | New Home | The form with an address typed in. |
| `s04-photo-studio.png` | AI Photo Studio | The photos plus the one-tap edits on offer. **No edit is ever run** — see "Why no before/after" below. |
| `s05-reel-studio.png` | Reel Studio | Needs ≥ 2 photos on the home, else it skips itself. |
| `s06-aerial-intro.png` | Aerial intro sheet | Time of day, camera move, and the AI disclosure. |
| `s07-plan-usage.png` | Settings → Plan & usage | What a plan gets you, in the app's own words. |
| `s08-published-tour.png` | The published tour page | What the person on the other end of the link sees, agent card included. |

Order them in App Store Connect the way they are numbered — the first two are what people
actually see in search results.

## Regenerate them

On the Mac build bridge:

```bash
bash "$HOME/Rendprop AI/repo/apps/ios/RendpropUITests/bridge-cmd-storeshots.sh"
```

That script does the whole run and never aborts the bridge:

1. `xcodegen generate` (the `.pbxproj` is committed and does **not** list `StoreShots.swift`
   until you regenerate).
2. Finds or creates a simulator called **"Store 6.9"** — `iPhone 17 Pro Max` on the newest
   installed iOS runtime, falling back to `iPhone 16 Pro Max`. Both are 1320 × 2868.
3. Freezes the status bar: `simctl status_bar … --time 9:41 --batteryState charged
   --batteryLevel 100 --wifiBars 3 --cellularBars 4`.
4. Seeds the simulator's photo library (see below).
5. `xcodebuild test -only-testing:RendpropUITests/StoreShots`.
6. Exports the attachments from the `.xcresult` and renames them by the names the test gave
   them, exactly like `bridge-cmd-uiwalk.sh` does.
7. **Rejects anything that is not exactly 1320 × 2868** (`sips -g pixelWidth -g pixelHeight`).
   A wrong size means the test ran on the wrong simulator; nothing wrong-sized is copied.

Output: `~/Rendprop AI/_bridge/out/storeshots/s01-….png` … `s08-….png`.

**Where the integrator commits them:** `docs/appstore/screenshots/6.9/`, keeping the file
names. That directory is the set that gets uploaded; this README is the recipe that made it.

## Seed real photos first — this is the one thing worth doing by hand

`s04` and `s05` show the photo studio and the reel maker, and what they show is whatever is
in the simulator's photo library. Put your own listing photos — interiors and exteriors you
would genuinely publish — in:

```
~/Rendprop AI/_bridge/in/storeshot-photos/
```

The script converts the first six to PNG and pushes them in with `xcrun simctl addmedia`.
With nothing there it falls back to a macOS desktop picture, and with nothing at all the
studio is captured showing its own showcase of the six one-tap edits — honest, but a much
weaker image, and `s05` skips itself because the reel card stays disabled below two photos.

## Two rules the test enforces, and why

**Why no before/after in `s04`.** The test runs with `-uiTesting`, which swaps in
`MockAPIClient`, whose `aiPhotoEdit` **echoes the submitted image straight back**. A
"before and after" built from that is two identical photos presented as an AI result — a
misleading screenshot and a 2.3.3 rejection. If you want a genuine before/after in the set,
capture it on a real device against the live backend and add it by hand.

**Why the paywall is never captured.** The scheme attaches `Rendprop.storekit` to the
**run** action only, not the test action, so under `xcodebuild test` `Product.products(for:)`
returns an empty array and the paywall correctly renders "Plans aren't available right now".
That empty state must never reach the App Store. The IAP review screenshot has its own
recipe — `docs/appstore/iap-review/README.md`.

## Fair housing

Nothing in a Rendprop screenshot may mention people, neighbourhoods, schools, or
demographics — not in a typed address, not in a listing description, not in a caption you
add on top of the image. The test types one street address and nothing else for exactly
this reason. If you add caption text over the PNGs before uploading, the same rule applies
to the captions.

## Reading a missing shot

Every step that could not be reached writes its reason into the result bundle as an
activity name:

```bash
xcrun xcresulttool get test-results activities \
  --path ~/"Rendprop AI"/_bridge/out/storeshots-<stamp>.xcresult \
  --test-id 'StoreShots/testStoreShots()'
```

Look for an activity beginning `SKIPPED:` — it names the exact control that was not found.

## One project.yml line the integrator still owes

`apps/ios/project.yml` excludes `README.md` and `bridge-cmd-uiwalk.sh` from the
`RendpropUITests` sources so they are not copied into the test bundle. The new script needs
the same treatment:

```diff
       excludes:
         - "README.md"        # how to run it — documentation, not a bundle resource
         - "bridge-cmd-uiwalk.sh"   # runs on the Mac bridge; never part of the bundle
+        - "bridge-cmd-storeshots.sh"   # same — the store-shot bridge block
```

Without it the shell script is copied into the UI-test bundle as a resource. Harmless, but
wrong, and inconsistent with the line right above it.
