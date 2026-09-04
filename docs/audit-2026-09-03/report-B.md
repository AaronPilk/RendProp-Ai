# Report — W1-B (AppModel, flow screens, models, support, design system)

All work is in the files I own. No new `.swift` files (xcodegen does NOT need re-running for this slice).
Every new persisted field is Optional + `decodeIfPresent`. No force-unwraps were added (the one
pre-existing `layer as! AVPlayerLayer` in `PlayerLayerView` became an optional cast).

## Changes by file

### `apps/ios/Rendprop/RendpropApp.swift` (rewritten around the same structure)
- **AppModel additions (DECISIONS §B2, exact names)**: `remove(_:) async`, `setExteriorPhoto`, `setAerial`,
  `setRegion`, `setLastError`, `markDirty`, `syncListing(_:) async` (PATCH via `api.updateListing`, clears
  `needsServerSync` on success, in-flight guard + re-check loop so an edit made mid-PATCH isn't lost, never
  throws), `syncDirtyListings() async`, `publishExisting(listingID:) async throws -> URL`
  (`existingAssetID:` extra defaulted param), `@Published var pendingPublish: [UUID]` (persisted),
  `let renderCoordinator = RenderCoordinator()`.
- `setSold/setZillow/setMainPhoto/setCoordinate` → `markDirty` + `Task { await syncListing }`;
  `modify(_:sync:_:)` (defaulted `sync: true`) does the same; sample listings are no-ops for the
  file/AI-writing setters (sold/zillow/mainPhoto/exterior/aerial).
- `load()`: restore → **reconcile (A4)**: `.processing/.uploading` without tour → `.draft` + `lastError`
  "The render didn't finish…"; with tour → `.ready` (+ queued in `pendingPublish` when no share link);
  `.ready` without tour and without share → `.draft` (+ `lastError` when the asset still exists);
  `pendingPublish` pruned to real listings that still have a local tour and no link. Then `reseedSamples()`,
  then background `syncDirtyListings()` + `resumePendingPublishes()`.
- `reseedSamples()` is now **derived**: `listings = real + SpaceType.current.sampleListings`, guarded by
  `hasLoaded` (calling it before load used to persist an EMPTY snapshot). `persist()` also guards `hasLoaded`.
- **`publishTour`** (signature kept + `existingAssetID: String? = nil`): puts the id in `pendingPublish`
  first, `ensureServerListing`, **first-frame poster** via `PosterMaker` (`AVAssetImageGenerator`, 1280 px,
  JPEG q0.8, `Caches/posters/`) → `UploadManager.shared.uploadPoster(fileURL:listingID:)` (best effort),
  upload role=render (or reuse a remembered/passed asset id), `api.publishApp(... chapters: [ChapterInput],
  posterAssetID:)` always with `Enhancements()` (A5), persists `shareSlug/shareURL/publishedRenderID`,
  `lastError = nil`, `.ready`, removes from `pendingPublish`. Failure → `lastError = server message`
  (`APIError.errorDescription`), stays pending, rethrows. 404/400 on the asset drops the remembered id.
- New persisted `uploadedRenderAssets: [UUID: UploadedRenderAsset]` (relPath → server asset id) so a
  retried publish / the AI-enhance fallback never re-uploads the same master and keeps the same
  `(listing, asset)` idempotency key.
- `resumePendingPublishes()`: on launch, signed-in only (never prompts); skips listings whose render
  upload is still in flight in `UploadManager` (the notification finishes those), uses a `.done`
  upload's asset id directly.
- `UploadManager.didCompleteNotification` observer in `init` → `handleUploadCompleted` publishes a pending
  listing with the completed asset when no in-app pipeline is awaiting it (F-B-01 e).
- `AppModel.chapters(from:speedFactor:)` (static) builds `[ChapterInput]` on the rendered timeline.
- **`RenderCoordinator: ObservableObject`** (`@MainActor`) with `@Published var jobs: [UUID: RenderJobState]`
  (`phase/fraction/error/isRunning` + `stage/note/errorStatus/canSkipEnhance`), `weak var model`,
  `start(listing:asset:)`, `publish(listingID:allowEnhance:)`, `skipEnhance(listingID:)`,
  `cancel(listingID:)`, `clear(listingID:)`, `isRunning`, `progress(for:)`, `job(for:)`. Owns the `Task`
  per listing (per-run token so a cancelled/superseded task can never clobber a newer job), keeps
  `isIdleTimerDisabled = true` while any job runs (reset after), `beginBackgroundTask` per job, the whole
  render → sign-in gate → AI enhance → publish pipeline. Render failure → listing `.draft` + `lastError`.
  Not signed in → `.ready` + `pendingPublish` + stage `awaitingSignIn`. AI enhance: **pre-flights `/me`
  entitlements and skips the upload when `topazPerMonth == 0` / allowance used** (note says why), tier
  mapping fixed (`premium4k → "4k30"/30 fps`, `cinematic → "4k60"/60 fps` via `Render.Tier`), 20-min poll,
  skippable, enhanced file now at `Recordings/enhanced-<id>.mp4`, any failure falls back to the standard
  tour with the server's message in `note` and reuses the uploaded master asset for the publish.
