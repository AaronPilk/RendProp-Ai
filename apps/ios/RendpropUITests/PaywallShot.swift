//
//  PaywallShot.swift
//  The App Store Connect SUBSCRIPTION REVIEW screenshot
//  (docs/appstore/iap-review/README.md).
//
//  ONE test — `testPaywallShot()` — opens the app's real paywall on a booted
//  6.9-inch simulator with the StoreKit products actually loaded, and attaches
//  `keepAlways` screenshots of it: `p01-paywall-monthly`, `p02-paywall-yearly`
//  and `p03-paywall-legal`. `bridge-cmd-paywallshot.sh` runs it, exports the
//  PNGs, and copies p01 to `docs/appstore/iap-review/paywall.png` when it is
//  exactly 1320 × 2868. `tools/asc/asc.py review apply` attaches that file to
//  every auto-renewable subscription.
//
//  WHY THIS FILE EXISTS. `StoreShots` never captures the paywall: the scheme
//  attaches `Rendprop.storekit` to the RUN action only (project.yml), so under
//  `xcodebuild test` `Product.products(for:)` comes back empty and the paywall
//  honestly says "Plans aren't available right now". App Review needs the
//  opposite — the purchase UI with real product names and prices — so this
//  test brings the StoreKit test environment up ITSELF, before the app
//  launches:
//
//      let session = try SKTestSession(configurationFileNamed: "Rendprop")
//      session.resetToDefaultState()
//      session.disableDialogs = true
//      session.clearTransactions()
//
//  That is Apple's automation API for exactly this — "StoreKitTest works with
//  XCTest for extending unit and UI test coverage to your in-app purchases"
//  (WWDC20 session 10659). There is a single test environment per simulator
//  and every `SKTestSession` controls it, so a session created in the test
//  runner is what the app under test sees when it asks StoreKit for products.
//  The .storekit file has to be a resource of THIS bundle ("include the
//  configuration file in the test targets so that it's referenceable by
//  SKTestSession" — same session); project.yml adds it to RendpropUITests
//  only, never to the app target, so nothing reaches the .app or an archive.
//
//  Rules, same as StoreShots: `XCUIScreen.main.screenshot()` for the full
//  1320 × 2868 including the status bar; identifier first, visible label
//  second, never coordinates; one `XCTContext.runActivity` per step. A step
//  that cannot be reached writes the reason into the result bundle AND fails
//  the test, so a screenshot of Home cannot pass as paywall evidence. One rule of
//  its own: NO PURCHASE BUTTON IS EVER TAPPED. "Subscribe" / "Start 7-day free
//  trial" are photographed, never touched. The only controls this test presses
//  are Account, Account → Settings and plan → View plans, the Monthly / Yearly
//  picker, the paywall's own "Try again", and "Close".
//
//  NEVER PUBLIC. The PNG goes into App Store Connect's per-subscription
//  "Review Information → Screenshot" field, which only App Review sees. It is
//  not a marketing screenshot and must not join the eight store shots in
//  docs/appstore/screenshots/ — the prices it shows come from the LOCAL
//  StoreKit configuration, not from App Store Connect.
//

import XCTest
import StoreKitTest

final class PaywallShot: XCTestCase {

    // MARK: - Fixtures

    private var app: XCUIApplication!

    /// The StoreKit test environment. Kept alive for the whole test on
    /// purpose — it is created BEFORE `app.launch()` and released in tearDown.
    private var storeKit: SKTestSession?

    /// What happened while bringing the StoreKit test environment up. Written
    /// into the result bundle as the test's first activity.
    private var storeKitNote = ""

    /// Longest wait for a screen. A cold simulator compiles shaders on the
    /// first launch.
    private let screenTimeout: TimeInterval = 15
    /// Wait for something that should already be there.
    private let shortTimeout: TimeInterval = 3
    /// How long the paywall gets to render a real price before the run gives
    /// up and captures the empty state instead.
    private let productTimeout: TimeInterval = 20

    /// Name of the StoreKit configuration file, without its `.storekit`
    /// extension (`apps/ios/Rendprop.storekit`, a resource of this bundle).
    private let configurationName = "Rendprop"

