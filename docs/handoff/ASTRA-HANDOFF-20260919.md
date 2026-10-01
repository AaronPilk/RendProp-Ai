# Astra handoff — 19 Sep 2026

You are GPT-6 Astra working the Rendprop repo alongside Claude. You have been
idle since 14 Sep. Claude shipped two waves in that gap and they are on real
users' phones without ever having been audited. Your job is to find what is
wrong with them, then build the one thing Claude deliberately stopped short of.

Work on your own branch off `claude/call-fixes-20260917`. Do not force-push a
shared branch. Claude works this repo in parallel — fetch and integrate.

---

## State of truth

- Repo `github.com/AaronPilk/RendProp-Ai`, local `~/Rendprop AI/RendProp-Ai`.
- **`claude/call-fixes-20260917` at `7bcc624` is the tip.** It is 10 commits
  ahead of `origin/main` and `main` has nothing that is not in it. Main is
  stale; do not branch from it.
- Shipped to TestFlight and in use: **1.0.3 (29)**, internal group "Rendprop
  team", `IN_BETA_TESTING`. 1.0.2 is APPROVED AND LIVE on the App Store — its
  train is closed, so any new build is 1.0.3+ and build numbers must be
  monotonic across the whole app, not per train.
- Migrations applied through **0054**. Next free number is **0055**.
- Your last work was the spatial ablation (30,000 steps → 21.48 PSNR, best so
  far, still below acceptance; SOG export 632 s against a 600 s allowance).
  Spatial stays OFF and is not this handoff.
- You have a `feat/agent-reel` branch with interrupted WIP from 15 Sep. Say so
  if you intend to pick it back up; it is not part of this task.

### What the two waves changed (review range `8d32f85..7bcc624`)

**Wave 1, `0e0501c`** — six UX defects from TestFlight walks: the render
percentage was gated to one stage; a lead's phone and email had merged into one
accessibility element so the phone opened Mail; disabled buttons only changed
alpha; `MKLocalSearchCompleter` address autocomplete; the first-project guide
moved above the hero on Home; and `player.ts` got a 28-viewport ceiling on the
scroll track (a 6:50 tour was building a 203-screen scroll before the lead form
came into reach) plus a `#skiptodetails` control behind a new `SKIP_SLOT`.

**Wave 2, `4a4ba2c` + `7bcc624`** — from a recorded call with the owner's
mother, a working real-estate agent, and his stepdad. Read
`docs/audit/CALL-FEEDBACK-20260917.md` and the transcript beside it before you
touch anything; it is the requirements document for this wave.

