# Claude launch changes: verified fixes and remaining launch blockers

Date: October 8, 2026. Purpose: feedback requested by Aaron for Claude to make fixes before an App Store submission.

Reviewed local `claude/launch-fixes-20261008` at `6225d63ea590d9689eb01266e2be03316cfd542a`, including backend `78556e0`, native/site `c90ef58`, and the attached handoff. Three independent review agents checked native integration, backend admission, and costs. Production inspection was read-only. Backend reproductions used synthetic Deno interfaces and a disposable local PostgreSQL 17 database; no customer data, provider jobs, purchase, notification, or production configuration was changed.

**Verdict: the changes improve access, error recovery, and operations, but the public launch is not ready.** Preserve those improvements while correcting the concrete faults below. This review does not authorize a lower margin, larger trial funding, reduced advertised allowances, or production deployment of an unreviewed fix.

## Source alignment and the native fix already prepared

Codex integration branch: `audit/launch-alignment-20261008`. Native fix commit: `7bc1c36fe07ab032b338eae30b531faa6a9cc3c4`.

That commit fixes:

- `AIFailure.init(_:title:message:)` did not assign the added `isServiceUnavailable` property. The first actual unsigned, nonlab Release simulator SDK build failed with this error (exit 65, 29.13 seconds). The copy now preserves the flag and support recovery.
- The held-trial fixture generator omitted the new ceiling purchase helpers and failed compilation. It now extracts those actual methods and exercises named/guest, owner/denied, eligible/ineligible, cancellation, and account/workspace/session changes.
- Ceiling trial headings used the funded-only offer predicate while the button used Apple eligibility. Offer presentation now follows the same ceiling predicate; ceiling checkout does not start the funded reservation flow. It displays no invented numeric trial allocation.
- Direct purchase calls now require the same named-account state as the UI.

The corrected regular Release simulator build **passed**, exit 0, 110.49 seconds, with changed source hashes stable during the build. It is unsigned software verification, not an Apple upload or a camera/purchase acceptance test. Focused native checks passed: held/ceiling purchase 131 assertions plus 27 fault controls; bounded trial 86 plus 23 controls; reel failure recovery 90. Baseline purchase fulfillment 126 plus 6 controls and subscription policy 312 also passed. `git diff --check` passed.

Use the native fix commit on top of Claude's changes; do not recreate the same fixes or force-push a shared branch.

The handoff's build/source description needs correction: TestFlight **50** contains `c9cf64e`; TestFlight **51** contains `2c567a5`. `ec1e3e6` adds the new Home banner after 51 was delivered. It is not 51's compiled payload. This integration has not been uploaded. The earlier 51 full CI failure remains recorded; it was not relabeled green.

## 1. Enforce costs before every paid app-AI attempt

`services/supabase/functions/_shared/funded-serving.ts:155` dispatches without a money reservation in ceiling mode. Photo, copy, voice, chapters, and Coach record through `_shared/ledger.ts:174`/`:188`, a best-effort direct insert into `cost_ledger`. That insert does **not** invoke `log_job_cost` or enforce a monthly ceiling. Successful ledger entries, feature counts, and after-the-fact alerts are not pre-dispatch price admission. Failed/refunded photo attempts and helper/fallback calls need liability accounting too.

Actual-method reproduction: an attempt started at **1,195 cents** with a **1,200-cent ceiling**, dispatched with **zero money-admission RPCs**, and recorded **1,201.7 cents** afterward. Existing ordinary-video reservation logic is a useful working safeguard; retain it.

Required fix: an atomic, shared account/workspace dollar reservation before each billable attempt, including helpers, fallback, voice, text, retries, and ambiguous failures. Retain charged or uncertain liabilities; release only costs proven not billable. Count provider-attempt costs even when the user's feature credit is refunded. An unknown complete price must not dispatch as ordinary customer expense. Ceiling mode can remain; fixing this does not require rebuilding the entire funded model.

