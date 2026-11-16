# Rendprop pricing audit — 3 October 2026

**6 October checkpoint:** the inclusive financial admission guards are delivered
as recorded in [the rollout handoff](handoff/CAS-AND-STUDIO-ROLLOUT-20261006.md),
with no retail, trial or App Review funds seeded. The advertised 100/200/400-photo
bundles remain financially **NO-GO** at the currently bounded attempt costs.
The guards prevent unfunded creation; they do not make those marketed quantities
deliverable within the owner's 75%-after-Apple serving envelope. The findings
below retain their dated source and catalog assumptions.

**4 October clarification:** the owner confirmed Small Business Program approval
(email received last week) and selected a 75% floor **after Apple's fee**.
The effective date is still unverified. The Topaz correction and current
policy are recorded in [the follow-up](handoff/TOPAZ-AND-MARGIN-20261004.md).
The findings below retain the 3 October evidence and assumptions; the full
margin floor remains unenforced.

**Decision: current plans do not enforce a 75% minimum margin.** Do not use the older pricing documents as a profitability guarantee. Existing monthly prices may be retained only with a revised, funded usage policy and complete cost admission; simply topping up fal does not fix the economics.

This audit reviewed source commit `a16465514f12d06bb61be405d12ce8dd7effd695`, live public plan/routing configuration, the public US App Store purchase catalog and current primary provider tariffs. No customer records, secret values, authenticated Apple account settings, vendor invoices or paid generation jobs were accessed. Runtime code, product prices, quotas, production configuration and vendor balances were not changed. This document and historical-document notices are documentation changes only.

## 1. Define the target explicitly

The owner requested a 75% floor excluding advertising acquisition costs. The denominator has not yet been chosen. These definitions have materially different results:

- **Margin on customer payments:** `(P − payment/platform fees − serving costs) / P`.
- **Margin on net receipts:** `(R − serving costs) / R`, where `R` is the payment after platform fees, applicable taxes, discounts, refunds and other proceeds adjustments.

For the US-price scenarios below, `R = P × (1 − commission)`; separately collected pass-through sales tax is excluded. Actual proceeds can be lower. Serving costs must include every provider attempt, compute, recurring storage/delivery and the allocated cost of serving the customer. Advertising/CPA is excluded. A contribution-margin target does not establish company-wide profitability: fixed overhead, unconverted trials and startup operating expenses still need funding.

