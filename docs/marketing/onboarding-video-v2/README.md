# Onboarding video v2 — how to make it

A narrated ~100–105 s ad-grade walkthrough of the real app, recorded from the
iOS simulator: a cold open, one feature per beat in first-project order, a
loop-back hook roughly every 20 s, an ElevenLabs voice, and a closing CTA.
Four files come out of the same one recording:

| file | what | where it goes |
|---|---|---|
| `onboarding.mp4` | 1080×2348 (the simulator's own portrait aspect), H.264 + AAC, faststart | rendprop.com, the first-run "Watch the sample tour" slot, paid social |
| `onboarding-9x16.mp4` | 1080×1920, the master fitted inside a 9:16 frame on a dark ground | Reels / TikTok / Shorts |
| `onboarding-30s.mp4` + its 9x16 | a 4-beat, ~28–30 s cut of the same take | paid social, a shorter placement |
| `onboarding-15s.mp4` + its 9x16 | a 3-beat, ~15 s cut of the same take | bumper ads, Stories |

Not an App Store *App Preview* — those have their own capture and content
rules. Plain MP4s.

This supersedes `docs/marketing/onboarding-video-README.md` (v1) as the take
to shoot. The bridge script and the build tool are the same two pieces v1
used — only the test's beat order and the script changed — so this file only
repeats what is different; **`bridge-cmd-onboardingtour.sh` runs exactly as
it did for v1**, unchanged.

Five pieces, in the order they run:

| piece | file | changed for v2? |
|---|---|---|
| the script — words, captions, hooks, what is on screen per beat | `docs/marketing/onboarding-video-v2/SCRIPT.md` (+ `SCRIPT-30s.md`, `SCRIPT-15s.md`) | new |
| the shot list — exact accessibility ids/labels/hold times per beat | `docs/marketing/onboarding-video-v2/STORYBOARD.md` | new |
| the tour — one XCUITest that drives the app at narration pace and stamps `TOUR_MARK` lines | `apps/ios/RendpropUITests/OnboardingTour.swift` | yes — 14 beats (00–13), reordered |
| the bridge — boots the sim, seeds media, records the screen, runs the tour | `apps/ios/RendpropUITests/bridge-cmd-onboardingtour.sh` | **no** |
| the narrator — turns `Say:` lines into ElevenLabs audio | `tools/video/narrate_elevenlabs.py` | new |
| the build — cuts the take at the marks, lays narration, burns captions, adds cards | `tools/video/build_onboarding.py` | yes — `--end-card`, `--hook-card`, `--only-scripted` |

## Step 1 — Seed the media, then record (on the Mac)

**Put real media in `~/Rendprop AI/_bridge/in/onboarding-media/` before you
run the take you intend to publish** — two or three listing photos
(`.jpg`/`.png`/`.heic`) and one 10–20 s walkthrough clip (`.mp4`/`.mov`,
portrait, walked at a steady pace):

```bash
mkdir -p ~/"Rendprop AI"/_bridge/in/onboarding-media
cp /path/to/walkthrough.mp4 /path/to/photo-1.jpg /path/to/photo-2.jpg \
   ~/"Rendprop AI"/_bridge/in/onboarding-media/
```

This matters more for v2 than it did for v1: the bridge's own step 4 turns
those files into a `xcrun simctl addmedia` call before the test runs, and
**this is the whole fix for the two beats v1's take could not film** — beats
04 (tag rooms) and 05 (create the tour) needed no code change, only a clip in
the library (see `STORYBOARD.md`'s "Before you record" for exactly what the
bridge does, and the equivalent command to run by hand if you are driving the
test outside the bridge). No photos also mutes beat 07's real-photo grid and
disables beat 08's reel card. Skip this and the bridge falls back to a
desktop picture and an ffmpeg-generated placeholder clip — fine for a test
take, not for the one you ship.

Then:

```bash
bash "$HOME/Rendprop AI/repo/apps/ios/RendpropUITests/bridge-cmd-onboardingtour.sh"
```

Output in `~/Rendprop AI/_bridge/out/onboardingtour/`:

- `tour-raw.mp4` — the screen, device resolution, ~2–4 min plus a short head
  before the app launches
- `marks.txt` — `TOUR_MARK 00 …` through `TOUR_MARK 13 …` plus `TOUR_MARK
  END`, on the recording's clock (14 marks + END — `grep -c TOUR_MARK
  marks.txt` should print 15)
- `activities.txt` — every note the test wrote (skip reasons, STOREKIT line)

The bridge also tries its own build at the very end (its step 11) — **ignore
that output.** It always points at v1's `docs/marketing/onboarding-video-script.md`
with no narration, because the bridge script itself was not changed for v2
(see the table above). The real build is Step 4 below.

Knobs (same as v1): `KEEP_APP=1` (no uninstall), `SIM_UDID=…`, `TOUR_RENDER=1`
(actually tap "Create my tour" in beat 05 and wait — adds up to a minute and
breaks the 150 s recording budget; only for a look), `NO_PREBUILD=1`. Watch it
run — the Simulator window has to be open and on screen; a recording of a
hidden window is black.

## Step 2 — Stage and transcode

Get `tour-raw.mp4` and `marks.txt` into one folder wherever `ffmpeg` is
installed (the Mac with `brew install ffmpeg`, or this repo's container).
The Mac's own bundled `ffmpeg` (not a Homebrew build) is often missing
`drawtext`/`subtitles` — the build names the missing filter if so, and the
fix is the same proxy step v1 needed:

```bash
mkdir -p work && cd work
cp ~/"Rendprop AI"/_bridge/out/onboardingtour/tour-raw.mp4 .
cp ~/"Rendprop AI"/_bridge/out/onboardingtour/marks.txt .
ffmpeg -i tour-raw.mp4 \
  -vf "fps=30,scale=1080:2348:flags=bicubic,setsar=1" \
  -c:v libx264 -preset veryfast -crf 21 -pix_fmt yuv420p -an -movflags +faststart \
  take-30fps.mp4
```

(Run this wherever ffmpeg actually has the filters — if that isn't the Mac,
copy `tour-raw.mp4` + `marks.txt` to wherever is and run the rest of these
steps there too.)

## Step 3 — Narrate with ElevenLabs

Put the API key where nothing else reads it (once):

```bash
umask 077; echo sk_your_real_key > ~/"Rendprop AI"/_bridge/.elevenlabs-key
```

Pick a voice — this prints every voice the key can use, id and labels, and
never prints the key itself:

```bash
python3 tools/video/narrate_elevenlabs.py --list-voices
```

Then generate one `.mp3` per segment straight from `SCRIPT.md`'s `Say:`
lines (skip `--voice` to auto-pick the first voice labelled "warm", else a
documented calm fallback — pin one explicitly once you've picked from
`--list-voices`):

```bash
python3 tools/video/narrate_elevenlabs.py \
  --script docs/marketing/onboarding-video-v2/SCRIPT.md \
  --out work/narration \
  --voice <voice_id_from_above>
```

A partial run (a quota, a dropped connection) resumes for free — existing
`work/narration/NN.mp3` files are left alone; add `--overwrite` to redo
everything or `--only 07,08` to redo specific beats. `--dry-run` prints the
plan (voice, model, per-segment status) without calling the API.

## Step 4 — Build the full cut

```bash
python3 tools/video/build_onboarding.py \
  --raw work/take-30fps.mp4 --marks work/marks.txt \
  --script docs/marketing/onboarding-video-v2/SCRIPT.md \
  --narration work/narration --out work/out \
  --fit --title-seconds 0 \
  --end-card "Try it out now — free for 7 days" --end-card-seconds 3
```

Add `--dry-run` first: it validates the inputs and prints the timeline (take
range, length, narration length, hold, output range and caption per segment)
without rendering. What the flags above do that v1's build did not need:

- `--fit` paces every beat to its own narration (speeds the picture up, then
  trims) instead of freezing on a long line — this is how the v2 take should
  be cut; see `SCRIPT.md`'s own note on pacing.
- `--title-seconds 0` drops the title card entirely: beat 00 *is* the cold
  open, so nothing should play before it.
- `--end-card TEXT --end-card-seconds 3` adds the CTA card, in the caption's
  own look, after beat 13 and before the existing `rendprop.com` / App Store
  card (which still renders from its own defaults — no flag needed).
- Hooks need no flag at all: `SCRIPT.md`'s `Hook:` lines are read straight out
  of the script the same way `Say:`/`Caption:` are. `--hook-card ID=TEXT` is
  only for adding or overriding one from the command line.

Writes `onboarding.mp4` and `onboarding-9x16.mp4` into `work/out/` (plus
`captions.ass`, `timeline.json`, `narration-script.txt` for QA), and prints a
report — check it for the total length and any `WARN` line (a caption needing
a third line, a mark with no script segment, a segment with no mark).

### Checking the sync once

`simctl` needs a moment to start capturing after the bridge launches it, so
the marks can sit up to about a second late. Scrub the first cut: beat 00's
mark should land right as Home first appears. If it shows a beat early,
rebuild with `--offset -0.5` (or whatever the gap is, in seconds) — it shifts
every mark, so one correction fixes the whole take. `marks.txt`'s header line
says which clock the marks are on; `clock=launch` (rather than the normal
`clock=recording`) means the test never got the recorder's epoch and
`--offset` has to carry the whole head. If a particular beat's own footage
looks wrong (a menu still on screen instead of the feature it names),
`--source ID=START-END` re-points that one segment at a different range of
the raw take instead of its marks — v1's actual cut needed this for a few
segments; check the render before reaching for it.

## Step 5 — Build the 30-second cut-down

Same take, same marks, a shorter script and `--only-scripted` (drops any mark
`SCRIPT-30s.md` doesn't have a heading for, instead of showing it caption-less):

```bash
python3 tools/video/build_onboarding.py \
  --raw work/take-30fps.mp4 --marks work/marks.txt \
  --script docs/marketing/onboarding-video-v2/SCRIPT-30s.md \
  --narration work/narration --out work/out-30s \
  --fit --title-seconds 0 --only-scripted \
  --end-card "Try it out now — free for 7 days" --end-card-seconds 3
```

`--narration work/narration` is the SAME folder from Step 3 — `SCRIPT-30s.md`
re-narrates beats 00/01/07/12 shorter, so generate those four again into the
same directory with `--overwrite` first if you want the condensed wording
actually spoken (skip this and the full-length lines are simply trimmed by
`--fit` instead — still on-message, just not verbatim the shorter copy):

```bash
python3 tools/video/narrate_elevenlabs.py \
  --script docs/marketing/onboarding-video-v2/SCRIPT-30s.md \
  --out work/narration --voice <voice_id> --overwrite --only 00,01,07,12
```

Writes `onboarding.mp4` / `onboarding-9x16.mp4` into `work/out-30s/` — rename
them (`onboarding-30s.mp4` etc.) once you pull them out, since the filenames
themselves don't change between builds.

## Step 6 — Build the 15-second cut-down

Same pattern, three beats (00/01/12), and the CTA card trimmed to 2 s (the
full 3 s reads slow at 15 s total):

```bash
python3 tools/video/narrate_elevenlabs.py \
  --script docs/marketing/onboarding-video-v2/SCRIPT-15s.md \
  --out work/narration --voice <voice_id> --overwrite --only 00,01,12

python3 tools/video/build_onboarding.py \
  --raw work/take-30fps.mp4 --marks work/marks.txt \
  --script docs/marketing/onboarding-video-v2/SCRIPT-15s.md \
  --narration work/narration --out work/out-15s \
  --fit --title-seconds 0 --only-scripted \
  --end-card "Try it out now — free for 7 days" --end-card-seconds 2
```

## What a good v2 take looks like

- Home comes up in **real estate** with "Win the listing. Skip the film
  crew." and no homes yet (a clean container — the bridge uninstalls).
- Beat 00's demo page actually loads and the house visibly flies as the drag
  happens (needs network; a blank web view means it did not — re-run where
  there's a connection).
- "24 Willow Bend Court" is typed in full in beat 02; the keyboard goes away
  before Step 2's buttons show.
- The clip imports in beat 03 and Review & Submit shows "YOUR VIDEO" with its
  duration. Beats 04 and 05 then show the tagger with two rows (Entry,
  Kitchen) and "PICK YOUR QUALITY". If either skipped, the library had no
  clip — seed one (Step 1) and re-run.
- Beat 06 rests on the Leads banner's own line ("Every tour is one link with
  a lead form built in.") without tapping it — that's correct; the tap is
  beat 11.
- Beat 07's studio shows the six one-tap edits, then two real photos with a
  wand on each and the disclosure line. If the reel card in beat 08 stayed
  disabled, the photos did not import — `activities.txt` says why.
- Beat 08's Reel Studio scrolls to "STEP 2 · ADD YOUR VOICE" with "My voice"
  selected; nothing is recorded.
- Beat 09's aerial sheet shows its disclosure; beat 10's floor plan screen
  shows the upload path (the simulator has no LiDAR, so "Scan one room" does
  not appear — expected).
- Beat 11 opens the same Leads banner and shows "No leads yet" on a fresh
  install.
- Beat 12 shows all six types in the menu; Home re-themes to the venue
  headline and back. If `activities.txt` says the switcher fell back to a
  relaunch, the re-theme moment is missing from the recording — re-run.
- Every beat has a mark: `grep -c TOUR_MARK marks.txt` should print 15 (14 +
  END). A missing one means that screen was unreachable; `activities.txt`
  names it.
- Total under 150 s in the build report for the full cut. If it runs long,
  the usual cause is a slow narration file (`--fit` speeds the picture to
  match it, but only up to `--max-speed`) — regenerate that one segment a
  touch faster rather than cutting words from `SCRIPT.md`.

## Known limits under `-uiTesting`

- Beat 06 (share the link) and beat 11 (leads) show the Leads banner and the
  Leads screen, not a completed publish — the render ("Create my tour", beat
  05) is skipped by default for time (`TOUR_RENDER=1` runs it for a look),
  so there is no published listing to generate a real share link from. The
  narration describes the share link and the MLS-safe link; it does not claim
  the beat shows one being copied.
- The in-app camera ("Record a walkthrough") cannot run in the simulator; the
  button sits on screen in beat 03 and is named in the narration, not opened.
- RoomPlan scanning needs LiDAR; beat 10's floor plan screen shows the upload
  path instead.
- Nothing is purchased, deleted, AI-edited, generated, recorded, or published
  by the tour, ever — see `OnboardingTour.swift`'s own file header, "THINGS
  THIS TEST NEVER DOES."
- No price is ever spoken or shown; "free for 7 days" (the CTA card) is the
  one number this video states, and it is true on every plan.
