# TestFlight 59 beta feedback — triage, fixes and what's left — 2026-10-11 (Claude)

Source: App Store Connect TestFlight feedback, pulled with the ASC API (`betaFeedbackScreenshotSubmissions`). Nine submissions from Aaron on build 59 (22:28–22:40Z) plus one from Stephenie on build 56. Screenshots and the index are in `~/Rendprop AI/beta-feedback-20261011/`. Every item below was matched against the edge-function and Postgres logs for the same minutes.

## Fixed on the server tonight (live now, no new build needed)

| # | What you saw | What was actually happening | Fix | Live |
|---|---|---|---|---|
| 8 | "I deleted a listing and it says nothing has been deleted" — Recently deleted empty | `DELETE /listings/C621B8DF…` returned **400** at 22:27:43Z; Postgres: `permission denied for table listings`. The build-58 delete wrote `trash_expires_at` through the tenant (RLS) client, but `authenticated` only has column UPDATE grants on `deleted_at, gallery_asset_ids, main_photo_key, mls_ref, source`. The phone fires-and-forgets the delete, so it removed the card locally, the server listing stayed live, and it came back on the next sync. **Every delete on 58 and 59 failed this way** — my build-58 SQL suite ran that write as `service_role`, so it never saw the grant. | New service-only RPC `trash_listing(actor, listing)` with the same authority the RLS policy used (`listing_content_access(..., write)`); the route calls it instead of writing the column. Migration `20261011233000_build59_trash_listing.sql`, live as `20261011230539` (md5 `d838b2dd…` = local). Suite 42 → 52 assertions incl. the tenant-grant negative control; route test models the grant. | listings **52** |
| 4 | "There was a error with the reel feature" — *Unsupported video accounting metadata* | `POST /ai-video/reel-clip` **400** at 22:35:03Z. Codex's preset change put `preset_version: 1` into the cost-reservation metadata; `app_video_cost_reserve` allow-lists metadata keys (`tier, seconds, aspect, motion, …`) and rejected it before any provider POST. **Every preset reel on 58/59 failed.** The handler test mocks that RPC, so it passed. | `preset_version` removed from the accounting metadata (the preset is identified by `motion`, which is allow-listed); the handler test now asserts every metadata key is on the SQL allow-list (mutant with `preset_version` fails). | ai-video **66** |
| 1 | "it keeps failing to sync… spins for a minute then says this" — *1 listing update is waiting to sync / Retry Studio sync* | The logs show `PUT /listings/55739BCB…/facts` → 200, three times, on every refresh since this morning. That listing is 855 Central Ave, which you marked **sold** at 14:52Z. The server renders the sold timestamp as `…52.261+00:00`; the phone sends `…52.261Z`; the phone's acknowledgement compared the text, never matched, so the edit stayed "waiting" forever and re-sent itself (3 attempts per refresh). Not a 58/59 regression — it has been there since the facts sync landed Oct 5; the 503s on 57 hid it. | Every listing payload now carries `sold_at` in the phone's own shape when that is lossless (`canonicalTimestamps`, `_shared/http.ts`), so the acknowledgement matches on builds 57/58/59 without an update. Build 60 also acknowledges timestamps by instant (iOS, below). | listings **52** |

Deployed with `deploy-backend.mjs --run` (source-verified readback, receipt `docs/releases/BUILD59-FEEDBACK-BACKEND-20261011.json`). Deno sweep 1907/0, DB suite 52/52 fresh + replay, invariants 270/270, standalone route tests 10/10.

