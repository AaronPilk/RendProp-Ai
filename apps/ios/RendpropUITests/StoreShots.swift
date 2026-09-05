//
//  StoreShots.swift
//  The App Store screenshot capture (docs/appstore/screenshots/README.md).
//
//  ONE test — `testStoreShots()` — drives a booted 6.9-inch simulator through the
//  eight screens that sell the app and attaches a `keepAlways` screenshot of
//  each, named `s01-…` … `s08-…`. `bridge-cmd-storeshots.sh` runs it, exports the
//  PNGs, and checks every one is exactly 1320 × 2868.
//
//  This is NOT the UI walk. `RendpropUITests.testWalk()` exists to prove every
//  screen still draws; this exists to produce eight marketing images. The rules
//  are therefore different in three ways:
//
//  1. `XCUIScreen.main.screenshot()`, not `app.screenshot()`. App Store Connect
//     rejects anything that is not exactly the device's pixel size, and only the
//     screen capture is guaranteed to be the full 1320 × 2868 including the
//     status bar (which the bridge script freezes at 9:41, full battery, full
//     bars — the same convention every Apple marketing shot uses).
//  2. NO AI EDIT IS EVER RUN. `-uiTesting` means `MockAPIClient`, whose
//     `aiPhotoEdit` deliberately ECHOES THE SUBMITTED IMAGE BACK. A "before and
//     after" built from that would be two identical photos presented as an AI
//     result — a misleading screenshot, and grounds for rejection under 2.3.3.
//     The studio is captured showing the one-tap edits on offer, never a result.
//  3. THE PAYWALL IS NEVER CAPTURED. Under `xcodebuild test` no StoreKit
//     configuration is attached, so `Product.products(for:)` returns an empty
//     array and the paywall correctly renders "Plans aren't available right
//     now". That empty state must never reach the App Store. The IAP review
//     screenshot is captured on a real phone instead — see
//     docs/appstore/iap-review/README.md.
//
//  Everything else matches the walk: identifier first, visible label second,
//  never coordinates; `continueAfterFailure = true`; one `XCTContext.runActivity`
//  per step; and a step that cannot be reached writes the reason into the result
//  bundle instead of failing the run. Seven good screenshots beat a red test.
//

import XCTest

final class StoreShots: XCTestCase {

    // MARK: - Fixtures

    private var app: XCUIApplication!

    /// Longest wait for a screen. A cold simulator compiles shaders and seeds
    /// the sample listings on the first launch.
    private let screenTimeout: TimeInterval = 15
    /// Wait for something that should already be there.
    private let shortTimeout: TimeInterval = 3
    /// How long the hosted demo tour gets to load in its web view before the
    /// shot is taken. It is a real network round trip to rendprop.com.
    private let webTimeout: TimeInterval = 12

    /// The address typed into the New Home form and the "name this home" gate.
    ///
    /// FAIR HOUSING: a street address and nothing else. No neighbourhood, no
    /// school, no description of who lives there or who a space would suit —
    /// none of that may appear in any Rendprop marketing surface, and a
    /// screenshot is a marketing surface.
    private let shotAddress = "24 Willow Bend Court"

