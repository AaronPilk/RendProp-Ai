# ROAM — MASTER BUILD PROMPT (v3, exhaustive, iOS-first)
### "Walk it. Upload it. Fly through it." — turn any phone walkthrough into a scroll-through cinematic flythrough.

> **HOW TO USE THIS DOCUMENT**
> Paste this entire document as the founding brief for the ROAM build (Claude Code, a new project, or a senior team). It is the single source of truth for product, architecture, and every layered system. It is deliberately exhaustive: it specifies the iOS app, the render pipeline, the streaming layer, the backend, payments (including Apple's in-app-purchase rules), the growth loop, security/compliance, infrastructure, testing, and operations — down to data schemas, state machines, API surfaces, edge cases, and acceptance criteria.
>
> **PRIME DIRECTIVE — MOBILE PERFECT.** ROAM is an **iOS mobile app first**. The capture experience and the shared flythrough must feel flawless on an iPhone in one hand, on cellular, in bright sun, with a thumb. Desktop is the easy case and comes for free. Every decision below is made mobile-first; where a tradeoff exists, the iPhone wins.
>
> **GROUNDING.** The hardest piece — the scroll-driven flythrough player — is already proven in a working prototype (see Part 6). Fresh 2026 research on competitors, AI-render costs, streaming, and unit economics is baked into the relevant parts. Codename **ROAM** (rename freely).

---

## TABLE OF CONTENTS

- **PART 0 — Executive summary & the one-sentence product**
- **PART 1 — Market, opportunity & competitive landscape (verified 2026 data)**
- **PART 2 — Product principles & the mobile-perfect mandate**
- **PART 3 — System architecture: the layered map (every subsystem)**
- **PART 4 — The iOS app (complete spec): capture, guidance, upload, auth, IAP, push, offline, deep links**
- **PART 5 — The scroll-scrub flythrough player (mobile-perfect, exhaustive)**
- **PART 6 — The render pipeline (state machine + every stage)**
- **PART 7 — Storage, streaming & delivery layer**
- **PART 8 — Backend services, data model (full schema) & API surface**
- **PART 9 — Payments & billing (Apple IAP compliance + Stripe + credits ledger)**
- **PART 10 — Sharing, embeds & the growth loop**
- **PART 11 — Lead capture & CRM integrations**
- **PART 12 — Listing metadata & MLS integration**
- **PART 13 — Analytics, dashboards & agent reporting**
- **PART 14 — Admin, internal tooling & ops console**
- **PART 15 — Security, privacy, compliance & content moderation**
- **PART 16 — Infrastructure, DevOps, observability & SLOs**
- **PART 17 — Testing strategy (incl. real-device & render QC)**
- **PART 18 — Notifications (APNs, email, SMS)**
- **PART 19 — Onboarding, activation & retention**
- **PART 20 — Pricing & unit economics (modeled with verified costs)**
- **PART 21 — Roadmap: phased milestones with acceptance criteria**
- **PART 22 — Risk register & mitigations**
- **PART 23 — Team, roles & delivery plan**
- **PART 24 — Appendices: encode recipes, ffmpeg, generative prompt templates, iOS entitlements, glossary**

---

# PART 0 — EXECUTIVE SUMMARY

**Product.** ROAM is an iOS app where a real-estate agent (or any business) records a single continuous walkthrough of a space with their iPhone — or uploads an existing phone/drone clip — and ROAM automatically renders it into a **cinematic, scroll-through "fly-through."** The viewer scrolls or swipes and glides through the property like a drone, room by room. The output is a **shareable link + embeddable page** that plays perfectly on a phone: drop it in an Instagram bio, a listing, or a text, and prospects fly through the home before they ever book a showing.

**Business.** Pay-per-render (**$29+**) with premium tiers (**4K**, **Cinematic AI**), plus recurring per-listing hosting (**$5/mo**) and team plans. Gross margins **69–93%** when hosted correctly. Replaces $300–$8,000+ per-listing spend on 3D-capture cameras, drone shoots, and photographers.

**Moat & wedge.** ~78% of US listings still have **no** virtual tour. Incumbents are hardware-locked, subscription-locked, or built on clunky click-to-teleport navigation. Even the new "phone-video → 3D" splat startups output a *free-roam scene you drag around* — a videogame. **ROAM's output is a produced, on-rails cinematic scroll — a film.** Position: *"The property tour that watches like a film, not a videogame. Just your phone. No camera, no rig, no monthly fee."*

**Why it's technically feasible today.** The "drone glide" is 90% **stabilization + frame-interpolation + pacing + encode** — cheap, deterministic, no AI required. Generative video (Seedance/Veo/Kling) is a *premium enhancement on 8–15s hero clips only* — using it on a full walkthrough is both unaffordable and incoherent (models drift and hallucinate a different house every clip). The scroll-scrub player is already proven. The remaining work is the iOS app, the automated pipeline, streaming at scale, and the SaaS.

**The single most important engineering decision:** host delivery on **Cloudflare Stream** (per-minute billing → 4K costs the same as 1080p; viral break-even ~28,500 views) with storage on **Cloudflare R2** (zero egress). This one choice is what makes 4K affordable and the unit economics defensible.

---

# PART 1 — MARKET, OPPORTUNITY & COMPETITIVE LANDSCAPE

### 1.1 The numbers (verified 2026)
- **~4 million** US existing-home sales/year (NAR), plus new construction; the **virtual-tour market is ~$11B (2024) → ~$74B by 2030, ~34% CAGR** (Grand View Research).
- **Only ~22% of listings use a virtual tour** (Harvard Business School study of 75,000+ sales) → **~78% have none.** The beachhead is the gap, not the agents already on Matterport.
- **54% of buyers won't view a home without a tour; 62% want more 3D tours** (Zillow 2024 Consumer Housing Trends). Listings with tours see materially more views and inquiries; per vendor data they sell faster and for more (treat vendor stats as directional; HBS is the credible anchor).
- **The three complaints ROAM exploits:** (1) clunky **click-to-teleport node navigation** (worst on mobile); (2) **cost / surprise subscriptions / hosting fees**; (3) **hardware dependency** (Matterport Pro cams, iGUIDE PLANIX, Giraffe robotic cam, Asteroom rotator, 360 cameras).

### 1.2 Competitive map
- **Matterport** (acquired by CoStar, ~$1.6B): category leader; special cams or phone; Free→$69→$309/mo; **click-teleport nodes, media locked in their cloud.**
- **Zillow 3D Home:** free, phone/360; **node-jump panoramas, locked to Zillow's ecosystem.**
- **CloudPano / Kuula / Ricoh360 / Asteroom:** $19–$69/mo or ~$59/tour; **panorama-stitch, discrete hotspots, per-room rig setup.**
- **iGUIDE / Giraffe360:** proprietary hardware ($99–$199/tour or ~$360/mo); **hardware gate.**
- **Splat Tour / Splat Labs / Real Horizons (⚠️ closest thesis):** phone-video → **Gaussian-splat 3D**; free→~€19/mo; **but output is a free-roam scene you drag/orbit — not a guided cinematic scroll.**

### 1.3 The seam ROAM owns
Own the **format**, not the reconstruction tech. Splat startups do "phone → 3D scene." ROAM does "phone → *produced cinematic scroll*": lower cognitive load, feels like a film, shareable as a link, viewer installs nothing, plays perfectly on a phone. Marketing headline: **"Just your phone. No camera, no rig, no monthly fee."** Attack the ~78% no-tour long tail; expand horizontally later (restaurants, gyms, hotels, apartments, retail, Airbnb, venues).

---

# PART 2 — PRODUCT PRINCIPLES & THE MOBILE-PERFECT MANDATE

### 2.1 Non-negotiable principles
1. **Mobile perfect, always.** Every screen, gesture, and the shared player must be flawless on an iPhone on cellular. Test on real devices (see Part 17). Desktop parity is a bonus, never a driver.
2. **Great input → great output.** Capture guidance is a first-class feature, not a nicety. The app teaches the perfect walkthrough in real time (pace, horizon, path, light).
3. **Deterministic first, generative second.** The base render never depends on expensive AI. Generative is a premium layer on short hero clips only.
4. **The share link is the product AND the growth engine.** Every published flythrough must load fast, look premium, and convert — with lead capture and a subtle ROAM watermark that drives new signups.
5. **Cost-aware by construction.** Every render step logs its compute/API/egress cost. Margin is observable per job from day one. View caps and hosting TTLs are built in, not bolted on.
6. **Fail soft.** Every media path has a fallback: scrub → autoplay loop; 4K → 1080p; generative → deterministic; upload fails → resume; render fails → retry the right step.
7. **Trust & honesty in-app.** Never promise MLS/IDX before it's approved for a market. Be explicit about processing time, view caps, and hosting windows.

### 2.2 What "mobile perfect" concretely means
- **Capture:** 60fps guidance overlays that never drop frames; one-handed reachable controls; works in bright sun (high-contrast UI, brightness boost); survives phone calls, backgrounding, low battery; never loses a recording.
- **Upload:** resumable, background, cellular-aware (warn on large uploads over cellular; allow Wi-Fi-only), progress that survives app kill.
- **Player (shared link):** loads under ~2s to first interaction on 4G; buttery scroll-scrub under the thumb with no jank; correct behavior in iOS Safari **and** in-app browsers (Instagram, TikTok, Facebook, iMessage preview); respects Low Power Mode; never triggers fullscreen unexpectedly; haptic + inertial feel.
- **Auth/payments:** Sign in with Apple; Apple-compliant purchase flow; nothing that risks App Store rejection.

### 2.3 The iOS platform realities we design around (call these out to the builder)
- **iOS Safari autoplay:** inline muted autoplay allowed with `playsinline` + `muted`; sound requires a user gesture. The scrub player is muted by design.
- **In-app browsers** (Instagram/TikTok/FB/Snapchat webviews) are **more restrictive and lower-memory** than Safari — the single most important test surface. Many agents will share to Instagram; most viewers open in the IG webview.
- **iOS memory pressure:** large canvas image sequences can OOM a webview. Budget memory; prefer video-scrub or capped image sequences on mobile.
- **Native HLS on iOS:** Safari plays HLS natively (`<video src=...m3u8>`); other platforms need hls.js. Provide both.
- **App Store IAP rules:** selling digital renders/subscriptions **inside the iOS app** generally requires Apple In-App Purchase (15–30% cut). This is a core architectural decision (Part 9), not an afterthought.
- **Background execution limits:** uploads/render-polling must use background URLSession / push, not long-running foreground timers.
- **ATT / privacy:** App Tracking Transparency, privacy nutrition labels, and Sign in with Apple are mandatory considerations.

---

# PART 3 — SYSTEM ARCHITECTURE: THE LAYERED MAP

ROAM is, at its core, **a queue of long GPU jobs feeding an egress-heavy streaming layer, fronted by a native iOS capture app and a web share-player.** Every layer below is a subsystem you must build or integrate.

```
┌───────────────────────────────────────────────────────────────────────────┐
│ 1. iOS APP (native Swift/SwiftUI)                                           │
│    Capture · Guidance · Room tagging · Resumable upload · Auth · IAP ·      │
│    Push · Offline cache · Deep links · In-app share · Local analytics       │
└───────────────┬───────────────────────────────────────────────────────────┘
                │  HTTPS (REST/GraphQL) + resumable upload (tus/multipart)
┌───────────────▼───────────────────────────────────────────────────────────┐
│ 2. EDGE / API GATEWAY                                                       │
│    TLS, auth (JWT/session), rate limiting, request validation, routing,     │
│    signed upload URLs, signed playback URLs, webhooks in/out                │
└───────┬───────────────────────────────────────────────┬───────────────────┘
        │                                                │
┌───────▼───────────────┐  ┌───────────────────┐  ┌──────▼───────────────────┐
│ 3. CORE SERVICES       │  │ 4. EVENT BUS /     │  │ 5. RENDER ORCHESTRATOR   │
│  Auth · Users/Orgs ·   │  │    JOB QUEUE       │  │  State machine per job · │
│  Listings · Renders ·  │◄─┤ (events, retries,  │─►│  fan-out to GPU workers ·│
│  Billing · Sharing ·   │  │  idempotency,      │  │  per-step cost logging · │
│  Leads · Notifications │  │  dead-letter)      │  │  provider abstraction    │
└───────┬───────────────┘  └───────────────────┘  └──────┬───────────────────┘
        │                                                 │
┌───────▼───────────────┐                          ┌──────▼───────────────────┐
│ 6. DATA STORES         │                          │ 7. GPU RENDER WORKERS     │
│  Postgres (primary) ·  │                          │  Modal/RunPod containers: │
│  Redis (cache/queue) · │                          │  ingest·stabilize·        │
│  Object storage R2 ·   │                          │  interpolate·grade·       │
│  Search index          │                          │  upscale·generative·      │
│                        │                          │  stitch·encode·package    │
└───────┬───────────────┘                          └──────┬───────────────────┘
        │                                                 │ writes renditions
        │                                          ┌──────▼───────────────────┐
        │                                          │ 8. STREAMING/DELIVERY     │
        │                                          │  Cloudflare Stream + R2 · │
        │                                          │  HLS ABR · scrub proxy ·  │
        │                                          │  sprite/VTT · signed URLs │
        │                                          └──────┬───────────────────┘
        │                                                 │
┌───────▼─────────────────────────────────────────────────▼──────────────────┐
│ 9. WEB LAYER                                                                │
│    Public flythrough share-player (mobile-perfect) · embed · marketing      │
│    site · agent dashboard · admin/ops console                               │
└───────────────────────────────────────────────────────────────────────────┘
        ▲                         ▲                        ▲
        │                         │                        │
┌───────┴──────────┐  ┌───────────┴─────────┐  ┌───────────┴──────────────────┐
│ 10. PAYMENTS      │  │ 11. NOTIFICATIONS   │  │ 12. INTEGRATIONS             │
│  Apple IAP (iOS) ·│  │  APNs push ·        │  │  CRM/GHL webhooks · MLS/RESO │
│  Stripe (web) ·   │  │  Transactional email│  │  · listing-URL metadata ·    │
│  credits ledger   │  │  · SMS              │  │  social export               │
└──────────────────┘  └─────────────────────┘  └──────────────────────────────┘

  Cross-cutting: 13. Observability (logs/metrics/traces/alerts) ·
  14. Security/Privacy/Compliance · 15. CI/CD & IaC · 16. Feature flags/config ·
  17. Analytics/telemetry · 18. Cost accounting/FinOps
```

### 3.1 The eighteen subsystems (each is specified later)
1. **iOS app** (Part 4) — native Swift/SwiftUI capture + upload + account.
2. **API gateway** (Part 8) — the front door.
3. **Core services** (Part 8) — auth, users/orgs, listings, renders, billing, sharing, leads, notifications.
4. **Event bus / job queue** (Parts 6, 8) — durable, idempotent, retriable.
5. **Render orchestrator** (Part 6) — the per-job state machine.
6. **Data stores** (Part 8) — Postgres, Redis, R2, search.
7. **GPU render workers** (Part 6) — the pipeline containers.
8. **Streaming/delivery** (Part 7) — Cloudflare Stream + R2 + scrub proxy + sprites.
9. **Web layer** (Parts 5, 10, 13, 14) — player, embed, dashboard, admin.
10. **Payments** (Part 9) — Apple IAP + Stripe + credits ledger.
11. **Notifications** (Part 18) — APNs, email, SMS.
12. **Integrations** (Parts 11, 12) — CRM/GHL, MLS/RESO, listing URLs, social.
13. **Observability** (Part 16).
14. **Security/privacy/compliance** (Part 15).
15. **CI/CD & IaC** (Part 16).
16. **Feature flags & remote config** (Parts 4, 16).
17. **Analytics/telemetry** (Part 13).
18. **FinOps / cost accounting** (Parts 6, 20) — per-render margin visibility.

### 3.2 A duration reality that shapes the whole system
**Flythroughs are NOT all short.** A studio condo might be a 45–90s flythrough; a large single-family home 2–4 min; a **luxury estate or apartment/condo complex 5–10+ min.** This has cascading consequences the builder must design for from day one:
- **Render compute scales with length** (stabilize/interpolate/upscale are per-frame) → cost per render is a **function of source minutes**, not a flat number.
- **Streaming cost scales with minutes watched.** On Cloudflare Stream (per-minute billing), a 6-min flythrough watched for 3 min costs ~4.5× a 40s watch. Delivery — not storage — dominates and it is **duration-driven**.
- **Pricing must be duration-based** (per-minute-of-output tiers), and **view caps must be minute-based** (included *streamed minutes*), not a flat view count. A flat $29-for-any-length model loses money on long, popular, big-property flythroughs.
- **The player must stay buttery for long videos** — long scrub tracks, more keyframes, larger proxies, memory ceilings on mobile webviews. Canvas image-sequence scrubbing does NOT scale to multi-minute 4K (too many frames/too much memory); long videos use the **low-res all-intra scrub proxy + high-bitrate playback rendition** path (Part 5).
See Part 20 for the duration-aware pricing model and Part 6/7 for the length-driven cost and player implications.

---

# PART 4 — THE iOS APP (COMPLETE SPEC)

**Recommendation: build the ROAM capture app as a native iOS app in Swift + SwiftUI.** Rationale: ROAM is iOS-only for v1, and the two things that make or break it — (a) frame-perfect camera control with gyro/IMU logging for stabilization, and (b) rock-solid resumable background uploads of large video — are exactly where native AVFoundation + URLSession beat cross-platform. (An Expo + react-native-vision-camera build is a viable faster-to-ship alternative if the team is RN-native; if chosen, the same subsystem specs below apply, using VisionCamera, expo-sensors, and a background-upload module. Default to native Swift.)

Minimum target: **iOS 16+** (SwiftUI maturity, `AVCaptureSession` multi-cam, ScreenCaptureKit-era APIs), iPhone 11 and newer as the performance floor; design for iPhone SE small screens and Pro Max large screens.

## 4.1 App module map
1. **Onboarding & auth** (Sign in with Apple, email OTP, phone OTP)
2. **Home / My Listings** (list, statuses, search, filters)
3. **New Listing** (metadata entry or URL/MLS import)
4. **Capture** (guided recording) OR **Import** (photo library / Files / drone clip)
5. **Room tagging** (live during capture + post-capture on a scrubber)
6. **Review & submit** (choose render tier, confirm length/price, pay)
7. **Render status** (progress, push on completion)
8. **Flythrough detail** (preview, share, embed, analytics, re-render)
9. **Share sheet** (link, QR, social export, copy embed)
10. **Leads inbox** (leads captured from that listing's flythrough)
11. **Billing / credits** (purchases, subscription, invoices)
12. **Settings** (brand kit, notifications, account, legal, support)

## 4.2 Capture subsystem (the crown jewel)
**Engine:** `AVCaptureSession` with `AVCaptureMovieFileOutput` (or `AVAssetWriter` for finer control). Configure the best format for stabilization + interpolation input:
- **Resolution/fps:** capture at **4K/60 when the device supports it and thermals allow**, else 4K/30 or 1080p/60. Store the true capture fps in metadata (the pipeline needs it).
- **Stabilization at source:** enable `preferredVideoStabilizationMode = .cinematicExtended` (or `.auto`); expose an **"Action Mode"-style toggle** for max stabilization on newer devices. This is free stabilization that reduces pipeline work.
- **Gyro/IMU logging:** record **CoreMotion** device-motion (attitude, rotation rate, gravity) time-synced to the video via `CMSampleBuffer` presentation timestamps, and persist it as a sidecar. **This gyro sidecar lets the render pipeline use Gyroflow-grade stabilization (sub-pixel), which is the single biggest quality lever** — do not skip it.
- **HDR & color:** capture in a consistent color space (Rec.709 for predictable grading; optionally HDR with a tone-mapping step in the pipeline). Lock white balance/exposure smoothing to avoid flicker while walking room-to-room (or auto with smoothing).
- **Audio:** capture audio (for optional ambient/soundtrack) but the flythrough is muted by default; keep audio as an optional track.
- **Thermals & battery:** monitor `ProcessInfo.thermalState`; if `.serious/.critical`, drop to 4K/30 or 1080p and warn. Warn at low battery before a long capture.
- **Storage:** write to app container; show remaining-space estimate (4K/60 ≈ ~400 MB/min — a 6-min estate ≈ ~2.4 GB). Guard against out-of-space mid-capture (pre-flight check).

**Guided-capture overlays (must run at 60fps, never jank):**
- **Horizon/level indicator:** from `CMDeviceMotion` gravity vector — `pitch`, `roll`; show a bubble/level that turns green when the phone is upright and steady. Nudge "keep it level."
- **Pace metronome:** target a slow, steady walking speed. Derive motion magnitude from `userAcceleration`/`rotationRate`; a subtle pulsing ring + haptic taps set the pace ("match this rhythm"). Warn "slow down" when motion exceeds a threshold (fast motion = interpolation artifacts + motion blur).
- **Path guide:** on-screen tips per phase — "start outside / at the entry," "sweep doorways slowly," "one continuous take," "end on the backyard/exterior." Optional checklist of rooms to visit.
- **Framing guide:** rule-of-thirds grid; "phone at chest height, portrait or landscape (pick once, keep it)."
- **Light check:** sample average luminance; warn "too dark — open blinds / turn on lights."
- **Live room tagging:** floating buttons ("Kitchen," "Primary," "Backyard," "+ Add room") that **timestamp a chapter marker** at the current recording time; editable later.

**Capture UX rules (mobile perfect):** big reachable record button; lock orientation once chosen; prevent accidental stops; auto-pause handling on interruptions (calls, Control Center) with `AVCaptureSessionInterruption` observers and graceful resume or safe finalize; never lose footage — finalize partial recordings and let the user resume/append or submit as-is.

## 4.3 Import subsystem (existing phone/drone video)
- Import from **Photos** (PHPicker), **Files** (drone exports), or AirDrop.
- Validate: duration (min ~20s, max configurable e.g. 15 min), resolution, fps, codec (H.264/HEVC/ProRes), rotation, HDR. Reject/repair as needed; transcode ProRes to a working codec on-device or server-side.
- Drone clips often already smooth/4K → the pipeline can **skip stabilization** and go straight to grade/encode (detect via metadata + optional user "this is a drone shot" flag).

## 4.4 Upload subsystem (resumable, background, cellular-aware)
- **Protocol:** resumable chunked upload via **tus** (or S3/R2 multipart) to a signed upload URL. Persist the upload URL + offset locally (Core Data/SQLite) so it resumes across app launches.
- **Background:** use a **background `URLSession`** (`URLSessionConfiguration.background`) so uploads continue when the app is backgrounded/killed and wake the app on completion. Note iOS favors a single background transfer over many small chunks — chunk while foreground, hand off to a consolidated background transfer when the user leaves.
- **Cellular awareness:** detect connection type; if on cellular and file is large, prompt "This is a 2.4 GB upload — upload on Wi-Fi, or continue on cellular?" with a Wi-Fi-only default toggle in settings.
- **Integrity:** checksum (SHA-256) client + server; verify before enqueueing render.
- **Progress & resilience:** live progress that survives app kill; auto-retry with backoff; clear failed/paused/queued states; let the user pause/resume.
- **Pre-upload compression option:** optionally transcode a lighter upload proxy on-device (HEVC) to cut upload time, while keeping the option to upload the full-quality master for best 4K output (make this a setting: "faster upload" vs "best quality").

## 4.5 Auth & identity
- **Sign in with Apple** (required if offering third-party login; also the smoothest iOS UX), **email magic-link/OTP**, and **phone OTP** (agents love SMS). Backend issues JWT/refresh tokens; store in **Keychain**.
- **Org model:** a user can belong to an org (team/brokerage) with roles (owner, admin, agent, marketing). Brand kit at org level (logo, colors, agent card, default CTA).
- **ATT:** request App Tracking Transparency only if you actually do cross-app tracking; otherwise skip to avoid friction. Provide full privacy nutrition labels.

## 4.6 In-app purchases & entitlements (see Part 9 for the full billing spec)
- **Apple IAP is required** for selling renders/subscriptions consumed in the iOS app. Model renders as **consumable credits** (e.g., "render credits" or "minute credits") purchased via StoreKit 2, and hosting/team as **auto-renewable subscriptions.**
- Maintain an **entitlements cache** locally, validated by server-side receipt validation + StoreKit 2 transactions; the server credits ledger is the source of truth.
- Provide a restore-purchases path and clear receipts/invoices.

## 4.7 Push, deep links, offline
- **APNs push** for render-complete, lead-received, hosting-expiring, purchase receipts. Ask for permission contextually (after first render submitted, not at cold start).
- **Universal Links** (`applinks:`) so tapping a flythrough link opens the app if installed (agent side), and **deep links** to a listing/render/lead.
- **Offline:** capture and queue uploads offline; view cached listings/renders; graceful "reconnect to submit" states. Local store = Core Data or SQLite (GRDB); cache media thumbnails.

## 4.8 App-side analytics, flags, crash, support
- **Telemetry:** capture-funnel events (started, completed, submitted), upload success/failure, render outcomes, share actions, lead events. Privacy-respecting (no PII in analytics).
- **Feature flags / remote config** (e.g. via a config service) to gate tiers, pricing, capture params, and kill-switches without an App Store release.
- **Crash & performance:** crash reporting (e.g. Sentry/Crashlytics), ANR/hang detection, frame-drop monitoring on capture overlays.
- **In-app support:** help center, "how to shoot a great walkthrough" tutorial (video), contact support, and a "report a bad render" path that attaches job id + logs.

## 4.9 iOS quality bar (acceptance)
- Capture overlays hold 60fps on iPhone 12+; no dropped recording across interruptions in a 100-recording soak test.
- Resumable upload survives app kill + network loss + device reboot and completes.
- Cold start < 1.5s to Home; capture screen ready < 1s from tap.
- Full VoiceOver labels; Dynamic Type; dark mode; small-screen (SE) and large-screen (Pro Max) layouts correct.
- No App Store rejection risks (IAP compliance, privacy labels, ATT, permission strings all present).

---

# PART 5 — THE SCROLL-SCRUB FLYTHROUGH PLAYER (MOBILE-PERFECT, EXHAUSTIVE)

This is the product's face — the thing shared to Instagram and opened by thousands of prospects on their phones. **It must be flawless in the iOS Safari and in-app webviews.** It is a web player (so viewers install nothing) that can also be embedded in the native app via `WKWebView`.

## 5.1 The proven core technique (reuse from the prototype)
Scroll position drives `video.currentTime`. One continuous video is scrubbed by scroll/finger instead of playing on a timer:
- A tall scroll container (e.g. `height: NNNvh`, N scaled to video length) with a **`position: sticky`, 100svh video** inside.
- A `requestAnimationFrame` loop: `p = clamp(-track.top / (track.height - innerHeight), 0, 1)`; `targetT = p * (duration - 0.05)`; **ease** `curT += (targetT - curT) * 0.1`; set `video.currentTime = curT` only when `|video.currentTime - curT| > ~0.02`. The lerp is what makes it buttery, not jumpy.
- Room labels / captions fade by scroll anchor: `opacity = clamp(1 - |p - anchor| / window, 0, 1)`; translateY for a subtle rise.
- Progress bar `scaleX(p)`; buffer gate begins scrubbing at ~96% buffered; % loader before.

## 5.2 Two rendering paths — pick by length (critical for mobile + long videos)
- **Path A — Video-scrub (default; required for anything over ~60s or 4K).** Play a **low-res, dense-keyframe / all-intra "scrub proxy"** (e.g. 540–720p, short GOP) under the scroll, and swap to the **high-bitrate playback rendition** (1080p/4K) on tap/fullscreen. Dense keyframes make `currentTime` seeks instant; low-res keeps the proxy small and memory-safe. **This is the path for large houses / apartment complexes** — canvas frames don't scale to multi-minute 4K.
- **Path B — Canvas image-sequence (short only, ≤ ~45–60s).** Pre-decode WebP/JPEG frames into `ImageBitmap`s and blit the right one per scroll tick (the Apple product-page technique) — zero runtime seek, most reliable cross-browser. **Cap the frame count** (e.g. ≤ ~300–450 frames) and resolution to stay under mobile-webview memory limits; never use for long flythroughs.

The render pipeline (Part 6) emits the right assets for the chosen path based on final duration.

## 5.3 iOS Safari & in-app webview specifics (the make-or-break list)
- **Attributes:** `<video muted playsinline preload="auto" disablepictureinpicture disableRemotePlayback>`; `webkit-playsinline` for legacy. Never rely on audio.
- **First-frame paint:** show a **poster** immediately; don't block on full buffer. Reveal the scrub only after enough buffered range covering the initial scroll.
- **Seeking cost:** iOS coalesces rapid `currentTime` sets; keep the delta threshold and lerp so you don't thrash the decoder. Prefer HLS byte-range seeking on the proxy.
- **Memory:** in-app browsers (Instagram/TikTok/FB) have **much smaller memory budgets** than Safari — this is the #1 test target. Keep the proxy small; unload the canvas path if used; avoid multiple decoders; release `ImageBitmap`s.
- **Low Power Mode:** autoplay/decoding can be throttled; detect jank and fall back to a tap-to-play autoplay-loop with the same overlays.
- **Momentum scrolling & rubber-banding:** use `overflow` scroll with `-webkit-overflow-scrolling: touch`; account for iOS momentum in the rAF mapping; avoid layout thrash (use transforms/opacity only).
- **Address-bar resize:** iOS Safari toolbar show/hide changes viewport height — use `100svh`/`100dvh` and recompute on `resize`/`visualViewport` to prevent jumps.
- **Touch vs scroll:** support **both** vertical scroll (default) and an optional **drag-to-scrub** gesture; add subtle **haptics** (where available via the Vibration API — limited on iOS) and inertial easing so it *feels* like flying.
- **Reduced motion:** honor `prefers-reduced-motion` with a gentler mode.

## 5.4 Player features (overlays & conversion)
- Room labels/chapters with a **chapter rail** (tap a room → smooth-scroll to that anchor).
- Listing metadata card (address, beds/baths/sqft/price), **agent card** (photo, name, brokerage, call/text/email), and a **"Book a showing" lead form** (Part 11) appearing at anchor points and at the end.
- **Scrub hint** on load ("scroll to fly through ↓") that fades after first interaction.
- **Sprite/VTT hover thumbnails** on desktop; on mobile, a lightweight timeline with room ticks.
- **ROAM watermark / "Made with ROAM" chip** (subtle; drives the growth loop; removable on higher tiers).
- **Fullscreen / immersive** tap-to-play with sound (if an audio track exists).
- **Social meta:** rich Open Graph/Twitter cards (poster + title) so links unfurl beautifully in iMessage/IG/FB.
- **Analytics beacon:** report view start, scroll depth (% of home seen), room dwell, lead submit, and **streamed minutes** (for billing/caps) — batched, privacy-respecting.

## 5.5 Performance budget (mobile)
- First interaction < ~2s on 4G; poster paint < 500ms.
- No long tasks > 50ms during scrub; rAF loop stays within frame budget (use passive listeners, transform/opacity only, no layout in the loop).
- Proxy size target: keep the scrub proxy small enough to buffer the first segments fast even in an IG webview.
- Graceful degradation ladder: 4K playback → 1080p → scrub proxy only → autoplay loop → poster + "tap to play."

## 5.6 Embed
- `<iframe>` + a lightweight `<script>` embed for listing sites/portals; responsive; lazy-loaded; postMessage API for height + events; respects the same mobile rules.

---

# PART 6 — THE RENDER PIPELINE (STATE MACHINE + EVERY STAGE)

The pipeline turns raw capture into the streaming renditions the player needs. It is an **async job orchestrated as a state machine**, fanned out to GPU workers, with **per-step cost logging** and **retry-the-right-step** semantics. Compute scales with source length (Part 3.2), so cost is tracked per job and used to price/settle credits.

## 6.1 Job state machine
`created → uploaded → validating → queued → ingesting → stabilizing → interpolating → grading → upscaling(optional) → segmenting → generating_hero(optional) → stitching → encoding → packaging → publishing → ready`
Terminal/aux: `failed(step, reason)`, `needs_reshoot(quality)`, `canceled`, `expired`, `archived`.
Rules: each transition is an event on the bus; each step is **idempotent** (safe to retry) and **checkpointed** (a failed `upscaling` retries upscaling, not the whole chain); a **dead-letter** path captures poison jobs for ops. Every step writes `{durationMs, gpuType, gpuSeconds, providerCost, bytesIn, bytesOut}` to a `render_step_costs` ledger.

## 6.2 Stage-by-stage
1. **Validate / QC (fast, cheap).** Probe duration/fps/res/codec/rotation/HDR; run a quick quality heuristic (blur/shake/darkness score from sampled frames). If below threshold → `needs_reshoot` with specific guidance ("too dark in the kitchen," "too shaky at 0:45"). This protects output quality and saves GPU spend on hopeless input.
2. **Ingest / normalize.** Transcode to a working intermediate (e.g. lightly-compressed intra-friendly), fix rotation, normalize color space, split audio track aside.
3. **Stabilize.** If a **gyro sidecar** exists → **Gyroflow**-grade sub-pixel stabilization + horizon lock (best). Else → **ffmpeg vidstab 2-pass** (detect + transform). Drone clips flagged smooth → skip. This is the #1 "handheld → floating drone" lever.
4. **Interpolate → 60fps glide.** **RIFE/FILM** to 60fps + optional slight slow-mo so it glides like a gimbal. **Topaz Video AI (Aion/Apollo)** for problem footage. Motion-blur management to avoid smear.
5. **Grade.** Auto cinematic grade (contrast/warmth/lift), denoise (`hqdn3d`), consistent look; optional brand LUT per org.
6. **Upscale (tier-gated).** 1080p base; **4K** on premium via Topaz (self-host on Modal GPU or desktop-farm) — keeps 4K near-$0 marginal vs per-frame hosted APIs.
7. **Segment / room-split.** Use chapter timestamps to define room segments (for chapter rail + potential per-room hero transitions).
8. **Generate hero clips (Cinematic AI tier only).** For 1–3 short moments (opener, key transitions) generate **8–15s image-to-video seeded from a REAL frame** (Seedance/Veo/Kling) so it stays on-model. Prompt templates in Appendix C. QC each clip; auto-regen up to a capped budget; if it drifts off-model, drop it and fall back to the deterministic cut. **Never** attempt full-length generative (cost + incoherence — see Part 20/Appendix).
9. **Stitch.** Assemble deterministic backbone + hero clips + intro/outro; add subtle transitions; overlay burn-ins only if needed (labels are rendered by the player, not baked, so they stay crisp and editable).
10. **Encode (multi-rendition).** Emit: (a) **scrub proxy** — low-res all-intra/short-GOP H.264 for instant seek; (b) **playback renditions** — 1080p and/or 4K, **AV1 preferred** (30–50% smaller than HEVC, broad HW decode on M3/M4+/A17+), H.264/HEVC fallback; short-GOP + faststart on all. Recipes in Appendix A.
11. **Package.** HLS (and DASH if needed) ABR ladder; generate **sprite atlas + WebVTT** thumbnail track for scrub preview; poster + social OG image.
12. **Publish.** Push renditions to Cloudflare Stream/R2; write `Render` record with playback ids, durations, byte sizes, sprite/VTT, poster; flip listing to `ready`; fire `render.ready` event → push + email + webhook.

## 6.3 GPU workers & orchestration
- **Primary compute: Modal** (scale-to-zero, ~1s cold start, arbitrary containers with FFmpeg + RIFE + upscaler + Gyroflow baked into one image; `.spawn()` + `Queue` + retries built in). **RunPod** for cost-sensitive batch; **fal.ai** to offload hosted interpolation/upscale if quality-per-dollar wins there.
- **Provider abstraction:** every step implements a `RenderStep` interface (`run(input) → output + cost`) so engines can be swapped/routed to cheapest-that-qualifies. Generative providers behind a `GenerativeVideoProvider` interface (Seedance/Veo/Kling/Runway) with per-provider cost + quality scoring.
- **Orchestration:** Modal primitives for v1; **Inngest** once you fan across providers (event-driven, per-step retry from checkpoint, idempotency keys, concurrency limits, cost logging, and a `notify` step per transition). Temporal only if pipelines become long-lived/multi-day.
- **Autoscaling & queues:** priority queues (team/priority renders jump), backpressure, max-concurrency per GPU type, and a cost ceiling per job that pauses + alerts if exceeded.
- **Idempotency & retries:** deterministic step keys; exactly-once side effects on publish; exponential backoff; dead-letter after N attempts with ops alert.

## 6.4 Cost & FinOps hooks (margin visibility from day one)
Every job aggregates `render_step_costs` into a `job_cost` (compute + generative + encode + packaging) and, post-publish, accrues **delivery cost by streamed minutes** (Part 7). The billing service compares `job_cost + accrued_delivery` against the price paid to compute **realized margin per render**, surfaced in the admin cost dashboard (Part 14) and used to tune pricing/caps.

---

# PART 7 — STORAGE, STREAMING & DELIVERY LAYER

## 7.1 The two decisions that define the unit economics
- **Storage: Cloudflare R2 for everything** (raw uploads, intermediates, renditions, sprites, posters). **Zero egress** — the highest-leverage decision in the build. At 10 TB/mo egress, R2 = $0 vs S3 ≈ $890/mo (~$10K/yr). S3-compatible, so tus/multipart tooling just swaps the endpoint. Watch R2 Class-A op cost — batch/tar intermediates; don't write tens of thousands of individual frame files (use worker scratch volumes, push consolidated artifacts).
- **Delivery: Cloudflare Stream** for HLS ABR + CDN. **Per-minute-delivered billing, bandwidth included, resolution-agnostic → 4K costs the same as 1080p.** This is what makes 4K affordable and pushes viral break-even to ~28,500 view-equivalents (vs ~3,200 on Mux). **Mux** is easiest for an MVP (native sprite/VTT storyboards + instant seek) but is a margin killer at viral scale — use it only to ship fast, migrate to Stream as volume grows. Never run the entry tier on Mux.

## 7.2 Rendition set per flythrough
- **Scrub proxy:** low-res (540–720p) all-intra/short-GOP H.264 for instant seek (mobile-safe).
- **Playback renditions:** 1080p (base), 4K (premium) — AV1 preferred + H.264/HEVC fallback; ABR ladder for connection adaptation.
- **Sprite atlas + WebVTT** thumbnail track (scrub preview).
- **Poster** (first strong frame) + **social OG image** (branded).

## 7.3 Duration-aware delivery cost (this is the core economic variable)
Delivery cost = **streamed minutes × rate**. Streamed minutes = Σ over views of (minutes each viewer actually watches). Because flythroughs range from ~45s (condo) to 8+ min (estate/complex), and popular listings get thousands of views, **delivery is duration-driven and must be metered, capped, and priced by minutes** (see Part 20). The player reports **streamed minutes** per view to the billing/metering service; caps and hosting TTLs enforce ceilings.

## 7.4 Access control & lifecycle
- **Signed playback URLs** (short-lived tokens) so links can be revoked/expired; per-listing access rules (public share vs private preview).
- **Hosting TTL:** included window (e.g. 60–90 days) then auto-expire unless on a hosting plan; expiry both caps egress exposure and creates the $5/mo upsell moment.
- **Storage tiering:** hot renditions on Stream/CDN; masters + intermediates to R2 cold/archive; auto-demote listings not viewed in ~14 days; re-derive on demand.
- **Purge & privacy:** hard-delete on user request (GDPR/CCPA) across Stream + R2 + DB references; audit log.

---

# PART 8 — BACKEND SERVICES, DATA MODEL & API SURFACE

## 8.1 Service map (modular monolith is fine for v1; split later)
- **Auth service** — Sign in with Apple/email/phone OTP, JWT/refresh, sessions, org/roles.
- **Users/Orgs service** — profiles, teams, brand kits, roles/permissions.
- **Listings service** — listings + metadata (manual/URL/MLS), lifecycle.
- **Capture/Upload service** — signed upload URLs, resumable session state, checksum verify, hand-off to render.
- **Render service** — job creation, status, orchestration triggers, cost aggregation, re-render.
- **Streaming service** — playback URL signing, rendition registry, sprite/poster, expiry.
- **Billing service** — Apple IAP receipt validation, Stripe (web), credits ledger, subscriptions, invoices, metering (streamed minutes), margin accounting.
- **Sharing service** — share pages, embeds, OG images, QR, view/beacon ingest.
- **Leads service** — lead capture, routing, CRM/GHL webhooks, notifications.
- **Notifications service** — APNs, email, SMS; templates; preferences.
- **Analytics service** — event ingest, agent dashboards, internal ops metrics.
- **Admin service** — ops console, moderation, support tooling, cost dashboard.
- **Integrations service** — MLS/RESO, listing-URL scrape, social export, CRM.

## 8.2 Data model (Postgres — starter DDL sketch)
```sql
-- Identity & org
users(id pk, email, phone, apple_sub, name, avatar_url, created_at, ...)
orgs(id pk, name, type[solo|team|brokerage], brand_kit jsonb, created_at)
memberships(id pk, user_id fk, org_id fk, role[owner|admin|agent|marketing])

-- Listings & capture
listings(id pk, org_id fk, agent_id fk, address, beds, baths, sqft, price_cents,
         description, status[draft|capturing|processing|ready|expired|archived],
         source[manual|url|mls], mls_ref, created_at)
capture_assets(id pk, listing_id fk, storage_key, duration_s, fps, width, height,
               codec, is_drone bool, has_gyro bool, sha256, bytes, created_at)

-- Render pipeline
render_jobs(id pk, listing_id fk, capture_asset_id fk, tier[smooth|premium4k|cinematic],
            status, current_step, error jsonb, cost_cents int, priority int,
            created_at, started_at, finished_at)
render_step_costs(id pk, job_id fk, step, gpu_type, gpu_seconds numeric,
                  provider, provider_cost_cents, bytes_in, bytes_out, ms int, created_at)
renders(id pk, job_id fk, listing_id fk, duration_s, has_4k bool,
        scrub_playback_id, playback_ids jsonb, sprite_key, vtt_key, poster_key,
        published_at, expires_at, hosting_plan_id fk null)

-- Sharing & leads
share_pages(id pk, render_id fk, slug unique, cta_config jsonb, lead_capture bool,
            watermark bool, created_at)
share_views(id pk, share_page_id fk, ts, minutes_streamed numeric, scroll_depth numeric,
            country, referrer, device, in_app_browser text)  -- metering + analytics
leads(id pk, share_page_id fk, listing_id fk, name, email, phone, message,
      status, routed_to, crm_synced bool, created_at)

-- Billing
credit_ledger(id pk, org_id fk, delta int, reason, ref_type, ref_id, balance_after, created_at)
purchases(id pk, org_id fk, platform[apple|stripe], product_id, amount_cents,
          apple_txn_id, stripe_pi, status, created_at)
subscriptions(id pk, org_id fk, platform, product_id, status, current_period_end,
              seats int, plan[hosting|team|pro], created_at)
metering(id pk, render_id fk, month, minutes_streamed numeric, delivery_cost_cents int)

-- Notifications & audit
notifications(id pk, user_id fk, type, payload jsonb, sent_at, read_at)
audit_log(id pk, actor_id, action, target_type, target_id, meta jsonb, ts)
```
Indexing: hot paths on `listings(org_id,status)`, `render_jobs(status,priority)`, `share_views(share_page_id,ts)`, `credit_ledger(org_id,created_at)`. Money in integer cents. Soft-delete + audit for compliance.

## 8.3 API surface (illustrative REST; GraphQL optional for the app)
```
POST   /auth/apple            POST /auth/email/otp        POST /auth/phone/otp
POST   /auth/refresh          POST /auth/logout

GET    /me                    PATCH /me                   GET /orgs/:id
POST   /orgs                  PATCH /orgs/:id/brand-kit   POST /orgs/:id/members

GET    /listings              POST /listings              GET/PATCH/DELETE /listings/:id
POST   /listings/:id/metadata/from-url   POST /listings/:id/metadata/mls

POST   /uploads/session       -> {uploadUrl, uploadId}   (tus/multipart, signed)
POST   /uploads/:id/complete  -> verifies checksum, creates capture_asset
POST   /captures/:assetId/chapters   (room tags)

POST   /renders               (listingId, assetId, tier) -> job   (debits credits)
GET    /renders/:jobId        (status, step, cost)        POST /renders/:jobId/cancel
POST   /renders/:jobId/retry  POST /renders/:renderId/re-render

GET    /f/:slug               (public share page data)    POST /f/:slug/view (beacon)
POST   /f/:slug/lead          (lead capture)              GET  /renders/:id/embed

GET    /billing/products      POST /billing/apple/validate (receipt)
POST   /billing/stripe/checkout   POST /billing/webhooks/apple  POST /billing/webhooks/stripe
GET    /billing/credits       GET  /billing/invoices

GET    /leads                 PATCH /leads/:id            POST /integrations/crm/test
GET    /analytics/listings/:id   GET /analytics/org

# Admin (separate auth/role)
GET    /admin/jobs            GET /admin/costs            POST /admin/jobs/:id/requeue
GET    /admin/margins         POST /admin/moderation/:id/action
```
Webhooks OUT: `render.ready`, `lead.created`, `hosting.expiring`, `purchase.completed`. All idempotent, signed (HMAC), retried with backoff.

---

# PART 9 — PAYMENTS & BILLING (APPLE IAP COMPLIANCE + STRIPE + CREDITS LEDGER)

**This is a first-class architectural constraint, not a checkout screen.** Get it wrong and Apple rejects the app.

## 9.1 The Apple rule (design around it)
Digital goods/services consumed inside an iOS app (renders, hosting, team plans) generally **must** use **Apple In-App Purchase** (StoreKit 2), which takes **15–30%**. You cannot link out to a cheaper web checkout to dodge it (with narrow, evolving exceptions). Plan for it:
- **In-app purchases (StoreKit 2):**
  - **Render/minute credits** = **consumable** IAPs (buy a pack of render-minutes or render credits; a render debits the ledger by its duration/tier cost).
  - **Hosting & Team plans** = **auto-renewable subscriptions**.
- **Web purchases (Stripe):** the **marketing site / web dashboard** can sell via Stripe at full margin (no Apple cut). Encourage agents to buy credits on the web where allowed; the app consumes the shared credits ledger. (Do NOT put "buy cheaper on the web" CTAs inside the iOS app — that risks rejection.)
- **Price the IAP tiers to absorb Apple's cut** so blended margin stays healthy; steer power users/teams to web/Stripe billing.

## 9.2 Credits ledger (single source of truth)
- All purchases (Apple or Stripe) **credit** the org's ledger; every render **debits** it by a computed cost (duration × tier rate — see Part 20). Balance is server-authoritative; the app shows a cached balance validated against the server.
- **Server-side receipt validation:** validate Apple transactions (StoreKit 2 `Transaction` + App Store Server API/notifications v2) and Stripe webhooks; grant credits only on verified, non-duplicated transactions (idempotency on `apple_txn_id`/`stripe_pi`).
- **Refunds & chargebacks:** handle Apple refund notifications + Stripe disputes → reverse ledger entries; flag abuse.
- **Metering settlement:** streamed-minute overages beyond a render's included minutes either draw from credits, prompt an upgrade, or auto-degrade quality (Part 20 caps).

## 9.3 Subscriptions & team billing
- Hosting ($5/mo per active listing) and Team ($199/mo incl. renders + hosted listings + priority) as auto-renewable subs (Apple) or Stripe subscriptions (web/brokerage). Proration, seat management, dunning (failed-payment retries + grace), invoices, tax (Stripe Tax), and clear cancellation.

## 9.4 Acceptance
- No App Store rejection for IAP/entitlements; restore-purchases works; receipts validated server-side; ledger reconciles to Apple/Stripe reports; no double-credit on retries.

---

# PART 10 — SHARING, EMBEDS & THE GROWTH LOOP

The share link is the flywheel. Optimize it relentlessly for mobile virality.

- **Share sheet (in-app + web):** copy link, QR code (for print flyers/yard signs/open houses), "share to Instagram/TikTok/Facebook/iMessage," copy embed code.
- **Rich unfurls:** per-share **Open Graph/Twitter** tags (branded poster + title + description) so links look premium in iMessage/IG/FB DMs. Generate a branded OG image per render.
- **Social export:** produce **vertical 9:16 short clips** (auto-cut highlights of the flythrough) for Reels/TikTok/Stories with a "link in bio" nudge — this is how agents advertise the swipe-through experience. (Reuse the render pipeline to emit a 9:16 teaser rendition.)
- **Watermark / attribution:** subtle "Made with ROAM" chip + link on free/entry tier (removable on higher tiers) → every viewed flythrough markets ROAM to the next agent.
- **Referral:** agent referral codes (give credits, get credits); brokerage seeding.
- **QR at the door:** open-house mode — a QR that opens the flythrough; capture walk-in leads.
- **Privacy controls:** unlisted/private preview links; revoke; password-protect (optional); expire.

---

# PART 11 — LEAD CAPTURE & CRM INTEGRATIONS

- **Lead form on the flythrough** (name/phone/email/message + "Book a showing"/"Get more info") appearing at anchor points and the end; mobile-optimized, one-thumb.
- **Instant routing:** on submit → notify the agent (push + SMS + email), store the lead, and **fire a webhook** to the agent's CRM. First-class **GoHighLevel** integration (webhook/API), plus generic webhook + Zapier/Make; later Follow Up Boss, kvCORE, etc.
- **Attribution:** tie each lead to the listing, the share source (IG/portal/QR), and scroll depth ("watched 80% of the home").
- **Anti-spam:** rate limit, hCaptcha/turnstile, honeypot; validate phone/email.
- **Leads inbox** in-app + dashboard; status (new/contacted/won); export CSV.

---

# PART 12 — LISTING METADATA & MLS INTEGRATION

- **MVP:** manual metadata entry, or **paste a listing URL** (Zillow/Realtor/brokerage) to scrape public fields where permitted (address, beds/baths/sqft/price, photos) with clear ToS awareness.
- **V2 MLS:** **RESO Web API** integration per market. **Be explicit in-app that MLS access is gated** (per-MLS approval, brokerage credentials, RESO membership) — never promise IDX before a market is approved. Support agent-provided credentials and a market-by-market rollout.
- **Use of metadata:** auto-populate player overlays (address/price/beds/baths), auto-title, and pre-fill social OG text; optional auto-import of listing photos for a gallery section.

---

# PART 13 — ANALYTICS, DASHBOARDS & AGENT REPORTING

- **Agent-facing (per listing):** views, unique viewers, **average minutes watched**, **scroll-depth (% of home seen)**, per-room dwell, lead count/conversion, traffic source (IG/portal/QR/link), device split, geography. A shareable "your listing performance" card the agent can screenshot for the seller ("your home got 3,200 views").
- **Seller-facing report:** a clean weekly email/PDF the agent forwards to the homeowner (great retention/referral driver).
- **Internal ops:** render throughput, queue depth, step latencies, failure rates by step, reshoot rate, **realized margin per render** (job cost + accrued delivery vs price), cohort retention, credit burn.
- **Pipeline:** event ingest → warehouse (BigQuery/ClickHouse) → dashboards (Metabase/internal). Privacy-respecting; no PII in analytics stores.

---

# PART 14 — ADMIN, INTERNAL TOOLING & OPS CONSOLE

- **Job monitor:** live board of render jobs (state, step, elapsed, cost, GPU); requeue/cancel/retry; view logs + input/preview; dead-letter triage.
- **Cost/margin dashboard (FinOps):** per-render and aggregate compute + generative + delivery cost vs revenue; margin by tier and by video length; alerts when a render or a viral link crosses a cost ceiling.
- **Moderation:** content review queue (flag inappropriate/illegal captures), takedown tooling, DMCA handling.
- **Support:** user lookup, listing/render history, credit adjustments, refunds, impersonate-for-support (audited), resend receipts.
- **Config:** feature flags, pricing/caps, capture params, provider routing, kill-switches.

---

# PART 15 — SECURITY, PRIVACY, COMPLIANCE & MODERATION

- **AuthN/Z:** short-lived JWT + refresh in Keychain; org-scoped RBAC on every endpoint; signed upload + playback URLs.
- **Encryption:** TLS everywhere; encryption at rest (R2/Postgres); secrets in a manager (not in code); rotate keys.
- **PII minimization:** store only what's needed; separate PII; no PII in logs/analytics; field-level encryption for lead contact data.
- **Privacy law:** **GDPR/CCPA** data-subject requests (export + hard delete across Stream/R2/DB/analytics), consent for lead capture, cookie/consent on the web player, DPA with subprocessors (Cloudflare/Modal/Stripe).
- **App Store privacy:** accurate nutrition labels, permission-purpose strings (camera/mic/photos/motion/notifications), ATT only if tracking, Sign in with Apple.
- **Content moderation & abuse:** guard against illegal/inappropriate content; report/takedown flow; watermark provenance; block known-abusive accounts; rate-limit renders per account to deter cost-abuse.
- **Property/consent:** in-app reminder that the user must have the right to record and publish the space; ToS/EULA + acceptable-use.
- **Resilience:** WAF/rate limiting at the edge; DDoS protection (Cloudflare); backups + tested restore; incident runbook.

---

# PART 16 — INFRASTRUCTURE, DEVOPS, OBSERVABILITY & SLOs

- **Environments:** dev / staging / prod, isolated data + secrets; ephemeral preview envs for PRs where feasible.
- **IaC:** Terraform/Pulumi for cloud + Cloudflare (R2/Stream/WAF/DNS); Modal/RunPod configs in code; reproducible.
- **CI/CD:** lint/type/test on PR; build + deploy backend (containers) on merge; **EAS/Xcode Cloud** for iOS builds + TestFlight; OTA config where possible; DB migrations gated + reversible.
- **Observability:** structured logs (correlation ids across app→api→queue→worker→stream), metrics (queue depth, step latency, error rates, cost), distributed tracing, dashboards + alerting (PagerDuty/Opsgenie). Per-job trace so any render is fully reconstructable.
- **SLOs:** API p99 latency; render success rate (e.g. ≥ 98% of valid inputs render without manual intervention); **time-to-ready** target (e.g. p50 < 8 min, p90 < 20 min for a 3-min source — tune with data); player start-time p90 < 2s on 4G; upload success ≥ 99%.
- **DR/backup:** Postgres PITR; R2 versioning on masters; runbooks for GPU-provider outage (failover Modal↔RunPod↔fal), Stream outage (failover host), and queue backlog.
- **Cost controls:** budget alerts per subsystem; autoscale to zero on idle; per-job cost ceilings; egress dashboards.

---

# PART 17 — TESTING STRATEGY (incl. real-device & render QC)

- **Unit/integration:** services, ledger math (money!), state-machine transitions, provider adapters (mocked), signing/expiry.
- **iOS:** unit + snapshot tests; **real-device matrix** (SE, 12, 14/15, Pro Max; iOS 16/17/18); capture soak test (100 recordings, interruptions, low storage/battery/thermal); upload chaos (kill app, drop network, reboot mid-upload).
- **Player QA — the critical surface:** automated + manual across **iOS Safari, Chrome iOS, and in-app webviews (Instagram, TikTok, Facebook, Snapchat, iMessage preview)**; low-memory devices; Low Power Mode; slow-3G/4G throttling; long (8-min) and short (45s) flythroughs; verify smooth scrub, no OOM, fast start, correct fallbacks.
- **Render QC:** golden-input fixtures (handheld shaky, drone-smooth, dark, fast-motion, huge/long) with expected-quality assertions; automated blur/shake/exposure scoring on outputs; visual-diff spot checks; cost-per-step regression (alert if a step's cost drifts).
- **Load:** simulate viral link (tens of thousands of concurrent viewers) → verify CDN, signing, metering, and caps hold; queue load (hundreds of concurrent renders) → verify autoscale + priority.
- **Security:** dependency scanning, SAST/DAST, pen test before GA, receipt-validation abuse tests.

---

# PART 18 — NOTIFICATIONS (APNs, EMAIL, SMS)

- **APNs push:** render-ready, lead-received, hosting-expiring (with 1-tap renew), purchase receipt, weekly performance. Contextual permission ask (after first render).
- **Transactional email:** welcome, receipt/invoice, render-ready with link, lead alert, hosting-expiring, weekly seller/agent report. (Reuse a provider like Resend/Postmark; verified domain; no spammy design.)
- **SMS:** lead alerts (agents want instant SMS), OTP, optional render-ready. (Twilio/GHL.)
- **Preferences:** per-channel, per-type opt in/out; quiet hours; unsubscribe compliance.

---

# PART 19 — ONBOARDING, ACTIVATION & RETENTION

- **First-run:** Sign in with Apple → "shoot your first walkthrough" guided flow with a 60-second tutorial video and a sample flythrough to feel the magic. Offer **one free or discounted first render** to cross the activation threshold (the "aha" is seeing their own home fly).
- **Activation metric:** first published flythrough shared. Instrument the funnel: install → account → capture started → capture completed → uploaded → render ready → shared → first lead.
- **Retention:** push weekly performance ("your listing got X views, Y leads"); new-listing reminders; seasonal campaigns; referral credits; team seat expansion; hosting renewals as recurring touchpoints.
- **Education:** "How to shoot a perfect walkthrough" course; best-practices per property type (condo vs estate vs complex — long-video guidance); example gallery.

---

# PART 20 — PRICING & UNIT ECONOMICS (DURATION-AWARE)

> **Correction baked in (per the founder's note):** flythroughs are NOT uniformly short. A studio condo ≈ 45–90s; a large home 2–4 min; a **luxury estate or apartment/condo complex 5–10+ min.** Both **render compute** and **streaming delivery** scale with length, so ROAM **must price by output duration and cap by streamed minutes** — a flat "$29 for any length" model loses money on long, popular, big-property flythroughs. Below is the corrected, duration-aware model.

## 20.1 The two length-driven cost drivers
1. **Render compute** (stabilize/interpolate/upscale) is per-frame → roughly **linear in source minutes**. A 6-min source ≈ 4× the GPU time of a 90s source.
2. **Delivery** = **streamed minutes × rate**. On Cloudflare Stream (~$0.001/min delivered, resolution-agnostic), cost = Σ(minutes each viewer watches). Longer videos + engaged viewers + viral reach = the dominant, duration-driven cost.

## 20.2 Realistic watch-time assumptions (replacing the flawed flat 40s)
Average watch scales with length but **sub-linearly** (viewers of a 6-min estate don't all watch 6 min; but they watch far more than 40s). Model with a **completion factor** that declines with length:

| Output length | Assumed avg watch | Completion factor |
|---|---|---|
| 1 min (condo) | ~0.7 min | 70% |
| 3 min (home) | ~1.6 min | 53% |
| 6 min (estate) | ~2.6 min | 43% |
| 8 min (complex) | ~3.2 min | 40% |

(Scrub UX inflates engagement vs passive video — people scrub back and forth — so treat these as conservative-to-moderate; instrument real data and update.)

## 20.3 Per-render delivery cost at scale (Cloudflare Stream, $0.001/streamed-min)
`delivery = views × avgWatchMin × $0.001`

| Output | avg watch | 2,000 views | 10,000 views | 50,000 views (viral) |
|---|---|---|---|---|
| 1 min | 0.7 | $1.40 | $7.00 | $35 |
| 3 min | 1.6 | $3.20 | $16.00 | $80 |
| 6 min | 2.6 | $5.20 | $26.00 | $130 |
| 8 min | 3.2 | $6.40 | $32.00 | $160 |

**Takeaway:** at 10k views a 6–8 min flythrough already costs **$26–$32 to deliver** — more than a flat $29 render's whole price. **Pricing and caps MUST be minute-based.**

## 20.4 The corrected pricing model — price by output minutes + included streamed-minute caps
Charge a **base render fee by length band**, and **include a streamed-minute allowance** sized to the length; overage draws credits, prompts an upgrade, or auto-degrades to 720p.

| Length band | Smooth (1080p) | 4K Premium | Cinematic AI | Included streamed-minutes | Overage |
|---|---|---|---|---|---|
| **≤ 90s** (condo) | **$29** | $49 | $99 | 8,000 min | $0.002/min |
| **90s–3 min** (home) | **$49** | $79 | $149 | 20,000 min | $0.002/min |
| **3–6 min** (estate) | **$79** | $119 | $199 | 40,000 min | $0.002/min |
| **6–10 min** (complex) | **$119** | $169 | $279 | 70,000 min | $0.002/min |

Notes: overage priced at 2× your Stream cost (healthy margin); when a listing exceeds its included minutes, notify the agent and offer a "Boost" (more minutes) or a hosting plan; optionally auto-drop to 720p past the cap to protect margin. Render compute even at the long end is a few dollars (deterministic; generative capped), so the length-based price easily covers compute + a generous delivery allowance.

## 20.5 Worked margins (Smooth tier, Cloudflare Stream, R2 zero-egress, Stripe/IAP fee ~$1–$1.50)
Compute for long renders ≈ $0.20–$0.80 (deterministic, GPU-min linear); storage negligible.

| Scenario | Price | Compute | Delivery (10k views) | Fee | COGS | **Margin** |
|---|---|---|---|---|---|---|
| 90s condo, 10k views | $29 | $0.25 | $7.00 | $1.15 | $8.40 | **$20.60 (71%)** |
| 3-min home, 10k views | $49 | $0.45 | $16.00 | $1.72 | $18.17 | **$30.83 (63%)** |
| 6-min estate, 10k views | $79 | $0.70 | $26.00 | $2.59 | $29.29 | **$49.71 (63%)** |
| 8-min complex, 10k views | $119 | $0.90 | $32.00 | $3.75 | $36.65 | **$82.35 (69%)** |

4K Premium improves margin further (Stream bills 4K = 1080p). Cinematic AI adds ~$2–$8 generative but prices +$50–$160, so margin holds ~80%+.

## 20.6 Recurring & team
- **Hosting: $5/mo per active listing** past the included window (~84% margin at typical ongoing view volume; overage minute-metered). The compounding annuity.
- **Team: $199/mo** incl. a **minute pool** (e.g. 60 output-minutes of renders/mo) + N hosted listings + priority queue; overage renders billed by length band at a discount. Model to ~75% margin.
- **Enterprise/brokerage:** volume minute pools, white-label, SSO.

## 20.7 The three margin guardrails (now minute-aware)
1. **Included streamed-minute caps per render** (sized by length) + metered overage; auto-prompt upgrade or auto-degrade to 720p past the cap. This converts the viral-long-video blowout into revenue or a capped cost.
2. **Time-boxed hosting → $5/mo upsell.** Hard TTL caps egress exposure and drives recurring conversion.
3. **Cap generative spend per render (~$5 ceiling) + cache/reuse hero/transition clips; gate regenerations.**

## 20.8 Break-even (why host choice + caps are existential)
On **Cloudflare Stream**, even a 6-min estate priced at $79 stays positive to **~40k+ streamed-minute-equivalents** before the cap engages. On **Mux** ($0.15/GB), the same long-4K video underwater by a few thousand views — **do not run long/4K/entry tiers on Mux.** Host choice + minute caps move break-even by an order of magnitude.

---

# PART 21 — ROADMAP: PHASED MILESTONES WITH ACCEPTANCE CRITERIA

**Phase 0 — Foundations (infra + skeleton).** Repos, IaC, envs, auth, DB schema, R2, Cloudflare Stream account, CI/CD, TestFlight pipeline. *Accept:* a signed-in iOS build can create a listing and upload a test file to R2; a stub render publishes a hosted test video that plays via Stream.

**Phase 1 — MVP (the wedge).** Native capture + guided overlays (level/pace) + room tagging; resumable background upload; pipeline v1 (**stabilize → interpolate 60fps → grade → dense-keyframe encode → HLS**, NO generative); mobile-perfect scroll-scrub share player (Path A) with room labels + lead form; Apple IAP render credits ($29 band + duration bands); push on completion; basic dashboard. *Accept:* an agent records a real home and has a shareable, buttery flythrough link (opens perfectly in the Instagram webview) in minutes, paid via IAP; margins logged per render.

**Phase 2 — Premium + growth.** 4K tier; Cinematic AI tier (Seedance/Veo hero clips + transitions, capped); sprite/VTT scrub previews; 9:16 social teaser export; analytics (views/scroll-depth/leads); GHL/CRM lead routing; referral; hosting subscription + minute caps/metering; team accounts. *Accept:* 4K + Cinematic renders ship within cost ceilings; agents can post a Reel teaser + link and see performance + leads; hosting recurring live.

**Phase 3 — Scale + moat.** MLS/RESO per-market metadata; auto room-detection/labeling (vision); interactive hotspots; exterior drone-reveal synthesis from a photo; white-label for brokerages; portal API; vertical expansion (restaurants/gyms/hotels/retail/Airbnb); ops/FinOps dashboards hardened; multi-provider render failover. *Accept:* first brokerage white-label live; a non-RE vertical pilot renders; SLOs met at 10× volume.

---

# PART 22 — RISK REGISTER & MITIGATIONS

| Risk | Mitigation |
|---|---|
| Generative cost/incoherence | Deterministic backbone for full length; generative only 8–15s i2v hero clips seeded from real frames; per-render gen cost ceiling + QC/regention caps. |
| **Long-video / viral egress blowout** | Duration-based pricing + **included streamed-minute caps** + overage/auto-degrade; Cloudflare Stream (per-minute, 4K=1080p) + R2 zero-egress; hosting TTL. |
| Shaky/dark/fast input | Guided capture (level/pace/light) + pre-render QC with reshoot prompts + Gyroflow/vidstab. |
| Mobile scrub jank / OOM in IG webview | Low-res all-intra proxy (not canvas) for long/4K; memory budget; fallback ladder; the in-app webview is the #1 test target. |
| Apple IAP rejection | IAP-first billing (StoreKit 2), no web-checkout CTAs in-app, server receipt validation, restore purchases. |
| GPU/stream provider outage | Provider abstraction + failover (Modal↔RunPod↔fal; Stream↔alt host); queue durability. |
| MLS gating overpromise | Manual/URL metadata MVP; RESO per-market later; honest in-app copy. |
| Splatting competitors | Win on *format* (produced cinematic scroll vs free-roam scene), share-link growth loop, verticals, CRM integrations. |
| Cost creep / thin margins | Per-step cost logging + FinOps dashboard + budget alerts + cost ceilings per job; price by length band. |
| Content/legal (recording rights) | In-app consent reminder, AUP/EULA, moderation + takedown, provenance watermark. |

---

# PART 23 — TEAM, ROLES & DELIVERY PLAN

- **iOS engineer(s)** — Swift/SwiftUI, AVFoundation/CoreMotion, background URLSession, StoreKit 2.
- **Backend engineer(s)** — API, queue/orchestration, billing/ledger, integrations.
- **Media/ML engineer** — render pipeline (ffmpeg, Gyroflow, RIFE/Topaz), GPU workers (Modal), generative provider integration, QC scoring.
- **Web/frontend engineer** — the mobile-perfect scrub player + embed + dashboard + marketing site.
- **Design** — capture UX + player + brand; motion.
- **DevOps/SRE (part-time early)** — IaC, observability, SLOs, on-call.
- **Founder/PM** — GTM (agent wedge), pricing, brokerage partnerships, content.
Suggested build order mirrors Part 21; keep a tight MVP crew, expand at Phase 2. Instrument cost/margin from the first render.

---

# PART 24 — APPENDICES

## Appendix A — Proven encode recipes (starting point)
- **Base:** H.264 `-profile:v high -pix_fmt yuv420p`; **dense keyframes** `-g 12 -keyint_min 12 -sc_threshold 0`; `-movflags +faststart`.
- **Scrub proxy (instant seek):** 540–720p, all-intra or very short GOP (`-g 1..5`), CRF ~26–30, no audio, faststart — small + memory-safe for mobile/in-app webviews.
- **Playback renditions:** 1080p + 4K; **AV1 preferred** (svt-av1) with **H.264/HEVC fallback**; ABR ladder for HLS.
- **Grade/denoise:** `hqdn3d`, `eq=brightness=:contrast=:saturation=:gamma=`.
- **Two-pass or CRF** targeting per rendition; then package to HLS via Cloudflare Stream (or Mux for MVP). Emit **sprite atlas + WebVTT** + poster + branded OG image.
- **Stabilize (no gyro):** `ffmpeg -i in.mp4 -vf vidstabdetect=shakiness=8:accuracy=15 -f null -` then `-vf vidstabtransform=smoothing=30:input=transforms.trf,unsharp=5:5:0.8`.
- **Interpolate to 60fps:** RIFE/FILM (self-host on GPU) or Topaz Video AI for problem footage.

## Appendix B — Capture guidance defaults (bake into the iOS app)
Walk slow and steady · phone at chest height, horizon level (gravity-vector level indicator) · one continuous take · sweep doorways slowly · good light (blinds open, lights on; luminance check) · avoid fast turns/whip pans (interpolation smear) · portrait or landscape — pick once and keep it · log gyro/IMU sidecar · enable cinematic/Action stabilization · end on the best exterior/backyard for a strong finish · target length by property (condo ~1 min, home 2–4 min, estate/complex 5–10 min) — the app suggests a target and a room checklist.

## Appendix C — Generative hero-clip prompt templates (Cinematic AI tier; short, i2v-seeded)
- **Aerial opener (i2v from a real exterior frame):** "Cinematic aerial drone push-in toward this exact home, golden-hour warm light, smooth gentle gimbal motion, photoreal, no morphing of the structure." 8–10s, seed = real exterior frame.
- **Doorway transition (i2v):** "Slow cinematic dolly through this doorway into the next room, steady glide, consistent architecture, photoreal." 6–8s, seed = frame at the doorway.
- **Reveal (i2v):** "Slow reveal rising over the backyard/pool at dusk, calm, cinematic, keep geometry identical." 8–10s.
- Rules: always image-to-video seeded from a REAL frame; QC each clip for structural drift; auto-regen up to the cost cap; if it morphs the property, DROP it and keep the deterministic cut. Never full-length generative.

## Appendix D — iOS capabilities / entitlements / permission strings (checklist)
- Capabilities: Sign in with Apple; Push Notifications (APNs); Background Modes (background fetch/processing, background URLSession); Associated Domains (Universal Links); In-App Purchase.
- Info.plist purpose strings: `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `NSPhotoLibraryUsageDescription`/`NSPhotoLibraryAddUsageDescription`, `NSMotionUsageDescription`, `NSUserTrackingUsageDescription` (only if ATT used), notifications.
- StoreKit 2 products: consumable render/minute credits; auto-renewable hosting & team subs. Server-side receipt validation + App Store Server Notifications v2.
- Privacy nutrition labels accurate; data-deletion path; account deletion in-app (App Store requirement).

## Appendix E — Glossary
- **Flythrough:** the produced scroll-through cinematic video output.
- **Scrub proxy:** low-res dense-keyframe rendition bound to scroll for instant seeking.
- **Playback rendition:** high-bitrate 1080p/4K (AV1) for fullscreen play.
- **Streamed minutes:** Σ minutes actually watched across all views — the core delivery-cost + billing unit.
- **Completion factor:** avg watch ÷ output length; declines with length.
- **Deterministic backbone:** stabilize + interpolate + grade + encode (no generative) — the always-on core.
- **Cinematic AI tier:** premium tier adding short generative hero clips.
- **Included minute cap:** streamed-minute allowance bundled with a render/tier.
- **Hosting TTL:** included live window before a render expires or converts to $5/mo hosting.

---

---

# PART 25 — DETAILED USER & DATA FLOWS (SEQUENCE DIAGRAMS)

These are the canonical end-to-end flows. Implement exactly these state transitions and side effects; every arrow is idempotent and observable (correlation-id threaded from app → API → queue → worker → stream).

## 25.1 Capture → Upload → Render → Publish
```
Agent (iOS)            API / Services         Queue/Orchestrator      GPU Workers         Stream/R2
  |  create listing ----->| listings.create    |                       |                   |
  |  record + gyro sidecar|                     |                       |                   |
  |  request upload  ----->| uploads.session -->| (signed R2 URL)       |                   |
  |  chunked tus upload -------------------------------------------------------------------> R2 (raw)
  |  upload complete ----->| uploads.complete   | verify sha256         |                   |
  |                        | capture_assets.new |                       |                   |
  |  submit render  ------>| renders.create     | debit credits (hold)  |                   |
  |                        |                    | enqueue job(created)  |                   |
  |                        |                    |--- validating ------->| QC probe          |
  |                        |                    |   (needs_reshoot?)     |                   |
  |                        |                    |--- ingest/stabilize ->| Gyroflow/vidstab  |
  |                        |                    |--- interpolate ------>| RIFE 60fps        |
  |                        |                    |--- grade/upscale ---->| grade/Topaz(4K)   |
  |                        |                    |--- (hero gen) -------->| Seedance/Veo      |
  |                        |                    |--- stitch/encode ---->| ffmpeg multi-rend |
  |                        |                    |--- package ---------->| HLS+sprite+poster |
  |                        |                    |--- publish ------------------------------> Stream/R2 (renditions)
  |                        | renders.publish    | settle credits(final) |                   |
  |  <-- APNs render.ready-| notify             |                       |                   |
  |  share link/embed ---->| sharing.create     |                       |                   |
```
Failure handling: any step failure → checkpoint + retry that step (backoff); after N attempts → dead-letter + ops alert + refund/hold-release; `needs_reshoot` → notify agent with specific guidance and do NOT consume the full credit (only the cheap QC cost).

## 25.2 Viewer → Flythrough → Lead
```
Viewer (phone webview)      CDN/Stream            API                CRM/Agent
  | GET /f/:slug ---------->| share page (SSR)     |                  |
  | load poster + proxy --->| HLS scrub proxy      |                  |
  | scroll-scrub  --------->| byte-range seeks     |                  |
  | (beacon) view+minutes ------------------------>| metering.ingest  |
  | submit lead ----------------------------------->| leads.create --->| webhook (GHL) + SMS/push to agent
  | <-- confirmation -------|                       |                  |
```
Metering ingests **streamed minutes** for billing/caps; if a listing crosses its included cap → notify + offer Boost/hosting + optional auto-degrade to 720p.

## 25.3 Purchase → Credits → Consumption
```
iOS StoreKit2  --purchase-->  Apple  --receipt-->  billing.validate  --> credit_ledger (+)
web Stripe     --checkout-->  Stripe --webhook-->  billing.stripe    --> credit_ledger (+)
render submit  --------------------------------->  billing.debit     --> credit_ledger (-)  (hold→settle on publish)
```
Idempotency on `apple_txn_id`/`stripe_pi`; server ledger authoritative; app shows cached balance.

---

# PART 26 — CAPTURE QUALITY SCORING & RESHOOT LOGIC

Protects output quality AND GPU spend. Runs partly on-device (instant nudges) and partly server-side in the `validating` step.

**Signals & scoring (0–100 composite):**
- **Shake:** motion variance from gyro sidecar / optical flow; penalize high-frequency jitter and whip pans.
- **Pace:** mean translational speed; penalize too-fast (interpolation smear) and erratic speed changes.
- **Exposure/light:** mean luminance + clipping %; penalize under/over-exposure and heavy per-room swings.
- **Focus/blur:** Laplacian variance on sampled frames; penalize soft/blurry stretches.
- **Coverage/continuity:** dropped frames, cuts, orientation flips; penalize discontinuities.
- **Duration sanity:** within band for the property type.

**Decision:**
- Score ≥ threshold → proceed to full render.
- Score in warn band → proceed but flag "quality notes" to the agent and apply stronger stabilization/denoise.
- Score < threshold → **`needs_reshoot`** with **timestamped, specific guidance** ("0:45 too shaky — slow down," "kitchen underexposed — add light"), consuming only the cheap QC cost, not the full render credit.

On-device, surface the top failing signal LIVE during capture (e.g., "slow down," "hold level," "too dark") so most reshoots never happen.

---

# PART 27 — PLAYER IMPLEMENTATION DEEP-DIVE (PSEUDOCODE)

```js
// Mobile-perfect scroll-scrub core (Path A: video-scrub).
const track = document.querySelector('#track');      // tall, height ∝ duration
const video = document.querySelector('#scrub');       // sticky 100svh, muted, playsinline, preload=auto
let curT = 0, lastSet = -1, started = false;

function tick() {
  const total = track.offsetHeight - window.innerHeight;
  const p = clamp(-track.getBoundingClientRect().top / total, 0, 1);
  const target = p * (video.duration - 0.05);
  curT += (target - curT) * 0.1;                       // lerp → butter
  if (Math.abs(video.currentTime - curT) > 0.02 && Math.abs(curT - lastSet) > 0.02) {
    try { video.currentTime = curT; lastSet = curT; } catch {}
  }
  updateOverlays(p);                                   // opacity = 1 - |p - anchor|/window ; transforms only
  requestAnimationFrame(tick);
}

function begin() {                                     // gate on buffer
  if (started) return; started = true; requestAnimationFrame(tick);
}
video.addEventListener('progress', () => {
  const end = video.buffered.length ? video.buffered.end(video.buffered.length-1) : 0;
  reportBuffer(end / video.duration);
  if (end >= video.duration * 0.96) begin();
});
video.addEventListener('canplaythrough', () => setTimeout(begin, 1200)); // fallback
video.muted = true; video.playsInline = true; video.load();

// Resilience:
// - visualViewport 'resize' → recompute total (iOS toolbar show/hide, 100svh/100dvh).
// - if frame budget blown (long tasks) → drop to autoplay-loop fallback with same overlays.
// - swap to high-bitrate playback rendition on tap/fullscreen; keep proxy for scrub.
// - passive scroll listeners; never read layout inside tick; only transform/opacity writes.
```
For **Path B (canvas, short only):** preload capped `ImageBitmap` frames, `ctx.drawImage(frames[idx], ...)` where `idx = round(p*(N-1))`; release bitmaps on unmount; never exceed the mobile frame/memory cap.

---

# PART 28 — RENDER PIPELINE STEP REFERENCE (I/O · FAILURE · RETRY)

| Step | Input | Output | Typical engine | Failure modes | Retry/mitigation |
|---|---|---|---|---|---|
| validate/QC | raw asset + gyro | quality score, probe | ffprobe + heuristics | corrupt/unsupported | reject → needs_reshoot; cheap |
| ingest | raw | normalized intra intermediate | ffmpeg | codec/rotation edge | transcode variants; retry |
| stabilize | intermediate (+gyro) | stabilized | Gyroflow / vidstab | no gyro / extreme shake | vidstab fallback; stronger smoothing |
| interpolate | stabilized | 60fps glide | RIFE/FILM/Topaz | artifacts on fast motion | Topaz for problem clips; reduce factor |
| grade | 60fps | graded | ffmpeg eq/hqdn3d + LUT | color cast | brand LUT / auto-grade retune |
| upscale | graded | 4K (premium) | Topaz/self-host | VRAM/time | tile; smaller batch; retry |
| segment | graded + chapters | room segments | logic | bad timestamps | default single segment |
| hero gen | seed frames | 8–15s clips | Seedance/Veo/Kling | structural drift/cost | QC + regen (capped) → drop to deterministic |
| stitch | backbone + heroes | assembled | ffmpeg | join artifacts | crossfade; re-encode segment |
| encode | assembled | proxy + renditions | ffmpeg (svt-av1/x264) | encode fail | fallback codec; retry |
| package | renditions | HLS + sprite + VTT + poster | Stream/ffmpeg | packaging fail | re-package; alt host |
| publish | packaged | playback ids, record | Stream/R2 API | provider outage | failover host; retry; alert |

Every step emits `render_step_costs`; the orchestrator enforces a **per-job cost ceiling** that pauses + alerts if exceeded (guards against a runaway generative or upscale).

---

# PART 29 — API CONVENTIONS & EVENT TAXONOMY

**Conventions:** versioned (`/v1`), JSON, cursor pagination (`?cursor=&limit=`), `Idempotency-Key` header on all POSTs that create/charge, RFC-7807 problem+json errors (`type/title/status/detail/instance`), consistent error codes (`invalid_input`, `insufficient_credits`, `not_found`, `rate_limited`, `payment_required`, `conflict`), per-org + per-IP **rate limits** at the edge, HMAC-signed webhooks with retry + replay protection, correlation-id echoed in every response.

**Event taxonomy (bus + analytics):**
`user.signed_up` · `listing.created` · `capture.started` · `capture.completed` · `upload.started/progress/completed/failed` · `render.created/step_started/step_completed/needs_reshoot/failed/ready/canceled` · `render.cost_recorded` · `share.created` · `share.viewed` · `share.minutes_metered` · `lead.created` · `lead.routed` · `purchase.completed/refunded` · `credit.debited/credited` · `hosting.expiring/expired/renewed` · `cost.ceiling_exceeded` · `moderation.flagged`. Each event carries correlation-id, org/user, and cost fields where relevant.

---

# PART 30 — EDGE CASES CATALOG (design for these explicitly)

- Upload interrupted by call/reboot/network loss → resume from offset; never lose footage.
- Out of storage mid-capture → pre-flight check + finalize partial safely.
- Thermal throttle during 4K/60 capture → auto-drop to 4K/30 or 1080p with a toast; never crash.
- Extremely long (12+ min) source → warn, suggest split, cap; ensure proxy + memory strategy holds.
- Portrait vs landscape mixed / orientation flip mid-take → detect + normalize or reshoot prompt.
- Drone clip already 4K/smooth → skip stabilize/interpolate; straight to grade/encode.
- Very dark / night / mixed light → grade + denoise; reshoot if below threshold.
- Generative hero drifts off-model → drop it, keep deterministic cut (never ship a morphing house).
- Viral link (100k+ views) on a long 4K flythrough → minute caps + auto-degrade + hosting upsell; margin protected.
- In-app browser (IG/TikTok) low memory → proxy-only + autoplay-loop fallback; no OOM.
- Low Power Mode throttles decode → detect jank → fallback ladder.
- Payment edge: duplicate receipt, refund, chargeback, failed renewal → idempotent ledger + dunning + reversal.
- Account deletion / GDPR erasure → purge across Stream + R2 + DB + analytics; audit.
- Offline capture then submit later → queue + sync; clear states.
- Multiple agents in one org sharing a credit pool → server-authoritative ledger + concurrency-safe debits.

---

# PART 31 — NON-REAL-ESTATE VERTICALS & EXPANSION

The capability is horizontal; real estate is the wedge. Same pipeline + player, different templates/metadata/CTAs:
- **Restaurants / bars / cafés:** "walk through the vibe" for reservations/Google/IG; CTA = reserve/menu.
- **Gyms / studios:** tour the floor; CTA = free trial/sign up.
- **Hotels / short-term rentals / Airbnb:** room + amenity flythrough; CTA = book.
- **Apartment complexes / student housing / senior living:** unit + amenity tours (long-video use case); CTA = tour/apply.
- **Venues / event spaces / wedding:** sell the space; CTA = inquire.
- **Retail / showrooms / auto dealers:** browse the space; CTA = visit/shop.
- **Construction / real-estate development:** progress flythroughs over time.
Productize as vertical "kits" (capture guidance, overlay templates, CTAs, pricing) once RE is winning. The share-link growth loop works identically in every vertical.

---

# PART 32 — GO-TO-MARKET & GROWTH PLAYBOOK

- **Wedge:** solo/independent agents and small teams priced out of Matterport/drones (the ~78% no-tour gap). Lead with "just your phone, no camera, no subscription."
- **Proof loop:** every published flythrough carries "Made with ROAM" → viewers who are agents convert. Referral credits amplify.
- **Content:** short IG/TikTok demos of "walk your listing → get this" (the transformation is the ad); agent testimonials; "$20 vs $300 drone" comparison.
- **Distribution:** brokerage partnerships (seat/volume deals, white-label), real-estate coaches/influencers, listing-portal embeds, open-house QR kits.
- **Land & expand:** free/discounted first render → per-render habit → hosting subscription → team plan → brokerage white-label.
- **Retention:** weekly performance pushes, seller-facing reports (agents look good to clients), new-listing reminders, seasonal pushes.
- **Pricing psychology:** anchor against $300 drone / $8k camera; duration bands feel fair ("bigger home, bit more"); hosting is a small recurring "keep it live."

---

# PART 33 — EXPANDED APPENDICES

## Appendix F — Additional ffmpeg building blocks
- **Sprite/VTT (self-hosted):** extract 1 frame/N sec → tile into a sprite atlas → generate WebVTT with `#xywh=` regions mapping timecodes to tiles (for scrub hover thumbnails when not on Mux).
- **9:16 social teaser:** `crop`/`scale` to 1080×1920, pick 12–20s of the best glide, add subtle zoom + "link in bio" end card; export H.264 for Reels/TikTok.
- **Poster/OG image:** pick a strong exterior/great-room frame; overlay branded card (address/price/agent) for the social unfurl.
- **HDR handling:** tone-map HDR captures to SDR Rec.709 for consistent grading (`zscale`/`tonemap`), or maintain an HDR rendition where supported.

## Appendix G — Provider abstraction interfaces (illustrative)
```ts
interface RenderStep { name: string; run(input: Asset, cfg): Promise<{output: Asset; cost: Cost}> }
interface GenerativeVideoProvider {
  id: 'seedance'|'veo'|'kling'|'runway';
  i2v(seedFrame: Image, prompt: string, seconds: number, res: '1080p'|'4k'): Promise<{clip: Video; cost: Cost}>;
  qualityScore(clip: Video, seedFrame: Image): number;   // structural-consistency check
}
interface StreamHost { publish(renditions): Promise<{playbackIds; scrubId; spriteKey; vttKey}>; signUrl(id, ttl): string }
```
Route generative to cheapest provider meeting a quality-score threshold; log cost per call; enforce per-job gen budget.

## Appendix H — KPIs to instrument from day one
Activation rate (install→first shared flythrough), reshoot rate, render success rate, p50/p90 time-to-ready, avg output length by property type, avg streamed-minutes/view, views/lead, lead→showing rate, **realized margin per render** (by tier & length), hosting attach rate, referral coefficient, in-app-browser player error rate.

---

---

# PART 34 — iOS SCREEN-BY-SCREEN SPEC (DETAILED)

Every screen must be one-thumb reachable, Dynamic-Type + VoiceOver ready, dark-mode correct, and correct on SE → Pro Max. States: loading / empty / error / offline for each.

1. **Splash / cold start** — brand mark; silent auth-token check via Keychain; route to Home or Onboarding in < 1.5s.
2. **Onboarding** — 3 value cards ("No camera. No rig. Just your phone." / "AI renders your walkthrough into a drone flythrough." / "Share a link that converts."), 60s tutorial video, Sign in with Apple (primary) + email/phone OTP. First-render incentive banner.
3. **Home / My Listings** — list of listings with status chips (Draft / Uploading / Processing / Ready / Expired), thumbnail poster, quick actions (share, view, re-render). Search + filter (status, date, address). Prominent "＋ New Listing" FAB. Empty state = "Shoot your first walkthrough."
4. **New Listing** — address autocomplete (MapKit), beds/baths/sqft/price, or "Import from listing URL" / "Import from MLS" (V2). Choose "Record now" or "Upload existing / drone clip."
5. **Capture** — full-screen camera; guidance overlays (level bubble, pace ring + haptics, light warning, framing grid); floating room-tag buttons; big record button; timer + remaining-storage; thermal/battery warnings; interruption-safe. Post-stop → Review.
6. **Import** — PHPicker/Files; validation feedback; "this is a drone shot" toggle; trim (optional).
7. **Room Tagging (post)** — scrubber timeline with chapter pins; add/rename/reorder rooms; preview.
8. **Review & Submit** — preview thumbnail; **length band + price shown clearly** (duration-aware); tier selector (Smooth / 4K / Cinematic AI) with plain-language differences + price deltas; credit balance; "Submit render" → IAP if insufficient credits. Confirm estimated ready-time.
9. **Render Status** — progress with step labels ("Stabilizing… Interpolating… Encoding…"), estimated time, cancel; on ready → celebratory state + share.
10. **Flythrough Detail** — embedded preview (WKWebView player), Share, Copy link, QR, Embed, Analytics (views/minutes/leads/scroll-depth), Re-render, Hosting status + renew, 9:16 teaser export.
11. **Share Sheet** — native share + IG/TikTok/FB/iMessage, QR, embed code, "download teaser."
12. **Leads Inbox** — per-listing leads; contact (call/text/email one-tap); status; CRM-sync indicator; export.
13. **Billing / Credits** — balance, buy credit packs (IAP consumables), subscriptions (hosting/team), purchase history, restore purchases, invoices (web).
14. **Settings** — brand kit (logo/colors/agent card/default CTA), notification prefs (per channel/type + quiet hours), account (profile, org/team, sign out, **delete account**), legal (ToS/Privacy/AUP), support/help, "how to shoot" course.

**Global UI:** offline banner; upload progress mini-bar persistent across screens; toast system; haptics on key actions; skeleton loaders; pull-to-refresh; graceful error recovery everywhere.

---

# PART 35 — PIPELINE CONFIGURATION & PARAMETERS REFERENCE

Centralize these as remote config so they're tunable without redeploy:
- **Capture targets:** preferred `{4K/60, 4K/30, 1080p/60}` by device tier + thermal state; stabilization mode; gyro logging on/off; max duration by property type.
- **QC thresholds:** shake/pace/exposure/blur/continuity pass + warn cutoffs; reshoot policy.
- **Stabilize:** gyro-first vs vidstab; `smoothing`, `shakiness`, `accuracy`; horizon-lock.
- **Interpolate:** target fps (60), factor cap, engine (RIFE/FILM/Topaz) selection heuristic (by motion score).
- **Grade:** default LUT/auto-grade params; denoise strength; per-org brand LUT.
- **Upscale:** enable per tier; model; tile size; VRAM guardrails.
- **Generative:** enabled per tier; #hero clips; seconds each; provider routing + quality threshold; **per-job gen cost ceiling**; regen cap.
- **Encode:** proxy res/GOP/CRF; playback renditions + codecs (AV1/H.264/HEVC); ABR ladder; faststart.
- **Delivery:** host (Stream/Mux), signed-URL TTL, hosting TTL days, included streamed-minute caps by length band, overage rate, auto-degrade-to-720p toggle.
- **Cost ceilings:** per-job hard ceiling; alert thresholds; per-org daily render cap (abuse guard).

---

# PART 36 — WORKED COST EXAMPLES (END-TO-END, DURATION-AWARE)

**Example A — 90s condo, Smooth, 5,000 views.**
Compute ~$0.25 · delivery = 5,000 × 0.7 × $0.001 = $3.50 · fee ~$1.15 · COGS ≈ $4.90 → at **$29 price, margin ≈ $24.10 (83%).**

**Example B — 3-min home, 4K Premium, 20,000 views.**
Compute ~$0.55 (incl. 4K upscale self-hosted) · delivery = 20,000 × 1.6 × $0.001 = $32 (Stream 4K = 1080p rate) · fee ~$2.72 · COGS ≈ $35.3 → at **$79 price, margin ≈ $43.7 (55%)**; the included 20,000-min cap ≈ 12,500 full-watch-equivalents — past it, overage or auto-degrade protects margin.

**Example C — 7-min apartment complex, Cinematic AI, 30,000 views.**
Compute ~$0.90 + generative (3 hero clips) ~$5 · delivery = 30,000 × 3.0 × $0.001 = $90 · fee ~$8 → COGS ≈ $104 → at **$279 price, margin ≈ $175 (63%)**; but 30k × 3 min = 90,000 streamed-min exceeds the 70,000 included → overage 20,000 × $0.002 = **+$40 revenue** (or auto-degrade). This is exactly why long/big-property renders MUST be minute-capped and duration-priced — the flat model would have lost money here.

**Rule of thumb:** price = f(length band, tier); include a streamed-minute allowance ≈ (assumed avg-watch × ~12,500 views) for the band; meter + cap + overage beyond it. Deterministic compute stays a few dollars even at 8 min; generative is ceilinged; **delivery is the variable you must price and cap by minutes.**

---

# PART 37 — MOBILE-PERFECT ACCEPTANCE CHECKLIST (SHIP GATE)

Do not ship Phase 1 until ALL pass on real devices:
- [ ] Scroll-scrub is buttery (no visible stutter) on iPhone 12/13 SE-class in **iOS Safari AND the Instagram in-app browser** for a **6-minute** flythrough.
- [ ] Player first-interaction < 2s on throttled 4G; poster paints < 500ms; no OOM in IG/TikTok webview across 20 opens.
- [ ] Fallback ladder verified (4K→1080p→proxy→autoplay-loop→poster) under Low Power Mode + slow network.
- [ ] Capture overlays hold 60fps on iPhone 12+; no dropped recording across 100 interrupted captures; gyro sidecar logged + synced.
- [ ] Resumable upload survives app-kill + network-drop + reboot mid-upload and completes; cellular warning works.
- [ ] IAP purchase → credits → render debit → publish end-to-end; restore purchases; server receipt validation; no double-credit.
- [ ] Render of shaky handheld input looks drone-smooth (stabilize+interpolate) and matches golden-quality assertions.
- [ ] Duration-band pricing + streamed-minute cap + overage/auto-degrade all enforce correctly; per-render margin logged.
- [ ] Lead form submits → agent push + SMS + CRM webhook; OG unfurl looks premium in iMessage + IG DM.
- [ ] Account deletion + GDPR erasure purges Stream+R2+DB+analytics.
- [ ] SLO dashboards + cost/margin dashboard live; per-job cost ceiling + alerts working.

---

---

# PART 38 — NON-GOALS & ANTI-PATTERNS (what NOT to build)

- **Do NOT** attempt full-length generative video (cost + incoherence; the property must stay identical). Generative = short i2v hero clips only.
- **Do NOT** ship a single monolithic 4K MP4 for the player — always adaptive HLS + a low-res scrub proxy.
- **Do NOT** run the entry/long/4K tiers on Mux (margin death at viral scale); Cloudflare Stream + R2.
- **Do NOT** use canvas image-sequence scrubbing for long/4K flythroughs (mobile OOM) — proxy path only.
- **Do NOT** price flat per render regardless of length — price by duration band + streamed-minute caps.
- **Do NOT** put "buy cheaper on the web" CTAs inside the iOS app (App Store rejection). IAP-first.
- **Do NOT** promise MLS/IDX before a market is approved.
- **Do NOT** bake room labels into the video (keep them player overlays — crisp, editable, localizable).
- **Do NOT** block the player on full buffer, request audio autoplay, or trigger unexpected fullscreen on iOS.
- **Do NOT** store PII in logs/analytics or skip the GDPR/CCPA erasure path.

---

# PART 39 — TIER DEFINITIONS IN PLAIN AGENT LANGUAGE (for UI copy)

- **Smooth ($ by length):** "We turn your walkthrough into a silky drone-style glide in HD. Perfect for most listings."
- **4K Premium:** "Ultra-crisp 4K glide — the premium look for luxury and standout listings."
- **Cinematic AI:** "Adds a jaw-dropping AI aerial opener and cinematic transitions between rooms. The scroll-stopping version for social."
- **Hosting ($5/mo):** "Keep your flythrough live past the included window so your link never dies."
- **Team ($199/mo):** "For teams and brokerages — a monthly render pool, hosted listings, and priority processing."

---

# PART 40 — MARKETING COPY BANK (seed for app store + ads + share cards)

- "Walk it. Upload it. Fly through it."
- "The tour that watches like a film — not a videogame."
- "Just your phone. No $8,000 camera. No monthly subscription."
- "Your listing, as a drone flythrough — for the price of a lunch."
- "Scroll through the home before you ever book the showing."
- "$20 vs $300 for a drone. Same wow. Your phone."
- "Post it to your bio. Watch the leads roll in."
- "78% of listings have no tour. Be the agent who does."
- App Store subtitle: "Phone walkthrough → cinematic flythrough."

---

# PART 41 — DETAILED GENERATIVE PROMPT LIBRARY (Cinematic AI, i2v-seeded, capped)

All prompts are **image-to-video seeded from a real frame** and 8–15s; QC each for structural drift; auto-regen within budget; drop to deterministic if it morphs the property.
- **Golden-hour aerial opener:** "Cinematic aerial drone push toward THIS exact home at golden hour, warm sunset light, smooth gentle gimbal motion, ultra photoreal, do not alter the building's architecture or add/remove structures."
- **Front-approach reveal:** "Slow low aerial glide up the driveway to the front entrance of this home, steady cinematic motion, consistent geometry, photoreal."
- **Doorway push-through:** "Smooth dolly through this doorway into the next room, gentle glide, keep walls/furniture identical, photoreal, no warping."
- **Great-room orbit:** "Slow subtle orbit across this open living space, cinematic, stable, keep the room's layout identical."
- **Backyard/pool dusk reveal:** "Gentle aerial rise revealing the backyard and pool at dusk, calm cinematic mood, keep geometry identical."
- **Skyline/exterior outro:** "Slow pull-back aerial away from the home revealing the neighborhood at sunset, cinematic, photoreal."
Negative guidance (where supported): "no morphing, no extra windows/doors, no distorted furniture, no text, no people unless present in seed."

---

# PART 42 — DEFINITION OF DONE (WHOLE PRODUCT, PHASE 1)

A real estate agent installs ROAM, signs in with Apple, records a continuous walkthrough of a real home with live capture guidance, tags rooms, and submits a Smooth render priced by the home's length band via Apple IAP. Minutes later they get a push: their walkthrough is now a **buttery, drone-style scroll-through flythrough** hosted on a link that **plays flawlessly in the Instagram in-app browser on an iPhone.** They post it to their bio; prospects scroll through the home and submit a "Book a showing" lead that hits the agent's phone (SMS + push) and CRM (webhook). Every render logs its full cost so realized margin is visible, and streamed-minute caps + hosting TTL protect margin on long, popular, big-property flythroughs. **That is the wedge. Ship it, then layer 4K, Cinematic AI, analytics, CRM, MLS, verticals, and white-label.**

---

### FINAL DIRECTIVE TO THE BUILDER
Ship the **Phase 1 MVP** first: native iOS capture with guidance → resumable upload → deterministic pipeline (stabilize→interpolate→grade→dense-keyframe encode→HLS on Modal, stored on R2, delivered on Cloudflare Stream) → a **mobile-perfect scroll-scrub share player that is flawless in the Instagram in-app browser** → Apple-IAP duration-band pricing with streamed-minute caps → push on completion → per-render cost/margin logging. Prove that an agent can walk a house with their phone and have a shareable, buttery flythrough link in minutes for $29+. Then layer 4K, Cinematic AI, analytics, CRM, MLS, and the growth loop. **Mobile perfect, deterministic-first, cost-aware, honest.**

<!-- END OF ROAM MASTER BUILD PROMPT -->

