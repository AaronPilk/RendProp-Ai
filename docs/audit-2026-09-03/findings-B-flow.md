# Findings — B · Main user journey (onboarding → listings → new listing → review → render/publish → player)

Files read line-by-line: `OnboardingView.swift`, `HomeListingsView.swift`, `NewListingView.swift`,
`ReviewSubmitView.swift`, `RenderStatusView.swift` (incl. `SignInView`), `PlayerWebView.swift`,
`Resources/player/index.html`, `Auth/SignInView.swift` (empty stub). Supporting reads: `Models/*`,
`RendpropApp.swift`, `APIClient.swift`, `MockAPIClient.swift`, `LiveAPIClient.swift`, `Config.swift`,
`RenderEngine.swift`, `UploadManager.swift`, `MediaImporter.swift`, `CaptureView.swift`, `AuthStore.swift`,
the top of `FlythroughDetailView.swift`, `SettingsView.swift` (AgentCard + account section),
`services/supabase/functions/renders/index.ts`, `ai-video/index.ts`, migration `0008`, and
`services/edge/tour-host/src/player.ts` (to compare the in-app preview with the hosted page).

## Summary
The happy path (address → upload/record → tag → on-device render → sign in → publish → share) is
wired and mostly coherent, the chapter timebase is consistent end-to-end, injection into the
player is escaped, and persistence is tolerant. The flow falls apart on every *unhappy* path:
publishing exists only inside `RenderStatusView`, so a declined sign-in, an offline moment, a
server error, a tab switch, or an app kill leaves a tour that can never get a share link (the
copy literally promises "share it later" and nothing implements it). `RenderStatusView.onAppear`
re-runs the whole render + publish (+ paid AI enhance) every time the screen re-appears. The
"AI declutter / Design style" extras in Review & Submit do nothing to the video but make the
server stamp the public tour "Virtually staged" — a false disclosure. The AI tiers are two labels
for one identical job that upscales a 720p master to 1440p, not 4K. New-listing drafts are
inserted before any video is picked and can never be finished or deleted; real-estate listings
silently get "3 bd · 2 ba" from stepper defaults. `demo.mp4` is not in the repo and the missing-
file fallback loads the un-adapted real-estate demo page for every business type.

## Findings (most severe first)

### F-B-01 · P0 · A tour that isn't published in the RenderStatus screen can never be published
- Where: `Screens/RenderStatusView.swift:95-99, 161-176, 371-397, 402-417`; `RendpropApp.swift:135-179`
  (`publishTour` — its only caller is `RenderStatusView.performPublish`); `Screens/FlythroughDetailView.swift:185-203`
  (the "Publish to get your share link" banner has no button and no action).
- What's wrong: every publish failure path ends in `publishFailed = true; markReady()` and the user is told
  "Saved on your phone — we couldn't publish the share link. You can view it now and **share it later**."
  There is no "later": no retry button on the status screen, no publish action on the listing detail, no
  background job. The paths that land here: (a) `SignInView` "Not now" (`onSignInSheetDismissed` 413-416);
  (b) any network/server error in `ensureServerListing` / `UploadManager.upload` / `publishApp`
  (`performPublish` catch 387-396) — including plain offline; (c) leaving the screen while publishing
  (`onDisappear { pollTask?.cancel() }` 191 → the awaited `session.data` throws → catch → dead-end);
  (d) `UploadManager.upload` throwing `.busy` because a previous (auto-resumed) upload is still running
  (`UploadManager.swift:232-234, 342-362`); (e) app killed during the publish upload: `UploadManager.init`
  resumes and completes the upload, but the `onUploadComplete` continuation died with the process, nobody
  observes `didCompleteNotification`, so `/renders/publish-app` is never called — the listing stays
  `.processing` ("Working on it") with a viewable local tour and no link.
- User-facing effect: the product's core promise ("One link. Real leads.") is unreachable for anyone who
  hit any hiccup; the only workaround is to create a brand-new listing and re-upload/re-render from scratch.
  The listing card shows "Ready" (or "Working on it" in case e) with no share button, and the detail page
  tells them to "Create your tour" which they already did.
- Fix: (1) Make publish a first-class, re-runnable action: add `AppModel.publishExisting(listingID:)` that
  reads `tours[id]` + `assets[id].roomTags` + the persisted `renders[id]` (tier/enhancements) and runs the
  same `publishTour`; store the last `Render` in `model.renders[listing.id]` from `ReviewSubmitView.start()`
  (that map is currently never written — see F-B-27). (2) In `FlythroughDetailView`, when
  `tour != nil && serverShareURL == nil`, render a real "Publish tour" button (sign-in gate → publish →
  progress) instead of the passive banner; also a "Retry publish" button in `RenderStatusView` when
  `isReady && publishFailed`. (3) Persist a pending-publish record (listing id, render output rel path,
  server asset id once known) so a relaunch after case (e) can finish with just the `publish-app` call —
  subscribe to `UploadManager.didCompleteNotification` (it already carries `assetID` + `listingID`) in
  `AppModel` and complete the publish there. (4) Change the failure copy to name the real action
  ("Tap Publish on the listing when you're back online"). All new persisted fields Optional.

