# HANDOFF — branch `p12-A` (area A · listing detail)

Changes that finding F-A-* needs but that **cannot be made from this branch**, because they
require editing existing lines in files `p12-A` does not own (`Upload/UploadManager.swift`,
`Networking/APIClient.swift`, `Networking/MockAPIClient.swift`, `Screens/SettingsView.swift`)
or non-additive edits to `Models/Listing.swift` / `Networking/LiveAPIClient.swift`.

Each item is written so the owning branch can apply it without re-deriving the analysis.

---

## 1. F-A-11 (P1) — DEFERRED. Photos / floor plan / reel never reach the share link

**Status: none of this exists.** `UploadManager.beginPhotoBatch` still has zero callers, and
the hosted page's `gallery`, `floorplan_url` and `reel_url` slots are never written by the app.

### Why it could not be done on `p12-A`

1. **The client cannot obtain a public URL for anything it uploads.**
   `POST /uploads/batch` mints `storage_key` in `R2_BUCKET_UPLOADS`
   (`services/supabase/functions/uploads/index.ts:334`), and only the **renders** bucket has a
   public base (`_shared/r2.ts:37` `R2_PUBLIC_BASE_URL`, used by `publicR2Url`). The base URL is
   never sent to the app. `PhotoTicket` (`APIClient.swift:51`) carries `storageKey` but nothing
   can turn it into an `https://` URL on device.
2. **`Listing.details` is `[String: String]`** (`Models/Listing.swift:37`), but the hosted page
   needs `details.gallery` to be an **array**
   (`services/edge/tour-host/src/player.ts:1379 galleryItems` → `Array.isArray(g)`). Changing the
   dictionary's value type is not an additive edit.
3. **Wholesale-PATCH clobber.** `LiveAPIClient.listingBody(_:forPatch:)` sends the *entire* local
   `details` map on every PATCH (`LiveAPIClient.swift:729-736`), and `AppModel.setSold` /
   `setZillow` / `setMainPhoto` / `setCoordinate` each fire a full `syncListing`. So a separate
   "PATCH just the gallery" call would be wiped by the very next ordinary edit. Whatever the app
   publishes has to live in the local model and ride the normal PATCH.
4. `beginPhotoBatch` is fire-and-forget: it posts
   `UploadManager.photosDidCompleteNotification` with `assetIDs` only (`UploadManager.swift:1172`),
   never URLs, and returns `Void`.

### The change set, in the order it has to land

