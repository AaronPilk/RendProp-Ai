# Rendprop — Standing Brief for an Autonomous Build Agent

You are working on **Rendprop**, a shipping iOS app (bundle `com.rendprop.app`, App Store
Connect id 6808982413). Version 1.0 build 16 is **in App Review right now**. There are real
users' files, a real production database, and real money moving through AI providers on every
request you touch.

Read this file completely before your first edit. Re-read §1 and §2 before every deploy.

---

## 0. What Rendprop is

An agent films a walkthrough on their iPhone. Rendprop turns it into a scroll-driven
"drone-style" property tour hosted on the web, plus AI photo edits, aerial intros, reels, a
floor plan from LiDAR, a landing page and lead capture. Subscriptions are StoreKit 2, five
products in one group, and **no account is required for anything** — that is a Guideline
5.1.1(v) constraint the app was rejected over twice, not a preference.

**Repo:** `github.com/AaronPilk/RendProp-Ai`
**Stack:** SwiftUI + AVFoundation (iOS) · Supabase Postgres + Deno edge functions · Cloudflare
Worker (`services/edge/tour-host`) serving the public tour pages · R2 + Cloudflare Stream ·
a routed multi-vendor AI layer (`ai_routes` + `_shared/providers/chain.ts`).

Layout that matters:

```
apps/ios/Rendprop/            SwiftUI app
  Networking/APIClient.swift      the protocol (1,780 lines) — LiveAPIClient + MockAPIClient implement it
  Render/ReelComposer.swift       AVFoundation compositor. compose(shots:renderSize:options:output:)
  Render/RenderEngine.swift       the flythrough render (720p master, encodeLongEdge = 1280)
  Screens/FlythroughDetailView.swift   526 KB. Contains ReelStudioView. Handle with care.
  Auth/AuthStore.swift            isSignedIn vs isIdentified — see §2
services/supabase/functions/  Deno edge functions
  ai-copy/{index,prompt,shotlist,agentreel,guard}.ts
  ai-video/{index,motion,dronecost}.ts
  _shared/{router,supabase,http,fairhousing,ledger,ratelimit}.ts
services/supabase/migrations/ 0001..0034
services/edge/tour-host/      Cloudflare Worker: the public /t/ and /u/ tour pages
docs/                         contracts. LAUNCH-CONTRACT.md is load-bearing (see §2)
```

---

## 1. Hard constraints — violating any of these causes real damage

1. **Never delete production data.** Not to clean up, not to test, not to reset state. A
   previous session destroyed the owner's real workspace by suggesting an in-app "delete
   account" as a test. Three listings were unrecoverable.
2. **Never run `DELETE /me` against production**, and never suggest the in-app delete-account
   flow as a way to test anything.
3. **Never touch App Store Connect prices or metadata.** A submission is pending. Uploading a
   build is safe; *attaching* one or editing the version is not, unless explicitly asked.
4. **Never enable a disabled `ai_routes` row.** `enabled = false` rows carry a reason in their
   `note` — unconfirmed commercial rights, `trains_by_default` privacy tier, or a price that
   breaks the margin. Enabling one silently changes what customer media is sent where, and to
   whom, and at what cost. Kie and Higgsfield are disabled pending written no-training terms.
5. **The fair-housing gate stays server-side.** `_shared/fairhousing.ts` runs on input and on
   output. Do not move it into the client, do not add a bypass, do not weaken a rule to make a
   test pass.
6. **Keys are never printed, echoed, committed, or pasted into a message.** They live at
   `~/Rendprop AI/_bridge/.asc/`, `.supabase-token`, `.elevenlabs-key`, all chmod 600. Read
   them into an env var; never into stdout.
7. **Work on an isolated branch.** Another agent works this repo in parallel. `git fetch` and
   integrate; never assume you own the worktree. Never force-push a shared branch. Current
   heads: `feat/ia-photos-split` (build 16, submitted), `feat/agent-reel` (server side of the
   agent reel), `main` (deliberately behind).
