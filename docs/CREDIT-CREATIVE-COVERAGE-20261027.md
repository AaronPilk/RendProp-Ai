# Creative credit coverage audit — 27 October 2026

> **Historical snapshot, superseded later on 27 October.** The aerial and
> Photo Motion rows and launch gates below describe an earlier source state.
> The current candidate has a **dormant 20-credit, 1080p Aerial opening** path
> with a bounded supplier quote and fair customer-credit settlement
> (`20261027183000_credit_aerial_opening.sql`,
> `20261027184000_aerial_fair_charge.sql`), plus a quoted Photo Motion credit
> path (`20261027202224_photo_motion_credit_quote_gate.sql` and subsequent
> admission/terminal migrations). These migrations and their matching app and
> Edge code remain **source-only until the guarded backend rollout and device
> tests pass**. Use [the current trial/credit activation plan](release/TRIAL_AND_CREDIT_ACTIVATION_20261027.md)
> and live readbacks for release decisions; do not treat this audit's old
> "no wallet credits" statements as the current behavior.

This is a code audit of the candidate build, not a production deployment or an
App Store Connect price check. Customer credits and supplier spending are
separate ledgers. The quoted supplier amounts below are admission ceilings in
code, not settled invoices.

| Customer action | Customer billing in this branch | Evidence and release status |
| --- | --- | --- |
| Declutter one photo | 10 credits when the verified monthly-credit subscription is primary, or when a purchased top-up is used; legacy photo allowance for an included/old plan. One exact quote and request key per photo. | `services/supabase/functions/ai-photo/index.ts:171-245`; `services/supabase/migrations/20261027161200_credit_serving_photo_declutter.sql:1-115`. Existing tariff is active, but the launch catalog remains gated elsewhere. |
| Stage one photo | 15 credits on the same wallet path, or legacy photo allowance for an included/old plan. The iOS setup displays total credits for all selected photos and refreshes the quote and balance before dispatch. | `services/supabase/functions/ai-photo/index.ts:170-245`; `services/supabase/migrations/20261027182000_credit_photo_stage.sql:1-92`; `apps/ios/Rendprop/Screens/FlythroughDetailView.swift:5056-5190`. **New tariff starts inactive**, so this is implemented and tested but not purchasable/deployed. It must be activated with the matching binary and credit catalog. |
| Twilight, sky, lawn, custom photo edit | Legacy `photo_edits_per_month` allowance, not credits. The server rejects a credit header for these edits. | `services/supabase/functions/ai-photo/index.ts:171-245,931-949`. UI must not claim they spend purchased credits. |
| Import enhancement | Deterministic on-device photo processing; no AI supplier and no credit debit. | `apps/ios/Rendprop/Screens/FlythroughDetailView.swift` (`enhance` processing and import descriptions); keep free. |
| Photo Motion / listing video clips | Legacy `reelmo` allowance and video supplier cost reservation, not wallet credits. Photo Motion's final composition is local/worker processing. | `services/supabase/functions/ai-video/index.ts:339-458,1109-1277`; `services/supabase/functions/ai-video/cost-reservation.ts`. A finished clip is not the same as a credit-priced generation. |
| Current Aerial intro | Legacy `aerialmo` allowance plus five saved supplier reservations and a video reservation; no wallet hold. | `services/supabase/migrations/20261023173725_aerial_omni_reference_profile_functions_20261023.sql:114-151`; `services/supabase/functions/property-video-jobs/aerial-public.ts:19-29`. **Highest priority gap** because the owner explicitly expects an aerial price in credits. |
| Older AI aerial endpoint and drone/upscale | `aerialmo`/`dronemo` allowances and supplier reservations, not wallet credits. | `services/supabase/functions/ai-video/index.ts:339-458,1281-1392` and its drone route. |
| AI voice and room chapters | Separate voiceover and chapter allowances, not wallet credits. | `services/supabase/functions/ai-voice/index.ts:336-363`; `services/supabase/functions/ai-chapters/index.ts:325-359`. |
| Premium property website | Separate verified Apple consumable, tied to one property, not wallet credits. | `services/supabase/functions/_shared/property-website-purchase.ts:1-22`. A one-time purchase covers a persistent entitlement and hosting, so monthly credits cannot silently substitute without a duration/hosting policy. Basic sites use no wallet credit. |

