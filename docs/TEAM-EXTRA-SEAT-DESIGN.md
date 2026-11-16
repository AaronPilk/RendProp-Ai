# Team extra seats: implemented authority, pending sale activation

The existing `com.rendprop.app.team.monthly` remains a three-seat Team subscription. On 28 October 2026, App Store Connect showed $249.00 for new buyers and a $249.99 price scheduled for 30 October; existing $249.00 subscribers are preserved. The app displays StoreKit's actual localized price. Existing renewals and restores keep their Team entitlement.

Six exact monthly auto-renewable identifiers are known to the Apple verifier and requested from StoreKit by the prepared iOS source. The paywall shows one only when a fresh service-only catalog read names that exact SKU for a current paid Team workspace. The catalog, media policy and combined credit policy remain inactive, so no extra seat is currently offered. Team ends at nine seats; ten or more is the separate brokerage product.

| Total seats | Apple product ID | Proposed US price/month | Monthly AI credits |
| ---: | --- | ---: | ---: |
| 3 | `com.rendprop.app.team.monthly` | $249.99 target (scheduled) | 600 |
| 4 | `com.rendprop.app.team4.monthly` | $299.99 | 700 |
| 5 | `com.rendprop.app.team5.monthly` | $349.99 | 800 |
| 6 | `com.rendprop.app.team6.monthly` | $399.99 | 900 |
| 7 | `com.rendprop.app.team7.monthly` | $449.99 | 1,000 |
| 8 | `com.rendprop.app.team8.monthly` | $499.99 | 1,100 |
| 9 | `com.rendprop.app.team9.monthly` | $549.99 | 1,200 |

App Store Connect returned the six exact USA prices on 28 October 2026. The server requires an active exact-SKU catalog row, an active matching credit catalog row, the **current signed paid Production Apple transaction**, and retail serving funding with a price-attested US/USD schedule matching the target amount. If any is absent, a variant cannot increase seat capacity above the three-seat Team base. Client-provided suffixes, prices, and future `autoRenewProductId` never grant capacity. Sandbox receipts cannot grant Production seats. The extra credit catalog is inactive by default.

Apple currently places all seven Team monthly products at group level 1. A switch in either direction is a same-duration crossgrade: Apple makes it effective immediately, refunds the unused part of the old subscription and charges the new full monthly price. The new verified paid term receives its full 700–1,200 credit allowance once. Remaining credits from the overlapping old term are revoked when the new verified paid term is granted; already spent credits stay spent, and previously admitted holds can settle. A lower-seat crossgrade may immediately pause members above the new seat limit. A notification replay or restore cannot mint a second allowance, and an old transaction's refund reversal cannot restore credits after a newer transaction becomes current. Top-up credits are unaffected. The $50 step is a recurring list-price difference after the base price change, not a promise about the immediate prorated charge.

Before selling these products:

1. Add a current App Review screenshot for each Team 4–9 product and submit them with the build. Each is presently `MISSING_METADATA` despite a USA price, localization and one-week introductory offer. Confirm StoreKit's real device price and the immediate crossgrade timing in Sandbox. If deferred lower-seat changes are required, change and verify Apple's group levels before sale.
2. Create a bounded `apple_serving_schedules` row for each intended US/USD price with real reserve and net-proceeds evidence; App Store Connect price points alone are not payment evidence. Fund and activate the corresponding `paid_media_budget_policy` with separate business cash.
3. Approve the monthly credit tariff and profit analysis, then activate the matching `credit_monthly_catalog`, `team_paid_seat_variants` and combined credit policy together. The prepared app dynamically presents only sale-ready products. Direct variant purchases by new customers remain closed because Apple's configured one-week offer has no variant-specific funded trial admission; start with the three-seat Team product and expand after its first paid term. Do not advertise a variant trial until that path is funded and tested.
4. The over-capacity rule is implemented in `20261027193000_team_overcapacity_access.sql`: a lower current paid seat count retains the owner and earliest accepted members (accepted timestamp, then user ID), pauses later members' Team billing and owner delegation, keeps their memberships and personal listing libraries, and refuses new invitations. Removing an earlier member resumes the next accepted person. `GET /team` exposes `seat_active` and `seats.paused` so the owner can remove a member or upgrade. The disposable Team variant fixture proves the signed five-to-three transition, and the Team readiness runner retains concurrent invitation controls. This policy alone does not activate the six products.
5. Run Production-like signed subscription tests for each SKU, midterm higher- and lower-seat crossgrades, expiry, refunds, billing retry/grace, and a TestFlight purchase/restore. Confirm the server's sale list is empty before activation and appears only for a current funded Team owner afterward.

The disposable PostgreSQL fixture `services/supabase/tests/team_paid_seat_variants.sql` checks inactive-catalog denial, exact funded-price seat entitlement, upgrade credit replacement, stale refund reversal, replay, and signed-SKU mismatch. It does not claim App Store Connect or device verification.
