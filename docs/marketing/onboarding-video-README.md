# Onboarding video — how to make it

A narrated ~2½-minute "How it works" walkthrough of the real app, recorded from
the iOS simulator, with a voice-over and burned-in captions. Two files come out:

| file | what | where it goes |
|---|---|---|
| `onboarding.mp4` | 1080×2348 (the simulator's own portrait aspect), H.264 + AAC, faststart | rendprop.com/support, the first-run "Watch the sample tour" slot later |
| `onboarding-9x16.mp4` | 1080×1920, the master fitted inside a 9:16 frame on a dark ground | Reels / TikTok / Shorts |

It is **not** an App Store *App Preview* — those have their own capture and
content rules. This is a plain MP4.

Four pieces, in the order they run:

| piece | file |
|---|---|
| the script — words, captions, what is on screen per segment | `docs/marketing/onboarding-video-script.md` |
| the tour — one XCUITest that drives the app at narration pace and stamps `TOUR_MARK` lines | `apps/ios/RendpropUITests/OnboardingTour.swift` |
| the bridge — boots the sim, seeds media, records the screen, runs the tour, exports the marks | `apps/ios/RendpropUITests/bridge-cmd-onboardingtour.sh` |
| the build — cuts the take at the marks, lays the narration, burns the captions, adds the cards | `tools/video/build_onboarding.py` |

## Step 1 — Record (on the Mac)

```bash
bash "$HOME/Rendprop AI/repo/apps/ios/RendpropUITests/bridge-cmd-onboardingtour.sh"
```

What it does: `xcodegen generate` → boot the 6.3-inch iPhone 17 Pro simulator
(`CC58F5C6-C811-4FEB-889A-EF10CE1E7A0E`) → uninstall the app (clean
container) → status bar 9:41 → seed the photo library → `xcodebuild
build-for-testing` (unrecorded) → start `xcrun simctl io recordVideo` → run
`RendpropUITests/OnboardingTour` → SIGINT the recorder → export the marks.

Output in `~/Rendprop AI/_bridge/out/onboardingtour/`:

- `tour-raw.mp4` — the screen, device resolution (1206×2622), ~2½ min plus a
  short head before the app launches
- `marks.txt` — `TOUR_MARK 01 12.40 …` per segment plus `TOUR_MARK END`, on the
  recording's clock
- `activities.txt` — every note the test wrote (skip reasons, STOREKIT line)

**Before the take that you will publish, put real media in
`~/Rendprop AI/_bridge/in/onboarding-media/`:** two or three listing photos
(`.jpg/.png/.heic`) and one 10–20 s walkthrough clip (`.mp4/.mov`, portrait,
walked at a steady pace). The photos appear in the AI Photo Studio and unlock
the reel card; the clip is what gets uploaded, tagged and rests on Review &
Submit. Without them the bridge falls back to a macOS desktop picture and an
ffmpeg-generated colour-drift clip (fine for a test take, not for the one you
ship), and with no ffmpeg on the Mac the tour skips segments 05 and 06.

Knobs: `KEEP_APP=1` (no uninstall), `SIM_UDID=…`, `TOUR_RENDER=1` (actually tap
"Create my tour" and wait — adds about a minute and breaks the 150 s budget;
only for a look), `NO_PREBUILD=1`.

Watch it run — the Simulator window has to be open and on screen; a recording
of a hidden window is black.

## Step 2 — Stage

Get three things into one folder wherever `ffmpeg` is installed (the Mac with
`brew install ffmpeg`, or this repo's container):

```
work/
  tour-raw.mp4      from the bridge
  marks.txt         from the bridge
  narration/        01.mp3 … 13.mp3 — one file per segment (see below); optional
```

Narration: one file per segment, named by segment id (`01.mp3`, `02.wav`,
`03.m4a` all work), calm and clear, about 2.5–3 words a second. The lines are
the `Say:` entries in the script; `build_onboarding.py` also writes them out as
`narration-script.txt` for a TTS pass. Segments 00 (title card) and 99 (end
card) have no narration. Files that are missing simply leave that segment
captions-only.

## Step 3 — Build

```bash
python3 tools/video/build_onboarding.py \
  --raw work/tour-raw.mp4 --marks work/marks.txt \
  --script docs/marketing/onboarding-video-script.md \
  --narration work/narration --out work/out
```

Add `--dry-run` first: it validates the inputs and prints the timeline (take
range, length, narration length, hold, output range and caption per segment)
without rendering. The bridge runs this build itself at the end when ffmpeg is
on the Mac.

What the build does, in order:

1. Cuts the take at the marks — segment k is mark k → mark k+1; `END` closes
   the last one; the head before the first mark is dropped.
2. Scales to 1080 wide at the source aspect, 30 fps constant.
3. Lays each narration file at its segment's start. **If a narration is longer
   than its segment, the segment's last frame is frozen (ffmpeg `tpad`) until
   the narration ends, plus 0.4 s** — so the voice never talks over the next
   screen. Later segments shift accordingly.
4. Burns the captions (`captions.ass`): bottom third, white, dark outline, at
   most two lines, wrapped to balance the lines.
5. Adds a 1.5 s title card ("Rendprop · How it works") and a 2 s end card
   ("rendprop.com · Rendprop on the App Store"), generated with ffmpeg
   `color` + `drawtext` in the first clean sans found on the machine (Inter →
   Helvetica Neue → Poppins → Noto → Roboto → Liberation → DejaVu → Arial;
   override with `--font`).
6. Writes `onboarding.mp4`, then derives `onboarding-9x16.mp4`: the master
   scaled to fit 1080×1920 and **padded** on the sides with the card colour —
   never cropped, because the type capsule in the nav bar and the tab bar
   both carry meaning. (A source wider than 9:16, which the simulator never
   produces, would be scaled to width and centre-cropped instead.)
7. Prints a report and warns when the total passes 150 s, a caption needs a
   third line, a mark has no script segment, or a script segment has no mark.

Useful flags: `--offset -0.8` (shift every mark; see below), `--gain 3`
(narration dB), `--tail 0.6`, `--width 1080`, `--title/--subtitle/--end1/--end2`.

### Checking the sync once

`simctl` needs a moment to start capturing after the bridge launches it, so the
marks can sit up to about a second late. Scrub the first cut: the title card
should land exactly on Home. If Home shows a beat before the caption starts,
rebuild with `--offset -0.5` (or whatever the gap is); it applies to every
mark, so one correction fixes the whole take. `marks.txt`'s header says which
clock the marks are on — `clock=recording` is the normal case; `clock=launch`
means the test never got the recorder's epoch and `--offset` has to carry the
whole head.

## What a good take looks like

- Home comes up in **real estate** with the hero "Win the listing. Skip the
  film crew." and no homes yet (a clean container — the bridge uninstalls).
- The type menu shows all six types; Home re-themes to the venue headline and
  back. If `activities.txt` says the switcher fell back to a relaunch, the
  re-theme moment is missing — re-run.
- "24 Willow Bend Court" is typed in full; the keyboard goes away before the
  Step 2 buttons are shown.
- The clip imports and Review & Submit shows "YOUR VIDEO" with its duration;
  the tagger shows two rows (Entry, Kitchen). If segments 05/06 skipped, the
  library had no video (seed one).
- The hosted demo page loads and the house visibly flies as the drag happens
  (needs network; a blank web view means it did not).
- The studio shows the six one-tap edits, then two real photos with a wand on
  each and the disclosure line. If the reel card stayed disabled, the photos
  did not import — `activities.txt` says why.
- Reel Studio scrolls to "STEP 2 · ADD YOUR VOICE" with "My voice" selected;
  nothing is recorded.
- The aerial sheet shows its disclosure; the floor plan screen shows the
  upload path (the simulator has no LiDAR, so "Scan one room" does not appear —
  that is expected).
- The paywall shows real prices ("/month") — if it shows "Plans aren't
  available right now", the StoreKit test session did not start; the STOREKIT
  line in `activities.txt` says which lookup failed.
- Every segment has a mark: `grep -c TOUR_MARK marks.txt` should print 14 (13 +
  END). A missing one means that screen was unreachable; the note names it.
- Total under 150 s in the build report. If it is over, the usual cause is a
  slow narration file (the build holds frames for it) — re-record that segment
  a touch faster rather than cutting words.

## Known limits under `-uiTesting`

- Publish / share link / MLS link / the COMPLIANCE card need a published
  listing on the live backend and are not shown; segment 11 shows the Leads
  banner and screen instead, and the narration describes publishing.
- The in-app camera ("Record a walkthrough") cannot run in the simulator; the
  button is on screen in segment 04 and named in the narration, not opened.
- RoomPlan scanning needs LiDAR; the floor plan screen shows the upload path.
- The render ("Create my tour") is skipped by default for time; `TOUR_RENDER=1`
  runs it for a look.
- Nothing is purchased, deleted, AI-edited, generated, recorded or published
  by the tour, ever.
