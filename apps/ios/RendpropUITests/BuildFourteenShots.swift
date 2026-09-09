//
//  BuildFourteenShots.swift
//  Photographs the three surfaces build 14 added, so they are looked at rather
//  than assumed: the free-week line at the end of onboarding, the plan banner
//  on Home, and Settings → Team.
//
//  Same rules as ReviewerWalk: `continueAfterFailure = true`, one activity per
//  step, never an assert that costs the other screenshots, identifier first and
//  visible label second. It taps nothing destructive — there is no Delete
//  Account step here and there must never be one.
//
//  WHAT THE TEAM SHOT WILL SHOW. `-uiTesting` makes Config.isUITesting true, so
//  AuthStore reports an identified session, but TeamAPI talks to the real edge
//  function and the mock has no token for it — so the screen draws its load
//  error rather than a member list. That is the correct thing to verify here:
//  the row exists, the screen is reachable, it does not crash, and a failed
//  fetch degrades to a sentence instead of a blank. The member list itself is
//  proven server-side by the 27 live checks in _bridge/cmd/1355-team-e2e.sh.

import XCTest

final class BuildFourteenShots: XCTestCase {

    private var app: XCUIApplication!
    private let screenTimeout: TimeInterval = 15
    private let shortTimeout: TimeInterval = 3
    private let maxOnboardingScreens = 8

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        // A fresh install, so the onboarding really runs — that is where the
        // free-week line lives.
        app.launchArguments += ["-uiTesting", "-appearance", "light"]
        app.launch()
    }

    override func tearDownWithError() throws { app = nil }

    func testBuildFourteenShots() {
        step01FreeWeekLine()
        step02HomePlanBanner()
        step03SettingsTeam()
        step04BannerStates()
    }

    /// The banner draws from a live /me, which the mock cannot answer — so
    /// without this it is never seen at all. Relaunches with the DEBUG-only
    /// override once per state that matters.
    private func step04BannerStates() {
        for (arg, name) in [("trial", "b04-banner-trial"), ("ended", "b05-banner-ended"), ("paid", "b06-banner-paid")] {
            XCTContext.runActivity(named: name) { _ in
                app.terminate()
                app = XCUIApplication()
                app.launchArguments += [
                    "-uiTesting", "-appearance", "light",
                    "-hasOnboarded", "YES",
                    "-ui.planBanner", arg,
                ]
                app.launch()
                _ = app.tabBars.buttons["Home"].waitForExistence(timeout: screenTimeout)
                sleep(4)
                let asButton = app.buttons["home.planBanner"]
                let asOther  = app.otherElements["home.planBanner"]
                let found = asButton.waitForExistence(timeout: 6) || asOther.exists
                note("\(name) banner present: \(found)")
                shoot(name)
            }
        }
    }

    // MARK: b01 — the last onboarding screen, which now says what the week gives

    private func step01FreeWeekLine() {
        XCTContext.runActivity(named: "b01 free week") { _ in
            // Page through the feature cards until "Get started" appears — that
            // is the business-type picker, the screen the line was added to.
            // The carousel's cards carry "Continue" until the last, which
            // carries "Get started" — and the business-type picker AFTER it
            // carries a second "Get started". The free-week line is on the
            // picker, so this pages past the first one.
            var hops = 0
            while hops < maxOnboardingScreens {
                if app.staticTexts["What do you showcase?"].exists { break }
                let cont = app.buttons["Continue"]
                if cont.exists, cont.isHittable { cont.tap(); hops += 1; continue }
                let start = app.buttons["Get started"]
                if start.exists, start.isHittable { start.tap(); hops += 1; continue }
                break
            }
            _ = app.staticTexts["What do you showcase?"].waitForExistence(timeout: screenTimeout)
            shoot("b01-onboarding-free-week")
            let line = app.staticTexts["Your first week is on us"]
            note("free-week line on the picker: \(line.waitForExistence(timeout: shortTimeout))")
        }
    }

    // MARK: b02 — Home, with the plan banner under the hero

    private func step02HomePlanBanner() {
        XCTContext.runActivity(named: "b02 home") { _ in
            let start = app.buttons["Get started"]
            if start.waitForExistence(timeout: shortTimeout), start.isHittable { start.tap() }
            // Home takes a moment: it seeds the sample listings on first launch.
            _ = app.tabBars.buttons.firstMatch.waitForExistence(timeout: screenTimeout)
            sleep(6)
            shoot("b02-home-plan-banner")
            // BY IDENTIFIER, never by text: the banner's headline is word for
            // word the onboarding line, so a text match answers true on the
            // wrong screen — which is exactly what it did the first time.
            let onHome = app.buttons["home.planBanner"].waitForExistence(timeout: 6)
                || app.otherElements["home.planBanner"].exists
            note("plan banner on Home: \(onHome)")
            let tabs = app.tabBars.buttons.allElementsBoundByIndex.map { $0.label }
            note("tabs: " + tabs.joined(separator: ", "))
        }
    }

    // MARK: b03 — Settings → Team

    private func step03SettingsTeam() {
        XCTContext.runActivity(named: "b03 team") { _ in
            let settings = app.tabBars.buttons["Settings"]
            guard settings.waitForExistence(timeout: screenTimeout) else {
                note("no Settings tab"); return
            }
            settings.tap()
            sleep(2)

            let team = app.buttons["Team"].firstMatch
            let teamCell = app.cells.containing(.staticText, identifier: "Team").firstMatch
            var opened = false
            if team.waitForExistence(timeout: shortTimeout), team.isHittable {
                team.tap(); opened = true
            } else if teamCell.waitForExistence(timeout: shortTimeout), teamCell.isHittable {
                teamCell.tap(); opened = true
            } else {
                // The row sits below the fold on a small screen.
                app.swipeUp()
                sleep(1)
                let again = app.buttons["Team"].firstMatch
                if again.waitForExistence(timeout: shortTimeout), again.isHittable {
                    again.tap(); opened = true
                }
            }
            note("Team row reachable: \(opened)")
            sleep(3)
            shoot(opened ? "b03-team" : "b03-settings-no-team-row")
        }
    }

    // MARK: - Helpers

    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// A finding recorded in the result bundle instead of a failed run.
    private func note(_ text: String) {
        let a = XCTAttachment(string: text)
        a.name = "note"
        a.lifetime = .keepAlways
        add(a)
    }
}
