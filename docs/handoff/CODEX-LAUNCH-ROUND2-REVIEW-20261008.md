# Claude Round 2: independent review and staged repairs

Reviewed Claude `b320700` on `claude/launch-blockers-20261008`. Integrated into the isolated `audit/launch-alignment-20261008` branch through merge `1cbaa22415612c0eacf912dd184e518090b97baa`. This review distinguishes deployed Claude changes from additional Codex repairs. It is not an App Store release receipt or a claim that all application behavior has been tested.

## Production readback

Read-only checks confirmed migration `20261008235218 launch_round2` and ACTIVE versions: ai-photo 61, ai-video 59, ai-copy 28, ai-chapters 34, ai-voice 43, coach 30, studio 26, me 58, notify 20. The ai-photo runtime's shared router/funding/chain sources matched the integrated Round 2 source before these new local changes; the remaining complete source matches are recorded in Claude's `docs/releases/BACKEND-LAUNCH-ROUND2-20261008.json`, not independently re-downloaded in this review.

Production was in ceiling mode with commission 3,000 bps, margin 7,500 bps, hosting reserve 50¢, trial ceiling 500¢ and free lifetime ceiling 300¢. The dated trial pool was 29,000¢ for October 8–November 8; its counted spend was zero and `serving_cost_reservations` was empty at the read. These are a snapshot, not assurance that every provider attempt was settled correctly. No hosted data, configuration, secret, notification or Apple setting was changed by this review.

Security Advisor reported the new `cost_ledger_settle_serving_hold` SECURITY DEFINER trigger as client-executable. A trigger function is not directly callable as an ordinary RPC; no exploit was demonstrated. The staged settlement migration revokes PUBLIC/anon/authenticated execution. Other existing advisor findings were not blanket-revoked.

## Round 2 fixes independently confirmed

- A fresh disposable schema applied all 121 baseline migrations; the 176-assertion launch suite and concurrent same-writer/mixed-writer races passed, including lock-removal controls. The previously reproduced photo-then-video bypass is refused by the shared authority.
- Successful reservations still count after three minutes if their ledger write is missing. The old timer release is gone.
- A September 29–October 29 paid term retains September 30 expenditure after crossing a calendar boundary; it does not refill on October 1.
- An older active Sandbox receipt cannot revive a newer refund. An old inactive receipt reports the current different trial's deadline.
- An enrollment-backed retention notice remains valid at its delivery consumer. The notification dispatcher checks the current finding and admin status before delivery; cleared findings skip and read errors retry without sending.
- The new iOS model compiles against the actual SDK. The native and Studio clients display the shared allowance.

These confirmations supersede the corresponding findings in `CODEX-CLAUDE-LAUNCH-BLOCKERS-REVIEW-20261008.md`; do not repeat the old six-item report as if none were fixed.

## Additional defects reproduced and repaired locally

### Settlement must identify the exact attempt

The deployed trigger sorts same-request holds by matching stage, but can fall back to another stage/provider and then to FIFO. Actual ai-copy ledger writers omitted stage. A synthetic normal fallback used an uncertain OpenAI primary held at 50¢ and a succeeded Anthropic fallback held at 5¢. Inserting the actual key-only ai-copy receipt shape for a 2.1¢ winning estimate bound the OpenAI row; counted liability fell from 55¢ to 7.1¢, discarding the unknown primary 50¢. A separate duplicate-receipt fixture also bound two different holds. These are real SQL/RPC reproductions with synthetic charges, not measured supplier invoices or a paid exploit.

Staged migration `20261009003159_launch_settlement_identity.sql` requires exact workspace/request/stage/provider/model and a successful unbound hold. Missing identity and uncertain predecessors stay held for reconciliation. No FIFO substitution is permitted. Durable video/erase receipts and successful copy/chapter writers now carry their attempt identity. Existing mismatched bindings are conservatively unbound; their ledger rows remain counted. The new trigger's client permissions are revoked.

### Billing grace must not grant unpaid money

The deployed grace branch starts a new spending window at expiry. A stale grace record with its prior paid Starter term already fully spent admitted another 991¢ without a recovered payment. The native entitlement adapter actually stores Apple's grace deadline in `expires_at` for a grace snapshot, so simply using that field as paid expiry would also mis-anchor annual slices.

