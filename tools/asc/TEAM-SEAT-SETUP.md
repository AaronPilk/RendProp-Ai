# Dormant Team seat subscriptions

The three-seat Team subscription remains `com.rendprop.app.team.monthly` at
$249.99/month. Extra capacity uses a separate auto-renewable subscription in
the same Apple group and level, with one current product per workspace:

| Seats | Product ID | US monthly price | Monthly credits |
| ---: | --- | ---: | ---: |
| 4 | `com.rendprop.app.team4.monthly` | $299.99 | 700 |
| 5 | `com.rendprop.app.team5.monthly` | $349.99 | 800 |
| 6 | `com.rendprop.app.team6.monthly` | $399.99 | 900 |
| 7 | `com.rendprop.app.team7.monthly` | $449.99 | 1,000 |
| 8 | `com.rendprop.app.team8.monthly` | $499.99 | 1,100 |
| 9 | `com.rendprop.app.team9.monthly` | $549.99 | 1,200 |

These exact prices and credits match the forward repair in
`services/supabase/migrations/20261027190441_pricing_margin_repair.sql`.
The Apple definitions are in `asc.py` and `Rendprop.storekit`, but normal ASC
commands **exclude all six**. The prepared app requests them from StoreKit and
shows none until a workspace-scoped server sale list confirms exact funded
catalog readiness. The server funding/catalog rows remain inactive.
App Store Connect GET on 28 October 2026 confirmed all six USA price points,
monthly periods, level 1, localizations and introductory offers. Each product
still reports `MISSING_METADATA` because its App Review screenshot is absent.

Read-only inspection, when Apple credentials are available:

```sh
python3 tools/asc/asc.py status --include-team-seats
python3 tools/asc/asc.py subscriptions plan --include-team-seats
```

`subscriptions plan` can stop immediately on the existing $49/$99/$249
monthly-price mismatch. [Schedule the exact .99 increases separately](SUBSCRIPTION-REPRICE.md)
while preserving existing subscribers' current prices, or explicitly skip the
three mismatched IDs to inspect the dormant-seat products before those prices
take effect. Only then review the explicit `subscriptions apply
--include-team-seats` plan. That
command can create and price the six Apple subscriptions, localize them, set
USA availability and a one-week introductory offer; it also reconciles the
four base monthly products. **Do not run it as part of the ordinary release
bridge or merely to make the simulator show extra seats.**

Before any extra seat is sold, add and read back each review image; verify
signed Apple purchase, same-level crossgrades in both directions, renewal,
refund and restore on a TestFlight device; fund the exact signed-price serving
schedule and media budget; then activate the matching server catalogs. The
source-only app gate needs no later binary edit. Only an existing current paid
Team workspace can see these variants: new buyers start with the three-seat
product, because the configured seven-day introductory offers have no funded
variant trial admission. Remove those introductory offers in App Store Connect
before activation unless a funded variant trial path is implemented and tested.
A future renewal preference alone must never grant
more seats or credits. The first in-app purchase/review rules still apply to
the unapproved SKUs.

Before submitting a build that offers the extra seats, replace the stale
`docs/appstore/metadata/en-US/review_notes.txt` statement that Team 4–9 are
not offered. Truthful conditional review wording is: “An existing owner of a
currently paid three-seat Team subscription can choose four through nine seats
from Settings & plan after the exact subscription and funded service catalog
are enabled. The US monthly list prices are $249.99 for three seats and
$299.99–$549.99 for four through nine, increasing $50 per tier; each tier
adds 100 monthly AI credits. Existing preserved prices and immediate prorated
charges may differ. Apple handles same-level monthly switches immediately
with a prorated refund for unused time and a new full charge.
Reducing seats can immediately pause access for members above the new limit;
their memberships and saved work remain.” Use this only after the six products
have App Review screenshots, the three-seat $249.99 new-buyer price is live,
and the activation and device checks above pass.
