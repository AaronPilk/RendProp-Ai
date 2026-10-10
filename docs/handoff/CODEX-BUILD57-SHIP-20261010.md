# Build 57 shipped to TestFlight — 2026-10-10

**TestFlight 1.0.4 (57) is available for internal testing. App Store submission remains NO-GO.** Claude's supplied review was read in full and preserved as `CLAUDE-BUILD57-REVIEW-20261010.md`. Its archive GO was acted on; no review submission was sent.

Machine receipt: `docs/releases/TESTFLIGHT-57-20261010.json`. Private evidence: `/Users/pilksclaes/LocalRendpropAudits/build57-ship-20261010/`. This documentation is a descendant of the frozen archive source, not a different product build.

## Signed artifact and Apple

- Clean source: `d5ed053e472594e94c408f9798d1fe30c705d4dd`, branch `fix/build57-portable-integration-20261010`.
- One signed archive, one export and one upload. No XcodeGen regeneration or product-source changes. Xcode 26.4.1; Release for generic iOS device. Commands and results retained as `archive-command.json`, `export-command.json`, `upload-command.json` and their logs; credential values are withheld.
- All 135 tracked Swift compiler inputs, including eight external capture files, match the frozen commit; one generated asset-symbol source retained separately. Archive, exported binary and dSYM share UUID `D9DCDA5B-7D3C-348C-A069-35F352A7FD77`. SHA256s are in the machine receipt.
- Exported IPA has App Store distribution profile, `get-task-allow=false`, production APNs and valid signatures. No spatial capture Lab compile flag. Privacy manifests match source. Both archive and export are 1.0.4 (57).
- Deliberate export setting: `manageAppVersionAndBuildNumber=false`, preserving the reserved number rather than permitting automatic renumbering. Actual Apple readback establishes 57, rather than relying on this setting.
- Apple build ID: `46e2df20-e688-4e14-afa7-88655f28e8ba`; `VALID`, `APP_STORE_ELIGIBLE`, internal `IN_BETA_TESTING`. External state is `READY_FOR_BETA_SUBMISSION`; external beta review was not sent.
- The first compiled-input verification rejected shell-escaped spaces; corrected parser uses shell decoding. No artifact changed. Initial failure retained.

## Website and connected Studio

Website worker `49b2e9a3-e917-437f-92b4-c59c5f5bb23d` is deployed. Predeploy checks passed. Plain and query responses checked for `/features`, `/pricing`, `/support`, `/terms`, `/privacy`. Current Coming-soon and support restrictions are present. Static pages match source after removing only the identified Cloudflare JS-detection script; raw responses and headers are retained. Cache HIT responses already match current content; no cache purge was needed. This is not a claim of raw response-byte identity.

Studio worker **`a489f876-479d-4ceb-b64d-e2a7912c94f8`** is the final deployment. Tests were 479/479; typecheck/build passed. Final `check-dist.mjs --require-connected` passed: gzip 349,777 B, beneath the unchanged 350,000 B cap. All 31 deployed files, security headers, callback routing and missing-route policy match this final build. A real headless Chrome visit shows Sign in and no page errors. Actual account login and cross-device customer sync remain unverified by that entry-page check.

An earlier deployment in this turn, `3a34cc49-b2ba-48fd-b9cf-6309105477c2`, omitted the public browser connection configuration. Normal `npm run verify` permits disconnected local mode and did not catch it. The explicit connected-release check caught it. Restored the existing public production configuration from an earlier configured checkout, validated that the key is browser-safe and belongs to the expected project, rebuilt and superseded the disconnected version. No server secrets were changed or printed. Preserve both deployment logs; only the final connected version is release evidence. Future Studio release commands must require connected configuration before deploying.

Backend was already live and was not redeployed. John Apple, funding, credentials, repo visibility, Home styling and the listing toolbox were left unchanged.

## Apple draft and professional images

