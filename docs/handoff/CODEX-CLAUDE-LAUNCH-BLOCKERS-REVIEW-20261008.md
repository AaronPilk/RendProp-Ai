# Review of Claude's launch-blocker fixes — 2026-10-08

Reviewed `f17d2bdf4de3d6760f2baa087b99de1c64d9bd3c` after reading `CLAUDE-LAUNCH-BLOCKERS-20261008.md` in full. Integrated by fast-forward into isolated `audit/launch-alignment-20261008`; shared branches were not rewritten. Three agents reviewed money admission, receipt/retention rules, and notifications/native presentation in parallel. No production writes, paid provider calls, credential changes, or Apple submission were made by this review.

**Release conclusion: material improvements, but not all eight blockers are closed.** The new passing suite does not cover several complete workflows. Fix the concrete cases below before claiming public launch readiness. Preserve the working routing, capture and publication plumbing.

## Verified progress and current deployment

- Live readback confirms migrations `20261008201736`, `20261008201840`, `20261008220411`; ceiling mode; the new 15%-commission/75%-net-margin envelope configuration.
- Live function metadata confirms ai-photo 60, ai-video 58, ai-copy 27, ai-chapters 33, ai-voice 42, coach 29, studio 25, me 57. Independently fetched ai-photo's deployed shared `funded-serving.ts`, `router.ts`, and `providers/chain.ts`: all match the integrated source exactly. Other bundle-wide byte matches remain Claude's release-receipt evidence.
- On a disposable PostgreSQL 17 database with all 120 migrations, Claude's 121 SQL assertions, three races and two lock-removal controls passed. The new helper reservation and durable publication locks work. Twenty-five focused Deno tests passed. These are bounded checks, not full CI or real model acceptance.
- Fresh inactive Sandbox receipts are refused; an ordinary previously granted receipt does not restart its original window. Ceiling purchases now receive independent 90-day retention enrollments.
- The documented SKU figures are correct arithmetic for **one allocation** at USD list price and an effective 15% Apple commission: Starter/Pro/Team 991/2053/5241 cents; annual-equivalent Starter/Pro 817/1703 cents. They do not establish actual supplier costs or correct allocation periods.

## Required fixes with reproductions

### 1. One money authority must admit video as well as helpers (P1)

`serving_ceiling_spent_cents` sees video holds, but the reverse is false: the actual `app_video_cost_reserve_v2` writer still uses the older entitlement ceiling and spend reader. Bria's separate admission likewise needs the same authority. The helper lock alone cannot protect a separate writer.

Actual final-schema reproduction: Starter ceiling **991c**, ledger **980c**, admitted photo hold **10c**. `app_video_cost_reserve_v2` then admits **9.72c**: **999.72c committed**, while its old reader reports only **989.72c** against the old 1200c cap. With global trial sponsorship set to **0c**, video still admits **9.72c** and the trial-pool reader counts **0c**; the helper control correctly refuses.

Route all paid writers (reel, aerial, Topaz, Bria, photos, text, voice, fallbacks and judges) through one shared admission/accounting authority and compatible locks. Test both ordering directions, concurrent mixed writers, free lifetime and trial-global boundaries. No provider dispatch may precede admission.

### 2. Do not drop a successful liability on a timer (P1)

New migration lines 124–130 count a successful serving hold for only two minutes. No receipt-bound ledger acknowledgement is required before it disappears. The photo submission can be marked successful before polling and transfer finish.

Actual reproduction: ledger **985c** plus successful **6c** hold counts **991c**. Move only the synthetic local settlement timestamp three minutes back, with no ledger row: the reader returns **985c**, then admits another **6c**. Actual committed cost is **997c** against **991c**.

Replace the timer with an atomic, idempotent hold-to-ledger reconciliation bound to the actual attempt/receipt. Preserve reserved/uncertain/succeeded liability until a definitive nonbillable rejection or confirmed transfer. Test delayed/missing/duplicate ledger writes, paid terminal failure, queued output, and settlement across periods.

### 3. Bind allocations to the paid service period (P1)

`plan_serving_ceiling` lines 72–103 supplies a full monthly envelope; `serving_ceiling_spent_cents` lines 126–129 resets by calendar month. These are different periods.