- `PersistentStore`: `PersistedState.pendingPublish: [UUID]?` and `.uploadedRenderAssets` (both Optional,
  `decodeIfPresent`), `save(...pendingPublish:uploadedRenderAssets:)` (defaulted params), `Loaded` gains both;
  an undecodable snapshot is copied to `rendprop-state.corrupt-<ts>.json` before it could be overwritten.
- `RendpropApp.init()` registers `UserDefaults` defaults `wifiOnlyUploads = true` (F-C-07).
- `RootTabView`: `.task { load(); reseedSamples() }` + `.onChange(of: "space.type")` → the ONE place samples
  re-derive (fixes onboarding re-pick, F-C-10). Home menu became a `Picker` inside the `Menu` (checkmark
  works, F-C-22) and no longer calls reseed itself.
- Home dashboard: `firstRealListing` excludes sold listings; **Aerial tile falls back to the listings tab**
  when there's no real listing and the sheet only ever opens on a real listing; Reel tile opens
  `PhotoStudioView(listing:intent: .reel)`; the share banner is now a **Leads banner → `LeadsView()`** with
  the `/me` lead count when signed in ("Leads appear here; email alerts are coming"); How-it-works copy fixed
  (steady normal pace like the capture coaching; "One link or QR code"; leads land in Leads); hero
  `TimelineView` paused under Reduce Motion; partner links no longer force-unwrap a URL.

### `Screens/RenderStatusView.swift` (rewritten; `SignInView` kept)
- Observes `model.renderCoordinator` (`RenderStatusContent` with `@ObservedObject`); **never starts work on
  appear**; no `onDisappear` cancel; `runSimulation` removed.
- Modes: working (percent while rendering, spinner while enhancing/publishing, real **Cancel** button with
  confirmation → `coordinator.cancel` → `.draft` + pop for a render, `.ready` for a publish; "Skip AI enhance"
  while skippable), failed (**Try again** → `coordinator.start`, **Cancel**), ready (View my tour / Share when
  the server URL exists / **Retry publish** on `publishFailed` with the server message, **Upgrade plan** link
  to `Config.pricingURL` on 402, **Sign in to publish** on 401, `note` for enhance fallbacks), needsSignIn
  (sheet auto-presented once), publishLater ("Not now" → `.ready` + `pendingPublish`, copy tells the user to
  publish from the listing; "Sign in & publish" re-opens the sheet), idle (relaunch: "Start render").
- Sign-in sheet dismissal: signed in → `coordinator.publish(allowEnhance: true)`. `SignInView` now keeps
  Apple's one-time `fullName` (`AuthStore.shared.userName` + UserDefaults `auth.userName`) and explains
  what "Not now" does.

### `Screens/ReviewSubmitView.swift` (rewritten; `RoomTaggerView`/`PlayerLayerView` kept)
- Removed: AI declutter/design-style extras card, price summary rows, "Length band"/`PricingBand`,
  the decorative cellular prompt, the mock worker upload path, unused `uploads` env object.
- Added: **Handheld walkthrough / Drone footage** segmented control (A8), prefilled from `asset.isDrone`
  or the metadata heuristic `looksLikeDrone` (make/model/software containing DJI/Autel/Skydio/Parrot/
  Hasselblad, or a DJI-style filename); written into `asset.isDrone` before start.
- Tier picker gated by `/me` entitlements (`UsageSummary.entitlements?.canUseTopaz`): locked AI tiers show
  "Team plan" (no prices), can't be selected, selection falls back to Smooth; signed-out shows a "Sign in"
  link that presents `SignInView`.
- `start()`: `model.assets[id] = asset`, `model.renders[id] = Render(... Enhancements())`, `setLastError(nil)`,
  `model.renderCoordinator.start(listing:asset:)`, pushes `RenderStatusView`. When a tour already exists →
  "View tour" + explicit "Render again" (confirmation); while rendering → "See progress".
- `RoomTaggerView.addTag` merges a second tap at the same moment (<0.5 s) instead of stacking dots (F-B-25).

