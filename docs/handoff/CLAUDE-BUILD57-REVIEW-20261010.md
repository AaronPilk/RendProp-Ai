# Claude review — build 57 on `fix/build57-portable-integration-20261010` (2026-10-10)

Reviewed after `git fetch origin`: tip `d5ed053e472594e94c408f9798d1fe30c705d4dd`, frozen runtime/tooling checkpoint `2a9d98f092780d5476a8cbfca63aeeccc31363da`, import `796bf86d05661c3cdbe77f072bb6b86688ba0861`. Read in full: `docs/handoff/CODEX-BUILD57-CROSSCHECK-20261010.md`, `CLAUDE-BUILD57-FIXES-20261010.md`, `docs/releases/BUILD57-PREP-20261010.md`, `docs/releases/BUILD57-BACKEND-DEPLOY-20261010.json`. Evidence from this pass: `~/Rendprop AI/claude-build57-review-evidence/`. Read-only worktree `~/Rendprop AI/claude-build57-review` (detached at `d5ed053`). Nothing was edited, deployed, rotated, funded, or submitted; John Apple untouched.

## Verdict

**GO to archive 1.0.4 (57) and upload it to TestFlight from `d5ed053`.** The frozen checkpoint `2a9d98f` is green on all 12 hosted jobs (run `38067429608`, readback 17:10Z); the tip differs from it only by one UI-test file and one doc. Dispatch CI on `d5ed053` as well (secret scan has not seen it) — do not wait for it to archive, but record it with the archive.

**NO-GO for App Store submission** until the artifact and acceptance gates in §6 are met. Nothing in this pass is a product failure; every open item is missing evidence (Apple artifact, site/Studio deploy readback, phone, real generation, invoice) or a fixture detail already closed by Codex.

## 1. Source binding (verified, not inferred)

