# Report — W1-C (Networking / Upload / Auth / Config)

Files edited (only these): `apps/ios/Rendprop/Networking/APIClient.swift`, `Networking/LiveAPIClient.swift`,
`Networking/MockAPIClient.swift`, `Upload/UploadManager.swift`, `Upload/DirectUploader.swift`,
`Upload/UploadStore.swift`, `Auth/AuthStore.swift`, `Auth/SignInView.swift` (comment-only placeholder),
`Config.swift`. No new .swift files. Nothing compiled here — every file re-read top to bottom; brace/paren
balance verified mechanically; every call site of every changed signature grepped across the app (§PARENT MUST APPLY).

## What changed

### Networking/APIClient.swift (protocol + shared types — DECISIONS §B1 verbatim)
- `typealias RenderTier = Render.Tier` (line 5) so the B1 signature compiles as written.
- `Entitlements` (61–98): `plan, planRaw, trialEndsAt, rendersPerMonth, photoEditsPerMonth, reelsPerMonth,
  aerialsPerMonth, topazPerMonth, used[renders|photo_edits|reels|aerials|drone], leads` + helpers
  `cap(for:)`, `remaining(_:)`, `canUseTopaz`, `canUseAerial`, `isTrial`.
- `UsageSummary` gains Optional `entitlements`, `userName`, `orgName`, `brandName` (100–118).
- `AerialRequest` (132–145) exactly per B1 + `isGrounded`.
- `Lead` (147–158), `ChapterInput` (162–170, `wireDictionary` → `{label, t_ms, sort}`).
- Protocol (180–317): `deleteListing(serverID:)`, `requestUpload(... contentType:idempotencyKey:)`,
  `publishApp(listingID:assetID:durationS:speedFactor:tier:enhancements:chapters:posterAssetID:)`,
  `updateChapters(renderID:chapters:)`, `leads(listingServerID:)`, AI methods with `idempotencyKey: String?`,
  `aiVideoAerial(_:idempotencyKey:)` (old `aiVideoAerial(style:prompt:seconds:aspect:)` REMOVED).
- Extension overloads (320–377) keep old call shapes compiling: `requestUpload` without role/type,
  `aiVideoAerial(_:)`, `aiPhotoEdit/aiVideoDrone/aiVideoReelClip` without a key, and a `@available(deprecated)`
  `publishApp(... staged: ... chapters: [[String: Any]])` shim (no caller left — safe to delete later).
- `AIVideoJob.grounded/synthetic: Bool?` (382–392). `PublishedTour.renderID` documented as `renders.id`.
- `APIError` (419–503): `invalidURL, badResponse(Int), decoding, notConfigured, server(status:code:message:)`;
  `status`, `code`, `isQuota/isUnauthorized/isConflict/isRateLimited/isNotFound/isForbidden/isPayloadTooLarge/
  isValidation/isAlreadyComplete`; `errorDescription == message`; `recoverySuggestion`; `defaultMessage(for:)`.

### Networking/LiveAPIClient.swift
- `aiSession` with `timeoutIntervalForRequest = Config.aiRequestTimeout` (120 s) for `/ai-photo` + `/ai-video/*` (31–43).
- `makeRequest(url:method:json:idempotencyKey:)` (64–91): stable key when given (bounded to 8…128 chars by
  hashing), fresh UUID otherwise on non-GET (previous behaviour).
- `execute()` (96–124): refreshes the JWT via `AuthStore.validAccessToken()` before sending; on 401 →
  `AuthStore.shared.forceRefresh()` once + retry; a second 401 → `signOut()`; every non-2xx → `serverError()`
  (135–151) decoding `{error, code}` (also `message`), stripping `RPnnn:`; friendly per-status fallback.
- `decode()` maps DecodingError → `APIError.decoding` (156–164).
- `updateListing` PATCHes `listings/<serverID ?? id>` (198–206); `listingBody(_:forPatch:)` (474–518) sends
  full local truth on PATCH with JSON null for cleared values: `price_cents/beds/baths/sqft` (0 → null),
  `tagline`, `details` (`{}` — NOT NULL column), `lat/lng` (coarsened), `zillow_url`, `sold_at`, and `status`
  mapped by `wireStatus` (`uploading → processing`; never sends `uploading`). POST omits empties.
