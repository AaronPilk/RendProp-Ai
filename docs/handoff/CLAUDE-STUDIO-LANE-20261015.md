# Claude Studio lane — October 15, 2026

Branch `claude/launch83-web-studio-20261015`, base `3483a36`. Edits are limited to `apps/studio/src` and
`apps/studio/tests`. **Committed in `ddb386c`; the later Codex ordering follow-up is described in the combined handoff.** Evidence is local and headless only:
Node unit tests plus Playwright Chromium over isolated fixtures. Nothing touched production, a provider,
real accounts or purchases, and nothing here counts as phone acceptance.

## Changed files

- `src/features/creative/CreativeWorkspace.tsx`: the photo loader reads every media page and skips server-derived files (S1, S5)
- `src/features/creative/photo-lineage.ts`: new `isServerDerivedPhoto` key check (S5)
- `src/features/creative/coordinator-photo-export.ts`: re-signs expiring links for the same photo list, excludes derived files and adds a readme sentence (S2, S5)
- `src/features/creative/CoordinatorPhotoExportPanel.tsx`: passes `refresh` (S2)
- `src/features/home/features.ts`: tool order and labels now follow the iPhone Home (S3)
- `src/features/listings/readiness.ts`: the finish guide says "Make a video" instead of "reel" (S3)
- `src/features/sync/MakeVideo.tsx`: ignores a status reply for a job that is no longer on screen (S4)
- Tests:
  - New: `tests/feature-parity.test.ts`, `tests/creative-photo-pages-browser.mjs`, `tests/make-video-status-browser.mjs`
  - Extended: `tests/coordinator-photo-export.test.ts` (+3 tests)
  - Fixture hooks (opt-in, default behaviour unchanged): `tests/creative-fixture.tsx` (server-shaped paging), `tests/make-video-fixture.tsx` (`holdJobStatus`)
  - `tests/listing-finish-browser.mjs`: the button label changed from "Open Reel Studio" to "Make a video". Same assertions, nothing weakened.

## Bugs fixed

For each bug, "Before" was run against HEAD `src` with the new tests, and "After" against the patched tree.

### S1 — AI Photo Studio version tabs showed only the first 50 media rows (P02, P03, P01, O06)

- **Repro:** `loadPhotos()` fetched page 0 only. In the photo panel there was no way to load more; the "Load more" button lived only in the Scripts panel. After a save or batch, it reloaded page 0 again. Try a listing with more than 50 gallery rows, where the staged version is on page 2, then open AI Photo Studio and click Staged.
- **Before:** Staged said "No saved results in this category yet." The Original picker listed 50 of 56 rows. The batch grid was missing rows 51+.
- **After:** all pages load, bounded at 5,000 rows with a guard against non-advancing pages and de-duplication by id. Staged lists the saved version, which you can review, select or download. "Edit original with AI" still starts from Original.
- **Regression:** `tests/creative-photo-pages-browser.mjs`. Before: fail (`Expected 57, Received 51` options). After: pass. It also proves page offsets 0 and 50 were requested and no AI, upload or gallery call was made.

### S2 — Large coordinator ZIP could never finish after 10 minutes (P11)

- **Repro:** every signed URL is fetched once at the start. `studio/media` links expire after 600 s (`MEDIA_TTL_SECONDS`). Parts are user-paced at about 11 photo families per part, so a large library takes many parts.
- **Before:** once 10 minutes passed, the next photo threw "A photo link expired. Refresh this property and prepare the package again." Restarting began again at part 1, so a big library could never complete.
- **After:** when a photo's link has less than 2 minutes left, the generator re-reads the same saved list through the existing `loadCoordinatorPhotos`. It requires the identical id sequence and order. If the list changed (missing, extra or reordered photos), it stops with "The saved photos changed while this package was being prepared…". A link that is still expired after re-reading still fails. No photo is skipped or substituted.
- **Regressions** (`coordinator-photo-export.test.ts`):
  - "later parts re-sign expired links…": 3 parts, exactly 1 refresh, re-signed URLs fetched, exact master bytes and 4 copies per photo
  - "a changed saved photo list during re-signing refuses…"
  - Before: both fail with "A photo link expired…". After: both pass.

### S3 — Studio tool cards and finish guide still said "Make a reel" and led with the walkthrough (V01, V02, A01, O06)

