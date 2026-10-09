//
//  RendpropUITests.swift
//  The automated UI walk (docs/LAUNCH-CONTRACT.md § UI walk).
//
//  ONE test — `testWalk()` — drives a booted simulator through every main
//  screen and attaches a `keepAlways` screenshot of each. The owner reviews
//  those PNGs before ad spend, so the walk is built around one rule:
//
//      A MISSING SCREEN FAILS THE GATE, WITHOUT LOSING LATER SCREENSHOTS.
//
//  `continueAfterFailure = true` preserves diagnostic screenshots, but every
//  required screen/control has a failing assertion. Fixture images are drawn
//  by this test; the photo library, microphone and AI generation are never used.
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
import UIKit

final class RendpropUITests: XCTestCase {

    // MARK: - Fixtures

    private var app: XCUIApplication!
    private var fixtureDirectory: URL!
    private var capturedScreens = Set<String>()

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

        // The existing app hook imports these two generated images into an
        // empty test project. Never inspect or drive the real photo library.
        fixtureDirectory = try makeSyntheticPhotos()

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
            //   AIConsent          "ai.thirdPartyProcessing.consent.v3"
            "-hasOnboarded", "YES",
            "-space.type", "real_estate",
            // Deterministic screenshots regardless of the simulator's theme.
            "-appearance", "light",
            // Guideline 5.1.2(i) consent. Without it the AI screens
            // (PhotoStudioView, ReelStudioView) show a full-screen disclosure
            // overlay and dismiss themselves when it is not answered.
            "-ai.thirdPartyProcessing.consent.v3", "YES",
            "-ui.seedPhotosDir", fixtureDirectory.path,
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - The walk

    func testRequiredAccountGate() throws {
#if targetEnvironment(simulator)
        app.terminate()
        app.launchArguments += ["-ui.requiredAccountGate"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Welcome to Rendprop"].waitForExistence(timeout: screenTimeout))
        XCTAssertTrue(app.buttons["account.signInApple"].exists)
        XCTAssertFalse(app.buttons["Not now"].exists)
        for identifier in ["account.terms", "account.privacy", "account.help"] {
            XCTAssertTrue(app.descendants(matching: .any)[identifier].exists, identifier)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "required-account-gate"; screenshot.lifetime = .keepAlways; add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "required-account-accessibility"; tree.lifetime = .keepAlways; add(tree)
#else
        throw XCTSkip("Closed account-screen fixtures exist only on the simulator.")
#endif
    }

    /// Closed Home-only render: no listing creation, capture or paid action.
    /// The same test can run at the simulator's default and accessibility sizes.
    func testHomeShowroomCards() throws {
#if targetEnvironment(simulator)
        XCTAssertTrue(waitForHome(timeout: screenTimeout))
        let activeIDs = ["tour", "photos", "photoStudio", "reel", "aerial"]
            .map { "home.feature.\($0)" }
        var identifiers = activeIDs
        let spatial = app.buttons["home.feature.spatial"]
        let spatialAvailable = spatial.exists
        if spatialAvailable { identifiers.append("home.feature.spatial") }
        let activeCount = identifiers.count
        identifiers += ["home.comingSoon.floorPlan", "home.comingSoon.3dFloorPlan"]
        if !spatialAvailable { identifiers.append("home.comingSoon.spatial") }
        let cards = identifiers.map { app.descendants(matching: .any).matching(identifier: $0).firstMatch }
        for card in cards { XCTAssertTrue(card.exists, card.identifier) }
        func revealCard(_ card: XCUIElement) {
            let top = app.navigationBars.firstMatch.frame.maxY
            let bottom = app.tabBars.firstMatch.frame.minY
            // At large text a full swipe can pass a card. Choose direction
            // from its current geometry instead of continuing toward the end.
            for _ in 0..<16 {
                let frame = card.frame
                if card.isHittable && frame.minY >= top && frame.maxY <= bottom { return }
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
                let toward = frame.minY < top ? 0.72 : 0.38
                start.press(forDuration: 0.05, thenDragTo:
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: toward)))
            }
        }
        revealCard(cards[0])

        let frames = cards.map(\.frame)
        let first = frames[0]
        XCTAssertGreaterThan(first.height, 0)
        XCTAssertGreaterThan(first.width, 0)
        for (index, frame) in frames.enumerated() {
            XCTAssertEqual(frame.height, first.height, accuracy: 1, identifiers[index])
            XCTAssertEqual(frame.width, first.width, accuracy: 1, identifiers[index])
            if index > 0 {
                let previous = frames[index - 1]
                XCTAssertTrue(frame.minY > previous.minY + 1
                    || (abs(frame.minY - previous.minY) <= 1 && frame.minX > previous.minX),
                    "Active cards must precede Coming soon cards: \(identifiers[index])")
            }
        }
        for identifier in identifiers where identifier.hasPrefix("home.comingSoon.") {
            XCTAssertFalse(app.buttons[identifier].exists, "Coming soon must not open a feature")
        }
        XCTAssertFalse(app.buttons["home.feature.floorPlan"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS %@",
            "You, on every tour you send")).count, 0)
        XCTAssertTrue(app.tabBars.buttons["Profile"].exists)