### F-B-02 · P0 · "AI declutter" / "Design style" extras do nothing to the tour, but the public page gets a false "Virtually staged" disclosure
- Where: `Screens/ReviewSubmitView.swift:191-287` (extras card), `301-314` (summary rows "AI declutter (photos) · Included",
  "Restage · Modern · Included"), `274-283` (warning that the shared tour WILL show a "Virtually staged" label);
  `Render/RenderEngine.swift:73-74` (`render(asset:progress:)` takes no enhancements — nothing on-device uses them);
  `Screens/RenderStatusView.swift:377-384` and `RendpropApp.swift:166-171` (enhancements are only forwarded to
  `/renders/publish-app`); `services/supabase/migrations/0008_audit_round4.sql:219-222` (server derives
  `staged := declutter OR style != as_is` and stamps the render); `Resources/player/index.html:271` /
  `PlayerWebView.swift` (`VIRTUALLY_STAGED` is never injected, so the in-app preview never shows the chip either).
- What's wrong: the copy promises "Give the rooms new furniture and decor in a style you pick. Walls and
  windows stay exactly the same." and "Removes clutter and personal items from your listing photos with AI."
  Neither a video restage nor a photo declutter is triggered anywhere by these flags (the photo AI lives in
  `PhotoStudioView` and is independent). The only effect of toggling them is that the hosted tour of the
  *unaltered* video is labelled "Virtually staged" — an MLS/advertising disclosure that is now false in the
  other direction — and the Review screen's pipeline preview (`Render.pipelineSteps`, `Render.swift:114-120`)
  lists "Decluttering" / "Restaging · Modern" steps that never run.
- User-facing effect: an agent picks "Scandinavian", waits, gets their untouched walkthrough with a
  "✦ Virtually staged" chip on the public page; the in-app preview shows no chip, so they only discover it
  when a buyer asks. Reviewers will read the extras card as a feature that doesn't exist (App Store 2.3.1).
- Fix: Remove the extras card (and `priceSummary` rows, `pipelineSteps` entries) from the tour flow until a
  video declutter/restage pipeline exists; send `enhancements: {declutter:false, style:"as_is"}` from
  `publishTour` (keep the `Enhancements` type — it is persisted and Codable). If the intent is to keep a
  hook for *photo* declutter, move it into `PhotoStudioView` where `/ai-photo` is actually called. When a
  real video enhancement ships, inject `VIRTUALLY_STAGED = true` in `PlayerWebView.localPreviewHTML`
  (replace the `const VIRTUALLY_STAGED = false;` literal) so the preview matches the hosted page.

### F-B-03 · P0 (verify) / P1 · `demo.mp4` is not in the repo, and the missing-demo fallback loads the un-adapted real-estate template
- Where: `Screens/PlayerWebView.swift:35-43` (fallback branch), `96-98` (`demoHTML` returns nil when
  `demo.mp4` is absent); `Resources/player/` contains only `index.html`; `git ls-files` has no `*.mp4`
  anywhere although other binaries (png/webp) are tracked; `apps/web/player/README.md:13` and
  `docs/context/RENDPROP-CONTEXT.md:135` claim it ships.
- What's wrong: if the file is absent from the build (any fresh clone / CI / new machine), `demoHTML` is
  nil and `makeUIView` falls through to loading the raw `index.html`. That page hard-codes "1247 Hillcrest
  Drive", "$1,175,000 · 4 bd · 3 ba", "Sarah Mitchell / Demo Realty Group", "Book a showing", real-estate
  chapters, and `src="demo.mp4"` (404 → loader spins, then `begin()` fires at 12 s onto a black stage).
  So a gym owner's sample tour and the Home tab's "See it in action" show a house, a realtor and a dead video.
- User-facing effect: the "each type feels like its own app" promise breaks on the very first screen; the
  in-app sample is the only thing a new user can play before recording.
- Fix: (1) Confirm `demo.mp4` is committed under `apps/ios/Rendprop/Resources/player/` (folder resource,
  already in `project.yml`). (2) Make the fallback honest: if the demo video is missing, still run the
  type-adaptation on the template (split `demoHTML` into `adaptTemplate(...)` + optional video copy) and
  show a "Sample video unavailable" state instead of the raw template; never load `index.html` untouched.

### F-B-04 · P1 · `RenderStatusView.onAppear { start() }` is unguarded — every re-appearance re-renders and re-publishes (and re-runs the paid AI enhance)
- Where: `Screens/RenderStatusView.swift:190` (`.onAppear { start() }`), `199-205` (`start()`), `207-237`
  (`runRealRender` cancels `pollTask` and starts a fresh encode), `225-226` (then `beginPublish` again).
- What's wrong: `onAppear` fires again when the user taps back from "View my tour" (`FlythroughDetailView`
  is pushed on top, 147-148), or leaves the tab and comes back. `start()` has no "already ran" guard, so the
  asset is re-encoded from 0 %, then `runPublishPipeline` runs again → for Smooth a second
  `create_render_job` + `publish_render` (new slug overwrites `listing.shareSlug`; the previously shared link
  now points at an older render row), for 4K/Cinematic a second `/ai-video/drone` submission (Topaz quota +
  real money) and a second 20-minute wait, plus the sign-in sheet again if the user had declined.
- User-facing effect: the ring visibly restarts at 2 % after backing out of the tour; links already sent to
  buyers change under them; AI quota burns.
