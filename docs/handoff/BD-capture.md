# HANDOFF — p12-BD (areas B · render/publish flow, D · capture engine)

Changes that belong to files this branch does not own. Each item is written so
the owner can apply it verbatim. Nothing here is speculative — every one was
verified against the code as it stands on `p12-BD` at the time of writing.

Owned by this branch (already done, do not re-apply): `Screens/RenderStatusView.swift`,
`Screens/ReviewSubmitView.swift`, `Screens/NewListingView.swift`, `Capture/*`,
`Render/RenderEngine.swift`, plus `Import/MediaImporter.swift`.

---

## 1. `RendpropApp.swift` — a failed RE-render downgrades a finished listing to "Not finished"

**Severity: P1. Reachable today.** Review & Submit offers "Render again with these
settings" once a listing has a tour (correct — it is confirmed first). If that
re-render fails (source video gone, disk full, writer error), `runRender`'s catch
sets the listing to `.draft` even though the previous tour — and possibly a live
share link — still exists. The card then reads "Not finished" for a listing whose
tour plays and whose public link works, and `reconcileAfterRestore` never repairs
it because it does not touch `.draft`.

`RenderCoordinator.cancel(listingID:)` already gets this right
(`model?.setStatus(hasTour ? .ready : .draft, for: id)`); the failure path just
missed the same check.

`RendpropApp.swift:844`, in `RenderCoordinator.runRender`:

```swift
            let message = AppModel.userMessage(for: error)
-           model.setStatus(.draft, for: id)
+           // A re-render that fails must not demote a listing that still has a
+           // working (possibly published) tour — cancel() already does this.
+           model.setStatus(model.tours[id] != nil ? .ready : .draft, for: id)
            model.setLastError(message, for: id)
```

`lastError` still carries the message, so the detail screen keeps offering
"Try the render again".

---

## 2. `RendpropApp.swift` — the AI tiers cannot reach 4K, so the tier copy is false (F-B-09a)

**Severity: P1 copy-truth.** `Models/Render.swift` advertises "AI motion smoothing
+ upscale (up to 4K, 30 fps / 60 fps)". The server *can* deliver that — since the
last wave `POST /ai-video/drone` computes `upscale = clamp(targetLongEdge /
srcLong, 1, 4)` (`services/supabase/functions/ai-video/index.ts:416-426`) — but
only when it knows the source's dimensions:

```ts
const srcLong = asset.width && asset.height ? Math.max(asset.width, asset.height) : null;
...
} else {
  upscale = tier === "1080p60" ? 1 : 2;      // ← the branch we hit today
}
```

Both iOS render uploads send `UploadMetadata(durationS:bytes:)` and nothing else,
so `capture_assets.width/height/fps` stay NULL, `srcLong` is null, and the server
falls back to `upscale = 2`. The on-device master is 1280 long-edge
(`RenderEngine.encodeLongEdge`), so the "4K" tiers actually produce **2560×1440**.
Send the dimensions and the same master upscales ×3.0 → 3840 long edge, real 4K,
still inside the server's `outLong <= 4096` guard. `asset.fps` also drives
`interpolate`, so send it too.

`POST /uploads/:id/complete` already accepts and validates all three
(`services/supabase/functions/uploads/index.ts:215-224`) and `LiveAPIClient`
already forwards `metadata.width/height/fps` (`LiveAPIClient.swift:256-257`).
Nothing server-side needs to change.

**Two call sites.** `MediaImporter.probe(url:)` returns oriented `width`/`height`
plus `fps` and is already in the target; it does not decode frames.

`RendpropApp.swift:529`, in `AppModel.publishTour`:

```swift
                let bytes = FileStore.fileSize(renderOutputURL)
-               let meta = UploadMetadata(durationS: durationS, bytes: bytes)
+               // width/height/fps are what let /ai-video/drone pick a real 4K
+               // upscale factor instead of its blind ×2 fallback (F-B-09).
+               let probe = await MediaImporter.probe(url: renderOutputURL)
+               let meta = UploadMetadata(durationS: durationS, fps: probe.fps > 0 ? probe.fps : nil,
+                                         width: probe.width > 0 ? probe.width : nil,
+                                         height: probe.height > 0 ? probe.height : nil,
+                                         bytes: bytes)
```

`RendpropApp.swift:970`, in `RenderCoordinator.enhance` (this is the upload the
drone route actually consumes):

