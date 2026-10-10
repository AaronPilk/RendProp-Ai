# Build 57 — Claude fixes handoff (2026-10-10)

Owner mandate for this round: "apply all fixes and test until it's ready; on
the listing page Measurements is still clickable, it needs to be Coming soon
like 3D model". Seven parallel agents (N1 listing, N2 custody/push, S1 Studio
export, D1 database, E1 functions, W1 site/metadata, R1 release evidence) plus
the lead's integration pass. Everything below is what was actually done and
measured; nothing is reported from receipts Claude could not read.

Status line: **BACKEND LIVE · BRANCH COMMITTED (not pushed — sandbox has no
GitHub credentials) · CI PENDING · ARCHIVE PENDING · GO/NO-GO: pending the
independent pass after CI + TestFlight 57**

## 1. Binding

| Item | Value |
|---|---|
| Branch | `claude/build57-fixes-20261010` (worktree `~/Rendprop AI/build57`) |
| Base | `b6a3d80` = Codex build-56 code `6d320d6` + docs (`740438f`, `b6a3d80`); native base tree `apps/ios` = `10058cf6507e486b23b320be13cff752fa5a7280` |
| Build-57 code checkpoint | `b8b1f7e8a99d2cfef5c0f480580de2be0c159252` (+ the receipt commit on top; see git log) |
| Native tree at `b8b1f7e` | `apps/ios` = `63a919cc04e950371455b3be542d51abffc4c9f5`; `tools/spatial-spike/capture-ios/Sources` = `c71f06b295d74134a15236af4d653c8e9eac5bfe` (unchanged); `tools/asc` = `c3daca181f2ee2400524e6a10747ca2a734852ab` (unchanged) |
| Native app diff vs base | 7 files under `apps/ios/Rendprop` + `project.yml` + `Rendprop.xcodeproj` (+86 −28); UI tests and harnesses separately |
| Version / build | `MARKETING_VERSION 1.0.4`, `CURRENT_PROJECT_VERSION 57` (`apps/ios/project.yml:10`, both `Rendprop.xcodeproj` configurations) |
| Archive source commit | to be recorded by whoever archives (must be `b8b1f7e` or a descendant differing only under `apps/ios/tests`, `apps/ios/RendpropUITests`, `tools/audit`, `docs`) |
| Apple build | not yet archived — id/number/IPA/dSYM to be read back from ASC after upload (`manageAppVersionAndBuildNumber=true`) |
| Production after this round | migration `20261010155636 build57_select_workspace_lock_order` (repo file `20261010141500_…`, SHA256 `363e66d4ea43f87082fdb0422416e5734224af6d13cd232152f0a9ff809f5cbd`); `select_workspace(uuid,uuid)` md5 `ab14c1f6454c971bef4f62a1d98c995d` (was `922f967fa624cc026dbe6f60ad922a0e`), definer, `search_path=""`, EXECUTE only service_role/postgres; 132 migrations total. Functions: ai-photo 68→**69**, ai-copy 35→**36**, notify 24→**25**, coach 34→**35**; verify_jwt unchanged (true/true/false/true); source read back and hash-matched (36/25/14/24 runtime files) — receipt `docs/releases/BUILD57-BACKEND-DEPLOY-20261010.json` |
| Functions NOT redeployed | ai-video 63, ai-voice 46, ai-chapters 37, admin 36, property 23, studio 29 import `_shared/ledger.ts`, whose only change is an extra structured `console.error` line on insert failure. Their live bundles therefore predate that line; behaviour is identical. Redeploy them with the next functional change (`node apps/studio/scripts/deploy-backend.mjs --functions ai-video,ai-voice,ai-chapters,admin,property,studio --run`). |

## 2. What build 57 changes

