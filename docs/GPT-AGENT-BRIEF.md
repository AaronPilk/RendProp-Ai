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

## 4b. Guided Scan — coverage, not technique (the Matterport-parity feature)

The owner's standing thesis, and it is the right one: **generative video will always be
inventing. The thing that actually beats Matterport is the LiDAR scan — measured geometry.**
This feature is that thesis executed, and it is the last real gap.

### What is missing, stated exactly

The app already has both halves and they do not talk to each other:

- `Capture/GuidanceOverlays.swift` coaches **technique** during a walkthrough — `LevelBubble`,
  `PaceRing`, `LightWarning`, `ThirdsGrid`. Hold it level, do not rush, there is not enough
  light. All real-time, all about *how* you are moving the phone.
- The RoomPlan scanner (inside `Screens/FlythroughDetailView.swift`, ~line 9459) produces a
  `SavedFloorPlan` of `[CapturedRoom]` merged by `StructureBuilder`, multi-storey, with
  `CapturedRoom.sections` classifying each area and `CapturedRoom.story` giving the floor.

**Nothing in the app knows about coverage.** No screen tells the agent where they have not
been. The scan knows the geometry; the walkthrough does not know where it is inside that
geometry. So an agent finishes a capture with no idea they never walked the north-east corner,
and finds out when the tour is rendered.

Matterport's actual moat is not its camera. It is that its app stands you on a numbered point,
counts them down, and refuses to call the scan done until the floor is covered.

### The feature

A capture mode that plans waypoints from the room geometry, tracks which have been covered
live, draws a top-down map while you walk, and tells you what is left. The reference demo shows
exactly this: a phone screen with the room footprint drawn, capture points as dots around it,
the current target highlighted, and a progress bar reading **"5 of 16"**.

### Build it in this order

1. **Waypoint planning is DETERMINISTIC AND SERVER-STYLE, on device.** Given the
   `[CapturedRoom]` polygons, compute the capture points before the walk starts: one per room
   minimum, plus additional points for rooms above an area threshold or whose polygon is
   non-convex (an L-shaped great room needs two, because one standing point cannot see round
   the notch). Same discipline as `ai-copy/shotlist.ts` `planShots` and `ai-copy/agentreel.ts`
   `planWindows` — pure, testable, and the same house plans the same points twice. Unit-test
   the geometry before any UI exists.
2. **Coverage tracking from the ARKit pose.** RoomPlan runs on an `ARSession`, so
   `ARCamera.transform` is already in the same world coordinate space as the polygons. A
   waypoint is covered when the camera has been within a radius of it AND has swept enough
   yaw there — standing on a point facing one wall is not coverage. Do not invent a second
   coordinate system; do not re-localise.
3. **The map.** A top-down overlay: the room outline, covered points solid, the current target
   highlighted, remaining points dim, and `N of M`. This is a new file under `Capture/`, beside
   `GuidanceOverlays.swift` — do **not** add it to `FlythroughDetailView.swift`, which is
   already 526 KB and is where this codebase goes to become unmaintainable.
4. **Gap reporting at the end.** Name what was missed in the agent's own words — "you did not
   cover the primary bathroom" — using the `CapturedRoom.sections` labels the scan already
   produces. Never a silent pass. Follow the house rule from §7: refuse or warn honestly rather
   than quietly delivering something incomplete.
5. **Resumable.** A phone call, a battery warning or a backgrounded app must not lose fifteen
   covered waypoints. Persist coverage alongside the scan.

### Rules specific to this feature

- **Multi-storey already works and must keep working.** One `RoomCaptureSession`, with
  `stop(pauseARSession: false)` between rooms to preserve the world coordinate space, then
  `StructureBuilder.capturedStructure(from:)`. Waypoints are grouped by `CapturedRoom.story`.
  Area is summed **per room** — one convex hull over a whole L-shaped floor bridges the notch
  and invents square footage. That bug has been fixed once; do not reintroduce it.
- **Not every device has LiDAR.** `RoomCaptureSession.isSupported` is already checked at
  `FlythroughDetailView.swift:9560`. On a device without it, this mode must degrade to the
  existing technique guidance rather than appearing and failing.
- **The guidance must never block the shutter.** An agent standing in a client's kitchen with a
  seller watching cannot be locked out of finishing. Warn, count, name the gaps — never refuse
  to stop recording.
- **No new analytics events** unless all four places in §2 are edited.
- **This is a capture feature, not an AI feature.** It costs nothing per use: no route, no
  provider, no `ai_routes` row, no per-generation ceiling. Keep it that way — do not reach for a
  model to decide something geometry already answers.

### Why it matters commercially

Everything else in the app is a better version of something an agent could already do badly.
This is the one feature that removes the reason to own a $3,000 camera and a Matterport
subscription. It is also the feature a brokerage's ops lead evaluates, because it is the one
that determines whether twenty agents produce usable scans without training.

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
