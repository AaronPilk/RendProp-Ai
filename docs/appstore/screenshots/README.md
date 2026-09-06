# App Store screenshots — 6.9-inch set

App Store Connect requires **one** iPhone size and auto-scales the rest. Rendprop ships the
**6.9-inch** set: **1320 × 2868 portrait**, 3–10 images. The app is iPhone-only
(`TARGETED_DEVICE_FAMILY = 1`), so **there is no iPad set**.

The set is made in four steps, all scripted:

| Step | Where | Command | Output |
|---|---|---|---|
| 1. Capture | Mac bridge | `bash "$HOME/Rendprop AI/repo/apps/ios/RendpropUITests/bridge-cmd-storeshots.sh"` | `~/Rendprop AI/_bridge/out/storeshots/s01-… s15-….png` — raw simulator captures |
| 2. Stage | Mac | copy the raw captures into `docs/appstore/screenshots/6.9/` (optional, see below) | the committed raw set |
| 3. Compose | Mac or container | `python3 tools/screenshots/compose.py --src <captures> --plan docs/appstore/screenshots/plan.json --out docs/appstore/screenshots/6.9-framed` then `--check` | `6.9-framed/*.png` + `sheet.jpg` |
| 4. Upload | Mac | `python3 tools/asc/asc.py screenshots apply --dir docs/appstore/screenshots/6.9-framed --replace` | the APP_IPHONE_67 set in App Store Connect |

A raw capture is a plain screenshot. What the store shows is the **framed** version: the
capture with rounded corners on a brand background under a one-line benefit headline — the
format every app at the top of the category uses. `plan.json` is the set: which captures,
in which order, with which words.

## The set (`plan.json`)

| # | Frame | Headline | Raw capture(s) |
|---|---|---|---|
| 1 | `01-cinematic-tour.png` | Walk it once. A cinematic tour. | `01-published-tour` (= `s08`) — the hosted listing page |
| 2 | `02-every-tool.png` | Every tool in one place | `02-home-showroom` (= `s01`) — the top of Home |
| 3 | `03-every-business.png` | Venues, gyms and restaurants too | `s09-venue-home` + `s10-restaurant-home` + `s11-gym-home`, fanned |
| 4 | `04-photo-fixes.png` | Photos fixed in one tap | `04-photo-studio` (= `s04`) — the studio's one-tap edits |
| 5 | `05-one-link.png` | One link. Leads land in the app. | `03-sample-tour` (= `s02`) — the tool grid, the leads banner, the player |
| 6 | `06-your-card.png` | Your card on every tour | `s15-share-link` — the hosted page at its agent card and lead form |
| 7 | `07-start-in-a-minute.png` | Add the home. Film it. Share it. | `05-new-home` (= `s03`) — the New Home form |
| 8 | `08-social-reel.png` | Photos become a social reel | `s12-reel-studio` — the reel entry |

The first three are what people see in search results; the real-estate hero is first and the
industry frame is third on purpose. Every headline is a benefit in plain English, at most 32
characters, no hype words, no emoji, and nothing a fair-housing reviewer could read as a claim
about people or neighbourhoods. Rules the composer enforces: ≤ 2 lines, ≥ 4.5:1 contrast,
1320 × 2868, RGB, under 8 MB.

Captured but **not** in the set, and why: `s13-floor-plan` (a simulator has no LiDAR, so the
screen says so — capture it on a LiDAR iPhone if you want it), `s14-leads` (the mock has no
leads: an empty inbox), `s07-plan-usage` (Settings), `s05` / `s06` (need photos on the home /
skipped). Add any of them to `plan.json` when a better capture exists; a plan may hold up to 10.

## Step 1 — capture (Mac bridge)

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