- Fix: add `@State private var didStart = false` and `guard !didStart else { return }; didStart = true` in
  `start()`; or switch to `.task` keyed on the render id and make `runRealRender` a no-op when
  `renderOutput != nil` (re-show the ready state instead). Never re-publish a listing that already has
  `serverShareURL` from this screen.

### F-B-05 · P1 · Render failure / cancellation / app kill leaves the listing stuck at "Working on it" with no retry and no delete
- Where: `Screens/RenderStatusView.swift:191` (`onDisappear` cancels the render — fires on tab switch,
  "Watch the intro again", account deletion, etc.), `230-235` (catch sets `failureMessage` only),
  `86` (the title becomes the error text, no action); `Screens/ReviewSubmitView.swift:347` (status set to
  `.processing` before the render); `RendpropApp.swift:44-63` (status is persisted; no recovery on load);
  `Screens/FlythroughDetailView.swift:205-251` (toolbox has no "render"/"create tour" action);
  `HomeListingsView.swift` / whole app (no delete-listing anywhere: only `SettingsView.wipeLocalData` 319-349).
- What's wrong: `RenderEngine` errors (`noVideoTrack`, `cannotBuild` for ≤0.2 s clips, writer failures,
  cancellation) show "Could not prepare the render." / "Render cancelled." with the back button now visible
  and nothing else. The listing keeps `status = .processing` forever; the card says "Working on it"; the
  detail page plays the raw capture and offers no way to render, and there is no way to remove the listing.
  App killed mid-render → identical state on relaunch (asset persisted, tour absent).
- User-facing effect: permanent "Working on it" cards that never finish; the only fix is Delete account.
- Fix: (1) On failure set the listing back to `.draft` (or a new Optional `lastError: String?`) and show a
  "Try again" button that calls `runRealRender` again. (2) In `FlythroughDetailView`, when `asset != nil &&
  tour == nil`, show "Create tour" → `ReviewSubmitView(listing:asset:)`. (3) On `AppModel.load()`, downgrade
  any `.processing`/`.uploading` listing that has no `tours[id]` to `.draft`. (4) Add `AppModel.delete(id:)`
  (remove listing + asset/tour files + `Photos/<id>` dir) with a swipe/`contextMenu` on `ListingCard` and a
  destructive button in the Manage card; server-side `DELETE /listings/:serverID` when `serverID != nil`.

### F-B-06 · P1 · Draft listings are created before any video exists; cancelling the picker leaves a permanent "Not finished" card that cannot be finished
- Where: `Screens/NewListingView.swift:84, 94` (`prepareListing()` runs on button tap), `297-310`
  (`model.add(listing)` inserts + persists immediately), `340-343` (`receive` only navigates);
  `DesignSystem/Theme.swift:72` ("Not finished" label); `FlythroughDetailView` has no add-video path.
- What's wrong: tapping "Upload a video" then cancelling the Photos/Files picker, backing out of the capture
  screen, an import failure (`importFailed` alert 226-230), or simply leaving `NewListingView` all leave a
  `.draft` listing with no asset. The user sees a card "Not finished"; opening it shows "SAMPLE TOUR — record
  a walkthrough to see your own home here" with no button to do so. Every retry from the list creates another
  orphan. Because `createdListing` is per-form-instance, coming back via the "+ New Home" button starts a new
  listing rather than continuing the draft.
- User-facing effect: a growing pile of dead "Not finished" cards the user can neither complete nor delete.
- Fix: create the listing in `receive(_:)` (after an asset exists) — keep `prepareListing()` for validation
  only; or, if drafts are desired, give drafts a real continuation (detail page "Add video" → the same
  picker/capture → `ReviewSubmitView`) plus delete (F-B-05). Also re-apply `pendingCoord` in the re-sync
  branch (`281-295` drops latitude/longitude captured after the first tap).

### F-B-07 · P1 · Real-estate stepper defaults (3 bd / 2 ba) become facts on the card, the server and the public page
- Where: `Screens/NewListingView.swift:16-17` (`beds = 3`, `baths = 2.0`), `297-301` (stored as-is when
  `isRE`); `Models/Listing.swift:100-106` (`metaLine` shows whatever is stored, never hides zeros);
  `Networking/LiveAPIClient.swift:411-412` (`beds`/`baths` sent when > 0); `tour-host/src/player.ts:100-104`
  (hosted chip prints them).
- What's wrong: the "Home details (optional)" disclosure is collapsed by default; a user who never opens it
  publishes "3 bd · 2 ba" for a 5-bedroom house. The code comment (273-274) protects venues from the default
  but not real estate, where it matters most.
- User-facing effect: wrong bedroom/bath counts on the card, the og:description and the shared tour.
- Fix: default `beds = 0`, `baths = 0`, treat 0 as unset everywhere: `metaLine` should build parts only for
  > 0 like `PlayerWebView.metaText` (320-331) already does; `Stepper` labels "Bedrooms: —" when 0.

