//
//  RendpropUITests.swift
//  The automated UI walk (docs/LAUNCH-CONTRACT.md § UI walk).
//
//  ONE test — `testWalk()` — drives a booted simulator through every main
//  screen and attaches a `keepAlways` screenshot of each. The owner reviews
//  those PNGs before ad spend, so the walk is built around one rule:
//
//      A MISSING SCREEN MUST NEVER COST US THE OTHER SCREENSHOTS.
//
//  Hence `continueAfterFailure = true`, generous waits, no XCTAssert in the
//  walk itself, and one `XCTContext.runActivity` per step whose name says what
//  happened (captured / skipped and why). A step that cannot be reached writes
//  its reason into the activity instead of failing the run.
//
//  Element lookup order is always: accessibility identifier → visible label
//  text → nothing. Never coordinates. The identifiers below do not all exist
//  yet — they are listed in HANDOFF-P5.md as paste-ready insertions for the
//  agents who own those screens — so every step also carries the real button
//  titles read out of the source, and the walk works either way.
//
//  The app is launched with `-uiTesting`, which makes `Config.makeAPIClient()`
//  return `MockAPIClient` — no network, no live backend, no real listing, no
//  real spend figure in any screenshot.
//

import XCTest

final class RendpropUITests: XCTestCase {

    // MARK: - Fixtures

    private var app: XCUIApplication!

    /// Longest wait for a screen to come up. The first launch on a cold
    /// simulator has to compile shaders and seed the sample listings.
    private let screenTimeout: TimeInterval = 15
    /// Wait for something we expect to be there already.
    private let shortTimeout: TimeInterval = 3

    /// Typed into the "name this home" field so the walk owns a real project
    /// (every AI tool is deliberately a no-op on the seeded samples).
    private let walkAddress = "1 Walk Test Street"