### N1 — Listing page: Measurements is Coming soon (the owner's defect)
- `apps/ios/Rendprop/Screens/FlythroughDetailView.swift:235-241`: the `ListingToolLinkTile` → `FloorPlanView` entry is replaced by a plain `ListingToolCard(title: "Measurements", sub: "Coming soon", icon: "ruler", gradient: RPGradient.plan, dimmed: true)` with `.accessibilityElement(children: .combine)` and id `detail.measurementsComingSoon` — the same pattern as the 3D floor plan / 3D walkthrough cards and as Home (`RendpropApp.swift` `comingSoonTile("Measurements", …)`). Tile order unchanged; `FloorPlanView`/`FloorMeasurementsView` stay compiled but unreachable.
- Routes that could still open the hidden screen: `RendpropApp.swift` `routeDestination` now lands `.floorPlan` on `FlythroughDetailView` (coach chip, stale push); server-side the coach `open_floor_plan` action is retired (`services/supabase/functions/coach/actions.ts` `RETIRED_ACTIONS`, dropped in `sanitizeCoachOutput`; prompt step 6 tells the model to say Coming soon; `knowledge.ts` facts rewritten; `docs/COACH-CONTRACT.md` row updated). Contract enum unchanged (three-way lockstep preserved).
- Copy: in-app guide (`HomeListingsView.swift` `.measurements` and `.spatial` steps), offline coach replies (`CoachModel.swift` floor-plan topic and `facts_review` hint), App Store `description.txt:15`, `review_notes.txt:7/9`, `keywords.txt` ("floor plan" → "photo editor"), `docs/appstore/{README,review-notes,review-readiness}.md`, `docs/appstore/screenshots/plan.json` (+ README note: frame 1 source capture shows the 1.0.3 Home with a live Floor plan tool and must be re-captured from build 57), public site (`features.html` floor-plans section is a Coming-soon block; `index/pricing/compare/support.html`, `llms.txt`, `src/index.ts` fallback landing), `docs/floor-plan-measurements.md` + `README.md` notes.
- Tests: `DetailMetadataRegressionUITests` (7 fixtures) asserts every Coming-soon card exists, reads "Coming soon", is not a button, `detail.floorPlan` is absent, and `assertMeasurementsStaysComingSoon` taps the card and proves no "Measurements & plans"/"Floor plan" navigation bar appears; `BetaPolishUITests.testMeasurementsIsComingSoonOnTheListingPage` (new); the two manual-measurement journeys are parked behind `measurementsToolboxLinkRestored` (XCTSkipUnless) with their stale "Floor plan" titles corrected to "Measurements & plans" for the build that re-enables them. `apps/ios/tests/run-native-ux-audit.py` source oracle: toolbox block must contain the Coming-soon card and must not contain `detail.floorPlan"` or `FloorPlanView(`.
- Native: **yes** (archive required).

### N2 — Guest custody and push cleanup (Claude re-audit B1/B2)
- B1 verified under production ordering (`applySession` fires `onAccountChanged` before `userID = sub`; journal captured while the guest is still active; `confirmLocalAdoption` re-owns every journaled row incl. never-synced drafts; build-55 repair on reload; rollback on persist failure; samples never stamped). Two gaps fixed:
  1. `discardLocalAdoption` (`RendpropApp.swift:439-466`): a cancelled handoff (sign-out, clear, stale record at sign-in) now releases exactly the rows the journal named that are still owned by the dead source — `cloudSyncOwnerID`/`cloudDraftOrgID` cleared, `cloudDetachedServerID` kept so an explicit publish creates afresh and auto-sync never duplicates; foreign/sample/re-owned rows untouched; persistence failure rolls listings and journal back.
  2. `forgetServerIdentities` (`RendpropApp.swift:235-273`): a guest whose session died with **no** handoff (revoked refresh token / definitive 4xx → `signOut(preservingAdoption: true)`; no new anonymous sessions are created) used to get its never-synced drafts stamped with the dead guest id at the next Apple sign-in — hidden forever. Build 57 remembers the session kind from the token (`AuthStore.Keys.sessionIdentified` = `auth.supabase.sessionIdentified.v1`, written in `init()` from the cached token and in `applySession` after the outgoing callback) and, when the remembered subject is known-anonymous and no unconfirmed journal exists, releases that identity's rows to the phone instead of fencing them. Identified sources, foreign custody, pending journals and devices without the record (pre-57) keep the fence.