**What you should see now, on build 59 as installed:** delete a listing → it appears under Settings › Recently deleted; a reel generates (after you forget the stuck request — see #3); the "waiting to sync" line on 855 Central Ave clears on the next refresh.

## Fixed in build 60 (branch `claude/build60-feedback-20261011`, needs an archive)

| # | What you saw | Cause | Fix |
|---|---|---|---|
| 3 | After the reel failed, "Back to reel setup" won't let me tap Generate ("Pick 2 photos first" with 5 picked) | The app saves an "unconfirmed submission" marker before every paid POST so a lost response can't double-charge. A **definitive refusal** (the server answered 4xx before admitting anything) left that marker in place; the marker disables Generate, and the button label fell through to the photo-count wording. | A 4xx (not 408) now retires the marker and the error surfaces unchanged; transport loss, timeouts and 5xx keep it exactly as before. The button says "Review the saved request first" when a marker is the reason. Proven with a Linux build of the real `makeClip`: 13 assertions, mutant fails (`claude-build60-evidence/`); the Mac harness gained the same case + negative control. |
| 5, 0 | "I don't see anywhere where I can 'share all'" / "share all is supposed to be the FULL package of the entire listing" | Share all lived in Photos and in the YOUR FILES card below the toolbox. | New toolbox tile **Share everything** (`detail.sharePackage`): one ZIP with the walkthrough tour, every photo (JPEG copies, disclosure notes, retained originals), reels, the aerial opening, moving photos, the 3D scan, a `listing-details.txt` (address, facts, listing-page link, MLS-safe link) and a README. "Separate files" delivery shares the same set loose. Videos are read from where they live — nothing is copied or moved. |
| 2 | "Aerial intro needs to be next to re-render fly through" | Toolbox order | Aerial intro now sits beside Re-render fly-through; Share everything and Listing contact follow; the three Coming-soon cards close the grid. |
| 9 (Stephenie, build 56) | "Get started takes you to the listings you already have, not letting you start a new listing" | With 2+ homes the picker only listed existing homes. | First row is now **Start a new home** → the same name-it sheet a first home gets, then straight into the feature. |
| 1 (belt and braces) | sync loop | — | `ListingFactsSync.acknowledge` compares `sold_at` by instant (±1 ms), baseline keeps the server text for compare-and-set. |

Build number 60 in `project.yml` and both pbxproj configs. Swift parse-checked here (no Xcode in the sandbox); Codex runs the simulator and harness gates.

## Working as intended (your own notes)
- 7, 6: "Republish tour looks like it works" / "after airplane mode… it worked" — the build-59 fix is confirmed on a real phone.

## Not addressed tonight
- The export-sheet copy still says "Export photos" in a couple of secondary labels when it carries videos; cosmetic.
- Measurements / 3D cards remain Coming soon.

## What to do on your phone now (build 59)
1. Open 855 Central Ave once — the "1 listing update is waiting to sync" line should clear within a refresh.
2. Reel Studio on 2320 Chantilly: tap **Forget request…** on the stuck Photo 1 card, then Generate. It should run now (server fix). Build 60 makes the forget unnecessary.
3. Delete the "OWNER VIDEO QA…" listing again → Settings › Recently deleted should show it → Restore.

## Paste-ready prompt for Codex (build 60)

```
Build 60 — beta feedback fixes — 2026-10-11

Branch claude/build60-feedback-20261011 (two commits on top of 53b54bd). The backend half is ALREADY LIVE: migration build59_trash_listing (20261011230539), listings 52, ai-video 66 — do not redeploy or re-apply; just make sure the migration file and docs/releases/BUILD59-FEEDBACK-BACKEND-20261011.json are in the tree.

1. Fast-forward fix/build58-reel-integration-20261011 with the branch. Read docs/handoff/CLAUDE-BUILD60-FEEDBACK-20261011.md first.
2. Run the gates: deno test (functions sweep, expect 1907), the standalone tools/audit/*_test.ts, python3 tools/audit/test_database_runner.py (build58_db_controls now 52), the DB regression on a disposable cluster, apps/ios/tests/run-reel-request-recovery.py (new case: a definitive 4xx retires the unconfirmed marker; new mutant negative-refusal-keeps-marker), apps/ios/tests/run-photo-export-renderer.py, and the XCUITests (DetailMetadataRegressionUITests).
3. Add one XCUITest on the "rich" fixture: tap detail.sharePackage, expect export.deliverAs with "One ZIP file" selected and export.packageExtras listing at least "walkthrough-tour.mp4" and "listing-details.txt"; and one on Home with two fixture homes: tap home.getStarted, expect home.picker.newProject, tap it, expect the name-it sheet.
4. Archive 1.0.4 (60) to the internal TestFlight group. Do not touch 1.0.4 (57) in review; do not press Release.
5. Report the tip sha, gate outputs, CI run id, and the TestFlight 60 receipt.
```