### F-B-08 · P1 · The cellular/Wi-Fi guard is a lie in live mode: "Wait for Wi-Fi" is ignored and the real (larger) upload is forced onto cellular with no cancel
- Where: `Screens/ReviewSubmitView.swift:51-59, 329-350` (prompt sized on the RAW capture; `cellularApproved`
  is unused in the `Config.useLiveBackend` branch); `Upload/UploadManager.swift:225-250`
  (`upload(...)` forces `cellularApproved: true`); `Screens/RenderStatusView.swift:189` (back button hidden
  while publishing), no cancel control; `SettingsView.swift:61` ("Only upload big videos on Wi-Fi" toggle).
- What's wrong: in the shipping configuration nothing is uploaded at submit time; the thing that is uploaded
  later is the all-intra render (14 Mbps → roughly 50–100 MB per source minute) or a multi-GB Topaz 4K file,
  and it goes out on cellular regardless of the user's setting or their "Wait for Wi-Fi" answer. The prompt's
  message ("Upload now on cellular, or queue it for Wi-Fi?") describes an upload that doesn't happen. In the
  mock path "Wait for Wi-Fi" queues an upload that no view can ever release (`pendingCellularConfirmation` /
  `confirmCellularAndStart` have no callers).
- User-facing effect: surprise cellular data use of hundreds of MB to GBs; a user who chose "Wait for Wi-Fi"
  gets exactly the opposite; no way to stop it once the status screen hides the back button.
- Fix: move the cellular decision to `performPublish`/`enhanceThenPublish` using `FileStore.fileSize(output.url)`
  (and honour `wifiOnlyUploads`); if not approved, mark the tour ready-but-unpublished and offer "Publish on
  Wi-Fi" (needs F-B-01's publish action); add a Cancel to the status screen that calls `uploads.cancel()`.
  Remove the submit-time prompt or reword it to what actually happens.

### F-B-09 · P1 · "4K Premium" and "Cinematic AI" are the same job on a 720p master → 1440p output; copy says "true 4K"; scrub master is no longer all-intra
- Where: `Screens/RenderStatusView.swift:291-295` (`tierParam` "4k30"/"4k60" but `targetFps: 60` for both),
  `278` ("upscaling to 4K on our render farm"); `services/supabase/functions/ai-video/index.ts:199-213`
  (`upscale_factor = 2` for any non-1080p tier, fps taken from `target_fps`, tier otherwise ignored;
  `H264_output: true` = normal-GOP H.264); `Render/RenderEngine.swift:64` (`encodeLongEdge = 1280` →
  1280×720 master is what gets uploaded, `RenderStatusView.swift:285-289`); `Models/Render.swift:75-84`
  (blurbs "true 4K upscale", "4K upscale at 60fps"); `RenderStatusView.swift:350-352` (the Topaz file
  replaces the local scrub master for in-app playback).
- What's wrong: the original 4K capture is thrown away; a 2× upscale of 1280×720 is 2560×1440. Both AI tiers
  produce byte-identical requests, so the tier picker is a distinction without a difference. The
  Topaz output is not all-intra, so both the in-app WKWebView scrub and the hosted `scrub_url` lose the
  frame-accurate scrubbing the engine went to great lengths to produce (needs a device check, but
  `H264_output` alone won't produce keyframe-per-frame).
- User-facing effect: users pick the "premium" tier and get a softer 1440p file that scrubs worse than the
  free tier, and they wait up to 20 minutes for it.
- Fix: for the AI tiers upload the ORIGINAL capture (`asset.localURL`, role=render) or render a higher-res
  master (e.g. `encodeLongEdge = 2160/3840` for those tiers); make the tiers actually differ
  (premium4k → `tier:"4k30", target_fps: 30`; cinematic → `"4k60", 60`) or collapse to one tier; either
  re-encode the Topaz result all-intra on device (an `AVAssetExportSession`/writer pass with
  `AVVideoMaxKeyFrameIntervalKey: 1`) before publishing or publish it as the HLS/high-bitrate rendition and
  keep the on-device all-intra file as `scrub_url`. Fix the blurbs to the real output.

### F-B-10 · P1 · Files import overwrites any earlier import with the same filename (second listing silently replaces the first listing's video)
- Where: `Import/MediaImporter.swift:157-158` (`dest = importsDir/<original name>`, `removeItem(at: dest)`
  then move) — triggered from `Screens/NewListingView.swift:212-220`.
- What's wrong: drone exports are named `DJI_0001.MP4`, `DJI_0002.MP4`…; re-exports collide. Importing a
  second file with the same name deletes the first listing's source video (its `asset.localURL` now points
  at the new content, or at nothing until the move lands) and its `preview-<name>.html`. The Photos path
  avoids this with a UUID prefix (105); the Files path does not. If the move fails, `onPicked(url)` keeps a
  temp-inbox URL that iOS purges — `PersistentStore.load` then drops the asset on next launch (F-B-05 state).
- User-facing effect: "same video twice" or two drone clips with the same name → one listing's tour source
  is silently swapped or lost.
- Fix: name the destination `import-<uuid8>-<name>` like the Photos path; on move failure copy into Imports
  (never keep the inbox URL).

### F-B-11 · P1 · The sign-in gate sits after a multi-minute render and "Not now" is a one-way door
- Where: `Screens/RenderStatusView.swift:242-248` (`beginPublish` shows the sheet only after the render),
  `413-416` ("Not now" → `publishFailed`), `SignInView` 498-503 (requests `.fullName`/`.email`, never reads
  `credential.fullName`/`email` — `AuthStore.userName` stays "Dev Agent" so Settings shows the generic
  "Signed in with Apple").