    override func setUpWithError() throws {
        // Three screenshots. One unreachable control must not cost us the rest.
        continueAfterFailure = true

        // ORDER MATTERS: the test environment has to exist before the app
        // launches, because PurchaseManager asks StoreKit for the products in
        // its very first task (`.paywallHost()` → `PurchaseManager.start()`).
        startStoreKitTestEnvironment()

        app = XCUIApplication()
        // Identical to StoreShots / RendpropUITests — same mock backend, same
        // skipped gates, same deterministic light appearance. Keys verified
        // against source: RendpropApp.swift @AppStorage("hasOnboarded"),
        // RootTabView @AppStorage("space.type"), @AppStorage("appearance"),
        // AIConsent "ai.thirdPartyProcessing.consent.v3".
        //
        // `-uiTesting` does not touch StoreKit: PurchaseManager.loadProducts()
        // calls `Product.products(for: RendpropProducts.all)` unconditionally,
        // and Config.makeAPIClient() only swaps the REST client for the mock.
        app.launchArguments += [
            "-uiTesting",
            "-hasOnboarded", "YES",
            "-space.type", "real_estate",
            "-appearance", "light",
            "-ai.thirdPartyProcessing.consent.v3", "YES",
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
        storeKit = nil
    }

    // MARK: - The capture

    func testPaywallShot() {
        note(storeKitNote)
        let productsLoaded = step01Monthly()
        step02Yearly(productsLoaded: productsLoaded)
        step03Legal(productsLoaded: productsLoaded)
        closePaywall()
        XCTAssertTrue(productsLoaded, "No review-safe paywall was captured. See p01-paywall-EMPTY and the step notes.")
    }

    // MARK: - StoreKit test environment

    /// Bring up the local StoreKit environment from `Rendprop.storekit`.
    ///
    /// Tried in order, each recorded for the result bundle: the documented
    /// `init(configurationFileNamed:)` with the bare name, the same with the
    /// extension, then `init(contentsOf:)` on the file's URL inside this
    /// bundle. Never throws out of setUp — with no session the app still
    /// launches and the test captures the empty state as `p01-paywall-EMPTY`
    /// so the integrator can see exactly what happened.
    private func startStoreKitTestEnvironment() {
        var session: SKTestSession?
        var attempts: [String] = []

        do {
            session = try SKTestSession(configurationFileNamed: configurationName)
            attempts.append("SKTestSession(configurationFileNamed: \"\(configurationName)\") OK")
        } catch {
            attempts.append("configurationFileNamed \"\(configurationName)\" failed: \(error.localizedDescription)")
        }

        if session == nil {
            let withExtension = configurationName + ".storekit"
            do {
                session = try SKTestSession(configurationFileNamed: withExtension)
                attempts.append("SKTestSession(configurationFileNamed: \"\(withExtension)\") OK")
            } catch {
                attempts.append("configurationFileNamed \"\(withExtension)\" failed: \(error.localizedDescription)")
            }
        }

        if session == nil {
            let bundle = Bundle(for: PaywallShot.self)
            if let url = bundle.url(forResource: configurationName, withExtension: "storekit") {
                do {
                    session = try SKTestSession(contentsOf: url)
                    attempts.append("SKTestSession(contentsOf: \(url.lastPathComponent)) OK")
                } catch {
                    attempts.append("contentsOf \(url.lastPathComponent) failed: \(error.localizedDescription)")
                }
            } else {
                attempts.append("\(configurationName).storekit is NOT in the test bundle \(bundle.bundleURL.lastPathComponent) "
                                + "— project.yml must list it under RendpropUITests.sources (buildPhase: resources), "
                                + "then re-run `xcodegen generate`.")
            }
        }

        guard let session else {
            storeKitNote = "STOREKIT: no test session — the paywall will show its empty state. "
                + attempts.joined(separator: " | ")
            return
        }

        // Apple's canonical order (WWDC20 10659): reset every override to the
        // configuration file's defaults, silence the test-environment dialogs
        // so the run needs no human, and start from zero transactions so no
        // leftover purchase from an earlier run marks a card "Your plan" or
        // hides the introductory offer.
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        // Deterministic prices: the US storefront in US English gives
        // "$49.00/month" whatever the Mac's own region is set to. Both are
        // documented SKTestSession properties.
        session.storefront = "USA"
        session.locale = Locale(identifier: "en_US")

        storeKit = session
        storeKitNote = "STOREKIT: test environment up (storefront USA, en_US, dialogs off, transactions cleared). "
            + attempts.joined(separator: " | ")
    }

    // MARK: p01 — Account → Settings and plan → View plans → the paywall

    /// The deliverable. Reached the way a customer (and a reviewer) reaches
    /// it: Account tab → Settings and plan → Plan & usage → View plans
    /// (`settings.upgradePlan`, SettingsView.PlanActionRows — visible signed-out and under the mock,
    /// whose `/me` reports no plan). Waits for a real StoreKit price before
    /// capturing; if none renders, says why and captures `p01-paywall-EMPTY`.
    /// - Returns: true when a price was on screen for the shot.
    private func step01Monthly() -> Bool {
        var loaded = false
        activity("p01 — Paywall · Monthly") {
            guard openSettings() else {
                note("SKIPPED: Account → Settings and plan did not open — capturing the current screen.")
                shot("p01-paywall-EMPTY")
                return
            }
            guard let upgrade = scrollTo(ids: ["settings.upgradePlan"], labels: ["View plans", "Change plan"],
                                         swipes: 8, perSwipeTimeout: 0.5) else {
                note("SKIPPED: no `settings.upgradePlan` / View plans / Change plan row in Settings. "
                     + "The row should be visible even without a signed-in account.")
                shot("p01-paywall-EMPTY")
                return
            }
            tap(upgrade)
            guard waitForAny(ids: ["paywall.root"],
                             labels: ["Turn any phone walkthrough", "Pick a plan"],
                             timeout: screenTimeout) else {
                note("SKIPPED: tapped View plans but no `paywall.root` appeared within "
                     + "\(Int(screenTimeout))s — capturing whatever is on screen.")
                shot("p01-paywall-EMPTY")
                return
            }

            loaded = waitForProducts()
            settle(1.5)          // let the cards and the buy bar finish animating in
            if loaded {
                shot("p01-paywall-monthly")
            } else {
                note("EMPTY: no StoreKit price rendered within \(Int(productTimeout))s, so this is the "
                     + "\"Plans aren't available right now\" state, NOT the review screenshot. "
                     + "Most likely the StoreKit test environment did not reach the app: check the "
                     + "STOREKIT note above, that Rendprop.storekit is a resource of RendpropUITests, "
                     + "and that the app was built Debug. Captured anyway so you can see it.")
                shot("p01-paywall-EMPTY")
            }
        }
        return loaded
    }

    // MARK: p02 — the Yearly tab

    /// Same sheet, picker on Yearly. Since 2026-10-09 every annual product is
    /// in `RendpropProducts.notSoldAtLaunch`, the picker is hidden and this
    /// step records SKIPPED; it returns if annual plans are ever sold again.
    private func step02Yearly(productsLoaded: Bool) {
        activity("p02 — Paywall · Yearly") {
            guard productsLoaded else {
                note("SKIPPED: no products rendered, so the Yearly tab would show the same empty state.")
                return
            }
            guard let yearly = periodSegment("Yearly") else {
                note("SKIPPED: no \"Yearly\" segment in the billing-period picker.")
                return
            }
            tap(yearly)
            if waitForLabel(containing: "/year", timeout: shortTimeout + 2) == nil {
                note("Tapped Yearly but no \"/year\" price appeared within \(Int(shortTimeout) + 2)s "
                     + "— capturing the sheet as it stands.")
            }
            settle(1.2)
            shot("p02-paywall-yearly")
        }
    }

    // MARK: p03 — the legal block

    /// Scrolled to the bottom of the sheet: the auto-renew sentence, Terms of
    /// Use, Privacy Policy, with the buy bar (price disclosure + "Restore
    /// purchases") pinned underneath. Back on Monthly first so p03 pairs with
    /// the deliverable.
    private func step03Legal(productsLoaded: Bool) {
        activity("p03 — Paywall · legal block") {
            guard waitForAny(ids: ["paywall.root"], labels: ["Terms of Use", "Restore purchases"],
                             timeout: shortTimeout) else {
                note("SKIPPED: the paywall is no longer on screen.")
                return
            }
            if productsLoaded, let monthly = periodSegment("Monthly") {
                tap(monthly)
            }
            // ONLY EVER SWIPE UP HERE. A swipe down on a sheet whose content is
            // already at the top is the interactive-dismiss gesture, and it
            // would close the paywall mid-step.
            if scrollTo(ids: [], labels: ["Terms of Use"], swipes: 6) != nil {
                app.swipeUp()        // clear the pinned buy bar; at the end this just bounces
                settle(0.5)
            } else {
                note("\"Terms of Use\" never scrolled into view — capturing the paywall where it stands.")
            }
            settle(1.2)
            shot("p03-paywall-legal")
        }
    }

    // MARK: - Paywall helpers

    /// True only when every launch plan shows the exact local StoreKit price
    /// and the purchase screen does not say subscriptions are unavailable.
    ///
    /// A card whose product did not load prints a bare dash. A live App Store
    /// catalog can also leak into a CLI simulator run even after SKTestSession
    /// initializes; checking only for "/month" previously accepted the wrong
    /// $49.00/$99.00/$249.00 prices as a current fixture capture.
    /// The cards combine their children into accessibility labels.
    ///
    /// When the empty state ("Plans aren't available right now") shows up
    /// first, presses the paywall's OWN "Try again" — a plain product reload,
    /// never a purchase — up to three times inside the same budget.
    private func waitForProducts() -> Bool {
        let deadline = Date().addingTimeInterval(productTimeout)
        var retries = 0
        let expected = [
            (id: "paywall.plan.pro", price: "$29.99/month"),
            (id: "paywall.plan.max", price: "$49.00/month"),
            (id: "paywall.plan.ultra", price: "$99.99/month"),
            (id: "paywall.plan.team", price: "$249.99/month"),
        ]
        repeat {
            let labels = expected.map { item -> String in
                let card = app.descendants(matching: .any)
                    .matching(identifier: item.id).firstMatch
                return card.exists ? card.label : "missing"
            }
            let pricesMatch = zip(expected, labels).allSatisfy { item, label in
                label.contains(item.price)
            }
            let unavailable = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", "New paid subscriptions are temporarily unavailable")
            ).firstMatch.exists
            if pricesMatch && !unavailable {
                note("Fixture prices rendered: \(labels.joined(separator: "; "))")
                return true
            }
            if unavailable {
                note("REJECTED: the purchase screen says new paid subscriptions are temporarily unavailable.")
                break
            }
            if retries < 3, let retry = emptyStateRetryButton() {
                retries += 1
                note("The paywall showed \"Plans aren't available right now\" — tapping its own "
                     + "\"Try again\" (\(retries) of 3).")
                tap(retry)
                settle(2)
            }
        } while Date() < deadline
        let observed = expected.map { item -> String in
            let card = app.descendants(matching: .any)
                .matching(identifier: item.id).firstMatch
            return "\(item.id): \(card.exists ? String(card.label.prefix(100)) : "missing")"
        }
        note("REJECTED: expected local StoreKit launch prices \(expected.map { $0.price }); observed \(observed.joined(separator: "; "))")
        return false
    }

