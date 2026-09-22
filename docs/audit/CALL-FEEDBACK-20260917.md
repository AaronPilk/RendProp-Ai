# The call, 17 Sep 2026 — what two real users found

Source: `Call_with_Stephenie_Tocado_2.m4a`, 14 min 31 s, transcribed on device.
Speakers: **Stephenie Tocado**, a working real-estate agent, 57, using the app
for the first time on her own listing; **Aaron**, narrating for the record; and
**Richard**'s declutter test, relayed by Aaron.

Both speakers address the build agents by name on the tape and mark when they
start and stop talking. This document is the transcript turned into work.

---

## 1. The app would not let her create a listing without a video

Her first run, verbatim:

> "When I first opened the app and I had to add my home, so I added the house,
> the very first thing, all I saw was an option was to take a video or upload a
> video. It did not say, do you want to take pictures right now? So I did my
> video and then after my video tour, then I have to scroll down and go to an
> area called toolboxes and I see something called photos."

Aaron's read of it:

> "Maybe my mom is in a rush and doesn't want to take the video, but just wants
> to take the pictures. But she can't create a home listing without uploading a
> video first, which breaks the entire system down from the very beginning. It
> makes it so it doesn't work at all."

**This was not a bug. It was a written decision.** `NewListingView.swift`
carried it in a comment: *"The listing is created ONLY once a usable video
exists (decision A4) — cancelling a picker never leaves a 'Not finished' card
behind."* A4 was protecting something real: a cancelled picker should not mint a
half-made listing. What nobody priced was the other half — that photos, floor
plans, the share link and every tool in the toolbox all hang off a listing, and
the only door to a listing was a five-minute video.

Her fix, in her own words:

> "Then it should ask me, what do I want to do next? Do I want to take a video
> or do I want to do pictures? Not every property needs a video."

**Shipped.** Step 2 is now *Photos or video*, with a third button — **Start with
photos** — that creates the listing and opens straight onto its photo library.
A4's real rule is kept intact: the listing is created on a deliberate commitment
(a button press), never on a dismissed sheet. A listing with no video was
*already* a supported state everywhere else in the app — `AddVideoFlowView` and
the "Add a walkthrough video" card exist for exactly it. It was only
uncreatable.

## 2. Typing the address

> "It's annoying to have to type in the address and right now there's not a
> feature installed where you can start typing the address in and it pulls
> Google Maps or Apple Maps data."

Correct, and already fixed two days earlier on `claude/ux-wave-20260915`
(`AddressCompleter`, `MKLocalSearchCompleter` — no key, no vendor, no cost row).
It has not reached her phone because that branch has not been cut to TestFlight.
**Nothing to build. This one is a build cut.**

## 3. Pause and resume the walkthrough

> "I would take the video and my client would accidentally come out in front of
> me. I need a feature… to be able to pause the video and then restart it in
> case you have run into a person or something."

Her only options were to keep filming the client or shoot the house again.

**Shipped.** `AVCaptureMovieFileOutput` has no pause on iOS, so a pause closes
the current file and a resume opens the next; `CameraManager` banks the pieces
and `TakeJoiner` joins them passthrough — no re-encode, so a 4K take does not
spend minutes and quality being glued together.

Three things this had to get right and does:

- **The ten-minute ceiling is on the take, not the piece.** Each resume gets
  `max − banked`, or a paused take would earn a fresh ten minutes every time.
- **Room tags land on the joined clock.** `currentRecordedSeconds` is
  `banked + current`, so a tag tapped after two pauses points at the frame it
  was tapped on.
- **So does the motion sidecar.** `MotionRecorder` now subtracts the paused
  interval from every sample; without that, a 30-second hold would put every
  later sample 30 seconds past the frame it describes.

Tagging works while held — pausing to name a room is exactly when someone
reaches for it. If the join ever fails, the review card says so and hands back
the first piece rather than pretending: *never lose footage* (master spec 4.2).

## 4. The photographer in the mirror

> "It needs to be able to take out any images of the photographer from the glare
> of mirrors or windows. There's a lot of images where you can see my entire
> body and face in the glare of a window or a mirror."

**Shipped**, riding Declutter rather than becoming its own mode — a new edit
mode is a new billable route, a new ledger row, a new provenance kind and a new
disclosure sentence, and "a person who is not part of the property" is already
what Declutter means. The prompt now rebuilds the reflection as the empty
surface would look. It also aligns with the HUD guidance this product already
follows, which says AI listing media should not be rendering people at all.

