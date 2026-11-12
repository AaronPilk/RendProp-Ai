# Build 58 — Claude handoff (2026-10-11)

Owner asks today, in order: Richard (via Aaron) wants to hand a listing's photos to
his transaction coordinator as one file; "it's showing Needs attention on my
TestFlight app"; "when you download the image shouldn't it get downloaded with
the AI disclosure and the original?"; "my published listing is not loading";
"there needs to be a button on the app that says republish"; "if you delete a
listing there should be a way to relist it".

Status line: **TWO LIVE BUGS FIXED (server + Worker) · BACKEND FOR BUILD 58 LIVE ·
BRANCH COMMITTED (not pushed — sandbox has no GitHub credentials) · WORKER DEPLOY
NEEDS AARON'S WRANGLER · CI PENDING · ARCHIVE PENDING · 1.0.4 (57) STAYS IN
REVIEW WITH THE MANUAL-RELEASE HOLD**

## 1. Binding

| Item | Value |
|---|---|
| Branch | `claude/build58-photo-zip-20261011` (worktree `~/Rendprop AI/build58`) |
| Base | `2d8b8cb` = `origin/fix/build57-portable-integration-20261010` (the tree Codex archived build 57 from, plus docs) |
| Commits | `6849868` tour-host fix · `01e7194` uuid-case fix · `a56ba01` build-58 features |
| Tip | `a56ba01c3a3b15b6b57759ddeba66fdbebd09d67`; native tree `apps/ios` = `2c41a4901e04c9191a39071d421b9035c92c7e1c` |
| Diff vs base | 41 files, +2148 −45 (native: 14 files, +934 −19) |
| Version / build | `MARKETING_VERSION 1.0.4`, `CURRENT_PROJECT_VERSION 58` (`apps/ios/project.yml:10`, both pbxproj configurations) |
| New native files | `Rendprop/Support/ZipArchive.swift`, `Rendprop/Screens/RecentlyDeletedView.swift` — both registered in `project.pbxproj` by hand (xcodegen would produce the same membership from `project.yml`) |
| Production (Supabase) | migration **live** as version `20261011155746` (repo file `services/supabase/migrations/20261011170000_build58_trash_restore_republish.sql`); functions **live**: listings 51, me 64, uploads 55, ai-photo 70, leads 49, ai-copy 37, ai-video 64, ai-voice 47, ai-chapters 38, coach 36, renders 52, team 28, property 24, studio 30, spatial 21, events 37 — all `source-verified` by `apps/studio/scripts/deploy-backend.mjs --run` (receipt `docs/releases/BUILD58-BACKEND-DEPLOY-20261011.json`). JWT policies unchanged. |
| Production (Cloudflare) | tour-host Worker **not yet deployed** — needs Aaron's wrangler login: `~/Rendprop AI/Fix-Tour-Pages-20261011.command` (or step 3 of the ship script below) |
| Apple | untouched. 1.0.4 (57) `46e2df20…` WAITING_FOR_REVIEW, MANUAL release. No submission, withdrawal or release by Claude. |

## 2. The two live bugs (both hit real phones on build 57)