8. **US-only launch.** No i18n work, no non-US territory config.

---

## 2. Invariants this codebase has already been burned by

These are not style notes. Each one shipped a bug.

**`isSignedIn` ≠ `isIdentified`.** `isSignedIn` means "has a session" and is true from first
launch, because the app opens an anonymous Supabase session for itself. `isIdentified` means
"has a real Apple identity" and is read off the JWT's `is_anonymous` claim. **Gate content,
features and purchases on neither.** Ask `isIdentified` only for genuinely cross-device or
account-based things — carrying a workspace to a new device, and team seats. Gating a feature
on either one is what got the app rejected twice.

**`.convertFromSnakeCase` and explicit snake_case `CodingKey`s are mutually exclusive.** The
strategy rewrites the key to camelCase and *then* matches it against `CodingKey.stringValue`,
so `case suggestedReplies = "suggested_replies"` never matches and the decode throws. This made
the AI coach silently answer from its offline fallback for its entire life — while still
billing for the call. Use `decodeExact` (no key strategy) for anything with explicit keys.

**Analytics: four places or nothing.** Adding an event name means editing all four of
`apps/ios/Rendprop/Analytics.swift`, `services/supabase/functions/events/schema.ts`,
`events/events.test.ts`, and `docs/LAUNCH-CONTRACT.md`. The function rejects a *whole batch* on
one unknown name and the client re-queues it, so a device that sends an unknown event jams its
own analytics queue forever. If you are not prepared to do all four, add no event.

**`SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` appears exactly once in `project.pbxproj`.**
`#if DEBUG` can therefore compile a test door out of the very build the tests run against.
Verify which configuration defines it before relying on a DEBUG fence.

**Launch-arg overrides read `ProcessInfo.processInfo.arguments`, never `UserDefaults`.** House
pattern: `Config.uiTestGuideState`. A UI test that sets a default and a build that reads an
argument silently pass each other.

**A `.task` modifier on a `Group` whose only branch is `if let state` is attached to
EmptyView, and never fires.** Use `@StateObject` for anything that must load.

**A 400 does not fail over.** `chain.ts` classifies a rejected request *shape* as `validation`
and rethrows deliberately — asking a second vendor the same malformed question bills you twice.
So a route row with the wrong request shape is a user-visible error, not a silent fallback.

**`defaultPolicyFor()` is dead code.** `plan_routing_policy` is read, cached, and never
applied. `min_plan` is the only working plan lever — `planRank(step.min_plan) > rank` drops the
step. Do not assume a cheap-tier policy is protecting anything.

**Overlapping edits bail silently.** Two edits anchored on overlapping text: the first inserts
before the anchor the second is still looking for, the patch writes nothing, and the build gate
then passes against an unchanged tree and reports success. **Every build script must grep for
the new symbols before it is allowed to build.** "It compiled" means nothing if nothing changed.

**A deploy script that runs tests and then deploys regardless is not a gate.** Exit non-zero
before deploying. A previous violation took every public `/u/` tour page to 503 for four
minutes.

**iOS Keychain survives app deletion.** Delete-and-reinstall is not a clean-install test.

**A test that cannot tell whether it should run must not answer "no".**
`shotlist_test.ts` decided whether to run its two compatibility checks with a
`statSync` inside a bare `catch`, which swallowed a permission error exactly like a
missing file. Run without `--allow-read` and the suite reported "109 passed, 2
ignored" and looked green while the one gate proving `ai-copy` and `ai-video` still
share a move vocabulary never executed. It now rethrows anything that is not
`Deno.errors.NotFound`, so the environment problem is visible instead of silent.
**Treat every "ignored" in a test summary as a claim to verify, not a pass.**

