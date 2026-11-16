# Owner decision sheet: trial funding and paid allowances

The approved product scope can be implemented, but **no whole trial subsidy or positive paid photo allowance is financially certified yet**. The trial money proposal is unapproved; trial funding/configuration remain off. Keep ordinary new paid checkout closed until the complete paid bundle has a verified funding contract. This sheet proposes decisions; it changes no prices, quotas or funds.

## Trial: what the numbers actually buy

In ordinary terms: the approved experience lasts up to seven days and includes one short walkthrough from the user's own footage, five photo-request credits and one published listing. Each allowance is independent; using one does not erase the others. A failed or interrupted accepted photo request can still use a credit. Exhaustion does not start Apple's paid renewal early or erase saved work. This experience remains disabled until its funding and paid-plan gates are complete.

The approved trial is seven days or included usage exhausted: one captured/imported walkthrough of at most 90 seconds, five admitted photo requests, one published listing and 1GiB lifetime uploads. A photo admission consumes a credit before generation; it is not a promise of a successful edit. Fallbacks can add provider attempts without granting another credit. Captured footage avoids buying AI-generated video, but processing and hosting still cost money.

The pinned Gemini image request holds **31.1296¢ ($0.311296)** per provider attempt: full 131,072 input tokens plus 4,096 combined thought/output tokens. This is a documented ceiling, not paid-account acceptance, quality or invoice proof.

| Five-request scenario | Exact provider hold | Whole cents to earmark before other costs |
|---|---:|---:|
| One pinned Gemini attempt per request | $1.556480 | $1.56 |
| Gemini plus at most one 4¢ Kontext fallback per request | $1.756480 | $1.76 |
| Five single Gemini attempts plus one vision suggestion | $3.620864 | $3.63 |
| Five single Gemini attempts plus two vision suggestions | $5.685248 | $5.69 |

Kontext’s 4¢ quote applies only to its priced no-mask request shape, and only where it can perform the requested edit correctly. Other stages cannot be assumed free or silently skipped. Unknown-price stages currently refuse finite admission. The route/fallback policy needs an explicit maximum for **every** attempt; ambiguous results retain their holds. Photo suggestions and prompt polish share the cash envelope but do not consume these five photo credits.

**Package proposal to price:** keep the approved five photo admissions; use an explicitly bounded, task-correct photo chain, and exclude expensive helpers from that package or give them a separately funded finite count. A hypothetical $5 owner-funded envelope leaves at most $3.44 after five single attempts, or $3.24 after the two-stage scenario, for all seven cost categories below. Those leftovers are arithmetic, not measured reserves. The amount should be approved only after those categories fit. A hypothetical $25 pool supports five full $5 lifetime purchase holds, including abandoned availability checks; it is not a signup cap, a customer charge or another FAL package purchase. Neither amount is approved.

Atomic pre-purchase reservation and trusted video-duration admission are deployed dormant. Cancellation, interruption and deletion cannot recycle an admitted sponsor commitment. Enabling an Apple auto-renewing trial also requires a workable, funded paid plan afterward; trial sponsorship cannot repair the current paid promises.

## Paid plans: budget available at the 75% after-Apple target

Only 25% of verified after-Apple net can pay **all** serving costs. The retained USA/USD catalog gives the following scenario; its 15% proceeds figures are not settled cash or proof that the reduced commission is effective today. Apple approval timing, taxes, adjustments and refunds still need an attested conservative proceeds floor.

| SKU | Customer price | Catalog proceeds | Maximum inclusive serving envelope |
|---|---:|---:|---:|
| Starter monthly | $49 | $41.65 | $10.41/month |
| Starter annual | $490 | $416.50 | $104.12/year; four $8.67 and eight $8.68 anchored intervals |
| Pro monthly | $99 | $84.15 | $21.03/month |
| Pro annual | $990 | $841.50 | $210.37/year; eleven $17.53 and one $17.54 anchored intervals |
| Team monthly | $249 | $211.65 | $52.91/month |

The marketed 100/200/400 photo requests alone would hold **$31.1296/$62.2592/$124.5184**, even with one Gemini attempt each and no fallback, helper or hosting cost. They exceed the monthly envelopes before the rest of the bundle. Annual discounts make the constraint tighter.

Two alternatives to review, with prices unchanged and **no approval implied**:

1. A smaller photo-centered bundle. For example, 10/25/60 admitted requests for Starter/Pro/Team can be costed using the bounded two-stage scenario above:

| Proposed count | Image-only money earmark | Left for every other feature and all seven categories |
|---|---:|---:|
| Starter 10 | $3.52/interval | $6.89 monthly; at least $5.15 annual interval |
| Pro 25 | $8.79/interval | $12.24 monthly; at least $8.74 annual interval |
| Team 60 | $21.08/interval | $31.83 monthly |

These are candidate counts to cost, **not publishable allowances**. Current renders, voice, copy, chapters and any enhancement promises must also fit those residual amounts or be clearly changed in the proposed bundle. The example does not establish that they fit. An unverified effective commission or lower recognized proceeds reduces the envelope again.

