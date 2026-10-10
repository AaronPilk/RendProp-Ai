# Codex build57 cross-check — 2026-10-10

Historical audit snapshot. Subsequent archive, TestFlight availability, website/connected Studio deployments and Apple draft evidence are in [CODEX-BUILD57-SHIP-20261010.md](CODEX-BUILD57-SHIP-20261010.md). This audit itself predates those actions; its pending statuses below are historical.

## Source recovery

Read the supplied build56 release-evidence cross-check and `CLAUDE-BUILD57-FIXES-20261010.md` in full. The copied `~/Rendprop AI/build57/.git` points to an unavailable `/sessions/...` sandbox repository. Neither the sandbox code commit `b8b1f7e` nor its branch exists in this Mac's Git object store or on origin at readback. The copied files remain intact.

Imported the complete copied source onto known base `b6a3d80`, without rewriting shared or Claude branches:

- Branch: `fix/build57-portable-integration-20261010`.
- Import commit: `796bf86d05661c3cdbe77f072bb6b86688ba0861`.
- Imported full tree: `6d57e3aaaf2144f79f0aab798e24193f4c479699`.
- `apps/ios` tree: `63a919cc04e950371455b3be542d51abffc4c9f5`.
- External compiled capture source tree: `c71f06b295d74134a15236af4d653c8e9eac5bfe`.
- ASC tooling tree at import: `c3daca181f2ee2400524e6a10747ca2a734852ab`.

All three subtrees match Claude's build57 handoff. The import is a new commit; it does not claim the unavailable sandbox commit's ancestry. All 52 file checksums in `BUILD57-BACKEND-DEPLOY-20261010.json` match copied source. This verifies the receipt's local source binding; it is not a fresh production readback.

## Independently executed on the Mac

Evidence root: `/Users/pilksclaes/LocalRendpropAudits/build57-crosscheck-20261010/`.

- `node --test tests/phase1/adoption-local-bindings.test.mjs`: 153 assertions; 13 compiled fault controls rejected; exit 0.
- `python3 apps/ios/tests/run-push-account-isolation.py --out <evidence>/push`: 70 assertions; 10 controls; exit 0.
- `python3 apps/ios/tests/run-native-ux-audit.py --evidence-dir <evidence>/native-ux-final`: 16 runs passed after the UI-test scrolling correction.
- `STUDIO_BROWSER_EXECUTABLE='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' node tests/export-audio-browser.mjs`: passed with actual H.264/AAC, including transient waiting without loss, real stall refusal, cut continuity and silent-video handling. No Opus substitution.
- Same command with `--fault=live-original-audio`: exit 1; continuous-speech assertion detects a zero-RMS gap. Retained `export-audio-negative.log`.
- Same browser command for `tests/export-resume-browser.mjs`: exit 0; 12 export variants plus preparation refusals passed, including the unchanged completion and audio assertions that failed CI #220. Retained `export-resume.log` and `export-resume-receipt.json`.

### Actual Release simulator build and UI checks

Compiled the actual app with `xcodebuild test`, scheme `Rendprop`, configuration `Release`, iPhone 17 simulator (iOS 26.4), signing disabled for simulator only. Exact invocation/logs and result bundles are retained under the evidence root (`measurements-ui.log`, `measurements-ui.xcresult`, `measurements-ui-focused.log`, `measurements-ui-focused.xcresult`). Selected the new `BetaPolishUITests/testMeasurementsIsComingSoonOnTheListingPage` plus the seven `DetailMetadataRegressionUITests` cases.

Initial run: **7/8 passed**, including the new Measurements non-navigation test; the empty-listing case failed at the test's `back(from:)` Photos-card existence assertion. The retained hierarchy shows `Detail fixture empty` still open, Measurements a plain Coming-soon card and the first lazy-grid row scrolled above the viewport. No product navigation failure was established.

Corrected only the test helper: use its existing outer-page scrolling to materialize Photos before the existing existence assertions after returning/tapping. Product navigation, the non-button checks and every Coming-soon/no-navigation assertion remain unchanged. Focused Release rerun of the failing empty-listing case plus the rich photo/tour/aerial/client navigation case: **2/2 passed**. This is a documented initial failure and targeted closure, not a claim that a single fresh 8/8 run occurred. The seven initial passes, two focused passes and compiled source are retained separately. No camera or microphone was used.

The browser tests ran on a private byte-for-byte Studio source snapshot, with the identical package lock and the existing Mac dependencies. Synthetic fixtures only; no customer media, live providers or camera use. Foundation harnesses exercise actual extracted production methods, not SwiftUI rendering or StoreKit.

Metadata remeasured: description 3863 characters / 3915 bytes; review notes 3939 characters; keywords 96 bytes. Within the current repository's Apple limits.

## CI correction and scan classification

