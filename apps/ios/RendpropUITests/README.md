# RendpropUITests — the automated UI walk

One test, `RendpropUITests.testWalk()`, drives a booted simulator through every
main screen and attaches a screenshot of each to the result bundle. It exists so
the owner can look at nine PNGs and say "yes, ship it" without opening Xcode.

| # | Attachment | Screen |
|---|---|---|
| 01 | `01-home` | Home dashboard |
| 02 | `02-add-home` | Add a home (New Home / the "name your first home" gate) |
| 03 | `03-photo-studio` | AI Photo Studio for a real home |
| 04 | `04-reel-studio-voice` | Reel Studio, scrolled to **STEP 2 · ADD YOUR VOICE** |
| 05 | `05-settings` | Settings |
| 06 | `06-owner-console` | Owner console (spend · providers · usage · health) |
| 07 | `07-routing` | Owner console → AI routing |
| 08 | `08-paywall` | Paywall sheet (via `settings.upgradePlan` in Settings) |
| 09 | `09-health-probe` | Health section after "Test all keys" (`admin.testAllKeys`) |

Every screenshot is `lifetime = .keepAlways`, so it survives a passing run.

## What the walk assumes

The app is launched with these arguments (`-key value` pairs land in
`UserDefaults`' argument domain, which `@AppStorage` reads):

```
-uiTesting                                   → Config.makeAPIClient() returns MockAPIClient
-hasOnboarded YES                            → skip the intro
-space.type real_estate                      → the Homes/real-estate identity
-appearance light                            → deterministic screenshots
-ai.thirdPartyProcessing.consent.v1 YES      → skip the Guideline 5.1.2(i) overlay
```

`-uiTesting` is the important one: the walk NEVER talks to the live backend, so
no screenshot can contain a real customer, a real share link or a real spend
figure. `MockAPIClient.me()` reports `isAdmin: true`, which is what makes the
owner console reachable offline.

Two things outside this folder decide whether steps 04–09 produce a PNG:

1. **A signed-in session.** Settings only draws the owner-console rows when
   `AuthStore.shared.isSignedIn` is true, and with `Config.enableAuth == true`
   that needs a Keychain token the simulator does not have. The one-line
   `AuthStore` hook is written out in `HANDOFF-P5.md` (§ AuthStore hook) — it is
   not applied here because this agent does not own that file.
2. **Two photos in the simulator's library.** Reel Studio's card is disabled
   until the home has two photos. The bridge script seeds them with
   `xcrun simctl addmedia`; without them step 04 skips itself with a note.

Steps skip rather than fail. `continueAfterFailure = true`, no assertion in the
walk, and each step is an `XCTContext.runActivity` whose name records what
happened — so a missing paywall never costs you the other eight screenshots.

## Run it locally

`xcodegen generate` is NOT optional. `Rendprop.xcodeproj/project.pbxproj` is
committed and lists its sources individually; it contains neither the
`RendpropUITests` target nor the new `Screens/AdminFunnelView.swift` and
`Screens/AdminProbeAPI.swift`. Skip the generate step and `xcodebuild` fails
with "scheme has no test action" or "Cannot find AdminFunnelView in scope".

```bash
cd apps/ios
xcodegen generate
xcrun simctl boot CC58F5C6-C811-4FEB-889A-EF10CE1E7A0E 2>/dev/null

xcodebuild test \
  -project Rendprop.xcodeproj \
  -scheme Rendprop \
  -destination 'platform=iOS Simulator,id=CC58F5C6-C811-4FEB-889A-EF10CE1E7A0E' \
  -only-testing:RendpropUITests \
  -resultBundlePath /tmp/walk.xcresult
```

`-resultBundlePath` must not already exist — `xcodebuild` refuses to overwrite
one. Use a timestamped name (the bridge script does).

To watch it, open the Simulator app first; the walk runs in the foreground.

## Run it on the Mac build bridge

Use `apps/ios/RendpropUITests/bridge-cmd-uiwalk.sh` — it does xcodegen → boot → seed
photos → test → export → `ls` in one block, and reports each stage's exit code
without aborting the bridge.

## Getting the PNGs out of the `.xcresult`

### Xcode 16 and later (this is the one to use on Xcode 26.4)

```bash
xcrun xcresulttool export attachments \
  --path /tmp/walk.xcresult \
  --output-path ./shots
```

That writes every attachment into `./shots` plus a `manifest.json` describing
them. The exported files are named by the tool, not by the test, so map them
back to `01-home` … `09-health-probe` with the manifest — each entry carries an
`exportedFileName` and the name the test gave it
(`suggestedHumanReadableName`). `bridge-cmd-uiwalk.sh` does that rename for
you. Useful extra flags: `--test-id <identifier>` for one test, `--only-failures`
to export only failed tests' attachments.

### Legacy flow (still works, and is the fallback in the bridge script)

Every pre-Xcode-16 `xcresulttool` verb now needs `--legacy`:

```bash
# 1. dump the object graph and find the attachment payload ids
xcrun xcresulttool get --legacy --format json --path /tmp/walk.xcresult

# 2. pull one attachment out by its payloadRef id
xcrun xcresulttool export --legacy --type file \
  --path /tmp/walk.xcresult \
  --id <payloadRef id> \
  --output-path 01-home.png
```

The graph is nested: `actions._values[].actionResult.testsRef.id` → that object's
`summaryRef.id`s → each summary's `activitySummaries[].attachments._values[]`,
where `name` is `01-home` and `payloadRef.id._value` is the id to export.
`bridge-cmd-uiwalk.sh` walks exactly that path in its fallback branch.

Without `--legacy` those two verbs fail on Xcode 16+ with a deprecation error.

### Reading the skip notes

If a PNG is missing, the reason is in the bundle as an activity name:

```bash
xcrun xcresulttool get test-results activities \
  --path /tmp/walk.xcresult --test-id 'RendpropUITests/testWalk()'
```

Look for an activity whose name starts with `SKIPPED:` — it says exactly which
control was not found.

---

# ReviewerWalk — what an App Store reviewer sees first

`ReviewerWalk.testReviewerWalk()` is a second, separate capture in the same
bundle. The UI walk above and the store shots both launch with
`-hasOnboarded YES` and `-ai.thirdPartyProcessing.consent.v1 YES`, so they land
straight on Home with every gate already answered — which is precisely the part
a reviewer never gets. This test launches like a **brand-new install** and
photographs the first-run path in the order a reviewer walks it.

| # | Attachment | Screen |
|---|---|---|
| 01 | `r01-onboarding-1` … `r01-onboarding-5` | Every page of the intro |
| 02 | `r02-first-home` | Home, the moment onboarding completes |
| 03 | `r03-homes` | The Homes tab (first-tour card + the two seeded samples) |
| 04 | `r04-sample-detail` | The first sample home's detail (SAMPLE TOUR, "This is a sample", TOOLBOX dimmed) |
| 05 | `r05-sample-player` | The tour player — Home → "Watch the sample tour" (hosted demo listing page) |
| 06 | `r06-profile` | The Profile tab / agent card |
| 07 | `r07-settings-legal` | Settings scrolled to **Legal & support** — Terms of Service + Privacy Policy |
| 08 | `r08-delete-account` | Settings **Your data**, with "Delete account" in frame (Guideline 5.1.1(v)) |
| 09 | `r09-delete-confirm` | The "Delete account?" confirmation alert |
| 10 | `r10-signin-gate` | The Sign in with Apple sheet — **expected to skip**, see below |
| 11 | `r11-ai-consent` | The Guideline 5.1.2(i) AI disclosure, first time an AI tool is opened |

**There are five onboarding screens**: four feature cards in `OnboardingView`'s
paged `TabView` ("Film with your phone", "An AI photo studio in your pocket",
"Reels and floor plans, done for you", "One link. Real leads.") followed by the
"What do you showcase?" business-type picker. Cards 1–3 carry a **Continue**
button; card 4's says **Get started** and flips to the picker; the picker's own
**Get started** sets `hasOnboarded = true`. The walk does not hard-code four —
it screenshots whatever is on screen, presses whichever button is there, and
stops once the picker has been photographed, so a fifth card added later is
captured with no edit here. The real count for each run is written into the
result bundle as an activity note.

## What it launches with — and what it deliberately does not

```
-uiTesting          → Config.makeAPIClient() returns MockAPIClient
-appearance light   → deterministic screenshots
```

That is the whole list. **No `-hasOnboarded`**, so `RendpropApp`'s
`@AppStorage("hasOnboarded")` is false and `OnboardingView` is the root. **No
consent override**, so `AIConsent` is ungranted and the disclosure really
appears at the door of the AI Photo Studio — r11 is the proof it exists. **No
`-space.type`** either: the default is `SpaceType.realEstate`, which is what the
picker pre-selects, so the walk accepts the default the way a reviewer would.

Because those flags live in **UserDefaults inside the app's container**, a
container left over from a previous run would already have them set and the run
would quietly capture the wrong app. `bridge-cmd-reviewerwalk.sh` therefore runs
`xcrun simctl uninstall <udid> com.rendprop.app` **before** the test. Running
`xcodebuild test` by hand without that uninstall gives you a walk that starts on
Home with no intro and no consent sheet.

## Safety rules this test is built around

1. **No deletion is ever confirmed.** Step r09 taps "Delete account" once to
   photograph the confirmation, then taps **Cancel** and nothing else.
   `SettingsView.deleteAccount()` calls the live server —
   `serverAccountsEnabled` is `Config.useLiveBackend && Config.enableAuth`,
   neither of which `-uiTesting` turns off — so "Delete" is genuinely
   destructive even here. The fallback path skips any button whose label
   contains Delete / Clear / Erase / Remove / Confirm / Sign out, and leaves the
   dialog standing rather than pressing one of them.
2. **No AI edit is ever run.** r11 stops at the consent sheet and taps "Not
   now". `MockAPIClient.aiPhotoEdit` echoes the submitted image back, so any
   "result" would be a misleading screenshot.
3. **No assertions.** `continueAfterFailure = true`, one
   `XCTContext.runActivity` per step, and an unreachable step writes its reason
   into the bundle instead of failing the run.

## r10 is expected to skip

`AuthStore` short-circuits on the walk flag —
`isSignedIn = Config.isUITesting ? true : …` (`Auth/AuthStore.swift`) — so for
the whole run the app believes it is signed in.
`FlythroughDetailView.needsSignIn` is false, Settings draws "Sign out" instead
of "Sign in with Apple", and nothing raises `SignInView`. Signing in for real
needs an Apple ID on the simulator, which no automated walk can supply, so
**capture the sign-in sheet by hand on a device** for the review notes. The step
still makes the attempt, so if that `-uiTesting` shortcut is ever removed the
shot starts appearing with no change to the test.

One more consequence of the same flag: r11 creates the walk's **one real home**
("24 Willow Bend Court") through the "Name this home first" gate, because every
AI tool is a deliberate no-op on the seeded samples. That is why r11 runs last —
every "fresh install" shot above is already taken by then.

## Run it on the Mac build bridge

```bash
bash "$HOME/Rendprop AI/repo/apps/ios/RendpropUITests/bridge-cmd-reviewerwalk.sh"
```

It does xcodegen → boot → **uninstall** → status bar → test → export → `ls` in
one block, on the existing 6.3-inch iPhone 17 Pro simulator
`CC58F5C6-C811-4FEB-889A-EF10CE1E7A0E`, and reports each stage's exit code
without aborting the bridge. PNGs land in
`~/Rendprop AI/_bridge/out/reviewerwalk/` as `r01-….png` … `r11-….png`.

Unlike `bridge-cmd-storeshots.sh` it seeds **no photos** (a reviewer's phone has
an empty library too, and r11 never picks one) and applies **no size gate**
(these are review-notes screenshots, not App Store Connect uploads). It does
apply the same 9:41 / full-battery / full-bars status bar, so a reviewer-walk
PNG and a store PNG sit side by side without one being dated by a random clock.

## Run it by hand

```bash
cd apps/ios
xcodegen generate
xcrun simctl boot CC58F5C6-C811-4FEB-889A-EF10CE1E7A0E 2>/dev/null
xcrun simctl uninstall CC58F5C6-C811-4FEB-889A-EF10CE1E7A0E com.rendprop.app   # NOT optional

xcodebuild test \
  -project Rendprop.xcodeproj \
  -scheme Rendprop \
  -destination 'platform=iOS Simulator,id=CC58F5C6-C811-4FEB-889A-EF10CE1E7A0E' \
  -only-testing:RendpropUITests/ReviewerWalk \
  -resultBundlePath /tmp/reviewerwalk.xcresult
```

Skip notes and the onboarding page count:

```bash
xcrun xcresulttool get test-results activities \
  --path /tmp/reviewerwalk.xcresult --test-id 'ReviewerWalk/testReviewerWalk()'
```

---

# PaywallShot — the subscription review screenshot

`PaywallShot.testPaywallShot()` is a third capture in the same bundle. It exists
for one file: `docs/appstore/iap-review/paywall.png`, the **App Store Connect
subscription review screenshot** that App Review requires on every
auto-renewable subscription (`python3 tools/asc/asc.py review apply` attaches it
to all five sold products). Apple wants the purchase UI as a customer sees it —
real product names, real prices — and it is never shown to the public.

| # | Attachment | Screen |
|---|---|---|
| 01 | `p01-paywall-monthly` | Settings → Plan & usage → **Upgrade plan** → the paywall, Monthly tab, with StoreKit prices. **The deliverable.** |
| 02 | `p02-paywall-yearly` | The same sheet on the **Yearly** tab (Team falls back to its monthly price with a "Monthly only" note — Team Yearly is not sold at launch). |
| 03 | `p03-paywall-legal` | Scrolled to the bottom: the auto-renew sentence, Terms of Use, Privacy Policy, and the pinned buy bar with **Restore purchases**. |
| — | `p01-paywall-EMPTY` | Only when no price rendered within 20 s: the "Plans aren't available right now" state, so you can see what went wrong. Never copied into the repo. |

## How it gets products under `xcodebuild test`

`StoreShots` never opens the paywall because the scheme attaches
`Rendprop.storekit` to the **Run** action only, and xcodegen has no
`storeKitConfiguration` for the test action — so under `xcodebuild test`
`Product.products(for:)` returns nothing and the paywall shows its (correct)
empty state. `PaywallShot` therefore brings the StoreKit test environment up
itself, in `setUpWithError()` **before** `app.launch()`:

```swift
let session = try SKTestSession(configurationFileNamed: "Rendprop")
session.resetToDefaultState()
session.disableDialogs = true
session.clearTransactions()
session.storefront = "USA"
session.locale = Locale(identifier: "en_US")
```

This is Apple's automation API for StoreKit Testing in Xcode ("StoreKitTest
works with XCTest for extending unit and UI test coverage to your in-app
purchases" — WWDC20 10659). There is one test environment per simulator and
every `SKTestSession` controls it, so a session created in the test runner is
what the app sees when `PurchaseManager.loadProducts()` runs at launch. Two
things in `project.yml` make it work:

1. `Rendprop.storekit` is a **resource of the RendpropUITests target only**
   (`sources: - path: Rendprop.storekit, buildPhase: resources`). StoreKitTest
   resolves the name inside the bundles loaded into the runner, so the file has
   to ride inside `RendpropUITests.xctest`. It is not in the app target and a
   test bundle is never archived, so nothing reaches the .app.
2. `FRAMEWORK_SEARCH_PATHS` on that target names
   `$(PLATFORM_DIR)/Developer/Library/Frameworks`, where `StoreKitTest.framework`
   sits next to `XCTest.framework`. Swift auto-links it on `import StoreKitTest`.

The test tries `configurationFileNamed: "Rendprop"`, then `"Rendprop.storekit"`,
then `init(contentsOf:)` on the bundle URL, and writes which one worked (or why
none did) into the result bundle as the first activity (`STOREKIT: …`). If the
paywall still shows its empty state, it presses the paywall's own **Try again**
up to three times before giving up.

## What it launches with

The same five arguments as the UI walk and the store shots — `-uiTesting`,
`-hasOnboarded YES`, `-space.type real_estate`, `-appearance light`,
`-ai.thirdPartyProcessing.consent.v1 YES`. `-uiTesting` does not touch
StoreKit: `PurchaseManager.loadProducts()` calls `Product.products(for:)`
unconditionally, and `Config.makeAPIClient()` only swaps the REST client for the
mock. It does make `AuthStore.isSignedIn` true, and the mock `/me` reports no
plan, which is exactly the state in which `SettingsView.PlanActionRows` draws
**Upgrade plan** (`RendpropProducts.isUpgradeable(planName: nil)`).

## What it relies on in the app

| Element | Where |
|---|---|
| Tab bar button **Settings** | `RootTabView`, `RendpropApp.swift` |
| `settings.upgradePlan` / label **Upgrade plan** | `SettingsView.PlanActionRows` |
| `paywall.root` / header **Turn any phone walkthrough…** / **Pick a plan. Cancel any time.** | `PaywallView` |
| A label containing **/month** (or **/year** on the Yearly tab) | `PaywallView.priceText` = `Product.displayPrice` + `BillingPeriod.priceSuffix`; a missing product prints a bare dash with no suffix, so the suffix is proof a real price rendered |
| Segmented picker buttons **Monthly** / **Yearly** | `PaywallView.periodPicker` (`BillingPeriod.pickerLabel`) |
| **Plans aren't available right now** + button **Try again** | `PaywallView.unavailableCard` |
| Link **Terms of Use**, button **Restore purchases**, button **Close** | `PaywallView.legalBlock`, `restoreButton`, toolbar |

## Safety rules

1. **No purchase button is ever tapped.** "Subscribe" / "Start 7-day free
   trial" are photographed, never touched. The only controls pressed are the
   Settings tab, "Upgrade plan", the Monthly/Yearly segments, the paywall's own
   "Try again", and "Close".
2. **No assertions.** `continueAfterFailure = true`, one activity per step, and
   an unreachable step writes its reason into the bundle instead of failing.
3. **Nothing empty reaches the repo.** The bridge script copies only
   `p01-paywall-monthly.png`, only at exactly 1320 × 2868; an `EMPTY` capture
   has a different name and cannot land in `docs/appstore/iap-review/`.

## Run it on the Mac build bridge

```bash
bash "$HOME/Rendprop AI/repo/apps/ios/RendpropUITests/bridge-cmd-paywallshot.sh"
```

Same "Store 6.9" simulator (iPhone 17 Pro Max, 1320 × 2868) and the same 9:41
status bar as `bridge-cmd-storeshots.sh`; no photos are seeded. PNGs land in
`~/Rendprop AI/_bridge/out/paywallshot/`, and the monthly shot is copied to
`~/Rendprop AI/repo/docs/appstore/iap-review/paywall.png` when it passes the
size gate. The last line is always `PAYWALL_PNG=<path>` or `PAYWALL_PNG=MISSING`.

## Run it by hand

```bash
cd apps/ios
xcodegen generate        # adds Rendprop.storekit to the test bundle's resources
xcrun simctl boot B4DAE2B9-B951-4808-AF5D-97D89D64CECC 2>/dev/null   # "Store 6.9"

xcodebuild test \
  -project Rendprop.xcodeproj \
  -scheme Rendprop \
  -destination 'platform=iOS Simulator,id=B4DAE2B9-B951-4808-AF5D-97D89D64CECC' \
  -only-testing:RendpropUITests/PaywallShot \
  -resultBundlePath /tmp/paywallshot.xcresult
```

The `STOREKIT:` note, the `Price rendered: …` proof and any skip reasons:

```bash
xcrun xcresulttool get test-results activities \
  --path /tmp/paywallshot.xcresult --test-id 'PaywallShot/testPaywallShot()'
```
