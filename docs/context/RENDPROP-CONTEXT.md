# RENDPROP — MASTER CONTEXT & CHAT LOG

> Single catch-up file. Read this first in any new session. It captures what Rendprop is,
> every decision made, the current build state, known issues, and what's next — so we never
> re-explain the project or lose thread when switching models/hitting usage limits.
>
> Last updated: 2026-07-09 · Owner: Aaron Pilkington (aaron@skyway.media) · GitHub: AaronPilk/RendProp-Ai

---

## 0. LATEST STATE (2026-07-09) — READ THIS + THE TWO DOCS BELOW

Phase 1 is largely BUILT and running on device. Since this file's original sections were
written, we shipped a LOT more. For the authoritative current state + next build, read:

- **`RENDPROP-FABLE5-BRIEF.md`** (this folder) — the complete, self-contained handoff brief
  (mission, constraints, everything built, immediate priority, the massive roadmap). This is
  the best single catch-up document now.
- **`repo/docs/INDUSTRY-LOGIC.md`** — the locked per-industry field/CTA/feature spec.

**CORE DIRECTION:** Rendprop is multi-industry, NOT real-estate-only (venues, restaurants/bars,
retail/grocery, gyms/studios, other). Each business type must feel like a genuinely DIFFERENT
app — not a re-skin.

**Shipped since original sections below:** persistence, render v2 (all-intra + Vision
stabilization), scrub-and-tag room tagging (live + post-upload), photo studio (deterministic
Core Image enhance), RoomPlan LiDAR floor plan, geolocated map + use-current-location, 3-tab
bar (Homes/Profile/Settings), agent card + headshot + IG/LinkedIn/TikTok injected into the
tour, mark-sold/archived folder, Zillow link, portfolio HTML share, and the multi-business
`SpaceType` system + data-driven per-type detail fields (`SpaceType.detailFields` →
`Listing.details` → `DetailFieldsEditor`).

**IMMEDIATE PRIORITY (not yet built):** make each type feel like its own app — per-type sample
listings (replace the hardcoded real-estate samples), per-type card/tab/empty icons, reseed
samples on business-type change. See §6 of the Fable 5 brief.

**Key constraints (unchanged, critical):** can't compile Swift in-sandbox (verify with a
subagent); new .swift files get dropped from the Xcode target (put code in EXISTING in-target
files); git push from the Mac; new model fields must be Optional (Codable back-compat);
navigation must be destination-based.

---

## 1. WHAT RENDPROP IS

**One line:** Walk it. Upload it. Fly through it.
Turn any phone walkthrough into a scroll-through cinematic flythrough of a property.

**The loop:** A real estate agent records a continuous walkthrough of a home on their iPhone →
Rendprop renders it into a drone-style cinematic glide → output is a shareable link where a
viewer **scrolls to fly through** the home. iOS-first.

**Why it wins:** No drone, no crew, no gear. Just the phone already in the agent's pocket.
The scroll-scrub player is the product's face and the hardest already-proven piece.

---

## 2. THE ECONOMICS (three decisions that define the model)

1. **Cloudflare Stream** for delivery — per-minute billing, 4K costs the same as 1080p.
2. **Cloudflare R2** for storage — zero egress fees.
3. **Duration-band pricing + streamed-minute caps** — never flat-price a render.

**Non-negotiables (hard rules):** No full-length generative video. No canvas scrubbing for
long/4K clips. No Mux for entry tiers. No flat pricing. No web-checkout CTAs inside the iOS
app (Apple IAP only). Mobile-perfect, deterministic-first, cost-aware, honest stats.

---

## 3. REPO LAYOUT

Local: `~/Rendprop AI/repo` · Remote: `github.com/AaronPilk/RendProp-Ai.git`