- B2 verified: terminal 401/403/RP401 retire the queue entry; network/5xx stay retryable; signed-out relaunch retries; corrupt queue recovers only after a verified secure removal; delete-account never queues the dead credential; `wipeLocalData` clears `auth.pendingPushUnregisters.v1` and `push.unregisterStorageBlocked.v1`; APNs tap/foreground still require recipient == current owner.
- Native: **yes**.
- Proof (all executed in the sandbox on Swift 6.1 with Foundation-only shims — see §3): `tests/phase1/adoption-local-bindings.test.mjs` 153 assertions + **13** compiled mutants rejected (base: 124+11; new: cancelled-handoff block, dead-guest release block, `fence-dead-guest-custody`, `release-journaled-guest-custody`); `apps/ios/tests/run-push-account-isolation.py` 70 assertions + 10 fault controls (base 67+10); `tools/audit/required-account-onboarding-20261008` 50 checks + 12 controls; `tools/audit/apple-code-session-20261004` 29; `tests/phase1/auth-sync-identity.test.mjs` green. Fixture stubs gained `Keys.sessionIdentified` (`required-account-onboarding` + `apple-code-session` templates, `auth-sync-identity` scaffold).
- Residual (documented, not fixed): `serving_cost_reserve`/`app_video_cost_reserve` lock billing org then content org without a profile lock and can deadlock against the **same** user's own `prepare_account_deletion` when ids sort the other way (D1 reproduced for `serving_cost_reserve`); transient, state stays consistent; fix recipe in D1's notes (`order by id for update` over both orgs + `launch_blockers_pg.py` anchors).

### S1 — Studio export: CI #218/#220 "Original audio playback stalled during export"
- Root cause (product): `apps/studio/src/editor/export.ts` refused the export on the first `waiting`/`stalled` event of the live media element (2x / undecodable-audio path). Chromium fires `waiting` for every decoder/renderer underflow, including ones already over at dispatch; on the 3-vCPU hosted macOS runner that is routine. Reproduced locally by starving only the renderer (SIGSTOP 120 ms every 400 ms): every 2x run was refused with the identical message at `export-resume-browser.mjs:207`; measured actual silence ≤ 10 ms. "clock-baseline delivered 0 frames" is expected (that plugin bypasses `fixture.requestExportFrame`), not a symptom.
- Fix: measured loss instead of events — `MAX_ORIGINAL_AUDIO_LOSS_SECONDS = 2/30`; after `video.play()` resolves both clocks are captured and each loop iteration compares recording time elapsed with media time elapsed (÷ speed); refuse on two consecutive readings above 67 ms. Same user-facing message; buffer path, photos and the 10 s video-stall check untouched.
- Thresholds unchanged: line 207 still `toBe("done")` with 20 000 ms; the 7 200-sample opening window, the 400–480 Hz continuity bound, the deliberately-short-input refusal and the dropped-speech mutant are as before. New control `double-speed-transient-waiting` (a `waiting`+`playing` pair with no loss must export); `double-speed-stall` / `decode-failure-stall` still refused; `--fault=live-original-audio` mutant still fails.
- Proof (sandbox, Linux Chromium 1243, opus substituted for the absent AAC encoder in a local-only copy): `npm run verify` typecheck/479 unit/build/check-dist, gzip **349,962 B** (ceiling 350,000); `export-resume-browser.mjs` 12/12 exports + 4 preparation refusals, 2 consecutive clean runs and 1 run under the renderer-freeze stress that reproduced #220 on the base; `export-audio-browser.mjs` 9/9 + mutant exit 1; `finishing-audio-probe-controls` 1/13; `cloud-editor-browser` 16; `conversation-browser` 16. Only macOS CI can run the H.264/AAC assertions and `finishing-browser.mjs`.
- Native: no. **Studio must be redeployed** (wrangler, Mac).

