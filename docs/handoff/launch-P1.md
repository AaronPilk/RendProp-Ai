# HANDOFF-P1 — StoreKit 2 subscriptions + paywall

Branch `launch-p1`. Three commits:

| commit | what |
|---|---|
| `bdb9d34` | product catalogue, entitlement-sync API, `Rendprop.storekit` |
| `0325ebd` | `PurchaseManager`, `PaywallView`, `PaywallHost` |
| `486c575` | app wiring — `.paywallHost()`, Settings rows, the three 402 CTAs |

Before this, the app sold nothing: the only upgrade path was a US-storefront-only
link to rendprop.com/pricing, and that page has no checkout either. Now the app
sells auto-renewable subscriptions in-app, on every storefront.

---

## 1. What was built

### New files

| file | what it is |
|---|---|
| `apps/ios/Rendprop/Purchases/Products.swift` | `RendpropPlan` (starter/pro/team), `BillingPeriod`, product ids, per-plan benefit lines, `RendpropProducts` id↔plan mapping, `PaywallLegal` (URLs + disclosures). **No prices.** |
| `apps/ios/Rendprop/Purchases/PurchasesAPI.swift` | `EntitlementSync` model, `protocol PurchasesAPI`, `extension LiveAPIClient: PurchasesAPI` (POST `/me/entitlement`), `extension MockAPIClient: PurchasesAPI`. |
| `apps/ios/Rendprop/Purchases/PurchaseManager.swift` | `@MainActor final class PurchaseManager: ObservableObject`, `.shared`. StoreKit 2 only. |
| `apps/ios/Rendprop/Purchases/PaywallView.swift` | the one paywall screen. |
| `apps/ios/Rendprop/Purchases/PaywallHost.swift` | `PaywallRouter`, `PaywallReason`, `PaywallEvents`, `.rendpropPlanChanged`, `PaywallHostModifier` / `.paywallHost()`. |
| `apps/ios/Rendprop.storekit` | Xcode StoreKit configuration for simulator testing (schema v2.0). **Not bundled — attached to the scheme.** |

### Edited files (minimal diffs)

| file | change |
|---|---|
| `RendpropApp.swift` | `.paywallHost()` added in `WindowGroup` next to `.environmentObject(model)`; the "Storefront (3.1.1/3.1.3)" comment block rewritten — it claimed the app sells nothing. |
| `Screens/SettingsView.swift` | inside "Plan & usage" only: two rows (`Upgrade plan`, `Manage subscription`) in a nested `PlanActionRows` view that also observes `.rendpropPlanChanged`. |
| `Screens/RenderStatusView.swift` | the 402 publish CTA opens the paywall; `Config.pricingURL` demoted to a secondary "See plans on the web". |
| `Screens/FlythroughDetailView.swift` | same for `AIFailureCard` (+ a defaulted `quotaFeature` property) and the photo-studio 402 alert. |

### The two rules the engine enforces

1. **`.unverified` is never trusted** — not granted, not finished, not sent.
2. **A transaction is `finish()`ed ONLY after the server accepts it.** A network
   failure leaves it unfinished, so StoreKit redelivers it through
   `Transaction.updates`; `refreshOnForeground()` retries it, and so does the
   paywall's "Try again". Nobody ends up paying for nothing.

`activePlan` is **display only**. Every real gate stays server-side
(`orgs.plan` + `plan_entitlements`).

### Server contract used (P2 owns the server side)

```
POST /me/entitlement            (owner JWT, apikey, Idempotency-Key)
{ "signed_transaction": "<JWS>", "signed_renewal_info": "<JWS, optional>" }
→ 200 { plan, source, expires_at, product_id, original_transaction_id, environment }
```

`signed_transaction` = `VerificationResult<Transaction>.jwsRepresentation`.
`signed_renewal_info` = `status.renewalInfo.jwsRepresentation` from
`product.subscription?.status`, sent when StoreKit has one (optional by contract).

The `Idempotency-Key` is derived from the payload (`k:` + sha256), so a retry of
the same signed transaction must **replay** server-side, not write a second row.

