# One-time App Review readiness

Run `python3 -B tools/asc/one_time_iap_readiness.py --require-ready` immediately
before adding the two consumables to the draft app-version review submission.
This command is read-only. It checks exact USA-only prices, product type,
English localization, draft version, review note, and a **COMPLETE** private App
Review screenshot through Apple's current v2 product relationship.

At the 28 October 2026 live readback, the 100-credit pack is USD 39.99 and the
Luxury Property Website upgrade is USD 25.00. Both are USA-only consumables with
an English name and description. Both are `MISSING_METADATA` because neither has
an App Review screenshot. This is not a purchase-path acceptance result.

| Product | Accurate customer copy (≤45 characters) | Genuine offer screenshot |
| --- | --- | --- |
| `com.rendprop.app.credits.100` | `100 nonexpiring credits for one workspace.` | In the exact review build, sign in as an eligible workspace owner/admin. Open Account → Settings & plan → Credits. Capture the balance and `Add 100 credits · [StoreKit price]` offer. The isolated Sandbox operator authority can expose this CTA to a specifically authorized QA actor with the Production product gate still off, after its matching migration and Edge function have been deployed. A QA grant does not establish retail funding. |
| `com.rendprop.app.website.premium.property` | `Luxury design for one property. Plan hosting.` (current ASC copy; improve only with an intentional localized metadata edit) | Open a saved eligible property → Website design. Capture the real `Upgrade this property · [StoreKit price]` offer with luxury designs visible. TestFlight Sandbox can expose it when the server's Sandbox gate allows that property. |

Use a genuine iPhone screenshot from the exact review build, with the item and
StoreKit price visible, at a supported native screen size. Do not synthesize a
buy button, use a simulator fixture while the live offer is gated, or substitute
a marketing screenshot. Upload one private review screenshot to **each** parent
IAP; read back `assetDeliveryState.state=COMPLETE` and its checksum. Apple says
the image can be updated but not removed after upload, so capture the final
offer before reserving the asset. These are not the optional 1024 × 1024
promotional images.

Final review notes should include the navigable route and an eligible test
account. Once the actual gates and physical Sandbox flows are verified, these
are accurate product-specific paragraphs to replace the current short notes:

> **100 credits:** In Account → Settings & plan → Credits, a workspace owner or
> admin can buy 100 nonexpiring credits for that workspace. The app shows the
> localized StoreKit price. The server credits the workspace once after it
> verifies the signed Apple transaction. Pending purchases can be checked from
> the same screen. These credits do not change the subscription.

> **Luxury Property Website:** Open a saved eligible listing → Website design.
> The one-time consumable unlocks Signature Estate and Coastal Luxe for that
> property only; it does not include hosting, which follows the workspace plan.
> The app shows the localized StoreKit price. Server verification binds the
> signed purchase to the exact property. A Sandbox purchase is test-only and
> does not change the public hosted site.

Do not replace the notes while the corresponding offer is unavailable. Confirm
the physical Sandbox purchase, cancellation, pending/recovery, duplicate grant
prevention and refund path for each SKU before submitting. The first consumable
of this type must be included with the new app-version review submission; adding
the products to a draft does not submit the app.

Apple references: [IAP information](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-information), [first-IAP submission](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase), [current IAP screenshot read endpoint](https://developer.apple.com/documentation/appstoreconnectapi/get-v2-inapppurchases-_id_-appstorereviewscreenshot), [asset verification](https://developer.apple.com/documentation/appstoreconnectapi/uploading-assets-to-app-store-connect).
