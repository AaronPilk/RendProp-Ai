# FIX WAVE 1 — decisions, shared contracts, file ownership

Read `/home/claude/audit/BRIEF.md` first (product + hard rules). Then this file. Then the findings files
that cover your slice. You are FIXING now (edit files under /home/claude/rendprop). You cannot compile Swift
here — write conservative, idiomatic Swift (iOS 16 deployment target, Swift 5.9/6 toolchain, Xcode 26),
re-read every edit, and keep every hard rule from BRIEF.md. Prefer adding types to EXISTING files (no new
.swift files). Every new persisted model field must be Optional.

## A. Product decisions (final — do not re-litigate)
1. **Aerial intro is grounded on the property.** The sheet shows a "THE PROPERTY" card: exterior photo
   (defaults to `listing.exteriorPhotoURL`, i.e. exterior or main photo), buttons "Choose photo" (photo
   library, 1 image) and "Take photo" (camera); region line (`listing.regionLabel`, e.g. "Charlotte, NC",
   editable text field, prefilled from geocode, never the street); TIME OF DAY (golden hour / midday /
   twilight / overcast); CAMERA MOVE (rise & reveal / pull back / orbit / push in); FORMAT 16:9 / 9:16;
   LENGTH 4/6/8 s; free-text "look" hint with n/200 counter. With a photo → "Generate from this photo"
   (grounded, Seedance image-to-video, starts on the photo and flies out). Without a photo → button says
   "Generate generic scenery" and a warning explains the AI will invent a generic <spaceNoun>. Result:
   inline `VideoPlayer`, Save to Photos (real completion), Share, Regenerate (old file kept until the new
   one lands), "Open Reel Studio with this clip". Aerial persisted on the listing (`aerialRelPath`,
   `aerialGeneratedAt`, file at `Documents/Aerials/<listingID>-<unixstamp>.mp4`); tool card shows "Aerial
   ready" when present. Job cannot be lost by swipe-down (`interactiveDismissDisabled` while generating,
   confirm on Close). Copy says the truth: "AI-generated from your exterior photo — not real drone footage".
   Space type is sent so venues/restaurants/gyms/stores get the right kind of building.
2. **Publishing is a first-class, re-runnable action.** `AppModel.publishExisting(listingID:)` publishes
   the existing local tour (no re-render). FlythroughDetailView shows "Publish tour" when
   `tours[id] != nil && serverShareURL == nil`, "Create tour" when `assets[id] != nil && tours[id] == nil`
   (pushes ReviewSubmitView), "Add walkthrough video" when `assets[id] == nil && !isSample`. RenderStatusView
   has "Retry publish" on failure and never re-runs on re-appearance. A pending publish survives relaunch.
3. **Listings can be edited and deleted.** `ListingEditSheet(listing:)` (reusing the New Listing form) and
   `AppModel.remove(_:)` (all local files + `DELETE /listings/:serverID` best-effort). Swipe-to-delete on the
   list, "Delete" in the Manage card (confirm). Deleting a published listing unpublishes the hosted tour.
4. **Drafts are not created before a video exists.** NewListingView inserts the listing only when an asset
   arrives (`receive`). On launch, `.processing`/`.uploading` listings without a tour → `.draft` with
   `lastError` = "Render didn't finish"; cards show a "Needs attention" chip and the detail screen offers
   the right next action. Real-estate beds/baths default to 0 (unknown) — never publish invented "3 bd · 2 ba".
5. **"AI declutter" and "Design style" leave Review & Submit** (they never touched the video and only
   produced a false "Virtually staged" label). Keep the `Enhancements` type; always send
   `{declutter:false, style:"as_is"}`; remove the extras card, price/summary rows, and pipeline steps.
   The AI tiers stay but are gated by entitlements from `/me` (locked tiers show "Team plan" — no prices) and
   the drone path is skipped (no upload) when `topaz_per_month == 0`.
6. **Local edits sync to the server.** Any mutation on a listing with `serverID` sets
   `needsServerSync = true`; `AppModel.syncListing(_:)` PATCHes `listings/<serverID>` (address, price, beds,
   baths, sqft, tagline, details, lat/lng, sold_at (null to un-sell), zillow_url, status mapped
   uploading→processing) and clears the flag. Called after each mutation and on launch for dirty listings.
7. **Samples are demos**: stable ids (UUIDv5-style constant per type+index — implement as
   `UUID(uuidString: "0000000<n>-5AMP-4000-8000-<type-padded>")!` or any deterministic scheme), every tool
   that writes files or calls AI is disabled on samples with a "Create a \(spaceNoun) first" hint, Manage
   hidden for samples. Home "Aerial intro" tile falls back to the listings tab when there is no real listing.