Acceptance: under simultaneous requests at the limit, only affordable work dispatches; photo/text cannot bypass it; an uncertain timeout cannot release money and repeat indefinitely. Test actual admission methods and SQL, not only mocked `serving_mode` values.

## 2. Preserve Aaron's 75% margin after Apple's fee

The stated $12/$24/$60 monthly caps are too high even if enforced perfectly. At a 15% commission, before hosting, storage, delivery, voice, retries, and other serving expenses:

| Plan | Maximum all-in serving cost for 75% net margin | Margin if current AI cap is fully used |
|---|---:|---:|
| Starter monthly, $49 | $10.4125/month | 71.19% at $12 |
| Pro monthly, $99 | $21.0375/month | 71.48% at $24 |
| Team monthly, $249 | $52.9125/month | 71.65% at $60 |
| Starter annual, $490 | $8.6771/month | 65.43% at $12/month |
| Pro annual, $990 | $17.5313/month | 65.78% at $24/month |

These are arithmetic limits, not estimates of actual invoices. Derive a serving envelope from the actual SKU, commission period, net receipts, annual discount, and non-AI costs. An approved Small Business enrollment is not proof of the effective commission period. Do not silently lower 100/200/400 photo allowances or switch models to inferior output; report the quality/cost tradeoff if those promises cannot fit.

Production introductory transactions currently get the purchased-plan allowances with no shared launch sponsor cap because `apple-funding.ts` short-circuits classification. Define and enforce the promised **seven days or finite usage**, including a total trial sponsorship limit. The $290 approval was a monthly/trial launch preparation ceiling, not permission for unlimited free trials. Free-tier photo/helper allowances also recur through 30-day meters rather than being one finite onboarding sample.

## 3. Expired and refunded Sandbox receipts must not grant new access

`services/supabase/functions/me/index.ts:1226` calls `grant_sandbox_trial` before using the derived receipt status. The SQL grant accepts original/product strings, persists no receipt identity or verified expiry, and resets an expired trial to `now() + interval '7 days'`.

Actual handler fixtures returned **200 plus a future trial** for both an expired and a revoked receipt; the same response reported `expired` or `refunded`. Actual SQL replay of the same original after trial expiry granted **7.00000 new days**. The paid Pro protection control passed and must remain.

Required fix: validate current verified entitlement status before granting; bind the buyer, workspace, original, transaction, and verified validity period; persist the grant and make replay idempotent. The same receipt cannot restart an exhausted or expired sponsor window. Keep explicit owner testing sponsorship separate from reviewer/customer trial grants.

Acceptance: expired, refunded, revoked, wrong-buyer/workspace, reused and exhausted receipts cannot create fresh sponsored access; a valid replay preserves the original deadline and counters; paid workspaces are never downgraded.

## 4. Consume the one-free-listing slot atomically

`20261008201736_launch_ceiling_mode.sql:43` counts existing renders without locking or consuming a durable workspace slot. Different publication jobs lock different job rows.

Actual PostgreSQL reproduction allowed **two concurrent first publications to commit** for one free workspace. A sequential second publication was correctly refused. Ordinary soft deletion retained the consumed slot; that claim passed.

Required fix: a durable workspace-scoped publication admission, consumed atomically; republishing that same listing remains idempotent. Exercise concurrent jobs against actual SQL and the publication path.

## 5. Missing serving configuration must fail closed

The SQL `serving_mode()` returns ceiling for every value except exact `funded`. Actual SQL returned `ceiling` for both a missing config row and `{}`. This contradicts the TypeScript comment and mock test's fail-closed claim.

Required fix: only an explicit valid `ceiling` activates ceiling mode. Missing, malformed, null, or unknown configuration should use the safe mode and be observable. Test the actual SQL function.

## 6. Retention must apply to ceiling subscriptions

Production readback confirms `hosting_retention_state` finds its deadline only through retail/trial `serving_funding`. Ceiling purchases create no such rows. A new ceiling subscriber therefore falls into `policy: preserved`, with hosting available indefinitely. This conflicts with the approved prospective 90-day grace and public Terms.