- What's wrong: the user learns publishing needs an account only after waiting for the encode; declining
  has no recovery (F-B-01). The scopes are collected and discarded (Apple only returns the name once, on the
  first authorization — it is lost for good).
- User-facing effect: dead-end tours; account row never shows the user's name.
- Fix: gate at "Create my tour" (or at least tell the user before the render that publishing needs sign-in
  and keep a Publish button, F-B-01); store `credential.fullName`/`email` into `AuthStore.userName`
  (UserDefaults key already exists) or drop the scopes.

### F-B-12 · P2 · Navigation stack is never unwound after success; two independent entry points allow duplicate/parallel renders
- Where: `Screens/RenderStatusView.swift:147-148` (pushes the detail on top; New → Review → Status stay
  below); `Screens/ReviewSubmitView.swift:36-38` (re-tapping "Create my tour" after backing out re-renders
  and re-publishes the same listing, new slug); `RendpropApp.swift:566, 673` (Home tab has its own
  `NewListingView` in a separate `NavigationStack`); `UploadManager.swift:232-234` (`.busy`).
- What's wrong: after "Your tour is ready", back-taps land on Review & Submit and New Listing for the same
  listing; each re-submit creates a new server render job and overwrites `shareSlug`. Starting a second
  listing from the Home tab while one renders on the Listings tab runs two encoders concurrently and the
  second publish fails with `.busy` (→ F-B-01 dead-end).
- Fix: pop to root on "View my tour" (e.g. `@Binding path`/`NavigationPath` owned by `HomeListingsView`, or
  present the flow as a `fullScreenCover` that dismisses on completion); disable "Create my tour" when the
  listing already has a tour and offer "Re-render" explicitly; queue publishes in `UploadManager` instead of
  throwing `.busy`.

### F-B-13 · P2 · Sample listings get new UUIDs every launch/type switch; tools opened on a sample orphan data; sample banners point at actions that don't exist
- Where: `Models/Listing.swift:415-476` (`sampleListings` constructs fresh `Listing()` → new `id` each
  call), `RendpropApp.swift:57-62, 68-71` (`load`/`reseedSamples`); `FlythroughDetailView.swift:213-249`
  (Photos, Reel, Floor plan, Aerial, Mark as sold, Zillow all enabled on a sample), `185-203` (sample detail
  banner "Create your tour and it becomes a live rendprop.com page" — no button), `RendpropApp.swift:743-748`
  (Home "Share & Leads" banner opens the sample's detail); `Listing.swift:421-422` (the second RE sample is
  permanently `.processing` → card "Working on it" with no play overlay, no explanation).
- What's wrong: a user who adds photos, a floor plan or "Mark as sold" to a sample loses it at next launch
  (`Documents/Photos/<old-uuid>/` is orphaned; the sold sample reappears). The "Working on it" sample looks
  like a stuck render. Sample screens tell the user to "create your tour" where no create action exists.
- Fix: give samples deterministic ids (`UUID(uuidString: "00000000-0000-0000-0000-00000000000\(n)")` per type),
  gate photo/floor-plan/aerial/manage tools on `!listing.isSample` (route to `NewListingView` with an honest
  "Samples are read-only — create your own" note), drop the `.processing` sample or label it "Sample render in
  progress", and turn the detail banner into a button (`NewListingView` for samples, Publish for real ones).

### F-B-14 · P2 · The in-app end card is a fake lead form with no preview marker, and it no longer mirrors the hosted page
- Where: `Resources/player/index.html:433-441` (submit → `localStorage` only → "Request sent"), `229-236`
  (phone is plain text, no `tel:`; no `mailto:` — `AgentCard.email` is never injected anywhere in
  `PlayerWebView`); `PlayerWebView.swift:337-357` (`adaptCopy` only swaps label/sub); compare
  `services/edge/tour-host/src/player.ts:50-79, 142-259` (tel/mailto links, deep-link CTA mode for
  `bookingUrl`/`reservationUrl`/`onlineStoreUrl`/`website`, per-type extra lead fields, secondary links).
- What's wrong: an agent demoing in-app (or a buyer handed the phone) submits a "lead" that goes nowhere and
  sees "Request sent". For a restaurant with a reservation URL the in-app preview shows a lead form while the
  public page shows a "Reserve your table" deep-link button; onboarding promises "every viewer can reach you
  in a tap" but the in-app card's phone isn't tappable.
- Fix: inject a visible "Preview — form disabled" state (`<form data-preview>` + disabled submit) in
  `localPreviewHTML`/`demoHTML`; add `tel:`/`mailto:` anchors for `agent.phone`/`agent.email`; mirror the
  hosted CTA logic (deep-link when `listing.actionURL != nil`) so preview == published page.