8. **Drone vs handheld is an explicit choice** in Review & Submit (segmented "Handheld walkthrough /
   Drone footage", prefilled by a metadata heuristic: `AVMetadata` make/model containing DJI/Autel/Skydio/
   Parrot). Picker buttons are just "Photos" / "Files".
9. **Imports are validated** (duration > 0.2 s, video track, width/height > 0, readable) with a clear alert;
   Files imports get unique names (`import-<uuid8>-<name>`); render guards `naturalSize > 0`.
10. **Capture**: remove the microphone input (tour is muted; keeps the plist string), idle timer disabled
    while capturing/rendering, HW stabilization ladder (`cinematicExtended → cinematic → standard → auto`
    per `activeFormat.isVideoStabilizationModeSupported`), X while recording = stop & DISCARD (confirm),
    "Use this take / Retake" after a take, level bubble sign fixed, `.finalizing` state, no per-second haptic.
11. **RenderEngine** writes to a temp file and moves into place only on success (never deletes the live
    tour first); pass-1 errors fall back to unstabilized; HDR composition color properties set to 709;
    correction divided by zoom. Stabilization SIGN: see `/home/claude/audit/VISION-SIGN.txt` if present
    (empirical result from a Mac run) — otherwise leave the sign as-is and add a clearly-marked TODO.
12. **Errors are honest.** `APIError.server(status:code:message:)` carries the server's `{error, code}`;
    UI shows the message; 402 → "Upgrade plan" CTA opening https://rendprop.com/pricing (no prices in-app);
    401 → sign-in prompt; 409 "already complete" on `/complete` = success; 429 → "try again in a few minutes".
13. **Leads reach the agent.** Backend `GET /leads` (RLS-scoped) + iOS `LeadsView` (all leads, and per
    listing from the detail screen) + Home dashboard count. Lead email notification is a later step (needs
    an email provider) — say so in the UI copy ("Leads appear here; email alerts coming").
14. **Public agent name never falls back to an email**; headshot upload + handle are NOT in this wave (copy
    on the card editor must not claim the headshot appears on the hosted page until it does).
15. **App publishes do not consume "AI tour renders"** (pricing copy says publishing is free):
    migration 0011 adds `render_jobs.source` ('worker'|'app'), `create_render_job(p_source)` excludes
    `source='app'` from the monthly count, uses `effective_plan()`, and `publish-app` marks its job `failed`
    when `publish_render` throws. Posters: `publish-app` accepts `poster_asset_id` (a `renders`-bucket photo
    asset of the same listing) → `publish_render(p_poster_asset)`; iOS uploads a first-frame JPEG poster.
16. **Missing prod migrations are committed** (0005b, 0008b, 0009, 0010 from
    `/home/claude/audit/reconstructed-migrations/`) so repo == prod, then 0011 (this wave).
17. **Hosted player**: explicit "video unavailable" state (never a black stage + fake view), jank watchdog
    ported from the iOS copy, `/f/%` no longer crashes, lead form validates client-side and shows the server
    message, SOLD/Archived badge from `tours` response, per-industry detail sections rendered from the
    camelCase `details` the app already sends, robots: real tours not AI-crawlable by default.
18. **Worker/pipeline**: `as_is`/none styles never trigger a restage; ffmpeg watchdog timer; `requests`
    exceptions mapped to `DBError`; `.env` inline comments parsed; HDR tonemap only when the probe says HDR.
    (The worker is not in the live path; these are correctness fixes only.)

## B. Shared contracts (exact — both sides must match)

