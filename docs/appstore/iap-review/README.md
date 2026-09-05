# In-app purchase review screenshot — `paywall.png`

Every auto-renewable subscription in App Store Connect has a **Review Information →
Screenshot** field, and it is required before the product can be submitted. Apple wants an
image of the purchase UI **as a customer sees it inside the app** — the real paywall, real
product names, real prices. It is only ever seen by App Review; it is not a marketing
screenshot and must not join the eight store shots in `docs/appstore/screenshots/`.

The file is **`docs/appstore/iap-review/paywall.png`**. That exact path is what
`tools/asc/asc.py` reads (`IAP_SCREENSHOT`), and the same PNG is attached to every sold
subscription — Team Yearly is withdrawn at launch, hence the `--skip-product`:

```bash
python3 tools/asc/asc.py review apply --skip-product com.rendprop.app.team.annual
```

## How the PNG is produced: `bridge-cmd-paywallshot.sh`

```bash
bash "$HOME/Rendprop AI/repo/apps/ios/RendpropUITests/bridge-cmd-paywallshot.sh"
```

That one command, run on the Mac build bridge, regenerates the project, boots the same
"Store 6.9" simulator the store shots use (iPhone 17 Pro Max, 1320 × 2868, status bar frozen
at 9:41), runs **one** XCUITest — `RendpropUITests/PaywallShot` — exports its screenshots,
and copies the Monthly-tab shot into the repo as `paywall.png` **only** when it is exactly
1320 × 2868. Its last line is always `PAYWALL_PNG=<path>` or `PAYWALL_PNG=MISSING`. The
yearly and legal shots land beside it in `~/Rendprop AI/_bridge/out/paywallshot/` for a
look; nothing empty is ever copied into the repo.

Then commit `paywall.png` and run the `review apply` command above.

### Why this needed its own test

`apps/ios/project.yml` attaches `Rendprop.storekit` to the scheme's **Run** action only, and
xcodegen has no `storeKitConfiguration` for the **test** action at all. So a plain
`xcodebuild test` launch has no StoreKit environment: `Product.products(for:)` returns an
empty array and `PaywallView` correctly renders **"Plans aren't available right now."** That
empty state is the app behaving properly for an empty product list — and it is exactly what
must never be uploaded. `StoreShots.swift` still never opens the paywall for that reason.

`PaywallShot.swift` solves it the way Apple built for automation: it creates an
`SKTestSession` from `Rendprop.storekit` (StoreKitTest framework) **before** launching the
app. There is a single StoreKit test environment per simulator and every `SKTestSession`
controls it, so the app under test sees the six products the moment `PurchaseManager` asks.
The `.storekit` file is a resource of the **test bundle only** (never the app), the session
has dialogs disabled and transactions cleared, and the storefront is pinned to `USA` /
`en_US` so the prices read `$49.00/month`. The test never taps a purchase button. Details,
identifiers and the by-hand recipe are in `apps/ios/RendpropUITests/README.md`
(§ PaywallShot).

### The caveat you are accepting

This is **StoreKit Testing in Xcode, not the App Store.** The prices come from
`apps/ios/Rendprop.storekit` (49 / 490 / 99 / 990 / 249, matching what App Store Connect is
being configured with — see `docs/handoff/launch-P1.md` §5.3), the "Start 7-day free trial"
eligibility is synthetic, and nothing in the PNG proves the real products load. For the review
screenshot field that is fine: Apple asks to see the purchase UI, and this is the real UI
with the real product names. It is not a substitute for checking the live products on a
device before submission, and it is not a marketing asset.

## If the run comes back `PAYWALL_PNG=MISSING`

* `p01-paywall-EMPTY.png` in the output folder means the paywall rendered its empty state:
  the StoreKit test environment did not reach the app. Read the activity notes the script
  prints the command for (`SKIP_NOTES=…`); the first one, `STOREKIT: …`, says which
  `SKTestSession` initialiser worked or why none did. The usual causes: `xcodegen generate`
  did not run (the committed `.xcodeproj` predates the resource), or the app was not built
  Debug.
* A `WRONG_SIZE` line means the test ran on a simulator that is not 1320 × 2868 — the script
  creates "Store 6.9" as an iPhone 17 Pro Max (16 Pro Max fallback); install one of those
  runtimes.
* No `p01-*` at all: read `/tmp/rp-paywallshot.log` for the build or test failure.

## The alternative: capture it on a phone

If you would rather the screenshot show App Store prices, the manual path still works and
produces a file that drops into the same place:

1. App Store Connect → **Users and Access → Sandbox Testers** → create a tester (a fresh
   email address that is not an existing Apple ID).
2. Create the products first (`docs/handoff/launch-P1.md` §5.3 has the ids, prices and
   levels) and make sure the **Paid Applications agreement is Active** — until it is,
   products return empty on a device too.
3. On the iPhone: **Settings → App Store → Sandbox Account** → sign in as the tester (do not
   sign the main Apple ID out).
4. Install a Debug or TestFlight build of the version you are submitting.
5. In the app: **Settings tab → Plan & usage → Upgrade plan**. Wait for the three plans to
   draw with prices and the **Start 7-day free trial** button.
6. Screenshot (side button + volume up), AirDrop the PNG to the Mac, and save it as
   `docs/appstore/iap-review/paywall.png`. Apple does not require a specific size for this
   field, only that the purchase UI is legible; `asc.py review apply` uploads whatever is at
   that path.

Nothing in this directory is uploaded automatically — `asc.py review apply` is the step that
attaches it, and it says so in its plan before doing anything.
