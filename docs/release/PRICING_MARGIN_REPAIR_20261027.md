# Dormant launch pricing and serving budget — updated 28 October 2026

The pricing repair began as source-only on `codex/pricing-margin-repair-20261027`.
No hosted database or active retail flag has changed. The later draft App Store
Connect consumable setup is recorded below; it is not approved for sale.
The four monthly customer prices remain Pro $29.99, Max $49.00, Ultra $99.99,
and three-seat Team $249.99. Each extra Team seat is $50/month through nine
seats. The `com.rendprop.app.credits.100` consumable was created in App Store
Connect on 27 October 2026 (Apple IAP ID `6827716217`) at the exact USA price
of **$39.99** for 100 nonexpiring credits. Its product, availability, price,
and draft en-US metadata were read back; it has no review screenshot or sale
approval, and its server catalog remains inactive.
The service-only entitlement writer now checks product ID against the sold
tier, so the historical `pro.monthly` $99 SKU can grant only Ultra and the
historical `starter.monthly` $49 SKU can grant only Max.

The owner's floor is 75% of receipts **after** Apple, excluding acquisition
spend. For this model, signed USA/USD customer price is conservatively reduced
by 30% Apple commission and rounded down to whole cents. The lower of that
amount and the exact attested retail funding floor is the usable net receipt.
At most 25% of that receipt can fund **all** service: the seven recurring
reserve categories, the full 5-cent supplier face of every monthly credit,
and a separate noncredit media slice. Unused credits do not imply an invoice,
but the entire liability is reserved before the period can be activated.

| Monthly product | Apple net floor | All-serving cap | Minimum storage, delivery, compute, email, support, retention, uncertainty reserve | Credit supplier face | Noncredit media available at minimum reserve |
| --- | ---: | ---: | ---: | ---: | ---: |
| Pro, 60 credits | $20.99 | $5.24 | $1.00 | $3.00 | $1.24 |
| Max, 120 credits | $34.30 | $8.57 | $1.50 | $6.00 | $1.07 |
| Ultra, 250 credits | $69.99 | $17.49 | $2.50 | $12.50 | $2.49 |
| Team 3, 600 credits | $174.99 | $43.74 | $5.00 | $30.00 | $8.74 |
| Team 4, 700 credits | $209.99 | $52.49 | $6.00 | $35.00 | $11.49 |
| Team 5, 800 credits | $244.99 | $61.24 | $7.00 | $40.00 | $14.24 |
| Team 6, 900 credits | $279.99 | $69.99 | $8.00 | $45.00 | $16.99 |
| Team 7, 1,000 credits | $314.99 | $78.74 | $9.00 | $50.00 | $19.74 |
| Team 8, 1,100 credits | $349.99 | $87.49 | $10.00 | $55.00 | $22.49 |
| Team 9, 1,200 credits | $384.99 | $96.24 | $11.00 | $60.00 | $25.24 |

The reserve categories are minimum cents per paid month in
`credit_monthly_margin_policy`. For Pro they are 20/20/10/5/25/10/10;
Max 30/30/15/5/35/15/20; Ultra 50/50/25/10/60/25/30; Team 3
100/100/50/25/125/50/50. Each added Team seat adds
15/20/10/5/35/5/10 cents. A signed retail schedule may require a larger
reserve or lower proceeds floor; the media balance shrinks accordingly. Each
period must match the fixed owner price and a USA/USD schedule exactly.
The minimum media slice must remain at least $1 Pro/Max, $2 Ultra, $5 Team 3,
plus $1 per added seat. This is a cash ceiling for noncredit video,
assessments and other supplier work, not an additional customer credit grant.
At Max $49.00, 120 credits fit the minimum reserve by only seven cents:
$34.30 conservative net × 25% rounds down to $8.57, less $1.50 of seven-category
operating reserves and $6.00 of full credit face leaves $1.07 for noncredit
media. An exact attested Apple net floor below $34.00 or any operating reserve
above $1.57 would fail the $1.00 media floor. Keep the catalog dormant until
the actual proceeds schedule and full-use costs are verified; do not silently
reduce the 120-credit allowance.
Existing feature counters remain safety limits and do not override the money
gate. Current plan cards advertise only eligible credit edits and creation.

At $39.99, the 100-credit pack has a $27.99 conservative Apple net floor and
a $6.99 all-serving cap. Its 5-cent-per-credit supplier face is $5.00, leaving
$1.99. The proposed $1.90 operating reserve allocates 40 cents storage,
35 delivery, 20 compute, 5 email, 45 support, 25 retention, and 20 uncertainty,
leaving 9 cents unallocated. A separate, evidenced Apple net-proceeds floor
must be recorded before the dormant pack row can be activated. The full
liability plus reserve must fit 25% of the lower of that floor and the
30%-commission estimate. A plain `active=true` toggle is rejected without
that evidence. The pack grant now requires the **signed** Apple
transaction to say $39.99, USD, USA and one consumable quantity; an older
$29.99 or foreign-storefront transaction cannot fund the new grant. A delayed
Ask-to-Buy purchase retains the 100-credit quantity captured in its original
intent. Existing purchased balances remain untouched.

These amounts are conservative **allocation floors**, not measured invoices or
a realized-profit claim. A release needs dated supplier bills and measured
hosting, delivery, support, refunds and tax outcomes; capacity and retention
bounds; exact Apple proceeds evidence; and full-use media/credit stress tests.
The paid schedule must fund every reserve category at or above the policy
floor. `credit_monthly_margin_allocation` refuses an underfunded or mismatched
signed period, even if a catalog flag is later enabled. The combined policy,
monthly catalog, Team seat variants, top-up product and trial stay dormant.

No activation should be inferred from this migration. Before sale, create or
verify the exact Apple products and USA prices, Sandbox purchase and renewal,
signed Production proceeds schedule, and review image. Then explicitly enable
the correct catalog and `credit-combined-v2` policy with a future
`activated_from` boundary in a separate reviewed change. Already-started
periods do not receive retroactive monthly grants.