The Stage/Declutter supplier fence is **5 cents per customer credit** across
every nonrejected provider attempt and the saved photo quality judge:
Declutter 10 credits / 50 cents; Stage 15 credits / 75 cents
(`services/supabase/migrations/20261027182000_credit_photo_stage.sql:39-75`).
That fence may refuse a route before supplier dispatch if its conservative
quote does not fit; it must not be bypassed to make an edit appear available.
The repaired local StoreKit test file has a dormant 100-credit pack at $39.99;
that implies $4.00 gross per Declutter and $6.00 per Stage from purchased
credits, before Apple commission, tax, hosting, and any other cost. This is not
evidence of the live App Store price or realized margin. Proposed monthly
grants are Pro 60, Max 120, Ultra 250, Team 600, with 100 more per paid Team
seat (`apps/ios/Rendprop/Purchases/Products.swift`). They put $3/$6/$12.50/$30
of supplier exposure at the 5-cent maximum before the combined subscription
ceiling. Unused monthly credits do not imply a provider bill; actual cost is
the settled ledger. See [the margin repair](release/PRICING_MARGIN_REPAIR_20261027.md)
for the full operating reserve and noncredit media budget.

For current Aerial intro, KIE generation alone is quoted at 45 cents for a
five-second 1080p Pro or Omni reference opening, or $1.675 on the old 4K
profile (`services/supabase/functions/_shared/aerial-kie.ts:15-17`). The
complete per-job quote adds vision assessment, quality checks, and processing
(`services/supabase/functions/property-video-jobs/aerial-public.ts:19-29`).
Do not advertise a fixed credit amount or extrapolate a live invoice from the
45-cent generator component. A wallet conversion must bind the exact manifest,
quote version, idempotency key, lifecycle, and five supplier stages; settle one
credit hold only when a billable provider result is confirmed, release if no
paid attempt happened, and preserve/finish saved holds after cancellation or
account downgrade. It must remove the corresponding legacy monthly debit for
the credit-primary path and prevent a second spend through the old endpoint.

The photo route settles the credit hold once generated bytes are confirmed,
before final geometry/storage/judge approval (`ai-photo/index.ts:1111-1158`).
An unusable generated image can therefore still consume credits, as supplier
liability may exist. The app must continue to show saved review/recovery rather
than promising an automatic credit refund for every rejected image.

Launch gates for truthful copy and safe billing:

1. Keep plan text scoped to **"eligible AI edits show their credit cost before
   you start"**. Purchased credits currently buy Declutter and, when activated,
   Stage. Do not say they buy all AI tools, Aerial intro, or property websites.
2. Apply the Stage migration; publish a matching iOS build; verify StoreKit
   monthly/top-up products, verified credit grants, wallet response and Stage
   quote on a sandbox phone; then activate only `photo-stage-v1`. The tariff is
   deliberately inactive in this branch.
3. Build and test an Aerial wallet bridge against its durable job journal
   before promising an Aerial credit price. Until then, say it uses its
   separate plan allowance and display no misleading credit balance there.
4. Review actual Apple product prices and provider invoices separately. The
   code ceilings protect spend but do not establish net profit.

Verification in isolated worktree: Deno check passed for `ai-photo/index.ts`;
the disposable PostgreSQL wallet test passed 69 assertions across 220
migrations, including Stage anti-cross-charge, saved-judge sharing, and the
75-cent cap; a full Debug iOS Simulator build passed. No deployment, catalog
activation, or physical-device acceptance occurred in this worktree.