- `mapListing` (536–560): `archived → .ready`, `capturing → .draft`, keeps `zillow_url` → `zillowURL`,
  sets `serverID = id`. (`main_photo_key` decoded but the model has no field for a remote key.)
- `requestUpload` sends `content_type` + `sha256` + stable key (215–233); `completeUpload` key `complete:<asset>`.
- `publishApp` (327–357): body `poster_asset_id`, chapters sorted/capped 60, key `"publish:<listing>:<asset>"`,
  decodes `id` → `renderID`, `video_url/poster_url/poster` when present.
- `updateChapters` (359–365), `deleteListing` (208–211), `leads()` (438–453, `{leads:[…]}` or bare array,
  newest first), `me()` (395–436): `entitlement`, `plan`, `plan_raw`, `trial_ends_at`, `usage.by_feature`
  → `Entitlements?` (nil on old servers), plus `user.name/org.name/org.brand_kit.name`; then
  `AuthStore.shared.applyServerIdentity(...)`. `LenientInt` tolerates ints/doubles/strings/null (588–599).
- AI: `aiPhotoEdit/Suggest/ImprovePrompt` send `space_type` (B4); `aiVideoAerial` builds
  `{image_b64?, mime?, space_type, region?, time_of_day, motion, style?, seconds, aspect}` (410–434) and
  fills `grounded/synthetic` when the server doesn't echo them; `aiVideoDrone/ReelClip` take the caller key.

### Networking/MockAPIClient.swift — full parity
`listings()` = `SpaceType.current.sampleListings` + offline-created rows; `createListing` assigns a serverID;
`updateListing` mirrors the status mapping; `deleteListing`/`updateChapters`/`leads` (→ []) stubs;
`publishApp` new signature with a deterministic slug per (listing, asset); `me()` returns nil plan/entitlements
(no fake "Dev" plan); `aiVideoStatus` → `.failed("AI video needs the live backend — you're offline (mock mode).")`
instead of a text file named .mp4; `renderStatus` throws `APIError.server(404)` and guards `steps.count - 7`.

### Upload/DirectUploader.swift
- `uploadContentType(for:kind:)` (mp4→video/mp4, mov/qt→video/quicktime, m4v→video/x-m4v, jpg/jpeg→image/jpeg,
  png/heic/heif/webp; unknown → kind default). `sha256Hex(_:)` for keys.
- `putRequest(url:contentType:)` — the P0 fix. `partPutRequest` still sends NO content type (verified in
  `_shared/r2.ts`: `presignUploadPart` signs only host+query; photo/poster PUT URLs DO sign `content-type`, so
  `photoPutRequest` mirrors the declared type exactly).
- Slices moved from `tmp` to Application Support (excluded from backup).

### Upload/UploadManager.swift
- `State` new Optional fields (decoded with `decodeIfPresent`): `contentType`, `listingLocalID`, `putURL`,
  `putURLIssuedAt`, `singlePutDone`, `failureMessage`, `terminalError`; helpers `isAutoResumable`, `canResume`.
- `begin(fileURL:listingID:listingLocalID:role:metadata:cellularApproved:)` derives + persists `contentType`;
  `launchSingle` PUTs with it. `requestTicketAndStart` sends `content_type` + key
  `"ticket:<sha256(relative path)>:<bytes>"`; 400/401/403/404/413 on the ticket → terminal failure.
- `/complete` (`completeAndFinish`): 409 "already complete" → `markDone`; any other 4xx (except 408/429) →
  TERMINAL with the server message (no re-ticket loop); 5xx/offline → resumable.
- Single mode: PUT HTTP status is now checked (a 403/expired URL used to count as success); transient failures
  retry the SAME presigned URL while < 13 min old, then re-ticket; `singlePutDone` makes a resume re-send only
  `/complete`; relaunch reconcile waits 2 s for a finished background task's delegate before re-sending.
- `upload(fileURL:listingID:listingLocalID:role:metadata:cellularApproved: = false)`: honours the cellular
  guard at publish time — when `shouldWarnCellular` and not approved it PARKS the upload (`.queued`,
  `pendingCellularConfirmation`) and throws `UploadError.cellularConfirmationRequired` immediately (never hangs
  the await); calling again with `cellularApproved: true` adopts the parked upload. Wi-Fi returning
  auto-starts a parked upload (Settings footer promises this). `UserDefaults.register(defaults:
  ["wifiOnlyUploads": true])` in `init`.
