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
expiration and refund/revocation. Repeat the signed Production path for the
first paid renewal. Sandbox trial funding is not yet implemented; current
`apple-funding.ts` returns `reason:sandbox`, so this is a release blocker rather
than a claimed TestFlight pass. Reconfirm the 5-edit supplier/assessment and
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

The initial credit ledger separately limits supplier Declutter attempts to
5 cents per credit, and the assessment quota bounds skipped photos. That is
not yet a combined subscription margin cap: noncredit tools still spend from
the prior plan serving envelope. Activating monthly grants before the
combined org-period limit and usable-video/aerial stress test would allow two
independent supplier budgets. Keep this catalog dormant until the shared
ceiling is verified against real supplier receipts and every advertised tool.
