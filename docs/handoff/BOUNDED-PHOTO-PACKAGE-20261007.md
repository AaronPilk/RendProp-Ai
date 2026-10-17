# Bounded photo package — source for review, activation off

This change makes a finite package reviewable without changing prices, SKUs,
nominal quotas or existing funded intervals. No count, cash, schedule or offer is
seeded. The proposed5/20/60paid photo admissions and startup/trial amounts still
require a concrete owner decision and verified funding evidence.

New image generation accepts one complete static JPEG, PNG or WebP, at most9MB
decoded,24megapixels and8192pixels on either edge. Source and any mask share the
9MB limit. User instructions are at most600UTF-8bytes; the complete provider
prompt is at most8192bytes. HEIC/HEIF must be exported to JPEG first. Native and
Studio generation callsites already create JPEG copies; originals are retained.
The structural checks do not decode every codec entropy stream and do not prove
a smaller billable image-token count. Historical saved-result recovery occurs
before prospective input validation and does not dispatch a provider again.

A finite new image operation permits one pinned Gemini3.1FlashImage primary
(1K output and4096combined thought/output tokens) and at most one already
eligible, task-correct Kontext fallback. Masks have no complete priced fallback
in this finite policy and fail before provider dispatch. Disabled routes are
never introduced. Private unlimitedQA retains its operator chain and adopts the
same prospective structural input bounds.

The primary retains the full131,072-token Developer API input hold:31.1296c.
One Kontext image adds4c. A complete two-attempt admission therefore holds at
most35.1296c; five operations require175.648c, rounded up to176whole cents for
package provisioning. Average usage and Cloud/Vertex image-token statements are
not substituted for the actual endpoint's full input authority. These are
conservative published-tariff holds, not settled supplier invoices.

Paid suggestions and prompt rewriting remain separately metered. The exact
pinned helper payload has one content, one text and at most one inline still
image, no tools/references/cache/URI inputs, one candidate and1024combined
thought/output tokens. Both vision and text hold the full model input limit
(158.0544c) using the higher announced2027tariff. Text byte limits do not prove a
tighter billed-token bound, and an assumed tokenizer/role overhead is not used.
The bounded trial fences both helpers before dispatch so they cannot
spend its five included photo admissions' cash. Genuine pre-configuration funded
trial compatibility and privateQA are preserved.

## Optional protected package contract

`20261007145527_serving_photo_partitions.sql` creates empty service-only
partitions for an exact existing funding slice. The immutable record binds the
funding interval, chosen count,35.1296c complete photo hold, aggregate rounded-up
photo reserve, separately capped helper/otherAI wallet, policy, tariff and
evidence hash. The sum must fit the original inclusive serving budget after all
seven non-AI reserves. Configuration is refused after any attempt was admitted;
it cannot reinterpret historical financial activity.

The existing funding lock serializes provisioning and each cost admission.
Helpers/otherAI cannot spend protected photo money, and photos cannot borrow
their wallet. A primary consumes one admission before dispatch; definitive
rejection, cancellation, device change or metadata deletion cannot recycle it.
A fallback requires that exact primary's actor/key/task/input hash and the
immutable4c tariff. No third stage, altered input or unpriced model is admitted.
Existing funding without a partition retains its shared cash behavior. The
original funding/refund/uncertain-liability gates are unchanged.

`serving_photo_package_context(actor,org)` is service-only and returns null when
unconfigured or not currently authorized. A configured current interval returns
only its org, policy/tariff/period, integer photo cap/used/remaining, photo cash
metadata and capped otherAI wallet metadata (spent rounded up; remaining rounded
down). It emits no foreign actor or funding identities. `/me` and clients must
use this optional contract only for an actually configured package; no nominal
100/200/400quota is changed merely by deploying this migration. Saved work and
result recovery remain governed by their existing authorization.

The retained admission records have no Auth/organization cascade. They contain
account/workspace/request identifiers and one-way input hashes, never original
media or a download capability. Export/legal inventory is handled with the
matching account-owned metadata disclosure.

## Concrete proposal, still unapproved

Until effective15% Apple commission and eachSKU's settled net floor are proved,
the conservative30% scenario gives smallest monthly serving slices714c for
Starterannual,1443c for Proannual and4357c for Teammonthly. Proposed5/20/60
admissions cost176/703/2108c. With500c of non-AI reserves, the separate wallets
would be38/240/1749c. Starterannual's38c wallet cannot fund either full-context
158.0544c helper. Its monthly181c wallet could fund one, which cannot be promised
as a common annual/monthly feature. Verified15% proceeds would leave191c for
Starterannual and admit one helper. The UI must disclose the exact wallet/cost
before dispatch. Helpers remain metered on paid accounts; these quantities are
owner choices, not activated entitlements.

The proposed500c reserve split is storage16, delivery96, compute130, email1,
support100, retention49 and uncertainty108. The corresponding proposed media
ceilings are10GiB inventory,50,000charged operations and100GiB transfer per
purchased service month, with immutable full-period plus90-day-retention
coverage. Shared account base/billing rounding is paid once by a separate
startup receipt; per-customer incremental tariffs cannot claim startup is free.
Exact transport/retry coverage, account invoices, finite email/support policy
and accepted cash evidence are activation requirements.

For one ten-trial cohort, the review proposal is **$290: $250startup plus
$40for ten4-dollar trials**. Four illustrative40-dollar base months plus
28.72dollars of account-wide rounded boundaries already total188.72dollars;
the61.28dollar remainder must cover actual remaining base/log/email/uncertainty
liabilities. This is a cash ceiling to review, not a complete-cost certificate.
The97-day trial service/retention window cannot be funded by an80-dollar
two-month startup sketch. A provider credit balance is not trial sponsorship.

Annual-capable launch needs a different finite coverage window: up to466days.
Sixteen illustrative40-dollar base periods plus sixteen7.18-dollar rounded
boundaries total754.88dollars before other costs. An unapproved **$890finite
launch-cohort ceiling ($850startup+$40ten trials)** leaves95.12dollars for
remaining evidenced startup costs. This is an alternative to shorter
monthly/trial-only coverage, not an automatic charge, reserve creation or
perpetual funded pool. Every future funding interval needs bound coverage.

The proposed4-dollar trial splits176c photo cash plus4storage/20retention/
20delivery/23compute/1email/100support/56uncertainty cents. Its proposed media
ceilings are3GiB inventory,10,000charged operations and100GiB transfer over
97days, in addition to the independent1GiB input hold. These allocations require
covered prepaid startup authority and actual finite transport/cost evidence.
They do not activate a trial or authorize early Apple billing when usage ends.

Existing marketed100/200/400photo bundles remain a public-launch NO-GO: image
holds alone exceed the inclusive serving ceilings before any other cost.
Marginal spending at25% of net receipts also does not prove75% aggregate margin
while the owner funds startup and trials. Whole-company margin must include
those recorded base costs, actual invoices, refunds and operating expenses.

Primary rates: [Google](https://ai.google.dev/gemini-api/docs/pricing),
[combined output cutoff](https://ai.google.dev/gemini-api/docs/generate-content/thinking#token-limits-and-max_output_tokens),
[Kontext](https://fal.ai/models/fal-ai/flux-pro/kontext),
[Supabase compute](https://supabase.com/docs/guides/platform/compute-and-disk),
[R2](https://developers.cloudflare.com/r2/pricing/),
[Workers](https://developers.cloudflare.com/workers/platform/pricing/).