---

## 2. Checks run

* `swiftc -parse` (Swift 6.0.3, Linux) clean on every file touched:
  `Products.swift`, `PurchasesAPI.swift`, `PurchaseManager.swift`,
  `PaywallView.swift`, `PaywallHost.swift`, `RendpropApp.swift`,
  `SettingsView.swift`, `RenderStatusView.swift`, `FlythroughDetailView.swift`.
  This catches syntax only — **no Apple SDK is available in the container**, so
  nothing here has been type-checked against StoreKit or SwiftUI.
* Every StoreKit symbol used was verified against Apple's documentation for iOS
  availability. All of it is **iOS 15+**, i.e. inside the iOS 16.0 target, and no
  `@available` guard is needed:
  `Product.products(for:)`, `Product.purchase(options:)` (`@MainActor`),
  `Product.PurchaseResult`, `VerificationResult.jwsRepresentation` (both the
  `Transaction` and the `RenewalInfo` overload), `Transaction.updates`,
  `Transaction.currentEntitlements`, `Transaction.finish()`,
  `Product.SubscriptionInfo.isEligibleForIntroOffer`,
  `Product.SubscriptionInfo.status`, `Product.SubscriptionInfo.Status.{transaction,renewalInfo}`,
  `AppStore.sync()`, `AppStore.showManageSubscriptions(in:)`, `StoreKitError`.
* `Rendprop.storekit` validated as JSON; schema shape checked against real
  Xcode-written `.storekit` files (RevenueCat's `storekit2-demo-app` for v2.0 and
  `purchases-ios/Tests/StoreKitUnitTests/UnitTestsConfiguration.storekit` for the
  `introductoryOffer` object). All `internalID`s unique.
* Secret grep over the full diff and the new files: **clean** (the only "password"
  hit is a comment explaining that `AppStore.sync()` prompts for the Apple ID
  password).
* Not run, not possible here: an actual build, `xcodebuild`, a simulator purchase.

---

## 3. Exact changes needed in files I do not own

### 3.1 `apps/ios/project.yml` (integrator — REQUIRED for simulator testing)

Add a scheme so Xcode attaches the StoreKit configuration on Run. XcodeGen:

```yaml
schemes:
  Rendprop:
    build:
      targets:
        Rendprop: all
    run:
      config: Debug
      storeKitConfiguration: Rendprop.storekit
    test:
      config: Debug
    profile:
      config: Release
    analyze:
      config: Debug
    archive:
      config: Release
```

`Rendprop.storekit` sits at `apps/ios/Rendprop.storekit`, i.e. next to
`project.yml`, deliberately **outside** the `Rendprop/` sources path so it is
never copied into the `.app`. Path is relative to `project.yml`.
(P5 may also add a `RendpropUITests` target under `schemes:` — merge, don't
replace.)

### 3.2 `apps/ios/Rendprop/RendpropApp.swift`, lines 4–6 (comment only)

The `import StoreKit` header comment still says *"Rendprop ships no StoreKit
products, no purchase UI and no prices"*. It is now false. I left it alone
because I was scoped to one edit region in that file. Replace with:

```swift
// StoreKit is used for two things: `Storefront.current.countryCode` (see
// `Storefronts` at the bottom of this file) and the in-app subscriptions in
// `Purchases/` — six auto-renewable products in the `rendprop_plans` group.
// No price string is compiled into the binary; every price comes from
// `Product.displayPrice`.
import StoreKit
```

### 3.3 P3 (analytics) — wire the sink once at launch

`PaywallEvents` is a nil-by-default seam so this branch does not depend on P3's
`Analytics`. At merge, add exactly one line where `Analytics` is initialised
(app launch, main actor):

```swift
PaywallEvents.sink = { name, props in Analytics.track(name, props) }
```

Events emitted, matching `docs/LAUNCH-CONTRACT.md § Events` exactly:
`paywall_viewed` (`reason`), `purchase_started`, `purchase_completed`,
`purchase_failed` (`reason` = `storekit` | `sync` | `pending` | `unknown`),
`restore`. Product events also carry `plan`, `product_id`, `period`.
No PII, no price, ever.