**Nothing that is not the app goes in the app.** The iOS target's sources path is
the whole `Rendprop` directory, so anything left in it is picked up — and a file
xcodegen does not recognise as source becomes a **resource**, shipped inside the
`.app`. A throwaway refactor script, `Screens/ia_split.py`, sat in the Resources
build phase next to `Assets.xcassets` and shipped in build 16 with internal
commentary in its docstring. `project.yml` now excludes `**/*.py`, `**/*.sh`,
`**/*.md` and `**/*.bak`. Before any archive, check what is actually in the bundle:
`grep -oE "/\* [^*]+ in Resources \*/" apps/ios/Rendprop.xcodeproj/project.pbxproj | sort -u`
should list only `Assets.xcassets`, `PrivacyInfo.xcprivacy` and `player`.

---

## 3. Verification is the job, not the last step

The single most common failure on this codebase is a green report over work that did not
happen. Every harness must:

- **Exit non-zero on failure.** `FAIL=1` at each failed check and `exit "$FAIL"` at the end. A
  check that prints "FAIL" and exits 0 is worse than no check.
- **Assert, never print.** Printing a privilege list is not checking it. Compare it.
- **Match the real bytes.** `grep '"ok"'` cannot see `\"ok\"` inside a `::text`-cast JSON
  string. Parse both JSON layers.
- **Race the real routes.** Concurrency claims are proven with two concurrent HTTP requests
  against production endpoints, then verified in the database — not reasoned about.
- **Prove the change landed** before building: grep for the new symbols in the tree.

Test commands that work today:

```bash
# Deno unit tests for the edge functions.
# --allow-read IS REQUIRED and is not cosmetic: shotlist_test.ts imports
# ai-video/motion.ts at runtime to prove the two move vocabularies still agree.
# Without the flag that read is refused and those tests report as "ignored".
cd services/supabase/functions && deno test --allow-net --allow-read --no-check ai-copy/
# 111 tests green across ai-copy, 0 ignored. If you see "ignored", something is
# skipping itself — find out what and why before you trust the run.

# Deploy one edge function (token read into an env var, never printed)
export SUPABASE_ACCESS_TOKEN="$(cat ~/'Rendprop AI'/_bridge/.supabase-token)"
supabase functions deploy ai-copy --project-ref ymgqpbnjpztwjsyvceld

# iOS. THE SIMULATOR IS PINNED BY UDID, not by name — names go stale every time
# Xcode ships. This machine has iPhone 17-series; iPhone 16 Pro is not installed.
SIM=CC58F5C6-C811-4FEB-889A-EF10CE1E7A0E   # iPhone 17 Pro
cd apps/ios && xcodegen generate
xcrun simctl boot "$SIM" 2>/dev/null; xcrun simctl bootstatus "$SIM" -b
xcodebuild build-for-testing -project Rendprop.xcodeproj -scheme Rendprop \
  -destination "platform=iOS Simulator,id=$SIM"
xcodebuild test-without-building -project Rendprop.xcodeproj -scheme Rendprop \
  -destination "platform=iOS Simulator,id=$SIM" \
  -only-testing:RendpropUITests/ReviewerWalk/testReviewerWalk
# If that UDID is gone, list what is there rather than guessing a name:
#   xcrun simctl list devices available | grep iPhone
```

**ReviewerWalk and the main UI walk are the release gate.** Both must be green before any
archive. Neither depends on `#if DEBUG`.

---

## 4. Phase 1 — finish the agent-on-camera reel (start here)

The server side is **built, deployed and verified live** on branch `feat/agent-reel`. The iOS
client does not exist yet. That is your first job.

### What already exists

`POST /ai-copy/agent-reel` (`services/supabase/functions/ai-copy/agentreel.ts`, 486 lines,
31 unit tests). An agent records themselves talking to camera; the route returns an
**edit-decision list** saying which listing photograph covers which sentence and what few words
burn on it. **Nothing is generated.** The agent's face, voice and timing are real footage.

Request:

```json
{ "listing_id": "…", "subject": "listing" | "agent", "tone": "punchy",
  "clip_seconds": 60.0,
  "transcript": [ { "t": 0.0, "text": "Hey, I'm Aaron…" }, … ],
  "photos":     [ { "id": "p_kitchen", "room": "Kitchen", "caption_hint": "waterfall island" }, … ],
  "facts": { "tagline": "…", "region": "…", "details": { "beds": "4", "price": "$695,000" } } }
```

Response:

```json
{ "subject": "listing", "clip_seconds": 60, "covered_seconds": 11.6, "face_seconds": 48.4,
  "model": "claude-sonnet-5",
  "cutaways": [
    { "window_id": "w1", "start": 3.2, "end": 6.4, "photo_id": "p_front",
      "room": "Exterior Front", "motion": "push_in", "on_screen_text": "JUST LISTED" },
    { "window_id": "w3", "start": 34.2, "end": 37.5, "photo_id": "",
      "room": "", "motion": "push_in", "on_screen_text": "" }
  ] }
```

An **empty `photo_id` is a legitimate answer**, not an error: the reel deliberately stays on the
agent's face for that window. Render it that way. A window that holds on the agent beats one
showing a bathroom while they talk about the school district.

The server owns the structure deterministically (`planWindows`): the first 2.0 s and last 1.5 s
stay on the face, cuts land only on transcript phrase boundaries, ≥1.2 s of face between any two
cutaways, b-roll ≤55 % of the take, no photo twice in a row, every window 1.6–3.5 s. **Do not
re-derive or override any of that on the client.** Render exactly what you are given.

Routing: `copy.agent_reel` — astra at position 1 gated to `min_plan = 'pro'`, claude-sonnet-5 at
position 2 for everyone else. Measured cost: **1.5 ¢ for a 60-second reel.**

### What to build

1. **Capture.** A screen to record a talking-head clip or import one from the photo library.
   Vertical, 9:16. Enforce `MIN_CLIP_SECONDS = 6` and `MAX_CLIP_SECONDS = 180` on the client so
   the user learns before they upload, not after.
2. **On-device transcription with phrase timings.** `SFSpeechRecognizer` with
   `requiresOnDeviceRecognition = true` (or `SpeechAnalyzer`/`SpeechTranscriber` where the
   deployment target allows). **Phrase-level, not word-level** — word timings quadruple the
   prompt and buy nothing, because the planner snaps to phrase boundaries anyway. This must be
   free and offline; do not add a server transcription route.
3. **The API call.** Add `aiCopyAgentReel(_:)` to `APIClient`, `LiveAPIClient` **and**
   `MockAPIClient` — the protocol is implemented by all three and the mock backs the screenshot
   walk. Mirror `aiCopyShotlist` exactly, including `decodeExact`.
4. **Execute the EDL in `ReelComposer`.** Extend, do not rewrite. The existing
   `compose(shots:renderSize:options:output:)` already does Ken Burns moves, captions in three
   styles, transitions and a voiceover mix. An agent reel is the talking-head clip as the base
   track, with each cutaway's photograph composited over `start…end` using its `motion`, and
   `on_screen_text` in the existing caption style. The agent's original audio is continuous
   underneath and is never ducked or cut.
5. **Where it lives.** `ReelStudioView` (inside `Screens/FlythroughDetailView.swift`) is the
   home for reels, and the FILES section on the listing screen lists finished ones. Follow the
   owner's standing rule: **an unlabelled control is invisible to an average agent** — no bare
   glyphs, every action gets a word.

### Acceptance

- A real 60-second clip, five listing photos, produces a finished vertical MP4 on device.
- Every cutaway lands on the exact `start`/`end` returned by the server, to the frame.
- A window with an empty `photo_id` shows the agent, with no caption over their face.
- ReviewerWalk and the main UI walk stay green.
- No new analytics event unless all four places in §2 are edited.

---

## 4b. Spatial Tour — a true 3D walkthrough (this is the Matterport replacement)

