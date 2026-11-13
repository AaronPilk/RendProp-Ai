# Claude audit rerun — reconciliation, 3 October 2026

**The rerun confirms the deployed fixes, but its profitability and residual anonymous-photo claims need correction. Its old photo implementation must not be reapplied.** This is an audit reconciliation, not a release or a claim that the remaining financial issues are fixed.

The owner's entire attachment was read as report material, not execution instructions. Its SHA-256 is `4e1a53b0ce2756d0f6b33ccb7cb3a8eb8f23c1a6492af64789d7c4700e1dbfab`. Reviewed source is `e45e017e29e29a7ac3322e2c5d7207566171c93b`; runtime functions/native source are unchanged from `a16465514f12d06bb61be405d12ce8dd7effd695`. This follow-up adds documentation only. No prices, allowances, production configuration, Apple submission, feature flag or provider balance were changed. Claude's other checkout was not edited.

## Confirmed with fresh evidence

At **2026-10-03 17:15 UTC**, Supabase lists 25 ACTIVE functions. All 15 versions named in the rerun match. The trial-start migration is recorded as `20261001152146`; video reservations as `20261003024724`, once. This checkout's trial migration filename is `20261001143615_subscription_confirmed_trial_start.sql`; the filename/live-ledger timestamp difference is not a second application.

The live trigger creates a Free workspace with null trial expiry/source. The live `app_video_cost_reserve` and `app_video_cost_settle` functions deny execution to both client roles, permit service role and have empty search paths. `app_video_held_cents` permits authenticated reads and checks membership before returning a sum. The ordinary-video cost hold closes the demonstrated estimated-cost concurrency gap; it is not universal paid-provider admission.

Fresh API-returned `ai-photo` v52 and `ai-copy` v19 entrypoints and their shared Auth module match this checkout byte-for-byte. This independently binds the anonymous-photo/copy findings to current deployed source. The other versions match the catalog; this follow-up did not repeat the earlier 196-file deployment verification.

Existing named toolbox/launch boundaries are present in current native source. The previous source fix and release evidence remain valid within their scope. A current local SDK uses a flat variadic `ViewBuilder.buildBlock`; this supports rejecting the pairwise-sibling explanation for that toolchain. `AppStoreTools` alone does not establish all archived SDK metadata or prove physical-phone crash resolution.

## Corrections to the rerun

| Claim/recommendation | Correct disposition |
|---|---|
| Seven pricing invariants prove 86% margin at full use | Configuration coherence is distinct from profitability. The exact seven predicates and financial inputs were not provided. A historical reference-cost model reproduces the rounded 86% before Apple fees and other serving costs; it is not a conservative current cost bound. |
| Anonymous reinstall can farm five photo edits for $0.20 | Current app-AI identity guards reject an anonymous Free caller before paid meters/dispatch. Identified Free users retain five edits, but $0.20 is a chosen-route estimate, not a worst-case bound. |
| Non-null `plan_source` proves every historical trial used Apple confirmation | Current code confirms eligible Apple subscriptions; the source vocabulary also permits legacy/manual grants. Non-null alone does not establish an individual cohort's origin. No customer subscription/cohort rows were queried here. |
| Reapply `0071443` photo supersession | Its useful behavior already exists in build 43, with stronger persistent history. Reapplying its session-only base tracking/deletion would regress the owner's required separate originals, decluttered and staged downloads. |
| Only Topaz invoice reconciliation remains | There is also a reproduced pre-admission actual-output pricing mismatch and incomplete financial coverage across other paid paths. Invoice reconciliation alone does not repair them. |

### Pricing

The historical units render $0.0075, photo $0.039, reel $0.24, aerial $0.80 and Topaz $3.60 produce reference costs **$6.97 / $13.955 / $35.3875** for current monthly counts. Those costs divided by $49/$99/$249 reproduce all three rounded 86% figures and the prior $8.5225 trial figure. This is an explicitly labeled reconstruction, not proof of Claude's unsupplied query inputs. Topaz is included at a fixed 90-second 1080p60 configuration; its actual supported cost range is absent.

At Apple 30%, the same reference model yields approximately 79.7–79.9% margin on monthly net receipts before excluded costs. Annual Starter/Pro fall to 75.62%/75.84%, leaving just $0.18/$0.48 per month for every excluded serving cost. Actual maximum media configurations, independent voice/chapters/helpers, paid attempts and recurring hosting invalidate this as a worst-case proof.