    override func setUpWithError() throws {
        // Eight screenshots. One unreachable control must not cost us the
        // other seven.
        continueAfterFailure = true

        app = XCUIApplication()
        // Identical to RendpropUITests.setUpWithError() — same mock backend,
        // same skipped gates, same deterministic light appearance. Keys verified
        // against source: RendpropApp.swift @AppStorage("hasOnboarded"),
        // RootTabView @AppStorage("space.type"), @AppStorage("appearance"),
        // AIConsent "ai.thirdPartyProcessing.consent.v1".
        app.launchArguments += [
            "-uiTesting",
            "-hasOnboarded", "YES",
            "-space.type", "real_estate",
            "-appearance", "light",
            "-ai.thirdPartyProcessing.consent.v1", "YES",
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - The capture

    func testStoreShots() {
        step02SampleTour()
        step03NewHome()
        let inStudio = step04PhotoStudio()
        step05ReelStudio(reachedPhotoStudio: inStudio)
        step06AerialIntro()
        // Home is captured LAST on purpose: by now step 04 has created one real
        // home, so "My Homes" shows a listing instead of the empty-state card.
        step01HomeShowroom()
        step07PlanAndUsage()
        step08PublishedTour()
    }

    // MARK: s01 — Home, scrolled to the showroom

    /// The hero shot: "Make something" — every tool the app has, in one grid.
    ///
    /// Note for whoever reviews the PNG: the two seeded sample homes
    /// ("1247 Hillcrest Drive", "88 Marina Vista #501") are deliberately NOT in
    /// this screen's "My Homes" list — that list is `AppModel.realProjects`,
    /// which excludes samples so no tool can be pointed at a demo. The samples
    /// appear on the Homes tab and in the "See it in action" player below,
    /// which is what s02 captures.
    private func step01HomeShowroom() {
        activity("s01 — Home · showroom") {
            popToRoot()
            guard openHomeTab(), waitForHome(timeout: screenTimeout) else {
                note("Home never appeared within \(Int(screenTimeout))s — capturing whatever is on screen.")
                shot("s01-home-showroom")
                return
            }
            // The TOP of Home is the store's first image: the hero promise, the
            // home the walk created under "My Homes", and the first tool tiles.
            // (s02 already shows the grid + the player further down.)
            scrollToTop()
            settle(1.5)
            shot("s01-home-showroom")
        }
    }

    // MARK: s02 — the tour player

    /// The product in one image: the scroll-to-fly-through player.
    ///
    /// Two sources, tried in order:
    ///   a) Home → "See it in action". On real estate this is a `WKWebView` on
    ///      the HOSTED demo (`rendprop.com/f/estate-demo?embed=1`) — a real
    ///      rendered flythrough, which is what we want in a store shot. It needs
    ///      the simulator to have network and the tour-host worker to be
    ///      deployed.
    ///   b) Homes tab → a sample home → its detail screen. The bundled player
    ///      falls back to "sample video unavailable" unless `demo.mp4` was
    ///      dropped into Rendprop/Resources/player/ (it is untracked — see
    ///      apps/web/player/README.md), so this path is the weaker shot and the
    ///      activity says so.
    private func step02SampleTour() {
        activity("s02 — Sample tour player") {
            _ = openHomeTab()
            if scrollTo(ids: [], labels: ["See it in action"], swipes: 6) != nil {
                settle(webTimeout)          // let the hosted flythrough load
                scrubPlayer()
                shot("s02-sample-tour")
                return
            }
            note("No \"See it in action\" section on Home — falling back to a sample home's detail.")
            guard openFirstSampleHome() else {
                note("SKIPPED: no sample home on the Homes tab either. Nothing to capture for s02.")
                return
            }
            settle(2)
            scrubPlayer()
            shot("s02-sample-tour")
            note("s02 came from the in-app sample player. If it shows \"sample video unavailable\", "
                 + "the bundled demo.mp4 is absent (it is untracked) — prefer the hosted demo.")
            popToRoot()
        }
    }

    // MARK: s03 — the New Home flow

    /// The form, with the address filled in — an empty form photographs as a
    /// blank screen. Nothing is created here: `NewListingView` only mints the
    /// listing once a video arrives, so backing out leaves no state behind.
    private func step03NewHome() {
        activity("s03 — New Home") {
            guard openHomeTab(), waitForHome(timeout: screenTimeout) else {
                note("SKIPPED: Home tab unavailable.")
                return
            }
            scrollToTop()       // s02 left Home scrolled past the "Add a home" button
            guard let add = scrollTo(ids: ["home.addHome"], labels: ["Add a home"], swipes: 6) else {
                note("SKIPPED: no `home.addHome` and no \"Add a home\" button on Home.")
                return
            }
            tap(add)
            guard waitForAny(ids: [], labels: ["New Home", "Step 1 · The home"], timeout: screenTimeout) else {
                note("SKIPPED: the New Home screen did not open.")
                return
            }
            typeAddressIntoFirstField()
            dismissKeyboard()
            settle()
            shot("s03-new-home")
            popToRoot()
        }
    }

    // MARK: s04 — AI Photo Studio

    /// Reached the way a new user reaches it: the "Take photos" tile on Home
    /// asks for a home first, and "Save and continue" lands in the studio. That
    /// gate is also what creates the ONE real home steps 05 and 06 need — every
    /// tool is disabled on a sample listing by design.
    ///
    /// The photos come from the simulator's library, which the bridge script
    /// seeds. With an empty library the studio shows its own showcase — the six
    /// one-tap edits named on screen — which is still an honest, usable shot.
    /// - Returns: true when the studio is on screen at the end of the step.
    @discardableResult
    private func step04PhotoStudio() -> Bool {
        var reached = false
        activity("s04 — AI Photo Studio") {
            guard openHomeTab(), waitForHome(timeout: screenTimeout) else {
                note("SKIPPED: Home tab unavailable.")
                return
            }
            scrollToTop()
            // A real home already exists (a re-run on a dirty simulator)? Go
            // straight in through its toolbox.
            if openFirstRealHome(), let studio = find(ids: ["detail.photoStudio"],
                                                      labels: ["AI Photo Studio"],
                                                      timeout: shortTimeout),
               studio.isEnabled {
                tap(studio)
            } else {
                popToRoot()
                guard let tile = scrollTo(ids: ["home.feature.photos"],
                                          labels: ["Take photos"], swipes: 6) else {
                    note("SKIPPED: no \"Take photos\" tile on Home, so there is no way in.")
                    return
                }
                tap(tile)
                nameFirstProjectIfAsked()
            }

            guard waitForAny(ids: [], labels: ["AI Photo Studio"], timeout: screenTimeout) else {
                note("SKIPPED: the AI Photo Studio did not open.")
                return
            }
            reached = true
            // The studio's own showcase — "Add a photo, then tap one button" and
            // the six one-tap edits — IS the store shot. The system photo picker
            // is a separate process that cannot be driven reliably (the first
            // run captured the picker itself), and NO EDIT IS EVER RUN here.
            settle(1.5)
            shot("s04-photo-studio")
        }
        return reached
    }

    // MARK: s05 — Reel Studio

    /// The reel card inside the photo studio is `.disabled` until the home has
    /// TWO photos (`canMakeReel`), so this step is honest about skipping when
    /// the simulator's photo library was never seeded.
    private func step05ReelStudio(reachedPhotoStudio: Bool) {
        activity("s05 — Reel Studio") {
            guard reachedPhotoStudio else {
                note("SKIPPED: the photo studio was never reached, so its reel card is unreachable.")
                return
            }
            guard let card = find(ids: ["detail.reelStudio"], labels: ["Make a reel"], timeout: shortTimeout),
                  card.isEnabled else {
                note("SKIPPED: the \"Make a reel\" card is disabled — it needs 2 photos on this home "
                     + "and the simulator's photo library supplied fewer. Seed it with "
                     + "`xcrun simctl addmedia` (bridge-cmd-storeshots.sh does this).")
                return
            }
            tap(card)
            guard waitForAny(ids: [], labels: ["Reel Studio"], timeout: screenTimeout) else {
                note("SKIPPED: Reel Studio did not open.")
                return
            }
            settle(1.5)
            shot("s05-reel-studio")
            dismissTopScreen()          // Close → back to the photo studio
            settle(0.8)
        }
    }

    // MARK: s06 — Aerial intro

    /// The AI opening shot, in its form state: time of day, camera move, and the
    /// disclosure line that rides with every aerial. Presented as a sheet from
    /// the home's TOOLBOX, so it needs the real home step 04 created.
    private func step06AerialIntro() {
        activity("s06 — Aerial intro") {
            popToRoot()
            guard openHomeTab() else {
                note("SKIPPED: Home tab unavailable.")
                return
            }
            scrollToTop()
            guard openFirstRealHome() else {
                note("SKIPPED: no real home to open. The aerial tool is disabled on sample listings "
                     + "by design, so there is nothing to capture without one.")
                return
            }
            guard let tile = scrollTo(ids: [], labels: ["Aerial intro"], swipes: 6),
                  tile.isEnabled else {
                note("SKIPPED: the \"Aerial intro\" tool card is absent or disabled.")
                return
            }
            tap(tile)
            guard waitForAny(ids: [], labels: ["Aerial intro", "Golden hour", "Rise & reveal"],
                             timeout: screenTimeout) else {
                note("SKIPPED: the aerial sheet did not open.")
                return
            }
            settle(1.5)
            shot("s06-aerial-intro")
            dismissTopScreen()
            popToRoot()
        }
    }

    // MARK: s07 — Settings → Plan & usage

    /// What a subscriber gets for their money, in the app's own words.
    ///
    /// Under `-uiTesting` the mock `/me` reports no plan and no entitlement
    /// block, so the rows read as an account with nothing bought yet. That is
    /// honest and safe to publish; it is NOT the paywall, which is never
    /// captured (see the file header).
    private func step07PlanAndUsage() {
        activity("s07 — Settings · Plan & usage") {
            guard openSettingsTab() else {
                note("SKIPPED: no Settings tab.")
                return
            }
            _ = waitForAny(ids: [], labels: ["Plan & usage", "Business type"], timeout: screenTimeout)
            if scrollTo(ids: [], labels: ["Plan & usage"], swipes: 6) == nil {
                note("The \"Plan & usage\" header never scrolled into view — capturing Settings as it stands.")
            }
            settle(2)
            shot("s07-plan-usage")
        }
    }

    // MARK: s08 — the published tour

    /// What the person on the other end of the link actually sees: the whole
    /// auto-built listing page — flythrough, details, and the agent card with
    /// its contact form. Reached from Home → "Watch the sample tour", which on
    /// real estate opens the HOSTED demo listing.
    ///
    /// Falls back to the Profile tab's card, which is the same card that rides
    /// on every published tour.
    private func step08PublishedTour() {
        activity("s08 — Published tour · agent card") {
            popToRoot()
            if openHomeTab() {
                scrollToTop()
            }
            if let link = scrollTo(ids: [], labels: ["Watch the sample tour"], swipes: 8) {
                tap(link)
                if waitForAny(ids: [], labels: ["Demo listing page"], timeout: screenTimeout) {
                    settle(webTimeout)      // the hosted page is a real download
                    shot("s08-published-tour")
                    popToRoot()
                    return
                }
                note("Tapped \"Watch the sample tour\" but the hosted demo page never titled itself.")
                popToRoot()
            }
            note("Falling back to the Profile tab's card — the hosted demo needs network plus a "
                 + "deployed tour-host worker.")
            guard openProfileTab() else {
                note("SKIPPED: no Profile tab either. Nothing to capture for s08.")
                return
            }
            settle(1.5)
            shot("s08-published-tour")
        }
    }

    // MARK: - Navigation helpers

    private func waitForHome(timeout: TimeInterval) -> Bool {
        waitForAny(ids: ["home.addHome"], labels: ["Make something"], timeout: timeout)
    }

    /// CAREFUL with the confirming labels below: "Add a home" and "My Homes"
    /// appear on BOTH the Home dashboard and the Homes tab (one as a section
    /// title and a button, the other as a nav title and a button), so using
    /// either would make `openTab` report success without switching tab. Only
    /// `home.addHome` and "Make something" are unique to the dashboard.
    @discardableResult
    private func openHomeTab() -> Bool {
        openTab("Home", ids: ["home.addHome"], confirmedBy: ["Make something"])
    }

    @discardableResult
    private func openSettingsTab() -> Bool {
        openTab("Settings", ids: [], confirmedBy: ["Plan & usage", "Business type"])
    }

    @discardableResult
    private func openProfileTab() -> Bool {
        openTab("Profile", ids: [], confirmedBy: ["Set up your card", "Set up card", "Edit card"])
    }

    /// Tap a tab and wait for something only that tab shows. A tab tap while a
    /// screen is pushed pops to the tab's root rather than switching, so a
    /// second tap is tried before giving up.
    private func openTab(_ title: String, ids: [String], confirmedBy labels: [String]) -> Bool {
        if find(ids: ids, labels: labels, timeout: 0.5) != nil { return true }
        let tab = app.tabBars.buttons[title]
        guard tab.waitForExistence(timeout: shortTimeout) else { return false }
        tab.tap()
        if waitForAny(ids: ids, labels: labels, timeout: shortTimeout) { return true }
        if tab.isHittable { tab.tap() }
        return waitForAny(ids: ids, labels: labels, timeout: shortTimeout)
    }

    /// The Homes tab lists BOTH the user's homes and the seeded samples; the
    /// Home dashboard lists only real ones. This opens the first row on the
    /// Homes tab, which on a fresh simulator is a sample.
    ///
    /// The tab button is tapped directly rather than through `openTab`: every
    /// label this screen shows is also on the Home dashboard, so there is no
    /// text that could confirm the switch actually happened.
    private func openFirstSampleHome() -> Bool {
        let tab = app.tabBars.buttons["Homes"]
        guard tab.waitForExistence(timeout: shortTimeout) else { return false }
        tab.tap()
        settle(1.5)
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", "Sample")
        for query in [app.buttons, app.cells, app.otherElements] {
            let element = query.matching(predicate).firstMatch
            if element.exists {
                tap(element)
                return waitForAny(ids: [], labels: ["TOOLBOX", "SAMPLE TOUR", "This is a sample"],
                                  timeout: screenTimeout)
            }
        }
        return false
    }

    /// Opens the first of the user's OWN homes from the Home dashboard —
    /// `home.listing.first` is on every real row and samples are never in that
    /// list, so this can only ever land on a real listing.
    private func openFirstRealHome() -> Bool {
        guard let row = scrollTo(ids: ["home.listing.first"], labels: [], swipes: 4) else { return false }
        tap(row)
        return waitForAny(ids: ["detail.photoStudio"], labels: ["TOOLBOX"], timeout: shortTimeout + 4)
    }

    /// The "which home?" gate. With no real home yet it asks for a name first;
    /// typing one and confirming lands straight in the tapped feature. A no-op
    /// when the gate did not appear.
    private func nameFirstProjectIfAsked() {
        guard waitForAny(ids: [], labels: ["Name this home first", "Save and continue"],
                         timeout: shortTimeout) else { return }
        typeAddressIntoFirstField()
        if let save = find(ids: [], labels: ["Save and continue"], timeout: shortTimeout) {
            tap(save)
        }
    }

    private func typeAddressIntoFirstField() {
        let named = app.textFields["Type the home's address"]
        let field = named.exists ? named : app.textFields.firstMatch
        guard field.waitForExistence(timeout: shortTimeout) else { return }
        field.tap()
        settle(0.4)
        field.typeText(shotAddress)
    }

    private func dismissKeyboard() {
        for title in ["Done", "done", "return"] {
            let key = app.keyboards.buttons[title]
            if key.exists && key.isHittable { key.tap(); settle(0.5); return }
        }
        if app.keyboards.element.exists {
            // Tapping the navigation bar takes focus off the field without
            // navigating anywhere.
            let bar = app.navigationBars.firstMatch
            if bar.exists && bar.isHittable { bar.tap() }
        }
        settle(0.5)
    }

    /// Best effort: bring photos in from the simulator's library so the studio
    /// shows real rooms instead of its empty showcase. PHPicker is a separate
    /// process and a fresh simulator has an empty library, so every stage is
    /// allowed to come up empty.
    private func addPhotosFromLibrary(count: Int) {
        guard let add = find(ids: [], labels: ["Add photos"], timeout: shortTimeout), add.isHittable else {
            note("No \"Add photos\" button — the studio will be captured with its one-tap-edit showcase.")
            return
        }
        tap(add)
        let images = app.images
        guard images.element(boundBy: 0).waitForExistence(timeout: 8) else {
            note("The simulator's photo library is empty — capturing the studio's own showcase of "
                 + "the one-tap edits instead. Seed real interior photos to improve this shot.")
            dismissTopScreen()
            return
        }
        for index in 0..<count {
            let cell = images.element(boundBy: index)
            if cell.exists && cell.isHittable { cell.tap() }
        }
        if let done = find(ids: [], labels: ["Add", "Done"], timeout: 2), done.isHittable {
            done.tap()
        } else {
            dismissTopScreen()
        }
        settle(5)       // ingest writes the files and rebuilds the grid
    }

    /// Drag inside the tour player so the frame is mid-flight rather than the
    /// poster frame. The player scrubs on scroll, and the web view swallows the
    /// gesture; if it does not, the page scrolls instead and the shot is simply
    /// the section as it stands.
    private func scrubPlayer() {
        let web = app.webViews.firstMatch
        guard web.exists else { return }
        web.swipeUp()
        settle(0.8)
        web.swipeUp()
        settle(1.2)
    }

    /// Back out of whatever is on top: a sheet's own dismissal button first
    /// (sheets have no nav-bar back button), then the navigation back button,
    /// then a swipe down.
    private func dismissTopScreen() {
        for title in ["Close", "Cancel", "Done"] {
            let button = app.buttons[title]
            if button.exists && button.isHittable { button.tap(); settle(0.8); return }
        }
        let backButtons = app.navigationBars.buttons
        if backButtons.count > 0 {
            let back = backButtons.element(boundBy: 0)
            if back.exists && back.isHittable { back.tap(); settle(0.8); return }
        }
        app.swipeDown()
        settle(0.8)
    }

    /// Unwind any pushed screens and sheets so the next step starts from a tab
    /// root. Bounded, so a screen that refuses to dismiss cannot spin forever.
    private func popToRoot() {
        for _ in 0..<4 {
            let hasBack = app.navigationBars.buttons.count > 0
                && app.navigationBars.buttons.element(boundBy: 0).exists
            let hasSheetButton = ["Close", "Cancel", "Done"].contains {
                app.buttons[$0].exists && app.buttons[$0].isHittable
            }
            guard hasBack || hasSheetButton else { return }
            dismissTopScreen()
        }
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

    /// Scroll back to the top of the current screen.
    ///
    /// LOAD-BEARING: `scrollTo` only ever walks DOWN the page, so a step that
    /// needs something ABOVE where the previous step left off — "Add a home"
    /// and the homes list both sit above the demo player on Home — will never
    /// find it without this first.
    private func scrollToTop(_ swipes: Int = 6) {
        for _ in 0..<swipes {
            app.swipeDown()
            settle(0.25)
        }
        settle(0.5)
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
    /// `app.screenshot()`: App Store Connect wants exactly 1320 × 2868 for the
    /// 6.9-inch set, status bar included.
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
    /// the web views and image decoders make progress.
    private func settle(_ seconds: TimeInterval = 1.0) {
        let idle = expectation(description: "settle")
        idle.isInverted = true
        wait(for: [idle], timeout: seconds)
    }
}