- **Repro:** tiles on the Dashboard and on the property page:
  - "Make a tour" came first.
  - The video tile read "Make a reel — Photos and clips → one social video", although it opens Make a video with Listing 16:9 as the default.
  - The finish guide said "Polish photos or make a reel / Open Reel Studio".
- **After:** the order is now Add photos → AI Photo Studio → **Make a video** ("A listing or social media video from your photos") → **Recorded walkthrough** ("Optional · …"), then Aerial (Coming soon), Measurements, 3D and Agent card. The finish guide says "Edit photos or make a video / Make a video". Ids, routes and write-gating are unchanged.
- **Regression:** `tests/feature-parity.test.ts` (2 tests). Before: 2 fail. After: 2 pass.

### S4 — A late status reply could replace the saved video you just opened (V09, V16)

- **Repro:** job B is creating and a status GET is in flight. Open job A (ready) from "Saved videos for this property". B's reply then lands.
- **Before:** the panel flipped back to B ("queued · 0/2… Cancel video").
- **After:** the stale reply is ignored, using a closed-effect flag plus a functional `setJob` that checks the job id. B keeps running on the server. No cancel, publish or duplicate dispatch.
- **Regression:** `tests/make-video-status-browser.mjs`. Before: fail at line 33 (shows B). After: pass. `make-video-browser.mjs` still passes.

### S5 — Video-only server files appeared as photo versions and coordinator masters (P11, P10, O06)

- **Source evidence:** `property_video_preparation_outputs/finish` registers ≤2048 px JPEG processing copies as uploaded `capture_assets` photos at `uploads/<org>/<listing>/prepared-video/…`. `property_video_job_outputs_reserve` registers each finished video's poster at `renders/<org>/<listing>/background/<job>/<lease>/first-clip.jpg`. `studio/media` lists every uploaded photo asset.
- **Before:**
  - The ZIP filed processing copies under `Originals/` as if they were originals, and filed poster frames under `Edited/`, each with four delivery copies.
  - Copies appeared as originals to edit from, and posters appeared in "Saved edits".
- **After:** `isServerDerivedPhoto` reads the storage key from the already-admitted URL (gateway capability or R2 path) and excludes exactly those two server namespaces from the coordinator list (including on re-sign) and from the Creative photo loader. The ZIP readme now says so.
- **Regressions:**
  - Unit: "video processing copies and video poster frames never enter the coordinator photo package". Before: fail (included `photo-2`, `photo-3`, `photo-4`). After: pass.
  - Browser: the derived rows in `creative-photo-pages-browser`. Before this fix: fail with 58 options instead of 57. After: pass.
- This is a client stopgap; contract C1 below is the real fix.

## Commands and results (local copy `/tmp/w83s/repo`)

| Check | Before (HEAD) | After |
|---|---|---|
| `npm test` | 565/565 pass | **570/570 pass** |
| `npm run build` (typecheck + vite) | pass | **pass** |
| `node scripts/check-dist.mjs` | gzip total 374,258, initial 140,431, create 205,922 | **gzip total 374,927 / 400,000; initial 140,440 / 160,000; create 205,947 / 260,000**. Passed; brandIdentical; privateNoindex |
| Browser runners: all 25 Studio CI runners + `make-video`, `photo-recovery` + the 2 new ones | — | **29/29 pass** |

- **Pre-existing, unrelated failure:** `tests/feature-entry-browser.mjs` (not in CI) fails at line 39 on both HEAD and patched. It still expects a "Scandinavian" staging button, but P04 replaced it with Contemporary. Left unchanged for Codex/owner.

## Areas checked without bugs (patched line numbers)

**MakeVideo**
- Voice is Off by default and the spoken-caption UI appears only when voice ≠ off (`MakeVideo.tsx:184`). `spoken_captions = voice!=="off"&&spoken` (`:113`).
- Voice/music sit under "(optional)" (`:177`). Labels, transitions and camera are under Advanced (`:182`).
- New and still-unplanned restored videos preserve the explicit input order. Automatic planning chooses per-photo movement and falls back to gentle push-in; it never sorts by room (`property-video.ts`). No per-photo questions are added.
- No 8 or 15 cap: "Select up to 100", the 101st is disabled (`:172-173`), and the 1–100 guard is at `property-video.ts:56,63`.