## 5. Richard's declutter, and the honesty problem

Richard's test worked — and made the front lawn very green. His objection is the
one that matters:

> "When somebody sees these pictures and then they go and look at the house it's
> going to be like a night and day difference."

Aaron's ask:

> "A scrolling left and right feature where it says actuality, which would mean
> how it looks now, or like before — and then what it could look like."

**Shipped.** The tour page already showed before and after side by side inside
the disclosure section. Side by side is compared from memory; one image with a
line through it is compared by eye, and the difference is the whole point. It is
now a drag.

One constraint worth writing down for whoever edits it next: **it is an ARIA
slider on a `div`, not a range input.** `<input` is a forbidden token on the
MLS-safe `/u/` twin and the disclosure section renders on both pages. Without
JavaScript it degrades to the existing compliant side-by-side pair — same two
figures, no second copy of either image.

## 6. The line she drew, and the hole it found

This is the most valuable thing on the tape. Stephenie, as a licensed agent,
describing what she may and may not do:

> "You can do things for like maybe design of the house, but you cannot remove
> things that are there… Let's say that there's a big, huge power pole in the
> backyard. Agents were removing the power pole… If there's a huge crack in the
> wall, you're not supposed to fix that. That should be in the picture."

Aaron: *"No, we will never do that."*

**We could have.** `ai-photo/index.ts` appends a `LOCK` to every prompt, and
`LOCK` protected *architecture* — walls, dimensions, window and door placement.
It said nothing about **condition**. Ask an inpainting model to tidy a room and
it will smooth a cracked wall or a water stain on the way past, because a clean
wall is what "tidy" looks like in its training data. Nothing in the file told it
not to.

**Shipped:** a `CONDITION_LOCK` on every route, `LOCK` and `STAGE_LOCK` alike.
Cracks, holes, stains, damp, rust, peeling paint, damaged flooring, broken
glass, worn fixtures — and permanent surroundings: power poles and lines, meters
and utility boxes, antennas, AC units, pool cages, fences, neighbouring
buildings, whatever is visible through a window. All stay. One carve-out, named
explicitly so the instruction does not contradict itself: grass, planting and
sky may be improved **when that is what was asked for**, and nothing about the
building, the hardscape or the surroundings may be.

This is not only an ethics position. A defect edited out of a listing photo is a
misrepresentation of a material fact, and it is the one edit no disclosure
sentence makes acceptable — the buyer's complaint is never "this was AI", it is
"the house is not what you showed me".

## 7. How old is this media

Her own story, as the person on the receiving end:

> "I looked at a house when I moved down here to St. Petersburg… Every picture
> of the home looked absolutely perfect… And when I came down here, the house
> looked completely different from how it looked in my image. And I was pissed
> at my landlord."

The photos were five years old. Her fix: *"there's like a time stamp on the
picture of the date that it was taken."*

**Shipped, partially.** `published_at` was in the tour payload the whole time
and rendered nowhere; the gallery now carries *"This tour was published on
<date>."* It is the publication date, not the shutter date, and the sentence
says publication and claims nothing more — an overstated provenance line is the
same failure in a nicer suit.

**Still open, and it needs a server change:** a true per-photo capture date
means putting `taken_at` on gallery items in the `tours` function payload. That
is a live production deploy and is flagged rather than done.

## 8. Tour length scales with the property

> "Some of these homes could be 15,000 square feet… it could be 12 to 15 minutes
> long. Or if it's a 1,900 square foot apartment, it'd be three minutes. If it's
> a 1,000 square foot house or apartment or condo, it could be a minute and 45
> seconds."

Consistent with the position already held since the 4,000 sq ft field test:
tour length is handled by the render's `speedFactor`, never by telling an agent
to walk faster. The 28-viewport scroll ceiling shipped on
`claude/ux-wave-20260915` is the other half of this — a 6:50 walkthrough used to
build a 203-screen scroll track before the viewer could reach the contact form.

---

## The pattern

Every UX defect in this product so far has been found by someone **outside the
build** — an older broker who followed none of the instructions, and now a
working agent who could not create a listing. Not by testing, not by audit. The
two people using it are the actual customer.

The instruction that closed Aaron's segment is the right one and worth keeping
as the standing rule for this kind of work:

> "Reevaluate the code and simulate and test every aspect of the app and then
> report back to me and rebuild everything with the new UX structure, keeping UI
> intact."

Change the flow. Keep the design.
