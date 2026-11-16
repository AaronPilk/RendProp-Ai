# Codex → Claude: final release audit — 2026-10-09

Audit the candidate below before we submit Rendprop to App Store review. The owner wants the code pushed and the new build on TestFlight first, so they can keep testing. **App Store submission remains on hold until this audit returns GO.** Spatial capture remains experimental; it is not the gate for the ordinary listing app.

This is a read-only audit request. Use parallel agents for independent areas, inspect the actual code and executable behavior, and return concrete reproducers. Handoff statements and previous passing tests are evidence to verify, not substitutes for the audit. Do not implement fixes during this pass.

## Candidate and delivery status

Delivery completed on the isolated branch. The code checkpoint and archive identity below are deliberately separate. The release receipt is `docs/releases/TESTFLIGHT-54-TEAM-PRIVACY-20261009.json`; later documentation-only commits do not change the candidate code.

| Item | Identity / status |
| --- | --- |
| Branch | `audit/launch-alignment-20261008` |
| Final code checkpoint to audit | `dca97aad9e6ab555e4dffb50259336debe46fa41` |
| Final CI | [Final CI](https://github.com/AaronPilk/RendProp-Ai/actions/runs/37995386399), exact `dca97aa`. Running at receipt time; read its actual final result before GO. No final pass is claimed while running. |
| Signed iPhone build | `1.0.4 (54)`, archived from `ed88c1687ddcf560c0d8409cfea84f87f30ca067` |
| Native content identity | `f12bb82143167e1bbfd488b7558647ddd3fb04a6`, equal for the archive source and final code checkpoint; distribution signing, entitlement, binary and IPA verification retained |
| TestFlight delivery | Apple build `ebe4d32d-7568-49d3-8906-ce58a6e52d19`: `VALID`, `IN_BETA_TESTING` internally, `APP_STORE_ELIGIBLE`, encryption false. One successful upload. External state `READY_FOR_BETA_SUBMISSION`; no external beta review is claimed. |
| Production database | `20261009214512 team_private_listing_libraries` applied from local `20261009192550_team_private_listing_libraries.sql`; SHA256 `3a0a02b67632bb4c84fe2f72c5bd4e5efd7153a6472d86083cd26e33f3eae94f` |
| Production functions | 17 source/JWT-verified functions: me62, listings49, studio29, team27, leads46, ai-photo66, ai-copy33, ai-video63, ai-voice46, ai-chapters37, uploads54, coach34, property23, events36, spatial20, tours56, renders50. No JWT-policy change. |
| Studio and published property site | Studio `c2875843-acdd-4960-858c-af9f3c817f1d`: 35 GETs, 31 served files verified. Tour host `0f6183e6-1e41-4170-bad2-3b114d8b53fb`: terms/privacy/support source content verified; the exact observed Cloudflare JSD script is the only transformation. No zone security setting changed. |
| Optional Python worker | Updated source; no worker/container deployment established by this audit. See runtime caveat below. |
| App Store | **NOT submitted.** Draft 1.0.4 still attaches build 53; seven revised campaign images are COMPLETE. Attaching 54, applying final metadata and submitting are separate post-audit steps. Future release stays manual. John Apple remains untouched. |

Compare the final checkpoint against the signed native source before reviewing the build. Backend/test/document changes after the archive can be legitimate; a native runtime change cannot be represented as already included in build 54.

## Boundaries

Work in your own isolated checkout of the **final** SHA, not stale `main` or an old Claude branch. Do not reset another agent’s worktree, force-push, edit the candidate, change feature flags, grant funding, rotate/read credentials, mutate hosted databases, submit paid provider jobs, or touch App Store Connect. Do not contact anyone. Preserve existing failing receipts and original assertions; identify stale fixtures explicitly rather than weakening safety or inventing a pass.

A safe checkout pattern, substituting the final SHA supplied above:

```sh
git fetch origin
git worktree add --detach ../claude-final-audit-20261009 <FINAL_SHA>
git -C ../claude-final-audit-20261009 status --short
git -C ../claude-final-audit-20261009 rev-parse HEAD
```

Keep reproducers and your report outside the candidate checkout. The prior Home/custom-photo handoff contains superseded submission instructions; this final handoff and Aaron's requirement to wait for your audit take precedence. Use local disposable Postgres clusters and offline/synthetic client fixtures. Read sanitized source-bound release receipts when needed; never print keys, tokens, customer media or contact information. No new paid image/video generation is authorized for this audit.

## Audit priorities

Reconcile the complete existing beta-feedback docket and any new reports with actual fixes, tests, live deployment and Build54 inclusion. Do not mark a camera-dependent report passed from a simulator or merely from a closed ticket. Fresh installation must require account creation/sign-in; inspect sign-out, stale account/cache isolation, deep links, deletion and interrupted purchase/restore recovery. Admin operational notifications must be clearly labeled, understandable, authorized, deduplicated and private to their intended recipient.

1. **Home only: design and navigation.** The approved Home has a photograph-led hero, white light canvas/adaptive dark canvas, two-column image cards (one at accessibility text sizes), clear Apple Liquid Glass/material treatment, a faint purple edge/glow, and the exact approved real-estate hero copy. Titles and subtitles sit together beside the icon, above the image. No bright gradient card fills, outer toolbox shell, My Listings duplicate, five-step guide card, extra Add a home button or extra toolbar bubble. Other screens, original listing-detail toolbox colors, shared design system and tab bar must retain their original design. Promotional art must never become a listing photo or client contact. New installs follow iPhone System appearance; existing explicit Light/Dark preferences remain honored. Preview launch arguments can override Settings—do not mistake `-appearance light` for a production bug. Review `apps/ios/Rendprop/RendpropApp.swift`, existing appearance persistence and asset usage.

2. **Team privacy, custody and authority.** Only the actual Team account owner can enumerate/switch/read/edit explicitly linked agents’ libraries. Invited agents keep their own account/listings and see no agent switcher, sibling listings or empty duplicate shared library. Sally must never see Tom. A private-library owner role, Team entitlement, billing parent, administrator role or sponsorship alone must not grant cross-agent authority. Directory capabilities are server-authoritative and actor-bound; stale/revoked delegation must disappear while preserving the agent’s own local capture data. Review the Team migration, `_shared/library-access.ts`, `_shared/workspaces.ts`, Team/listing/media handlers, native Workspace store/transport and Studio guards. Test a removed seat and a Team owner viewing a child library.

   Legacy listings keep their real `org_id`, listing ID, media keys and public URL; logical `library_org_id` groups authorized rows without retargeting mutations. Seat removal cannot move/delete content. Check exact listing/job/media/provenance mutations and RLS, not just the picker. Directory top `billing_org_id` is the stable account purchase root; each row’s billing scope funds its content. A beneficiary cannot initiate the parent’s purchase or reuse someone else’s transaction. Owner purchase recovery must stay bound to the original transaction while viewing an agent’s library.

3. **Money and race safety.** The owner’s minimum is **75% of receipts after Apple’s commission**, excluding unknown advertising acquisition cost. Serving costs still include AI attempts/fallbacks, processing, storage/hosting and supported service costs. Small Business enrollment is approved, but the model must use 30% before the effective switch and 15% from **2026-10-11 07:00 UTC**, with no early improvement assumed. Audit actual product prices, included features/usage, server admission, plan display and ledger—not old September margin claims or catalog agreement alone. Monthly products are the sale path; annual products are off sale while historical annual receipts remain recoverable.

   Trials are seven days or until the funded usage allowance is consumed; exhausting AI usage must not silently advance Apple’s billing date. Distinguish a customer’s exhausted allowance from temporary shared trial capacity. Verify the reviewed launch funding ceiling ($290), exact live trial/account/global caps, no unfunded AI dispatch, no blanket upgrade for pool outages, and truthful usage UI. Check `funded-serving.ts`, ledger/settlement code, activation/trial/retention migrations and all writers. Include parent/child Team mixed-writer races, hold/dispatch/settle ordering, failure/refund/retry/duplicate handling, provider-unknown liabilities and month rollover. A catalog estimate is not an invoice; unresolved liability must not be released merely because time passed, a workspace was deleted or a new billing month began.

   Money corrections are included in the candidate, principally `ed88c16` and `5342c2f`; `6dd3a42` fixes Python false duplicate acknowledgment on redirect failures. Retained source-bound SQL proof includes actual mixed-writer last-dollar admission, a removed-lock overspend control, deletion and unresolved-liability rollover. Inspect the executable CI SQL/race drivers and source hashes; older receipts do not certify changed inputs. New subscriptions use the approved 90-day hosting grace with notices/export path; existing preserved testers must not be silently deleted.

4. **Custom photo edits, history and downloads.** Ask anything now performs free deterministic intent preparation before paid dispatch. Vague requests ask plain clarification; lighting, movable clutter, sky, furniture, lawn and photographer reflections have bounded scopes. Repaint/remodel/permanent changes and hidden defects must be refused for marketing real property. Original paint, garage/trim colors, materials, finishes, layout and condition are locked across provider fallbacks. Full input up to 600 characters is retained; optional prompt improvement cannot widen intent. Check `_shared/custom-photo-prompt.ts`, `ai-photo`, `ai-copy`, native custom sheet and Studio.

   Prompt locks are not a guarantee of faithful pixels. Every **new** custom output and descendant needs exact-version comparison/review before listing selection, cover or download. Audit `PhotoVersionHistory.swift`, `PhotoExport.swift`, compare UI and Files direct Save/Share paths—not button visibility alone. Approval for download must persist without silently selecting/publishing the image. Original, decluttered and staged versions remain individually accessible; original export stays allowed. New cloud imports must not bypass review; legacy compatibility must not silently approve new outputs. Verify truthful virtual alteration/staging disclosures and export ratios without claiming one label satisfies every MLS’s local policy.

5. **Presenter consent and media privacy.** Fresh listing authority and live presenter consent are both required. The new Team migration must retain all three restrictive `presenter_approved_read` policies on capture assets, renders and media provenance. Actual consent revocation must produce zero authenticated reads even when the listing is otherwise authorized; removing those policies must fail the same oracle. Include deletion, signed delivery, provenance and removed-owner paths. Do not replace restrictive consent with a permissive listing grant.

6. **Published property site, Studio and media quality.** First visible image must be the selected main photo. Fly-through opens on demand and retains both scroll-driven exploration and normal watching where supported; Details/Contact/Top navigation must avoid trapping visitors in the heavy video. Confirm actual HD delivery/selection, responsive controls, client contact/lead routing, retained disclosures and publish authorization. Review `services/edge/tour-host`, native main-photo selection, and Studio cloud editor/reels/photo exports. Studio MP4/AAC narration and fade checks now decode the full audio before slicing the same fixed windows; the strict 7,200-sample requirement and audible thresholds must remain, with a deliberately short input refused. Do not weaken audio assertions to hide codec-seek short reads.

7. **Provider correctness and runtime reality.** Verify model endpoint/auth/routing, capability, input/output, real output quality evidence, actual cost evidence and fallback liability separately. Do not downgrade the model just to fit an attractive margin if output is unusable. Existing owner-only real photo/reel/aerial receipts may be inspected without generating more work. One authenticated five-second kitchen Seedance reel completed and persisted; that is limited functional evidence, not invoice-confirmed pricing, retail admission, universal fidelity or a physical capture pass. Real ordinary-photo evidence: `ship-20261009/backend/photo-qa-run/root-visual-review.json` and `exact-qa-photo-readback.json` beneath the protected evidence root. Real owner-reel evidence: `ship-20261009/backend/owner-reel-credential-repair-run/reel-output-download-receipt.json`, sampled frames and `owner-reel-financial-readonly-after-status-20261009.json`. Photo 6.7 cents and reel 24.3 cents are matched catalog estimates, not supplier invoices. No completed ordinary reel/aerial quality acceptance is claimed. Bria/spatial/3D stay in their approved experimental scopes.

   Python duplicate-ledger classification fixes are in `services/pipeline/cost_ledger.py` and `services/worker/db.py`. The optional polling worker imports them through `worker.py`/`enhance_bridge.py`; Git or TestFlight does not update a running container. Repo docs do not establish a live fleet or deployed application image digest. Native app publishing, Deno AI handlers, browser Studio exporter and spatial Modal code do not import these helpers. If a Python worker is active, require its runtime inventory and a separately verified rebuild/redeploy before claiming those changes live. Do not invent a deployment from the pinned Docker **base** image.

## Existing evidence and useful bounded commands

Read the Home, Team-private-library and custom-photo launch handoffs in full, then verify their assertions against the final code:

- `docs/handoff/CODEX-HOME-DESIGN-20261009.md`
- `docs/handoff/CODEX-TEAM-PRIVATE-LIBRARIES-20261009.md`
- `docs/handoff/CODEX-CUSTOM-PHOTO-AND-LAUNCH-20261009.md`

Local Team controls previously covered 92 assertions, workspace 28 and readiness 34, fresh/replay, permission mutants and races. Final group-two database drivers covered all 24 assigned flows, including actual Presenter 122 and a policy-removal negative control, against Team migration hash `83abb684638158b5d457a6999b6314074ed53fc436ac181cf090f29e32733b96`. The final migration adds four reviewed predecessor hash pins only: all 57 live guards were inventoried, four production predecessors omitted comments, and executable contents matched. Compatibility against those exact read-back bodies passes154 assertions fresh/replay; four executable-body mutations still refuse. The original Team/privacy-mutant/last-dollar runner also passed. Existing all24 receipts at83abb remain historical evidence with an explicit four-pin-only compatibility proof, not a claim they ran on production. Earlier passing counts are not final CI claims.

Protected local evidence lives under `/Users/pilksclaes/LocalRendpropAudits/`. Useful locations include `design-refresh-20261009/appearance-and-individual/`, `design-refresh-20261009/team-private-libraries/group2-5342c2f/final-consent-83abb684/all24-final-receipt.json`, and `design-refresh-20261009/team-private-libraries/python-ledger-runtime/read-only-runtime-receipt.json`. Final source, native tree, IPA/binary, CI, function versions, deployment IDs and private evidence hashes are in `docs/releases/TESTFLIGHT-54-TEAM-PRIVACY-20261009.json`. Additional evidence: `team-private-libraries/production-guard-review-6dd3/final-review-receipt.json`, `team-private-libraries/production-acceptance-dca97aa/read-only-production-acceptance.json`, `team-privacy/worker-redirect-diagnostic/final-review-receipt.json`, `team-privacy/studio-audio-final-receipt.json`. All are under `design-refresh-20261009/` in the protected evidence root. Older `release-source.json` preparation stubs are not final release proof.

Use the exact commands/parameters in the final CI workflow and applicable runner README; no clean-source bypass. Examples of focused existing entry points:

```sh
node --test tests/phase1/*.test.mjs
python3 apps/ios/tests/run-custom-photo-prompt.py
python3 apps/ios/tests/run-photo-export-renderer.py
python3 apps/ios/tests/run-serving-photo-package.py
python3 apps/ios/tests/run-native-trial.py
python3 apps/ios/tests/run-native-trial-hold.py
python3 apps/ios/tests/run-purchase-fulfilment.py
python3 tools/audit/run_team_private_libraries.py
python3 tools/audit/run_workspace_selection.py
python3 tools/audit/run_database_regression.py
npm --prefix apps/studio run verify
```

These are offline/fixture checks. Do not call them physical camera, real payment or paid-provider acceptance. Prefer targeted actual behavior plus meaningful negative controls; avoid hours of repeating unchanged checks without a new failure or source change.

## Return format and release decision

Return **GO / NO-GO for App Store submission**, bound to the exact final SHA, build 54 native content and recorded live deployments. State unresolved facts explicitly. For every blocker provide file/line, trigger, smallest working reproducer, expected versus actual behavior, affected users/money/privacy, and the narrow fix recommendation. Separate stale test fixtures from product defects. List checks you actually ran and retained evidence; do not certify all code because agents read selected paths.

Keep a separate **Needs real phone / real transaction / supplier invoice** list: camera/lens/stabilization, background/interruption behavior, eligible Apple trial/purchase/cancel/restore, device notification/delivery, and experimental room/spatial quality. The owner explicitly deferred ordinary physical acceptance to testing after delivery; these are pending, never passed by simulator. Known reproduced product, authorization, data-loss or unfunded-cost bugs are NO-GO; lack of camera access is not a reason to fabricate a pass or rebuild capture plumbing.

Do not submit to Apple, enable experiments, change pricing/allowances, issue credits or repair production as part of the audit. Send findings back first. The owner and Codex will approve/fix actual blockers, then verify the final manual-release submission separately.

## Prompt Aaron can paste

```text
Run Rendprop's final read-only audit before App Store submission. Fetch origin/audit/launch-alignment-20261008 and read docs/handoff/CODEX-TO-CLAUDE-FINAL-AUDIT-20261009.md in full. Audit code checkpoint dca97aad9e6ab555e4dffb50259336debe46fa41; later handoff/receipt commits are documentation only.

Use parallel agents for native/auth/purchases, Team privacy, backend/money, AI/media quality, Studio/public pages, and beta-feedback/release reconciliation. Verify actual code, behavior, final CI and deployed receipts. TestFlight1.0.4(54) is VALID and available internally; App Store remains unsubmitted.

Return a clear GO or NO-GO for submission. Every blocker needs file/line, a working reproducer, impact and a minimal fix. Separate real product defects, stale fixtures and checks that need a physical phone or supplier invoice. Do not invent camera/IAP acceptance.

Do not edit the candidate, alter production/funding/credentials, spend on generation, touch John Apple, force-push or submit to Apple. Return findings first.
```
