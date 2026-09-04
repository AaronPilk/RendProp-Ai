# Findings — A · Listing detail (`apps/ios/Rendprop/Screens/FlythroughDetailView.swift`, 3,283 lines)

## Summary
The screen is well-built at the presentation level, but almost every tool on it is an **island**: it produces a file on the phone and then the app forgets it. Nothing generated here — enhanced photos, main photo, floor plan, reel, aerial, Zillow link, sold state, post-publish room tags — ever reaches the hosted share page, even though the tour-host already has slots for `gallery`, `floorplan_url`, `reel_url`, `zillow_url`, and `updateListing`/`beginPhotoBatch` exist in the code with zero callers. The Aerial intro is the worst case: the sheet collects a free-text "look" and a length, the client sends only `{seconds, aspect, style?}`, the server builds a fixed text-to-video prompt for "a beautiful residential property", and the address, main photo, coordinates and business type are never used — so the clip cannot be of this property, the copy ("inspired by the address", "made to sit in front of your tour") is untrue. Dead-ends: no "Publish" when the local tour exists but publish failed/was skipped, no "add video" for a video-less listing, no edit/delete of a listing at all. Defects: `isProcessing` stuck forever when a photo animation is cancelled by `onDisappear` (fires on every fullScreenCover), heavy image encode/decode on the main actor, server error bodies discarded ("Server returned status 402"), "Saved to Photos" reported unconditionally.

## Findings (most severe first)

### F-A-01 · P0 · Aerial intro cannot know which property it is — nothing that identifies the listing is ever sent
- Where: `FlythroughDetailView.swift:1438-1716` (AerialIntroSheet), esp. 1444-1445 (only `seconds` + `styleHint` state), 1662-1664 (`aiVideoAerial(style:prompt:nil,seconds:aspect:"16:9")`); `LiveAPIClient.swift:316-327` (body = `seconds`, `aspect`, `style?` only); `ai-video/index.ts:244-290` (`address` "accepted for back-compat but ignored"; fixed t2v prompt; `falSubmit(MODEL_AERIAL, {prompt, duration, resolution, aspect_ratio, generate_audio})` — no `image_url`).
- What's wrong: user can enter one free-text "LOOK & FEEL" (truncated to 200 chars) and 4/6/8 s. No address, no photo, no time of day, no camera move, aspect hard-coded "16:9", no business type. `prompt` always nil. `listing` used only for the output filename. Backend prompt: "Cinematic aerial drone establishing shot … toward a beautiful residential property …" to `fal-ai/veo3.1/fast` pure text-to-video. `Listing.address` deliberately dropped (Veo safety filter note); `mainPhotoRelPath` never read; `latitude/longitude` (geocoded on this very screen :401-411) never read; `SpaceType` never sent, so a venue/restaurant/gym gets a house. The original spec (`docs/MASTER-BUILD-PROMPT.md:744-747`) required "i2v from a real exterior frame".
- Fix:
  - Model (`Models/Listing.swift`, all Optional): `exteriorPhotoRelPath: String?`, `regionLabel: String?` (city/state from the geocode placemark — never the street), `aerialRelPath: String?`, `aerialGeneratedAt: Date?`. `AppModel`: `setExteriorPhoto`, `setAerial`, `setRegion`. In `geocodeIfNeeded()` also store `placemark.locality`/`administrativeArea`.
  - AerialIntroSheet form: "THE PROPERTY" card: exterior-photo thumbnail defaulting to `mainPhotoURL`, else newest `enh-*.jpg`; "Choose exterior photo" (reuse `LibraryImagePicker`, limit 1) and "Take a photo" (reuse `CameraPicker`); save to `Photos/<id>/exterior.jpg`. Empty → warning "Without a photo the AI invents a generic \(spaceNoun)". "TIME OF DAY": golden hour / midday / twilight / overcast. "CAMERA MOVE": descend & approach / orbit / rise & reveal / pull back. Keep free-text hint with `n/200` counter. FORMAT 16:9 / 9:16.
  - API: `aiVideoAerial(imageBase64:mime:spaceType:region:timeOfDay:motion:style:prompt:seconds:aspect:)`; body adds `image_b64`, `mime`, `space_type`, `region`, `time_of_day`, `motion` (downscale ≤1280 px / JPEG 0.85 like `animate()` :742-743).
  - Backend `/aerial`: extend `AerialBody`; resolve image as `/reel-clip` does (:299-310, bounded by `MAX_IMAGE_B64_CHARS`). Map `space_type` → subject noun. Prompt with image: "Cinematic drone establishing shot of THIS EXACT <subject> shown in the reference image — preserve architecture, roofline, facade colours, materials, windows, landscaping exactly; no morphing. Camera: <motion>. <time-of-day> light, <region> setting. Photorealistic, no people/text/logos. <style>". Without image: today's paragraph with subject noun + region.
  - Model choice: the only i2v endpoint proven in this repo is `fal-ai/bytedance/seedance/v1/pro/fast/image-to-video` with `{prompt, image_url, resolution:"1080p", duration:"<2..12>"}` (`ai-video/index.ts:134,313-318`); use it when an image is present, keep `fal-ai/veo3.1/fast` t2v as the no-photo fallback. Return `grounded: true|false` in the 202 body so the app can label "Based on your photo" vs "Generic scenery".