    override func setUpWithError() throws {
        // The whole point of the walk is the screenshots. One unreachable
        // control must not take the rest of the run with it.
        continueAfterFailure = true

        app = XCUIApplication()
        app.launchArguments += [
            // Mock API client — see Config.isUITesting.
            "-uiTesting",
            // `-key value` pairs land in UserDefaults' NSArgumentDomain, which
            // @AppStorage reads, so these skip the screens that would
            // otherwise stand in front of Home. Keys verified against source:
            //   RendpropApp.swift  @AppStorage("hasOnboarded")
            //   RootTabView        @AppStorage("space.type") / SpaceType.realEstate == "real_estate"
            //   RendpropApp.swift  @AppStorage("appearance")  / Appearance.light == "light"
            //   AIConsent          "ai.thirdPartyProcessing.consent.v1"
            "-hasOnboarded", "YES",
            "-space.type", "real_estate",
            // Deterministic screenshots regardless of the simulator's theme.
            "-appearance", "light",
            // Guideline 5.1.2(i) consent. Without it the AI screens
            // (PhotoStudioView, ReelStudioView) show a full-screen disclosure
            // overlay and dismiss themselves when it is not answered.
            "-ai.thirdPartyProcessing.consent.v1", "YES",
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - The walk

    func testWalk() {
        step01Home()
        step02AddHome()
        let inPhotoStudio = step03PhotoStudio()
        step04ReelStudioVoice(reachedPhotoStudio: inPhotoStudio)
        step05Settings()
        step06OwnerConsole()
        step07Routing()
        step08Paywall()
        step09HealthProbe()
    }

    // MARK: 01 — Home

    private func step01Home() {
        activity("01 — Home dashboard") {
            guard waitForHome(timeout: screenTimeout) else {
                note("Home never appeared within \(Int(screenTimeout))s — screenshot taken anyway.")
                shot("01-home")
                return
            }
            settle()
            shot("01-home")
        }
    }

    // MARK: 02 — Add a home

    private func step02AddHome() {
        activity("02 — Add a home") {
            guard let add = find(ids: ["home.addHome"], labels: ["Add a home"], timeout: shortTimeout) else {
                note("SKIPPED: no `home.addHome` and no button labelled \"Add a home\" on Home.")
                return
            }
            tap(add)
            // The big button pushes NewListingView (nav title "New Home");
            // the same words also title StartProjectSheet, which the feature
            // tiles raise. Either is a correct `02-add-home`.
            _ = waitForAny(ids: [],
                           labels: ["New Home", "Add a home", "Name this home first"],
                           timeout: shortTimeout + 3)
            settle()
            shot("02-add-home")
            dismissTopScreen()
            _ = waitForHome(timeout: shortTimeout + 3)
        }
    }

    // MARK: 03 — AI Photo Studio

    /// Two ways in, tried in order:
    ///   a) Home already lists a real project → open it → toolbox → AI Photo Studio.
    ///   b) Fresh install (no real projects, only samples, whose tools are
    ///      disabled by design) → tap the "Take photos" tile → the gate asks
    ///      for a name → "Save and continue" lands straight in the studio.
    /// - Returns: true when the studio is on screen at the end of the step.
    @discardableResult
    private func step03PhotoStudio() -> Bool {
        var reached = false
        activity("03 — AI Photo Studio") {
            if openFirstListing(), let studio = find(ids: ["detail.photoStudio"],
                                                     labels: ["AI Photo Studio"],
                                                     timeout: shortTimeout) {
                tap(studio)
            } else {
                // (b) — the fresh-install path.
                guard let tile = find(ids: ["home.feature.photos"],
                                      labels: ["Take photos"],
                                      timeout: shortTimeout) else {
                    note("SKIPPED: neither a listing row nor a \"Take photos\" tile on Home.")
                    return
                }
                tap(tile)
                nameFirstProjectIfAsked()
            }

            guard waitForAny(ids: [], labels: ["AI Photo Studio"], timeout: screenTimeout) else {
                note("SKIPPED: AI Photo Studio did not open.")
                shot("03-photo-studio")     // whatever is on screen — better than nothing
                return
            }
            settle()
            shot("03-photo-studio")
            reached = true
        }
        return reached
    }

    // MARK: 04 — Reel Studio, the Voice step

    /// Reel Studio's card in the photo studio is `.disabled` until the home has
    /// TWO photos, so this step first tries to add photos from the simulator's
    /// library (seed it with `xcrun simctl addmedia` — see README.md). Every
    /// stage is optional: with no photos in the library the step records why it
    /// skipped and the rest of the walk carries on.
    private func step04ReelStudioVoice(reachedPhotoStudio: Bool) {
        activity("04 — Reel Studio · Voice step") {
            guard reachedPhotoStudio else {
                note("SKIPPED: the photo studio was never reached, so its reel card is unreachable too.")
                return
            }

            var reel = find(ids: ["detail.reelStudio"], labels: ["Make a reel"], timeout: shortTimeout)
            if reel == nil || reel?.isEnabled == false {
                addTwoPhotosFromLibrary()
                reel = find(ids: ["detail.reelStudio"], labels: ["Make a reel"], timeout: shortTimeout)
            }

            guard let card = reel, card.isEnabled, card.isHittable else {
                note("SKIPPED: the \"Make a reel\" card is disabled — it needs 2 photos on this home, "
                     + "and the simulator's photo library has none. Seed it with `xcrun simctl addmedia`.")
                return
            }
            tap(card)

            guard waitForAny(ids: [], labels: ["Reel Studio", "Make a reel"], timeout: screenTimeout) else {
                note("SKIPPED: Reel Studio did not open.")
                return
            }

            // The setup screen is one scroll — 1 Photos → 2 Voice → 3 Make it.
            // "Navigating to the Voice step" means scrolling STEP 2 into view
            // and switching the picker off "Off" so its pane is visible.
            if let voice = scrollTo(ids: ["reel.step.voice"],
                                    labels: ["STEP 2 · ADD YOUR VOICE", "My voice"],
                                    swipes: 8) {
                // Tapping the segment expands the record pane; harmless if the
                // element found was the step title rather than the segment.
                if voice.isHittable && voice.elementType == .button { voice.tap() }
                if let myVoice = find(ids: [], labels: ["My voice"], timeout: 1),
                   myVoice.isHittable {
                    myVoice.tap()
                }
            } else {
                note("The Voice step never scrolled into view — capturing Reel Studio as it stands.")
            }
            settle()
            shot("04-reel-studio-voice")

            dismissTopScreen()          // Close → back to the photo studio
            settle()
            dismissTopScreen()          // back out of the studio
            _ = waitForHome(timeout: shortTimeout + 3)
        }
    }

    // MARK: 05 — Settings

    private func step05Settings() {
        activity("05 — Settings") {
            guard openSettingsTab() else {
                note("SKIPPED: no Settings tab.")
                return
            }
            // `loadUsage()` runs on appear (mock `me()`), and its result is
            // what decides whether the owner-console rows draw.
            _ = waitForAny(ids: [], labels: ["Plan & usage", "Business type"], timeout: screenTimeout)
            settle(1.5)
            shot("05-settings")
        }
    }

    // MARK: 06 — Owner console

    private func step06OwnerConsole() {
        activity("06 — Owner console") {
            guard openSettingsTab() else {
                note("SKIPPED: no Settings tab.")
                return
            }
            guard let row = scrollTo(ids: ["settings.ownerConsole"],
                                     labels: ["Spend & providers"],
                                     swipes: 8) else {
                note("SKIPPED: the owner-console row is not drawn. It needs a signed-in session "
                     + "(AuthStore) plus `isAdmin: true` from `me()` — the mock sends true, so the "
                     + "missing half is the session. See HANDOFF-P5.md § AuthStore hook.")
                return
            }
            tap(row)
            guard waitForAny(ids: [], labels: ["Owner console", "Spend"], timeout: screenTimeout) else {
                note("SKIPPED: the owner console did not open.")
                return
            }
            settle(2)
            shot("06-owner-console")
            dismissTopScreen()
        }
    }

    // MARK: 07 — Routing

    private func step07Routing() {
        activity("07 — AI routing") {
            guard openSettingsTab() else {
                note("SKIPPED: no Settings tab.")
                return
            }
            guard let row = scrollTo(ids: ["admin.tab.routing"],
                                     labels: ["AI routing", "Routing"],
                                     swipes: 8) else {
                note("SKIPPED: the \"AI routing\" row is not drawn (same gate as step 06).")
                return
            }
            tap(row)
            guard waitForAny(ids: [], labels: ["AI routing"], timeout: screenTimeout) else {
                note("SKIPPED: the routing screen did not open.")
                return
            }
            settle(2)
            shot("07-routing")
            dismissTopScreen()
        }
    }

    // MARK: 08 — Paywall (added by another agent; skipped until it lands)

    private func step08Paywall() {
        activity("08 — Paywall") {
            guard openSettingsTab() else {
                note("SKIPPED: no Settings tab.")
                return
            }
            guard let upgrade = scrollTo(ids: ["settings.upgradePlan"],
                                         labels: ["Upgrade plan"],
                                         swipes: 8, perSwipeTimeout: 0.5) else {
                note("SKIPPED: no `settings.upgradePlan` in Settings yet — the paywall is another "
                     + "agent's work and had not landed when this ran. Nothing is wrong.")
                return
            }
            tap(upgrade)
            guard waitForAny(ids: ["paywall.root"],
                             labels: ["Choose a plan", "Plans"],
                             timeout: shortTimeout + 4) else {
                note("SKIPPED: tapped \"Upgrade plan\" but no `paywall.root` appeared within "
                     + "\(Int(shortTimeout) + 4)s.")
                return
            }
            settle()
            shot("08-paywall")
            dismissTopScreen()
        }
    }

    // MARK: 09 — Provider key health probe (added by another agent)

    private func step09HealthProbe() {
        activity("09 — Health probe") {
            guard openSettingsTab() else {
                note("SKIPPED: no Settings tab.")
                return
            }
            guard let row = scrollTo(ids: ["settings.ownerConsole"],
                                     labels: ["Spend & providers"],
                                     swipes: 8) else {
                note("SKIPPED: the owner console is not reachable (see step 06).")
                return
            }
            tap(row)
            guard waitForAny(ids: [], labels: ["Owner console", "Spend"], timeout: screenTimeout) else {
                note("SKIPPED: the owner console did not open.")
                return
            }
            // The Health section lives near the bottom of the console list.
            _ = scrollTo(ids: ["admin.tab.health"], labels: ["Health"], swipes: 10)
            guard let probe = scrollTo(ids: ["admin.testAllKeys"],
                                       labels: ["Test all keys", "Test all provider keys"],
                                       swipes: 6, perSwipeTimeout: 0.5) else {
                note("SKIPPED: no `admin.testAllKeys` button in the Health section yet — the key "
                     + "probe is another agent's work and had not landed when this ran.")
                return
            }
            tap(probe)
            // The probe is a network round trip per provider; 5 s is the cap
            // the contract sets for waiting on it in the walk.
            settle(5)
            shot("09-health-probe")
            dismissTopScreen()
        }
    }

    // MARK: - Navigation helpers

    /// Home is up when its one unmissable action is on screen.
    private func waitForHome(timeout: TimeInterval) -> Bool {
        waitForAny(ids: ["home.addHome"], labels: ["Add a home", "My Homes"], timeout: timeout)
    }

    @discardableResult
    private func openSettingsTab() -> Bool {
        // Already there?
        if find(ids: [], labels: ["Plan & usage"], timeout: 0.5) != nil { return true }
        let tab = app.tabBars.buttons["Settings"]
        guard tab.waitForExistence(timeout: shortTimeout) else { return false }
        tab.tap()
        // A tab tap while a screen is pushed only pops to the tab's root, so
        // tap again when the root did not surface.
        if !waitForAny(ids: [], labels: ["Plan & usage", "Business type"], timeout: shortTimeout) {
            if tab.isHittable { tab.tap() }
            return waitForAny(ids: [], labels: ["Plan & usage", "Business type"], timeout: shortTimeout)
        }
        return true
    }

    /// Opens the first REAL project listed on Home, if there is one. Samples
    /// never appear in that list, which is what makes this safe: every tool on
    /// a sample listing is deliberately disabled.
    private func openFirstListing() -> Bool {
        guard let row = find(ids: ["home.listing.first"], labels: [], timeout: 1)
                ?? firstListingRowByAddress() else { return false }
        tap(row)
        return waitForAny(ids: ["detail.photoStudio"], labels: ["TOOLBOX", "AI Photo Studio"],
                          timeout: shortTimeout + 4)
    }

    /// Fallback for a missing `home.listing.first`: the walk's own home is the
    /// only row whose label carries the address it typed.
    private func firstListingRowByAddress() -> XCUIElement? {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", walkAddress)
        for query in [app.buttons, app.cells, app.otherElements] {
            let element = query.matching(predicate).firstMatch
            if element.exists { return element }
        }
        return nil
    }

    /// The "which home?" gate. With no real project yet it asks for a name
    /// first; typing one and confirming lands straight in the feature that was
    /// tapped. A no-op when the gate did not appear (1+ homes already exist).
    private func nameFirstProjectIfAsked() {
        guard waitForAny(ids: [], labels: ["Name this home first", "Save and continue"],
                         timeout: shortTimeout) else { return }
        let field = app.textFields.firstMatch
        if field.waitForExistence(timeout: shortTimeout) {
            field.tap()
            field.typeText(walkAddress)
        }
        if let save = find(ids: [], labels: ["Save and continue"], timeout: shortTimeout) {
            tap(save)
        }
    }

    /// Best-effort: add two images from the simulator's photo library so the
    /// reel card unlocks. PHPicker is a separate process and a fresh simulator
    /// has an empty library, so every stage here is allowed to come up empty.
    private func addTwoPhotosFromLibrary() {
        guard let add = find(ids: [], labels: ["Add photos"], timeout: shortTimeout), add.isHittable else {
            return
        }
        tap(add)
        // PHPicker's grid. `images` is what it publishes for each asset cell.
        let images = app.images
        guard images.element(boundBy: 0).waitForExistence(timeout: 6) else {
            dismissTopScreen()      // empty library — close the picker
            return
        }
        for index in 0..<2 {
            let cell = images.element(boundBy: index)
            if cell.exists && cell.isHittable { cell.tap() }
        }
        if let done = find(ids: [], labels: ["Add", "Done"], timeout: 2), done.isHittable {
            done.tap()
        } else {
            dismissTopScreen()
        }
        // Ingest writes the files and rebuilds the grid.
        settle(4)
    }

    /// Back out of whatever is on top: a sheet's cancellation button first
    /// (sheets have no nav-bar back button), then the navigation back button,
    /// then a swipe-down as the last resort.
    private func dismissTopScreen() {
        for title in ["Cancel", "Close", "Done"] {
            let button = app.buttons[title]
            if button.exists && button.isHittable { button.tap(); settle(0.6); return }
        }
        let backButtons = app.navigationBars.buttons
        if backButtons.count > 0 {
            let back = backButtons.element(boundBy: 0)
            if back.exists && back.isHittable { back.tap(); settle(0.6); return }
        }
        app.swipeDown()
        settle(0.6)
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
                // Exact first — SwiftUI often combines a control's title with
                // its promise line into one label, so BEGINSWITH is the backup.
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

    /// Swipe up until the target is on screen. Returns it when found — even if
    /// it is a label rather than a control, so a caller can still screenshot.
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
            // A control the accessibility tree can see but the hit-tester
            // cannot (mid-animation, or just off the bottom edge).
            app.swipeUp()
            settle(0.35)
            if element.isHittable { element.tap() }
        }
        settle(0.6)
    }

    // MARK: - Screenshots, activities and waiting

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func activity(_ name: String, _ body: () -> Void) {
        XCTContext.runActivity(named: name) { _ in body() }
    }

    /// A line in the result bundle explaining a skip. Named activities are the
    /// only place a non-failing note survives into the `.xcresult`.
    private func note(_ text: String) {
        XCTContext.runActivity(named: text) { _ in }
    }

    /// Let animations and async loads settle. An inverted expectation waits the
    /// full interval and passes — unlike `sleep`, it keeps the runloop alive.
    private func settle(_ seconds: TimeInterval = 1.0) {
        let idle = expectation(description: "settle")
        idle.isInverted = true
        wait(for: [idle], timeout: seconds)
    }
}