Required fix: record hosting-policy enrollment and expiration/renewal deadlines independently of AI-funding rows. Preserve existing testers. Test paid expiry, renewal, refund, grace, notification/export access, and protected testers. A free lifetime listing also needs an explicit bounded serving-cost decision; it cannot be represented as margin-free forever hosting.

## 7. Prove the paid providers work, then finish the release surfaces

Read-only production status still shows Seedance **28 consecutive failures**, last success **September 7**; zero recorded generation cost in the last 24 hours at inspection. Honest error copy and an ops alert do not make reels operational.

Fix the failing configuration/provider path and retain a successful real non-owner photo, reel, and aerial result, assessed for useful output and actual cost. Stay within an expressly approved generation budget. Do not swap models solely on advertised price or declare success from HTTP 200.

The repository is still **public** (verified with `gh repo view`). Credential rotation and legacy-key shutdown remain explicitly unfinished/unverified in Claude's handoff. Complete the ordered runtime cutover and revocation without breaking public build 42; making the repo private alone does not revoke exposed keys. Preserve rollback and do not print/copy secrets into code or reports.

The live site still serves October 6 Terms/Privacy and old guest-support copy; Claude's site draft is not deployed. The local Worker typecheck and all configured `npm test` suites passed, including 92 legal assertions and actual bundle/media checks. However, draft Terms section 6 still describes separately funded/reserved trial usage while ceiling purchases skip that flow. Reconcile trial and retention behavior first, then deploy matching legal/help and metadata, and verify the served pages.

Apple read-only status: public 1.0.3 remains released; latest uploaded build is 51. All five sold IAP products are approved and at the expected US prices; Team annual is off sale. No 1.0.4 editable App Store version exists in the returned list. The old status script's zero-screenshot message is not proof the released version has no screenshots—it has no next editable target. Prepare the explicit next version/build, matching screenshots, account-first review notes and working reviewer path after the blockers are closed.

Do not submit internal-only build 51 to the App Store. Build and validate a normal App Store-eligible archive from the integrated reviewed source. Real-phone checks remain Aaron's: account sign-in/cancel, saved-work transfer, account/workspace switch isolation, restore/upgrade, free-first/paid-second publication, physical capture, and AI result/export flows. No simulator result in this review certifies camera behavior.

## Verified live improvements to retain

- Live `serving_mode = ceiling` and both October 8 migration versions match the handoff.
- Active versions: ai-photo 59, ai-video 57, ai-copy 26, ai-chapters 32, ai-voice 41, Coach 28, Studio 24, notify 19, me 56.
- All six new mode/publication/trial/ops RPCs deny `anon` and `authenticated` execution.
- Guest refusals changed to 403, existing ownership checks remain, and recipient verification is single-use.
- Hourly ops cron 8 is active. Destructive cleanup crons 5–7 remain off. Do not switch them on without reviewing their actual deletion behavior.
- No concrete notification regression was found in the targeted review. The live security advisor returned WARN/INFO findings that require contextual review; it did not report these new RPCs as client-executable.

## Evidence and limits

Private local SDK/live-page/Apple-status evidence: `/Users/pilksclaes/LocalRendpropAudits/launch-alignment-20261008/`.

Private backend reproducers: `/Users/pilksclaes/LocalRendpropAudits/claude-alignment-20261008/backend/` (`scratch-schema.sql`, `scratch-sql-results.json`, `actual-backend-repro.test.ts`, `actual-backend-repro.stdout.txt`). 148 existing targeted edge tests passed; five additional cases demonstrate the current faults. Those five passes mean the bugs reproduced, not that corrected behavior passed. The scratch database is stopped.

This is a focused integration review, not a claim that every code line, paid provider, physical camera, crash class, or public release has passed acceptance. No App Store/TestFlight upload or production mutation was performed for this review.