### `Screens/NewListingView.swift` (rewritten)
- `ListingFormData` (Equatable; beds/baths default **0 = unknown**, "—" stepper labels; price/sqft parsed
  digits-only via `Money.parseDollars`) + reusable `ListingFieldsForm<Middle>` (address card → middle slot →
  RE details / tagline + `DetailFieldsEditor`); `.textContentType(.fullStreetAddress)` only for real estate
  (`.organizationName` otherwise); per-type tagline placeholders.
- `NewListingView` creates the listing **only in `receive(_:)`** after a usable asset exists (A4), applying
  the form + `pendingCoord` (F-B-06). Coming back and picking another video reuses the listing and deletes
  the previous file.
- `VideoSourcePicker` (shared): "Photos" / "Files" / Record, import progress, `isDrone: false` always, own
  validation (duration > 0.2 s, w/h > 0, bytes > 0) with a clear alert; `try await MediaImporter.makeAsset`
  inside do/catch so it compiles whether W1-D makes it throwing or not.
- `ListingEditSheet(listing:)` — NavigationStack sheet, Save = `model.modify(sync:false)` + `markDirty` +
  `Task { await model.syncListing(id) }`, disabled until something changed.
- `AddVideoFlowView(listing:)` — same picker; stores `model.assets[id]`, `.draft`, clears `lastError`, pushes
  `ReviewSubmitView(listing:asset:)` via `navigationDestination(isPresented:)` (push it inside a
  NavigationStack, as W1-A does). Samples are read-only.

### `Screens/HomeListingsView.swift` (rewritten)
- `List` (plain, hidden chevron via invisible destination-based `NavigationLink`) so rows get real
  **swipe-to-delete** + **context-menu Delete** (samples excluded) → confirmation dialog (mentions that the
  share link stops working when published) → `model.remove`. Same in `SoldListingsView`.
- `ListingCard`: **"Needs attention"** chip + the `lastError` line when set; hero via
  `ImageThumbnails` (cached, downsampled, off-main; no `UIImage(contentsOfFile:)` in `body`); "Tour ready to
  share" only when a server URL exists (else "Tour ready"); placeholder icon from the listing's own type.
- `.refreshable { await model.syncDirtyListings() }` (was a no-op); empty-search row; first-run invitation card
  above the samples until the user has a real listing (the old unreachable `emptyState`); reseed-on-type-change
  moved to `RootTabView`.

### `Screens/OnboardingView.swift`
- Business-type copy now points at the Home tab menu (and Settings, which W1-D made a real switcher);
  LiDAR promise softened ("On iPhones with LiDAR… or upload one"); leads card mentions Leads.