**This is the single most strategically important feature in the product, and it is a separate
thing from the flythrough video.** The flythrough is a scroll-driven cinematic. This is a 3D
reconstruction of the real rooms that a buyer moves around inside, with a joystick, on a web
page. It is what Matterport sells, and replacing Matterport is the point.

Budget for it accordingly: this is weeks of work, not days. Ship it in the phases below, and
treat Phase A as a spike that proves the pipeline end to end on one room before anything is
polished.

### The reference flow, from the demo the owner supplied

Three states, in order:

1. **Guided AR capture.** The live camera view with capture targets drawn *in 3D space* as
   green spheres. A white reticle in the centre of the screen; the agent walks and points at
   each target and it registers. A progress bar and a counter — the demo shows `8 of 16`, then
   `14 of 16`. An undo control top-left, a stop control top-right. This is not video recording;
   it is a structured, countable capture.
2. **"Generating 3D World."** A full-screen progress state: *"This will take about 5 minutes —
   feel free to leave the app and come back."* The work is off-device and asynchronous.
3. **The navigable 3D world.** A photoreal render of the actual kitchen and living area, with a
   small round joystick control bottom-left for moving through the space.

That third screen is the product. The first two exist to make it possible.

### What the technology actually is, and why it is now affordable

This is **3D Gaussian Splatting (3DGS)** — the technique that displaced NeRF for this use case
because it renders in real time in a browser. The pipeline is: many posed images → a GPU
training run → a splat file → a WebGL viewer.

**The insight that makes this cheap for Rendprop specifically:** the normal slowest and most
failure-prone stage is COLMAP / structure-from-motion, which recovers where each photo was
taken from. **Rendprop does not need it.** The app already runs an `ARSession` for RoomPlan, so
`ARCamera.transform` gives a known pose for every frame, in metres, in one world coordinate
space, for free. Export poses with the frames and the reconstruction starts at training.

Verified numbers (2026):

| | |
|---|---|
| A small interior scene | ~200 images, ~500K gaussians, **8 GB VRAM**, an RTX 4090 is enough |
| Training time | minutes, not hours — the demo's "about 5 minutes" is realistic |
| Raw output (PLY) | 50–200 MB for a small scene |
| Web-delivery format | **SOG**, 15–20× smaller than PLY → roughly **3–13 MB per room** |
| Whole-house scenes | **Streamed SOG** — a spatial tree that loads chunks by camera position |
| GPU cost | a 4090-class hour is well under a dollar on commodity GPU cloud, so a room is **cents** |

Compare that to everything else in this app: a single generated reel on Seedance 2.5 costs
$14.19 (§6). A spatial tour of an entire house costs a fraction of that and is the feature that
removes the reason to own a $3,000 camera and a Matterport subscription. **The unit economics
here are better than any AI feature in the product.** That is not an accident — it is the
owner's own thesis, which is worth restating because it should govern every decision in this
section: *generative video will always be inventing; the thing that beats Matterport is the
scan, because the geometry is measured.*

### The architecture, end to end

Every piece has an existing home. **Do not invent a parallel stack.**

```
iOS: ARSession (already running for RoomPlan)
       ├─ RoomPlan  → CapturedRoom polygons        → waypoint planning + the floor plan we already ship
       └─ frames    → keyframes + ARCamera poses   → uploaded to R2
                                                        │
R2 (services/supabase/functions/_shared/r2.ts — presignPut, multipart already exist)
                                                        │
Edge function: POST /spatial  → enqueues a job (model it on render_jobs)
                                                        │
GPU worker (new, off-platform): posed frames → 3DGS training → PLY → SOG
                                                        │
R2 ← the .sog, plus a manifest (bounds, floor plane, room anchors, initial camera)
                                                        │
Cloudflare Worker services/edge/tour-host → the tour page embeds a WebGL splat viewer
                                                        │
                                    ┌───────────────────┴───────────────────┐
                          the buyer's browser              the app's own PlayerWebView
                          (shareable link, no app)         (Screens/PlayerWebView.swift)
```