### 2a. Every tour page on rendprop.com answered 503 "We couldn't load this tour"
- Cause: `services/edge/tour-host/src/upstream.ts` (and the Stream path in
  `media-delivery.ts`) paired `cache: "no-store"` (added 2026-10-07, `a326780`)
  with the older `cf: { cacheTtl: 0, cacheEverything: false }`. The Workers
  runtime throws `TypeError: CacheTtl: 0, is not compatible with cache: no-store
  header` before the subrequest leaves the Worker; `fetchUpstreamJSON` swallows
  it as "upstream unavailable" → 503 for `/f/`, `/u/` and `/a/`, and nothing is
  logged at Supabase (zero `/functions/v1/tours/*` requests in 24 h while
  Aaron's reloads were happening). Every Node check mocks `fetch`, so none saw it.
- Proof: reproduced in a real local workerd (`wrangler dev --local`), then the
  same runtime against production Supabase after the fix renders
  `/f/g2afbgmv32` 200, `/u/g2afbgmv32` 200, unknown slug 404, unknown handle 404.
- Fix (`6849868`): drop the cf cache keys, keep `cache: "no-store"`. New
  `scripts/check-runtime-upstream.mjs` boots the actual Worker through wrangler's
  `unstable_startWorker` (origin pinned to `https://rendprop.com`) against a
  loopback upstream and asserts tour 200 / unknown 404 / unbranded 200 /
  portfolio 404 plus a negative control proving the incident combination still
  throws. Wired into `npm test` (CI tour-host job). The two fetch mocks that
  asserted the broken pairing now assert the cf keys are absent.
- Deploy: Aaron (wrangler). Until then the site still 503s on tours.

### 2b. "Needs attention — Listing identity returned inconsistent data." (855 Central Ave)
- Cause: the phone sends `UUID.uuidString` in UPPERCASE (URL paths, query
  strings, JSON); Postgres returns uuid text lowercase; `80e006c` (2026-10-09)
  added `value.listing_id === listing` / `value.org_id === org` to the shared
  authority helpers. Function logs show the 503 on `PUT /listings/<ID>/facts`,
  `GET /me/compliance?listing_id=<ID>`, `POST /uploads` and `POST /ai-photo` for
  Aaron (through 15:06Z) and Richard (02:13–02:15Z). Simulator/UI fixtures use
  lowercase ids, so nothing caught it.
- Fix (`01e7194`), two layers: `_shared/http.ts` canonicalises uuid-shaped path
  segments and an allowlist of top-level body identity keys (`CANONICAL_ID_KEYS`;
  idempotency/batch keys, storage keys and free text untouched); `preferredOrg`
  lowercases a uuid `X-Org-Id`; `library-access` / `library-leads` /
  `library-listings` / `library-summary`, `me/compliance` and `ai-chapters`
  compare against the canonical form.
- Proof: `tools/audit/listing-uppercase-ids-20261011.ts` (CI) drives the actual
  `listings` handler with an uppercase path id + uppercase `X-Org-Id`: 200 on the
  fix, the phone's exact 503 on the previous source; negative control removes
  the canonicalisation from the helper and reproduces the message.
  `_shared/http.test.ts` + `library-access.test.ts` cover the boundary and the
  helpers. Full edge suite 1902/0 (was 1890/12 on the first pass — the coach
  admission test inlines `preferredOrg` textually, so that function is kept
  self-contained).
- Deploy: done from the sandbox (16 functions, versions above). **Aaron's
  phone check is still owed**: open 855 Central Ave, change a fact or pull to
  refresh — the red card should clear; uploads and AI photo edits should work.

## 3. Build 58 features

### 3a. One ZIP of a listing's photos (Richard's transaction coordinator)
- `ZipArchive.swift`: Foundation-only writer (store method, CRC32, UTF-8 names,
  central directory + EOCD; refuses duplicate/unsafe names and >4 GB; the copy
  pass re-checksums so a file changed mid-package fails instead of shipping
  corrupt). Verified on Linux: 26 checks, `unzip -t` clean, python zipfile
  reads every member byte-identical.
- `PhotoExportRenderer.package(_:archiveName:now:)`: README.txt (counts and the
  numbering/disclosure explanation) + every edited JPEG, `NN-disclosure.txt`
  and `NN-retained-original.*` → `"<address> photos.zip"` beside the prepared
  files (same cleanup).
- `PhotoExportSheet`: "Deliver as · One ZIP file / Separate files"
  (`export.deliverAs`), default ZIP when more than one photo, primary button
  "Share one ZIP file" (`export.share`). Entry points: Photos screen
  `photos.shareAll` ("Share all photos") and the listing page YOUR FILES card
  `detail.files.shareAllPhotos` ("Share all N photos"). The listing-page export
  now includes retained originals by default (toggle stays) — Aaron's "with the
  AI disclosure and the original".
- Harness: `apps/ios/tests/run-photo-export-renderer.py` compiles ZipArchive and
  adds the `negative-archive-drops-disclosures` mutant;
  `PhotoExportRendererTests.swift` parses the produced archive. Mac/CI only.

### 3b. "Republish tour" (same link, every time)
- SQL `republish_render(p_job, …)`: identical authority, asset and
  server-derived `staged` rules to `publish_render`, but it moves the listing's
  CURRENT published render onto the new job/asset **in place** — slug, row and
  first `published_at` unchanged, so flyers, QR codes and the MLS field keep
  working. Replay-safe per job (same render back); a never-published listing
  gets an ordinary first publish. `authenticated` may execute it (like
  `publish_render`).
- `POST /renders/republish-app` (same body/idempotency as `publish-app`;
  answers 200 with the same render id/slug and `republished: true`).
- iOS: `APIClient.republishApp`; `AppModel.republishExisting` syncs facts,
  client contact and gallery first, re-uploads the walkthrough only when the
  local file behind the tour changed, calls republish, refuses a server answer
  whose slug moved, stamps `Listing.lastRepublishedAt`. A cloud listing with no
  local walkthrough (restored or synced) republishes details/photos only.
  Listing page SHARE section: "Made changes?" card with **Republish tour**
  (`detail.republish`), progress (`detail.republishing`), failure card, and
  "Live page updated 2 minutes ago" (`detail.republished`).

### 3c. Recently deleted (30-day restore)
- `DELETE /listings/:id` now sets `trash_expires_at = now()+30 d`; the storage
  cleanup trigger skips an open window; `listing_trash_sweep()` (cron
  `listing-trash-sweep`, `23 * * * *`) queues the identical cleanup when the
  window closes (trigger body moved verbatim into
  `queue_listing_media_cleanup(uuid)`). A delete with no window (older clients,
  account deletion) queues cleanup immediately as before; account deletion is
  unchanged — its own job already covers every solo-org listing, and trashed
  listings carry no pending job to delay `storage_after`.
- `restore_listing(actor, listing)` (service-only): write access to the
  listing's logical library (`trashed_listing_library` = `listing_owner_library`
  without the deleted filter), clears the trash marks, re-publishes exactly the
  renders the delete took down (`renders.unpublished_by_delete_at`, stamped by
  the unpublish trigger) so the same links come back, reports deliveries the
  delete skipped (not re-sent). `list_trashed_listings(actor, org)` feeds the
  screen; marketing seats see rows but `can_restore=false`.