```
apps/
  ios/            Native Swift/SwiftUI capture app — 41 Swift files, XcodeGen project
  web/
    player/       Scroll-scrub flythrough share player — WORKING DEMO (index.html + demo.mp4)
    dashboard/    Agent dashboard (later phase, stub)
services/
  api/            Postgres schema (db/schema.sql) — identity, listings, render state machine,
                  cost ledger, metering, billing
  pipeline/       Render pipeline: stabilize → interpolate → grade → encode.
                  enhance.py = AI enhancement orchestrator. .env / .env.example for keys.
infra/            IaC stubs — Cloudflare R2/Stream, Modal, envs
docs/
  MASTER-BUILD-PROMPT.md         100KB — single source of truth, full product spec
  RENDPROP-XCODE-BUILD-PROMPT.md Xcode build spec (Apple aesthetics, get it on the phone)
  AI-ENHANCEMENTS-SPEC.md        Declutter + virtual restage spec
  samples/                       Before/after enhancement proof images
```

**docs/MASTER-BUILD-PROMPT.md is the source of truth.** When in doubt, it wins.

---

## 4. iOS APP STATE (apps/ios — target name: Rendprop)

- **Bundle:** `com.rendprop.app` · **Team ID:** `5F5C5G25Y6` (Aaron Pilkington, pinned in project.yml)
  - Note: during signing debugging we also used `com.pilk.rendprop` as a fallback bundle ID in
    Xcode if `com.rendprop.app` was ever unavailable. Team ID had a saga — see Known Issues.
- **Build system:** XcodeGen. Generate with `xcodegen generate` (regen re-stamps project.yml settings).
- **Phase 1 = runs on device, backend fully stubbed/offline.** Phase 2 items (Auth/IAP/Push) behind flags.

**What's built and in:**
- Full onboarding (3 swipe cards → Get Started → empty "My Homes")
- Real 4K capture with `cinematicExtended` stabilization; HEVC 4K/30 default; 0.5x ultra-wide default
- 100Hz gyro/motion sidecar recorder; level bubble + pace haptics (metronome) + light meter
- Live room tagging while walking (RoomTagBar)
- Photos/Files import (MediaImporter)
- Background resumable upload with cellular guard (UploadManager/DirectUploader/UploadStore)
- On-device render engine v1 — flythrough plays the user's REAL video, honest stats
- Review & Submit → duration-band pricing → simulated render → flythrough player (WKWebView wrapping the web player)
- Settings → Account → "Watch the intro again" (replays onboarding without reinstalling — good for demos)
- Design system: Theme / Typography / Components / Haptics. Light mode: white + purple, radically simple UX.
- **Persistence (added 2026-07-09, commit 9beb240):** `Support/PersistentStore.swift` writes listings/assets/tours/renders to `Documents/rendprop-state.json`; `AppModel` restores on launch and auto-saves on every mutation (didSet). File URLs are stored RELATIVE to Documents (iOS changes the container path across launches) and rebuilt at load; entries with missing files are dropped. **This fixed the "render vanished / shows SAMPLE TOUR after relaunch" bug** — root cause was AppModel being 100% in-memory, so on relaunch only the two seeded sample listings ("1247 Hillcrest Drive (Sample)" etc.) came back and the real listing + its tour mapping were wiped.
- **Capture is now upload-first (commit 9beb240):** New Listing shows "Upload a video" as the primary button, "Record a walkthrough" as secondary. Both feed the same render pipeline.

**Key files by area:**
- Capture: `Capture/CameraManager.swift`, `CaptureView.swift`, `MotionRecorder.swift`, `GuidanceOverlays.swift`, `RoomTagBar.swift`
- AI: `Networking/AI/` — `ClaudeClient`, `HiggsfieldClient`, `KieClient`, `EnhancementEngine`, `Secrets`
- Networking: `APIClient` (protocol), `MockAPIClient` (offline), `LiveAPIClient`
- Render: `Render/RenderEngine.swift`
- Screens: Onboarding, HomeListings, NewListing, ReviewSubmit, RenderStatus, FlythroughDetail, EnhancementPreview, PlayerWebView, Settings

---

## 5. WEB PLAYER STATE (apps/web/player — the crown jewel, PROVEN)