**The single most important architectural decision: the viewer is WEB, not Metal.** The tour is
already a hosted page built by `services/edge/tour-host/src/player.ts`, and the app already
displays that page inside `Screens/PlayerWebView.swift` (a `WKWebView`). So one WebGL viewer
serves the buyer's browser, the agent's phone, and the MLS-unbranded `/u/` twin. Writing a
native splat renderer would triple the work and produce three things to keep in sync. Do not do
it.

`player.ts` already loads a pinned external library from cdnjs with an SRI hash (see `HLS_SRC`
/ `HLS_SRI`). Follow that exact pattern for the splat viewer — pinned version, SRI, same CSP
posture. Candidate viewers, in order: **Spark** (World Labs, Three.js, reads SOG/SPZ/PLY) or
the **PlayCanvas engine**, whose SOG support is first-party. Evaluate both on a real room before
committing; the deciding criteria are mid-range Android and older iPhone performance, not
desktop.

### Phase A — the spike (do this first, prove it, then stop and report)

**Goal: one real room, captured on an iPhone, rendered as a splat in a browser.** No UI polish,
no job queue, no plan gating. If this does not work, nothing else in this section matters.

1. A throwaway capture harness in the app that runs an `ARSession`, saves keyframes as JPEG at
   a sensible cadence, and writes a sidecar JSON of `ARCamera.transform`, intrinsics, timestamp
   and `trackingState` per frame.
2. Get those onto a GPU box by hand. Train a splat using the ARKit poses **instead of** COLMAP.
   Prove that works — it is the load-bearing claim of this whole design.
3. Convert to SOG. Load it in Spark or PlayCanvas in a plain HTML page. Move around.
4. **Report with numbers:** frames captured, training minutes, GPU used, PLY size, SOG size,
   and the frame rate on a real phone browser — not a desktop.

Do not proceed to Phase B until the owner has seen that.

### Phase B — capture that a working agent can actually complete

This is where the demo's `N of 16` lives, and it is a coverage problem, not a technique problem.

The app today has `Capture/GuidanceOverlays.swift` — `LevelBubble`, `PaceRing`, `LightWarning`,
`ThirdsGrid` — all of which coach *how you hold the phone*. **Nothing in the app knows where you
have and have not been.** That is the gap.

1. **Waypoint planning is deterministic and runs on device before the walk.** Given the
   `[CapturedRoom]` polygons, compute capture points: one per room minimum, plus extra points
   for rooms above an area threshold or whose polygon is non-convex — an L-shaped great room
   needs two, because one standing point cannot see round the notch. Same discipline as
   `ai-copy/shotlist.ts` `planShots` and `ai-copy/agentreel.ts` `planWindows`: pure, unit-tested,
   and the same house plans the same points twice. **Write the geometry tests before any UI.**
2. **Coverage tracking from the pose.** A waypoint is satisfied when the camera has been within
   a radius of it **and** swept enough yaw there — standing on a point facing one wall is not
   coverage. RoomPlan and the frames share one world space; do not introduce a second
   coordinate system and do not re-localise.
3. **Draw the targets in AR**, as the demo does — spheres in world space, plus the counter and
   the progress bar. A new file under `Capture/`, beside `GuidanceOverlays.swift`. **Do not add
   this to `Screens/FlythroughDetailView.swift`**, which is already 526 KB and is where this
   codebase goes to become unmaintainable.
4. **Frame selection is a real problem, not an afterthought.** 200 good frames beat 2,000 bad
   ones. Drop frames on blur (variance of Laplacian), on `ARCamera.trackingState != .normal`,
   and on insufficient baseline from the last kept frame. This is what decides reconstruction
   quality and upload size, so it gets its own tests.
5. **Name the gaps at the end in the agent's own words** — "you did not cover the primary
   bathroom" — using the `CapturedRoom.sections` labels the scan already produces. Never a
   silent pass.