```swift
-           let meta = UploadMetadata(durationS: tour.durationS, bytes: FileStore.fileSize(tour.url))
+           let probe = await MediaImporter.probe(url: tour.url)
+           let meta = UploadMetadata(durationS: tour.durationS,
+                                     fps: probe.fps > 0 ? probe.fps : nil,
+                                     width: probe.width > 0 ? probe.width : nil,
+                                     height: probe.height > 0 ? probe.height : nil,
+                                     bytes: FileStore.fileSize(tour.url))
```

Both sites are already `async`. If this is not applied, the honest alternative is
to change the two blurbs in `Models/Render.swift` from "up to 4K" to "up to
1440p" — one or the other, but the current pair is a false claim.

**Not verified without a device/server run:** that fal's Topaz endpoint accepts a
non-integer `upscale_factor` of 3.0. The server already clamps to `<= 4` and the
schema documents the field as a float, but if fal rejects it, round `upscale`
down to an integer server-side rather than dropping this fix.

---

## 3. `RendpropApp.swift` — the AI enhance replaces the all-intra scrub master (F-B-09b)

**Severity: P2, quality regression on the paid tiers.** `RenderCoordinator.enhance`
downloads the Topaz result and swaps it in as the local tour:

```swift
model.tours[id] = AppModel.RenderedTour(url: dest, durationS: tour.durationS, ...)
```

The engine goes to real trouble to produce an ALL-INTRA H.264 (`AVVideoMaxKeyFrameIntervalKey: 1`,
no frame reordering) because the whole product is scroll-scrubbing. The fal job
is submitted with `H264_output: true`, i.e. an ordinary GOP structure. So a user
who picks a paid tier gets a file that scrubs *worse* than the free tier, both
in-app and as the hosted `scrub_url`.

Pick one:

- **(a) Cheapest, recommended for this release:** keep the Topaz file as the
  published/high-quality rendition, but leave `model.tours[id]` pointing at the
  on-device all-intra master so in-app scrubbing is unchanged. Requires the
  publish step to send the enhanced asset while the local tour stays the master —
  i.e. `RenderedTour` gains an Optional `enhancedURL`, and `publishTour` uploads
  that when present.
- **(b)** Re-encode the downloaded file on device with the same all-intra writer
  settings before swapping it in. Correct but adds another multi-minute pass on a
  phone that has just done one.
- **(c)** Have the server ingest the fal result straight into R2 and return an
  asset id (this also removes the multi-GB down-then-up round trip flagged in
  F-B-20) and publish that as the video rendition while `scrub_url` keeps the
  on-device master.

Whatever is chosen, the tier blurbs must not imply better scrubbing.

---

## 4. `HomeListingsView.swift` / `RootTabView` — the flow's navigation stack is never unwound (F-B-12 residual)

**Severity: P2, cosmetic now that the destructive half is fixed.** After "Your
tour is ready" → "View my tour", the stack is
`Listings → NewListing → Review → RenderStatus → FlythroughDetail`. Backing out
walks the user back through Review & Submit and the New Listing form for a
listing that is finished.

The dangerous consequences are already handled on this branch: Review & Submit
shows "View tour" + a confirmed "Render again" instead of "Create my tour" when a
tour exists, `RenderCoordinator` refuses a second concurrent job per listing,
publish is idempotent per listing+asset, and `NewListingView.receive` no longer
re-points a listing that already has a tour at a different video. What is left is
the back-stack itself.

This cannot be fixed from the three screens alone: a plain `NavigationStack`
cannot pop the views *below* the one being pushed. It needs a
`@State private var path = NavigationPath()` (or `[Route]`) owned by
`HomeListingsView` (and by the Home tab's own stack in `RendpropApp.swift:~1495`),
threaded down as a `@Binding` so "View my tour" can do
`path.removeLast(path.count); path.append(.detail(listing))`. If you add it, this
branch's three screens each need one extra `@Binding var path` parameter with a
default so `FlythroughDetailView`'s "Create tour" entry point keeps compiling.

---

## 5. Not a change — a decision recorded so it is not re-litigated

**F-D-14 encode bitrate.** The audit suggested raising the all-intra bitrate from
14 Mb/s to 24–30 Mb/s or shortening the GOP. Left at 14 Mb/s deliberately: the
duration cap (10 min source, `RenderEngine.maxSourceSeconds`) and
`AVVideoExpectedSourceFrameRateKey` are in place, and raising the bitrate makes
the *upload* problem worse — a 5-minute tour is already ~525 MB at 14 Mb/s and
that file is what gets pushed to R2. Shortening the GOP would trade away the
frame-exact scrubbing the product is built on. Changing either needs a
side-by-side look on a device, not a guess.