### B1. Swift protocol additions (owner: W1-C in `Networking/APIClient.swift` + Live + Mock)
```swift
enum APIError: Error, LocalizedError {
    case invalidURL, badResponse(Int), decoding, notConfigured
    case server(status: Int, code: String?, message: String)   // NEW — errorDescription == message
    var status: Int? { ... }            // 402/401/409/429 helpers:
    var isQuota: Bool; var isUnauthorized: Bool; var isConflict: Bool; var isRateLimited: Bool
}

struct AerialRequest {                  // NEW
    var imageJPEGBase64: String? = nil  // ≤1280 px long edge, JPEG q0.85, base64 (no data: prefix)
    var mime: String? = nil             // "image/jpeg"
    var spaceType: String               // SpaceType.rawValue
    var region: String? = nil           // "Charlotte, NC" — never a street address
    var timeOfDay: String = "golden_hour" // golden_hour|midday|twilight|overcast
    var motion: String = "rise_reveal"  // rise_reveal|pull_back|orbit|push_in
    var style: String? = nil            // ≤200 chars
    var seconds: Int = 6                // 4|6|8
    var aspect: String = "16:9"         // "16:9"|"9:16"
}
func aiVideoAerial(_ request: AerialRequest) async throws -> AIVideoJob   // REPLACES the old signature
// AIVideoJob gains: var grounded: Bool? ; var synthetic: Bool?

struct Lead: Identifiable, Codable, Hashable {   // NEW
    var id: UUID; var listingID: UUID?; var name: String; var phone: String?; var email: String?
    var message: String?; var extra: [String: String]?; var createdAt: Date; var source: String?
    var listingAddress: String?
}
func leads(listingServerID: UUID?) async throws -> [Lead]                  // GET /leads[?listing_id=]
func deleteListing(serverID: UUID) async throws                            // DELETE /listings/:id
func updateChapters(renderID: UUID, chapters: [ChapterInput]) async throws // PATCH /renders/:id/chapters
struct ChapterInput: Codable { var label: String; var tMs: Int; var sort: Int }

struct Entitlements: Codable, Hashable {   // NEW — decoded from /me `entitlement` + `usage`
    var plan: String; var planRaw: String?; var trialEndsAt: Date?
    var rendersPerMonth: Int; var photoEditsPerMonth: Int; var reelsPerMonth: Int
    var aerialsPerMonth: Int; var topazPerMonth: Int
    var used: [String: Int]      // keys: renders, photo_edits, reels, aerials, drone
    var leads: Int
}
// UsageSummary (the existing /me result type) gains `var entitlements: Entitlements?` (Optional).

// publishApp gains an optional poster: (owner W1-C)
func publishApp(listingID: UUID, assetID: String, durationS: Double, speedFactor: Double,
                tier: RenderTier, enhancements: Enhancements, chapters: [ChapterInput],
                posterAssetID: String?) async throws -> PublishedTour
// PublishedTour gains `var renderID: UUID?` (server renders.id) if not already exposed.

// UploadManager (owner W1-C):
func upload(fileURL: URL, listingID: UUID, role: String) async throws -> String   // unchanged; now sends
     // content_type derived from the extension and uses it on the PUT (P0 fix)
func uploadPoster(fileURL: URL, listingID: UUID) async throws -> String           // NEW: kind:"photo", role:"render" → asset id
// updateListing(_:) PATCHes listings/<serverID> and includes zillow_url, sold_at (null when nil), status mapped.
```
Idempotency: `makeRequest(..., idempotencyKey: String? = nil)`; publish uses `"publish:<serverListing>:<asset>"`;
AI sheets generate one UUID per user tap.

### B2. AppModel additions (owner: W1-B in `RendpropApp.swift`; others call these names exactly)
```swift
func remove(_ id: UUID) async                         // local files + maps + server DELETE (best effort)
func setExteriorPhoto(_ relPath: String?, for id: UUID)
func setAerial(relPath: String?, generatedAt: Date?, for id: UUID)
func setRegion(_ label: String?, for id: UUID)
func setLastError(_ message: String?, for id: UUID)
func markDirty(_ id: UUID)                            // needsServerSync = true if serverID != nil
func syncListing(_ id: UUID) async                    // PATCH if dirty; clears flag on success; never throws
func syncDirtyListings() async
func publishExisting(listingID: UUID) async throws -> URL   // uses tours[id] + renders[id] ?? Render(.smooth)
@Published var pendingPublish: [UUID] (persisted, Optional in the snapshot) // listing ids awaiting publish
let renderCoordinator = RenderCoordinator()           // ObservableObject: @Published var jobs: [UUID: RenderJobState]
struct RenderJobState { var phase: String; var fraction: Double; var error: String?; var isRunning: Bool }
```
`setSold/setZillow/setMainPhoto/setCoordinate/modify` call `markDirty` and (except modify inside load) trigger
`Task { await syncListing(id) }`. `publishTour` stores `publishedRenderID` and uploads a poster JPEG (first
frame via `AVAssetImageGenerator`, 1280 px, q0.8) via `uploads.uploadPoster` before `publishApp`.