### D1 — Database
- Fresh PostgreSQL 18 cluster: `ci-bootstrap.sql` + all migrations in `LC_ALL=C` order, 0 errors; local md5 of the 7 pinned functions = production; `invariants.sql` **All 270 invariants passed** (fresh + CI driver replays); every `services/supabase/tests/*.sql` fixture and every runnable `tools/audit/run_*.py` driver green (counts in §3).
- New controls `services/supabase/tests/build57_db_controls.sql` (66 assertions) + `tools/audit/run_build57_db_controls.py` (7 real two-session races): non-switcher can never select/activate a second owned library (RP403 / own); adoption after a live Team binding keeps the bound library active (4-arg and legacy 3-arg overload); first-time invite acceptance vs deletion preflight — no deadlock; deleted Team child + late settlement counted once, forged/mismatched/org-less receipts refused; token takeover under the canonical lock; legacy 3-arg `adopt_anonymous_org` is service_role/postgres-only, definer, delegates to the resolver (kept — `anonymous_adoption_recovery.sql` asserts it). Wired into `ci.yml` (both fixture lists + `db-publication-regression`).
- Defect fixed: Team owner's `select_workspace(owner, agent_private)` vs `prepare_account_deletion(agent)` deadlocked when the private library id sorts before the Team id (reproduced two-session). Migration `20261010141500_build57_select_workspace_lock_order.sql` locks `orgs where id in (p_org, library_team_org(p_org)) order by id for update` after the profile; pins predecessor `922f967f…` → `ab14c1f6…`; ACL unchanged. Runner proves the predecessor deadlocks and the fix does not (both id orders). Five runners' `superseded-followup-refused` expectation moved from `notification_register_device_session` to `select_workspace`.
- Live: applied 2026-10-10 as `20261010155636`; readback above.

### E1 — Edge functions
- `_shared/custom-photo-prompt.ts`: negated preservation verbs stay with their negation (`don't leave the stain visible`, `do not keep the wallpaper`); FIXED vocabulary gains kitchens/bathrooms/islands/worktops/benchtops/units/vanity/backsplash/tiles/railings/balcony/wiring/street signs/neighbouring house; defect nouns gain damp/wet/dark patches and spots-on-ceiling; material substitution covers `put … down`, `SURFACE instead`, bare surfaces (`with hardwood`, `marble`), `new SURFACE`; preservation clauses reject remodel words / renewed condition unless `unchanged/as is`; location prepositions extended; "look/appear new" → clarify. Closed bypasses: `remove the toys, keep the walls freshly painted`, furnishing `grey sofa on new hardwood` / `grey sofa and a white kitchen` / `cream sofa, keep the walls freshly painted`, and 18 more probes. Benign requests stay ready (`remove the boxes but don't touch the walls`, `brighten the kitchen. keep the paint color exactly as is.`, `add a sofa and preserve the garage door color`, `remove the toys, keep the walls white`, 600-char declutter, furnishing briefs, ~60 others). Polisher re-check inherits all of it.
- `notify/apns.ts` + `deliver.ts`: `pushDeepLink` (bare https/path only, no query/fragment/`..`), `pushCategory` (bounded), `recipient_user_id` must be a UUID, `deliverPush` pushes only to devices whose `user_id` equals the row's owner; serializer already dropped names/addresses/email/phone.
- `leads/index.ts`: unchanged contract re-proven (`{ok:true,accepted:true}` on create and dedup; honeypot `{ok:true}`; rate limit 429 and Turnstile 403 before any lookup).
- `_shared/ledger.ts`: structured `cost_ledger_insert_failed` line (request_key prefix 8, stage, route_id, feature, provider, model, code, message ≤200) — no behaviour change.
- Tests: `deno check` 25/25; `deno test` **1,897 / 0 / 1 ignored** (base 1,885); `tools/audit/uploads_*_test.ts` 62/62; `listing-facts-handler` 97 assertions. Lead's coach retirement test included (coach suite 47/47).
- Native: no. Deployed (§1).

