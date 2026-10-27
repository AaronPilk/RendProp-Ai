# Dormant Team seat subscriptions

The three-seat Team subscription remains `com.rendprop.app.team.monthly` at
$249.99/month. Extra capacity uses a separate auto-renewable subscription in
the same Apple group and level, with one current product per workspace:

| Seats | Product ID | US monthly price | Monthly credits |
| ---: | --- | ---: | ---: |
| 4 | `com.rendprop.app.team4.monthly` | $299.99 | 1,100 |
| 5 | `com.rendprop.app.team5.monthly` | $349.99 | 1,200 |
| 6 | `com.rendprop.app.team6.monthly` | $399.99 | 1,300 |
| 7 | `com.rendprop.app.team7.monthly` | $449.99 | 1,400 |
| 8 | `com.rendprop.app.team8.monthly` | $499.99 | 1,500 |
| 9 | `com.rendprop.app.team9.monthly` | $549.99 | 1,600 |

These exact prices and credits match
`services/supabase/migrations/20261027180000_team_paid_seat_variants.sql`.
The Apple definitions are in `asc.py` and `Rendprop.storekit`, but normal ASC
commands **exclude all six**. The app also excludes them from `RendpropProducts.all`,
and the server funding/catalog rows are inactive. StoreKit fixtures prove only
the local design, not that Apple has created or approved the products.

Read-only inspection, when Apple credentials are available:

```sh
python3 tools/asc/asc.py status --include-team-seats
python3 tools/asc/asc.py subscriptions plan --include-team-seats
```

`subscriptions plan` can stop immediately on the existing $49/$99/$249
monthly-price mismatch. Resolve those existing-subscription price schedules
first, including the decision about preserving current subscribers. Only then
review the explicit `subscriptions apply --include-team-seats` plan. That
command can create and price the six Apple subscriptions, localize them, set
USA availability and a one-week introductory offer; it also reconciles the
four base monthly products. **Do not run it as part of the ordinary release
bridge or merely to make the simulator show extra seats.**

Before any extra seat is sold, read back each Apple product ID, exact USA
price, group/level, availability, intro offer, localization and review image;
verify signed Apple purchase, upgrade, downgrade, renewal, refund and restore
on a TestFlight device; activate the matching signed-price serving schedule
and server credit catalog; then remove the six IDs from the app's dormant
allowlist in a tested build. A future renewal preference alone must never
grant more seats or credits. The first in-app purchase/review rules still
apply to any SKU Apple has not yet approved.