### F-B-15 · P2 · "Drone" is inferred from which picker was used and cannot be corrected
- Where: `Screens/NewListingView.swift:184-191` (Photos → `isDrone=false`, "A file or drone clip" →
  `isDrone=true`), `198, 215`; `Screens/ReviewSubmitView.swift:88-90` (read-only "Drone — skips
  stabilization"); `Render/RenderEngine.swift:101-102, 114` (drone → no stabilization, 1.25× instead of 2×).
- What's wrong: DJI/Insta360 clips usually live in Photos (→ stabilized + 2× "walk" retime, wrong), while any
  handheld clip opened from Files (AirDrop, iCloud Drive) is treated as drone (→ no stabilization, wrong).
- Fix: ask explicitly ("Was this shot on a drone?") or make it a toggle on the Review "YOUR VIDEO" card
  (`asset.isDrone` is already `@State`-mutable there).

### F-B-16 · P2 · Preview HTML leaks the sample's tagline into a real non-real-estate listing and shows demo chapters on real drafts
- Where: `Screens/PlayerWebView.swift:129-131` (`sub` falls back to `sample?.tagline` for a REAL listing
  with an empty tagline), `111-118` (RE/other quickTags as chapters on the demo reel shown for any real
  listing whose tour isn't ready).
- User-facing effect: "The Workshop" (real) shows "Creative studio & community space" (the sample's line)
  under its name; a real home's placeholder tour narrates "Living Room / Kitchen…" over the demo footage.
- Fix: only fall back to the sample tagline when `listing?.isSample != false`; for real listings without a
  tour, prefer an honest "Your tour will appear here" stage over the demo reel (or keep the reel but label it).

### F-B-17 · P2 · Onboarding tells users the business type can be changed "in Settings"; Settings has no switcher
- Where: `Screens/OnboardingView.swift:106`; `Screens/SettingsView.swift:32-44` (read-only row whose footer
  redirects to the Home tab); the actual switcher is the Home tab toolbar menu (`RendpropApp.swift:508-538`).
- Fix: either put a `Picker` in the Settings "Business type" section (calls `model.reseedSamples()` on change
  like the Home menu) or change the onboarding copy to "from the Home tab".

### F-B-18 · P2 · The empty state is unreachable, pull-to-refresh is a no-op, search has no empty result
- Where: `Screens/HomeListingsView.swift:30-33` (`emptyState` only when `model.listings.isEmpty`, but
  `AppModel.load` 57-62 always appends ≥1 sample per type), `55` (`.refreshable { await model.load() }` —
  `load()` is guarded by `hasLoaded`, so refresh does nothing; `api.listings()` is never called anywhere),
  `41-48` (no "No matches" row when `filtered` is empty).
- User-facing effect: the per-industry first-run moment ("Your first tour is 10 minutes away") never shows;
  the refresh spinner is a placebo; searching for something absent shows a blank list.
- Fix: decide whether samples should exist at all on first run (if yes, delete `emptyState` and the
  `Start filming` copy; if no, seed samples only into the Home tab demo and let the list be truly empty);
  either remove `.refreshable` or make it pull server listings when signed in; add an empty-search row.

### F-B-19 · P2 · No import validation: 0-second / trackless files reach Review ("0:00 · 0p · 0 fps") and die at render; no max-duration guard; "Length band" is a pricing leftover
- Where: `Import/MediaImporter.swift:36-46` (probe failures → zeros, no error), `Screens/ReviewSubmitView.swift:79`
  (renders the zeros), `23, 292-295` (`PricingBand` "Up to 90 seconds … 6 – 10 minutes" — a 15-minute clip is
  labelled "6 – 10 minutes"; the row means nothing now that tiers are "Included"); `Render/RenderEngine.swift:98`
  (throws `cannotBuild` for ≤0.2 s — which then hits F-B-05); server `publish_render` rejects `duration_s > 7200`.
- Fix: validate in `NewListingView.receive` (duration ≥ 1 s, has video track, ≤ a product max) and alert;
  drop the "Length band" row or rename it to a plain "Length: 3:20" line.

### F-B-20 · P2 · Upload engine side-effects around publish: failed uploads auto-resume with no consumer, block the next publish, and the AI-enhance master is uploaded twice
- Where: `Upload/UploadManager.swift:342-362` (`onNetworkRegained` resumes `.failed` uploads whose awaiting
  continuation already failed → orphan role=render asset on the server, and `.busy` for the next
  `upload()` while it runs, 232-234); `Screens/RenderStatusView.swift:285-289` vs `RendpropApp.swift:146-149`
  (skip/fallback path uploads the same `output.url` again for publish instead of reusing `assetID`);
  `337-346, 360` (Topaz result is downloaded to the phone, then re-uploaded to R2 — a multi-GB round trip).
- Fix: when `upload()` fails, `cancel()` the engine state (or mark it "abandoned") so it doesn't resume;
  let `publishTour` accept an existing `assetID`; have the server ingest the fal result URL directly into R2
  (server-side copy) and return the asset id.

### F-B-21 · P2 · Capture "X" while recording does not cancel — it finalizes and pushes Review & Submit
- Where: `Capture/CaptureView.swift:69-78` (`if isRecording { camera.stopRecording() }` with accessibility
  label "Stop and close"), `240-263` (`handleFinished` → `onComplete` → `NewListingView.receive` → Review).
- User-facing effect: a user who taps X to abandon a bad take is pushed into Review with the partial clip and
  a listing already created (F-B-06).
- Fix: X while recording → stop + discard (delete the file) and dismiss; keep "never lose footage" for
  interruptions, not for an explicit cancel. Or present a "Keep / Discard" dialog.

### F-B-22 · P2 · Listing cards decode full-size hero JPEGs synchronously on the main thread
- Where: `Screens/HomeListingsView.swift:271` (`UIImage(contentsOfFile:)` inside `body`, per card, per
  re-render, in a `LazyVStack`).
- Fix: cache a downsampled thumbnail (e.g. `CGImageSourceCreateThumbnailAtIndex` at ~800 px) next to the
  main photo when it is set, or load with `.task` into `@State`.

### F-B-23 · P2 · `Watch the intro again` swaps the root and tears down in-flight work
- Where: `Screens/SettingsView.swift:125-129` (`hasOnboarded = false` swaps the root → `RootTabView` is
  destroyed → any `RenderStatusView` gets `onDisappear` → render cancelled, F-B-05); `OnboardingView.swift:148-150`.
- Fix: present the intro as a sheet/cover over the tab view instead of swapping the root (or confirm when a
  render/publish is running).

### F-B-24 · P3 · Form/parsing polish in New Listing
- `NewListingView.swift:47-50` `.textContentType(.fullStreetAddress)` on a field labelled "Name or address"
  for venues/gyms (address autofill for a business name); `152` the non-RE description placeholder is always
  "Rooftop cocktail bar" (gym/grocery/other); `134-137, 286-287` `Int(priceDollars)` silently drops "1,200,000"
  pasted with commas or "$"; `Models/Listing.swift:128, 139` same for `startingPrice`/`membershipPrice`
  chips (`Int("3,500")` → no chip); `Models/Listing.swift:100-106` `metaLine` prints "0 bd · 0 ba" for land/lots.
  Fix: strip non-digits before `Int()`, per-type placeholders, hide zero parts.

### F-B-25 · P3 · Chapter/tag edge cases
- `ReviewSubmitView.swift:547-552` duplicate tags at the same `tMs` (two taps) → two dots, second never
  activates (`index.html:323-327` strict `<`); `PlayerWebView.swift:372-377` `jsLabel` deletes apostrophes
  ("Kid's Room" → "Kids Room") instead of escaping `\'`; >60 tags are silently truncated by the server
  (`renders/index.ts:38`) while the in-app preview shows all; when the first tag is at t > 0 the first rail
  dot is "active" from 0 s (`updateOverlays` default `active = 0`); no in-player error state when the video
  fails to load (12 s timeout to a black stage, `index.html:387`).

### F-B-26 · P3 · `runSimulation` is unreachable dead code that would spin forever in live mode
- `RenderStatusView.swift:199-205, 426-445`: `ReviewSubmitView.start` always stores the asset first, so the
  `else` branch never runs; if it ever did on live, `GET /renders/<local uuid>` 404s every 0.7 s with
  "Queued…" and no exit. Remove it or gate on `listing.isSample` with a local timer.

### F-B-27 · P3 · Mock-only leftovers in the live flow
- `ReviewSubmitView.swift:353-376`: in mock mode the raw capture is "uploaded" (simulate) and a server
  `Render` is created that nothing reads; the mini-bar shows "Sending your video…" for a fake upload.
  `AppModel.renders` is never written by any view (persisted but always empty). `index.html:273` `SLUG='demo'`
  and the localStorage beacon are inert in-app (fine, but note for anyone expecting metering from the app).

### F-B-28 · P3 · Minor UX / copy
- `OnboardingView.swift:18-20` "your phone scans a real floor plan" — LiDAR-only (Pro models); `RenderStatusView.swift:92`
  subtitle shows the source length ("3:20 walkthrough") while the tour is half that; `RenderStatusView.swift:189`
  hides Back for the whole ≤20-min AI wait (Skip exists, but no Cancel during the plain publish upload);
  `NewListingView.swift:104-118` if the Photos export never calls back, `importProgress` stays non-nil and
  both buttons remain disabled; `HomeListingsView.swift:58-60` + `RendpropApp.swift:514` double
  `reseedSamples()` on a type change (harmless); `PlayerWebView.swift:34` grants WKWebView read access to
  the whole Documents directory for enhanced-tour previews (`enhanced-*.mp4` lives at the root) — move
  enhanced files into `Recordings/`.

## Verified OK
- Chapter timebase is consistent: capture-time `tMs` ÷ `speedFactor` in `FlythroughDetailView.playbackTags`
  (107-113), in `AppModel.publishTour` (158-164) and the hosted player uses `t_ms/1000` directly
  (`player.ts:17-20, 1064`) — no double scaling; sort index = sorted order; empty tag list → no rail.
- All navigation in the slice is destination-based (`NavigationLink { … } label: { … }`,
  `navigationDestination(isPresented:)`); no `NavigationLink(value:)` for `Listing`.
- No digital-goods prices anywhere in the slice ("Included", "Early access", "Included with early access.").
- `index.html` injection map — literal placeholders: `<!--SOCIAL-->` (filled only when `agent.isSet`,
  otherwise hidden via `.social:empty`, comments don't count as content), `<!--ZILLOW-->` (RE + zillow set,
  local preview only). Literal swaps: title/og "1247 Hillcrest Drive" (all types), og "this home" → "this
  venue/place/…", "$1,175,000" (price or hidden), "4 bd · 3 ba · 2,850 sqft" (RE parts > 0 / tagline),
  `src="demo.mp4"` (local only, percent-encoded + HTML-escaped), `const CHAPTERS = […]` (both), "Sarah
  Mitchell"/"Demo Realty Group · (555) 012-3456"/`>SM<`/avatar (agent / hidden for real listings without a
  card / business identity for non-RE samples), "Book a showing" ×2 → `ctaTitle`, form sub + confirmation
  sentence → per-type copy, "Sarah will" → first name / "We'll". Every swap is `htmlEscape`d; chapter labels
  go through `jsLabel` (quote/backslash/angle-bracket stripped) so a custom room name cannot break out of the
  inline script or inject tags. Unfilled by design: `VIRTUALLY_STAGED` (see F-B-02), `SLUG`.
- `PlayerWebView.Coordinator`: `.linkActivated` and non-web schemes open externally and are cancelled;
  `createWebViewWith` returns nil after opening the URL — target=_blank links are not dead; initial
  `file://`/remote loads arrive as `.other` and are allowed.
- `demoHTML` copy ordering: `adaptCopy` runs before the address/agent swaps so the full demo sentences still
  match; RE real listing over the demo reel gets its own price/meta; real listings never show the demo agent.
- Sign in with Apple: fresh nonce per request, SHA-256 hex sent as `request.nonce`, raw nonce sent to
  Supabase `grant_type=id_token`; `authorizationCode` forwarded to `/me/apple-code` after the session exists;
  user cancel is not surfaced as an error; exchange errors are shown; tokens in Keychain; sheet cannot be
  swiped away mid-exchange; publish resumes in `onDismiss` only when signed in and not already ready.
- Onboarding cannot trap: default type is preselected, "Get started" is always enabled, pages advance by
  button or swipe; "Watch the intro again" flips `hasOnboarded` and the root swaps to the intro and back.
- `HomeListingsView` observes `space.type` so filtering/title/tab identity update live; samples are reseeded
  on type change; sold folder counts per type; samples are never persisted (`PersistentStore.save` filters
  `isSample`, `load` re-appends).
- `NewListingView.formValid` requires a non-blank address/name only (sensible for every type); property
  fields are optional; non-RE listings store `beds/baths/sqft/price = 0`; `spaceTypeRaw` stamped; tagline/
  details trimmed and nil-when-empty; re-sync branch updates an already-created draft's fields.
- `OneShotLocation`: handles `.notDetermined` → delegate → `requestLocation`, denied/restricted → nil,
  `NSLocationWhenInUseUsageDescription` present; only a 3-decimal coarse fix is stored; `LiveAPIClient`
  coarsens again on the wire.
- Photos import shows real progress, disables both buttons during copy (no double import), surfaces failure
  with an alert; imports are copied into the app container (no in-memory loads).
- `RoomTaggerView`: periodic observer removed in `teardown`, exact-tolerance seeks, slider guarded before
  duration loads, list sorted by time, removal by id.
- Review "YOUR VIDEO" summary matches the engine (drone → "skips stabilization" → engine skips pass 1).
- `RenderEngine` cancellation is bridged into the AVFoundation queues (`CancelFlag`); partial output is
  deleted on failure/cancel; output is Rec.709-tagged all-intra H.264 at 60 fps.
- `RenderStatusView`: local tour is stored in `model.tours` before publishing (local-first survives a
  publish failure or kill); the Share button appears only with a real server `serverShareURL` (no fabricated
  slugs); "Skip AI enhance" breaks the poll loop within ≤6 s and publishes the standard render; 20-minute
  deadline; every enhance failure falls back to the standard publish; `CancellationError` is swallowed when the
  view is gone; `publishFailed` and `enhanceNote` never stack.
- Persistence: assets/tours stored as Documents-relative paths, missing files dropped on load, tolerant
  field-by-field decoding for `Listing`, `Render`, `Enhancements`, persisted state, upload state.
- `Listing.serverShareURL` prefers the server `shareURL`, falls back to `https://rendprop.com/f/<slug>`; nil
  until published.

## Open questions / needs product decision
1. Should publishing require sign-in *before* the render ("Create my tour" gate) or stay post-render with a
   persistent "Publish" action? (Either way F-B-01 needs a re-runnable publish.)
2. Are the AI tiers meant to enhance the ORIGINAL 4K capture (contract §3 says the source is uploaded only
   when AI/4K is requested) or the 720p scrub master? Today it's the master. Should 4K Premium and Cinematic
   remain two tiers at all?
3. Should the extras card (declutter/restage) be hidden entirely until a video pipeline exists, or kept as
   a photo-studio shortcut? It must stop flipping `staged` either way.
4. Do we want drafts (listing without video) as a concept? If yes, they need "Add video" + delete; if no,
   create the listing only after a video is chosen.
5. Listing deletion: local only, or also `DELETE /listings/:id` (unpublishing the hosted tour)? There is
   currently no delete at all, and no `updateListing`/`listings()` call anywhere — sold status, Zillow and
   detail edits never reach the server, and a reinstall cannot recover listings that were published.
6. Should samples be visible in the collection at all once a user has a real listing, and should sample
   tools be read-only?
7. `demo.mp4`: is it intentionally untracked (size)? If so, add it to the build via a documented step;
   otherwise commit it.
8. Storage policy: three video copies per listing (source, all-intra master, enhanced 4K) in Documents with
   no cleanup and no `isExcludedFromBackup` — acceptable for early access?