### B3. Views other agents present (owner: W1-B unless noted)
- `ListingEditSheet(listing: Listing)` — in `NewListingView.swift`; edits + `model.modify` + `markDirty/sync`.
- `AddVideoFlowView(listing: Listing)` — in `NewListingView.swift`; Photos/Files/Record → ReviewSubmitView.
- `LeadsView(listing: Listing? = nil)` — in `SettingsView.swift` (owner W1-D); lists `api.leads(...)`.
- `SignInView` (exists in RenderStatusView.swift) — present when `!AuthStore.shared.isSignedIn`.

### B4. Wire contracts (owner: W1-E backend; W1-C client)
- Error envelope: `{ "error": string, "code"?: string }` codes: `validation | unauthorized | forbidden |
  not_found | conflict | plan_required | quota_exceeded | rate_limited | payload_too_large | upstream | internal`.
- `POST /uploads` accepts `content_type` (allow-listed); `/complete` for `kind:"video"` accepts any
  allow-listed observed type when the ticket type was server-defaulted (track `declared_by_client`), and
  the error message says "does not match the declared type". `POST /uploads` with `role:"render"` may
  carry `kind:"photo"` (poster) → public renders bucket key `renders/<org>/<listing>/<asset>.jpg`.
- `POST /ai-video/aerial` body: `{ image_b64?, mime?, space_type, region?, time_of_day, motion, style?,
  seconds, aspect }` → 202 `{ request_id, status_url, response_url, kind:"aerial", synthetic:true,
  grounded:boolean, model_id, seconds, aspect }`. Grounded = Seedance i2v (`MODEL_REEL` endpoint) with the
  image as data URI, prompt built server-side from space_type/motion/time_of_day/region + guardrails (+ the
  user's style hint appended, never replacing). Ungrounded = current Veo t2v with subject noun by space_type.
- `POST /ai-photo` accepts `space_type` and selects industry-aware prompts; `suggest`/`improve_prompt` are
  NOT charged against the monthly meter (separate burst limiter).
- `GET /me` adds `entitlement {renders_per_month, photo_edits_per_month, reels_per_month, aerials_per_month,
  topaz_per_month, seats}`, `plan` = effective plan, `plan_raw`, `trial_ends_at`, `usage.by_feature
  {renders, photo_edits, reels, aerials, drone}` (this window), and month-scoped `usage.renders`.
- `GET /leads?listing_id=&since=` → `{ leads: [{id, listing_id, name, phone, email, message, extra,
  created_at, source, listing_address}] }` (member-scoped).
- `PATCH /listings/:id` accepts `zillow_url`, `sold_at: null`, `status` in the DB set; `DELETE /listings/:id`
  also unpublishes renders (`published_at = null`).
- `GET /tours/:slug` returns 404 when the listing is deleted; adds `sold_at`, `status`; never returns an
  email as the agent name.
- `POST /renders/publish-app` accepts `poster_asset_id?` and returns `id` (renders.id) + `share_url`;
  marks the job failed on publish error. `PATCH /renders/:id/chapters {chapters:[{label,t_ms,sort}]}`.
- `handle_new_user`: org name = user metadata name or 'My business' (never the email).

## C. File ownership (edit ONLY your files; if you need a change elsewhere, write it to
`/home/claude/audit/handoff-<yourslice>.md` and the owner/parent will apply it)
- W1-A: `apps/ios/Rendprop/Screens/FlythroughDetailView.swift`
- W1-B: `apps/ios/Rendprop/RendpropApp.swift`, `Screens/RenderStatusView.swift`, `Screens/ReviewSubmitView.swift`,
  `Screens/NewListingView.swift`, `Screens/HomeListingsView.swift`, `Screens/OnboardingView.swift`,
  `Models/*.swift`, `Support/*.swift`, `DesignSystem/*.swift`
- W1-C: `apps/ios/Rendprop/Networking/*.swift`, `Upload/*.swift`, `Auth/*.swift`, `Config.swift`
- W1-D: `apps/ios/Rendprop/Screens/SettingsView.swift`, `Screens/PlayerWebView.swift`,
  `Resources/player/index.html`, `Capture/*.swift`, `Import/*.swift`, `Render/*.swift`, `Info.plist`,
  `PrivacyInfo.xcprivacy`, `apps/ios/project.yml`
- W1-E: `services/supabase/**`, `docs/UPLOAD-AND-PUBLISH-CONTRACT.md`, `.github/workflows/ci.yml`
- W1-F: `services/edge/tour-host/**`, `services/worker/**`, `services/pipeline/**`, `apps/web/player/**`

When done, write `/home/claude/audit/report-<slice>.md`: what you changed (file:line), what you deliberately
did not do and why, anything the parent must apply in other files, and a self-review checklist (force-unwraps,
main-actor, Optional fields, hard rules).