- `uploadPoster(fileURL:listingID:)`: `POST /uploads {kind:"photo", role:"render", content_type:"image/jpeg"}`
  → foreground PUT with the signed type → `/complete` (409 already-complete = success); returns the asset id;
  offline mock returns the synthetic id.
- `runSimulate` finishes through `markDone` (an awaiting `upload()` used to hang forever offline).
- `markDone` emits `didCompleteNotification` with `assetID`, `role`, `listingID` (server), `listingLocalID`;
  the `.done` record is removed from DISK immediately and kept only in memory until the next upload replaces it
  (W1-B's `handleUploadCompleted` reads `state?.role` after hopping to the main actor — nil-ing synchronously
  would have silently cancelled every resumed publish). `init` drops any legacy on-disk `.done`.
- Hash task keyed by upload id (`computeHashInBackground(fileURL:uploadID:)`); `pause()` cancels in-flight
  parts (suspend is not honoured by nsurlsessiond) and keeps done parts; `resume()` on a terminal failure starts
  over with a fresh ticket (explicit user action only); `onNetworkRegained` skips terminal failures;
  `onUploadFailed: ((String?) -> Void)?` carries the server message → `UploadError.server(message)`.
- `@Published lastFailureMessage` for the UI.

### Upload/UploadStore.swift — state file excluded from backup; write failure no longer silently `try?`-chains.

### Auth/AuthStore.swift
- Deleted `signInWithApple()`, `requestAppleIDToken`, `appleCoordinator`, `AppleSignInCoordinator` (dead path).
- `displayName: String` (non-optional — SettingsView reads `auth.displayName.trimmingCharacters`),
  `userName` kept as a synced alias (RenderStatusView assigns it directly → `didSet` → `setDisplayName`),
  `setDisplayName(_:)` persists under `auth.userName` and best-effort seeds `PATCH /me/brand {name}` when
  neither the local card nor the server brand kit has a name; `applyServerIdentity(userName:orgName:)` fills
  gaps from `/me` (never an email). "Dev Agent"/"Rendprop Dev" placeholders removed.
