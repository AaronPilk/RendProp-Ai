# Paid credits and seven-day trial: activation gate

This packet is source preparation only. `credit_monthly_catalog.active=false` and
`subscription_trial_config.enabled=false` are deliberate. Do not flip either
from a pricing UI change or a TestFlight screenshot.

## Public trial

The promised introductory term is seven days, one draft listing, up to five
selected photo edits and five assessments per day / ten per month. The trial
does not include publishing the listing website, video or aerial generation.
The app must verify Apple's actual USA free-intro
offer for the exact Pro29, Max, Ultra and Team subscription products, including
one introductory term per subscription group. The local `.storekit` file is
only a simulator fixture, not App Store Connect evidence.

Read `subscription_trial_activation_readiness()` with service authority. It
requires bounded product terms; an unexpired serving-cost sponsor envelope;
and an active USA seven-day schedule for each SKU backed by a dated, admitted
cash sponsor pool with enough uncommitted capacity. The existing $290
`app_config.trial_sponsor_pool` is an operational cost cap, not that separate
pre-purchase cash commitment. Every sponsor deposit, schedule price, Apple
commission floor and reserve component needs a documented receipt or cost
basis. The readiness function never enables purchases or attests that Apple
Store data and cash evidence were checked.

Before activation, verify a signed StoreKit **Sandbox/TestFlight** zero-price
intro against the originally reserved actor, org and SKU, then renewal,
expiration and refund/revocation. The test-only `grant_sandbox_intro_trial`
accepts only Apple's signed `FREE_TRIAL`, zero price, USA/USD, matching
`appAccountToken` and a term no longer than seven days. It creates one finite
test workspace trial only when the sponsor allocation covers the next seven
days and has at least the 500-cent trial envelope available. A paid Sandbox
purchase stays test-only and cannot open a trial. This exercises the trial UX
and bounded supplier path in TestFlight; it is **not** evidence of a funded
Production free-intro purchase. `apple-funding.ts` still returns
`reason:sandbox` for public purchase funding. Repeat the signed Production
path for the first paid renewal. Reconfirm the 5-edit supplier/assessment and
media-delivery bounds. Only then admit the funded pool and enable
`subscription_trial_config` in a reviewed, auditable database change.

## Paid monthly credits

Pro60 / Max120 / Ultra250 / Team600 and a 10-credit Declutter quote are
controlled TestFlight candidates, not activated retail allowances. Signed
paid transaction, renewal, refund and product-period replay tests must pass.
The server's monthly catalog then needs a reviewed activation, and the native
paywall must show exact current Apple `displayPrice` and authoritative credits.
No introductory, grace, refunded or Sandbox transaction may create Production
monthly credit grants. Purchased top-ups are nonexpiring and remain usable
after downgrade; they are bound to the original org and Apple transaction.

The dormant `credit-combined-v2` policy caps **all serving costs at 25% of
conservative Apple net proceeds**, using the lesser of the signed USA/USD
price after a 30% fee and the exact attested funding floor for the current paid
term. It removes seven explicit hosting, delivery, compute, email, support,
retention and uncertainty reserves first, then protects the full 5-cent
supplier face of every monthly credit. Video, aerial, assessments and other
noncredit supplier work use only the positive remainder. Linked credit supplier
receipts are counted once. Purchased top-up supplier liability is independent
because those credits have separate cash proceeds. The policy requires an
explicit `activated_from` timestamp:
paid periods that began before it remain on their legacy allowance until
renewal. Activating only the monthly catalog cannot mint Production grants;
the matching combined policy and date must be deliberately enabled after
final economics QA.

At the minimum funded operating reserve, the Pro/Max/Ultra/Team 3 supplier
ceilings are $4.24/$7.07/$14.99/$38.74. Their monthly-credit supplier faces
are $3/$6/$12.50/$30, leaving $1.24/$1.07/$2.49/$8.74 for noncredit media.
The precise price, reserve components and added-seat ladder are in
[the pricing margin repair](PRICING_MARGIN_REPAIR_20261027.md). This bounds
spending but does not prove realized margin without actual invoices and
serving limits. Keep the catalog and combined policy dormant until signed-period
and renewal tests, full-use supplier stress, and every marketed creative quote
pass. The 100-credit top-up also stays dormant until its $39.99 Apple price and
signed proceeds are verified.