Staged migration `20261009003326_carry_paid_allowance_through_grace.sql` carries unused money from the last known paid term/annual slice for a delayed-expiry notification (the stored active receipt still retains its paid expiry). It counts paid plus grace expenditure and grants no second allowance. For a stored `grace` receipt, the current schema has overwritten the paid expiry and does not establish a funded paid balance; AI therefore fails closed locally. Missing chronology, expired grace and an expired introductory trial likewise cannot establish new paid money. Recovery requires a verified new paid term. No feature counts, prices, commission, sponsorship or retention policy were changed.

This is a staged safety repair, **not commercial grace acceptance**. Apple supports 3/16/28-day grace, including free-to-paid transitions, so a seven-day intro plus a 28-day deadline cannot prove a normal monthly payment merely by duration. Persist signed paid expiry and offer/proceeds evidence separately, and review the actual configured grace service/funding promise before deployment. Existing service entitlement itself is retained. Official configuration guidance: https://developer.apple.com/help/app-store-connect/manage-subscriptions/enable-billing-grace-period-for-auto-renewable-subscriptions.

### Native crash and allowance presentation

Very large but finite spend/held/pool numbers could pass the new decoder and trap when converted from Double to Int for currency display. Staged bounds and balance checks reject those payloads. The real decoder/adapter harness covers malformed and inconsistent figures, exhausted lifetime budgets and historical funded-trial coexistence; compiled guard-removal controls demonstrate the checks matter.

A checked ceiling allowance now takes precedence over historical funded-trial UI. Introductory allowance copy says it ends, rather than promising a reset. Trial capacity copy handles missing, malformed, future, ended and exhausted pools without showing internal global sponsor dollars. Studio has the matching copy and validation.

### Pool capacity is not the customer's quota

Shared pool `[pool=cap|closed]` failures now have the staged machine code `trial_capacity_unavailable`. They show retry/support guidance rather than a customer quota/upgrade action. Individual free, trial and paid quotas retain `quota_exceeded`. Native photo batches stop on the first capacity refusal; Studio mutations do not auto-retry it or expose raw error bodies. This wire change must be deployed with its clients and affected function bundles.

## Remaining public-launch work

1. **Supplier liability is still estimated.** Successful photo/copy settlement uses catalog prices (`ledger.ts`, routed `step.unit_cents`), not complete measured supplier usage. Reference staging explicitly labels input tokens unmodeled. The 8.3584¢ Flash hold replaces itself with a 6.7¢ estimate after success. Exact binding fixes the wrong-attempt defect; it does not make that estimate an invoice. Retain a proven full liability until authoritative reconciliation, or establish an enforced endpoint-specific bound.
2. **The input bound is not enforced.** The documented quote assumes ≤2,048px input, whereas the source policy accepts 24 MP and 8,192px per edge; reference-image geometry also needs validation. Vision comments describe approximately 2,322 Gemini tokens/image but the bound multiplies by 2,048. These are missing bound evidence, not proof of actual losses. Do not lower image quality just to make arithmetic fit; validate the intended-quality route with real outputs and actual usage.
3. **The whole advertised bundle and revenue floor still disagree.** Ceiling mode exits `apple-funding.ts` before saving verified transaction price/currency/offer facts, and uses nominal list prices. The 50¢ serving reserve is an assumption rather than a verified hosting/render/storage/delivery/retention bound. Basic catalog estimates alone exceed Starter/Pro budgets, especially annual slices; helpers, quality upgrades, fallback attempts and failures are additional. No human approval reduced the 100/200/400 photo counts. Present a concrete useful package with matching app/site/store copy before changing promises.
4. **Grandfathering is not a new-contract policy.** On a synthetic pre-October-6 original transaction, a new `SUBSCRIBED` purchase updates Pro but creates no retention enrollment because the cutoff uses original row creation. The handoff's claim that any new subscription enrolls is therefore false. Conversely, org-wide retention from a new original can affect old preserved tester content. Track contract/content cohort explicitly and preserve existing testers' content as the owner instructed.
5. **Real model acceptance and credential cutover remain open.** Historical FAL failures and a period with no attempts prove neither current failure nor health. Run one authorized non-admin/non-sponsored photo, reel and aerial through the actual app path, inspect the outputs and exact ledger bindings, and reconcile provider charges. SDK/unit/SQL success cannot certify model quality, camera behavior or StoreKit on a real iPhone.
6. **Funding and launch operations need evidence.** The owner approved preparing a monthly/trial launch ceiling of $290; that does not itself authorize recurring or automatic paid activation. The finite pool fixes recurrence but remains an AI-only allocation, with free lifetime samples and indefinite free hosting outside it. Keep a concrete allocation/revenue/serving-cost receipt and ordered credential cutover. Do not change repository visibility or revoke old production credentials merely because a handoff says owner-only.