    /// The paywall's "Try again" (`SecondaryButton`, PaywallView.unavailableCard),
    /// only while the unavailable card is showing. Never any other button.
    private func emptyStateRetryButton() -> XCUIElement? {
        guard find(ids: [], labels: ["Plans aren't available right now"], timeout: 0.3) != nil else {
            return nil
        }
        let button = app.buttons["Try again"]
        return button.exists ? button : nil
    }

    /// A segment of the Monthly / Yearly picker (`Picker(...).pickerStyle(.segmented)`
    /// in PaywallView.periodPicker → a UISegmentedControl with one button per
    /// period, titled by `BillingPeriod.pickerLabel`).
    private func periodSegment(_ title: String) -> XCUIElement? {
        let segment = app.segmentedControls.buttons[title]
        if segment.waitForExistence(timeout: shortTimeout) { return segment }
        let button = app.buttons[title]
        return button.exists ? button : nil
    }

    /// First element of ANY type whose label contains `text`, polling until
    /// `timeout`. nil when nothing matched in time.
    private func waitForLabel(containing text: String, timeout: TimeInterval) -> XCUIElement? {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let element = app.descendants(matching: .any).matching(predicate).firstMatch
            if element.exists { return element }
            settle(0.25)
        } while Date() < deadline
        return nil
    }

    /// The sheet's toolbar "Close" (PaywallView, `.cancellationAction`). Best
    /// effort — the run is over either way.
    private func closePaywall() {
        let close = app.buttons["Close"]
        guard close.waitForExistence(timeout: shortTimeout), close.isHittable else { return }
        close.tap()
        settle(0.8)
    }

    // MARK: - Navigation helpers (mirroring StoreShots)

    @discardableResult
    private func openSettings() -> Bool {
        guard openTab("Account", ids: ["account.settings"], confirmedBy: ["Settings and plan"]) else { return false }
        guard let settings = find(ids: ["account.settings"], labels: ["Settings and plan"], timeout: shortTimeout) else { return false }
        tap(settings)
        return waitForAny(ids: [], labels: ["Business type", "Plan & usage"], timeout: screenTimeout)
    }

    /// Tap a tab and wait for something only that tab shows. A tab tap while a
    /// screen is pushed pops to the tab's root rather than switching, so a
    /// second tap is tried before giving up.
    private func openTab(_ title: String, ids: [String], confirmedBy labels: [String]) -> Bool {
        if find(ids: ids, labels: labels, timeout: 0.5) != nil { return true }
        let tab = app.tabBars.buttons[title]
        guard tab.waitForExistence(timeout: screenTimeout) else { return false }
        tab.tap()
        if waitForAny(ids: ids, labels: labels, timeout: shortTimeout) { return true }
        if tab.isHittable { tab.tap() }
        return waitForAny(ids: ids, labels: labels, timeout: shortTimeout)
    }

    // MARK: - Element lookup (identifier first, label second, never coordinates)

    /// First element matching any identifier, else any element whose label is
    /// (or starts with) one of `labels`. Polls until `timeout`.
    private func find(ids: [String], labels: [String], timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for identifier in ids {
                let element = app.descendants(matching: .any)
                    .matching(identifier: identifier)
                    .firstMatch
                if element.exists { return element }
            }
            for label in labels {
                // Exact first — SwiftUI often folds a control's title and its
                // promise line into one label, so BEGINSWITH is the backup.
                for predicate in [NSPredicate(format: "label ==[c] %@", label),
                                  NSPredicate(format: "label BEGINSWITH[c] %@", label)] {
                    for query in [app.buttons, app.staticTexts, app.cells,
                                  app.otherElements, app.links, app.images] {
                        let element = query.matching(predicate).firstMatch
                        if element.exists { return element }
                    }
                }
            }
            settle(0.4)
        } while Date() < deadline
        return nil
    }

    private func waitForAny(ids: [String], labels: [String], timeout: TimeInterval) -> Bool {
        find(ids: ids, labels: labels, timeout: timeout) != nil
    }

    /// Swipe up until the target is actually on screen — "exists" is not enough
    /// for a screenshot, the thing has to be in frame.
    private func scrollTo(ids: [String], labels: [String],
                          swipes: Int, perSwipeTimeout: TimeInterval = 0.8) -> XCUIElement? {
        for _ in 0...swipes {
            if let element = find(ids: ids, labels: labels, timeout: perSwipeTimeout),
               isOnScreen(element) {
                return element
            }
            app.swipeUp()
            settle(0.35)
        }
        if let element = find(ids: ids, labels: labels, timeout: perSwipeTimeout) { return element }
        return nil
    }

    private func isOnScreen(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        guard frame.width > 0, frame.height > 0 else { return false }
        let window = app.windows.element(boundBy: 0)
        guard window.exists else { return true }
        return window.frame.intersects(frame)
    }

    private func tap(_ element: XCUIElement) {
        guard element.exists else { return }
        if element.isHittable {
            element.tap()
        } else {
            // Visible to the accessibility tree but not to the hit-tester
            // (mid-animation, or just past the bottom edge).
            app.swipeUp()
            settle(0.35)
            if element.isHittable { element.tap() }
        }
        settle(0.8)
    }

    // MARK: - Screenshots, activities and waiting

    /// Full-screen, device-resolution capture. `XCUIScreen.main` rather than
    /// `app.screenshot()`: the bridge script only accepts exactly 1320 × 2868
    /// for the 6.9-inch simulator, status bar included.
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func activity(_ name: String, _ body: () -> Void) {
        XCTContext.runActivity(named: name) { _ in body() }
    }

    /// A line in the result bundle explaining a skip or a caveat. Named
    /// activities are the only place a non-failing note survives into the
    /// `.xcresult`.
    private func note(_ text: String) {
        XCTContext.runActivity(named: text) { _ in }
    }

    /// Let animations and async loads settle. An inverted expectation waits the
    /// full interval and passes — unlike `sleep`, it keeps the runloop alive so
    /// StoreKit's product load and the sheet animation make progress.
    private func settle(_ seconds: TimeInterval = 1.0) {
        let idle = expectation(description: "settle")
        idle.isInverted = true
        wait(for: [idle], timeout: seconds)
    }
}
