# Team extra seats: implemented authority, pending sale activation

The existing `com.rendprop.app.team.monthly` remains a three-seat Team subscription. Its App Store price was last reported as $249. The server catalog target is $249.99, but the app must display StoreKit's actual localized price. Existing renewals and restores keep their Team entitlement.

Six exact monthly auto-renewable identifiers are now known to the Apple verifier and iOS restore path. They are **not requested from StoreKit or sold in the paywall** until the activation checklist below is complete. Team ends at nine seats; ten or more is the separate brokerage product.

| Total seats | Apple product ID | Proposed US price/month | Monthly AI credits |
| ---: | --- | ---: | ---: |
| 3 | `com.rendprop.app.team.monthly` | Existing ASC price; target $249.99 | 1,000 |
| 4 | `com.rendprop.app.team4.monthly` | $299.99 | 1,100 |
| 5 | `com.rendprop.app.team5.monthly` | $349.99 | 1,200 |
| 6 | `com.rendprop.app.team6.monthly` | $399.99 | 1,300 |
| 7 | `com.rendprop.app.team7.monthly` | $449.99 | 1,400 |
| 8 | `com.rendprop.app.team8.monthly` | $499.99 | 1,500 |
| 9 | `com.rendprop.app.team9.monthly` | $549.99 | 1,600 |

These price points are targets, not an assertion that App Store Connect has them. The server requires an active exact-SKU catalog row, an active matching credit catalog row, the **current signed paid Production Apple transaction**, and retail serving funding with a price-attested US/USD schedule matching the target amount. If any is absent, a variant cannot increase seat capacity above the three-seat Team base. Client-provided suffixes, prices, and future `autoRenewProductId` never grant capacity. Sandbox receipts cannot grant Production seats. The extra credit catalog is inactive by default.

Apple handles subscription billing within the existing `rendprop_plans` group. A higher-level upgrade takes effect immediately and Apple refunds the unused part of the old subscription; the new paid term receives its full 1,100–1,600 credit allowance once. Remaining credits from the overlapping old term are revoked when the new verified paid term is granted; already spent credits stay spent, and previously admitted holds can settle. A lower-level downgrade normally takes effect at the next renewal. A notification replay or restore cannot mint a second allowance, and an old transaction's refund reversal cannot restore credits after a newer transaction becomes current. Top-up credits are unaffected.

Before selling these products:

1. Create all intended auto-renewable products in the existing Apple subscription group with exact product IDs and monthly durations. Set group levels in ascending service order: Team 9 highest, then Team 8 through Team 4, then existing three-seat Team, then Ultra/Max/Pro. Check Apple's upgrade/downgrade timing in Sandbox.
2. Confirm every storefront's actual StoreKit price and Apple's proceeds. Create a bounded `apple_serving_schedules` row for each intended US/USD price with real reserve and net-proceeds evidence; the proposed prices in this file are not payment evidence.
3. Approve the monthly credit tariff and profit analysis, then activate the matching `credit_monthly_catalog` and `team_paid_seat_variants` rows together. Add only these ready SKUs to `RendpropProducts.all` and the Team paywall. Do not advertise an introductory trial for a variant until its exact Apple intro offer and funded trial admission are tested.
4. The over-capacity rule is implemented in `20261027193000_team_overcapacity_access.sql`: a lower current paid seat count retains the owner and earliest accepted members (accepted timestamp, then user ID), pauses later members' Team billing and owner delegation, keeps their memberships and personal listing libraries, and refuses new invitations. Removing an earlier member resumes the next accepted person. `GET /team` exposes `seat_active` and `seats.paused` so the owner can remove a member or upgrade. The disposable Team variant fixture proves the signed five-to-three transition, and the Team readiness runner retains concurrent invitation controls. This policy alone does not activate the six products.
5. Run Production-like signed subscription tests for each SKU, midterm upgrades, next-renewal downgrades, expiry, refunds, billing retry/grace, and a TestFlight purchase/restore. Only then remove the iOS sale gate and verify actual device pricing.

The disposable PostgreSQL fixture `services/supabase/tests/team_paid_seat_variants.sql` checks inactive-catalog denial, exact funded-price seat entitlement, upgrade credit replacement, stale refund reversal, replay, and signed-SKU mismatch. It does not claim App Store Connect or device verification.