- Routes: `GET /listings/trash` (needs `X-Org-Id`), `POST /listings/:id/restore`
  (re-checks the ordinary scope on the live row before answering).
- iOS: Settings › **Recently deleted** (`settings.recentlyDeleted` →
  `RecentlyDeletedView`: rows with "Deleted Oct 11 · 29 days left", Restore
  (`recentlyDeleted.restore.<id>`), restored banner, empty/error states); the
  delete confirmation now says the listing can be restored for 30 days and that
  the same links come back. `AppModel.restoreListing` calls the route then
  refreshes the cloud workspace so the listing reappears (as a cloud listing;
  the local walkthrough file was removed at delete time, the tour is served from
  the cloud copy). Mock client mirrors all of it offline.

## 4. Evidence (what was actually run)

| Check | Result |
|---|---|
| tour-host `npm test` (12 checks incl. the new real-runtime one) | green; `wrangler deploy --dry-run` OK; mutation control: the runtime check fails on the previous `upstream.ts` (503) |
| Local workerd vs production Supabase | `/f/g2afbgmv32` 200 "855 Central Ave…", `/u/g2afbgmv32` 200, unknown slug 404, unknown handle 404 |
| `deno check` all 16 phone-facing function entrypoints | OK |
| Edge suite `deno test --allow-all .` | 1902 passed / 0 failed / 1 ignored |
| `tools/audit/listing-uppercase-ids-20261011.ts` | 23 assertions; previous source → 503 "Listing identity returned inconsistent data." |
| `tools/audit/listing-trash-routes-20261011_test.ts` / `renders-republish-route-20261011_test.ts` | 7/7, 4/4 (own processes; they set env and replace fetch) |
| `tools/audit/uploads_*_test.ts`, `listing-facts-handler-20261004.ts` | 62/62, 97/97 |
| DB: socket-only PG18, bootstrap + all 134 migrations, `tests/build58_db_controls.sql` | 42/42 fresh and after replaying the new migration; `tests/invariants.sql` 270/270; wired into `run_database_regression.py` REFLECTION_FIXTURES |
| Production readback after migration | function md5s identical to the local apply (`list_trashed_listings d3a6…`, `restore_listing b00e…`, `republish_render a7cd…`, `queue_listing_media_cleanup 2f98…`, `listing_trash_sweep fcf7…`, `unpublish_deleted_listing_renders d742…`), cron scheduled, two columns present, `republish_render` executable by authenticated, `restore_listing` not |
| Swift | `swiftc -parse` on every changed file (Linux toolchain). **No type-check or build of the app happened here** — Xcode/CI native job do that. |
| Not done | XCUITests for the new screens; a phone run; the Mac harness `run-photo-export-renderer.py` (iOS simulator) |

