# In-app purchase review screenshot — `paywall.png`

**27 October launch blocker:** The committed `paywall.png` is an obsolete
Starter/Pro capture showing $49.00/$99.00, a yearly picker, and old allowances.
It remains only as historical evidence. `tools/asc/asc.py review plan/apply`
rejects its exact fingerprint before any App Store review write, and
`asc.py status` reports it as missing launch evidence. Replace it with a fresh
capture of the Pro $29.99 / Max $49.99 / Ultra $99.99 / Team $249.99 monthly
catalog. Inspect the PNG itself: the simulator must show those prices, not a
dash, stale whole-dollar price, or "temporarily unavailable" purchase state.
The local StoreKit fixture is only test data; verify the same prices and
purchase availability against App Store Connect and on a real TestFlight device.

This is an owner-run capture/upload procedure, reviewed against repository code
on 24 September 2026. The stored PNG is an existing release asset; it has not
been recaptured or uploaded by this documentation refresh. Local StoreKit
fixtures do not establish current App Store prices or purchase success.

Every auto-renewable subscription in App Store Connect has a **Review Information →
Screenshot** field, and it is required before the product can be submitted. Apple wants an
image of the purchase UI **as a customer sees it inside the app** — the real paywall, real
product names, real prices. It is only ever seen by App Review; it is not a marketing
screenshot and must not join the nine-frame store screenshot plan in `docs/appstore/screenshots/`.

The file is **`docs/appstore/iap-review/paywall.png`**. That exact path is what
`tools/asc/asc.py` reads (`IAP_SCREENSHOT`), and the same PNG is offered to every
sold subscription. Existing approved Max, Ultra and Team subscriptions already
have review images; the current four-plan release specifically needs a fresh
image for new Pro. The six additional Team-seat products need their own
review images if they are opened for sale; a base four-plan image would not
show their selectable options. Annual products remain excluded.

```bash
python3 tools/asc/asc.py review apply --skip-product com.rendprop.app.team.annual
```

## How the PNG is produced: `bridge-cmd-paywallshot.sh`

```bash
bash "$HOME/Rendprop AI/repo/apps/ios/RendpropUITests/bridge-cmd-paywallshot.sh"
```

The bridge script operates on `~/Rendprop AI/repo` regardless of the checkout
from which it is invoked. Inspect that target before running it. It regenerates
the project, boots the same
"Store 6.9" simulator the store shots use (iPhone 17 Pro Max, 1320 × 2868, status bar frozen
at 9:41), runs **one** XCUITest — `RendpropUITests/PaywallShot` — exports its screenshots,
and copies the Monthly-tab shot into the repo as `paywall.png` **only** when it is exactly
1320 × 2868. Its last line is always `PAYWALL_PNG=<path>` or `PAYWALL_PNG=MISSING`. The
yearly and legal shots land beside it in `~/Rendprop AI/_bridge/out/paywallshot/` for a
look; nothing empty is ever copied into the repo.