### F-A-02 · P0 (backend) · The quota table the aerial/reel/photo routes read does not exist in the repo → every aerial 402s unless created out-of-band
- Where: `ai-video/index.ts:104-110`; `_shared/entitlements.ts:37-47,55-74` (on lookup failure returns `TRIAL_FALLBACK`: `aerials_per_month: 0`).
- Fix: commit the missing migrations (see F report / reconstructed-migrations); make the fallback loud (503 "plans not configured").

### F-A-03 · P1 · The aerial's copy lies about what it does and where it goes
- Where: `:1468` ("inspired by the address"), `:1553` ("Landscape 16:9 — made to sit in front of your tour or social cut"), `:1537`.
- Fix: reword to truth after F-A-01; add real destinations (F-A-06).

### F-A-04 · P1 · Aerial/photo/reel failures show "Server returned status N" — server's `{error}` message discarded
- Where: `LiveAPIClient.swift:62-68` (`execute` → `APIError.badResponse(code)`); shown at `:1497-1506`, `:641-644`, `:2005-2011`.
- Fix: in `execute()` decode `{error}` on non-2xx → `APIError.server(status:message:)`; branch UIs: 402/429 show message and hide "retries are free"; 401 → Sign in; 409 → "already started".

### F-A-05 · P1 · Aerial job is lost on swipe-down / Close and never resumable
- Where: `:395-398` (no `.interactiveDismissDisabled(isGenerating)`); `:1517-1521`; `:1523` (`onDisappear` cancels); `:1660-1714`.
- Fix: `.interactiveDismissDisabled(isGenerating)`; confirm on Close; persist `{requestId, statusUrl, responseUrl, kind, listingID, submittedAt}` and resume polling; `isIdleTimerDisabled` while generating. Same for `ReelStudioView.generate()` (:2115) and `PhotoStudioView.animate()` (:740).

### F-A-06 · P1 · Aerial output is a dead-end: not attached to the listing, invisible after the sheet closes, overwritten on regenerate, no preview
- Where: `:1696-1699` (`Documents/aerial-<listingID>.mp4`, overwritten); `:1701-1704`; `:1609-1646` (Save + Share, no player); `:239-243` (tool card never reflects an existing aerial).
- Fix: `Listing.aerialRelPath` + `aerialGeneratedAt`; write to `Documents/Aerials/<id>-<stamp>.mp4`; sheet opens on the result when one exists (inline `VideoPlayer`, Save, Share, "Regenerate" keeps old until new lands); card sub-label "Aerial ready". Destinations: ReelStudioView toggle "Open with your aerial"; `wipeLocalData` must remove `Documents/Aerials`.

### F-A-07 · P1 · Non-real-estate listings get a house (aerial + photo prompts)
- Where: `ai-video/index.ts:263-269`; placeholder `:1533`; `ai-photo/index.ts:97-143` (every prompt "real-estate photo"; staging = sofa/coffee table).
- Fix: send `space_type` on both routes; server maps to subject noun and type-aware staging sets; iOS type-aware copy in `emptyShowcase` (:898-924) and the wand dialog.

### F-A-08 · P1 · Detail screen dead-ends: tour exists but no share link → no way to publish; no video → no way to add one; no way to (re)render
- Where: `:185-203` (card with no button); `:128,138-142`; `:225-231`. `RenderStatusView.swift:387-396,413-416` says "share it later" — no UI. `NewListingView.swift:84-95,270-311` persists the listing before a video is picked.
- Fix: "Publish tour" button when `tour != nil && shareURL == nil` (sign-in gate → `model.publishTour`); "Add walkthrough video" when `asset == nil && !isSample`; "Create tour" when `asset != nil && tour == nil`; show `listing.status`.