[Apple's subscription rules](https://developer.apple.com/app-store/subscriptions/) ordinarily leave 70% in the first paid year and 85% after a paid year, before applicable taxes. Approved [Small Business Program](https://developer.apple.com/app-store/small-business-program/) participation can provide the reduced commission earlier. This account's approval and effective rate are unverified; use **30% conservatively** until established.

At a 30% commission, 75% margin on the full customer payment is **mathematically impossible**, even with zero AI or hosting cost: only 70% remains. At 15%, only 10% of the payment is available for all serving costs if the gross-payment margin must stay at 75%. A higher price alone cannot solve the 30% percentage-fee case.

The recommended, **unapproved** policy is an 80% operating target on net receipts with a 75% minimum, after all serving costs. The five percentage points provide headroom for cost uncertainty; they are not additional included AI allowance.

## 2. Verified products and current limits

The [public US App Store listing](https://apps.apple.com/us/app/rendprop/id6808982413), read without credentials on 3 October, lists the following five products. These match the local sold-product registry. Team annual exists in a local fixture/server compatibility mapping but is not currently sold by the app.

| Product | Customer price | Revenue per service month | Current provider ceiling/month |
|---|---:|---:|---:|
| Starter monthly | $49 | $49.00 | $12 |
| Starter annual | $490/year | $40.8333 | $12 |
| Pro monthly | $99 | $99.00 | $24 |
| Pro annual | $990/year | $82.50 | $24 |
| Team monthly | $249 | $249.00 | $60 |

Starter/Pro annual pricing is a **16.67% discount**, with the same monthly allowances. The annual cash receipt funds twelve months of service, rather than a fresh full-price monthly budget each month.

Paid monthly allowances, pooled per workspace:

| Plan | Tour renders | AI photos | Reel clips | Aerials | Topaz upscales | Seats |
|---|---:|---:|---:|---:|---:|---:|
| Starter | 4 | 100 | 6 | 2 | 0 | 1 |
| Pro | 10 | 200 | 12 | 4 | 0 | 1 |
| Team | 25 | 400 | 25 | 8 | 2 | 2 |

Voiceover and automatic chapters have independent counters in addition to those displayed allowances. Count limits are not equivalent to financial limits. The provider ceilings above are also not universal spending fences: several nonvideo/provider paths bypass their admission checks.

## 3. Maximum cost compatible with the target

These are **total serving-cost ceilings per service month**, not proposed AI-credit allocations. Hosting, support and other serving costs must be subtracted before assigning any AI allowance. All ceilings are rounded down to cents. They are mathematical scenarios, not deployed limits or a guarantee about actual invoices.

| Product | Net 75% floor, Apple 30% | Net 75% floor, Apple 15% | Gross-payment 75% floor, Apple 15% |
|---|---:|---:|---:|
| Starter monthly | $8.57 | $10.41 | $4.90 |
| Starter annual | $7.14 | $8.67 | $4.08 |
| Pro monthly | $17.32 | $21.03 | $9.90 |
| Pro annual | $14.43 | $17.53 | $8.25 |
| Team monthly | $43.57 | $52.91 | $24.90 |

Every current $12/$24/$60 provider ceiling exceeds even the net-receipts 75% budget, before hosting. If those ceilings are spent, monthly net-receipts margins at Apple 30% are approximately **65.0% / 65.4% / 65.6%**. These are ceiling-spend sensitivity scenarios; they are not observed invoices or proof that every nominal ceiling is reachable in a particular quota combination.

For the recommended 80% operating target, the more conservative budgets would be:

| Product | All serving costs, Apple 30% | All serving costs, Apple 15% |
|---|---:|---:|
| Starter monthly | $6.86 | $8.33 |
| Starter annual | $5.71 | $6.94 |
| Pro monthly | $13.86 | $16.83 |
| Pro annual | $11.55 | $14.02 |
| Team monthly | $34.86 | $42.33 |

Actual recognized proceeds, billing periods, discount/introductory offers, refunds and FX must determine the funded budget. The current verified-transaction decoder/subscription rows do not retain all of that information. Calendar-month cost resets and first-use rolling usage counters must not grant multiple budgets from one paid service period.

## 4. Cost bugs and missing financial enforcement

**Topaz actual output is underpriced in a reachable path.** With an honest 3840×2160, 60 fps, 300-second source, requesting the 1080p tier produces `upscale_factor: 1`; it does not downscale the source. The unchanged production handler and reservation helper reserve $12, while the [published Topaz Proteus tariff](https://fal.ai/models/fal-ai/topaz/upscale/video) implies **$48** for the resulting 4K60 output. This was reproduced offline with provider/auth/database doubles and controls, not a paid production job. Source width/height/FPS/duration are also client declared, so they need authoritative probing or a conservative bound before financial admission.

**Image price units can be wrong.** [FLUX Fill](https://fal.ai/models/fal-ai/flux-pro/v1/fill) charges $0.05 per rounded-up megapixel, whereas the live row books $0.05 per image. A 12 MP output would be $0.60; this is a conditional tariff example, not proof that the model preserves every uploaded image's dimensions. The API needs an enforced output-pixel bound and matching price calculation. The ordinary unmasked declutter flow is distinct from this masked Fill path. OpenAI `size:auto` and billable input tokens, and Gemini input/text/thinking usage, also make the cached output-only price an incomplete upper bound.

**Nonvideo spending can bypass the financial fence.** Photos, voice and chapters have count guards and best-effort post-call ledger writes rather than a shared, durable pre-call money reservation. Fallbacks and paid/ambiguous failures can cost money without consuming a success allowance. Copy, photo helpers, QC and coach have rate limits but no revenue-funded monthly money budget; some are accessible to identified Free accounts. Rate limiting alone cannot prevent loss.

**Studio limits are distinct from revenue-funded admission.** Editing plans and prompt enhancement have explicit enable/price gates, bounded output, a single attempt and daily request caps. Speech analysis also has configuration, duration and request caps. They do not share the ordinary-video money reservation or a verified-revenue budget. Their post-attempt ledger writes remain best effort. Presenter generation has its own durable lifetime workspace budget and defaults disabled, but that is also separate from collected subscription revenue. Current activation flags and customer-specific presenter settings were not queried; these code findings must not be represented as an observed production bill.

**Worker and recurring costs need separate closure.** Worker AI uses an in-memory per-job estimate cap and raw post-call ledger writes; live worker reachability was not established by this audit. It must use the shared financial protocol if enabled. Physical upload byte limits do not bound lifetime storage expense. Public delivery, retention after lapse, fixed service costs and recurring storage are outside the current provider ceiling. [R2 egress is free](https://developers.cloudflare.com/r2/pricing/), but storage and requests are charged; [Workers](https://developers.cloudflare.com/workers/platform/pricing/) and [Supabase](https://supabase.com/pricing) also have base/usage costs. Their current account invoices were not reviewed.

The recently deployed ordinary-video reservation journal does protect estimated-cost concurrent admission and retains uncertain provider acceptance. Preserve it. Its guarantee still depends on correct price units, actual media bounds and coverage of every paid dispatch.

## 5. Provider prices relevant to fal funding

fal's purchase-screen examples use Nano Banana 2 and Seedance 2. They are approximate illustrations, not Rendprop's configured production model mix. The enabled reel route currently uses **Seedance v1 Pro Fast**; the newer Seedance 2/2.5 routes and Kie/Higgsfield alternatives in the inspected catalog are disabled.

| Operation/configuration | Published provider-only cost | Important limit |
|---|---:|---|
| Seedance v1 Pro Fast, standard 1080p/24 fps/5 s | $0.243 | [Token-based tariff](https://fal.ai/models/fal-ai/bytedance/seedance/v1/pro/fast/image-to-video); auto-aspect output units require bounding |
| Veo 3.1 Fast, 1080p, no audio, 8 s | $0.80 | [Tariff](https://fal.ai/models/fal-ai/veo3.1/fast); audio/4K costs more |
| FLUX Kontext, one image | $0.04 | [Tariff](https://fal.ai/models/fal-ai/flux-pro/kontext) |
| Topaz Proteus, actual 1080p/60 fps/300 s | $12.00 | Output dimensions/FPS determine cost |
| Topaz Proteus, actual 4K/60 fps/300 s | $48.00 | Long upscales cannot fit safely inside the current Team plan at Apple 30% |
| fal Bria erase, 750p, per second | $0.14 | [Tariff](https://fal.ai/models/bria/video/erase/prompt); current app requires clips shorter than five seconds |
| Direct Bria mask + erase, per second | $0.065 combined | [$0.02 mask](https://platform.bria.ai/video-editing/generate-mask-by-prompt/api) plus catalog $0.045 erase; private TestFlight beta, not a generally enabled savings assumption |

These are primary published tariffs checked on 3 October, not reconciled account invoices. Do not assume every SKU receives fal's advertised eligible-usage discounts. Buying a provider balance is a cash prepayment; its eventual consumption is the expense. A recurring provider plan can create unused prepaid commitment and should not be purchased solely to advertise a lower unit cost.

For a $48 provider job, the minimum customer payment before other serving costs is:

| Target | Apple 30% | Apple 15% |
|---|---:|---:|
| 75% on net receipts | $274.29 | $225.89 |
| 80% on net receipts | $342.86 | $282.36 |
| 75% on customer payment | Impossible | $480.00 |

These are mathematical price floors, not recommended retail prices. They demonstrate why high-cost video cannot be described as an ordinary cheap included action. Restrict the supported configuration or sell separately funded usage with a quote before generation.

## 6. Recommended product and enforcement policy

1. **Keep the interface simple:** a base subscription for workspace/listing tools plus one shared, weighted AI usage balance. Display each action's credit quote on its action button before spending. Duration, resolution, model quality and stages determine the quote; a photo and a five-minute 4K video cannot cost the same credit count.
2. **Fund that balance from real proceeds:** recognize annual service over twelve months, subtract all serving-cost allocation, then use the 80% target / 75% floor policy if approved. Extra usage must come from verified paid purchases with the same fee-aware economics. No native consumable credit-pack product or implemented customer money wallet was found; this is a proposal, not an existing feature.
3. **Reserve before every paid attempt:** one organization-serialized durable money gate for app AI, Studio AI, helpers/QC, workers and each multi-stage call. Use immutable payload dimensions/rates and stable idempotency. Unknown prices fail closed. Retain ambiguous holds; do not refund a potentially paid call merely because the client timed out. Reconcile actual provider usage and invoices.
4. **Budget free usage explicitly:** a confirmed seven-day introductory subscription still earns zero subscription revenue until its paid renewal. TestFlight sandbox subscriptions also grant access without real receipts while providers charge real money. Give trials, QA, Free assistance and experiments separate finite owner-funded budgets. Their cost must be included in business economics even though advertising CPA is excluded. Do not silently alter the existing spatial experiment budget or beta gates.
5. **Fund retention and delivery:** apply clear storage and public-delivery allowances, with a policy/reserve for retained media after cancellation. Banked credits need funded outstanding liabilities; unlimited unfunded rollover or indefinite retained-media promises defeat the floor.
6. **Derive brokerage quotes from their allowance:** the existing $50/seat negotiation floor and $10.32 default cost formula are not a margin guarantee. Custom quotas, Topaz, voice/chapters, payment fees and hosting must enter the floor; below-floor service overrides need an explicit funded exception and verified collection policy.

Before claiming the floor: correct payload pricing, close all dispatch paths, validate purchase/billing-period/refund accounting, test admission concurrency and uncertain settlements, enforce recurring allowances, and reconcile a bounded real job per enabled tariff against provider usage. Do not rely on assumed 35% utilization, blended photo averages or a generic 10% retry allowance as a worst-case proof.

## Evidence retained locally

The full sanitized receipts, source hashes, offline reproductions and reproducible Decimal arithmetic are in:

`/Users/pilksclaes/LocalRendpropAudits/pricing-margin-20261003/`

Key files: `live-pricing-catalog.json`, `live-route-catalog.json`, `public-apple-pricing-readback.json`, `revenue-math.json`, `subscription-scenarios.csv`, `provider-pricing-review.json`, `topaz-actual-source-repro.json`, `topaz-live-shaped-router-repro.json`, `enforcement-review.json`, `enforcement-live-rate-clarification.json`, `studio-cost-clarification.json` and `policy-proposal.json`. The live-rate clarification corrects a legacy 4.8 cents/second Seedance assumption to the enabled 4.86 rate; it does not change the blockers. These are evidence of the audit, not a deployment receipt. Actual commission, all-storefront proceeds, account-specific provider tariffs and hosting/support invoices remain unknown.