### W1 — Site, metadata, legal
- Limits after W1 (lead re-measured at `b8b1f7e`): name 8/30, subtitle 29/30, promo 153/170, description **3,863 chars (3,915 bytes)**/4,000, keywords **96 bytes**/100, review notes **3,939**/4,000, release notes 1,157/4,000; no yearly/annual offers; contact aaron@pilk.ai; "Get started" wording kept.
- Public site: floor plans / measurements no longer promised anywhere (features section is a Coming-soon block; pricing value-math rows removed, traditional total $635–1,450 → $555–1,300, "six months of Pro" → "more than five months"; compare/support/index/llms.txt aligned; monthly-only, 90-day retention and "limited shared allocation" copy kept; CSP boot-script hash unchanged; 5 JSON-LD blocks parse).
- Legal: served `/terms` + `/privacy` (`src/legal.ts`, untouched) snapshot rendered to `docs/legal/RENDPROP-LEGAL-NOTICE-20261010.md`; the 20261006 file points to it.
- tour-host `npm ci && npm run typecheck && npm test`: all 11 scripts green (unbranded 687, routes 732, upstream 782, lead form 430, legal 93, spatial 114, bundle gate 28, media-delivery 93, media-controls 4/4 rejected, client delivery, audit boundaries). Playwright scripts need the Mac.
- **Site must be redeployed** (wrangler, Mac). Live anomaly to check after deploy: plain `/terms` and `/support` served stale October-6/September copies to the fetch tool while `?x` variants were current — check `cf-cache-status` from the Mac and purge those two paths if HIT.

### R1 — Evidence cross-check
`docs/releases/BUILD57-PREP-20261010.md`: every checkable build-56 claim matched the repo (commit graph, native tree identity, 48+89 SHA256s, both migration SHA256s, 8 function md5s incl. the `$pin$` chains, `.gitleaksignore` single fingerprint, `ci.yml` +3 without `continue-on-error`). Discrepancies: CI #220 was FAILURE (not "in progress"); gitleaks "667/669 commits" not reproducible (543/545 here); the "135 compiled Swift inputs" include 8 files under `tools/spatial-spike/capture-ios/Sources` outside the `apps/ios` tree hash; `asc.py` hard-codes `VERSION_STRING="1.0"`; `exportOptions.plist` manages the build number. Unverified: all 36 `/Users/pilksclaes/LocalRendpropAudits/…` receipts, Apple state, IPA/binary/dSYM hashes, Cloudflare versions.

## 3. Tests executed in the sandbox (Linux arm64; Swift 6.1.2 toolchain with `CryptoKit`/`Combine`/`FoundationNetworking` shims — Foundation-only harnesses, no SwiftUI)

| Suite | Command | Result |
|---|---|---|
| Edge functions | `deno check */index.ts`; `deno test --allow-all --node-modules-dir=auto .` | 25/25; 1,897 pass / 0 fail / 1 ignored |
| Uploads audit + listing facts | `deno test ../../../tools/audit/uploads_*_test.ts`; `listing-facts-handler-20261004.ts` | 62/62; 97 assertions |
| DB fresh replay | all 132 repo migrations + `invariants.sql` | 0 errors; 270/270 |
| DB CI driver | `tools/audit/run_database_regression.py` | 133 migrations, 109 replayed twice, 270/270 twice, negative control exit 3 |
| DB drivers | `run_reaudit_database` (42/41/4 races/6 guards), `run_legacy_notification_sessions` (23/10/29), `run_account_library_safety` (77 + 8 controls), `run_team_private_libraries` (92/28/34), `run_workspace_selection` (28), `run_private_internal_testing`, `run_personal_card_regression`, `*_pg.py` ×6, `run_build57_db_controls` (66 + 7 races) | all PASS |
| Adoption local bindings | `node --test tests/phase1/adoption-local-bindings.test.mjs` | 153 assertions; 13/13 mutants rejected |
| Phase-1 node suite | `node --test tests/phase1/*.test.mjs` | 33/35 green; the 2 failures are Linux-only (`RelativeDateTimeFormatter` missing in `Formatters.swift`; `/usr/bin/xcrun` hard-coded in the onboarding runner — run separately below) |
| Push account isolation | `python3 apps/ios/tests/run-push-account-isolation.py` | 70 assertions; 10 controls; passed |
| Required-account onboarding | `tools/audit/required-account-onboarding-20261008/run.py` | accepted; 50 checks; 12 compiled negative controls |
| Apple-code session | `tools/audit/apple-code-session-20261004/run.py` | 29 assertions |
| Native UX audit | `apps/ios/tests/run-native-ux-audit.py` | passed, 16 runs |
| Custom photo prompt (native) | `apps/ios/tests/run-custom-photo-prompt.py` | 15 controls + 11 source gates |
| Adoption owned identity | `apps/ios/tests/run-adoption-owned-identity.py` | PASS + 16 fault controls |
| Native trial | `apps/ios/tests/run-native-trial.py` | 86 checks; 23 controls |
| Native account deletion | `tools/audit/run_native_account_deletion.py` | guard removals rejected |
| Floor-measurement export / gallery sync / native media export / photo-gallery reconciliation | `tools/audit/*/run.py` | 18 / 46 / 118 / passed |
| Not runnable here | `listing-facts-review` (Linux currency formatting — fails identically on the base), `measurement-export` (CoreGraphics), `reel-request-recovery` (timeout), XCUITests, `run_deletion_regression`/`run_spatial_regression`/`run_adoption_regression`/`run_bounded_media_delivery`/`run_backend_billing_authority` (psql/PG/git constraints) — all land in CI `audit-harnesses` on macOS |
| Studio | `npm run verify` (479 unit, gzip 349,962/350,000), export/audio/finishing/cloud/conversation browser suites | green (opus-substituted locally; AAC on macOS CI) |
| tour-host | `npm run typecheck && npm test` | 11/11 scripts green |
| Swift syntax | `swiftc -parse` on every changed `.swift` | 9/9 ok |