### `Models/Listing.swift`
- `needsAttention`; `actionURL`/`subtitleLine`/`cardChips` use the listing's own `spaceType` (samples are now
  stamped with `spaceTypeRaw`); price chips parse "3,500"/"$49"; `DetailField.display(.price)` formats as
  Money; **stable sample ids** (`SpaceType.sampleID(_:)` built from raw UUID bytes, non-failable —
  `0000000n-0000-4000-8000-00000000000t`; the DECISIONS literal "5AMP" isn't hex and would have crashed);
  the second RE sample is `.ready` (no permanent "Working on it").

### `Models/Render.swift`
- `PricingBand` removed; `pipelineSteps` no longer lists declutter/restage; `Tier.usesServerAI`,
  `droneTierParam` ("4k30"/"4k60"), `droneTargetFPS` (30/60); blurbs say "up to 4K" at 30 vs 60 fps.
  `Enhancements`/`DesignStyle` kept for JSON back-compat (always defaults on the wire).

### `Models/Money.swift`
- `dollars(_:)` clamps on overflow (`multipliedReportingOverflow`); `parseDollars(_:)`; fixed `en_US` locale.

### `Support/FileStore.swift`
- `caches`, `aerialsDir`, `previewHTMLURL(besideVideo:)`, `removeVideoAndPreview`, `removeFiles(in:withPrefix:)`,
  `deleteListingFiles(listingID:assetURL:sidecarURL:assetID:tourURL:)` (recording/import + sidecar +
  previews, `tour-<asset8>.mp4`, `Photos/<id>`, `FloorPlans/<id>*`, `Aerials/<id>-*`, `reels/<id>-*`,
  `Recordings/enhanced-<id>*`, legacy root `enhanced-/aerial-` files, cached poster).
- `ImageThumbnails` (NSCache + `CGImageSourceCreateThumbnailAtIndex`, `cached`/`load`/`invalidate`).

### `DesignSystem/Components.swift`
- `AttentionChip`, `SecondaryButton`; dead `SkeletonRow` removed. `Theme.swift` untouched (every
  `Listing.Status` switch in my files is exhaustive; no `.archived` case — server `archived` maps to
  `.ready + soldAt` on W1-C's side).

## Deliberately NOT done
- No `NavigationPath` unwinding after "View my tour" (F-B-12) — Review now shows "View tour" instead of
  re-submitting, which removes the harm; a stack-owned path is a bigger refactor across W1-A's screens.
- `Listing.Status` cases unchanged (`.expired` still never set).
- Cellular/Wi-Fi honouring for the publish upload is W1-C's (`UploadManager`); the decorative prompt is gone.

## PARENT MUST APPLY (other owners)
1. **W1-C `Upload/UploadManager.swift`**: `func uploadPoster(fileURL: URL, listingID: UUID) async throws -> String`
   must exist (DECISIONS B1) — `AppModel.publishTour` calls `UploadManager.shared.uploadPoster(...)`. At the
   time of writing it is not yet in the file. It must not leave `state` in `.uploading/.queued/.paused`
   (otherwise the following `upload()` throws `.busy`).
2. **W1-D `Import/MediaImporter.swift`**: keep `makeAsset(from:isDrone:)` returning a non-optional
   `CaptureAsset` (`async` or `async throws` both compile — `VideoSourcePicker` uses `try await` in a
   do/catch and validates itself). If it returns `CaptureAsset?`, change `VideoSourcePicker.importFile` to
   unwrap.
3. **W1-D `Screens/SettingsView.swift` `wipeLocalData`**: add `model.pendingPublish.removeAll()`,
   `model.uploadedRenderAssets.removeAll()`, and remove `Documents/Aerials`, `FloorPlans`, `reels`,
   `Caches/posters` (Recordings/Imports/Photos already). `RenderStatusView.runSimulation` is gone, so nothing
   in Settings should reference it.
4. **W1-D `Render/RenderEngine.swift`**: output path must stay `Recordings/tour-<assetID8>.mp4`
   (`FileStore.deleteListingFiles` derives it) and be written atomically; the AI-enhanced file now lives at
   `Recordings/enhanced-<listingID>.mp4` (PlayerWebView's read grant is the video's directory, so no change).
5. **W1-C `Auth/AuthStore.swift`**: `SignInView` sets `AuthStore.shared.userName` and writes UserDefaults
   `auth.userName` directly (same key AuthStore reads). A proper `setDisplayName(_:)` would be cleaner.
6. **W1-C `Networking/APIClient.swift`**: the deprecated `publishApp(... staged: ..., chapters: [[String: Any]])`
   overload has no callers left in my files and can be deleted.
7. **W1-A `FlythroughDetailView`**: nothing required — it already calls `publishExisting`, `remove`,
   `ListingEditSheet(listing:)`, `AddVideoFlowView(listing:)`, `ReviewSubmitView(listing:asset:)`,
   `LeadsView(listing:)` with the signatures implemented here. `RenderJobState` is available via
   `model.renderCoordinator.jobs[id]` if it wants live progress.

## Self-review checklist
- [x] Force-unwraps: none added; `PlayerLayerView` cast made optional; sample ids built from bytes (no `!`).
- [x] `@MainActor`: `AppModel`, `RenderCoordinator` are MainActor classes; all UI state mutations from
      background work hop via `Task { @MainActor in }` / `MainActor.run`; file IO for delete and poster
      encode run in `Task.detached`.
- [x] Optional persisted fields: `pendingPublish`, `uploadedRenderAssets` (`decodeIfPresent`), reading old
      snapshots unchanged; `save()` filters both to real listing ids.
- [x] Hard rules: destination-based `NavigationLink { } label: { }` everywhere (incl. the hidden List links);
      no digital-goods prices or purchase copy ("Team plan", "Upgrade plan" link only); no new files;
      `Listing` new fields untouched; copy contradictions fixed (pace, QR, Settings/Home type switch).
- [x] Every `switch` over `Listing.Status`, `RenderJobState.Stage`, `UploadManager.Status`, `SpaceType`,
      `Render.Tier`, `FieldInputType` exhaustive.
- [x] Bracket/paren/string balance verified with a Swift-aware scanner on every edited file; every
      cross-file identifier referenced (`AerialIntroSheet`, `PhotoStudioView(listing:intent:)`,
      `FloorPlanView`, `AIPhotoStudioView`, `AgentCardEditorView`, `ProfileView`, `SettingsView`,
      `LeadsView`, `PhotoVideoPicker`, `FilesVideoPicker`, `CaptureView`, `Config.pricingURL`,
      `Entitlements.canUseTopaz/remaining`, `APIError.status/isNotFound/isValidation/isUnauthorized`,
      `ChapterInput`, `PublishedTour.renderID`, `api.deleteListing/updateListing/me/aiVideoDrone(…idempotencyKey:)`)
      grep-confirmed — except `UploadManager.uploadPoster` (item 1 above).