Output: `~/Rendprop AI/_bridge/out/storeshots/s01-….png` … `s15-….png` (each with
xcresulttool's `_0_<id>` suffix, which the composer ignores). What the test captures:

| Attachment | Screen | Notes |
|---|---|---|
| `s01-home-showroom` | Home, top | The hero card, the home step 04 created, the first tool tiles. |
| `s02-sample-tour` | Home, scrolled to "See it in action" | The tool grid, the leads banner, the hosted demo player scrubbed a few seconds in. |
| `s03-new-home` | New Home | The form with an address typed in. |
| `s04-photo-studio` | AI Photo Studio | The one-tap edits on offer. **No edit is ever run** — see below. |
| `s05-reel-studio` | Reel Studio | Needs ≥ 2 photos on the home, else it skips itself. |
| `s06-aerial-intro` | Aerial intro sheet | Time of day, camera move, the AI disclosure. |
| `s07-plan-usage` | Settings → Plan & usage | What a plan gets you, in the app's own words. |
| `s08-published-tour` | The hosted demo listing page | What the person on the other end of the link sees. Needs network. |
| `s09-venue-home` | Home as an event venue | The app relaunched without `-space.type`, then the top-left switcher driven to Event venue. |
| `s10-restaurant-home` | Home as a restaurant / bar | Same, Restaurant / Bar. |
| `s11-gym-home` | Home as a gym / studio | Same, Gym / Studio. |
| `s12-reel-studio` | Reel entry | The real home's toolbox → "Make a reel": the studio with the reel card ringed. With two photos on the home it opens Reel Studio itself. |
| `s13-floor-plan` | Floor plan | The upload path — a simulator has no LiDAR and the screen says so. |
| `s14-leads` | Leads | The inbox, empty under the mock. |
| `s15-share-link` | The share surface | A share action on the sample if one exists (it never does — samples never publish), else the hosted demo page scrolled to its agent card and lead form, else the Profile card. |

Why s09–s11 relaunch: a `-key value` launch argument lands in UserDefaults' argument domain,
which wins over anything the switcher persists, so under `-space.type real_estate` the menu
could never re-theme Home. The test drops the pin, drives the menu like a user, and takes the
hero headline changing as proof. If the menu cannot be driven it relaunches pinned to that
type and says so in the activity notes.

### Seed real photos first — this is the one thing worth doing by hand

`s04`, `s05` and `s12` show the photo studio and the reel maker, and what they show is
whatever is in the simulator's photo library. Put your own listing photos — interiors and
exteriors you would genuinely publish — in:

```
~/Rendprop AI/_bridge/in/storeshot-photos/
```

The script converts the first six to PNG and pushes them in with `xcrun simctl addmedia`.
With nothing there it falls back to a macOS desktop picture, and with nothing at all the
studio is captured showing its own showcase of the six one-tap edits — honest, but a much
weaker image, and `s05` skips itself because the reel card stays disabled below two photos.
(The test never drives the system photo picker itself — that is a separate process and the
first run captured the picker instead of the studio.)

### Two rules the test enforces, and why

**Why no before/after in `s04`.** The test runs with `-uiTesting`, which swaps in
`MockAPIClient`, whose `aiPhotoEdit` **echoes the submitted image straight back**. A
"before and after" built from that is two identical photos presented as an AI result — a
misleading screenshot and a 2.3.3 rejection. If you want a genuine before/after in the set,
capture it on a real device against the live backend and add it by hand.

**Why the paywall is not in this set.** `StoreShots` attaches no StoreKit configuration, so
under `xcodebuild test` `Product.products(for:)` returns an empty array and the paywall
correctly renders "Plans aren't available right now". That empty state must never reach the
App Store. The IAP review screenshot is produced by `PaywallShot` (an `SKTestSession` makes
the real prices render) — `docs/appstore/iap-review/README.md`.

The test also never taps a purchase button, never confirms a deletion, never runs an AI job
and never publishes.

### Reading a missing shot

Every step that could not be reached writes its reason into the result bundle as an
activity name:

```bash
xcrun xcresulttool get test-results activities \
  --path ~/"Rendprop AI"/_bridge/out/storeshots-<stamp>.xcresult \
  --test-id 'StoreShots/testStoreShots()'
```

Look for an activity beginning `SKIPPED:` — it names the exact control that was not found —
or `FALLBACK:` for a step that got its image another way.

## Step 2 — stage (optional)

The composer reads the bridge output directly, so staging is only about keeping the raw set
in the repo. The integrator copies the captures into `docs/appstore/screenshots/6.9/` — the
five from the first set keep the numbered names they were committed under, the rest keep
their attachment names:

```bash
S=~/"Rendprop AI"/_bridge/out/storeshots; D=~/"Rendprop AI"/repo/docs/appstore/screenshots/6.9
mkdir -p "$D"
for key in s09-venue-home s10-restaurant-home s11-gym-home s12-reel-studio s13-floor-plan s14-leads s15-share-link; do
  f=$(ls "$S"/${key}_*.png 2>/dev/null | head -1); [ -n "$f" ] && cp "$f" "$D/$key.png"
done
# the first five, under the names the plan and App Store Connect already know
for pair in s08-published-tour:01-published-tour s01-home-showroom:02-home-showroom s02-sample-tour:03-sample-tour s04-photo-studio:04-photo-studio s03-new-home:05-new-home; do
  f=$(ls "$S"/${pair%%:*}_*.png 2>/dev/null | head -1); [ -n "$f" ] && cp "$f" "$D/${pair##*:}.png"
done
```

`compose.py` resolves either spelling (`01-published-tour.png` ≡ `s08-published-tour.png`)
and the `_0_<id>` suffix, so `--src` can point at `6.9/` or straight at the bridge output.

## Step 3 — compose and check

```bash
# on the Mac, straight from the bridge output:
python3 tools/screenshots/compose.py \
  --src ~/"Rendprop AI"/_bridge/out/storeshots \
  --plan docs/appstore/screenshots/plan.json \
  --out docs/appstore/screenshots/6.9-framed --skip-missing
python3 tools/screenshots/compose.py --check --out docs/appstore/screenshots/6.9-framed
```

`--skip-missing` leaves out any frame whose capture the run did not produce and says so;
without it a missing capture is an error. `--check` re-reads every output and fails on
anything that is not 1320 × 2868, not RGB/RGBA PNG, 8 MB or over, or carries a fully
transparent pixel, and writes `sheet.jpg` next to the frames — **open it and look at every
frame before uploading**: headline wording, wrap, nothing clipped, the right capture under
the right words. The composer prints the font it used (Inter or SF Pro when installed,
Poppins in the container, DejaVu as the last resort — it says so) and the contrast ratio of
every frame.

Plan fields, per frame: `src` (a capture, or a list of 2–3 for the fanned "stack"), `out`,
`headline`, optional `subline`, `bg` (`violet`, `grape`, `indigo`, `ink`, `mist`, `#rrggbb`,
or `[#top, #bottom]`), `fit` (`bleed`, the classic bottom-cropped look, or `inset`),
`radius`. Stdlib + Pillow only (`python3 -m pip install pillow`). Tests:
`python3 -m pytest tools/screenshots -q`.

## Step 4 — upload

```bash
python3 tools/asc/asc.py screenshots plan  --dir docs/appstore/screenshots/6.9-framed --replace   # look first
python3 tools/asc/asc.py screenshots apply --dir docs/appstore/screenshots/6.9-framed --replace
```

`--replace` deletes every screenshot already in the APP_IPHONE_67 set (`DELETE
/v1/appScreenshots/{id}`) before uploading, then uploads in filename order and orders the
set. It is needed once after a re-frame: the raw set is still in there, and a set holds at
most 10. Without `--replace` the command only adds what is missing by checksum, so re-running
the bridge (`bash tools/asc/bridge-610-asc-apply.sh`) afterwards changes nothing. The bridge
uses the framed directory automatically when it has PNGs; `bash
tools/asc/bridge-610-asc-apply.sh --replace-screenshots` is the same rebuild from there.

Then check App Store Connect → the version → iPhone 6.9" Display: eight images, in order,
each with its headline readable at thumbnail size.

## Fair housing

Nothing in a Rendprop screenshot may mention people, neighbourhoods, schools, or
demographics — not in a typed address, not in a listing description, not in a headline over
the image. The test types one street address and nothing else for exactly this reason, and
the headlines in `plan.json` describe what the app does, never who a space is for. The
hosted demo page (`s08`, `s15`) carries the demo's agent card — a business card, which is
fine; check it still reads as one after a re-capture.

## What is committed, what is generated

`plan.json` and this README are the recipe and are committed. `6.9/` (raw captures) and
`6.9-framed/` (the composed set plus `sheet.jpg`) are generated on the Mac by the steps
above; keep them out of text patches (binary), and regenerate `6.9-framed/` from `plan.json`
rather than editing a frame by hand — the next run would overwrite it.

`apps/ios/project.yml` already excludes `bridge-cmd-*.sh` and `README.md` from the
`RendpropUITests` sources, so nothing here rides into the test bundle.