- `userID` = JWT `sub` (persisted, non-secret); `applySession` detects a DIFFERENT sub → clears names and fires
  `onAccountChanged` (main). `signOut()` public `@MainActor` (unchanged semantics; keeps name + sub so the same
  account re-signing in keeps its listings' server ids).
- `forceRefresh()` (used by the 401 retry); `refreshIfNeeded` signs out when there is no refresh token AND the
  access token has expired; `runRefresh` single-flight; `performRefresh` never resurrects after cancel.
- Keychain read/write/delete OSStatus logged via `os.Logger` (status only, never values); `SecItemAdd`
  duplicate race handled.
- `exchangeAppleIdentityToken` throws `APIError.server` with GoTrue's own message (`error_description`/`msg`/…).
- `jwtSubject(_:)` helper.

### Config.swift — `UploadMode`/`uploadMode` deleted; `useLiveBackend` kept (doc fixed); `aiRequestTimeout = 120`;
`pricingURL` (https://rendprop.com/pricing) for the 402 CTA — no prices in-app.

## Deliberately not done
- `main_photo_key` is not mapped into `Listing` (no model field for a remote key; adding one is W1-B's file).
- `Listing.Status` still has no `.archived` (W1-B's model) — server `archived` maps to `.ready` + `soldAt`.
- Did not send `status: "archived"` for sold listings (not in decision A6; tour host reads `sold_at`, A17).
- `X-Org-Id` / membership picker (F-E-23) — out of this wave.
- `aiImprovePrompt` still sends `image_b64` (the function requires it); doc comment corrected instead.
- `createRender`/`renderStatus` kept in the protocol (still referenced by W1-B's screens at audit time).

## PARENT MUST APPLY (call sites outside my files)
1. **W1-B `RendpropApp.swift` publish path** — `UploadManager.shared.upload(...)` is called without
   `cellularApproved` (default `false`). On cellular with "Ask before uploading on cellular" ON, it now throws
   `UploadManager.UploadError.cellularConfirmationRequired` (honest message) AND parks the upload; completion
   arrives later via `didCompleteNotification` → their `handleUploadCompleted` (already wired). To offer the
   dialog: catch that case, present "Start on cellular now / Wait for Wi-Fi", and on approve call
   `upload(..., cellularApproved: true)` (adopts the parked upload). Keep `pendingPublish` either way.
2. **W1-B `RendpropApp.swift`** — set `AuthStore.shared.onAccountChanged = { [weak model] in … }` to clear
   `serverID/shareSlug/shareURL/publishedRenderID/needsServerSync` on all listings and `uploadedRenderAssets`
   (nothing references `onAccountChanged` yet). Also touch `_ = AuthStore.shared` on the main thread at launch
   (next to `_ = UploadManager.shared`, line 18) so `@Published` init happens on main.
3. **W1-B `RenderStatusView.swift:537`** assigns `AuthStore.shared.userName = displayName` — works (didSet →
   `setDisplayName`), but `AuthStore.shared.setDisplayName(displayName)` is the intended call; the manual
   `UserDefaults.set(..., "auth.userName")` line is redundant.
4. **W1-D `SettingsView.swift` upload row** — optional: show `uploads.lastFailureMessage` (or
   `s.failureMessage`) under a Failed upload; "Resume upload" already works for terminal failures (fresh ticket).
5. **Notification consumers** — `didCompleteNotification.userInfo` now also carries `"role"` and
   `"listingLocalID"`; prefer reading `role` from userInfo over `UploadManager.shared.state?.role`.
6. Remove the deprecated `publishApp(... staged:chapters: [[String: Any]])` shim in APIClient.swift once
   nothing calls it (grep: no callers today).
7. `Config.UploadMode` and `AuthStore.signInWithApple()` are gone — grep shows no remaining references.

Verified already-matching call sites (no action): FlythroughDetailView `aiVideoAerial(request, idempotencyKey:)`,
`aiPhotoEdit(... idempotencyKey:)`, `aiVideoReelClip(... idempotencyKey:)`, `updateChapters`, `APIError.isQuota/
isUnauthorized/isRateLimited`, `Config.pricingURL`; RendpropApp `publishApp(... posterAssetID:)`,
`uploadPoster(fileURL:listingID:)`, `deleteListing(serverID:)`, `aiVideoDrone(... idempotencyKey:)`,
`ChapterInput(label:tMs:sort:)`, `me().entitlements`; ReviewSubmitView `Entitlements.canUseTopaz`; SettingsView
`Entitlements.*PerMonth/used/leads/plan/trialEndsAt`, `api.leads(listingServerID:)`, `Lead.*`, `auth.displayName`,
`auth.signOut()`, `uploads.pause/resume/cancel/confirmCellularAndStart/pendingCellularConfirmation`.

## Self-review checklist
- Force unwraps: none added (`!` only in `!=`/`!x` boolean contexts; `[0]` on `urls(for:)` pre-existing in UploadStore).
- Main actor: `@Published` mutations in UploadManager happen on main (delegate callbacks dispatched to main,
  `upload()` `@MainActor`, async paths hop via `MainActor.run`); AuthStore session/refresh paths `@MainActor`;
  `setDisplayName` documented main-thread (callers already inside `MainActor.run`).
- Optional persisted fields: all 7 new `UploadManager.State` fields Optional + `decodeIfPresent`; `UsageSummary`/
  `AIVideoJob` additions Optional; `Entitlements`/`Lead`/`ChapterInput` are new types (not persisted by me).
- Hard rules: no prices in the binary (`pricingURL` only); no new .swift files; DTOs tolerant (`decodeIfPresent`,
  `LenientInt`, `TolerantStringMap`); contact email untouched; never sends `uploading` status; no PII logged
  (Keychain log = key name + OSStatus only).
- Known compile risks (no toolchain here): `@Published var userName { didSet }` (supported since Swift 5.1);
  `Logger` interpolation uses `Int(status)`; heterogeneous `[String: Any]` literals in `completeUpload` are
  pre-existing (warning at most); `String + Substring` avoided.