**Jobs, recovery and publication**
- The journal is saved before POST; the idempotency key is `property-video:<operation>` with consent (`property-video.ts:113-114`).
- Lost-reply recovery uses an operation GET (`MakeVideo.tsx:59,155`). Proven capacity refusal is retained and a new operation is created (`:148`).
- Server-authorized resume keeps the same job (`property-video.ts:79-83`). Cancel needs server confirmation (`MakeVideo.tsx:156`).
- Scope key is actor, library and listing (`:20`), and the identity version is checked on every call.
- The result is private: no autoplay, preload=metadata (`:191`). Website publication requires an explicit review checkbox and only a 1920×1080 unbranded result, and the server reply must match listing, org, library, kind, asset, publication and slug (`property-video.ts:137-141`).

**Photo versions**
- New edits only start from the Original tab; the guard is at `CreativeWorkspace.tsx:621` and the controls at `:1285`.
- Saved tabs are review/download, with "Edit original with AI" at `:1114`, and `propertyOriginalPhoto` loads the paired original (`:1087`).
- Each saved edit inserts a new `photos` row via `studio_attach_photo` (migration `20261005215724`), so earlier versions are kept.

**ZIP**
- Exact master bytes and magic-number type (`coordinator-photo-export.ts:126`).
- Presets are described as "not universal platform requirements" (`:86`; panel `:58`).
- Unavailable media fails (`:24`); an oversized family fails rather than shrinking (`:157`).
- Scope and abort checks run around every await (`:61`; panel `:17`).
- Completion copy is honest: "offered for download" (panel `:66`). Unique numbered and id-based names are enforced by the existing collision test.

**Paid designs**
- `apps/studio/src` has no website-design or luxury-preview, purchase or entitlement UI (grep for theme, entitle, Signature, Coastal, purchase or unlock finds nothing beyond the plan-degraded flag). Studio therefore cannot render a preview as paid or create an entitlement.
- Published video state comes from the server: `publishVideo` reply checks, and ListingWorkflow builds its "Published tours" list from server `listing-state` renders.

## Contract proposals for Codex (backend lane, not implemented)

- **C1 — studio/media lists derived files as photos.** Exclude `uploads/*/*/prepared-video/*` and `renders/*/*/background/*` photo assets from `photos`, or add `derived:"video_processing_copy"|"video_poster"|null` to `StudioPhotoDTO`.
  - ListingWorkflow, outside this patch, still shows them. Posters get "Add to tour gallery" and appear in the "Tour cover photo" select, and copies show as "Source photo".
  - Once the server excludes them, S5's client check can be removed.
- **C2 — no way out of a stuck pending video request.** Scenario: a request was saved, the server never accepted it and the operation is not closed, and then its photo versions changed. Resume refuses ("earlier photo versions") and Recover reports "not found", so the user is stuck.
  - Proposal: `POST /functions/v1/property-video-jobs/operations/{operation_id}/abandon` with `{listing_id, expected_org_id}`. It tombstones the operation so a late POST with `property-video:<op>` gets 409, and returns `{operation_id, listing_id, selected_library_org_id, operation_closed:true, job:null}`.
  - If a job exists, it returns that job and never cancels it. Studio would then reuse `retainRejectedVideo`.
- **C3 — duplicate keys are dropped silently.** `studio/handler.ts` `sign()` returns null for a key already signed on the page without incrementing `unavailable_count`, so a client cannot detect the gap. Count it as unavailable, or return the row.
- **C4 — question:** confirm that the generic `renders/publish-app` (the recorded-walkthrough path with no `presentation_kind`) refuses property-video output assets, including 9:16 Social results with the watermark. ListingWorkflow's "Create & publish" source list offers any renders-bucket video as an "Edited tour".

## Not changed (by design or owned elsewhere)

- Batch AI photo edits stay limited to 6 at a time, and Scripts & shot plans to 20 photos. These are AI-edit and copy limits, not video caps; the video recipe allows up to 100.
- Codex-owned lanes are untouched: iOS/native, Supabase/DB/migrations/Edge, billing/StoreKit, video render/QC, CI workflow, deploys and phone/Mirroring. Job `c40f4860…` was not touched.

## Still needs phone or production checks (Codex/owner)

- Real authenticated Studio account, library and team-member isolation.
- Hosted `studio/media` paging with more than 50 rows.
- A real multi-part coordinator ZIP open in Finder/Files: folders, dimensions, completeness and re-sign after 10 minutes.
- The real Make a video lifecycle (enqueue → leave → recover/resume → review → explicit publish) against the same job, and its phone/Studio parity.
- Purchase and entitlement remain native/Sandbox only.
