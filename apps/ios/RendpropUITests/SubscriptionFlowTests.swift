import XCTest
import StoreKit
import StoreKitTest

/// Local StoreKit transactions + the app's offline MockAPIClient only. This
/// exercises billing without a camera, App Store account, real charge or API.
@available(iOS 17.0, *)
@MainActor final class SubscriptionFlowTests: XCTestCase {
    private var app: XCUIApplication!
    private var store: SKTestSession!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let config = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Rendprop", withExtension: "storekit"))
        store = try SKTestSession(contentsOf: config)
        store.resetToDefaultState(); store.clearTransactions(); store.disableDialogs = true
        // Some simulator runtimes fail to connect to StoreKitTest without an
        // IDE debug session. Never continue into the real App Store in that case.
        guard store.disableDialogs else {
            XCTFail("StoreKitTest did not accept its local configuration. No purchase test was run.")
            throw NSError(domain: "RendpropLocalStoreKitUnavailable", code: 1)
        }
        store.storefront = "USA"; store.locale = Locale(identifier: "en_US")
        launch()
    }
    override func tearDownWithError() throws { app?.terminate(); store?.clearTransactions(); store = nil }

    private func launch() {
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-hasOnboarded", "YES", "-space.type", "real_estate", "-appearance", "light", "-ai.thirdPartyProcessing.consent.v2", "NO"]
        app.launch()
    }
    private func openPaywall() {
        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20)); settings.tap()
        let plans = app.buttons["settings.upgradePlan"]
        for _ in 0..<12 {
            if plans.exists && plans.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(plans.exists && plans.isHittable); plans.tap()
        XCTAssertTrue(app.otherElements["paywall.root"].waitForExistence(timeout: 10) || app.scrollViews["paywall.root"].exists)
    }
    private func trialButton() -> XCUIElement {
        let button = app.buttons["Start 7-day free trial"]
        XCTAssertTrue(button.waitForExistence(timeout: 25), "The local seven-day free offer must be loaded and eligible")
        return button
    }
    private func waitFor(_ predicate: @escaping () -> Bool, timeout: TimeInterval = 15) {
        let condition = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: timeout), .completed)
    }

    func testConfirmedTrialPurchaseAndRestore() throws {
        openPaywall()
        XCTAssertTrue(store.allTransactions().isEmpty, "Opening the paywall must never activate a trial")
        trialButton().tap()
        XCTAssertTrue(app.staticTexts["Your plan is active. Manage or cancel it in Settings → Plan & usage."].waitForExistence(timeout: 20), "Success appears only after the mock server accepted the verified transaction")
        XCTAssertTrue(app.buttons["Manage current subscription"].waitForExistence(timeout: 10))
        XCTAssertEqual(store.allTransactions().filter { $0.state == .purchased }.count, 1)
        app.terminate(); launch(); openPaywall()
        let restore = app.buttons["Restore purchases"]
        XCTAssertTrue(restore.waitForExistence(timeout: 10)); restore.tap()
        XCTAssertTrue(app.staticTexts["Your subscription is restored."].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Manage current subscription"].exists)
        XCTAssertEqual(store.allTransactions().filter { $0.state == .purchased }.count, 1, "Restore cannot create another purchase")
    }

    func testCancelledPurchaseDoesNotActivateTrial() async throws {
        try await store.setSimulatedError(.generic(.userCancelled), forAPI: .purchase)
        openPaywall(); trialButton().tap()
        waitFor { self.app.buttons["Start 7-day free trial"].isEnabled }
        XCTAssertFalse(app.buttons["Manage current subscription"].exists)
        XCTAssertTrue(store.allTransactions().filter { $0.state == .purchased }.isEmpty)
    }

    func testPendingApprovalDoesNotActivateUntilApproved() throws {
        store.askToBuyEnabled = true
        openPaywall(); trialButton().tap()
        XCTAssertTrue(app.staticTexts["Your request was sent for approval. Your plan turns on as soon as it's approved — you can close this."].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["Manage current subscription"].exists)
        let pending = try XCTUnwrap(store.allTransactions().first(where: \.pendingAskToBuyConfirmation))
        try store.approveAskToBuyTransaction(identifier: pending.identifier)
        XCTAssertTrue(app.buttons["Manage current subscription"].waitForExistence(timeout: 20))
        XCTAssertEqual(store.allTransactions().filter { $0.state == .purchased }.count, 1)
    }

    func testUnavailableProductsKeepRestoreAndManageVisible() async throws {
        app.terminate()
        try await store.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .loadProducts)
        launch(); openPaywall()
        XCTAssertTrue(app.staticTexts["Plans aren't available right now"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Restore purchases"].exists)
        XCTAssertTrue(app.buttons["Manage subscription"].exists)
        XCTAssertTrue(store.allTransactions().isEmpty)
    }
}

/// Navigation remains testable when the OS's StoreKitTest service is unavailable.
/// This class never taps a purchase, restore or Apple-management action.
@MainActor final class SubscriptionNavigationTests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws { app?.terminate() }
    private func launch(_ extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-hasOnboarded", "YES", "-space.type", "real_estate", "-appearance", "light", "-ai.thirdPartyProcessing.consent.v2", "NO"] + extra
        app.launch()
    }
    private func show(_ element: XCUIElement) {
        for _ in 0..<14 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testSettingsPlanAndRecoveryRoutesRemainVisible() {
        launch()
        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20)); settings.tap()
        let plans = app.buttons["settings.upgradePlan"]
        show(plans)
        XCTAssertTrue(app.buttons["settings.manageSubscription"].exists)
        XCTAssertTrue(app.buttons["settings.restorePurchases"].exists)
        screenshot("billing-settings-plan-management")
        plans.tap()
        XCTAssertTrue(app.buttons["Restore purchases"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Manage subscription"].exists)
        XCTAssertTrue(app.staticTexts["Preview workspace"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Selected: Pro · Monthly"].waitForExistence(timeout: 15))
        screenshot("billing-paywall-workspace-and-recovery")
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["settings.upgradePlan"].waitForExistence(timeout: 10))
    }
    func testPaidHomeBannerOpensPlanManagement() {
        launch(["-ui.planBanner", "paid"])
        let home = app.tabBars.buttons["Home"]
        XCTAssertTrue(home.waitForExistence(timeout: 20)); home.tap()
        let banner = app.buttons["home.planBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 15)); show(banner); banner.tap()
        XCTAssertTrue(app.buttons["Manage subscription"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Restore purchases"].exists)
    }
}
