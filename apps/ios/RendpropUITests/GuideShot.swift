//
//  GuideShot.swift
//  A screenshot of the first-project guide card at a known progress state
//  (Guide/FirstProjectGuide.swift, Guide/FirstProjectCard.swift).
//
//  ONE test — `testGuideShot()` — launches with `-ui.guideState 2`, which
//  forces `FirstProjectGuide.progress(model:)` to report exactly 2 of 5 steps
//  done (Config.uiTestGuideState) instead of reading the real capture/tag/
//  render/share state the card normally derives its progress from, and
//  attaches a `keepAlways` screenshot of Home with the card mid-guide. Real
//  progress is slow to set up from a clean simulator — it needs a filmed
//  walkthrough, tagged rooms, a finished render and a published link — so the
//  launch argument is what makes every card state reachable on demand.
//
//  Same rules as StoreShots / PaywallShot: identifier first, visible label
//  second, never coordinates; `continueAfterFailure = true`; one
//  `XCTContext.runActivity` per step; a step that cannot be reached writes the
//  reason into the result bundle instead of failing the run.
//

import XCTest

final class GuideShot: XCTestCase {

    // MARK: - Fixtures

    private var app: XCUIApplication!

    /// Longest wait for a screen. A cold simulator compiles shaders and seeds
    /// the sample listings on the first launch.
    private let screenTimeout: TimeInterval = 15

    override func setUpWithError() throws {
        // One screenshot. Nothing here is worth failing the run over.
        continueAfterFailure = true

        app = XCUIApplication()
        // Identical base to StoreShots / RendpropUITests — same mock backend,
        // same skipped gates, same deterministic light appearance — plus
        // `-ui.guideState 2`, read only under `-uiTesting` (Config.swift).
        // Keys verified against source: RendpropApp.swift
        // @AppStorage("hasOnboarded"), RootTabView @AppStorage("space.type"),
        // @AppStorage("appearance"), AIConsent
        // "ai.thirdPartyProcessing.consent.v1", Config.uiTestGuideState.
        app.launchArguments += [
            "-uiTesting",
            "-hasOnboarded", "YES",
            "-space.type", "real_estate",
            "-appearance", "light",
            "-ai.thirdPartyProcessing.consent.v1", "YES",
            "-ui.guideState", "2",
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - The capture

    func testGuideShot() {
        activity("g01 — First-project guide · 2 of 5") {
            guard waitForHome(timeout: screenTimeout) else {
                note("Home never appeared within \(Int(screenTimeout))s — capturing whatever is on screen.")
                shot("g01-guide-card")
                return
            }
            guard scrollTo(ids: ["guide.card"], labels: ["Your first"], swipes: 6) != nil else {
                note("The guide card never scrolled into view — on a simulator reused from an earlier "
                     + "run it may already be permanently dismissed (FirstProjectGuide.isHiddenForever "
                     + "only bypasses that for THIS launch's forced state, never clears a flag written by "
                     + "a previous one). Capturing Home as it stands.")
                shot("g01-guide-card")
                return
            }
            settle(1.5)
            shot("g01-guide-card")
        }
    }

    // MARK: - Navigation helpers (mirrors StoreShots.swift)

    private func waitForHome(timeout: TimeInterval) -> Bool {
        waitForAny(ids: ["home.addHome"], labels: ["Make something"], timeout: timeout)
    }

    /// First element matching any identifier, else any element whose label is
    /// (or starts with) one of `labels`. Polls until `timeout`.
    private func find(ids: [String], labels: [String], timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for identifier in ids {
                let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
                if element.exists { return element }
            }
            for label in labels {
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

    private func isOnScreen(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        guard frame.width > 0, frame.height > 0 else { return false }
        let window = app.windows.element(boundBy: 0)
        guard window.exists else { return true }
        return window.frame.intersects(frame)
    }

    /// Swipe up until the target is actually on screen — "exists" is not
    /// enough for a screenshot, the thing has to be in frame.
    private func scrollTo(ids: [String], labels: [String], swipes: Int) -> XCUIElement? {
        for _ in 0...swipes {
            if let element = find(ids: ids, labels: labels, timeout: 0.8), isOnScreen(element) {
                return element
            }
            app.swipeUp()
            settle(0.35)
        }
        return find(ids: ids, labels: labels, timeout: 0.8)
    }

    // MARK: - Screenshots, activities and waiting (mirrors StoreShots.swift)

    /// Full-screen, device-resolution capture.
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func activity(_ name: String, _ body: () -> Void) {
        XCTContext.runActivity(named: name) { _ in body() }
    }

    /// A line in the result bundle explaining a skip or a caveat.
    private func note(_ text: String) {
        XCTContext.runActivity(named: text) { _ in }
    }

    /// Let animations settle. An inverted expectation waits the full interval
    /// and passes — unlike `sleep`, it keeps the runloop alive.
    private func settle(_ seconds: TimeInterval = 1.0) {
        let idle = expectation(description: "settle")
        idle.isInverted = true
        wait(for: [idle], timeout: seconds)
    }
}