| Claim | Result |
|---|---|
| Import `796bf86` == Claude's sandbox commit | **Byte-identical.** Full tree `6d57e3aaaf2144f79f0aab798e24193f4c479699` is exactly the tree of the sandbox commit `6d3b803` (the receipt commit on top of `b8b1f7e`). Ancestry differs, content does not. The "unavailable sandbox commit" therefore has an exact tree equivalent on origin. |
| `apps/ios` at import / checkpoint | `63a919cc04e950371455b3be542d51abffc4c9f5` at `796bf86`, `04ecb28`, `2a9d98f` (= Claude's build-57 native tree). |
| `apps/ios` at tip `d5ed053` | `047b86036f0418aa1e11aa344b170e6512c113b1` — differs from the checkpoint **only** in `apps/ios/RendpropUITests/DetailMetadataRegressionUITests.swift` (+27 −3, the lazy-grid scroll helper). `apps/ios/Rendprop`, `project.yml`, `Rendprop.xcodeproj` unchanged → the shipped app at the tip is the checkpoint's app. |
| External capture sources | `c71f06b295d74134a15236af4d653c8e9eac5bfe` at every commit (unchanged since `95243bf`). |
| ASC tooling | `c3daca18…` at import → `177be1888f8f4f776658d2edffd619d495ae816d` from `2a9d98f` (asc.py/README/bridge/test only). |
| functions / migrations / Studio / tour-host trees | `4422e415…` / `16ca946a…` / `e125dfe5…` / `8a8c5c3e…` at every commit from `796bf86` to `d5ed053` — identical to the sandbox commit, i.e. identical to what was deployed. |
| Backend receipt | all 52 `manifest.hashes` recomputed from the tip's `services/supabase/functions`: 52 match, 0 mismatch. |
| Codex commits reviewed | `04ecb28`: `.gitleaksignore` +5 (two exact `796bf86:…BUILD57-BACKEND-DEPLOY-20261010.json:generic-api-key:22|32` fingerprints — recomputed: they are the SHA256s of `_shared/api-key-config.ts` and `_shared/library-access.ts`, no secret) + the record. `2a9d98f`: `asc.py` `VERSION_STRING = "1.0.4"`, `find_editable_version` matches only that version string in an editable state, the cross-version fallback loop is deleted; README/bridge summary text; 5 new regressions, `python3 -m unittest discover -s tools/asc -t tools/asc` → **213 OK** here. `d5ed053`: UI-test helper + record. No product code in any of the three. |

## 2. CI

- `38067429608` (#223), `workflow_dispatch`, head `2a9d98f` (= frozen checkpoint), attempt 1, created 16:22:55Z, completed 17:08:41Z: **conclusion `success`, 12/12 jobs** — including **"Cloudflare Worker (tour-host)"**, the job that failed #220 at the Studio MP4 export step (S1's measured-loss detector is the fix), and "Offline audit evidence, consent and native harnesses" (macOS) **61/61 steps, 0 failed**. Read back from the GitHub API at 17:10:50Z (`claude-build57-review-evidence/ci-38067429608.json`).
- `38066790433` (#221, `796bf86`): secret scan failed on the two receipt checksums, then cancelled by concurrency. `38067111642` (#222, `04ecb28`): secret scan passed, cancelled by concurrency when `2a9d98f` was dispatched. Neither is release evidence; Codex's record says the same.
- **The tip `d5ed053` has no CI run.** Its delta from `2a9d98f` is one UI test file + one doc, which the build-56/57 rule accepts for an archive commit ("differ only under apps/ios/tests, apps/ios/RendpropUITests, tools/audit, docs"). Still dispatch CI on `d5ed053` before or alongside the archive: the secret scan has not seen that commit, and it costs nothing.
- Correction to my own handoff (`CLAUDE-BUILD57-FIXES-20261010.md` §4.4/§6): `ci.yml` contains **no `xcodebuild`** (0 references). The XCUITests do **not** run in CI; Codex is right. The simulator evidence for the Measurements card is Codex's local Release build (7/8, then the empty-listing fixture 2/2 after the scroll fix) — Mac-local, not hosted.

## 3. Product paths reproduced on the tip (sandbox, independent of Codex's Mac runs)

| Path | Command (tip code, `/tmp/ph2/tree` = `git ls-files` copy of `d5ed053`) | Result |
|---|---|---|
| Guest custody (B1 + cancelled handoff + dead-guest release) | `node --test tests/phase1/adoption-local-bindings.test.mjs` (real extracted `forgetServerIdentities`/`discardLocalAdoption`/`confirmLocalAdoption`/`PersistentStore`) | **153 assertions; 13/13 compiled mutants rejected** |
| Push isolation (B2) | `python3 apps/ios/tests/run-push-account-isolation.py` | **70 assertions; 10 fault controls; passed** |
| Measurements non-clickable (source oracle) | `python3 apps/ios/tests/run-native-ux-audit.py` | **passed, 16 runs** (toolbox block contains the Coming-soon card and neither `detail.floorPlan"` nor `FloorPlanView(`; Home has no `featureButton(.floorPlan)`) |
| Live original audio (S1) | `node tests/export-resume-browser.mjs` (Playwright Chromium 1243) | **passed: 12 runs, 7 checks, 4 preparation refusals, 0 errors** |
| | `node tests/export-audio-browser.mjs` | **9/9**: `double-speed-stall` and `decode-failure-stall` refused with the unchanged message; `double-speed-transient-waiting` exports; silent video, split segments, cancel handled |
| | `… --fault=live-original-audio` | **exit 1** on "Continuous speech through cutaway boundaries" (zero-RMS gap) — the mutant is still caught |
| Studio unit/build gate | `npm run verify` | **479/479**; build ok; `check-dist` passed, gzip **349,972 B** with my local opus line (**349,962 B** for the real tree) against the 350,000 B cap |
| Edge functions | `deno check` 25/25; `deno test --allow-all --node-modules-dir=auto .` | **1,897 / 0 / 1 ignored** |
| Database | `tools/audit/run_build57_db_controls.py`; `run_reaudit_database.py` | **66 assertions + 7 real races; 42** |

Sandbox caveats (same as the build-57 handoff): Linux Swift 6.1 with Foundation-only shims — no SwiftUI, no StoreKit, no simulator; opus substituted for AAC in the browser suites (Codex's Mac run used real H.264/AAC); `AdoptionProductionLibrary.absentFile` needs a Linux-only error-cast overlay for the harness (irrelevant on iOS).

## 4. Production (read-only readback 16:56Z)

Migration `20261010155636 build57_select_workspace_lock_order` on top (132 total); `select_workspace(uuid,uuid)` md5 `ab14c1f6454c971bef4f62a1d98c995d`, EXECUTE only service_role/postgres; `accept_org_invite` `09979c64…` unchanged. Functions: **ai-photo 69, ai-copy 36, notify 25, coach 35** (uploaded 15:57–15:58Z, entrypoints `source/supabase/functions/<fn>/index.ts`), verify_jwt true/true/false/true; no function has been redeployed since. Quiet: 3 devices, outbox 28 sent / 1 skipped / 0 pending, 0 deletions in flight. Nothing was deployed in this pass.

## 5. Findings

**Product failures: none.** Every repaired path in build 57 reproduces on the tip's code; no regression surfaced in 1,897 edge tests, the DB races, or the native harnesses.

**Fixture failures (closed):**
- F1 — `DetailMetadataRegressionUITests` empty-listing case: `back(from:)`/`openSheet`/`assertMeasurementsStaysComingSoon` asserted `detail.photos` exists without scrolling the lazy grid back into view. Codex's fix calls the existing `scrollTo` (outer-gutter swipe, bounded 24 iterations, still asserts existence and no navigation). Oracle not weakened; the Measurements no-navigation assertions are untouched. The initial 7/8 and the focused 2/2 are separate pieces of evidence, as Codex says — there is no single 8/8 run on record. Acceptable: the only failing assertion was the Photos-card existence after a scroll restore, with `Detail fixture empty` still on screen.

**Notes / risks (not blockers):**
- N1 — Studio gzip headroom is **38 bytes** (349,962 / 350,000). Any Studio change after 57 trips `check-dist`; either raise the cap deliberately or trim before the next Studio deploy.
- N2 — Six ledger-consuming functions (ai-video 63, ai-voice 46, ai-chapters 37, admin 36, property 23, studio 29) still run bundles without the new `cost_ledger_insert_failed` log line. Behaviour identical; redeploy with the next functional change, not now.
- N3 — `asc.py` now refuses any version other than an editable **1.0.4**. If 1.0.4 ever leaves an editable state, `metadata apply` will try to **create** another 1.0.4 (Apple rejects duplicate version strings — loud, not silent) and `build attach` raises. Fine for this release; read the printed version line on every `--dry-run`.
- N4 — The archive script's `--no-upload` performs a full signed archive (Codex is right): archive once, from `d5ed053`, after CI.
- N5 — Residuals carried unchanged from the build-57 handoff §7: same-user `serving_cost_reserve`/`app_video_cost_reserve` vs own-deletion lock order (transient), build-55 journal `detaching` edge, Linux-only harness quirks.

## 6. Gates before App Store submission (what is still missing, by class)

**Artifact / release evidence (Codex/Aaron on the Mac):**
1. CI `38067429608` is `success` 12/12 (done). Dispatch a run on `d5ed053` and record its id with the archive.
2. Archive 1.0.4 (57) from `d5ed053`; record the exact `xcodebuild archive`/`-exportArchive` lines, the 135 Swift inputs incl. the 8 external capture files, profile = App Store distribution, `get_task_allow=false`, `aps-environment=production`, IPA/binary/dSYM hashes, Apple build id and the processed build number read back (`manageAppVersionAndBuildNumber=true`).
3. Website + Studio deploy (`Ship-Rendprop-Build57-20261010.command` steps 4–6 or by hand) with readback: `/features` Coming-soon block, `/pricing` without floor-plan rows, `/support` "do not open yet", `cf-cache-status` on `/terms` and `/support` (purge if HIT).
4. App Store screenshot frame 1 re-captured from build 57 (current source shows a live Floor plan tool).
5. `asc.py build attach --build 57 --dry-run` → real; `metadata apply` only if the plan is text-only for 1.0.4; `review stage --dry-run` shows the draft with the app version + three monthly subscriptions. No `review send`.

**Phone (TestFlight 57, real device):**
- Listing page: Measurements card reads Coming soon, is not a button, tapping leaves the page where it is; Home unchanged.
- B1: 1.0.3 (42) guest with an offline listing → upgrade → Apple sign-in shows it under the adopted workspace; 57-specific: a guest whose refresh token was revoked before signing in still finds its drafts after Apple sign-in; a cancelled handoff (sign out before the receipt) leaves the drafts publishable.
- B2: Delete account → other Apple ID on the same phone → `POST /me/devices` succeeds; offline sign-out > 1 h → sign-in registers.
- The standing list: fresh-install sign-in, Team invite/join/seat removal, StoreKit purchase/cancel/restore/Ask-to-Buy, camera/export/Maps/tel, iOS 16 push + generic lock-screen alert for a foreign recipient, Safari watch mode + Turnstile, one real buyer enquiry.

**Real generation:** one ordinary (non-sponsored) photo edit, reel and aerial with settled holds; provider behaviour on a smuggled condition instruction under the CONDITION_LOCK; Kontext truncation at 3,310 chars.

**Invoice / Apple:** supplier invoices vs catalog holds (6.7¢ photo, 24.3¢ reel, 104¢ aerial, 50¢ hosting reserve); a 15% commission line from 2026-10-11; ASC state read back (USA-only, $49/$99/$249 monthly, one-week trial, annual SKUs off sale).

**Evidence Claude cannot read:** `/Users/pilksclaes/LocalRendpropAudits/build57-crosscheck-20261010/` (Codex's logs, xcresults, receipts) — treated as Codex-reported, consistent with everything reproduced here.

## 7. Prompt seed for the final pass (after archive + deploys)

Read this file, `CODEX-BUILD57-CROSSCHECK-20261010.md` and the archive receipt. Bind the archive commit to `d5ed053` (native tree `047b8603…`, app tree equal to `63a919cc…` under `apps/ios/Rendprop`), CI `38067429608` + the tip run, production (migration `20261010155636`, `select_workspace` `ab14c1f6…`, ai-photo 69 / ai-copy 36 / notify 25 / coach 35), TestFlight 1.0.4 (57) by Apple build id, and the Cloudflare worker versions. Return GO/NO-GO for submission with the phone/model/invoice list separated from product findings. Do not edit, deploy, change credentials/visibility/funding, touch John Apple or submit to Apple.

---
## Addendum — CI 38067429608 final readback (17:10:50Z)
`status: completed`, `conclusion: success`, head `2a9d98f092780d5476a8cbfca63aeeccc31363da`, 12/12 jobs success, native job 61/61 steps with 0 failures, completed 17:08:41Z. #220's failing step ("Studio MP4 export, AAC narration and continuous agent audio") passed in the tour-host job of this run.