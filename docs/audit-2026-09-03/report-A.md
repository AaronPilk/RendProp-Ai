# Report — W1-A · `apps/ios/Rendprop/Screens/FlythroughDetailView.swift`

File rewritten in place (3,283 → ~4,870 lines; the floor-plan section from `FloorPlanView` down is the
original code with three `isFinite` guards). No new .swift files. Every new helper type is `private`
(file-scope) so nothing here can collide with, or be depended on by, other files. I could not compile —
the file was re-read top to bottom after assembly, brace-balanced by script, and every external
identifier it uses was grep-verified against the tree as it stood at write time (APIClient.swift, Listing.swift,
FileStore.swift, Config.swift, Components.swift, SettingsView.swift had already landed W1-B/C/D changes;
RendpropApp.swift / NewListingView.swift had NOT — those calls follow DECISIONS §B2/B3 verbatim).

## What changed (by task item)

### 1. AerialIntroSheet overhaul (A1, B1/B4) — `struct AerialIntroSheet` (~line 2490)
- "THE PROPERTY" card: exterior photo thumbnail (defaults to `listing.exteriorPhotoURL`), **Choose photo**
  (`LibraryImagePicker(selectionLimit: 1)`) and **Take photo** (`CameraPicker`); saved to
  `Photos/<listingID>/exterior.jpg` (≤2560 px JPEG q0.9, encoded off-main) then `model.setExteriorPhoto(relPath, for:)`.
  Without a photo: warning "Without a photo the AI invents a generic <noun>", button reads
  **Generate generic scenery** (warn colour); with one: **Generate from this photo**.
- **REGION** text field prefilled from `listing.regionLabel`; if empty and coordinates exist →
  `CLGeocoder.reverseGeocodeLocation` (geocoder retained in `@State`) → locality/administrativeArea only →
  field + `model.setRegion(label, for:)`. Copy says only city/state leaves the phone.
- TIME OF DAY (golden_hour/midday/twilight/overcast), CAMERA MOVE (rise_reveal/pull_back/orbit/push_in with a
  blurb), FORMAT 16:9 / 9:16, LENGTH 4/6/8 s, LOOK hint with `n/200` counter (hard-capped via onChange).
- Request: `AerialRequest(spaceType: space.rawValue)` + region/timeOfDay/motion/style/seconds/aspect; the photo
  is downscaled to ≤1280 px JPEG q0.85 → base64 in `Task.detached` (`AIImagePrep.jpegBase64`); submitted with
  `api.aiVideoAerial(request, idempotencyKey: <one UUID per tap>)`.
- Poll every 6 s as before → download → `Documents/Aerials/<listingID>-<unixstamp>.mp4` (`FileStore.aerialsDir`)
  → `model.setAerial(relPath:generatedAt:for:)` (Documents-relative via `FileStore.relativePath`) → the PREVIOUS
  aerial file is deleted only after the new one is on disk.
- Result state: inline `VideoPlayer`, **Save to Photos** through `PHPhotoLibrary.performChanges` (flag flips only on
  success; denial/failure shows a message), `ShareLink`, **Regenerate** (keeps the current clip until a new one
  lands; form shows "Back to your aerial"), **Open Reel Studio with this clip** (`ReelStudioView(listing:photos:
  extraClipURLs:)`, new init parameter). If `listing.aerialURL` exists the sheet opens on the result.
- `.interactiveDismissDisabled(isGenerating)`; Close while generating → confirmation dialog; screen kept awake via
  `UIApplication.shared.isIdleTimerDisabled` (reset on disappear and on phase change).
- In-flight job persisted in UserDefaults `aerial.pending.<listingID>` (`PendingAerialJob`: the Codable `AIVideoJob`
  + listingID + submittedAt + grounded + aspect); reopening within 2 h resumes polling (`resume(_:)`), the record
  is cleared on completion/definitive failure and expires after 2 h. `aerial.meta.<listingID>` stores
  grounded/aspect so a reopened result is labelled and framed correctly.
