# Exact US launch prices in App Store Connect

The source catalog defines Pro **$29.99**, Max **$49.99**, Ultra **$99.99**,
and three-seat Team **$249.99** per month. The approved Max, Ultra, and Team
products currently have whole-dollar USA starting prices. The ordinary
`asc.py subscriptions plan/apply` deliberately refuses that mismatch before it
creates another product. `subscription_reprice.py` is a separate, narrow route
for the three existing monthly products only. It does not touch Pro, annual
products, Team seat variants, the credit pack, app review, or public release.

`plan` is authenticated GET-only. Choose a calendar date at least three UTC
days ahead, then inspect its read-only result:

```sh
python3 tools/asc/subscription_reprice.py plan --effective-date YYYY-MM-DD
```

`apply` requires the same date and a flag acknowledging that **existing
subscribers keep their current price**. It preflights all three products and
all exact Apple USA price points before the first write. It refuses a product
with an existing conflicting future schedule, a missing/ambiguous current
price, a price decrease, or any inexact price point. After each accepted write
it reads the future schedule back. If that read-back is ambiguous, stop and
inspect App Store Connect before retrying.

```sh
python3 tools/asc/subscription_reprice.py apply \
  --effective-date YYYY-MM-DD --confirm-preserve-existing-prices
```

Rerunning for a confirmed exact future schedule makes no write. The API request
is `POST /v1/subscriptionPrices` with `startDate`,
`preserveCurrentPrice=true`, `planType=UPFRONT`, and the exact USA
`subscriptionPricePoint`. The tool does **not** overwrite a different future
price. Apple allows one future change per storefront and plan type and says
the earliest date is generally one to two days ahead because storefront
effective times vary. A future scheduled amount is not yet the price a new
buyer sees. After the date, recheck App Store Connect and a real StoreKit
product response before treating the .99 amount as live.

The rest of the catalog has separate, explicit paths:

1. Run the read-only command below to inspect creation of the missing Pro
   $29.99 SKU while leaving the three existing prices untouched:

   ```sh
   python3 tools/asc/asc.py subscriptions plan \
     --skip-product com.rendprop.app.starter.monthly \
     --skip-product com.rendprop.app.pro.monthly \
     --skip-product com.rendprop.app.team.monthly
   ```

   Add `--include-team-seats` only if the six extra Team seat SKUs are in scope;
   they remain dormant in the app and server until separate end-to-end testing.
   `subscriptions apply` with the same skips can create these new products
   without repricing the existing three. Read back each exact USA price and
   introductory offer.
2. Run `credit_pack_iap.py status` and `plan`. Its guarded `apply` can create
   the **100-credit $29.99 consumable** with USA-only availability, a single
   exact price, and en-US metadata. It never substitutes a nearby price tier.
   Do not run its `apply` until the contribution-margin audit accepts the
   $29.99/100-credit economics. An IAP review screenshot, a verified Sandbox
   purchase/grant/refund, and inclusion with the first app submission remain
   separate requirements.
3. Wait for the existing subscriptions' future .99 prices to become effective,
   then run `asc.py subscriptions plan` without skips and verify the USA prices
   using StoreKit. Do not label a scheduled price as live. Review the current
   paywall, paid-app agreement, banking/tax, credit funding, and App Review
   assets before a submission. None of these scripts submits the app.

This procedure protects existing subscribers during the price increase. Apple
does not permit preserving a higher existing subscriber price on a price
decrease. It also avoids relying on a future date's storefront hour as an
immediate price change.

Apple's `UPFRONT` plan type is the standard subscription billed once per
subscription period, including Rendprop's one-month products. Apple's
`MONTHLY` plan type is specifically a 12-month commitment billed in monthly
installments; using it here would change the product's billing contract.
The API's future-price listing does not reveal the preservation choice of a
schedule created elsewhere. An already-scheduled exact amount/date is left
untouched but flagged for manual inspection of subscriber treatment.

Offline verification:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools/asc -v
```

Apple primary sources: [subscription pricing help](https://developer.apple.com/help/app-store-connect/manage-subscriptions/manage-pricing-for-auto-renewable-subscriptions),
[auto-renewable subscription API](https://developer.apple.com/documentation/appstoreconnectapi/managing-auto-renewable-subscriptions),
[App Store Connect OpenAPI 4.5.1](https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip).
