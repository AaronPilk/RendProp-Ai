# Topaz cost correction and approved margin policy — 4 October 2026

The owner directly confirmed Apple Small Business Program approval, with the
approval email received “last week,” and defined the minimum as **75% of net
receipts after Apple's commission**. Exact approval/effective dates remain
unverified. Use 15% for forecasts after effectiveness; retain 30% for current
admission planning until the effective date is established. Apple applies the
reduction 15 days after the end of the approval fiscal month:
[program rules](https://developer.apple.com/app-store/small-business-program/).

Claude's `15acc27` was read as report material. Its Topaz finding is correct;
its older photo patch must not replace build 43's separate saved libraries.
Neither Claude's working tree nor native source was modified for this fix.

## Monetary policy

All serving costs, including providers, failed attempts, hosting/storage,
delivery and serving support, must fit within 25% of recognized net receipts.
Advertising is excluded per the owner's instruction. Taxes/refunds/offers and
annual service allocation still affect the receipts available to fund work.

Maximum **total** monthly serving budgets, rounded down to cents:

| Sold plan | At Apple 30% | At effective Apple 15% |
|---|---:|---:|
| Starter $49/month | $8.57 | $10.41 |
| Pro $99/month | $17.32 | $21.03 |
| Team $249/month | $43.57 | $52.91 |
| Starter $490/year, per service month | $7.14 | $8.67 |
| Pro $990/year, per service month | $14.43 | $17.53 |

These are ceilings before reserving recurring serving costs, not AI allowances.
The existing $12/$24/$60 AI ceilings alone exceed these totals even at 15%.
The prior proposed 80% operating target remains a proposal, not an approved
replacement for the now-confirmed 75% floor. No plan prices or allowances were
changed by the Topaz fix. **The full margin floor is not yet enforced.**

## Topaz change

An honest 3840×2160, 60-fps, 300-second source requested as `1080p60` retains
4K because Topaz's minimum upscale factor is one. The old enabled-router path
reserved $12; the published Proteus tariff calls for $48. The corrected route
calculates both output dimensions from the exact factor and uses source MP4
headers/sample tables instead of client-declared upload metadata.

The new probe supports a narrow progressive H.264/AVC MP4 contract, checks
container/AVC configuration and sample-table consistency, caps metadata reads
at 2 MiB plus at most 64 small box headers, and uses a 15-second deadline.
It requires exact range responses with a stable strong ETag and total size.
Only completed v2 uploads can be submitted, because their publication key is
immutable; legacy sources need a new upload. Unknown/unsupported source formats,
output above 60 fps, duration above 300 seconds and output above 4096 pixels
are refused before allowance/reservation/provider submission. A 1080p selection
never silently downscales a 4K source.

Header validation is **not decoded-picture attestation**. Independent review
produced a tiny synthetic malformed `avc1` file with 1080p headers that a local
FFmpeg decoder renders at 4K. Therefore every accepted Topaz job reserves and
books the highest published tariff, **16 cents per second**, until trusted
decoding or invoice reconciliation supports releasing a cheaper amount. A
lower geometry estimate cannot weaken admission or settlement. This remains
a conservative published-rate policy for the supported container contract,
not proof of arbitrary hostile media's invoice or all subscription costs.

The API retains `estimated_cost` for the header-derived output estimate and
adds `reserved_cost` for the budget amount. For 300 seconds of 4K60 both are
$48. For 30 seconds of legitimate 1080p30 the estimate is $0.60 but the
conservative reservation/booked estimate is $4.80. This is a provider-cost
budget fence; it does not implement a customer credit wallet or an IAP charge.

Published tariff: up to720p $0.01/s, through1080p $0.02/s, above1080p $0.08/s;
60 fps doubles the rate. Rates above60 fps are unverified despite API support.
The actual adapter pins Proteus, so Gaia's discount does not apply:
[fal model pricing](https://fal.ai/models/fal-ai/topaz/upscale/video).

The existing atomic reservation journal, no-retry rule for uncertain POSTs,
and hold-to-ledger settlement remain intact. Both live model aliases
`topaz/upscale/video` and `fal-ai/topaz/upscale/video` are accepted; other
provider/model/unit combinations fail before a hold or provider POST. Journal
metadata stays within the deployed SQL whitelist, so no migration is needed.
The source's listing workspace now determines entitlement, quota and hold
when a caller belongs to several workspaces and omits `X-Org-Id`.

## Verification and release

The production route fixture reproduces the enabled live model alias/rates,
forged upload hints and the $48 hold/ledger amount. A behavioral negative
control reinstates tier-based estimation and is detected; the maximum-tariff
reservation still survives that defective informational estimate. Lower-price,
unsupported-source, duplicate, uncertain-POST and failed-settlement controls
also run offline. No paid provider job or customer media is used.

Final verification and deployment evidence will be added after the release.
Private artifacts are retained under
`/Users/pilksclaes/LocalRendpropAudits/topaz-cost-fix-20261004/`,
`topaz-output-fix-20261004/`, `topaz-decoder-review-20261004/`, and
`apple-small-business-20261004/` beside that directory. Earlier receipts are
preserved. Physical-phone acceptance remains the owner's test.

Remaining work from the pricing audit: shared funded reservations across all
paid paths; actual receipt/offer/refund/annual accounting; recurring-cost
allocation; separate trial/TestFlight funding; provider invoice reconciliation.
The complete list remains in [the 3 October audit](../PRICING-AUDIT-20261003.md).
