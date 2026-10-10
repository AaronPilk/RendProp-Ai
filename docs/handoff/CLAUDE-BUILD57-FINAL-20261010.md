# Claude final review — build 57 as shipped and submitted (2026-10-10, ~19:30Z)

Scope: `fix/build57-portable-integration-20261010` tip `3cfd32a` (= `d5ed053` + two docs-only commits `7860d98`, `3cfd32a`); `docs/handoff/CODEX-BUILD57-SHIP-20261010.md`, `docs/releases/TESTFLIGHT-57-20261010.json`, `docs/releases/APPSTORE-57-20261010.json`, my earlier `CLAUDE-BUILD57-REVIEW-20261010.md` (preserved byte-identical in `docs/handoff/`). Read-only: nothing edited, deployed, rotated, funded, resubmitted; John Apple untouched. Evidence: `~/Rendprop AI/claude-build57-review-evidence/` (+ `ci-224-audio-export/`).

## Verdict

**The submitted artifact is the reviewed code, and nothing found in this pass calls for withdrawing it or resubmitting.** 1.0.4 (57) is in `WAITING_FOR_REVIEW` with **MANUAL** release (submitted 17:53:19Z on the owner's instruction, one request, `submission_accepted=true`).

- **GO — leave the submission in review.** Product paths reproduce; the only red hosted job on the archive commit is an environment underrun that the code handles correctly (§3); website and Studio live deployments bind to the tip (§4).
- **NO-GO — do not press "Release this version" yet**, even if Apple approves first. The release gate is the owner's phone acceptance on the TestFlight build (same binary as submitted) plus the model/invoice evidence in §6. Manual release makes this a free hold.

## 1. Artifact binding (Codex-reported receipts, cross-checked where readable)

| Item | Value | Checked by Claude |
|---|---|---|
| Archive source | `d5ed053e472594e94c408f9798d1fe30c705d4dd` (branch tip at archive time; later commits are docs only: `git diff --name-only d5ed053 3cfd32a` → 5 files under `docs/`) | yes |
| App code at `d5ed053` | `apps/ios/Rendprop` + `project.yml` + `Rendprop.xcodeproj` identical to the CI-green checkpoint `2a9d98f` (only `RendpropUITests/DetailMetadataRegressionUITests.swift` differs); `apps/ios` tree `047b8603…`, external capture `c71f06b2…`, ASC tooling `177be188…` | yes |
| Compiled inputs | 135 tracked Swift inputs (127 app + 8 external) + 1 generated asset-symbol source, `compiled_inputs_match_source=true` | count matches R1's inventory; file-level match is Codex-reported |
| Apple build | id `46e2df20-e688-4e14-afa7-88655f28e8ba`, 1.0.4 (57), `VALID`, `APP_STORE_ELIGIBLE`, internal `IN_BETA_TESTING`, external beta never sent | Codex-reported (no ASC access from here) |
| Binary identity | archive/IPA/dSYM UUID `D9DCDA5B-7D3C-348C-A069-35F352A7FD77`; IPA SHA256 `dda4e6f5…`, archived binary `ef1cf5f6…`, exported binary `71a8596b…`, dSYM `235c2b75…`; App Store distribution profile, `get-task-allow=false`, `aps-environment=production`, signatures verified, no Lab compile flag, `manageAppVersionAndBuildNumber=false`, 1 upload attempt | Codex-reported (`/Users/pilksclaes/LocalRendpropAudits/build57-ship-20261010/` not readable here) |
| App Store draft | version `39ff74df-…` → build 57; review `ecf0a17a-…` = app version + three monthly subscription versions; 7 screenshots COMPLETE (frames 1 and 5 replaced from build-57 simulator pixels — frame 1 was my gate); en-US text metadata only; no price/availability/age-rating mutation | Codex-reported |
| Submission | `submitted_date 2026-10-10T17:53:19.511Z`, review and version states `WAITING_FOR_REVIEW`, release type MANUAL, known open items declared at submission (intermittent Studio audio-export CI, phone acceptance, provider/invoice) | Codex-reported |

## 2. CI on the archive commit

- `38067429608` (#223) at `2a9d98f`: **12/12 success** (17:08Z) — binds the app code (identical under `apps/ios/Rendprop` to `d5ed053`).
- `38071986005` (#224) at `d5ed053`: **failure — 11/12**; the native macOS job (61 steps) and every other job succeeded; "Cloudflare Worker (tour-host)" failed at "Studio MP4 export, AAC narration and continuous agent audio". The hosted log (job 114271106587, read through the signed-in browser) shows the export-resume suite **passed** (7 checks, 12 runs) and the audio suite passed `normal-speed-stall`, `split-segments`, `double-speed-pitch` (2x at 879 Hz, RMS 0.088) and refused `double-speed-stall` as required, then refused **`double-speed-transient-waiting`** (`ok=false, decodeCalls=0, injected=true`) and stopped.
- Same test file and same product source passed this control in #223 fifty minutes earlier on the same runner class → nondeterministic on the hosted runner, not a code change.

## 3. The #224 refusal, classified: environment underrun, detector correct

What I did (sandbox, tip code, `claude-build57-review-evidence/ci-224-audio-export/`): an instrumented *local-only* copy of `export.ts` records the detector's measurement each loop and marks "would refuse" instead of aborting, so the exported audio can be analysed; the fixture's 2x transient-waiting case was then run 24 times under renderer-only SIGSTOP starvation (0, 80/300, 150/400, 250/500, 350/600, 450/700 ms).

| Starvation | Would refuse (≥ 2/30 s, 2 consecutive readings) | Exported audio |
|---|---|---|
| none, 80/300 | no (max measured loss 15–17 ms) | clean: weakest 40 ms RMS 0.0875, 880 Hz, duration 1.02–1.07 s |
| 150/400 | no (28–51 ms) | no zero-RMS gap; mild artifacts: weakest RMS 0.043–0.074, 855–895 Hz, duration 1.11–1.17 s |
| 250/500 | **yes** ×3 (78–139 ms) | **real gaps** (weakest RMS 0.0001–0.0002, 1–2 silent 40 ms windows), pitch 737–885 Hz |
| 350/600, 450/700 | **yes** ×6 (245–420 ms) | 4/6 with 3–6 silent windows and pitch 548–658 Hz; 2/6 without a gap in the analysed window but stretched to 1.46–1.65 s (the suite's ±0.18 s duration oracle rejects those) |

Every run the real detector would have refused produced a recording that fails at least one real oracle (gap, pitch, or duration); every run it would not have refused had no gap and held 880 Hz within 30 Hz. **No false positive observed.** The threshold is, if anything, lenient — sub-threshold starvation already leaves mild artifacts. The fixture's synthetic `waiting`/`playing` events cannot have caused it: on the 2x media path there is no `waiting` listener any more and the only `playing` listener (`realign`) lives in the 1x buffer path. So the hosted refusal required real measured loss: the starved runner genuinely dropped original audio, and the product refused to hand the user a damaged file — the same runner behaviour that failed #218/#220 under the old event-based detector, now rare instead of routine.

Impact: iOS build 57 none (Studio is separate); the deployed Studio refuses a 2x/undecodable-audio export on a starved machine instead of producing a gapped file (safe side; 1x buffer path unaffected). Not a product failure; not a reason to touch the submission.

What should change (Codex/S1, not now): (1) attach the measurements to the stall error (`cause: {maxLossSeconds, readings}`) so a hosted refusal is classifiable from the receipt; (2) make the `double-speed-transient-waiting` **control** environment-aware without weakening any oracle — on refusal, if the detector's own readings show the element clock stalled ≥ 2/30 s twice, record "environment underrun" and retry that control once on the same runner, fail if it refuses again or if it refused *without* measured loss; `double-speed-stall`/`decode-failure-stall` keep refusing, RMS/pitch/duration oracles unchanged; (3) later, consider a tighter threshold or a third reading, informed by the 150/400 row.

## 4. Live deployments bind to the tip

- **Studio** `a489f876-479d-4ceb-b64d-e2a7912c94f8` (final, connected; superseded disconnected `3a34cc49…` correctly not counted): the live chunk that carries `export.ts` (`/assets/cloud-media-QFud6YxL.js`, 115,760 B) is **byte-identical modulo chunk-name hashes** to a pristine build of `d5ed053` in the sandbox (normalized SHA-256 `7c06ba65a1c3340b…` both sides); it contains the measured-loss detector (`2/30`) and no `waiting` listener. `index-BzdA7aCM.css` is identical by hash. The remaining JS chunk hashes differ only because the connected public configuration is inlined at build time and Vite's hashing cascades through the import graph. Entry page: "Rendprop Studio · Your content, connected", Sign in shown, 0 page errors (Codex) — account login and cross-device sync remain unverified, as Codex states.
- **Website** `49b2e9a3-e917-437f-92b4-c59c5f5bb23d`: read from the real browser with `cache: no-store` — `/features` 4× "Coming soon", 0× LiDAR/scan, 0× "Payment estimate", 0× "published beside it"; `/pricing` 0 floor-plan rows; `/support` 2× "do not open yet"; `/terms` and `/privacy` no yearly/annual; all `cf-cache-status: HIT` copies already current, so Codex's "no purge needed" holds. Caution for future passes: Cowork's `web_fetch` tool returned a **stale** pre-build-57 `/features` (floor plans, LiDAR, payment estimate) — that is the tool's own cache, not the edge; W1 saw the same artifact. Use the browser for live readbacks.
- **Backend**: unchanged since my deploy (migration `20261010155636`, `select_workspace` `ab14c1f6…`, ai-photo 69 / ai-copy 36 / notify 25 / coach 35; readback 16:56Z). Not redeployed, as instructed.

## 5. Product findings

**None new.** All build-57 product paths reproduced on the tip earlier today (adoption custody 153 + 13 mutants; push isolation 70 + 10; Measurements source oracle 16 runs; Studio export-resume 12/7/4 and export-audio 9/9 with the mutant caught; deno 1,897/0/1; DB 66 + 7 races / 42) — `CLAUDE-BUILD57-REVIEW-20261010.md` §3. Codex's Mac evidence (real H.264/AAC 9/9, Release simulator XCUITests 7/8 → focused 2/2) is consistent and separately retained.

Fixture note carried: `DetailMetadataRegressionUITests` empty-listing lazy-grid failure was a test-helper scroll issue, fixed in `d5ed053` without weakening the Measurements no-navigation assertions; the two parked measurement journeys are skipped and must not be reported as passing.

Notes (unchanged, not blockers): Studio gzip headroom now 223 B (349,777 / 350,000 connected build); six ledger-consuming functions still on pre-log-line bundles; `asc.py` fails loudly if 1.0.4 stops being editable; same-user reserve/deletion lock order (transient); build-55 journal `detaching` edge.

## 6. Still open — owner evidence, none of it a product finding

**Before pressing Release (TestFlight 1.0.4 (57) = the submitted binary):**
- Listing page: Measurements card reads Coming soon, is not a button, tapping leaves the page where it is; Home unchanged.
- Guest custody: 1.0.3 (42) guest with an offline listing → upgrade → Apple sign-in shows it under the adopted workspace; a guest whose refresh token was revoked before signing in still finds its drafts; a cancelled handoff leaves them publishable.
- Push: Delete account → other Apple ID on the same phone registers; offline sign-out > 1 h → sign-in registers; generic lock-screen alert for a foreign recipient.
- Fresh-install sign-in; Team invite/join/seat removal; StoreKit purchase/cancel/restore/Ask-to-Buy; camera/downloads/Maps/tel; Safari watch mode + Turnstile; one real buyer enquiry.

**Real generation:** one ordinary (non-sponsored) photo edit, reel and aerial with settled holds; provider behaviour on a smuggled condition instruction; Kontext truncation at 3,310 chars.

**Invoice / Apple:** supplier invoices vs catalog holds; the 15% commission line from 2026-10-11; ASC state read back after review (USA-only, $49/$99/$249 monthly, one-week trial, annual SKUs off sale).

**Evidence Claude cannot read:** both `/Users/pilksclaes/LocalRendpropAudits/build57-*` roots (Codex-reported, consistent with everything reproduced here).

## 7. If Apple comes back

- **Approved before acceptance is done:** hold the MANUAL release; finish §6; then release.
- **Rejected:** fix on a new build from this branch; CI must be green on the archive commit (a tour-host rerun that fails only on the §3 control is environmental — record it, do not call it fixed, apply the control change in §3 first).
- **Metadata-only questions:** `asc.py` targets 1.0.4 only; every mutation `--dry-run` first, read the printed version line.