## 4. Deploy plan — what is done and what the Mac must do

### 4.1 Backend — DONE (lead, 2026-10-10 ~15:57Z)
Migration applied via Supabase MCP after the predecessor-pin readback (`922f967f…` live); functions deployed with the repo's own tool: `node apps/studio/scripts/deploy-backend.mjs --functions ai-photo,ai-copy,notify,coach --run` (Supabase CLI 2.120.0, access token from `_bridge/.supabase-token`, never printed) — stages the source closure (52 files), enforces `function-jwt-policy.json`, deploys one function per invocation, downloads and hash-compares each bundle. Receipt committed at `docs/releases/BUILD57-BACKEND-DEPLOY-20261010.json`. Production quiet at readback: 3 devices, outbox 28 sent / 1 skipped / 0 pending, 0 deletions in flight. No data backfill, no funding rows, no John Apple.

### 4.2 Site + Studio — PENDING (Mac, wrangler)
`docs/handoff/BUILD57-SHIP.command` (also at `~/Rendprop AI/BUILD57-SHIP.command`) does, in order: push the branch, run the Mac-only native harnesses, `npm ci && npm run predeploy && wrangler deploy` for tour-host, `npm ci && npm run verify && wrangler deploy` for Studio, then prints the archive command. Readback after: `/features` no longer promises floor plans, `/terms` `/privacy` `/support` match the repo (check `cf-cache-status`; purge `/terms` and `/support` if HIT).

### 4.3 iOS 1.0.4 (57) — PENDING (Codex/Aaron on the Mac)
Prerequisites: branch pushed, CI green on the archive commit, `git status --short` empty.
```
bash tools/asc/bridge-600-archive-upload.sh --no-upload   # dry run: xcodegen generate → archive
bash tools/asc/bridge-600-archive-upload.sh               # archive → export → upload
```
(key from `~/Rendprop AI/_bridge/.asc`, never echoed; team 5F5C5G25Y6; `exportOptions.plist` method app-store-connect, `manageAppVersionAndBuildNumber=true`, `uploadSymbols=true`). Record here afterwards: exact command line, archive commit, IPA SHA256, binary SHA256, dSYM UUID, profile = App Store distribution, `get_task_allow=false`, `aps-environment=production`, 135-input source binding.

