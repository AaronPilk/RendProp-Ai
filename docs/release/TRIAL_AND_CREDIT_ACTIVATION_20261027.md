# Paid credits and seven-day trial: activation gate

This packet is source preparation only. `credit_monthly_catalog.active=false` and
`subscription_trial_config.enabled=false` are deliberate. Do not flip either
from a pricing UI change or a TestFlight screenshot.

## Public trial

The promised introductory term is seven days, one listing, up to five selected
photo edits and five assessments per day / ten per month. It does not include
video or aerial generation. The app must verify Apple's actual USA free-intro
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

Pro80 / Max200 / Ultra440 / Team1000 and a 10-credit Declutter quote are
controlled TestFlight candidates, not activated retail allowances. Signed
paid transaction, renewal, refund and product-period replay tests must pass.
The server's monthly catalog then needs a reviewed activation, and the native
paywall must show exact current Apple `displayPrice` and authoritative credits.
No introductory, grace, refunded or Sandbox transaction may create Production
monthly credit grants. Purchased top-ups are nonexpiring and remain usable
after downgrade; they are bound to the original org and Apple transaction.

The dormant `credit_combined_budget` policy makes the total subscription
supplier ceiling **45% of conservative 70% Apple net proceeds, less 50 cents
for hosting**, using only the signed USA/USD price for the current exact paid
term. It reserves the full 5-cent supplier face of every monthly credit up
front, then limits video, aerial, assessments and other noncredit costs to the
remainder. Linked credit supplier receipts are counted once. Purchased top-up
supplier liability is independent because those credits have separate cash
proceeds. The policy also requires an explicit `activated_from` timestamp:
paid periods that began before it remain on their legacy allowance until
renewal. Activating only the monthly catalog cannot mint Production grants;
the matching combined policy and date must be deliberately enabled after
final economics QA.

At candidate prices/grants the combined ceilings are Pro $8.94, Max $15.24,
Ultra $30.99 and Team $78.24. The monthly-credit reserves are $4/$10/$22/$50,
leaving only $4.94/$5.24/$8.99/$28.24 for all other supplier work, including
assessments. This deliberately guarantees the monthly credits remain usable,
but the remaining video/aerial headroom may not support advertised quotas.
Keep the catalog and combined policy dormant until signed-period and renewal
tests, full-use supplier stress, and every marketed creative quote pass.