Exact 1.0.4 version `39ff74df-71d4-4bf1-92f4-9c709e7f4366` now references build 57. Draft review `ecf0a17a-6fdd-40c9-8e0b-39f345b1b830` has exactly the app version and three monthly subscription versions; `submitted=false`, manual release. No annual SKU or price changes made this turn.

Seven professional images are COMPLETE with verified order and checksums. Frames 1 and 5 were replaced using native Release build-57 simulator pixels. Frame 1 shows the current Home design with Coming-soon disclosure. Frame 5 replaces an older misleading active-measurements advertisement with actual available creation tools. Other five images are unchanged. Assets are 1320×2868 RGB PNGs; originals and new manifest are retained in the private campaign folder.

Only en-US description, keywords, promotional text, release notes and review notes were updated and verified against repository text. Broad metadata apply was not used: its plan included unrelated age-rating fields. No age-rating, pricing or availability mutations. Initial checksum visibility and screenshot ordering readbacks lagged; those failed checks were preserved and fresh GETs verified final state. No duplicate uploads or repeated mutations. `apple-draft-actions/completed.json` is the final successful readback.

## Fresh CI regression — still open

Checkpoint run **38067429608** at `2a9d98f` independently confirmed **12/12 success**. New archive-tip run **38071986005** at `d5ed053` has a failed tour-host job. At the recorded snapshot ten jobs succeeded and the native harness job was still running; see the machine receipt for the latest recorded snapshot.

The failing step is **Studio MP4 export, AAC narration and continuous agent audio**. `double-speed-transient-waiting` unexpectedly refuses export with “Original audio playback stalled during export.” The hosted receipt has `ok=false`, `decodeCalls=0`, `injected=true`; no page errors or external requests. Earlier intentional failure output from the listing negative control is not the failing step.

The unchanged real H.264/AAC browser suite subsequently passed **9/9 on this Mac**. This does **not** close the hosted regression. Retained hosted logs, downloaded media artifact and local rerun are under the evidence root. Do not rerun until green and call it fixed. Diagnose whether elapsed-audio vs media-currentTime sampling reports false loss under CPU pressure or correctly catches a real underrun; preserve measured-loss detection, real-stall refusal, continuous-audio RMS and pitch oracles. No product change was made to suppress the failure.

## Remaining submission gates

1. Resolve or rigorously classify the hosted audio-export failure with a reproducer and unchanged loss oracles.
2. Real device: fresh install/sign-in; guest draft adoption including revoked-token/cancelled handoff; account deletion/switch and push registration; Team privacy/invite/removal; StoreKit purchase/cancel/restore/Ask-to-Buy; camera, downloads, Maps/tel, public watch mode and one buyer enquiry. Simulator compilation does not establish these.
3. Ordinary non-sponsored photo/reel/aerial generations, successful hold-to-ledger binding, quality and CONDITION_LOCK resistance. No new paid model jobs were run this turn.
4. Supplier invoices vs held catalog costs and effective Apple commission. The scheduled 15% assumption starts October 11; no payout evidence was fabricated. Funding and allowances were not changed.

## Prompt for Claude

Read `docs/handoff/CODEX-BUILD57-SHIP-20261010.md`, `CLAUDE-BUILD57-REVIEW-20261010.md` and `docs/releases/TESTFLIGHT-57-20261010.json` from origin. Build 57 is uploaded, VALID and internally testable, bound to clean `d5ed053`; exact Apple build and worker IDs are recorded. Do a final read-only review of the retained artifact/deployment/draft evidence. The new CI run 38071986005 failed on `double-speed-transient-waiting` despite a later unchanged local H.264/AAC 9/9 pass: investigate this, do not count the local pass as closure or weaken stall/RMS/pitch checks. Confirm the final connected Studio deployment, not its superseded disconnected version. Separate product findings from pending phone/model/invoice evidence and return actionable GO/NO-GO. No redeploy, submission, credential/funding/visibility change or John Apple action. The private evidence paths are Codex-reported unless you can access them directly.