Review the image before committing it. Before any owner-run upload, reconcile
`asc.py`'s launch-era version selection with the intended release; see
[the tooling caveats](../../../tools/asc/README.md#release-target-caution).

### Why this needed its own test

`apps/ios/project.yml` selects `Rendprop.storekit` for the Run action and
`RendpropStoreKit.xctestplan` selects it for the Test action. The test plan must
actually reach the launched app; merely constructing `SKTestSession` is not
proof. A product-load failure correctly renders an unavailable state, which
must never be uploaded. `StoreShots.swift` does not capture the paywall.

`PaywallShot.swift` solves it the way Apple built for automation: it creates an
`SKTestSession` from `Rendprop.storekit` (StoreKitTest framework) **before** launching the
app. The generated screenshot must prove the app saw the local products by
showing Pro $29.99 and Max $49.99 together. It is local fixture evidence only;
the real TestFlight capture below is the release image.
The `.storekit` file is a resource of the **test bundle only** (never the app), the session
has dialogs disabled and transactions cleared, and the storefront is pinned to `USA` /
`en_US`. The test never taps a purchase button. Details,
identifiers and the by-hand recipe are in `apps/ios/RendpropUITests/README.md`
(§ PaywallShot).

### The caveat you are accepting

This is **StoreKit Testing in Xcode, not the App Store.** The prices come from
`apps/ios/Rendprop.storekit` (29.99 / 49.99 / 99.99 / 249.99 for the monthly products), the "Start 7-day free trial"
eligibility is synthetic, and nothing in the PNG proves the real products load. The capture shows the actual app purchase UI populated by a local fixture;
the owner must confirm that its names, prices and offers match the intended release. It is not a substitute for checking the live products on a
device before submission, and it is not a marketing asset.

## If the run comes back `PAYWALL_PNG=MISSING`

* `p01-paywall-EMPTY.png` in the output folder means the paywall rendered its empty state:
  the StoreKit test environment did not reach the app. Read the activity notes the script
  prints the command for (`SKIP_NOTES=…`); the first one, `STOREKIT: …`, says which
  `SKTestSession` initialiser worked or why none did. The usual causes: `xcodegen generate`
  did not include the current test-bundle resource, or the app was not built
  Debug.
* A `WRONG_SIZE` line means the test ran on a simulator that is not 1320 × 2868 — the script
  creates "Store 6.9" as an iPhone 17 Pro Max (16 Pro Max fallback); install one of those
  runtimes.
* No `p01-*` at all: read `/tmp/rp-paywallshot.log` for the build or test failure.

## The alternative: capture it on a phone

If you would rather the screenshot show App Store prices, the manual path still works and
produces a file that drops into the same place:

1. Follow Apple's [sandbox account setup](https://developer.apple.com/help/app-store-connect/test-in-app-purchases/create-a-sandbox-apple-account/) for the intended device-testing flow.
2. Create the products first (`docs/handoff/launch-P1.md` §5.3 has the ids, prices and
   levels) and make sure the **Paid Applications agreement is Active** — until it is,
   products return empty on a device too.
3. Follow the device's current sandbox sign-in flow; do not sign out the owner's main Apple account merely to take a screenshot.
4. Install a Debug or TestFlight build of the version you are submitting.
5. Install the exact **1.0.5 (125) TestFlight build** and sign in to Rendprop.
   Open **Account → Settings & plan → Plan & usage → View plans**. Wait for
   StoreKit to load the four monthly cards: Pro, Max, Ultra and Team. Check
   their localized prices, select Pro, and keep its price, trial/subscribe
   action and pinned purchase disclosure visible. The action must accurately
   reflect the current funding and trial state; do not capture a purchase
   unavailable/error state as the review image.
6. Capture the phone's native screenshot (side button + volume up). Transfer
   the original PNG to the Mac and save it as
   `docs/appstore/iap-review/paywall.png` in the **release checkout**. Do not
   resize or compose it. `asc.py` accepts Apple's supported iPhone portrait
   sizes; check the actual PNG, including the product name, live price, button
   state and absence of a Yearly picker. A separate phone QA record should
   confirm the other three prices even if they are below the visible fold.
7. Repeat after the **30 October 2026** USA price schedule becomes effective;
   until then, Max/Ultra/Team can still display their old whole-dollar prices.
   Check the exact final amounts with StoreKit before using the image for
   review. The new Pro product is already scheduled at $29.99.

Apple requires a screenshot of the actual subscription purchase UI for its
review field and accepts any screenshot size supported by this iPhone app.
The image is private to App Review. [Apple's review-image rules](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-information/)
and [iPhone size list](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
are the controlling references. A screenshot is separate from a successful
Sandbox purchase and from approval of the subscription localization.

Nothing in this directory is uploaded automatically — `asc.py review apply` is the step that
attaches it, and it says so in its plan before doing anything.