- Disclosure "AI-generated — not real drone footage of this <noun>. Say so when you share it." is visible in every
  state; result/progress carry "Based on your photo" vs "Generic scenery" from `job.grounded`.
- Samples: the sheet shows "Samples are demos — create a <noun> first" and no form (defensive against the Home tile).

### 2. Errors (A12) — `AIFailure` / `AIFailureCard` (private, ~line 920)
- Every server-facing failure in this file goes through `AIFailure(error, title:)`: prefers the `.server` message,
  then `errorDescription`; maps `URLError` offline codes to "You're offline…". Cards/alerts show **Upgrade plan**
  (`Link` to `Config.pricingURL` → https://rendprop.com/pricing, no prices in-app) on `isQuota`, **Sign in** on
  `isUnauthorized`, "Try again in a few minutes" on `isRateLimited`, otherwise a plain retry hint. The
  "retries are free while it fails" copy is gone entirely.
- Used by: aerial sheet (card), reel studio (failed phase card), photo studio (alert with Upgrade plan / Sign in
  buttons, title varies: "AI enhance failed" / "Couldn't animate the photo" / "Couldn't analyze the photo"),
  custom-edit "Improve my prompt", publish card, chapter sync note.

### 3. Dead-ends (A2/A3/A4) — `nextStepCard`, `manageSection`
- Pre-publish card is now an action: **Publish tour** (`needsSignIn` → `SignInView(onSignedIn: publishNow)` →
  `try await model.publishExisting(listingID:)`, spinner + inline `AIFailureCard`, "Retry publish" label when
  `lastError`/failure present) when `tours[id] != nil`; **Create tour** → `NavigationLink { ReviewSubmitView(listing:
  currentListing, asset: a) }` when only the asset exists; **Add walkthrough video** → `NavigationLink {
  AddVideoFlowView(listing: currentListing) }` when nothing exists; samples get "Create a <noun>" → `NewListingView()`.
  `listing.lastError` is shown as a warn banner on each card.
- Manage card: **Edit details** → `.sheet { ListingEditSheet(listing: currentListing) }`; **Delete <noun>** (destructive,
  confirmation dialog with honest copy) → `await model.remove(id)` → `dismiss()`; Sold toggle bumps `playerRefresh`
  (no extra sync call — the model syncs itself); Zillow validated (`validZillowURL`: zillow.com host with any
  scheme, or any well-formed https URL; inline error otherwise; empty clears) and bumps `playerRefresh` on save.
  Manage is hidden for samples.

### 4. Samples (A7) — `toolboxSection`
- Photos / Make a reel / Tag rooms / Floor plan / Aerial intro are `.disabled` + dimmed with the "Create a <noun> first"
  sublabel on `isSample`; the sample tour stays viewable; Agent card stays enabled (not per-listing).
  Aerial card shows "Aerial ready" when `listing.aerialURL != nil`.

### 5. Photo studio — `struct PhotoStudioView`
- `onDisappear` only cancels `animateTask` when nothing is presented over the studio (`isPresentingOverlay`); the
  `CancellationError` branch resets `isProcessing` (F-A-12).
- `aiEdit` re-entrancy guard (`guard !isProcessing`); wand button disabled while processing.
- Sign-in gate (`requireSignIn()` → `SignInView` sheet) on AI edit / suggest / custom edit / animate (F-A-13).
- JPEG decode/encode/base64 moved off the main actor (`AIImagePrep.jpegBase64 / writeJPEG`, `Task.detached`);
  the downscaler pins `UIGraphicsImageRendererFormat.scale = 1` — the old helper inherited the 3× screen scale, so
  "1280 px" uploads were actually 3840 px.
- Thumbnails: `DetailPhotoThumb` (private) loads via the shared `ImageThumbnails` cache (ImageIO ≤800 px, keyed by
  path+mtime) in `.task`; full-res `UIImage(contentsOfFile:)` no longer runs inside `body` anywhere in this file.
  `PhotoCompareView` decodes both images once, off-main, at ≤2400 px. `delete` invalidates the cache entry.
- Type-aware copy via `listing.spaceType` (samples → `SpaceType.current`): nav title "<Noun> photos", "Furnish &
  style" instead of "Virtual staging" for non-RE, "Green lawn" only for real estate, staging dialog "furnishes the
  <noun>", empty-state chips per type. "Set as main image" → "Use as cover photo" (F-A-25 relabel).
- `EnhancedPhoto.loadAll(listingID:)` / `.directory(for:)` extracted so the aerial sheet can hand Reel Studio the photos.
- Photo-clip result sheet + reel + aerial + QR all use the shared `PhotosLibrarySaver` (real completion).
- `PhotoStudioView(listing:intent:)` — `.reel` shows a "add at least 2 photos" hint (F-A-20); the detail's "Make a
  reel" card passes it.

### 6. QR — `QRShareSheet` / `QRCodeMaker` (private)
- "QR code" button (replaces the second ShareLink) → sheet with a 1024 px `CIFilter.qrCodeGenerator` image
  (nearest-neighbour scaled), the URL (selectable), **Save image** (real completion) and `ShareLink(item: Image…)`.

### 7. Room tags after publish — `roomTaggerDismissed()`
- Snapshot of tags taken when the tagger opens; on dismiss, if changed and `publishedRenderID != nil` and a tour
  exists: rescale by `speedFactor` exactly like `AppModel.publishTour` (`Int((Double(tMs) / sf).rounded())`, sorted,
  `sort = index`) → `api.updateChapters(renderID:chapters:)` best effort; `chapterSyncNote` shows
  "Updating… / Chapters updated on your share link. / Couldn't update … — <server message>".

### 8. Leads — `performanceSection`
- Renamed "LEADS": `serverID != nil` → `NavigationLink { LeadsView(listing: currentListing) }` row + "Leads appear
  here; email alerts coming."; unpublished → "Publish your tour to start collecting leads…"; samples → a sample
  leads stat only. The "Views, watch time…" promise and the Views/Avg watch/Scroll-depth fake stats are gone.

### 9. Nits (F-A-26)
- `%.3g` speed label; `safeSpeedFactor` guards `isFinite && > 0` for both `playbackTags` and the label (no `tour!`).
- `zillowText` seeded once (`zillowSeeded`), never reset on appear.
- `CLGeocoder` kept in `@State`; one geocode attempt per appearance; forward geocode also stores the region label.
- `isFinite` guards in `FloorPlanRenderer` (`scale`, area, `feetInches`) and on coordinates before the map.
- Nav title = address; "Tweak the look" copy replaced ("Adjust the settings above and generate again.").
- Unreachable "running offline" branches removed (sign-in branch kept) in the aerial and reel sheets.
- `MapPin.id` derived from the coordinate (no new UUID per body); "Open in Maps" link under the map.
- Info card shows `StatusChip` + region; details/links/quick copy use `listing.spaceType` instead of `SpaceType.current`
  (samples fall back to the current type because they carry no `spaceTypeRaw`).
- Idempotency: one `UUID().uuidString` per user tap for aerial / photo edit / reel clip / animate (B1 note).

## Deliberately NOT done (and why)
- F-A-11 (enhanced photos / floor plan / reel reaching the hosted page): needs upload roles + backend fields — out of
  this wave's contract.
- F-A-17 floor-plan export/per-room scans: not in the task list; only the `isFinite` guards were applied.
- `/ai-photo` `space_type`: the Swift `aiPhotoEdit` signature has no such parameter (contract B1), so the studio
  can't send it yet — see handoff.
- Publish progress uses a spinner + copy, not `UploadManager.state` — avoided adding an `@EnvironmentObject
  uploads` dependency to a screen reached from four entry points.

## PARENT MUST APPLY (other files)
1. **W1-B `RendpropApp.swift`** — this file calls, exactly per §B2: `model.remove(_:) async`,
   `model.setExteriorPhoto(_:for:)`, `model.setAerial(relPath:generatedAt:for:)`, `model.setRegion(_:for:)`,
   `model.publishExisting(listingID:) async throws -> URL`, and relies on `setSold`/`setZillow`/`setMainPhoto`/
   `setCoordinate` syncing themselves. It also reads `listing.lastError`, `publishedRenderID`, `aerialURL`,
   `aerialGeneratedAt`, `exteriorPhotoURL`, `regionLabel` (already in Listing.swift).
   Optional nicety: `remove(_:)` could also `UserDefaults.standard.removeObject(forKey: "aerial.pending.<id>")` and
   `"aerial.meta.<id>"`.
2. **W1-B `NewListingView.swift`** — `ListingEditSheet(listing:)` is presented as a `.sheet` with
   `.environmentObject(model)`; `AddVideoFlowView(listing:)` is **pushed** via `NavigationLink` (destination-based),
   so it must NOT wrap its own `NavigationStack` and should reach ReviewSubmitView via `NavigationLink` /
   `navigationDestination(isPresented:)` (same shape as `NewListingView`). If it was built as a self-contained
   sheet, change the `addVideoCard` link (~line 417) to `.sheet`.
3. **W1-B `RenderStatusView.swift`** — `SignInView(onSignedIn:)` must keep that parameter (used by the publish
   gate). Its copy is publish-specific ("Sign in to publish"); it is also presented for AI edits/aerials/reels —
   consider a `title/subtitle` parameter with defaults.
4. **W1-B `FileStore.swift`** — this file depends on `ImageThumbnails.cached/load/invalidate` and
   `FileStore.aerialsDir` (both present in the current working tree). Keep them.
5. **W1-C `Config.swift` / `APIClient.swift`** — depends on `Config.pricingURL`, `AerialRequest`, `ChapterInput`,
   `APIError.server/isQuota/isUnauthorized/isRateLimited`, `AIVideoJob.grounded`, the `idempotencyKey:` variants of
   `aiVideoAerial/aiPhotoEdit/aiVideoReelClip`, and `updateChapters` (all present). If `aiPhotoEdit` gains a
   `spaceType` parameter, pass `space.rawValue` from `PhotoStudioView.aiEdit`.
6. **W1-D `SettingsView.swift`** — `wipeLocalData` should also remove `Documents/Aerials` and the
   `aerial.pending.*` / `aerial.meta.*` UserDefaults keys. `LeadsView(listing:)` is used as-is.
7. **W1-B `HomeDashboardView`** — the Aerial tile may still open the sheet for a sample; the sheet now refuses
   politely, but A7 says the tile should route to the listings tab when there is no real listing.
8. **W1-E backend** — `/ai-video/aerial` must accept `{image_b64, mime, space_type, region, time_of_day, motion,
   style, seconds, aspect}` and return `grounded` (contract B4); the client sends exactly those.

## Self-review checklist
- Force-unwraps: none added; the `tour!` in the caption is gone. `fatalError` only in the pre-existing
  `RoomScanController.init(coder:)`.
- Main actor: every `@State`/model mutation from async work is inside `await MainActor.run { }` (or a main-actor
  view method); image/base64/QR/thumbnail work runs in `Task.detached`; `nonisolated static` stitch/makeClip kept.
- Optional fields: no model changes in this file; persisted job/meta records are private Codable structs in
  UserDefaults, tolerant on decode failure (treated as absent).
- Hard rules: all navigation destination-based (`NavigationLink { } label: { }`, `navigationDestination` untouched);
  no digital-goods prices or purchase copy (Upgrade plan is a link to the website only); no new .swift files; no
  contact email in copy; `Config.useLiveBackend` branches removed only where compile-time true made them dead.
- Type-checker: long bodies split into `@ViewBuilder` sub-views; no stack exceeds 10 children.
- Concurrency pitfalls checked: no `await`/`try` right of a ternary; no captured `var` mutated inside `Task {}`
  closures (`request` is declared inside the closure); `@Sendable` closures capture only values.