Working scroll-scrub demo. Faithful to spec:
- rAF lerp scrub, 96% buffer gate, room chapters + tap-to-jump rail
- Lead-capture form end-card, streamed-minutes metering stub
- Jank watchdog with autoplay-loop fallback
- All iOS Safari / webview attributes set (playsinline, muted, preload, etc.)
- Ships with a synthetic ~55s demo.mp4 encoded all-intra (dense keyframes) for instant seeks

**Try it:** `cd ~/Rendprop\ AI/repo/apps/web/player && python3 -m http.server 8080`
Open on the Mac, or the Mac's LAN IP on the iPhone (the test that matters).

---

## 6. AI ENHANCEMENTS (docs/AI-ENHANCEMENTS-SPEC.md)

Add-on layer on top of the deterministic pipeline. **One rule: furniture & decor only — the
architecture NEVER changes.** Walls, windows, floors, fixtures, views are sacred (wrong-house =
lawsuit + brand killer).

| Add-on | Does | Price v1 | UI |
|---|---|---|---|
| Auto-declutter | Removes boxes/mess/cords/counter clutter | +$19/render | Toggle in Review & Submit |
| Virtual restage | Re-styles furniture/art/decor in a chosen style | +$49/render | Picker: As-is · Modern · Rustic · Minimalist · Scandinavian |

Stored on `render_jobs.enhancements` (jsonb). Wired end-to-end in the iOS app.

**Provider stack:**
- **Claude (Fable 5) API** — orchestration, room understanding, and the **drift judge** (scores
  source vs. enhanced frames 0–100; below threshold → auto-regen or fall back to original).
- **Higgsfield** — generative video (restage, hero clips), i2v, upscale/reframe. Connected via MCP.
- **KIE.ai** — switched to as an AI provider with hard cost guards (verified live). See commit f7834ed.
- **Seedance** (via Higgsfield routing: `bytedance/seedance/v2/pro/image-to-video`) — i2v seeded from real frames.
- **SAM-2** (self-hosted GPU) — clutter object masks. **ProPainter-class** — temporally consistent inpainting removal.

**Cost guards in .env:** `QC_PASS_SCORE=85`, `QC_MAX_RETRIES=2`, `MAX_GEN_COST_PER_JOB_CENTS=2500`.

**Key setup:** double-click `Add API Keys.command` in repo root (fills `.env`, gitignored, keys never leave the machine).
`.env.example` documents: `ANTHROPIC_API_KEY` (model `claude-fable-5`), `HIGGSFIELD_API_KEY`/`_SECRET`,
model routing (`HF_IMAGE_EDIT_MODEL=nano-banana-pro/image-edit`), R2, Modal, Cloudflare Stream.

Proof images in `docs/samples/`: original cluttered → decluttered → restaged modern → decluttered via KIE.

---

## 7. GIT HISTORY (21 commits — the decision trail, newest first)

```
a278a79  Settings: "Watch the intro again" — replays onboarding without reinstalling
33e9b25  Pin real Team ID 5F5C5G25Y6 (OU field from signing certificate)
941d02c  Unpin team — WY2F35GG95 was the cert ID; grep was circular
be6b2b5  Re-pin team WY2F35GG95 — confirmed real Team ID from working build
1070849  Revert team pin — WY2F35GG95 was the certificate ID, not the Team ID
d907c36  On-device render engine v1 + normal walking pace
16d3495  Flythrough plays the user's REAL video; honest stats
ffc0033  Capture: 0.5x ultra-wide default + HEVC 4K/30 default
ebed5e8  Pin development team WY2F35GG95 in project.yml
c982df7  Home redesign: aesthetic full-width listing cards
f7834ed  Switch AI provider to KIE.ai with hard cost guards (verified live)
d1bd264  Native in-app AI engine: Claude plans+judges, Higgsfield executes
6daf45e  enhance.py: browser UA header (Cloudflare blocks default urllib signature)
1cf393a  Sync .env.example (key+secret format, model routing)
84a8da5  Working enhancement orchestrator + one-click key setup
324a137  Enhancement proof-of-concept: cluttered -> decluttered -> Modern restage
831a78e  Light mode redesign: white + purple, radically simpler UX
1b9d29f  AI enhancements: auto-declutter + virtual restaging
d5cff8f  Fix NewListingView Section init (header/footer closures)
6602ce2  Rendprop iOS app: Xcode Phase 1 bring-up (runs on device, backend stubbed)
a8fbd55  ROAM Phase 0: monorepo scaffold + working scroll-scrub player demo
```