SKAdNetwork: conversion value **4** on `paywall_viewed` and **5** on
`purchase_completed` (contract § SKAdNetwork). P3 owns that call — the sink
gives it the hook.

### 3.4 P2 (server) — three things the client assumes

1. `POST /me/entitlement` accepts and honours an `Idempotency-Key` header
   (replay, don't duplicate). The client sends one on every attempt, derived
   from the payload, so all retries of the same transaction share a key.
2. The response's `plan` is the **effective** plan. `"free"` (or empty) makes the
   client clear `activePlan`; anything else is shown as the live plan.
3. `expires_at` is ISO-8601 (fractional seconds optional). Every field except
   `plan` may be omitted; the client tolerates that.

### 3.5 Optional polish (any agent, later)

The three `AIFailureCard` call sites can pass a sharper `quotaFeature` so the
paywall names the allowance that ran out. Defaults to `""` (generic wording)
today:

* `FlythroughDetailView.swift:~510` (publish failure) → `quotaFeature: "renders"`
* `FlythroughDetailView.swift:~3501` (`AerialIntroSheet`) → `quotaFeature: "aerials"`
* `FlythroughDetailView.swift:~4752` (`ReelStudioView`) → `quotaFeature: "reels"`

---

## 4. How to verify (Mac, simulator)

1. `xcodegen generate` in `apps/ios` after applying §3.1.
2. Xcode → Scheme → Edit Scheme → Run → Options → **StoreKit Configuration:
   `Rendprop.storekit`**. (If §3.1 was applied this is already set; check it.)
3. Run on a simulator. Settings → Plan & usage → **Upgrade plan**.
4. Expect: three cards, prices `$49.00/month` … `$2,490.00/year`, "Most popular"
   on Pro, button reading **"Start 7-day free trial"** (the local config makes
   every account intro-eligible).
5. Buy. Xcode → Debug → StoreKit → Manage Transactions shows the transaction.
   With `Config.useLiveBackend = false` the Mock returns the plan after 0.3 s and
   the sheet reflects it; with the live backend it round-trips `/me/entitlement`.
6. Turn the Mac's network off, buy again → the paywall says the purchase went
   through but the plan hasn't switched on, and the transaction stays
   **unfinished** in Manage Transactions. Turn the network on, background and
   foreground the app → it syncs and finishes. **This is the single most
   important test in this branch.**
7. Delete the app, reinstall, tap **Restore purchases** → the plan comes back.
8. **Manage subscription** opens Apple's sheet.
9. Empty-state check: remove the StoreKit configuration from the scheme and open
   the paywall → "Plans aren't available right now" + Retry. No spinner, no crash.
10. Open the paywall from the three 402 CTAs (see risk R1 below).

---

## 5. OWNER checklist — Aaron, App Store Connect

Nothing in the app works in TestFlight or production until these are done.

### 5.1 Paid Applications Agreement (do this FIRST)
App Store Connect → Business → **Agreements, Tax, and Banking**. The Paid
Applications agreement must be **Active**, with banking and tax forms complete.
Until it is, `Product.products(for:)` returns an **empty array** in TestFlight and
production and the paywall correctly shows "Plans aren't available right now".
This is the #1 cause of "my products don't load".

### 5.2 Subscription group
App Store Connect → your app → **Subscriptions** → create a group.
* Reference Name: `rendprop_plans`
* Group display name (en-US): `Rendprop Plans`
All six products go in **this one group** so Apple manages upgrade/downgrade
proration for you.

### 5.3 The six products

Create each as an **Auto-Renewable Subscription** inside `rendprop_plans`.
Subscription Level controls upgrade vs downgrade — **1 is the highest tier**:

| Product ID | Reference Name | Duration | Price (USD) | Level |
|---|---|---|---|---|
| `com.rendprop.app.team.monthly` | Team Monthly | 1 Month | 249.00 | 1 |
| `com.rendprop.app.team.annual` | Team Yearly — **NOT SOLD AT LAUNCH — needs Apple's higher price points** | 1 Year | 2490.00 | 1 |
| `com.rendprop.app.pro.monthly` | Pro Monthly | 1 Month | 99.00 | 2 |
| `com.rendprop.app.pro.annual` | Pro Yearly | 1 Year | 990.00 | 2 |
| `com.rendprop.app.starter.monthly` | Starter Monthly | 1 Month | 49.00 | 3 |
| `com.rendprop.app.starter.annual` | Starter Yearly | 1 Year | 490.00 | 3 |

Family Sharing: **off** on all six.

> 🚫 **`com.rendprop.app.team.annual` is NOT SOLD AT LAUNCH (decided 2026-09-05)
> — it needs Apple's higher price points.** App Store Connect's yearly price
> points stop at **USD 1,000** unless Apple grants extended ones, and $2,490 is
> above that; the request is open. So build **five** products, not six: Team
> ships monthly-only. The id is still defined in `Products.swift` and still maps
> to `team`, so an existing sandbox purchase keeps its entitlement — it is
> listed in `RendpropProducts.notSoldAtLaunch`, which the app filters out of
> `RendpropProducts.all` before asking StoreKit, and the paywall's Yearly tab
> shows the Team card at its monthly price with a "Monthly only" note. **To sell
> it once Apple grants the price points: empty that set (one line), create the
> product in ASC per the row above, and put the Team Yearly line back in
> `docs/appstore/metadata/en-US/description.txt`.**

> ⚠️ **Price points.** `$990.00` is above App Store Connect's default price
> list. You may have to request **additional (extended) price points** for the
> app before you can pick it — Apple approves these but it is not instant. Do
> this early. If the exact number isn't offered, pick the nearest point; the app
> never hardcodes a price, so whatever you choose is what the paywall shows, and
> only the "2 months free" badge wording assumes 12-for-10.

### 5.4 Localizations — copy/paste (en-US)

Display Name is capped at **30 characters**, Description at **45**. These fit.

| Product | Display Name | Description |
|---|---|---|
| starter.monthly | `Starter Monthly` | `8 tours, 150 photo edits, 8 reels monthly.` |
| starter.annual | `Starter Yearly` | `8 tours, 150 photo edits, 8 reels monthly.` |
| pro.monthly | `Pro Monthly` | `25 tours, 300 photo edits, 20 reels monthly.` |
| pro.annual | `Pro Yearly` | `25 tours, 300 photo edits, 20 reels monthly.` |
| team.monthly | `Team Monthly` | `80 tours, 600 photo edits, 3 seats monthly.` |
| team.annual *(not at launch — see §5.3)* | `Team Yearly` | `80 tours, 600 photo edits, 3 seats monthly.` |

These numbers are the real `plan_entitlements` allowances. Don't inflate them —
the server enforces them and the app shows "8 of 8" against the same figures.

Group display name (shown on the App Store subscription page): `Rendprop Plans`.

### 5.5 Introductory offer — 7-day free trial

On **each of the six** products: Subscription Prices → **Introductory Offer** →
* Type: **Free**
* Duration: **1 week**
* Countries: all
* No end date

Apple grants the intro offer **once per subscription group per Apple ID**, so a
customer gets one 7-day trial across all six products. That is what the app
promises — the button only says "Start 7-day free trial" when
`isEligibleForIntroOffer` is true.

### 5.6 App Store Server Notifications V2

App Store Connect → your app → **App Information** → App Store Server
Notifications. Set **both**:

* Production Server URL:
  `https://ymgqpbnjpztwjsyvceld.supabase.co/functions/v1/apple-subscriptions/notify`
* Sandbox Server URL (same):
  `https://ymgqpbnjpztwjsyvceld.supabase.co/functions/v1/apple-subscriptions/notify`
* Version: **Version 2**

This is how renewals, cancellations, refunds and expiries reach the server
without the app being open. P2 owns the endpoint; it must be deployed with
`verify_jwt = false` (Apple sends no Supabase JWT).

### 5.7 Review-facing bits
* **Review notes**: give App Review a working demo account and say the app is a
  real-estate video tool; subscriptions unlock monthly render/AI allowances.
* **App Privacy**: purchases are handled by Apple; the app sends only Apple's
  signed transaction to our own server. No new data type is collected by the
  paywall itself.
* The paywall already carries the two links 3.1.2 requires (Apple's standard
  EULA + `https://rendprop.com/privacy`) and the auto-renew sentence. **Make sure
  `https://rendprop.com/privacy` is live before submitting** — a dead link there
  is a guaranteed rejection.
* The App Store listing must also carry the same subscription terms
  (title, length, price, link to Terms & Privacy) in the app description.

### 5.8 Sandbox testing on a device
App Store Connect → Users and Access → **Sandbox Testers** → create one. On the
device: Settings → App Store → Sandbox Account → sign in. Then run a TestFlight
or dev build. Sandbox subscriptions renew fast (1 week ≈ 3 minutes), which is the
only practical way to test renewal and expiry end to end.

---

## 6. Open risks

**R1 — a paywall opened from inside another modal.** The sheet is mounted once at
the app root (per the contract). The three CTAs I wired live in **pushed**
navigation destinations (`RenderStatusView`, `PhotoStudioView`,
`FlythroughDetailView`), where a root sheet presents correctly. But
`AIFailureCard` is shared and also renders inside `AerialIntroSheet` and
`ReelStudioView`, which are themselves presented modally — and this codebase
already documents that SwiftUI can silently drop a second presentation
(`AIConsentGate`'s comment in `RendpropApp.swift`). **Verify on device that the
paywall opens from a 402 inside the aerial sheet and the reel studio.** If it
does not, the fix is to dismiss that sheet before calling
`PaywallRouter.shared.present(reason:)`, or to present `PaywallView` locally from
those two screens.

**R2 — nothing here has been compiled.** No Apple SDK in the container. Every API
name and availability was checked against Apple's docs and every file passes
`swiftc -parse`, but the first real build may still surface a type error.
`SettingsView.swift` and `FlythroughDetailView.swift` have a history of
type-checker timeouts; the paywall is deliberately split into small view bodies
(`PlanCardBody`, `buyButton`, `restoreButton`) to keep the solver's work small,
and the Settings addition is a nested view rather than more inline conditionals.

**R3 — `PurchaseManager` builds its own API client.** `PurchaseManager.shared`
calls `Config.makeAPIClient()` in its initialiser rather than borrowing
`AppModel.api`, so it has no environment dependency. That means a second
`LiveAPIClient` (and its two `URLSession`s) exists at runtime. Harmless, but if
you prefer one client, set `PurchaseManager.shared.api = model.api as? PurchasesAPI`
at launch — the property is a settable `var` for exactly that.

**R4 — the plan row only refreshes where somebody listens.** After a successful
sync the client posts `Notification.Name.rendpropPlanChanged`. `AppModel` has no
plan/usage cache to invalidate (Settings loads `/me` into its own `@State`), so
this is the signal. **Observed today only by Settings → Plan & usage.** Any new
screen that shows the plan must observe it too.

**R5 — the 402 quota copy is generic in two places.** See §3.5. Honest, just less
specific than it could be.

**R6 — annual price points. HAPPENED (2026-09-05).** Apple has not granted
`$2,490.00`, so Team Yearly is not sold at launch (see §5.3) and the badge now
names the plans it is true for: `BillingPeriod.annualBadge` in `Products.swift`
reads "2 months free on Starter and Pro". `$990.00` still needs extended price
points. The badge is still one constant — change it there and nowhere else.

**R7 — plan numbers are duplicated.** `Products.swift` copies the allowances from
`0010_pricing_entitlements_and_spend_ceiling.sql`. If that table changes, change
`PlanAllowances` in the same commit or the paywall starts promising more than the
server gives. There is a comment saying so at the top of the file.