### F-A-09 · P1 · Zillow link and Sold state never sent to the server (which is ready for both)
- Where: `:257-265`, `:280-284`; `RendpropApp.swift:89-98`; `LiveAPIClient.swift:405-421` (`listingBody` sends `sold_at` but not `zillow_url`); `updateListing` (`LiveAPIClient:109`) has zero callers and PATCHes `listings/<listing.id>` (local id) instead of `serverID`.
- Fix: add `zillow_url` to `listingBody`; in `setSold`/`setZillow` fire `api.updateListing` when `serverID != nil` using `serverID`.

### F-A-10 · P1 · Room tags edited after publish never reach the hosted tour
- Where: `:225-231, :390-394`; chapters go out once at publish (`RendpropApp.swift:151-171`).
- Fix: new `PATCH /renders/:id/chapters`; `APIClient.updateChapters`; on tagger dismiss if published, rescale by `speedFactor` and PATCH. Persist `PublishedTour.renderID`.

### F-A-11 · P1 · Enhanced photos, main photo, floor plan and reel never reach the share link (public page has slots)
- Where: photos `:437-1004`; `UploadManager.beginPhotoBatch` (:254) no callers; `main_photo_key` never sent (`LiveAPIClient.swift:439` TODO); floor plan `:2534-2780`; reel `:2143-2146`. Public page: `player.ts:705-719` (`details.gallery|photos`), `:736-753` (`floorplan_url`), `:801-813` (`reel_url`).
- Fix: `Listing.publishedAssets` (Optional struct) merged into wire `details`; Photo studio "Publish photos to my link" → `beginPhotoBatch` → PATCH; floor plan → PNG via `ImageRenderer` → upload → `floorplan_url`; reel → upload → `reel_url`.

### F-A-12 · P1 · Photo animation cancelled by any fullScreenCover → studio stuck "Animating photo…"
- Where: `:587` (`.onDisappear { animateTask?.cancel() }`), `:594`, `:608`, `:788-789` (`catch is CancellationError { }` never resets `isProcessing`).
- Fix: don't cancel in `onDisappear` (or guard with an `isPresentingCover` flag); reset `isProcessing = false` in the cancellation branch.

### F-A-13 · P1 · AI photo edits / suggestions / custom prompts / Animate have no sign-in gate → "status 401"
- Where: `:651-697, :702-726, :733-794, :1186-1216` call `model.api` unconditionally; compare `AerialIntroSheet :1454-1455,1567-1589`.
- Fix: shared sign-in gate; present `SignInView` when `!signedIn`.