1. **Photos without a video.** She could not create a listing at all without
   shooting one. That was decision A4 in `NewListingView.swift` ("the listing is
   created ONLY once a usable video exists"). A4 was amended, not deleted — a
   new "Start with photos" button creates the listing on a deliberate press and
   pushes `FlythroughDetailView(listing:openPhotosOnAppear:)`.
2. **Pause and resume mid-take.** `AVCaptureMovieFileOutput` has no pause on
   iOS, so `CameraManager` now records one file per stretch, banks them in
   `segments`/`bankedSeconds`, and `TakeJoiner` (bottom of `CaptureView.swift`)
   joins them with `AVAssetExportPresetPassthrough`. Room tags and the motion
   sidecar run on the JOINED clock — `MotionRecorder` subtracts the paused
   interval.
3. **Before/after drag** on the tour page's disclosure section. ARIA slider on a
   `div`, never `<input type="range">` — `<input` is a forbidden token on the
   MLS-safe `/u/` twin and that section renders on both pages.
4. **`CONDITION_LOCK`** in `services/supabase/functions/ai-photo/index.ts`. The
   existing `LOCK` protected architecture and said nothing about condition, so
   an inpainting model asked to tidy a room was free to smooth a cracked wall.
   Defects, wear and permanent surroundings now stay as photographed, with one
   named carve-out for grass/planting/sky.
5. **Media date** on the tour page gallery from `published_at`.
6. **Person-in-shot detection** (`7bcc624`). Vision runs on the ~2 Hz buffer the
   light meter already samples; an amber banner warns while filming and the
   ranges land on `CaptureAsset.personVisibleRanges`. **Nothing consumes those
   ranges yet** — that is Task 2.

---

## Hard constraints — these are not negotiable

- **Never lose footage.** Master spec 4.2. This is the single most important
  invariant in the capture path and Task 1 is mostly about it.
- **Never delete production data.** No `DELETE /me` against production, and
  never suggest the in-app delete-account flow as a test path — that has already
  destroyed a real org once.
- **Never enable a disabled `ai_routes` row.** Kie and Higgsfield video routes
  stay disabled pending written no-training terms.
- **The fair-housing gate stays server-side** (`_shared/fairhousing.ts`), on
  input and output. No client-side move, no bypass.
- **Keys are never printed, echoed, committed or pasted into a message.** Read
  into env vars or files only. Public site/anon keys may be pasted.
- **Do not touch App Store Connect prices.**
- US-only launch. No i18n.
- Contact email is `Aaron@pilk.ai`. Never `skyway.media`, anywhere.
- No customer media to Fable/Mythos; no customer media or raw room geometry
  committed to Git.

---

## Task 1 — adversarially audit the two waves. This gates the merge to main.

Your proven value on this repo is returning NO-GO with reproducers. Two prior
audits found real P1s that would have shipped: `/adopt` fetching the caller's
membership role and discarding it, and `team/accept` inserting the membership
before consuming the invite so two users racing one code both became members.
Do that again, on this.

**Scope:** commit range `8d32f85..7bcc624`. Weight it toward the capture path —
that is where footage lives, it is the newest code, and a bug there costs
somebody a walkthrough of a house they have already left.

**The bar:** offline execution of the real functions, with reproducers, not
reasoning about the source. A finding without a way to trigger it is a
hypothesis; say so when that is what you have.

**Where Claude would look first** — its own honest list of what it is least sure
about. Treat these as leads, not as the boundary of the audit:

- `pendingEnd` is written on main (`pauseRecording`, `stopRecording`,
  `cancelTake`) and read on main inside the delegate's dispatch, while
  `movieOutput.stopRecording()` goes out on `sessionQueue`. Convince yourself
  there is no ordering where a pause and a stop interleave and a segment is
  banked under the wrong intent.
- `resumeRecording()` guards on `session.isRunning` and **returns silently when
  it is false**. A phone call mid-hold would make Resume do nothing with no
  feedback. The storage guard in the same function sets a visible message; this
  path does not. Claude thinks this is a real defect.
- `maxRecordedDuration` is set per segment to `max(1, 600 - banked)`. Work out
  what happens when a pause lands within a second of the cap firing.
- `TakeJoiner` uses `AVAssetExportPresetPassthrough`, which requires every piece
  to share a format. `reselectFormat` is documented as "between takes only", but
  check `toggleLens()` mid-take, a thermal downgrade mid-take, and an
  interruption/resume cycle. If passthrough can ever be handed mismatched
  tracks, the join fails and the fallback hands back only the first piece.
- The join failure path keeps the remaining pieces on disk and tells the user.
  Verify they are actually reachable afterwards and not orphaned in
  `Recordings/` forever.
- `closePersonRange` merges ranges within 1 s and drops anything under 0.75 s.
  Check the arithmetic across a pause boundary — the ranges must be on the
  joined clock, and a range opened before a pause and closed after a resume must
  not span the removed interval.
- The Vision pass runs `VNImageRequestHandler` with `orientation: .right` on the
  luma queue at ~2 Hz. Measure the thermal and battery cost on a real 10-minute
  4K take before agreeing it is free. If it is not, say so.
- `player.ts`: confirm the drag slider changes nothing in the `/u/` render, that
  `touch-action: pan-y` does not swallow vertical scroll on a phone, and that
  the no-JS path still emits the compliant side-by-side pair.
- `CONDITION_LOCK` is a prompt change on a live route. Run real before/after
  images through declutter and staging and report whether output quality
  degraded — a guardrail that makes every edit worse is a different kind of bug.
- Claude broke the unbranded gate once in this wave by putting a backtick inside
  a comment within a TypeScript template literal, which closed the literal. Grep
  for that class of mistake rather than trusting that the gate would have caught
  every instance.

**Deliver:** GO or NO-GO for merging `claude/call-fixes-20260917` into `main`,
a findings file under `docs/audit/`, and reproducers. Rank by whether a real
user loses data, money, or trust.

---

## Task 2 — make the video reflection removal actually run. Only after Task 1.

The owner asked for this directly: *"the ai function when shooting a video
should automatically remove you from mirrors and reflections."* Build 29 records
where it happened. Nothing acts on it yet.

**The constraint that decides the whole design.** `/ai-video/declutter` already
exists — `MODEL_DECLUTTER = "bria/video/erase/prompt"`, prompt-based object
removal. **Bria rejects sources of five seconds or more**, and the route
pre-checks `duration_s` and 409s without it because Bria bills before it
rejects (audit F-supabase-29). A walkthrough is two to fifteen minutes.

**The arithmetic.** A render's budgeted COGS is 240¢ (`_shared/ledger.ts
APP_AI_UNIT_CENTS`: render 240c, photo edit 4c, reel 24c, aerial 80c). Erasing a
whole six-minute take is ~72 five-second clips at the reel rate — about $17.28
and 72 sequential GPU jobs, against a $2.40 budget. Erasing only the seconds
somebody was visible is three or four clips, under a dollar. That gap is the
entire reason `personVisibleRanges` exists.

**Build:**

1. Cut each range to a clip strictly under 5 s on-device (split a longer range
   into consecutive clips). Reuse the `AVAssetExportSession` pattern already in
   `TakeJoiner`.
2. Upload each clip through the existing `UploadManager` path so it gets a real
   `asset_id` with a probed `duration_s`.
3. `POST /ai-video/declutter` per clip with an erase prompt naming the
   photographer and reflected people. Poll `GET /ai-video/status`.
4. Download, splice the erased clips back over their original ranges, re-render.
5. Surface it honestly. It is AI-altered media: it needs a provenance row and a
   disclosure sentence like every other edit. The route already writes those —
   confirm the disclosure that reaches the public page is truthful about what
   was removed.

**Money-path rules for this build**, because this is where the previous audits
found everything: charge once per clip and never on a pre-flight rejection;
refund on failure (`refundRateLimit` has been forgotten before — `ai-photo` and
`ai-video` both shipped without calling it); respect the cap, which comes out of
the `reels_per_month` pool; and make a cancelled job leave no charge behind.

**Before it ships, get a real Bria price.** The ledger currently records
`price_estimated: true` with no committed number — see HANDOFF-DB.md, "Known
gap: bria/video/erase/prompt". Any figure quoted to a customer before that is
made up.

**Make it opt-in for now.** A silent, billable step between Stop and a finished
tour is not something to switch on by default before anyone has seen its output.
A clear control on the review screen naming how many seconds it will process is
the right shape.

---

## Verification bar

Nothing is "done" until all of this is green, and say so with the real numbers:

- `services/edge/tour-host`: `npx tsc --noEmit` clean, and `npm test` — seven
  gates, currently **2,698 assertions** with the unbranded gate at **693**. If
  your change moves those counts, say why.
- `deno check` clean on any edge function you touch.
- `xcodebuild -scheme Rendprop` → `** BUILD SUCCEEDED **`.
- Migrations: start at **0055**, replay every migration in order against a real
  Postgres in a container before going near production, and apply twice to prove
  idempotency. That method caught two would-be production incidents on 0050.

## Things that have bitten this repo — do not re-learn these

- `create or replace` cannot change a function's return type. Drop first.
- `insert into orgs ... returning` inside a CTE plus a call to
  `org_seats_allowed()` in the same statement reads the pre-statement snapshot
  and returns defaults. Separate statements.
- A new plan value must be added to `_shared/router.ts` `PLAN_ORDER` and
  `coach/index.ts KNOWN_PLANS`, or `planRank()` silently returns 0 ("free") and
  a paying customer is routed to the cheapest model.
- Turnstile needs the site key on the Cloudflare Worker FIRST and the secret on
  Supabase SECOND. Secret-first takes the lead form down.
- Replying in Resolution Center does not resume an App Review. Only "Update
  Review" → "Resubmit to App Review" does.
- Do not run `npm ci` from a Linux shell against the macOS tree — it installs
  Linux workerd binaries and the next bridge build fails.

Report back with findings first. Do not start Task 2 until Task 1 has an answer.