6. **Resumable.** A phone call, a low-battery warning or a backgrounded app must not lose
   fifteen covered waypoints.

### Phase C — the reconstruction service

1. **Model the job on `render_jobs`.** There is already an async job table, a cost ledger
   (`_shared/ledger.ts`), and a worker-lease pattern. Reuse them. Note the open finding: a stale
   worker can overwrite a newer render because `insert_render` replaces by `job_id` with no
   ownership predicate (§5) — do not copy that bug into a new worker.
2. **A per-job cost ceiling, decided before the first job runs.** §5 F15 is the standing
   warning: the repo's per-generation cap lives in `log_job_cost()`, which the in-app AI routes
   never reach. A GPU job that can run away is worse than an API call that can, because nothing
   times it out for you. Cap wall-clock, cap iterations, cap gaussian count.
3. **The output is a manifest plus the splat**, not a bare file: bounds, the floor plane, the
   room anchors with their labels, and the initial camera pose so the tour opens somewhere
   sensible rather than inside a wall.
4. **This is not an `ai_routes` task.** It is not a vendor text/video call and it does not
   belong in the router. Do not add a row.

### Phase D — the viewer, and what makes it a product rather than a demo

A splat you can fly through is a demo. These four make it something a brokerage buys:

- **Floor-locked navigation.** Buyers do not want a free-flying camera; they want to walk. Lock
  the camera to eye height above the detected floor plane, with the joystick from the demo, and
  keep click-to-move between room anchors.
- **A dollhouse / top-down view.** Matterport's signature. The room polygons are already there
  from RoomPlan — this is mostly a camera state, not new data.
- **Measurement.** Matterport sells this hard, and Rendprop can do it *better*, because the
  geometry is measured LiDAR rather than inferred from photos. Tap two points, get a distance.
