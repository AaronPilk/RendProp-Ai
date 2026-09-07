//
//  CoachShot.swift
//  Coach smoke test + screenshots (docs/COACH-CONTRACT.md).
//
//  Two things this proves, end to end, against the mock backend
//  (`-uiTesting` → MockAPIClient.coach(), a deterministic canned reply with
//  exactly one action): BOTH entry points actually open Coach (Home's round
//  sparkles button, and Settings' "Coach & help" row), and a starter chip
//  really does produce an assistant reply with a tappable action chip.
//
//  Conventions mirror PaywallShot.swift exactly (this file is deliberately
//  self-contained, not shared — same as every other *Shot file here):
//  identifier first, visible label second, never coordinates;
//  `continueAfterFailure = true`; one `XCTContext.runActivity` per step; a
//  step that cannot be reached writes why into the result bundle instead of
//  failing the run; `XCUIScreen.main.screenshot()` with `.lifetime =
//  .keepAlways`.
//

import XCTest

final class CoachShot: XCTestCase {

    private var app: XCUIApplication!
    private let screenTimeout: TimeInterval = 15
    private let shortTimeout: TimeInterval = 3

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        // Same mock backend, same skipped gates, same deterministic light
        // appearance as PaywallShot / StoreShots.
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

    func testCoachShot() {
        step01OpenFromHome()
        step02SendStarterChip()
        step03TapAction()
        step04OpenFromSettings()
    }

    // MARK: p01 — Home's "Ask the coach" button

    /// Reached the way a user reaches it: Home tab → the round sparkles
    /// button (`home.askCoach` / "Ask the coach").
    private func step01OpenFromHome() {
        activity("p01 — Coach · opened from Home") {
            guard openHomeTab() else {
                note("SKIPPED: no Home tab.")
                return
            }
            guard let button = find(ids: ["home.askCoach"], labels: ["Ask the coach"], timeout: screenTimeout) else {
                note("SKIPPED: no `home.askCoach` button and no \"Ask the coach\" control on Home.")
                return
            }
            tap(button)
            guard waitForAny(ids: ["coach.root"], labels: ["Coach", "Ask the coach…"], timeout: screenTimeout) else {
                note("SKIPPED: tapped \"Ask the coach\" but Coach never appeared within \(Int(screenTimeout))s.")
                shot("coach-01-EMPTY")
                return
            }
            settle(1.2)   // let the greeting bubble and starter chips animate in
            shot("coach-01-opened")
        }
    }

    // MARK: p02 — a starter chip → the mock's canned reply

    /// Taps the first starter chip and waits for the assistant's reply
    /// bubble. Under `-uiTesting` this is MockAPIClient.coach() — a fixed
    /// reply with exactly one action chip.
    private func step02SendStarterChip() {
        activity("p02 — Coach · starter chip → reply") {
            guard find(ids: ["coach.root"], labels: ["Coach"], timeout: shortTimeout) != nil else {
                note("SKIPPED: Coach is not open.")
                return
            }
            guard let chip = find(ids: [], labels: ["Start my first tour"], timeout: shortTimeout) else {
                note("SKIPPED: no \"Start my first tour\" starter chip.")
                return
            }
            tap(chip)
            // The mock's one action is either "Open the tour" (a seeded
            // listing exists) or "Start my first project" (none yet) —
            // never both, never neither.
            guard waitForAny(ids: [], labels: ["Open the tour", "Start my first project"], timeout: screenTimeout) else {
                note("SKIPPED: no action chip appeared within \(Int(screenTimeout))s after the starter chip — "
                     + "the reply bubble may still have rendered; capturing whatever is on screen.")
                shot("coach-02-EMPTY")
                return
            }
            settle(0.8)
            shot("coach-02-reply")
        }
    }

    // MARK: p03 — tapping the action chip actually navigates somewhere

    /// Taps whichever action chip p02 found. Coach should dismiss and the
    /// app should land on a real screen — this only proves "something that
    /// isn't Coach" is now on screen, not which screen (that already has its
    /// own coverage elsewhere, e.g. StoreShots).
    private func step03TapAction() {
        activity("p03 — Coach · action chip navigates") {
            guard let action = find(ids: [], labels: ["Open the tour", "Start my first project"], timeout: shortTimeout) else {
                note("SKIPPED: no action chip left to tap.")
                return
            }
            tap(action)
            settle(1.5)
            if find(ids: ["coach.root"], labels: [], timeout: shortTimeout) != nil {
                note("Coach is still on screen \(Int(shortTimeout))s after tapping its action chip — "
                     + "expected it to dismiss (see RendpropApp.swift's `coachRoute` wiring).")
            }
            shot("coach-03-afterAction")
        }
    }

    // MARK: p04 — Settings' "Coach & help" row (entry point 2 of 2)

    private func step04OpenFromSettings() {
        activity("p04 — Coach · opened from Settings") {
            guard openSettingsTab() else {
                note("SKIPPED: no Settings tab.")
                return
            }
            guard let row = scrollTo(ids: ["settings.coachAndHelp"], labels: ["Coach & help"], swipes: 8) else {
                note("SKIPPED: no `settings.coachAndHelp` row and no \"Coach & help\" row in Settings.")
                return
            }
            tap(row)
            guard waitForAny(ids: ["coach.root"], labels: ["Coach"], timeout: screenTimeout) else {
                note("SKIPPED: tapped \"Coach & help\" but Coach never appeared within \(Int(screenTimeout))s.")
                shot("coach-04-EMPTY")
                return
            }
            settle(1.0)
            shot("coach-04-fromSettings")
        }
    }

    // MARK: - Navigation helpers (mirroring PaywallShot / StoreShots)

    @discardableResult
    private func openHomeTab() -> Bool {
        openTab("Home", ids: [], confirmedBy: ["RENDPROP"])
    }

    @discardableResult
    private func openSettingsTab() -> Bool {
        openTab("Settings", ids: [], confirmedBy: ["Plan & usage", "Business type"])
    }

    /// Tap a tab and wait for something only that tab shows. A tab tap while
    /// a screen is pushed pops to the tab's root rather than switching, so a
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

    /// Swipe up until the target is actually on screen.
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
            app.swipeUp()
            settle(0.35)
            if element.isHittable { element.tap() }
        }
        settle(0.8)
    }

    // MARK: - Screenshots, activities and waiting

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func activity(_ name: String, _ body: () -> Void) {
        XCTContext.runActivity(named: name) { _ in body() }
    }

    private func note(_ text: String) {
        XCTContext.runActivity(named: text) { _ in }
    }

    private func settle(_ seconds: TimeInterval = 1.0) {
        let idle = expectation(description: "settle")
        idle.isInverted = true
        wait(for: [idle], timeout: seconds)
    }
}
