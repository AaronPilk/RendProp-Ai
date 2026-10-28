# Provider cost readback — 2026-10-28

This is an owner-dashboard readback for launch economics, not a budget deposit,
supplier contract, or prediction of cost at scale. No purchase or provider
setting was changed during the read.

| Provider | Observed billing state | Launch implication |
| --- | --- | --- |
| KIE | 1,389 supplier credits remained at about 13:08 EDT; the displayed purchase rate was $5 per 1,000 credits; auto top-ups were **off**. API Usage showed $10.175 spent from October 15–28, of which $9.725 was Kling 3 and $0.45 Kling 3 Omni. | At the displayed rate, the current balance is about $6.95. A successful five-second 1080p aerial job in the visible log used 90 credits ($0.45); older successful five-second 4K property-video jobs used 335 credits ($1.675) each. These are examples, not a complete per-feature realized-cost distribution. The present balance would cover at most four more 335-credit jobs before other usage. Fund and cap supplier capacity before public paid activation. |
| FAL | Billing showed a **negative $2.79** credit balance and “out of credits”; paid invoices included $10 and $25 on October 14 and $25 on October 2. | Earlier FAL failures may be related to lack of credits. Check active route selection before claiming any current user flow depends on FAL. Do not route launch work to it without funded capacity. |
| Cloudflare | The October 18 invoice was $6.05 paid; September and August invoices were $5 each. Current October 18–November 17 billable usage displayed $0.00 with about 63.78k Worker requests, 4.03 million CPU milliseconds, and 1.7 GB-month R2 storage within included tiers. | Included-tier usage and historic invoices are not a marginal-cost forecast for public media traffic. |
| Supabase | The shared four-project Pro organization showed $26.18 current charges for October 20–November 20 and $47.71 projected. Base plan was $25; compute was $11.18 less $10 credits, with Rendprop at 208 micro-compute hours / $2.80 gross share before shared credits. Edge Function invocations were 48,921 of 2 million and egress 0.612 of 250 GB. Spend cap was **enabled**. | Shared invoices do not isolate Rendprop's full cost. At quota limits, the enabled spend cap can restrict service instead of allowing overage, so load and quota monitoring are an availability gate. |

The source quotes the optional KIE 4K property clip at 167.5 cents for one
five-second generation (`services/supabase/migrations/20261016100000_property_video_kie_kling3_4k_profile.sql`). This agrees with the visible KIE 335-credit receipts at $0.005 per supplier credit. The 12% local Photo Motion composition is a distinct route and does not make that KIE request. KIE's 1080p aerial examples agree with the source's 45-cent prospective route. Paid video retries, assessment, processing, hosting, delivery, refunds, and support must be accounted for in addition to a single successful model call.

The approved $1,000 / first-100-trials allocation is **not yet recorded as
unrestricted cash**. Connected payment cards and a plan to enable auto-refill
are not a reserve. Production trial and monthly-credit activation must remain
off until cash, supplier refill limits, signed StoreKit transactions, actual
receipt reconciliation, and full-use margin checks are proven. Max is $49.00,
not $49.99; its conservative noncredit media margin at the minimum operating
reserve is $1.07 per paid term. A 4K KIE job already costs more than that
amount, so it must be explicitly covered by a separately bounded paid-credit
quote or remain unavailable under that term. This note does not authorize a
funding or product-flag change.
