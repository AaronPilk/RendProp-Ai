# In-app purchase review screenshot — capture it on a phone

Every auto-renewable subscription in App Store Connect has a **Review Information →
Screenshot** field, and it is required before the product can be submitted. Apple wants an
image of the purchase UI **as a customer sees it inside the app**.

**It cannot be captured by `bridge-cmd-storeshots.sh`, and this is not a bug.**

## Why the simulator run cannot produce it

`apps/ios/project.yml` attaches the local StoreKit configuration to the scheme's **run**
action only:

```yaml
    run:
      config: Debug
      storeKitConfiguration: Rendprop.storekit
    test:
      config: Debug
      targets:
        - RendpropUITests
```

There is no `storeKitConfiguration` on the **test** action, so a `xcodebuild test` launch
has no StoreKit environment at all: `Product.products(for:)` returns an empty array and
`PaywallView` correctly renders **"Plans aren't available right now."** That empty state is
the app behaving properly for an empty product list — and it is exactly what must never be
uploaded, either as a marketing screenshot or as a product review screenshot.

`StoreShots.swift` therefore never opens the paywall at all.

## The capture path: a real phone, sandbox account

1. App Store Connect → **Users and Access → Sandbox Testers** → create a tester (a fresh
   email address that is not an existing Apple ID).
2. Create the six products first — `docs/handoff/launch-P1.md` §5.3 has the ids, prices, and
   levels — and make sure the **Paid Applications agreement is Active**. Until it is,
   products return empty on a device too, and you will chase this same empty state on
   hardware.
3. On the iPhone: **Settings → App Store → Sandbox Account** → sign in as the tester.
   (Do **not** sign the main Apple ID out.)
4. Install a Debug or TestFlight build of the same version you are submitting.
5. In the app: **Settings tab → Plan & usage → Upgrade plan**. Wait for the three plans to
   draw with real prices and the **"Start 7-day free trial"** button.
6. Screenshot: side button + volume up. Do it twice — once on the **Monthly** tab, once on
   **Yearly** — and use the one that shows the plan the product belongs to.
7. AirDrop the PNG to the Mac. iPhone 17 Pro Max / 16 Pro Max gives 1320 × 2868, which is
   fine; Apple does not require a specific size for this field, only that the purchase UI is
   legible.

Upload the same image to each of the six products (or one per tier, if you prefer the plan
to be highlighted in its own shot).

## If you have no device to hand

There is a simulator path, with a caveat you must accept before using it:

* Add `storeKitConfiguration: Rendprop.storekit` to the scheme's `test:` action in
  `project.yml`, re-run `xcodegen generate`, and StoreKit Test will serve the six products
  under `xcodebuild test`. The prices in `Rendprop.storekit` (49 / 490 / 99 / 990 / 249 /
  2490) match what App Store Connect is being configured with, so the paywall renders
  correctly.
* **The caveat:** that is StoreKit Test, not the App Store. The sheet is a local simulation,
  the trial eligibility is synthetic, and nothing proves the real products load. Use it to
  unblock a submission if you must; replace it with a device capture before you rely on it.
* If you take that route, do **not** fold the paywall into the marketing set as well.
  `docs/appstore/screenshots/README.md` keeps the paywall out of the eight store shots on
  purpose.

## Where the file goes

Commit the captured PNG here as `iap-review-<plan>.png` (e.g. `iap-review-pro.png`) so the
next submission does not have to rediscover the recipe. Nothing in this directory is
uploaded automatically — a human attaches it in App Store Connect.
