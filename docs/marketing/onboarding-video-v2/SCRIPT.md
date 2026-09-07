# Rendprop — onboarding video v2 script ("Every listing looks the same.")

A narrated, ad-grade ~105 s walkthrough of the real app, recorded from the iOS
simulator: a cold open, one feature per beat in the order a real first project
happens, a loop-back hook roughly every 20 s, and a closing CTA. Not an App
Store *App Preview* (those have their own rules) — a plain MP4 for
rendprop.com, the first-run "Watch the sample tour" slot, and paid social.

This supersedes `docs/marketing/onboarding-video-script.md` (v1, the 6 Sep
cut) as the shooting script. v1 stays as-is for its own record — see that
file's own README for how it was built. v2 needs a fresh take: the beat order
changed (the cold open is new footage-in-front, "share" split out of
"leads", the six-industries switch moved to the end), so v1's take cannot be
re-cut against this script.

**Voice:** the app's own — plain, calm, second person, one idea per beat. No
hype adjectives, ever — "seamless", "effortless", "powerful" do not appear
here and should not creep into a re-record. Say only what the screen shows or
what the app's own copy already says (`docs/appstore/metadata/en-US/description.txt`,
`docs/INDUSTRY-LOGIC.md`, `services/edge/tour-host/public/*.html`) — nothing
invented, no price ever spoken (prices come from StoreKit; "free for 7 days"
is the one number this video says, and it is true on every plan).

**Format of each beat** (`tools/video/build_onboarding.py` parses these
headings and fields — keep the shape):

```
## NN · M:SS–M:SS · Title
On screen: the UI action OnboardingTour.swift performs (ignored by the build)
Say: the spoken line              ≤ 28 words, second person, plain
Caption: the burned-in caption    ≤ 9 words, bottom third
Hook: a loop-back tease           optional — burned in top-of-frame as the
                                   beat's narration ends; only on ~4 beats,
                                   spaced ~20 s apart (see cadence below)
Trim: N s                         optional — cap this beat's take footage to
                                   its first N seconds before pacing (a render
                                   wait, a long load)
```

Times are **targets**; the real cut points come from the `TOUR_MARK` lines
`OnboardingTour.swift` writes while it runs. A narration longer than its
segment freezes the last frame until it ends (`build_onboarding.py --fit`
paces every beat to its line instead, which is how this v2 take should be cut
— see the v2 README).

**Total:** ~100 s of app footage, cold open included, no title card
(`--title-seconds 0` — the cold open IS the open) + a 3 s CTA card + a 2 s
"rendprop.com" card ≈ **105 s**, inside the 90–120 s target.

**Hook cadence** (loop-back teases, ~20 s apart): after **02** (≈0:18), after
**05** (≈0:40), after **07** (≈0:57), after **10** (≈1:19). Nothing after
**12** — by then the CTA is seconds away and there is nothing left to tease.

---

## 00 · 0:00–0:03 · Cold open

On screen: Cold launch straight to Home, scrolled down to the demo card. Tap
"Watch the sample tour." The hosted demo listing page opens; one slow drag
inside it and the house flies past as the page scrolls.

Say: Every listing looks the same. Until yours flies.

Caption: Until yours flies

## 01 · 0:03–0:11 · This is Rendprop

On screen: Home hero — "Win the listing. Skip the film crew." A slow scroll
down to "Make something" and back up to the hero.

Say: This is Rendprop. Walk through a space with your phone, and it becomes a
cinematic tour with a link you can send.

Caption: One walkthrough. One tour. One link.

## 02 · 0:11–0:18 · Start with the space

On screen: Tap "Add a home." On the New Home form, type "24 Willow Bend
Court" into the address field, dismiss the keyboard, rest on "Step 2 · The
video."

Say: Start with the space. Give it a name or address — everything you make is
saved to it.

Caption: Add the space — everything saves to it

Hook: Wait for the one-tap sky and twilight fix.