### Basic bundle comparison (estimates, not a guarantee)

Only 100/200/400 Flash photos at 6.7¢, 6/12/25 reels at 24.3¢ and 2/4/8 aerials at 48.6¢ are included here. Team quality upgrades, helper calls, failures, hosting and retention are excluded.

| SKU | AI budget at 30% Apple | At 15% Apple | Basic catalog bundle |
| --- | ---: | ---: | ---: |
| Starter monthly | 807¢ | 991¢ | 913¢ |
| Starter annual monthly slice | 664¢ | 817¢ | 913¢ |
| Pro monthly | 1,682¢ | 2,053¢ | 1,826¢ |
| Pro annual monthly slice | 1,393¢ | 1,703¢ | 1,826¢ |
| Team monthly | 4,307¢ | 5,241¢ | 3,676.30¢ |

The handoff's 88%/92% describes monthly budget/catalog-basic-cost ratios. It is not a guarantee of the fraction of every meter available in arbitrary editing order. At 30%, annual ratios are about 73%/76%; even 15% does not cover the annual basic bundle. Apple says adjusted Small Business proceeds begin 15 days after the end of the fiscal month of enrollment approval: https://developer.apple.com/app-store/small-business-program/. An effective-date confirmation can establish that timing without waiting for a payout, but the owner's approximate “last week” is insufficient to set a precise date.

## Evidence and delivery state

Verification counts and source hashes are recorded in `docs/releases/CODEX-LAUNCH-ROUND2-VERIFICATION-20261008.json`. This review uses a source-bound unsigned Release **iOS Simulator SDK compile**, portable native production-code harnesses, disposable PostgreSQL, offline Deno and Studio/site build/package checks. No physical camera capture, paid provider acceptance, signed archive, upload, or public App Store submission occurred.

Private evidence:

- `/Users/pilksclaes/LocalRendpropAudits/launch-round2-20261008/native/`
- `/Users/pilksclaes/LocalRendpropAudits/launch-round2-20261008/web/`
- `/Users/pilksclaes/LocalRendpropAudits/claude-alignment-20261008/backend-b320700/`
- `/Users/pilksclaes/LocalRendpropAudits/claude-launch-blockers-20261008/financial-review/round2/`

Last independently verified TestFlight remains **1.0.4 (51)** from `2c567a5`; it is not this integrated source. Claude Round 2 remains the deployed backend baseline until a new verified deployment receipt says otherwise. Stage and review the new migrations/functions together; do not use this document to claim the local repairs are live.

## Claude follow-up — 2026-10-09 ~01:00 UTC: Codex repairs reviewed and DEPLOYED

Reviewed `1f5650e` independently and deployed it from a `git archive` export of that exact commit (receipt `docs/releases/BACKEND-LAUNCH-SETTLEMENT-GRACE-20261009.json`).

- Migrations live as **`20261009005727 launch_settlement_identity`** and **`20261009005753 carry_paid_allowance_through_grace`** (repo files renamed from the staged `…003159` / `…003326` to the ledger versions; `run_database_regression.py` updated). Pre-flight: all anchors unique on live, 0 ceiling holds, 0 active/grace Apple subscriptions.
- Functions: ai-photo 62, ai-video 60, ai-copy 29, ai-chapters 35, ai-voice 44, coach 31, studio 27, me 59 (sources read back and hash-verified). notify stays 20 (unchanged).
- Checked before deploying: `app_video_cost_reserve_v2` delegates to v1, so the shared authority covers the path the edge actually calls; video receipts' `request_key/stage/provider/model` come from the same values as the serving hold; direct-Bria stage receipts key on `job.id` exactly as `dispatchDirect` reserves them; `fundedAttempt` finishes `succeeded` before any ledger write, so the `state='succeeded'` requirement cannot strand a normal success.
- Known, accepted: an ai-copy compliance retry ledgers ONE row (the winning retry stage), so the first successful attempt's hold stays unbound and counted, and `holds_unledgered` will name it after an hour. That is the correct liability (the provider billed it); the fix is to ledger each successful attempt, not to relax binding.
- Proof: disposable PG with both migrations — every money suite green (see receipt); Deno 1,803 pass; live readback + anonymous smoke test (no provider called, probe account deleted).
- Not done by Claude: iOS/Studio builds and deploys (clients must ship with the new `trial_capacity_unavailable` code; old build 42 sees it as a 402 quota prompt, which is acceptable), and items 1–6 of "Remaining public-launch work" above — they stand as written.