Today's offline production-source and live-shaped-router proof shows an honest 4K60/300-second source requested at the 1080p tier preserving its 4K output while reserving **$12**, against the published **$48** tariff. The matching 4K control correctly reserves $48. No paid job or actual invoice was used. One correctly priced $48 job alone exceeds Team's $43.575 total monthly serving-cost budget for a 75% net-receipts margin at Apple 30%.

Use [the current pricing audit](../PRICING-AUDIT-20261003.md) rather than the older cost tables. Gross-payment versus net-receipts margin and the effective Apple commission still need explicit resolution. The proposed 80% net operating target / 75% floor is not approved or deployed.

### Identity and the legacy worker exception

The actual Auth guard uses server-validated anonymous identity. An anonymous caller needs an exact active/grace Apple subscription bound to their user, workspace and selected Starter/Pro/Team plan; anonymous Free/null-source fails. The existing isolated guard/Coach fixtures passed **44 tests** with network/write/run denied, including a negative control that removes the photo guard and reaches a meter.

For identified Free callers, five cached 6.7-cent image successes can already book $0.335 before input usage or fallback charges. Megapixel-priced masked edits can cost more. None of those examples establish a reconciled invoice maximum.

There is a **separate conditional source gap**: `POST /renders` can enqueue worker enhancements without the same identity gate, and the worker source can call paid providers. A valid uploaded asset and available/configured consumer are required; this audit did not establish live paid reachability, enqueue work or call a provider. Do not describe current app-photo denial as a universal platform-wide paid-cost boundary. If that worker path is active, close it or apply the shared identity and funded-cost admission before claiming complete coverage.

### Photo retention

Current `PhotoVersionHistory` persists the pre-staging base, creates a new saved edit without deleting predecessor bytes, keeps Latest/Decluttered/Staged libraries and separates listing selection from Latest. Original/selected-version export paths remain available. The existing actual-source fixture passed **340 checks** again; two independently compiled temporary-copy mutations for predecessor deletion and loss of the persisted base were both caught.

The old branch's `removeItem(at: p.enhancedURL)` and session-only `stageBases` would weaken those guarantees. Do not merge it as-is or cherry-pick that photo implementation. These tests are software evidence; they do not certify completed physical Photos/Files delivery or cross-device version-history restoration. Saved history is local; publication uploads the explicitly selected version.

## Fresh crash inventory and remaining phone acceptance

Apple API access succeeded with a GET-only, own-app transport guard. Exhaustive available-feedback pagination completed at **2026-10-03 17:17:50 UTC**: 44 listed builds, highest iOS 1.0.3 build 43, **one crash-feedback submission for build 37**, and zero available submissions for builds 40–43. Raw crash logs and identifiers remain outside Git.

This is an inventory of available TestFlight crash-feedback submissions, not a full automatic-crash census or evidence that the physical arm64e crash is conclusively resolved. Keep the documented owner-phone cold-launch/rich-listing/destination checks. No camera, LiDAR or new physical-device test was performed here.

## Advisor scope

The fresh advisor still reports `pg_net` in public, plus the existing authenticated/anonymous policy and function warnings. Callable-definer notices are metadata findings, not automatic proof of an authorization bypass: inspected member helpers apply identity/membership checks and two of the four anonymous function hits are trigger/event-trigger functions. The new held-cost helper also remains an intentional authenticated warning; do not claim a clean advisor scan.

The live catalog reports `pg_net` 0.20.4 in public with **`extrelocatable=false`**. A supported migration/dependency review is needed; do not issue a blind `ALTER EXTENSION ... SET SCHEMA`. [Supabase's extension warning](https://supabase.com/docs/guides/database/database-linter?lint=0014_extension_in_public) remains the reference. No extension, grants or policies changed.

## Remaining work

Prioritize actual payload pricing/media verification and a shared funded cost reservation before every paid app/Studio/worker attempt. Include recurring serving costs, annual/offer/refund accounting and separately funded zero-revenue trial/TestFlight usage. Preserve the existing video reservation and photo-history fixes. Physical-phone acceptance remains separate; spatial stays in its existing beta/quality-gated scope.

Evidence is retained under `/Users/pilksclaes/LocalRendpropAudits/claude-rerun-20261003/`: `live-reconciliation-readback.json`, `identity-reconciliation.md`, `pricing-reconciliation.md`, `photo-history-reconciliation.md`, their tests/source bindings, and `apple/crash-inventory-sanitized.json`. The earlier pricing and release receipts were preserved.
