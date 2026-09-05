# HANDOFF — area C (data model, app state, Settings) · branch `p12-C`

Items from `audit/findings-C-model.md` (F-C-01 … F-C-20) that could **not** be
closed on this branch, with the exact change each one needs and who owns it.

---

## 1. `Resources/player/demo.mp4` is still missing from the repo (F-C-12)

**Status of the code:** fixed and safe. `PlayerWebView.demoHTML` only sets
`videoRef` when the bundled file is actually present; otherwise it flips
`const VIDEO_MISSING = true` in `Resources/player/index.html`, which renders the
explicit "Sample video unavailable / The sample clip isn't in this build. Record
a walkthrough to see your own tour here." stage. No black webview, no 404'd
`<video src="demo.mp4">`.

**Status of the asset:** still absent.

```
$ git ls-files apps/ios/Rendprop/Resources
apps/ios/Rendprop/Resources/Assets.xcassets/...
apps/ios/Rendprop/Resources/Secrets.example.plist
apps/ios/Rendprop/Resources/player/index.html      ← index.html only
$ ls apps/ios/Rendprop/Resources/player/
index.html                                          ← not on disk either
```

**Needed (repo owner — do NOT let an agent invent a binary):**

1. Commit the real clip at `apps/ios/Rendprop/Resources/player/demo.mp4`
   (git LFS if it is large), or add a build phase that generates it from the
   recipe in `apps/web/player/README.md`. `apps/ios/project.yml:40-42` bundles
   the whole `player` folder, so no project change is needed once the file exists.
2. Add a CI assertion to the `ios-static` job so it can never silently go
   missing again:

```yaml
      - name: Bundled player assets exist
        run: |
          for f in apps/ios/Rendprop/Resources/player/index.html \
                   apps/ios/Rendprop/Resources/player/demo.mp4; do
            [ -f "$f" ] || { echo "::error::missing bundled player asset: $f"; exit 1; }
          done
          echo "player assets present"
```

Until (1) lands, every non-real-estate sample tour and every real listing
without a video shows the placeholder stage instead of a demo. That is correct
behaviour, but it is not the intended demo experience.

---

## 2. Aerial / floor plan / reel / enhanced-photo model surface (F-C-16, partial)

**Already done:** the aerial is modelled — `Listing.aerialRelPath`,
`Listing.aerialGeneratedAt`, `Listing.aerialURL`, `AppModel.setAerial(...)`.
Deletion no longer depends on any of this: `FileStore.deleteListingFiles`
globs every artifact directory by listing id, so nothing is orphaned by a delete.

**Still missing:** floor plans and reels have no model representation, so the
detail screen cannot show them again after the sheet closes and the portfolio
cannot use them.

Files needed are **owned by other branches** (`FlythroughDetailView.swift`), so
this is a two-part change:

**Part A — `Models/Listing.swift` (owner: C).** Add inside the
`// MARK: - Added 2026-09-04` block, all Optional:

```swift
    /// Latest scanned/uploaded floor plan (Documents-relative).
    var floorPlanRelPath: String? = nil
    /// Uploaded floor-plan source (PDF/image) when the user supplied one.
    var floorPlanUploadRelPath: String? = nil
    /// Generated reel clips, newest first (Documents-relative).
    var reelRelPaths: [String]? = nil
```

and the matching `CodingKeys` cases + `decodeIfPresent` lines in
`extension Listing { init(from:) }`. Old snapshots decode unchanged (all three
are Optional with a `nil` default; see the round-trip note at the bottom).

**Part B — `Screens/FlythroughDetailView.swift` (owner: NOT C).** Where each
artifact is written today, add one `model.modify` call:

* after the floor plan is written (`Documents/FloorPlans/<id>.usdz`, ~line 4808):
  ```swift
  model.modify(listing.id, sync: false) { $0.floorPlanRelPath = FileStore.relativePath(for: url) }
  ```