Actual synthetic timestamp reproduction: one Starter payment covering September 29–October 29 already spent **991c** September 30. October counts **0c** and admits another **991c** without another payment. Annual subscriptions can similarly span thirteen calendar buckets. A seven-day trial spanning month-end can receive two $5 allocations.

Allocate against verified paid transaction/service windows, with an explicit nonrepeating trial allocation; alternatively prove a correct prorated calendar schedule. Do not refill unresolved liability simply because the calendar changed. Test month-end, annual boundaries, renewals, grace, upgrades and replay with no new payment.

### 4. Preserve receipt chronology and report current account state (P1/P2)

New migration lines 329–332 overwrite Sandbox transaction/status/expiry while retaining `greatest(signed_at)`, so old facts can acquire a newer signature timestamp.

Actual reproduction: a newer refunded receipt returns `granted:false`; an **older signed active** receipt for the same original then returns **`granted:true`**, opens seven days, and leaves status active stamped with the newer time. Enforce chronology before applying facts; do not revive a refunded receipt from older evidence.

Separately, replay lines 335–339 run before the paid-workspace check. Actual reproduction: paid Pro remains Pro in the database, but old Sandbox replay returns `plan:trial`. Replaying an ended old grant while another trial is current returns the old October 7 expiry instead of the current October 15 expiry. `me/index.ts` forwards these fields; `PurchaseManager.sync/applyServerPlan` uses them for active plan/product, so paywall state can disagree with Home/Settings.

Keep immutable grant history, but return the current effective plan, source, product and current deadline. Test paid upgrade plus old replay, different current trial plus old replay, and out-of-order signed status changes. This is a response inconsistency, not a demonstrated database paid-plan downgrade.

### 5. Complete retention enqueue-to-delivery (P1)

The new queue includes `hosting_retention_enrollments` (migration lines 227–232), but `hosting_retention_notice_current` in `20261006172251_prospective_hosting_retention.sql:52–71` still recognizes only `serving_funding` IDs.

Actual reproduction: **one valid ceiling notice queued → consumer returns false → outbox state expired**, although hosting remains available under its valid 90-day deadline. The current passing tests inspect the deadline but miss the delivery consumer.

Have producer and consumer resolve the same latest enrollment/funding source, retaining current membership, account-deletion and deadline checks. Test the actual consumer for ceiling, funded, renewal, stale deadline, and ineligible recipient before enabling destructive retention drains.

### 6. Prove supplier liability and align the customer usage screen (P1/P2)

`funded-serving.ts:171–225` replaces verified quotes with catalog estimates in ceiling mode. Its new test explicitly replaces a **31.1296c** bounded image quote with **6.7c**. A ledger priced from the same estimate demonstrates internal consistency, not the supplier bill. Keep verified input/output-token, resolution, duration and fallback bounds unless actual evidence supports a lower complete bound. Do not change model quality to make a spreadsheet pass.

The supposed 25% buffer is the **entire cost allowance** for a 75% net margin. Starter uses **991c AI + 50c hosting = 1041c** of a **1041.25c** allowance: virtually no unallocated cost buffer. Verify the effective Apple fee, net receipt currencies/territories, hosting/storage/egress/processing and paid failures. Existing user approval is 75% **after** Apple's fee; lowering 100/200/400 photo allowances was not approved.

Expose the usable shared envelope, counted spend, held liability, basis and reset/end in `/me` and Plan & usage. Feature counts alone currently promise availability while the general money gate can refuse. Distinguish free lifetime exhaustion (no monthly refill), personal trial exhaustion and exhausted shared sponsorship. Current free error wrongly says wait for the next period; shared-pool error wrongly blames the customer and says subscribe even if they already subscribed for an Apple intro trial.

## The screenshot and actual provider evidence

The new operations notifications are enqueued for **global `profiles.is_admin`**, not ordinary customers or workspace managers. Live readback has one global admin. The 396.06c-over-300c alert belongs to the Richard Tocado free workspace; it is not evidence that the owner's Team account became Free. These are internal estimated serving-cost alerts, not customer charges.