        let frameRows = zip(identifiers, frames).map { identifier, frame in
            ["id": identifier, "x": Double(frame.minX), "y": Double(frame.minY),
             "width": Double(frame.width), "height": Double(frame.height)] as [String: Any]
        }
        let frameData = try JSONSerialization.data(withJSONObject: frameRows, options: [.prettyPrinted, .sortedKeys])
        let frameAttachment = XCTAttachment(string: String(decoding: frameData, as: UTF8.self))
        frameAttachment.name = "home-showroom-frames.json"; frameAttachment.lifetime = .keepAlways; add(frameAttachment)
        let firstActiveScreenshot = XCTAttachment(screenshot: app.screenshot())
        firstActiveScreenshot.name = "home-showroom-active-start"; firstActiveScreenshot.lifetime = .keepAlways; add(firstActiveScreenshot)

        func retainSection(endingAt card: XCUIElement, name: String) {
            let visibleBottom = app.tabBars.firstMatch.frame.minY
            revealCard(card)
            XCTAssertTrue(card.isHittable, "Could not reach \(card.identifier) within the bounded Home scroll")
            XCTAssertLessThanOrEqual(card.frame.maxY, visibleBottom + 1, "The retained card must not be hidden behind the tab bar")
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        }
        retainSection(endingAt: cards[activeCount - 1], name: "home-showroom-active-cards")
        retainSection(endingAt: cards[cards.count - 1], name: "home-showroom-coming-soon-cards")
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "home-showroom-accessibility"; tree.lifetime = .keepAlways; add(tree)
#else
        throw XCTSkip("Closed Home fixtures exist only on the simulator.")
#endif
    }

    func testDesignHomeOnlyKeepsApprovedCopyAndTwoColumnCards() {
        XCTAssertTrue(waitForHome(timeout: screenTimeout))
        XCTAssertTrue(app.staticTexts["List it. Launch it. Sell it."].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@",
            "Be your own crew. Capture and polish photos, create tours, social media content, floor plans, virtual staging, and a shareable property site - all from your phone.")).firstMatch.exists)
        let started = app.buttons["home.getStarted"]
        XCTAssertTrue(started.isHittable)
        XCTAssertGreaterThanOrEqual(started.frame.height, 44)
        XCTAssertFalse(app.buttons["home.addHome"].exists,
            "Get started is the sole Home creation CTA")
        XCTAssertFalse(app.staticTexts["My Listings"].exists,
            "Listings belong in their own tab, not the Home dashboard")
        XCTAssertFalse(app.staticTexts["Your first home in five steps"].exists,
            "Get started replaces the duplicate Home setup card")
        shot("design-home-only-hero")
        let cards = ["tour", "photos", "photoStudio", "reel"].map {
            app.buttons["home.feature.\($0)"]
        }
        for card in cards { XCTAssertTrue(card.exists, card.identifier) }
        let frames = cards.map(\.frame)
        XCTAssertEqual(frames[0].minY, frames[1].minY, accuracy: 1)
        XCTAssertEqual(frames[2].minY, frames[3].minY, accuracy: 1)
        XCTAssertGreaterThan(frames[1].minX, frames[0].minX)
        XCTAssertGreaterThan(frames[2].minY, frames[0].maxY)
        XCTAssertEqual(frames[0].width, frames[1].width, accuracy: 1)
        for _ in 0..<8 where !cards[3].isHittable { app.swipeUp() }
        shot("design-home-only-two-column-cards")
    }

    func testAppearanceSettingsFollowSystemAndKeepOverrides() {
#if targetEnvironment(simulator)
        // Unlike screenshot fixtures, this test must let Settings write the
        // preference: NSArgumentDomain would otherwise force the launch value.
        app.terminate()
        if let index = app.launchArguments.firstIndex(of: "-appearance") {
            app.launchArguments.removeSubrange(index...(index + 1))
        }
        app.launch()
        XCTAssertTrue(waitForHome(timeout: screenTimeout))

        func choose(_ label: String) {
            app.tabBars.buttons["Settings"].tap()
            let option = app.segmentedControls.buttons[label]
            for _ in 0..<6 where !option.isHittable { app.swipeUp() }
            XCTAssertTrue(option.isHittable, "Appearance choice must remain reachable")
            option.tap()
            XCTAssertTrue(option.isSelected, "Settings must accept \(label)")
            app.tabBars.buttons["Home"].tap()
            XCTAssertTrue(app.buttons["home.getStarted"].exists)
            shot("appearance-home-\(label.lowercased())")
        }

        for label in ["Light", "Dark", "System"] {
            choose(label)
            app.terminate()
            app.launch()
            app.tabBars.buttons["Settings"].tap()
            let option = app.segmentedControls.buttons[label]
            for _ in 0..<6 where !option.isHittable { app.swipeUp() }
            XCTAssertTrue(option.isSelected, "\(label) must persist across relaunch")
            app.tabBars.buttons["Home"].tap()
        }
#else
        // This closed fixture performs no camera, account, purchase or AI work.
#endif
    }

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
        let required = Set(["01-home", "02-add-home", "03-photo-studio",
                            "04-reel-studio-voice", "05-settings", "06-owner-console",
                            "07-routing", "08-paywall", "09-health-probe"])
        XCTAssertTrue(required.isSubset(of: capturedScreens),
                      "Missing required screenshot steps: \(required.subtracting(capturedScreens).sorted())")
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
            let listings = app.tabBars.buttons["Listings"]
            XCTAssertTrue(listings.waitForExistence(timeout: shortTimeout), "Listings tab must remain reachable")
            listings.tap()
            guard let add = find(ids: [], labels: ["Add a home"], timeout: shortTimeout) else {
                note("SKIPPED: the Listings tab's Add a home action was unavailable.")
                return
            }
            tap(add)
            // The collection's Add action always opens NewListingView, including
            // when a real listing already exists. Get started uses that listing.
            XCTAssertTrue(waitForAny(ids: [],
                           labels: ["New Home", "Add a home", "Name this home first"],
                           timeout: shortTimeout + 3), "Add-home form did not open")
            settle()
            shot("02-add-home")
            dismissTopScreen()
            XCTAssertTrue(returnToHomeDashboard(), "Add-home form did not return to Home")
            XCTAssertTrue(waitForHome(timeout: shortTimeout + 3), "Add-home form did not dismiss")
        }
    }

    // MARK: 03 — AI Photo Studio

    /// Use Home's current AI Photo Studio route. The listing detail embeds a
    /// scroll-scrub player above its toolbox; app-wide swipes can scrub that
    /// player instead of bringing the toolbox onscreen. Home's feature gate
    /// resolves the same synthetic project without that ambiguous gesture.
    /// - Returns: true when the studio is on screen at the end of the step.
    @discardableResult
    private func step03PhotoStudio() -> Bool {
        var reached = false
        activity("03 — AI Photo Studio") {
            guard returnToHomeDashboard(),
                  let tile = scrollTo(ids: ["home.feature.photoStudio"], labels: [], swipes: 8) else {
                note("Required AI Photo Studio tile is missing from the confirmed Home dashboard.")
                return
            }
            tap(tile)
            nameFirstProjectIfAsked()

            guard app.navigationBars["AI Photo Studio"].waitForExistence(timeout: screenTimeout) else {
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

    /// Home's current reel feature opens ReelStudioView directly, using the
    /// same listing-photo input as the toolbox. Two generated fixtures must
    /// have completed local ingest before opening that presentation.
    /// Select them locally, then expose Voice without recording or generating.
    private func step04ReelStudioVoice(reachedPhotoStudio: Bool) {
        activity("04 — Reel Studio · Voice step") {
            guard reachedPhotoStudio else {
                note("SKIPPED: the photo studio was never reached, so its reel card is unreachable too.")
                return
            }

            // Ingest is asynchronous. Home's .reel gate reloads this listing's
            // photos before constructing ReelStudioView's immutable input.
            settle(4)
            guard returnToHomeDashboard(),
                  let card = scrollTo(ids: ["home.feature.reel"], labels: [], swipes: 8),
                  card.isEnabled, card.isHittable else {
                note("Required Home Make a reel control is missing, disabled or offscreen.")
                return
            }
            tap(card)
            nameFirstProjectIfAsked()

            guard app.navigationBars["Reel Studio"].waitForExistence(timeout: screenTimeout) else {
                note("SKIPPED: Reel Studio did not open.")
                return
            }

            let photos = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "reel.photo."))
            guard photos.element(boundBy: 1).waitForExistence(timeout: screenTimeout) else {
                note("Reel Studio has fewer than two synthetic photos; test-only seed import failed.")
                return
            }
            for index in 0..<2 {
                let photo = photos.element(boundBy: index)
                guard let visible = scrollTo(ids: [photo.identifier], labels: [], swipes: 6) else {
                    note("Synthetic reel photo \(index + 1) is not tappable.")
                    return
                }
                tap(visible)
            }
            XCTAssertTrue(waitForAny(ids: [], labels: ["2/8"], timeout: shortTimeout),
                          "Reel Studio did not select both synthetic photos")
            guard let myVoice = scrollTo(ids: [], labels: ["My voice"], swipes: 8) else {
                note("Required My voice segment did not scroll into view.")
                return
            }
            tap(myVoice)
            guard scrollTo(ids: [], labels: ["Record"], swipes: 3) != nil else {
                note("My voice did not expose its Record control; no recording was started.")
                return
            }
            settle()
            shot("04-reel-studio-voice")

            dismissTopScreen()          // Close → Home dashboard
            let home = app.tabBars.buttons["Home"]
            if home.exists && home.isHittable { home.tap() }
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
            XCTAssertTrue(waitForAny(ids: [], labels: ["Plan & usage", "Business type"], timeout: screenTimeout),
                          "Settings content did not load")
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
        waitForAny(ids: ["home.getStarted"], labels: ["Create Something Amazing"], timeout: timeout)
    }

    /// A Home-tab selection alone can leave that tab's navigation stack pushed.
    /// Confirm its exact navigation title before looking for Home feature IDs.
    private func returnToHomeDashboard() -> Bool {
        for _ in 0..<4 {
            let tab = app.tabBars.buttons["Home"]
            if tab.exists && tab.isHittable { tab.tap() }
            if app.navigationBars["Home"].waitForExistence(timeout: 1) {
                scrollToTop()
                return true
            }
            dismissTopScreen()
        }
        note("Could not return to the Home dashboard before opening its feature")
        return false
    }

    @discardableResult
    private func openSettingsTab() -> Bool {
        // A previous step may have left a sheet or pushed screen open.
        for _ in 0..<3 where !app.tabBars.buttons["Settings"].isHittable {
            dismissTopScreen()
        }
        // Already there?
        if find(ids: [], labels: ["Plan & usage"], timeout: 0.5) != nil {
            scrollToTop()
            return true
        }
        let tab = app.tabBars.buttons["Settings"]
        guard tab.waitForExistence(timeout: shortTimeout) else { return false }
        tab.tap()
        scrollToTop()
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
        guard let row = scrollTo(ids: ["home.listing.first"], labels: [], swipes: 6)
                ?? firstListingRowByAddress() else { scrollToTop(); return false }
        tap(row)
        return scrollTo(ids: ["detail.photoStudio"], labels: [], swipes: 8) != nil
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
        if app.navigationBars["Pick a home"].waitForExistence(timeout: 1) {
            // These are the only addresses authored by the two release walks.
            guard let fixture = scrollTo(ids: [], labels: [walkAddress, "24 Willow Bend Court"], swipes: 6) else {
                note("Project picker has no known synthetic walk project; refusing to choose another listing.")
                return
            }
            tap(fixture)
            return
        }
        guard waitForAny(ids: [], labels: ["Name this home first", "Save and continue"],
                         timeout: shortTimeout) else { return }
        let field = app.textFields.firstMatch
        guard field.waitForExistence(timeout: shortTimeout) else {
            note("New-project name field is missing")
            return
        }
        field.tap()
        field.typeText(walkAddress)
        if app.keyboards.buttons["Done"].isHittable { app.keyboards.buttons["Done"].tap() }
        if let save = find(ids: [], labels: ["Save and continue"], timeout: shortTimeout) {
            tap(save)
        } else {
            note("New-project Save and continue control is missing")
        }
    }

    /// Tiny, unmistakably synthetic images, generated locally. No library,
    /// customer path, internet, or fixture download. Retained for diagnostics.
    private func makeSyntheticPhotos() throws -> URL {
        #if !targetEnvironment(simulator)
        throw NSError(domain: "ReleaseWalk", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Synthetic shared-path UI walk requires an iOS simulator"])
        #else
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rendprop-ui-synthetic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        for index in 1...2 {
            let picture = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 320), format: format).image { context in
                (index == 1 ? UIColor.systemTeal : UIColor.systemOrange).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 480, height: 320))
                UIColor.white.setFill()
                context.fill(CGRect(x: CGFloat(40 * index), y: 45, width: 180, height: 130))
                ("SYNTHETIC UI FIXTURE \(index)\nNOT A PROPERTY PHOTO" as NSString).draw(
                    in: CGRect(x: 20, y: 225, width: 440, height: 80),
                    withAttributes: [.font: UIFont.boldSystemFont(ofSize: 20), .foregroundColor: UIColor.black])
            }
            let data = try XCTUnwrap(picture.jpegData(compressionQuality: 0.9))
            XCTAssertLessThan(data.count, 100_000, "Synthetic fixture unexpectedly large")
            try data.write(to: directory.appendingPathComponent("fixture-\(index).jpg"), options: .atomic)
        }
        return directory
        #endif
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
        return nil
    }

    private func scrollToTop() {
        for _ in 0..<8 { app.swipeDown(); settle(0.15) }
    }

    private func isOnScreen(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        guard frame.width > 0, frame.height > 0 else { return false }
        let window = app.windows.element(boundBy: 0)
        guard window.exists else { return true }
        return window.frame.intersects(frame) && element.isHittable
    }

    private func tap(_ element: XCUIElement) {
        guard element.exists else { note("Required tap target disappeared"); return }
        if element.isHittable {
            element.tap()
        } else {
            // A control the accessibility tree can see but the hit-tester
            // cannot (mid-animation, or just off the bottom edge).
            app.swipeUp()
            settle(0.35)
            if element.isHittable { element.tap() }
            else { note("Required tap target is not hittable: \(element.identifier) / \(element.label)") }
        }
        settle(0.6)
    }

    // MARK: - Screenshots, activities and waiting

    private func shot(_ name: String) {
        capturedScreens.insert(name)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func activity(_ name: String, _ body: () -> Void) {
        XCTContext.runActivity(named: name) { _ in body() }
    }

    /// Missing required coverage is an XCTest failure, not a passing note.
    /// Continue collecting independent screenshots after recording the failure.
    private func note(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTContext.runActivity(named: "REQUIRED COVERAGE FAILURE: \(text)") { _ in
            XCTFail(text, file: file, line: line)
        }
    }

    /// Let animations and async loads settle. An inverted expectation waits the
    /// full interval and passes — unlike `sleep`, it keeps the runloop alive.
    private func settle(_ seconds: TimeInterval = 1.0) {
        let idle = expectation(description: "settle")
        idle.isInverted = true
        wait(for: [idle], timeout: seconds)
    }
}