* after a `-upload.<ext>` source is saved:
  ```swift
  model.modify(listing.id, sync: false) { $0.floorPlanUploadRelPath = FileStore.relativePath(for: url) }
  ```
* after a reel is written (`Documents/reels/<id>-<stamp>.mp4`, ~line 4412):
  ```swift
  model.modify(listing.id, sync: false) {
      $0.reelRelPaths = [FileStore.relativePath(for: url)] + ($0.reelRelPaths ?? [])
  }
  ```

`sync: false` is deliberate — these are local paths; the server has no
`floor_plan_key` / `reel_key` column yet (see item 4).

Part A alone ships dead model surface, so it was intentionally **not** committed:
land A and B together.

---

## 3. Hosted portfolio link `rendprop.com/a/<handle>` (F-C-13, partial)

**Already done:** the button count and the exporter share one filter
(`PortfolioExporter.eligible`), so "Share my portfolio (N)" can no longer be a
no-op; a zero count shows "Publish a tour to share your portfolio"; the HTML is
built off the main thread and photos are downscaled to ~800 px / q0.72 first.

**Still an HTML file, not a link.** The backend already hosts
`GET /a/:handle` (`services/edge/tour-host/src/index.ts:156-181`) and `GET /me`
already returns `org.handle` (`services/supabase/functions/me/index.ts:84`), but
the app never reads it. Needs, in order:

1. **`Networking/APIClient.swift` + `LiveAPIClient.swift` (owner: NOT C —
   LiveAPIClient is off-limits on this branch):** add `orgHandle: String?` to
   `UsageSummary` and map it from the `/me` response's `org.handle`.
2. **`Screens/SettingsView.swift` (owner: C):** when `usage?.orgHandle` is
   non-empty, make the primary Profile action share
   `URL(string: "https://rendprop.com/a/\(handle)")` and demote the HTML export
   to a secondary "Export page" action.
3. **Product decision + server route:** letting the user *set* a handle needs
   `PATCH /me {handle}` with uniqueness validation, which does not exist today.
   Audit open question 3.

---

## 4. Backend gaps that block model work (no app-side fix possible)

| Gap | Audit | What the app needs |
| --- | --- | --- |
| `listings` PATCH has no `main_photo_key` allow-list entry | F-C-04 | The main photo is set locally and marked dirty, but `listingBody` deliberately sends `main_photo_key: nil` (`LiveAPIClient.swift:795`) because the value is a *local* path. Needs a `role:"photo"` upload + a server column before the hosted page can show it. |
| No `avatar_url` upload path for the brand photo | F-C-06 | Needs `APIClient.uploadBrandPhoto(_:) -> String` and a server `kind:"brand_photo"` routed to the public renders bucket. Until then the editor copy is honest ("Hosted tour pages show your initials for now — photo upload is coming"), so nothing is misleading — but the feature is absent. |
| `orgs.brand_kit` is one row per org, not per `space_type` | F-C-05 | The app works around this: only the org's PRIMARY business type is pushed, and the Brand kit footer says which one hosted pages show. A true per-industry card needs `brand_kit[space_type]` plus `tours`/`portfolio` selecting by `listing.space_type`. Audit open question 2. |
| No `floor_plan_key` / `aerial_key` on `renders/publish-app` | F-C-16 | Blocks publishing floor plans and aerials to the hosted page. |

---

## 5. Verify on device before submission

Things this branch changed that cannot be exercised without a build (no macOS
here — nothing on this branch has been through `xcodebuild`):

* **F-C-15 salvage path.** Hand-craft a `Documents/rendprop-state.json` with
  one malformed listing (e.g. `"price": "oops"`) among several good ones and
  confirm on relaunch that the good listings survive and only the bad one is
  gone. Then make the file unreadable/truncated and confirm a
  `rendprop-state.corrupt-<unix>.json` appears and the good file is not replaced
  by an empty one.
* **F-C-11 wipe.** After "Delete account", confirm
  `Library/Application Support/rp-upload-slices/` and `Library/Caches/posters/`
  are empty — those are the two that used to survive.