- **Privacy blur — non-negotiable, and it is a launch blocker, not a nice-to-have.** A 3D
  capture of somebody's home records the family photographs on the wall, the mail on the
  counter, the prescription on the nightstand and the contents of an open closet. This app
  already takes provenance and disclosure seriously (`_shared/provenance.ts`, the "Virtually
  staged" label). A spatial tour needs at least: a review step before publish, region blur, and
  the ability to exclude a whole room from the published scene. **Do not ship a public spatial
  tour without it.**

### Hard rules for this feature

- **Multi-storey already works and must keep working.** One `RoomCaptureSession`, with
  `stop(pauseARSession: false)` between rooms so the world coordinate space survives, then
  `StructureBuilder.capturedStructure(from:)`. Waypoints group by `CapturedRoom.story`. Area is
  summed **per room** — one convex hull over a whole L-shaped floor bridges the notch and
  invents square footage. That bug has been fixed once; do not reintroduce it.
- **Not every device has LiDAR.** `RoomCaptureSession.isSupported` is already checked at
  `FlythroughDetailView.swift:9560`. Degrade to the existing capture rather than showing a mode
  that fails.
- **Never block the shutter.** An agent standing in a client's kitchen with the seller watching
  cannot be locked out of finishing. Warn, count, name the gaps — never refuse to stop.
- **Upload is the user-visible cost.** A few hundred JPEGs on a listing agent's cellular
  connection is the step that will actually fail. Resumable multipart (`_shared/r2.ts` already
  has it), background upload, and honest progress. A previous field test lost a 343 MB upload
  silently on a 5G→wifi handover; do not repeat it.
- **Plan gating is the owner's decision, not yours.** Bring numbers and ask.
- **No new analytics events** unless all four places in §2 are edited.

### Acceptance

Phase A: a real room, captured on a phone, moving in a browser, with the numbers listed above.
Phase B: a non-technical person completes a full house without instruction, and the app
correctly names anything they missed. Phase C: a job runs end to end with a hard cost ceiling
and a manifest. Phase D: the tour page and the app's `PlayerWebView` show the same scene from
one implementation, and nothing publishes without a privacy review step.

---

## 5. Phase 2 — the open audit findings

None of these block review. All are real. Work them in this order; each gets its own branch,
its own harness, and a live proof against production.

- **F05 adoption recovery** — `POST /adopt` transfers an anonymous workspace to a real Apple
  identity. There is no recovery path if it fails partway.
- **F07 / F08 billing identity** — reconciling a StoreKit transaction to the right org when the
  buyer was anonymous at purchase time and identified later.
- **F09 / F10 deletion resumability** — `DELETE /me` enumerates, then destroys. A crash between
  the two leaves orphans that were never in the tombstone.
- **F12 request context** — no correlation id through the edge functions, so one user's failure
  cannot be traced across routes.
- **F13 banner invalidation** — the plan banner caches and does not invalidate on an
  entitlement change.
- **F14 asserting tests** — several existing tests print instead of asserting. §3 applies.
- **F15 spend guards** — the repo's per-generation cap lives in `log_job_cost()`, which raises
  `RP404` without a `render_job`. **The in-app AI routes never reach it and therefore have no
  ceiling except the ones written by hand** (`/ai-video/drone` has a $48 per-submission
  ceiling; most routes have none). This is the most expensive open finding.
- **Org lock on member removal / invite revocation** — `select … for update` on the org row
  before reading any count. Lock order is always profile → org → invite.
- **Worker lease loss** — `insert_render` replaces by `job_id` with no ownership predicate, so
  a stale worker can overwrite a newer render.
- **No iOS build / archive / UI-test job in CI.**

---

## 6. Phase 3 — the video prompt work (after Apple approves build 16)

`ai-video/motion.ts` holds the camera vocabulary. `REEL_MOTION_TEXT` is marked **FROZEN**
because changing it changes every clip the shipped app produces. Do not touch it while a build
is in review.

When approval lands: restructure `buildReelPrompt` to the Seedance formula —
**Subject → Action → Camera → Style**, plus `00–05s:` timing blocks — and **A/B it against the
current prompt on real listing photos before flipping the default.** Prompt structure is not
version-locked; this improves adherence on the `seedance/v1/pro/fast` model already in
production, at zero cost.

**Do not upgrade the video model.** Verified on fal 2026-09-10:

| model | ¢/sec | res | max clip |
|---|---|---|---|
| `seedance/v1/pro/fast` *(live)* | 4.86 | **1080p** | 6 s |
| `seedance-2.0/fast` | 24.19 | 720p | 15 s |
| `seedance-2.5` | 47.30 | 720p | 30 s |

Moving up is 5–10× **at lower resolution**. A six-clip reel is $1.46 today, $14.19 on 2.5 —
29 % of a month's revenue on a $49 plan, for one reel. The 2.x rows are seeded in migration
0034 as `enabled = false` so the ladder is a fact in the table. Rule 4 in §1 applies.

`video.transition` (end-frame clips) and `video.walkthrough` (nine stills → one continuous
shot) are seeded disabled with no caller. They are where 2.x genuinely earns its multiple, but
enabling either is a pricing decision that needs its own per-generation ceiling first — see F15.

---

## 7. How to work

- **Branch, build, prove, then report.** A report is the last thing you produce, and it states
  what you verified and how, not what you intended.
- **Write the comment that says why.** This codebase documents the reasoning behind a choice,
  not the mechanics of the code. `ai-video/motion.ts` is the model: it argues why a pull-back
  sells scale and why a bathroom refuses an orbit. Match that.
- **When a test tells you something surprising, distrust the test first.** Three banner bugs in
  one session were tests lying: an identical-string false positive, `UserDefaults` versus
  `ProcessInfo`, and a `.task` on EmptyView.
- **Refuse rather than truncate.** If a request exceeds a limit, say which limit and by how
  much. Silently dropping ten of a user's twenty photos is a worse answer than a sentence.
- **Ask before anything irreversible.** Submitting to App Review, enabling a route, deleting
  anything, or spending on a new provider is the owner's call, not yours.