## 03 · 0:18–0:26 · Film or upload the walk

On screen: Tap "Upload a video." The "Where is your video?" sheet offers
Photos or Files. Choose Photos, pick the walkthrough clip, and it imports
straight into Review & Submit. ("Record a walkthrough" is the other button —
the in-app camera can't run in the simulator, so it is named, not opened.)

Say: Record in the app — it coaches your pace and keeps you on the wide lens
— or upload a clip you already have.

Caption: Record in the app, or upload a clip

## 04 · 0:26–0:33 · Tag rooms, get chapters

On screen: Tap "Tag rooms on the video." In the tagger, tap "Entry" at the
start, scrub forward, tap "Kitchen," then Done. Review & Submit now lists
both rooms with their timestamps.

Say: Tag the rooms as you walk past them — tap a dot on the tour to jump
straight there.

Caption: Tag rooms → tap-to-jump chapters

## 05 · 0:33–0:40 · Create the tour

On screen: Scroll to "Pick your quality" and the "Create my tour" button.
Rest there. (Not tapped in the standard recording — a render takes a minute
in the simulator; `TOUR_RENDER=1` taps it and waits, for a look.)

Say: Pick a quality and tap Create my tour — Rendprop renders the flythrough
right on your phone.

Caption: Renders the flythrough on your phone

Hook: Coming up — your own voice becomes captions.

## 06 · 0:40–0:48 · Share the link

On screen: Back on Home, scroll to the Leads banner — "Every tour is one
link with a lead form built in. Leads appear here." Rest on it; not tapped
yet (that is beat 11).

Say: You get a share link with your card and a contact form — plus, for real
estate, an unbranded link that's MLS-safe.

Caption: A share link, plus an MLS-safe link

## 07 · 0:48–0:57 · AI Photo Studio

On screen: Home → "Take photos" → the AI Photo Studio for the home. The
one-tap edits are listed: twilight, blue sky, green lawn, tidy the room, add
furniture. Two photos are added from the library; the grid shows a wand on
each and the disclosure line. No edit is run.

Say: The AI Photo Studio fixes your photos in one tap — blue sky, twilight, a
green lawn, decluttering, or staged furniture — always labeled, original
included.

Caption: One-tap AI edits — every edit labeled

Hook: Stick around for the AI aerial shot.

## 08 · 0:57–1:05 · A reel, in your own voice

On screen: Tap "Make a reel." In Reel Studio, scroll to "STEP 2 · ADD YOUR
VOICE" and tap "My voice" — the Record button and "Your words become
captions on the video." Close without recording.

Say: Turn your photos into a short reel — record your own voiceover, and
your words become word-by-word captions automatically.

Caption: Your voice becomes word-by-word captions

## 09 · 1:05–1:12 · Aerial intro

On screen: Open the home from Home. In its toolbox tap "Aerial intro" — the
sheet shows the shot settings and, above them, the always-visible AI
disclosure. Close it — nothing is generated.

Say: Add an aerial intro — an AI opening shot that lifts off a photo you
already have, always disclosed as AI.

Caption: An AI aerial opening — always disclosed

## 10 · 1:12–1:19 · Floor plan

On screen: Still in the toolbox, tap "Floor plan": scan a room in 3D on a
LiDAR iPhone, or upload a plan (the simulator has no LiDAR, so it shows the
upload path — expected).

Say: Add a floor plan too — scan a room in 3D on supported iPhones, or upload
one you already have.

Caption: Floor plan — scan in 3D or upload

Hook: This works for gyms and restaurants too.

## 11 · 1:19–1:26 · Leads inbox

On screen: Back on Home, tap the same Leads banner. The Leads screen opens
("No leads yet" on a fresh install).

Say: Every enquiry from your tour lands right here, in Leads, so nothing gets
lost in a text thread.

Caption: Enquiries land here, in Leads

## 12 · 1:26–1:37 · Six kinds of space

On screen: Tap the business-type capsule at the top left. The menu lists all
six types. Pick "Event venue" — Home re-themes to "Book the date before they
ever visit." Open the menu again and switch back to "Real estate."

Say: This isn't only for homes. Six kinds of space — real estate, venues,
restaurants and bars, retail, gyms, or anything else — and the whole app
matches yours.

Caption: Six kinds of space, six different apps

## 13 · 1:37–1:42 · The honest line

On screen: Back on Home, resting on the hero.

Say: AI edits are always labeled — in the app, and on every tour you
publish.

Caption: AI edits are always labeled

---

## Cards (generated by the build, not filmed)

No title card — `--title-seconds 0` makes beat 00 the cold open. After beat
13:

- **CTA card**, 3 s, caption style — `--end-card "Try it out now — free for 7 days"`
- **Brand card**, 2 s, the existing look — `--end1 "rendprop.com"` /
  `--end2 "Rendprop on the App Store"` (both are the build's own defaults —
  no flag needed unless you want to change them)

---

## 30-Second Cut-Down

Four beats, same take and marks as the full cut: the cold open, a condensed
"this is Rendprop," a condensed AI Photo Studio, and a condensed six-spaces
beat — the fastest path to "this looks different and it's not just houses."
No hooks (nothing left to loop back for in 30 s). Build it with the SAME
`tour-raw.mp4` / `marks.txt` from the one recording, pointed at
**`SCRIPT-30s.md`** (a sibling of this file) with `--only-scripted` — see the
v2 README's exact command. Full text, so it reads standalone:

| id | Say (condensed) | Caption |
|----|----|----|
| 00 | Every listing looks the same. Until yours flies. | Until yours flies |
| 01 | This is Rendprop — walk a space with your phone, and it becomes a tour with a link you can send. | One walkthrough. One tour. One link. |
| 07 | The AI Photo Studio fixes your photos in one tap — always labeled, original included. | One-tap AI edits — every edit labeled |
| 12 | And it isn't only for homes — venues, restaurants, retail, gyms, or anything else, all in the same app. | Six kinds of space, six different apps |

Target: ~23 s of beats + the 3 s CTA card + the 2 s brand card ≈ 28–30 s.

## 15-Second Cut-Down

Three beats — the absolute minimum that still shows the hook, the product,
and that it isn't just for homes — in **`SCRIPT-15s.md`**:

| id | Say (ultra-condensed) | Caption |
|----|----|----|
| 00 | Every listing looks the same. Until yours flies. | Until yours flies |
| 01 | This is Rendprop — a phone walkthrough becomes a tour you can send. | One walkthrough. One tour. One link. |
| 12 | It works for homes, venues, restaurants, retail, or gyms. | Six kinds of space, six different apps |

Target: ~11 s of beats + a 2 s CTA card + a 2 s brand card ≈ 15 s (use
`--end-card-seconds 2` for this one — the full 3 s reads slow at 15 s total).

---

## Notes for whoever records the voice

- Pace: about 2.5–3 words a second. Every `Say:` line above is under that for
  its slot; if a take runs long, `--fit` speeds the picture up to match
  rather than cutting words — see the v2 README.
- Pronounce it "Rend-prop." "MLS" is spelled out. No price is ever spoken.
- One file per segment id: `narration/00.mp3` … `narration/13.mp3`
  (`.wav`/`.m4a` also fine) — `tools/video/narrate_elevenlabs.py --script
  SCRIPT.md --out narration/` does this from an ElevenLabs voice; see that
  tool's own `--help` and the v2 README for the exact command.
- A beat that is cut from the recording (its `TOUR_MARK` is missing) has its
  narration and caption dropped too — the video never talks about a screen it
  does not show.
- Never invent a feature, a number, or a claim. Every `Say:` line above traces
  to real app copy or the App Store description — check
  `docs/appstore/metadata/en-US/description.txt` and `docs/INDUSTRY-LOGIC.md`
  before changing one.
