# 100-credit App Store Connect product

`credit_pack_iap.py` prepares only `com.rendprop.app.credits.100`, a consumable
for 100 nonexpiring workspace credits at an **exact United States customer price
of USD 29.99**. It does not derive a price from the number of credits and never
substitutes a nearby Apple price point. Its product ID, amount, quantity, and
display name match `apps/ios/Rendprop.storekit` and the credit-wallet allowlist.
The localized description is 42 characters, within Apple's 45-character limit.

The script uses the existing private `asc.Client` credentials. Its three modes:

```sh
python3 tools/asc/credit_pack_iap.py status  # authenticated GETs only
python3 tools/asc/credit_pack_iap.py plan    # same GETs, lists needed steps
python3 tools/asc/credit_pack_iap.py apply \
  --confirm-product-id com.rendprop.app.credits.100
```

`apply` is deliberately separate from the release bridge. Do not run it until
the release owner has reviewed the plan, the current app record, and the final
price. The script can create the product, USA-only availability, a single exact
price schedule, one draft In-App Purchase version, and its en-US localization.
It reads back each successful write and may be rerun after an interrupted run.
It refuses conflicting type, availability, amount, version, or localized text;
it never edits existing product pricing or territory coverage. Apple may take
up to one hour to reflect product metadata in Sandbox.

The exact API sequence, from Apple's App Store Connect OpenAPI **4.5.1**:

| Step | Read | Write if missing |
| --- | --- | --- |
| App/product | `GET /v1/apps?filter[bundleId]=com.rendprop.app`; `GET /v1/apps/{appId}/inAppPurchasesV2?filter[productId]=...` | `POST /v2/inAppPurchases`, type `inAppPurchases`, attributes `name`, `productId`, `inAppPurchaseType=CONSUMABLE`, `reviewNote`, relationship `app` |
| Territory | `GET /v2/inAppPurchases/{id}/inAppPurchaseAvailability`; `GET /v1/inAppPurchaseAvailabilities/{id}/availableTerritories` | `POST /v1/inAppPurchaseAvailabilities`, `availableInNewTerritories=false`, `availableTerritories=[USA]` |
| Price | `GET /v2/inAppPurchases/{id}/iapPriceSchedule`; `GET /v1/inAppPurchasePriceSchedules/{id}/manualPrices`; `GET /v2/inAppPurchases/{id}/pricePoints?filter[territory]=USA` | `POST /v1/inAppPurchasePriceSchedules`, `baseTerritory=USA`, one inline `inAppPurchasePrices` reference `${...}`, `startDate=null`, exact `inAppPurchasePricePoint` ID for `customerPrice=29.99` |
| Version/metadata | `GET /v2/inAppPurchases/{id}/versions`; `GET /v1/inAppPurchaseVersions/{versionId}/localizations` | `POST /v1/inAppPurchaseVersions`, then `POST /v2/inAppPurchaseLocalizations`, related to the **version**, locale `en-US` |

The **remaining release steps are outside this tool**: provide an in-app
purchase review screenshot and confirm its Apple upload state; verify the
app's paid-app agreement, tax and banking state; test a Sandbox purchase and
server-verified grant on the exact App Store Connect product; then include the
first In-App Purchase in the **app binary submission through App Store Connect**.
Apple says the standalone review-submission API is not the path for an app's
first In-App Purchase. This command performs no screenshot upload, review
staging, app-version attachment, submission, or public release action.

Offline checks:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v tools/asc/test_credit_pack_iap.py
```

Apple primary sources:
[API 4.5.1 OpenAPI](https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip),
[Managing In-App Purchases](https://developer.apple.com/documentation/appstoreconnectapi/managing-in-app-purchases),
[Working with In-App Purchase versions](https://developer.apple.com/documentation/appstoreconnectapi/working-with-in-app-purchase-versions),
[IAP metadata field limits](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-information/).