Independent GitHub readback:

- #219 / `38021265572` at `317309ad`: completed success, 12 jobs.
- #220 / `38023826741` at `740438fc`: completed failure, 11 jobs passed; video/audio export step failed. Earlier release records' pending statuses are historical snapshots, not current status.
- First imported-source dispatch: `38066790433` at `796bf86d`; secret scan failed on two new receipt checksums, then workflow concurrency cancelled it when its replacement was dispatched. Replacement `38067111642` at `04ecb28` was in progress when the ASC repair started; its secret scan passed.

Both scan findings were independently recomputed as file SHA256 checksums (`_shared/api-key-config.ts` and `_shared/library-access.ts`, receipt lines 22 and 32). Added only the two exact commit:file:rule:line fingerprints to `.gitleaksignore`. No whole-file or rule exclusion. Local import-range scan then passed. Run the final all-ref scan and dispatch CI on the final documentation/scan descendant before claiming a green release tip.

## Remaining release work and runbook corrections

1. All 12 hosted jobs must complete successfully on the final branch. A local browser pass does not replace the hosted regression check.
2. `.github/workflows/ci.yml` contains no `xcodebuild` or Xcode UI-test invocation. The handoff's claim that simulator XCUITests run in CI is unsupported. The actual Release simulator build and focused UI checks are now executed locally as documented above. The two intentionally parked measurement journeys were not selected and must not be represented as passing tests.
3. Repaired `asc.py` to target **1.0.4** and select only that exact editable version. Added five regressions (multiple unrelated drafts, no fallback, actual build-attachment refusal before any write, a published target with an unrelated draft, current-version creation without writes). Updated existing fixture targets and archive guidance; all 213 ASC tests pass. Native and external capture trees are unchanged, but the ASC tooling tree changes from the import hash above. Before Apple mutations, read back the exact version resource ID, build marketing version and actual processed build number. The broad apply bridge is unsuitable here.
4. `--no-upload` on the archive script performs a signed archive; it is not a cheap dry run. Avoid archiving twice. Record the exact archive/export commands and source commit, the 135 Swift inputs including the eight external files, exported signing/profile/APNs settings, IPA/binary/dSYM binding and actual Apple build ID/number.
5. Website and Studio deployment/readback, screenshot frame 1 refresh and the full independent review remain pending in this record. Backend changes are reported deployed by Claude; avoid redundant redeployment.
6. Keep real-phone capture, purchase/cancel/restore, account switching and push delivery; real non-owner photo/reel/aerial with settled holds; and invoice/Apple commission evidence separate. Automated fixture passes do not establish these.
7. Preserve the current Home design and listing toolbox; leave John Apple, credentials, funding, repo visibility and App Store submission unchanged pending the authorized release gates.

The old App Store draft remains a historical build56 candidate unless an explicit later Apple readback establishes otherwise. Build57 has not been uploaded by this cross-check.

## Final code CI and source scope

Frozen runtime/tooling checkpoint: `2a9d98f092780d5476a8cbfca63aeeccc31363da`. All twelve jobs dispatched as [run 38067429608](https://github.com/AaronPilk/RendProp-Ai/actions/runs/38067429608); still pending at this record's last readback. `38067111642` was superseded/cancelled by workflow concurrency when the ASC fix required a new dispatch. Earlier partial passes are not a substitute for the frozen checkpoint's completed result.

This record and the lazy-grid test correction are a subsequent **docs/UI-test-only** change. They do not change the app product, project/build settings, external capture sources, Studio, backend, website or ASC tooling. Archive provenance must name a clean commit and bind these scopes explicitly; source equality must be checked instead of assuming that every descendant is equivalent. No build57 archive, export, TestFlight processing or Apple submission has been performed by this audit.

### Claude review prompt

Review `fix/build57-portable-integration-20261010` after fetching origin. Read this record plus `CLAUDE-BUILD57-FIXES-20261010.md`, `BUILD57-PREP-20261010.md` and `BUILD57-BACKEND-DEPLOY-20261010.json`. The original sandbox Git history was not available on the Mac; imported source `796bf86d` has the documented native/external/ASC trees and all 52 backend receipt hashes. Public ASC selector is fixed at `2a9d98f`, with 213 tests. Check the exact final code CI run 38067429608 and its head; do not infer a completed pass from this document. The first simulator run had one offscreen lazy-grid fixture failure; the preserved failure and focused 2/2 closure are separate evidence. Reproduce the product paths, especially guest custody, push isolation, live original audio and non-clickable Measurements; keep Home/toolbox styling intact. Return actionable GO/NO-GO and separate missing phone/model/invoice evidence from product failures. Do not redeploy backend, change credentials/funding/visibility, touch John Apple or submit to Apple. Build57 still needs its archive/Apple artifact binding and website/Studio deployment/readback.