Live Seedance record: 28 failures, last failure **October 2 at 20:44 UTC**, last success September 7, no stored HTTP status. OpenAI image route: three timeouts, last failure **October 2 at 15:34 UTC**, no stored status. OpenAI text has a separate successful health record. Those historical alerts do not prove the newly replaced FAL key failed today, or that every OpenAI feature is broken.

Read the signed-in FAL dashboard in Chrome: **$25 available**, pay-as-you-go, auto-top-up off. Error dashboard: no errors in the latest 24 hours; thirty-day results show two Topaz 503 entries from September 15 and one Fill 422 from September 8, without a matching October 2 Seedance entry. The precise current cause remains unproven; missing/invalid secret, ingress/auth, endpoint, network and input issues cannot be distinguished from these old null-status records. Do not label the FAL account empty or locked from this evidence. Next fresh controlled acceptance must retain actual HTTP status and owned receipt and prove saved playable output from a non-admin, nonsponsored account, within an explicitly funded limit.

Alerts dedupe per finding/user/channel/UTC day; already sent wording cannot update after a deploy. Delivery also does not recheck current global-admin status or whether the finding cleared. A seven-test network-denied synthetic dispatcher check confirmed an old ops row can still be delivered. Add current finding/recipient validation and label these clearly as admin alerts; preserve the monitoring rather than silently disabling it.

## Policy and release alignment

- Aaron authorized **preparing** a $290 monthly/trial launch ceiling. The deployed setting now resets an AI-only $290 sponsor pool automatically every month. That is not proof of approval for recurring sponsorship, nor a complete hosting/trial launch budget. Present a finite reviewed allocation and actual supplier evidence before activation claims.
- Small Business enrollment was approved last week; the effective 15% date is still unverified. The source uses 15% immediately. Preserve a conservative fee assumption until its effective application is known.
- Indefinite free listing hosting is an explicit unfunded policy choice. Do not claim its lifetime cost fits a finite guaranteed-margin budget. Existing testers must remain preserved; the owner's approved new-subscription retention is 90 days after service expiry.
- A Richard testing grant, any pool increase, model/pricing changes, and repo access changes are owner decisions; this review did not make them. Ordered credential cutover/revocation, served site/legal deployment, and real model acceptance remain unfinished.
- TestFlight 50 came from `c9cf64e`; 51 came from `2c567a5` and is internal-only. The new Home copy from `ec1e3e6` and native fix `7bc1c36` are in this integrated source but were not uploaded as a new build. The prior passing unsigned simulator SDK check is not an App Store archive, phone acceptance or current full CI.
- After the concrete fixes: qualify the integrated source in CI, deploy/source-verify the backend, verify served Terms/Privacy/Support, run real funded non-owner acceptance, then produce an App Store-eligible 1.0.4 archive. Keep spatial/Bria labs scoped for TestFlight. Do not submit the public app on the strength of build 51 or these synthetic tests.

## Local evidence for reruns

All additional SQL tests used synthetic fixtures in `BEGIN`/`ROLLBACK`; the disposable server was stopped. No hosted data was changed.

- Money-gap SQL: `/Users/pilksclaes/LocalRendpropAudits/claude-alignment-20261008/backend-f17d2bd/ceiling-gaps.sql`.
- Baseline full-schema/race receipt: `/tmp/rendprop-launch-blockers-pg-doscr3fk/receipt.json` (ephemeral).
- Financial/receipt/notice read-only results: `/Users/pilksclaes/LocalRendpropAudits/claude-launch-blockers-20261008/financial-review/actual-local-sql-review.private.json`.
- Committed portable command bodies and scope: `tools/audit/launch-blocker-review-20261008/README.md` and its three SQL scripts. These are diagnostic reproductions of the defects, not tests claiming release success.
- Notification dispatcher proof: `/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-ops-drain-review-x07wvgky/ops-proof.test.ts` and `runtime.log` (ephemeral, seven tests passed with network denied).

Convert these failures into tests of the actual dispatch/admission and notification-consumer paths. Report precise closure evidence and remaining uncertainty; do not turn passing catalog/fixture assertions into a model-quality or profit claim.