### F-A-14 · P1 · No way to edit or delete a listing anywhere
- Where: Manage `:253-295`; no `removeListing` anywhere; server has `DELETE /listings/:id`.
- Fix: "Edit details" (reuse NewListingView's form) → `model.modify` + `api.updateListing`; "Delete listing" (confirm) → remove from all maps + files + `DELETE /listings/:serverID`.

### F-A-15 · P1 · "QR / More" produces no QR code
- Where: `:176-181` — a second `ShareLink`. Home promises "One link, QR, or export" (`RendpropApp.swift:818`).
- Fix: `CIFilter.qrCodeGenerator()` on `shareURL`, sheet with image + ShareLink.

### F-A-16 · P1 · "Saved to Photos" reported even when the save failed
- Where: `:1400-1402`, `:1616-1618`, `:1975-1977` (`UISaveVideoAtPathToSavedPhotosAlbum(path, nil, nil, nil); saved = true`).
- Fix: `PHPhotoLibrary.shared().performChanges` with completion; set `saved` only on success; Settings hint on denial.

### F-A-17 · P2 · Floor plan: 2D plan can't be exported; single room only; copy over-promises; 2D→3D toolbar transition drops the second cover
- Where: `:2658-2664`, `:2716-2732`, `:2634-2639`, `:2795-2887`, `:2657`, `:3147-3153`, `:3029/3070`, `:2726`.
- Fix: "Export as image" via `ImageRenderer`; per-room scans; label "this room ≈ N sq ft"; confirm before re-scan; chain covers via `onDismiss`.

### F-A-18 · P2 · Every tool runs on sample listings whose ids change every launch → outputs orphaned
- Where: `:213-249`; `Listing.swift:415-476`; `RendpropApp.swift:57-63,68-71`; `:257-284`.
- Fix: deterministic sample ids (UUIDv5) AND gate tools for samples ("Create a \(noun) first"); hide Manage for samples.

### F-A-19 · P2 · Heavy image work on the main actor in the photo studio
- Where: `:656-696`, `:708-725`, `:740-793`, `:1194-1215`; `thumb()` (:806-829) and `selectThumb()` (:2028) decode full-res inside `body`; `LibraryImagePicker` (:2489-2497) loads 15 full-res images.
- Fix: `nonisolated static` helpers / `Task.detached` for encode/decode; cached thumbnails via `CGImageSourceCreateThumbnailAtIndex`.

### F-A-20 · P2 · "Make a reel" card lands in photo studio with no reel entry point when < 2 photos
- Where: `:219-223`, `:505-507`.
- Fix: `PhotoStudioView(listing:, intent: .reel)` hint + auto-open at threshold.

### F-A-21 · P2 · Performance card promises stats nothing will populate
- Where: `:313-319`. Fix: wire stats endpoint or hide the card for real listings.

### F-A-22 · P2 · "Suggest edits"/"Improve my prompt" spend photo-edit quota silently; `aiEdit` no re-entrancy guard
- Where: `ai-photo/index.ts:186-197`; app `:615, :1128-1142`; `aiEdit` (:651).
- Fix: server: don't charge helper modes; app: guard `aiEdit`, disable wand while processing.

### F-A-23 · P2 · Photo-to-clip files and reels never listed, reused or cleaned
- Where: `:778-781`, `:943-963`, `:995-1003`, `:2143-2146`, `SettingsView.swift:319-349`.
- Fix: track on listing or scan dirs; add `FloorPlans`, `reels`, `Aerials` to `wipeLocalData`.

### F-A-24 · P2 · Reel Studio motion prompt bypasses anti-hallucination scaffold
- Where: `:2183-2185`, `:747-749`; server `/reel-clip` `cleanPrompt(body.prompt) ?? DEFAULT` no wrapping (:314).
- Fix: send `motion` as separate field appended server-side.

### F-A-25 · P2 · "Set as main image" implies the public link; only affects local card
- Where: `:556-558, :464-467`; `Listing.swift:26-27`. Fix: covered by F-A-11; relabel meanwhile.

### F-A-26 · P3 · Nits
- `:139` `"%.2g"` prints 1.25× as "1.2×" — use `"%.3g"`.
- `:111` `Int(Double(tag.tMs) / tour.speedFactor)` traps on `speedFactor == 0`/NaN — guard.
- `:386-389` `onAppear` resets `zillowText`.
- `:280-284` no URL validation for Zillow.
- `PlayerWebView:302-305` Zillow baked at HTML gen; bump `playerRefresh` on Save.
- `:401-411` temporary `CLGeocoder()` not retained; errors swallowed; add back-off.
- `:363-379` Map: new `MapPin` UUID per render; deprecated API; add "Open in Maps".
- `:326` `metaLine` prints "0 bd · 0 ba".
- `:384` nav title "Flythrough" — use the address.
- `:1504` "Tweak the look below" — form is above.
- `:1567-1572`, `:1880-1885` "running offline" branches unreachable.
- `:1121-1123, :1201-1203` "Improve my prompt" sends only first 300 chars.
- `:641` "AI enhance failed" title reused for Animate errors.
- `:2836-2840`, `:2504-2511` permission denial unhandled.
- `:3147-3153, :3175-3179` `Int(NaN)` traps — guard `isFinite`.
- Idle timer not disabled during 1–3 min waits.

## Verified OK
Share gated on `serverShareURL`; room-tag rescale consistent; Zillow UI RE-only; samples: Tag rooms disabled, stats "Sample data", geocode skipped; aerial synthetic disclosure visible; `/ai-video` quota after validation, Idempotency-Key dedupe, SSRF guard; Reel Studio off-main, cancellation ≠ failure; Photo studio naming/ordering/delete-reselect; Floor plan LiDAR gate, straightening math, convex hull; Agent card PATCHes `/me/brand`; hard rules hold.

## Open questions
1. Aerial without a photo: allow generic or require photo? 2. Street address on the wire vs region. 3. Seedance i2v vs Veo reference-to-video. 4. Hosted pre-roll vs reel-only. 5. Sold listings on hosted portfolio: hide/badge. 6. Samples: gate tools or stable ids. 7. Delete with published tour: unpublish. 8. Helper modes consume quota?