## 5. What Aaron does next (in order)

1. **Tour pages back online (2 minutes):** double-click `~/Rendprop AI/Fix-Tour-Pages-20261011.command` (installs, runs every tour-host check, `wrangler deploy`, prints the four status codes — expect 200 200 404 404).
2. **Phone check on TestFlight 57 (no new build needed):** open 855 Central Ave, edit a fact → the "Needs attention" card clears; upload a photo; run one AI photo edit.
3. **Ship build 58:** `~/Rendprop AI/Ship-Rendprop-Build58-20261011.command` → pushes the branch, runs the Mac-only harnesses (incl. the photo-export one), deploys the Worker if step 1 was skipped, prints the archive commands. Then GitHub Actions → CI on `claude/build58-photo-zip-20261011` (all jobs), archive 1.0.4 (58) with `tools/asc/bridge-600-archive-upload.sh`, TestFlight.
4. **Phone acceptance on 58:** listing page → Republish tour (link unchanged, "Live page updated"); Photos → Share all photos → one ZIP opens on a Mac/Windows PC with README + JPEGs + disclosure notes + originals; delete a test listing → Settings › Recently deleted → Restore → it reappears and its old link works.
5. **Apple:** 1.0.4 (57) is still in review. Options once 58 is on TestFlight and accepted: (a) leave 57 in review, release it manually only if the phone checks in step 2 pass (the two server fixes already apply to 57), then submit 1.0.5 (58) later; or (b) cancel the 57 review in App Store Connect and attach 58 to 1.0.4 (same version, newer build) — one more review cycle. Claude recommends (b) only if Apple has not started reviewing yet; otherwise (a).

## 6. Notes and limitations
- Repo filename `20261011170000_…` vs live version `20261011155746`: the MCP stamps its own version (same pattern as build 57). `supabase_migrations.schema_migrations` lists the live one.
- `apps/studio/node_modules` in the worktree was a symlink for the deploy tool and is not committed.
- Codex's "follow-ups" from the build-57 ship record (attach readings to the export stall error, environment-aware retry, gzip headroom, six logging bundles) are untouched — except that the six older bundles were redeployed today as part of the uuid fix (they import `_shared/http.ts`).
- The one listing soft-deleted on 2026-09-26 predates the cleanup trigger: its media is still in R2 and it has no restore window (no `trash_expires_at`). Leave it.