**(a) Server — `services/supabase/functions/uploads/index.ts`**
Add a public photo role so gallery images land in the public bucket and the app is told the URL:
- accept `role:"gallery"` on `POST /uploads` and `POST /uploads/batch`;
- for that role use `bucketTag = "renders"` (the existing rule at `:597` — "Both public roles land
  in the renders bucket … 'access to the original' must be a link" — already establishes this);
- return `public_url: publicR2Url(storageKey)` alongside `put_url` / `storage_key`.
- Keep `role:"capture"` behaviour untouched. Charge the same upload budget.

**(b) Server — `services/supabase/functions/tours/index.ts`**
`floorplan_url` is already promoted out of `listing.details` (`:386`, `floorplanUrl()` at `:108`).
Do the same for the two missing slots so the app only ever has to write `listing.details`:
- keep passing `details` through verbatim (it already is, `:363`), which is enough for
  `gallery` / `reel_url` because `player.ts` reads them from `tour.listing.details`
  (`player.ts:1379`, `:1473`). **No tours change is strictly required** if the app writes those
  keys into `details` — verify with `check-unbranded.mjs` that a gallery does not leak branding
  onto the unbranded page.

**(c) iOS — `Models/Listing.swift`** (additive — `p12-A` could do this half, but it is useless
without (d))
The published assets must not go through the `[String: String]` detail map at all. Add a
separate, optional struct so no existing call site changes:

```swift
/// Assets published to the hosted page. Merged into the wire `details` at PATCH
/// time; NOT part of the industry detail-field map.
struct PublishedAssets: Codable, Hashable {
    var gallery: [String]?      // public https URLs, ordered
    var floorplanURL: String?
    var reelURL: String?
    var mainPhotoURL: String?
}
var publishedAssets: PublishedAssets? = nil
```
plus its `CodingKeys` case and `decodeIfPresent` line. This keeps `Listing.details` exactly as it
is; only the wire body (d) has to widen.

**(d) iOS — `Networking/LiveAPIClient.swift`, `listingBody(_:forPatch:)`** (non-additive, ~8 lines)
Merge `publishedAssets` into the outgoing `details` object, after the existing `details` block:

```swift
if let pub = l.publishedAssets {
    var d = (b["details"] as? [String: Any]) ?? [:]
    if let g = pub.gallery, !g.isEmpty { d["gallery"] = g } else if forPatch { d["gallery"] = NSNull() }
    if let fp = pub.floorplanURL, !fp.isEmpty { d["floorplan_url"] = fp } else if forPatch { d["floorplan_url"] = NSNull() }
    if let r = pub.reelURL, !r.isEmpty { d["reel_url"] = r } else if forPatch { d["reel_url"] = NSNull() }
    b["details"] = d
}
```
Note the current `b["details"]` is typed `[String: String]`; it has to widen to `[String: Any]`
for the array. That is the one existing line that must change.

**(e) iOS — `Upload/UploadManager.swift`**
`beginPhotoBatch` needs a result. Add an `async` sibling that returns the public URLs in the
caller's order:
```swift
@discardableResult
func uploadGalleryPhotos(listingID: UUID, fileURLs: [URL]) async -> [URL]
```
(`role:"gallery"`, reusing `runPhotoBatch`'s bounded-concurrency task group; collect
`ticket.publicURL` instead of only `assetID`.) Keep `beginPhotoBatch` for compatibility.

**(f) iOS — `Networking/APIClient.swift` + `MockAPIClient.swift`**
- `PhotoTicket` gains `var publicURL: URL? = nil` (decoded from `public_url`).
- `requestPhotoBatch` gains a `role: String = "capture"` parameter.
- Mirror both in `MockAPIClient` so offline dev still builds.

**(g) iOS — `Screens/FlythroughDetailView.swift` (owned by `p12-A`, ready to write)**
Once (a)–(f) exist, the UI is small and all of it belongs in files this branch owns:
- `PhotoStudioView`: a "Publish photos to my link" button (visible only when
  `currentListing.serverID != nil`), calling `uploadGalleryPhotos` then
  `model.modify(id) { $0.publishedAssets?.gallery = urls.map(\.absoluteString) }`.
  The cover photo goes to `publishedAssets.mainPhotoURL` in the same write — that is also the
  real fix for **F-A-25**, which is currently only a relabel ("Use as cover photo").
- `FloorPlan2DView`: the export path already produces a `UIImage`
  (`makeExport`); write it to a temp JPEG, upload with `role:"gallery"`, store `floorplanURL`.
- `ReelStudioView`: after a successful stitch, offer "Put this reel on my link" → upload →
  `reelURL`.
- Every one of these needs a sign-in gate and a visible failure path; reuse `AIFailureCard`.

**Do not** let any of these write into `Listing.details` directly: `ListingFormData`
(`NewListingView.swift:10`) round-trips `details` through the edit sheet and keeps unknown keys,
but the industry detail-field UI iterates `space.detailFields` and would ignore them — the
separate `publishedAssets` struct keeps the two concerns apart.

---

## 2. F-A-07 residual — `/ai-video/reel-clip` is never told the space type

`LiveAPIClient.aiVideoReelClip` (`:574`) does not send `space_type`, so the server falls back to
`real_estate` (`ai-video/index.ts:640`) and every photo→motion clip for a gym, restaurant or
venue is prompted as a "home" (`SCENE_NOUN`, `:210`). The aerial and `/ai-photo` routes both send
it correctly; this is the third route the audit's fix list did not name.

Required change (protocol file, not owned by `p12-A`):
- `APIClient.aiVideoReelClip(...)` gains `spaceType: String` (default `SpaceType.current.rawValue`
  in the existing convenience overload so no call site breaks);
- `LiveAPIClient` adds `body["space_type"] = spaceType`;
- `MockAPIClient` mirrors the signature;
- callers in `FlythroughDetailView.swift` (`PhotoStudioView.animate`, `ReelStudioView.makeClip`)
  pass `space.rawValue` — `p12-A` will make that change as soon as the signature exists.

---

## 3. F-A-16 residual — outside area A's files

`Screens/SettingsView.swift:1208` still uses
`UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)` followed by an unconditional success haptic,
in `AIPhotoStudioView`. This is the exact bug F-A-16 fixed everywhere in
`FlythroughDetailView.swift`. The fix is one line: call the existing
`PhotosLibrarySaver.saveImage(_:)`. That helper is currently `private` to
`FlythroughDetailView.swift` — either drop `private` (it is `enum PhotosLibrarySaver`, no name
clash in the target) or duplicate the eight-line `PHPhotoLibrary.performChanges` +
`authorizationStatus(for: .addOnly)` pattern in `SettingsView.swift`.

---

## 4. F-A-17 residual — per-room floor plans need iOS 17

The audit asks for "per-room scans". Storing several `<listingID>-<roomID>.usdz` files is easy;
**merging them into one plan is not possible on the iOS 16 deployment target** — RoomPlan's
multi-room merge (`StructureBuilder` / `CapturedStructure`) is iOS 17+. (Worth re-verifying
against the current SDK before committing to a design.)

`p12-A` therefore made the single-room limit **true in the copy** rather than shipping a list of
unrelated, unmergeable room plans ("Scan one room", "Room plan", "this room ≈ N sq ft").
When the deployment target moves to iOS 17, the follow-up is: keep a `[RoomScan]` per listing
(name + usdz + json), merge with `StructureBuilder`, and only then call the result a *floor plan*.

---

## 5. New Swift files are still unsafe in this repo

`apps/ios/Rendprop.xcodeproj/project.pbxproj` is **committed** and lists source files
individually (37 `.swift` entries). `project.yml`'s `sources: - path: Rendprop` glob would pick up
new files, but only after someone runs `xcodegen generate` on a Mac — which is exactly the failure
mode `docs/context/RENDPROP-FABLE5-BRIEF.md:18` records as having "burned us twice".

`p12-A` therefore added **no new files**; every new type
(`PhotoStudioView.SavedClip`, `PlanExport`, `PlanExportSheet`) is inline in the already-in-target
`Screens/FlythroughDetailView.swift`. Whoever merges these branches should either regenerate the
project or keep the same rule.