2. A disclosed shared AI spending allowance, set only after all other liabilities are reserved, with explicit per-feature attempt caps. This can adapt to differing route costs but must tell customers the usable included service before purchase; it cannot silently deny a marketed number of edits. Both alternatives need matching marketing, purchase/renewal admission and acceptance tests before launch.

## Seven concrete costs that still need a maximum

All seven categories below remain launch gates: none yet has a complete, verified maximum for this bundle. Provider holds alone cannot certify the target margin.

Paths refer to the mapped frozen 7f source. Public supplier rates are inputs, not account invoices or enforceable spend limits.

| Cost line | Current bound and remaining work | Evidence needed to price the maximum |
|---|---|---|
| Storage | `uploads/index.ts` and trial SQL bound 1GiB trial ingress. Generated images, transient/copy objects and accumulating byte-days need their own inventory/admission and physical deletion acknowledgements. | R2 storage class, daily-peak GB-month quantities, ClassA/B operations, rounding/shared free allocation; Supabase disk/backups and worker-volume invoice allocation. R2's published $0.015/GB-month alone does not price this whole inventory. |
| Delivery | `tour-host/src/media-delivery.ts` and `ai-photo/photo-result.ts` authorize reads but do not cap cumulative GET/HEAD/Range/recovery requests or bytes. A 600s signed URL is reusable. Add bounded gateway/provider authority, including rejected traffic and its own guard cost. | Actual Worker/R2/Supabase request, CPU and egress units, account pools and overages. Stream remains off. Complete the separate public-media access/cache gate before promising publication availability. |
| Compute/DB/functions | `ffmpeg_render.py` has per-invocation time bounds; `infra_costs.py` records estimates. Reserve actual CPU/RAM/disk/request/DB units before work and cap retries, concurrency and cumulative use. | Purchased Supabase compute/addons/MAU/edge/egress; Worker fixed $5 account plan plus request/CPU allocation; actual render-host uptime/resources/minimum replicas. Fixed costs need an explicit allocation, not assumed future customer counts. |
| Email | `notify/index.ts`, `email.ts` and lifecycle SQL bound batches/five row attempts, not total new rows. Meter enqueue and dispatch attempts; earmark mandatory notices before optional sends. | Actual Resend base/includes/overages, recipient and ambiguous-retry billing, invoice quantities/credits/tax. |
| Support | The ledger has a numeric support reserve but no bound on promised labor. Define included service and a time/event ledger or conservative fixed staffing allocation. | Actual payroll/contract rates, minimum staffing and escalation commitments; absence of tickets is not zero liability. |
| Retention/cleanup | Prospective retention SQL gates access at expiry +90days; it does not physically remove every object. Add expiry-to-deletion inventory, bounded completion and renewal safeguards. Preserve old testers as separate sponsorship. | Maximum byte-days through the paid/trial term plus 90days and cleanup; backup/provider-copy retention, deletion SLO and residual-byte completion evidence. |
| Uncertainty/reversals | `funded-serving.ts` keeps uncertain costs; purchase-reservation SQL keeps irreversible holds. Cost every enabled fallback/helper, cap attempts and reconcile provider receipts without treating timeouts as free. | Supplier-account acceptance, invoices and tariff/tax changes; effective Apple commission and financial reports by SKU/period/territory/currency, including adjustments, refunds and recognized net. |

The next owner-ready decision needs four filled items: **(a)** exact photo/fallback/helper package; **(b)** seven evidenced reserve amounts backed by hard limits and actual account rates; **(c)** conservative Apple proceeds floor and a complete paid/renewal bundle; **(d)** trial cash per irreversible hold and total committed pool. Once these fit together, an explicit funding approval can be concrete. Until then, preserve testing/Restore/Manage and leave funding and new paid checkout off. No GPU/spatial repricing is proposed here.

## Input-bound recheck — 7 October 2026 UTC

The current pinned request does not establish a smaller hard Developer API input-token bound. Its base64 cap limits encoded bytes, while decoded image dimensions and animation frames are not bounded by the server. `imageSize:1K` sets output resolution. The [Developer media-resolution tables](https://ai.google.dev/gemini-api/docs/generate-content/media-resolution) describe approximate, model-dependent token counts. The [Cloud model card](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/gemini/3-1-flash-image#image_generation_specifications) gives an exact input-image count in its own endpoint scope; the reviewed documentation did not establish that contract for the current Developer endpoint. This endpoint distinction is a conservative inference from the documented scopes, rather than a supplier confirmation.

Even a hypothetical zero input cost leaves the existing output reservation at 4,096 tokens × $60/million = **$0.24576 per attempt**. At 100/200/400 requests, that output hold alone is $24.576/$49.152/$98.304, exceeding the monthly serving envelopes before any other costs. These are conservative reservation amounts, not actual per-job invoices. Tightening only the input estimate cannot certify the current bundles. No quote, route, payload, funds or published allowance was changed.

The research receipt binds five current source inputs at `793ef9a`; SHA-256 `31fb434d16cfa3ad197fc7e17c7312ff4e4dcaff5d8f2cc85f5bbaacff37375e`. No provider call or output-quality experiment was performed.
