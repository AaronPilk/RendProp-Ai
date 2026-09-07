# Rendprop — onboarding video v2 storyboard

The shot-by-shot technical list behind `SCRIPT.md`: what `OnboardingTour.swift`
actually taps, waits for, and rests on, per segment — accessibility
identifiers and labels pulled straight from the test, not paraphrased. Use
this to operate the bridge, to sanity-check a take before narrating it, or to
change the test itself without breaking the shot. `SCRIPT.md`'s own
`On screen:` lines are the short, creative version of the same shots; this
file is the long, exact one.

Every beat below is one `private func segNN…()` in
`apps/ios/RendpropUITests/OnboardingTour.swift`, called in this order from
`testOnboardingTour()`. A beat that cannot be reached (a label never appears,
a sheet never opens) writes a `note(...)` explaining why and moves on —
nothing fails the test, and `build_onboarding.py` simply drops that segment's
narration and caption because its mark never got written.

---

## Launch

```
-uiTesting -hasOnboarded YES -appearance light -ai.thirdPartyProcessing.consent.v1 YES
```

No `-space.type` — the top-left business-type menu has to be genuinely
drivable for beat 12, and an argument-domain value would pin the type and
make the menu inert (see `IndustryWalk.swift`'s own header for why). The
container is uninstalled first (a clean install: no homes, real estate by
default) — `bridge-cmd-onboardingtour.sh` does this unless `KEEP_APP=1`.

## Before you record: seed the media

Two things have to be in the simulator's photo library *before*
`xcodebuild test` starts, or three of the fourteen beats film nothing:

- **2–3 listing photos** (`.jpg` / `.png` / `.heic`) — unlocks the AI Photo
  Studio's real-photo grid (beat 07) and the reel card (beat 08).
- **One 10–20 s walkthrough clip** (`.mp4` / `.mov`, portrait, walked at a
  steady pace) — is what gets imported in beat 03, and is the clip beats 04
  and 05 tag and render.

`bridge-cmd-onboardingtour.sh` does this for you (its step 4) from
`~/Rendprop AI/_bridge/in/onboarding-media/` — drop your files there and run
the bridge; nothing below needs to be typed by hand. Driving the test
directly (Xcode, or a manual `xcodebuild test`) needs the same seeding done
first:

```bash
xcrun simctl addmedia <UDID> \
  /path/to/walkthrough.mp4 \
  /path/to/listing-photo-1.jpg \
  /path/to/listing-photo-2.jpg
```

**This is the fix for the two beats v1's take could not film.** Beats 04
(tag rooms) and 05 (create the tour) are not missing code — `seg04TagRooms()`
and `seg05CreateTour()` were already correct in v1 and are unchanged here
apart from their id — they were missing *footage*, because v1's recording ran
with an empty photo library: `seg03RecordOrUpload()` found no clip in the
picker, returned `imported = false`, and `testOnboardingTour()` skips 04 and
05 outright whenever that happens (see its `if hasVideo { … } else { … }`
branch). Seed a clip with `simctl addmedia` before the take and both beats
fall into place with no code change at all.

## Reading the table

**Anchor** is what the test looks for, in the order it tries: an
accessibility identifier (`id:`) first, a visible label (`label:`) second —
identifiers are grepped straight from `.accessibilityIdentifier(` in
`apps/ios/Rendprop`, so they win even if the visible copy is later reworded.
**Hold** is the sum of the beat's own `beat()`/`settle()` calls — the time a
viewer actually gets to look at something, not counting the scroll/tap/wait
time around it.

---

### 00 · Cold open — `seg00Hook()` → `mark("00")`

| step | action |
|---|---|
| 1 | Cold launch; wait for Home (`id: home.addHome` / `label: "Make something"`) |
| 2 | Scroll to top → **MARK 00** |
| 3 | Scroll down (up to 8 steps) to `label: "Watch the sample tour"` |
| 4 | Tap it |
| 5 | Wait for `label: "Demo listing page"` or `"Sample tour"` (the hosted demo page) |
| 6 | Hold 1.0 s so the page draws |
| 7 | **One slow drag** inside the web view (`scrubPlayer()`: press 0.1 s → drag from 72% to 28% of the view height at `.slow` velocity → hold 0.3 s) — the house flies past as the page scrolls. **This drag is the hook.** |
| 8 | Hold 0.6 s, then back out |

Hold budget: ~1.6 s + the drag itself. Needs network to `rendprop.com`; a
blank web view at step 5 means it did not reach it — re-run on a connection
that can.

### 01 · This is Rendprop — `seg01Home()` → `mark("01")`

| step | action |
|---|---|
| 1 | Wait for Home |
| 2 | `ensureRealEstate()` — silently switches back to Real estate if a dirty simulator persisted another type. **Not part of the shot** — happens before the mark. |
| 3 | **MARK 01** |
| 4 | Hold 2.5 s on the hero ("Win the listing. Skip the film crew.") |
| 5 | Slow drag down (`gentleScroll(down: true)`) to reveal "Make something" |
| 6 | Hold 1.5 s |
| 7 | Slow drag back up (`gentleScroll(down: false)`) |
| 8 | Hold 0.8 s |

Hold budget: 4.8 s.

### 02 · Start with the space — `seg02AddHome()` → `mark("02")`

| step | action |
|---|---|
| 1 | Scroll to top → **MARK 02** |
| 2 | Scroll to `id: home.addHome` / `label: "Add a home"` (up to 4 steps) |
| 3 | Tap it |
| 4 | Wait for `label: "New Home"` or `"Step 1 · The home"` |
| 5 | Hold 1.5 s |
| 6 | Type `"24 Willow Bend Court"` into the field placeholder `"Type the home's address"` |
| 7 | Hold 1.0 s, then dismiss the keyboard |
| 8 | Hold 2.0 s on "Step 2 · The video" (Upload / Record) |

Hold budget: 4.5 s. **Fair housing:** the seeded address is a street address
only — no neighbourhood, school, or description of people; don't change it
to anything that reads otherwise.

### 03 · Film or upload the walk — `seg03RecordOrUpload()` → `mark("03")`

| step | action |
|---|---|
| 1 | **MARK 03** |
| 2 | Scroll to `label: "Upload a video"` (up to 3 steps) — `"Record a walkthrough"` sits beside it but is never tapped (the in-app camera cannot run in the simulator) |
| 3 | Tap it |
| 4 | Wait for the `"Where is your video?"` sheet (`"Photos"` / `"Files"`) |
| 5 | Hold 1.5 s |
| 6 | Tap `"Photos"` |
| 7 | Wait up to 8 s for the picker's first cell — **this is where a seeded clip is required; an empty library ends the take here** |
| 8 | Hold 1.5 s, then tap the cell (single-selection picker — finishes on the tap) |
| 9 | Wait for `"Review & Submit"` / `"YOUR VIDEO"` (up to 30 s for the import) |
| 10 | Hold 2.0 s |

Hold budget: 5.0 s. Returns whether the import succeeded; beats 04 and 05
only run when it did.

### 04 · Tag rooms, get chapters — `seg04TagRooms()` → `mark("04")` — *previously unfilmable*

| step | action |
|---|---|
| 1 | **MARK 04** |
| 2 | Scroll to `label: "Tag rooms on the video"` (or `"Tag areas on the video"`) (up to 4 steps) |
| 3 | Tap it |
| 4 | Wait for the tagger sheet — `label: "Scrub to where"` / `"Custom room name"` / `"Custom area name"` (labels chosen so the Review screen's own button underneath the sheet is never mistaken for it) |
| 5 | Hold 1.5 s |
| 6 | Tap the quick-tag chip `"Entry"` |
| 7 | Hold 1.0 s |
| 8 | Drag the tagger's slider to 55% of the clip |
| 9 | Hold 0.8 s |
| 10 | Tap the quick-tag chip `"Kitchen"` |
| 11 | Hold 1.5 s (both rows now in the tag list) |
| 12 | Tap `"Done"` |
| 13 | Hold 1.5 s on Review & Submit — `"ROOMS"` lists both |

Hold budget: 7.8 s. Needs the seeded clip from step 03 — see "Before you
record" above; the code itself needed no fix.

### 05 · Create the tour — `seg05CreateTour()` → `mark("05")` — *previously unfilmable*

| step | action |
|---|---|
| 1 | **MARK 05** |
| 2 | Scroll to `label: "Create my tour"` (up to 6 steps) |
| 3 | Hold 3.0 s on "PICK YOUR QUALITY" + the button — **not tapped** by default |
| 4 | *Only if the bridge sets `TOUR_RENDER=1`:* tap it, wait up to 150 s for `"View tour"` / `"YOUR TOUR"` / `"Tour ready"`, hold 3.0 s |
| 5 | Hold 0.5 s, then back out to Home (the new home and its video stay) |

Hold budget: 3.5 s standard, ~6.5 s with `TOUR_RENDER=1` (adds up to a
minute of wait and breaks the 150 s video budget — only for a one-off look,
never the take you narrate). Same fix as beat 04: a seeded clip.

### 06 · Share the link — `seg06Share()` → `mark("06")`

| step | action |
|---|---|
| 1 | Back to Home, scroll to top → **MARK 06** |
| 2 | Scroll (up to 6 steps) to the banner whose label contains `"Opens your leads."` |
| 3 | Hold 3.0 s — **rests on the banner's own text, not tapped yet** (tapping it is beat 11, filmed later so the two get different footage) |
| 4 | Back to root |

Hold budget: 3.0 s. This is the new beat split out of what v1 folded into a
single "Publish, share, leads" segment.

### 07 · AI Photo Studio — `seg07PhotoStudio()` → `mark("07")`

| step | action |
|---|---|
| 1 | Back to Home, scroll to top → **MARK 07** |
| 2 | Scroll to `id: home.feature.photos` / `label: "Take photos"` (up to 6 steps) |
| 3 | Tap it; `resolveProjectGate()` handles the "which home?" gate (a no-op here — exactly one home exists) |
| 4 | Wait for `label: "AI Photo Studio"` |
| 5 | Hold 2.5 s on the one-tap edits (twilight · blue sky · lawn · tidy · furniture) |
| 6 | `addTwoPhotosFromLibrary()`: tap `"Add photos"`, wait up to 8 s for the picker, hold 1.0 s, tap the first two image cells, tap `"Add"`/`"Done"`, hold 3.0 s while ingest writes the files — **needs the seeded photos; an empty library leaves the studio resting on the showcase instead** |
| 7 | Hold 2.5 s — a wand on every photo + the disclosure line |

Hold budget: 5.0 s + the ingest pause. Returns whether the studio was
reached; beat 08's reel card depends on it.

### 08 · A reel, in your own voice — `seg08Reel(inStudio:)` → `mark("08")`

| step | action |
|---|---|
| 1 | **MARK 08** (skipped-with-a-note if beat 07 never reached the studio) |
| 2 | Scroll to top; find `id: detail.reelStudio` / `label: "Make a reel"` — disabled until 2 photos exist |
| 3 | Tap it |
| 4 | Wait for `label: "Reel Studio"` / `"PICK PHOTOS"` |
| 5 | Hold 1.5 s |
| 6 | Scroll to `id: reel.step.voice` / `label: "STEP 2 · ADD YOUR VOICE"` / `"My voice"` (up to 6 steps) |
| 7 | Tap `"My voice"` — shows the Record pane; **nothing is recorded** |
| 8 | Hold 3.0 s |
| 9 | Close, hold 0.5 s |

Hold budget: 5.0 s.

### 09 · Aerial intro — `seg09AerialAndFloorPlan()`, first half → `mark("09")`

One method produces two marks — nothing else is filmed between them, so
there's no need to re-open the home's detail screen twice.

| step | action |
|---|---|
| 1 | Back to Home, scroll to top (shared with beat 10) |
| 2 | **MARK 09** |
| 3 | Scroll to `id: home.listing.first` / `label:` the home's own address (up to 4 steps) |
| 4 | Tap it |
| 5 | Wait for `id: detail.photoStudio` / `label: "TOOLBOX"` |
| 6 | Hold 1.0 s |
| 7 | Scroll to `label: "Aerial intro"` (up to 8 steps); tap if enabled |
| 8 | Wait for `label: "Golden hour"` / `"Rise & reveal"` (the shot-setting picker) |
| 9 | Hold 3.0 s — the shot settings **and, above them, the always-visible AI disclosure** |
| 10 | Close — **nothing is generated** |

Hold budget: 4.0 s.

### 10 · Floor plan — `seg09AerialAndFloorPlan()`, second half → `mark("10")`

| step | action |
|---|---|
| 1 | **MARK 10** |
| 2 | Hold 0.5 s |
| 3 | Scroll to `label: "Floor plan"` (up to 8 steps); tap if enabled |
| 4 | Wait for `label: "Add a floor plan"` / `"Scan one room"` / `"Floor plan ready"` / `"Room plan ready"` |
| 5 | Hold 2.5 s — the simulator has no LiDAR, so this shows the **upload** path, not "Scan one room" — expected, not a bug |
| 6 | Back |

Hold budget: 3.0 s.

### 11 · Leads inbox — `seg11LeadsInbox()` → `mark("11")`

| step | action |
|---|---|
| 1 | Back to Home, scroll to top → **MARK 11** |
| 2 | Scroll (up to 6 steps) to the **same** `"Opens your leads."` banner as beat 06 |
| 3 | Hold 0.8 s |
| 4 | Tap it — this time the tap happens |
| 5 | Wait for `label: "No leads yet"` / `"Loading leads…"` / `"Leads"` |
| 6 | Hold 3.0 s (`"No leads yet"` on a fresh install — expected) |
| 7 | Back to root |

Hold budget: 3.8 s.

### 12 · Six kinds of space — `seg12Industries()` → `mark("12")`

| step | action |
|---|---|
| 1 | Scroll to top → **MARK 12** |
| 2 | Tap the business-type capsule (nav-bar button whose label starts with the current type's name) |
| 3 | Hold 2.5 s — all six types listed in the open menu |
| 4 | Tap the menu row `"Event venue"` |
| 5 | Wait for a label containing `"Book the date before"` |
| 6 | Hold 2.5 s — Home re-themed for a venue |
| 7 | Tap the capsule again, hold 1.5 s |
| 8 | Tap the menu row `"Real estate"` |
| 9 | Wait for a label containing `"Win the listing"` |
| 10 | Hold 2.0 s — back to real estate (a hard relaunch pinned to real estate is the fallback if the switch silently failed) |

Hold budget: 8.5 s. This is v1's segment "02" (Six industries), **moved to
the end** for v2 — see `SCRIPT.md`'s "WHAT CHANGED FOR v2".

### 13 · The honest line — `seg13Close()` → `mark("13")`

| step | action |
|---|---|
| 1 | Back to Home, scroll to top → **MARK 13** |
| 2 | Hold 4.0 s, resting on the hero for the end card |

Hold budget: 4.0 s. Immediately followed by `mark("END")` — no further
action.

---

## Not filmed (called from nowhere)

`seg12Plans()` — v1's "Plans and the free trial" (its old segment "12" —
before v2's `seg12Industries()` took that id) — is still defined, still
correct, and still exercises the StoreKit test session end-to-end, but
`testOnboardingTour()` never calls it. v2's narration never speaks a price;
the free trial is the closing CTA card instead
(`build_onboarding.py --end-card`). Left in place rather than deleted so a
future cut that wants the paywall back has a working shot to re-enable — its
own `mark("12")` calls are dead code and must not be un-commented alongside
the real `seg12Industries()` without renumbering one of them.

## Total

Fourteen marks (00–13) plus `END`. Summed hold budget above is ~63 s of
*deliberate pauses* — scrolls, taps, imports and waits add the rest, landing
the full raw take in the same few-minutes range as v1's (`tour-raw.mp4` was
361 s / ~6 min in the 6 Sep recording). `build_onboarding.py --fit` is what
actually compresses each segment to its narration's length for the ~100 s
finished cut — see `README.md` in this folder for the exact command.