Note: project was originally codenamed **ROAM**, renamed to **Rendprop** everywhere.

---

## 8. KNOWN ISSUES / OPEN LOOPS

1. **Git push must come from the Mac.** The sandbox has no GitHub credentials. All 21 commits are
   local. Run: `cd ~/Rendprop\ AI/repo && git push origin main`.
2. **Swift can't compile in this environment.** First device build may surface a stray compiler
   error — paste it back and it gets fixed fast. (Already fixed one: NewListingView `Section`
   init — the `Section("title") { } footer: { }` form doesn't exist; correct is `Section { } header: { } footer: { }`.)
3. **Signing (user-side).** In Xcode: Rendprop target → Signing & Capabilities → Automatically
   manage signing → pick Team (Aaron Pilkington). If `com.rendprop.app` is unavailable, switch
   bundle ID to something unique like `com.pilk.rendprop`. Team ID is pinned as `5F5C5G25Y6`.
4. **Team ID saga (resolved).** `WY2F35GG95` turned out to be the *certificate* ID, not the Team
   ID. Real Team ID is `5F5C5G25Y6` (the OU field from the signing cert). Don't re-introduce the
   circular grep that re-pinned our own value.
5. **Demo video is synthetic.** Fastest way to know if the wedge lands: shoot a real 60s phone
   walkthrough, run it through stabilize → interpolate → scrub-proxy, and feel it under the thumb.

---

## 9. HOW TO RUN THINGS

**Web player (feel the scrub):**
```
cd ~/Rendprop\ AI/repo/apps/web/player && python3 -m http.server 8080
# open localhost:8080 on Mac, or Mac-LAN-IP:8080 on iPhone
```

**iOS app on your iPhone:**
```
cd ~/Rendprop\ AI/repo/apps/ios
brew install xcodegen       # once
xcodegen generate
open Rendprop.xcodeproj
# Xcode: pick Team → plug in iPhone → ⌘R
# First run on phone: trust cert (Settings → General → VPN & Device Management),
# grant camera/mic/motion, then record a walkthrough.
```

**Fresh first-run experience:** delete app from iPhone → ⌘R (gives permission prompts + empty state).
Or, after install: Settings → Account → "Watch the intro again".

**AI enhancement keys:** double-click `Add API Keys.command` in repo root.

---

## 10. ROADMAP (Part 21 of master spec)

- **Phase 1 (MVP, current):** capture app + deterministic pipeline + mobile-perfect player + IAP duration-band pricing.
- **Phase 2:** 4K, Cinematic AI hero clips, analytics, CRM, hosting subscriptions, Auth/IAP/Push.
- **Phase 3:** MLS/RESO integration, white-label, verticals.

**Best next move:** swap synthetic demo for a real walkthrough clip → run it through the
stabilize → interpolate → grade → scrub-proxy recipe → validate the wedge on a real phone under a real thumb.

---

## 11. OPERATING NOTES FOR THE AI CO-WORKER

- Modes: /GHOST (sharp, human, no AI slop) + L99 (max depth, pressure-test, ship the strongest version).
- Execution over theory. Build real assets, check work before submitting.
- iOS builds: expect to iterate on compiler errors the user pastes from Xcode.
- Keep this file updated at the end of any session that changes project state.
```
```

---
## §6 SHIPPED (this session): "different app per industry" layer 1
- `SpaceType.sampleListings` (Models/Listing.swift): believable per-type samples — Grand Atrium (venue, seats 220), Bella Notte (restaurant, Italian·Wine Bar·$$$), Fresh Market (retail, weekly special), Iron & Oak (fitness, 24/7 + trial), The Workshop (other). RE keeps Hillcrest/Marina Vista. All isSample, never persisted.
- `SpaceType.emptyStateLine`: per-industry empty-state copy.
- `AppModel.reseedSamples()` + `load()` now seeds CURRENT type's samples; `HomeListingsView.onChange(of: spaceTypeRaw)` reseeds live on type switch.
- `RootTabView`: first tab = "\(spaceNounCap)s" + type icon, observes @AppStorage("space.type").
- `ListingCard` hero placeholder = type icon (RE keeps house.and.flag); empty state icon = type icon; searchable prompt per type; a11y label uses subtitleLine.
- Compile-audited by subagent: CLEAN. No new files → no xcodegen needed.
- NEXT: §7B signature features (restaurant open/closed + menu btn; retail aisle guide + promo; venue packages; gym trial capture), then §7C per-industry lead forms in player HTML, then backend.

---
## LEAK PURGE + UI REBUILD (this session)
Full leak audit (subagent, 12 findings) — ALL fixed:
- NewListing "The home/home's address/Home details" → spaceNoun-driven
- ReviewSubmit tag coaching → customerNoun + quickTags; Render .asIs blurb; Flythrough share message "walk the home" → spaceNoun
- Settings: agent-card footer (customerNoun+ctaTitle), Brokerage placeholder → businessLabel, portfolio "buyer" copy, shoot-tip "exterior" removed
- PlayerWebView: Zillow injection gated to .realEstate; NEW `demoHTML()` — demo player fully type-adaptive (copies demo.mp4 to Caches/player-demo, rewrites chapters=quickTags, CTA, sample name/tagline, agent card). A gym's SAMPLE tour no longer shows Living Room/Book a showing/Hillcrest.
UI rebuild:
- 4-tab bar: [TypeNoun]s / **Business** / Profile / Settings. NEW `BusinessTypeView` (appended to SettingsView.swift, in-target): 2-col type card grid (icon+name+pitch, selected=filled accent) + "How X mode works" preview (tour stops chips, detail-field chips, CTA pill). Settings' inline picker replaced with pointer row.
- New adapters: `SpaceType.customerNoun`, `SpaceType.pitch`; `Listing.cardChips` — per-type card info chips (venue: Seats/From $/event type; restaurant: cuisine/$$$/hours; retail: category/hours/★special; fitness: $/mo, 24/7, Free trial; other: hours). ListingCard renders chips row.
Compile-audited CLEAN (2nd subagent). No new files → no xcodegen. Known benign: double reseed on type change (idempotent).

---
## DEEP SWEEP ROUND 2 (user found in-app Zillow on gym)
Root cause of "Zillow for a gym": FlythroughDetailView MANAGE card had ungated Zillow editor (the earlier fix only gated the SHARED tour's injection). Fixed + full multi-lens sweep (2 parallel subagents: string leakage + logic correctness):
- FlythroughDetail: Zillow editor/link gated to .realEstate; "Tag rooms" → "Tag areas" (also ReviewSubmit header ROOMS→AREAS, tagger nav title, edit labels)
- Render tier blurbs: "most listings"/"luxury listings" → tours/spaces
- ReviewSubmit: declutter copy spaceNoun; "Virtually staged" note type-gated (MLS wording RE-only)
- Info.plist: camera/location strings de-realestate'd
- PlayerWebView localPreviewHTML: "this home" → "this {spaceNoun}" for non-RE (demoHTML already had it)
- LOGIC BUG: non-RE listings stored default beds=3/baths=2 → NewListingView constructor now zeroes RE fields for non-RE (isRE gate)
- LOGIC BUG: PortfolioExporter used metaLine (printed "3 bd · 2 ba" for venues) → subtitleLine
Logic sweep verdicts: detail-fields gating PASS, CTA/actionURL wiring PASS, no-$0 PASS, quickTags reach PASS, reseed integrity PASS, demoHTML chapter math PASS, reactivity PASS, sample coherence PASS. Final compile audit CLEAN. No new files.

---
## LIVE SIMULATOR TEST + PROFILE PER-TYPE LOGIC (this session)
Drove the app end-to-end in iOS Simulator (iPhone 17 Pro). Build succeeded. Verified in GYM mode:
- Onboarding copy type-neutral ("space"/"customers"); business-type picker works
- "My Studios" title, "New Studio" btn, dumbbell tab icon, "Search studios"
- Iron & Oak sample card with gym chips ($49/mo · Open 24/7 · Free trial)
- Sample tour player: chapters = Entrance/Reception/... (NO Living Room), no house content
- Detail MANAGE card: "Mark as archived", ZERO Zillow (the exact bug — confirmed dead)
- Details card: Facility type/Membership/Day pass/Open 24/7/Amenities/Free trial
- Tools row: "Tag areas" (not Tag rooms); Performance stats present
- Business tab present in 4-tab bar
PROFILE PER-TYPE FIX (user request): profile now flips identity by type.
- SpaceType: profileCardName ("Agent card"↔"Business card"), profileNameLabel ("Full name"↔"Business name"), profileOrgLabel ("Brokerage"↔"Owner or manager (optional)"), profilePhotoLabel ("Headshot"↔"Logo or photo")
- AgentCardEditorView + Settings brand-kit row + nav title all use them
- Verified live: gym profile shows "Business card / Logo or photo / Business name / Owner or manager / …book a session"
- Compile-audited CLEAN. No new files.
NOTE: Simulator hardware-keyboard causes iOS accent-popup bug on text fields (env artifact, NOT app bug); fixed via I/O>Keyboard>disconnect hardware keyboard → software keyboard. Camera capture + LiDAR floor plan can't run in Simulator (device-only).

---
## PER-INDUSTRY LISTING ISOLATION (this session)
Bug: listings were global — a real-estate agent's 3 sold houses showed up in Food/Gym mode. Fix: stamp each listing with its industry, filter everywhere by current type.
- Listing.spaceTypeRaw: String? (optional → Codable back-compat; legacy nil → realEstate). Set at creation = SpaceType.current.rawValue in NewListingView.
- Listing.spaceType (nil→realEstate) + Listing.belongsToCurrentType (isSample || spaceType == .current)
- Filtered by belongsToCurrentType: HomeListingsView.filtered + soldCount, SoldListingsView.sold (archive), SettingsView.shareableCount + PortfolioExporter.build
- Existing pre-fix listings decode with spaceTypeRaw=nil → treated as real estate → only show in RE mode (correct for legacy data)
- HomeListingsView @AppStorage("space.type") pinned as LOAD-BEARING (drives filter reactivity; SpaceType.current isn't observable)
- Compile-audited CLEAN. No new files.

---
## PER-INDUSTRY BUSINESS CARD (this session)
Bug: labels flipped per type but the CARD DATA was one shared card (UserDefaults keys "agent.name" etc.) — set up RE agent, switch to restaurant, saw same name/brokerage.
Fix: namespace card storage by SpaceType.
- AgentCard.key(field): realEstate → "agent.{field}" (legacy, preserves existing card); others → "agent.{type}.{field}"
- AgentCard.current reads via key(); headshotURL per-type filename ("agent-headshot-{type}.jpg", RE keeps "agent-headshot.jpg")
- AgentCardEditorView: @AppStorage(AgentCard.key("...")) for all 8 fields (dynamic key legal Swift; editor pushed fresh → resolves to active industry)
- ProfileView: observes @AppStorage("space.type") + onChange reloads card+headshot; onAppear already reloaded
Each industry now has a fully separate business card (name/brokerage/phone/email/website/socials/headshot). RE data untouched (legacy keys). Compile-audited CLEAN. No new files.