### 4.4 CI — PENDING
Dispatch "CI" on `claude/build57-fixes-20261010` (the ship script opens the Actions page). Required: all 12 jobs green — `audit-harnesses`, `web-client-contracts`, `style-policy`, `studio`, `worker-edge` (the #220 step "Studio MP4 export, AAC narration and continuous agent audio" is the one S1 fixed), `upload-gateway`, `edge-functions`, `db-migrations`, `db-publication-regression` (now includes `run_build57_db_controls.py`), `python-worker`, `ios-static`, `secret-scan`. Record run id, head sha, conclusion, attempt number.

## 5. App Store steps (owner-run, after CI green and TestFlight 57 VALID)
1. `python3 tools/asc/asc.py status --skip-product com.rendprop.app.team.annual` — build 57 `VALID`; `asc.py` still hard-codes `VERSION_STRING = "1.0"` and finds 1.0.4 only by fallback: run every command with `--dry-run` first and stop if it prints any version other than 1.0.4.
2. `python3 tools/asc/asc.py build attach --build 57 --dry-run` → real run; readback: version `39ff74df-71d4-4bf1-92f4-9c709e7f4366` linked build number 57.
3. `python3 tools/asc/asc.py metadata plan` → `metadata apply` only if text-only for 1.0.4 (description 3,863, review notes 3,939, keywords 96 B). Screenshot frame 1 must be re-captured from build 57 before it is uploaded (the source capture shows a live Floor plan tool).
4. `review stage --dry-run` → draft `ecf0a17a-6fdd-40c9-8e0b-39f345b1b830` still READY_FOR_REVIEW with the app version + three monthly subscriptions. No `review send`, no `review submit`.
5. Release type MANUAL. **No submission until the independent GO.**

## 6. Still unverified (carried from `CLAUDE-FINAL-AUDIT-20261010.md`, updated)
**Phone (build 57 on TestFlight):** 1.0.3 (42) guest with an offline listing → upgrade → Apple sign-in shows it under the adopted workspace (B1); a guest whose refresh token was revoked before signing in keeps its drafts after Apple sign-in (new 57 path); Delete account → other Apple ID → `POST /me/devices` succeeds (B2); fresh-install sign-in; Team invite/join/seat removal; StoreKit purchase/cancel/restore/Ask-to-Buy; camera/export/Maps/tel; iOS 16 push registration and a generic lock-screen alert for a foreign recipient; Safari watch mode + Turnstile; one real buyer enquiry; **listing page: the Measurements card reads Coming soon, is not a button, and tapping it leaves the listing page where it is** (the XCUITests assert exactly this on the simulator in CI).
**Real generation:** one ordinary photo edit, reel and aerial with settled holds; provider behaviour on a smuggled condition instruction; Kontext truncation at 3,310 chars.
**Invoice / Apple:** supplier invoices vs catalog holds; a 15% payout line from 2026-10-11; ASC state (USA-only, $49/$99/$249 monthly, one-week trial, annual SKUs off sale); TestFlight 56/57 Apple build/IPA hashes.
**Evidence not readable by Claude:** `/Users/pilksclaes/LocalRendpropAudits/…`.

## 7. Known, not fixed in 57 — do not reopen without Aaron
Carried from the build-56 handoff (manual photo retry operation UUID; uncertain historical holds; multi-library billing grouping; signed price/offer persistence; dormant Python cost accounting; legacy invited Studio/brokerage rows; old-owner hidden caches; media proxy amplification). Added in 57: the same-user `serving_cost_reserve` / `app_video_cost_reserve` vs own-deletion lock order (transient, D1 recipe); six ledger-consuming functions not redeployed for a log-only change; the build-55 journal `detaching` edge (a D→E→D switch leaves `appliedToCurrentState=false`, so the reload repair never runs for that TestFlight-only population); Linux-only harness quirks (`AdoptionProductionLibrary.absentFile` reads the underlying error with `as? NSError`, which is nil on swift-corelibs — irrelevant on iOS).

## 8. Next independent pass (prompt seed)
Read this file, `docs/releases/BUILD57-PREP-20261010.md` and `docs/releases/BUILD57-BACKEND-DEPLOY-20261010.json` in full. Bind the archive commit (expected `b8b1f7e` or a docs/tests-only descendant), the CI run (all 12 jobs, every step), production readbacks (migration `20261010155636`, `select_workspace` md5 `ab14c1f6…`, ai-photo 69 / ai-copy 36 / notify 25 / coach 35) and immutable TestFlight 1.0.4 (57). Reproduce N1/N2/S1/D1/E1 through the real paths; keep the Home design, listing toolbox and private-library boundaries; treat unmounted receipts as missing. Return GO/NO-GO with reproducers, separating product failures, fixture failures and missing evidence; list phone/generation/invoice acceptance separately. Do not edit, deploy, change credentials/visibility/funding, make paid calls, touch John Apple or submit to Apple.
