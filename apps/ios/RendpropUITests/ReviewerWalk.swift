//
//  ReviewerWalk.swift
//  The FIRST-RUN capture — what an App Store reviewer sees, in the order they
//  see it (docs/appstore/…, and the review notes the integrator writes).
//
//  The full `testReviewerWalk()` launches the app the way a reviewer's
//  fresh install launches it and attaches a `keepAlways` screenshot of each
//  screen, named `r01-…` … `r11-…`. Run on the dedicated synthetic simulator.
//  Launch arguments force consent unanswered; Settings' existing intro action
//  reopens onboarding on a rerun. No uninstall/erase/clear occurs.
//
//  This is NOT the UI walk and NOT the store-shot set. The other two both pass
//  `-hasOnboarded YES` and `-ai.thirdPartyProcessing.consent.v2 YES` so they
//  land straight on Home with every gate already answered. That is exactly the
//  part a reviewer never gets. This test leaves onboarding unset and pins consent NO:
//
//      -uiTesting        → Config.makeAPIClient() returns MockAPIClient
//      -appearance light → deterministic screenshots
//
//  `@AppStorage("hasOnboarded")` starts false and `OnboardingView` is the root.
//  Consent starts false, so the Guideline 5.1.2(i) disclosure really appears the
//  first time an AI surface is opened — which is the single most-asked-about
//  screen in an AI app's review, and r11 is the proof it exists.
//
//  Real estate is pinned so a previous synthetic industry walk cannot change
//  the sample listing/player route that this offline gate checks.
//
//  THREE THINGS THIS TEST MUST NEVER DO
//
//  1. NEVER CONFIRM AN ACCOUNT DELETION. Step r09 taps "Delete account" ONCE to
//     photograph the confirmation alert that Guideline 5.1.1(v) requires, then
//     taps Cancel. `SettingsView.deleteAccount()` calls the REAL server
//     (`serverAccountsEnabled` is `Config.useLiveBackend && Config.enableAuth`,
//     both true regardless of `-uiTesting`), so a stray tap on "Delete" would
//     issue a live erasure request. `confirmDeletionIsNeverTapped` below is the
//     only button list this step is allowed to use.
//  2. Never run an AI edit. `-uiTesting` means `MockAPIClient`, whose
//     `aiPhotoEdit` echoes the submitted image back; a "result" built from that
//     would be a misleading screenshot. r11 exercises consent decisions only;
//     agreement exposes the idle studio and never taps an edit action.
//  3. Never hide missing required coverage. `continueAfterFailure = true`
//     collects the remaining screenshots, but missing screens fail XCTest.
//     Only r10 is explicitly excluded in the identified mock, verified by the
//     visible Sign out row. That exclusion is not sign-in coverage.
//
//  Element lookup is identifier first (grep `.accessibilityIdentifier(` in
//  apps/ios/Rendprop), visible label second, never coordinates.
//

import XCTest

final class ReviewerWalk: XCTestCase {

    // MARK: - Fixtures

    private var app: XCUIApplication!
    private var capturedScreens = Set<String>()

    /// Longest wait for a screen. A cold simulator compiles shaders and seeds
    /// the sample listings on the first launch.
    private let screenTimeout: TimeInterval = 15
    /// Wait for something that should already be there.
    private let shortTimeout: TimeInterval = 3
    /// The bundled player's own startup/error deadline is 12 seconds.
    private let playerTimeout: TimeInterval = 15

    /// The address typed into the "name this home" gate that r11 needs (every
    /// AI tool is deliberately a no-op on the seeded samples).
    ///
    /// FAIR HOUSING: a street address and nothing else. No neighbourhood, no
    /// school, no description of who a space would suit — none of that may
    /// appear in a Rendprop screenshot.
    private let walkAddress = "24 Willow Bend Court"

    /// The onboarding cards in `OnboardingView` (4 of them) plus the business
    /// type picker it flips to = 5 first-run screens. Read from source; the
    /// loop in `step01Onboarding` does not depend on the number being right,
    /// it just refuses to spin past this many.
    private let maxOnboardingScreens = 8

    /// Buttons r09 is allowed to press to get out of the delete-account alert.
    /// "Delete" is NOT here and must never be added — see the file header.
    private let confirmDeletionIsNeverTapped = ["Cancel"]

    override func setUpWithError() throws {
        // Eleven screenshots. One unreachable control must not cost us the
        // other ten.
        continueAfterFailure = true

        app = XCUIApplication()
        // Consent starts false without reading or clearing persisted data.
        // Do not pin hasOnboarded=false: argument-domain precedence would
        // prevent its persisted completion from being read after Get started.
        //   RendpropApp.swift  @AppStorage("hasOnboarded")  → NOT set: the intro shows
        //   AIConsent          "ai.thirdPartyProcessing.consent.v2" → NOT set: r11 shows
        //   RendpropApp.swift  @AppStorage("appearance") / Appearance.light == "light"
        app.launchArguments += [
            "-uiTesting",
            "-appearance", "light",
            "-ai.thirdPartyProcessing.consent.v2", "NO",
            "-space.type", "real_estate",
        ]
        if name.contains("testAIConsentDecisions") || name.contains("testAskAILabelOnLongTitle") {
            // Focused iteration reuses r11 without spending minutes on the
            // unrelated onboarding/player/legal/deletion-dialog screenshot walk.
            app.launchArguments += ["-hasOnboarded", "YES"]
        }
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - The capture

    func testReviewerWalk() {
        step01Onboarding()
        step02FirstHome()
        step03Homes()
        let onSampleDetail = step04SampleDetail()
        step05SamplePlayer(reachedSampleDetail: onSampleDetail)
        step06Profile()
        step07SettingsLegal()
        step08And09DeleteAccount()
        step10SignInGate()
        // LAST on purpose: it creates the walk's one real home, which changes
        // what Home and the Homes tab look like. Every "fresh install" shot
        // above is already taken by the time it runs.
        step11AIConsent()
        let required = Set(["r01-onboarding-1", "r02-first-home", "r03-homes",
                            "r04-sample-detail", "r05-sample-player", "r06-profile",
                            "r07-settings-legal", "r08-delete-account", "r09-delete-confirm",
                            "r11-ai-consent"])
        XCTAssertTrue(required.isSubset(of: capturedScreens),
                      "Missing required reviewer steps: \(required.subtracting(capturedScreens).sorted()); r10 is excluded only in identified mock")
    }

    /// Same actual r11 path and assertions as the release walk. No fixture
    /// consent view, coordinate taps, AI edit or destructive dialog is used.
    func testAIConsentDecisions() {
        step11AIConsent()
        let required = Set(["r11-ai-consent", "r11b-consent-actions", "r11c-consent-granted"])
        XCTAssertTrue(required.isSubset(of: capturedScreens),
                      "Missing required consent states: \(required.subtracting(capturedScreens).sorted())")
    }

    /// An accessibility label can be complete while the drawn title is "A…".
    /// Check geometry and opening the real destination, then require review of
    /// the screenshot. This never sends a Coach message or invokes a provider.
    func testAskAILabelOnLongTitle() {
        step03Homes()
        guard step04SampleDetail() else {
            XCTFail("Long-title sample detail must be reached")
            return
        }
        let buttons = app.buttons.matching(identifier: "askAI")
        XCTAssertEqual(buttons.count, 1, "Ask AI must be unambiguous")
        guard buttons.count == 1 else { return }
        let button = buttons.element(boundBy: 0)
        XCTAssertTrue(button.isHittable && button.isEnabled)
        XCTAssertGreaterThanOrEqual(button.frame.width, 76)
        XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        XCTAssertTrue(app.frame.contains(button.frame))
        shot("ask-ai-long-title")
        tap(button)
        XCTAssertTrue(app.navigationBars["Coach"].waitForExistence(timeout: screenTimeout),
                      "Ask AI must open the actual Coach screen")
        shot("ask-ai-coach-open")
        XCTAssertTrue(Set(["ask-ai-long-title", "ask-ai-coach-open"]).isSubset(of: capturedScreens))
    }

    // MARK: r01 — the onboarding pages

    /// Every page of `OnboardingView`, in order.
    ///
    /// The view is four feature cards in a paged `TabView` followed by the
    /// "What do you showcase?" business-type picker (`choosingType`). The card
    /// pages carry a "Continue" button until the last one, where it becomes
    /// "Get started" and flips to the picker; the picker's own "Get started"
    /// sets `hasOnboarded = true` and swaps the root for `RootTabView`.
    ///
    /// The loop below does not hard-code four: it screenshots whatever is on
    /// screen, taps whichever of the two buttons is there, and stops as soon as
    /// the picker has been photographed — so a fifth card added later is
    /// captured without touching this file. The activity note records the real
    /// count for whoever reads the result bundle.
    private func step01Onboarding() {
        activity("r01 — Onboarding") {
            if app.tabBars.buttons["Settings"].waitForExistence(timeout: 2) {
                guard openSettingsTab(),
                      let intro = scrollTo(ids: [], labels: ["Watch the intro again"], swipes: 10) else {
                    note("Existing synthetic state could not reopen onboarding through Settings")
                    return
                }
                tap(intro)
                info("Rerun: opened onboarding through Settings; existing synthetic projects were preserved")
            }
            guard waitForAny(ids: [], labels: ["Continue", "Get started", "RENDPROP"],
                             timeout: screenTimeout) else {
                note("SKIPPED: no onboarding on launch. Either `hasOnboarded` survived from a "
                     + "previous run (uninstall the app first — bridge-cmd-reviewerwalk.sh does) "
                     + "or the intro was removed.")
                shot("r01-onboarding-1")
                return
            }

            var screens = 0
            var photographedPicker = false
            for _ in 0..<maxOnboardingScreens {
                settle(0.9)                 // the page transition is animated
                screens += 1
                // The picker is the only page that lists the business types.
                let onTypePicker = find(ids: [],
                                        labels: ["Real estate", "Event venue"],
                                        timeout: 1.0) != nil
                shot("r01-onboarding-\(screens)")

                if onTypePicker {
                    photographedPicker = true
                    // Accept the pre-selected "Real estate" the way a reviewer
                    // would, and leave the intro.
                    if let start = find(ids: [], labels: ["Get started"], timeout: shortTimeout) {
                        tap(start)
                    } else {
                        note("The type picker had no \"Get started\" button — onboarding cannot be left.")
                    }
                    break
                }

                if let next = find(ids: [], labels: ["Continue"], timeout: 1.0) {
                    tap(next)               // a card page that is not the last
                } else if let start = find(ids: [], labels: ["Get started"], timeout: 1.0) {
                    tap(start)              // the last card → the type picker
                } else {
                    note("Onboarding page \(screens) had neither \"Continue\" nor \"Get started\" — "
                         + "swiping instead.")
                    app.swipeLeft()
                }
            }

            XCTAssertTrue(photographedPicker, "Onboarding never reached its business-type picker within \(maxOnboardingScreens) pages")
            info("r01 captured \(screens) onboarding screens; business-type picker reached: \(photographedPicker)")
        }
    }

    // MARK: r02 — the first screen after onboarding

    /// What the app becomes the moment `hasOnboarded` flips: `RootTabView`'s
    /// Home tab, with no homes of the user's own yet.
    private func step02FirstHome() {
        activity("r02 — First Home after onboarding") {
            guard waitForHome(timeout: screenTimeout) else {
                note("Home never appeared within \(Int(screenTimeout))s after onboarding — "
                     + "capturing whatever is on screen.")
                shot("r02-first-home")
                return
            }
            scrollToTop()
            settle(1.5)
            shot("r02-first-home")
        }
    }

    // MARK: r03 — the Homes tab

    /// The collection tab. On a fresh install it is the "Your first tour is 10
    /// minutes away" card plus the two seeded SAMPLE listings — the only
    /// content a reviewer has to work with before they film anything.
    private func step03Homes() {
        activity("r03 — Homes tab") {
            guard openSpacesTab() else {
                note("SKIPPED: no second tab (Homes/Venues/Places/Stores/Studios/Spaces).")
                return
            }
            settle(2)                       // the list seeds its samples on first appear
            shot("r03-homes")
        }
    }

    // MARK: r04 — a sample home's detail

    /// The first sample listing's detail: the SAMPLE TOUR player at the top,
    /// the "This is a sample" card, and the TOOLBOX with every AI tool dimmed
    /// (samples never publish and their tools are no-ops by design — decision
    /// A7). This is the screen that explains to a reviewer why the AI buttons
    /// do nothing until they make a home of their own.
    /// - Returns: true when the sample detail is on screen at the end.
    @discardableResult
    private func step04SampleDetail() -> Bool {
        var reached = false
        activity("r04 — Sample home detail") {
            guard openFirstSampleHome() else {
                note("SKIPPED: no row whose label contains \"Sample\" on the Homes tab, so no "
                     + "sample detail to capture.")
                return
            }
            reached = true
            settle(2)
            shot("r04-sample-detail")
        }
        return reached
    }

    // MARK: r05 — the sample tour player

    /// The product in one screen: the scroll-to-fly-through player.
    ///
    /// Use only the sample detail's natural bundled player. Hosted demo pages
    /// are outside this offline UI gate. Require its loaded controls and reject
    /// all explicit unavailable states; a blank WKWebView is not player proof.
    /// This remains bundled-demo UI coverage, not physical-room validation.
    private func step05SamplePlayer(reachedSampleDetail: Bool) {
        activity("r05 — Sample tour player") {
            guard reachedSampleDetail || openFirstSampleHome() else {
                note("Required sample detail is not reachable for the bundled-player check.")
                return
            }
            scrollToTop()
            let web = app.webViews.firstMatch
            guard web.waitForExistence(timeout: screenTimeout) else {
                note("Sample detail has no player web view")
                return
            }
            settle(playerTimeout)
            let unavailable = web.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "unavailable"))
            guard unavailable.count == 0,
                  web.staticTexts["Scroll to fly through"].exists else {
                note("Bundled player did not reach its ready UI: demo.mp4 may be absent or the player failed; blank/unavailable is not coverage")
                shot("r05-player-failure")
                return
            }
            scrubPlayer()
            shot("r05-sample-player")
            info("r05: bundled-demo player UI only; no hosted page, real room, or reconstruction was validated")
            popToRoot()
        }
    }

    // MARK: r06 — the Profile tab

    /// The agent card a reviewer is asked to fill in — the card that rides on
    /// every published tour and collects the leads.
    private func step06Profile() {
        activity("r06 — Profile tab") {
            popToRoot()
            guard openProfileTab() else {
                note("SKIPPED: no Profile tab.")
                return
            }
            settle(1.5)
            shot("r06-profile")
        }
    }

    // MARK: r07 — Settings, Legal & support

    /// Guideline 1.5 / 5.1.1: the Terms of Service and Privacy Policy links,
    /// plus the two support mailto rows (contact, and reporting AI content or a
    /// tour that should not be public) that Guideline 1.2 / 4.7.1 wants.
    private func step07SettingsLegal() {
        activity("r07 — Settings · Legal & support") {
            popToRoot()
            guard openSettingsTab() else {
                note("SKIPPED: no Settings tab.")
                return
            }
            scrollToTop()
            if scrollTo(ids: [], labels: ["Legal & support", "Terms of Service"], swipes: 10) == nil {
                note("Neither the \"Legal & support\" header nor \"Terms of Service\" scrolled into "
                     + "view — capturing Settings as it stands.")
            }
            settle(1.5)
            shot("r07-settings-legal")
        }
    }

    // MARK: r08 + r09 — in-app account deletion

    /// Guideline 5.1.1(v): an account-based app must let people delete their
    /// account FROM INSIDE the app. r08 is the row; r09 is the confirmation it
    /// raises.
    ///
    /// In `SettingsView` the row lives under the "Your data" header (next to
    /// "AI processing" and "Clear data on this phone"), not under the "Account"
    /// header — the account rows above it are sign in / sign out / watch the
    /// intro again. Both headers are searched so the step survives either
    /// arrangement.
    ///
    /// SAFETY: the alert is dismissed with `confirmDeletionIsNeverTapped`,
    /// which contains "Cancel" and nothing else. `deleteAccount()` calls the
    /// live server (`Config.useLiveBackend && Config.enableAuth`, neither of
    /// which `-uiTesting` turns off), so the "Delete" button is genuinely
    /// destructive even in this walk.
    private func step08And09DeleteAccount() {
        activity("r08 — Settings · Delete account") {
            popToRoot()
            guard openSettingsTab() else {
                note("SKIPPED: no Settings tab, so r08 and r09 are both unreachable.")
                return
            }
            scrollToTop()
            guard let row = scrollTo(ids: [], labels: ["Delete account"], swipes: 10) else {
                note("SKIPPED: no \"Delete account\" button in Settings. Guideline 5.1.1(v) needs "
                     + "one — check SettingsView's \"Your data\" section.")
                return
            }
            settle(1)
            shot("r08-delete-account")

            activity("r09 — Delete account confirmation") {
                tap(row)                    // ONCE. Never again in this test.
                guard waitForAny(ids: [],
                                 labels: ["Delete account?", "Sign in to delete your account"],
                                 timeout: shortTimeout + 3) else {
                    note("SKIPPED: tapping \"Delete account\" raised no confirmation dialog within "
                         + "\(Int(shortTimeout) + 3)s. Nothing was confirmed.")
                    dismissDeleteDialogSafely()
                    return
                }
                settle(1)
                shot("r09-delete-confirm")
                dismissDeleteDialogSafely()
            }
        }
    }

    /// Leave the delete flow without deleting anything.
    ///
    /// Only the alert's exact Cancel button is permitted. No allow-by-exclusion
    /// fallback: an unknown button could also destroy data. Failure leaves the
    /// dialog open and fails the gate; it never confirms or clears anything.
    private func dismissDeleteDialogSafely() {
        for title in confirmDeletionIsNeverTapped {
            let button = app.alerts.firstMatch.buttons[title]
            if button.exists && button.isHittable {
                button.tap()
                settle(1)
                XCTAssertFalse(app.alerts.firstMatch.exists, "Delete confirmation did not dismiss after Cancel")
                return
            }
        }
        note("The delete dialog offered nothing safe to press, so it is LEFT OPEN on purpose. "
             + "NOTHING was confirmed. Missing Cancel is a release-gate failure.")
    }

    // MARK: r10 — the sign-in gate

    /// The Sign in with Apple sheet a reviewer meets when they try to publish
    /// or open an AI tool without an account.
    ///
    /// EXPECTED TO SKIP under this walk, and that is not a defect. `AuthStore`
    /// reads `Config.isUITesting` and reports `isSignedIn == true` for the
    /// whole run (Auth/AuthStore.swift), so `FlythroughDetailView.needsSignIn`
    /// is false, Settings draws "Sign out" instead of "Sign in with Apple", and
    /// no path raises `SignInView`. Signing in for real needs an Apple ID on
    /// the simulator, which no automated walk can supply.
    ///
    /// The attempt is still made — if the `-uiTesting` auth shortcut is ever
    /// removed, this step starts producing the shot with no edit here — and the
    /// note tells the integrator to capture it by hand on a device instead.
    private func step10SignInGate() {
        activity("r10 — Sign-in gate") {
            popToRoot()
            guard openSettingsTab() else {
                note("SKIPPED: no Settings tab.")
                return
            }
            scrollToTop()
            guard let signIn = scrollTo(ids: [], labels: ["Sign in with Apple"], swipes: 8) else {
                scrollToTop()
                guard app.launchArguments.contains("-uiTesting"),
                      scrollTo(ids: [], labels: ["Sign out"], swipes: 8) != nil else {
                    note("r10 may be excluded only when the identified mock visibly shows Sign out")
                    return
                }
                info("EXPECTED EXCLUSION r10: -uiTesting uses an identified mock and Settings shows Sign out. Sign-in UI is NOT counted as covered; capture it separately on a device.")
                return
            }
            tap(signIn)
            guard waitForAny(ids: [],
                             labels: ["Sign in to publish", "Sign in to use", "Sign in with Apple"],
                             timeout: screenTimeout) else {
                note("SKIPPED: tapped \"Sign in with Apple\" but no sign-in sheet appeared.")
                dismissTopScreen()
                return
            }
            settle(1.5)
            shot("r10-signin-gate")
            dismissTopScreen()              // never authenticate; just photograph the gate
            popToRoot()
        }
    }

    // MARK: r11 — the AI third-party processing consent

    /// Guideline 5.1.2(i): the disclosure that names every processor the media
    /// is sent to, and asks for explicit permission BEFORE the first
    /// transmission. This is the screen a reviewer looks hardest for in an AI
    /// app, and it is why this walk passes no consent override.
    ///
    /// Reached the way a new user reaches it: Home → "Take photos"
    /// (`home.feature.photos`) → the "Name this home first" gate → "Save and
    /// continue" lands in `PhotoStudioView`, whose `.task` calls
    /// `AIConsent.shared.ensureGranted()` and whose `.aiConsentGate()` overlay
    /// draws `AIConsentView` while it waits.
    ///
    /// Exercise both decisions in the mock-only app: decline must return Home;
    /// reopening must ask again; agreement must reveal the studio. No edit,
    /// provider request, camera, microphone or purchase action is started.
    private func step11AIConsent() {
        activity("r11 — AI processing consent") {
            popToRoot()
            guard openHomeTab(), waitForHome(timeout: screenTimeout) else {
                note("SKIPPED: Home tab unavailable, so there is no \"Take photos\" tile to open.")
                return
            }
            scrollToTop()
            guard let tile = scrollTo(ids: ["home.feature.photoStudio"],
                                      labels: ["AI Photo Studio"], swipes: 6) else {
                note("SKIPPED: no AI Photo Studio tile on Home, so the studio — and the "
                     + "consent sheet at its door — cannot be reached.")
                return
            }
            tap(tile)
            nameFirstProjectIfAsked()

            guard waitForAny(ids: [],
                             labels: ["Rendprop's AI runs in the cloud", "Agree and continue"],
                             timeout: screenTimeout) else {
                if waitForAny(ids: [], labels: ["AI Photo Studio"], timeout: shortTimeout) {
                    note("The studio opened without consent despite the explicit NO launch argument. "
                         + "The required disclosure gate failed; do not erase or reinstall the app.")
                    popToRoot()
                } else {
                    note("SKIPPED: neither the consent sheet nor the AI Photo Studio appeared after "
                         + "the \"Take photos\" gate.")
                }
                return
            }
            settle(1.5)
            shot("r11-ai-consent")

            // Existence or partial window intersection is not reachability.
            // The historical r11 image had the floating tab bar across Agree.
            // Scroll the disclosure itself and require fully visible controls.
            XCTAssertFalse(app.tabBars.firstMatch.exists,
                           "The tab bar must not cover the consent disclosure")
            guard consentAction("aiConsent.agree") != nil,
                  let notNow = consentAction("aiConsent.decline") else { return }
            XCTAssertGreaterThanOrEqual(notNow.frame.height, 44,
                                        "Decline needs a full-size tap target")
            shot("r11b-consent-actions")
            notNow.tap()
            XCTAssertTrue(waitForHome(timeout: screenTimeout),
                          "Declining consent must leave the studio and return Home")
            XCTAssertFalse(app.navigationBars["AI Photo Studio"].exists,
                           "Declining must dismiss the studio, not merely hide its overlay")
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "aiConsent.root").firstMatch.exists,
                           "Declining must remove the disclosure")
            XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: shortTimeout),
                          "Declining must restore the tab bar")

            guard let reopen = scrollTo(ids: ["home.feature.photoStudio"],
                                        labels: [], swipes: 8) else {
                note("Cannot reopen AI Photo Studio after declining consent")
                return
            }
            tap(reopen)
            nameFirstProjectIfAsked()
            let disclosure = app.descendants(matching: .any).matching(identifier: "aiConsent.root").firstMatch
            XCTAssertTrue(disclosure.waitForExistence(timeout: screenTimeout),
                          "Declining must not silently grant consent on reopening")
            guard let agree = consentAction("aiConsent.agree") else { return }
            agree.tap()
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                 object: disclosure)
            XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: screenTimeout), .completed,
                           "Agreement must remove the disclosure")
            XCTAssertTrue(app.navigationBars["AI Photo Studio"].exists,
                          "Agreement must keep the user in AI Photo Studio")
            XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: shortTimeout),
                          "Agreement must restore the tab bar")
            shot("r11c-consent-granted")
            popToRoot()
        }
    }

    /// Checks the real scroll viewport, not just any intersection with a window.
    /// A bounded failure remains a test failure; no coordinate fallback can hit
    /// a different action beneath an obstructing native toolbar.
    private func consentAction(_ identifier: String) -> XCUIElement? {
        let scrolls = app.scrollViews.matching(identifier: "aiConsent.root")
        let scroll = scrolls.firstMatch
        guard scroll.waitForExistence(timeout: screenTimeout) else {
            note("Consent scroll view is missing")
            return nil
        }
        guard scrolls.count == 1 else {
            note("Consent must expose exactly one identified scroll viewport")
            return nil
        }
        let action = scroll.buttons[identifier]
        for attempt in 0...8 {
            if action.exists, action.isEnabled, action.isHittable,
               action.frame.width > 0, action.frame.height > 0,
               scroll.frame.contains(action.frame) {
                return action
            }
            guard attempt < 8 else { break }
            scroll.swipeUp()
            settle(0.35)
        }
        note("Consent action is not fully visible and hittable: \(identifier)")
        return nil
    }

    // MARK: - Navigation helpers

    private func waitForHome(timeout: TimeInterval) -> Bool {
        waitForAny(ids: ["home.addHome"], labels: ["Make something"], timeout: timeout)
    }

    /// CAREFUL with the confirming labels: "Add a home" and "My Homes" appear
    /// on BOTH the Home dashboard and the Homes tab, so either would make
    /// `openTab` report success without switching tab. Only `home.addHome` and
    /// "Make something" are unique to the dashboard.
    @discardableResult
    private func openHomeTab() -> Bool {
        openTab("Home", ids: ["home.addHome"], confirmedBy: ["Make something"])
    }

    @discardableResult
    private func openSettingsTab() -> Bool {
        openTab("Settings", ids: [], confirmedBy: ["Plan & usage", "Business type", "Legal & support"])
    }

    @discardableResult
    private func openProfileTab() -> Bool {
        openTab("Profile", ids: [], confirmedBy: ["Set up your card", "Set up card", "Edit card"])
    }

    /// The second tab. Its title is the current business type's plural
    /// (`SpaceType.spaceNounCap + "s"`), which is "Homes" on the real-estate
    /// default this walk accepts — but every other type is tried so a run that
    /// picked something else still works.
    ///
    /// Tapped directly rather than through `openTab`: every label this screen
    /// shows also exists on the Home dashboard, so no text could confirm the
    /// switch really happened.
    @discardableResult
    private func openSpacesTab() -> Bool {
        for title in ["Homes", "Venues", "Places", "Stores", "Studios", "Spaces"] {
            let tab = app.tabBars.buttons[title]
            if tab.waitForExistence(timeout: 1.0) {
                tab.tap()
                settle(1.5)
                // A tapped tab is not proof that its collection opened.
                if !app.searchFields.firstMatch.waitForExistence(timeout: shortTimeout) {
                    app.swipeDown()
                    return app.searchFields.firstMatch.waitForExistence(timeout: shortTimeout)
                }
                return true
            }
        }
        return false
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

    /// Open the first seeded SAMPLE listing from the second tab. On a fresh
    /// install every row there is a sample, and their addresses all end in
    /// "(Sample)".
    private func openFirstSampleHome() -> Bool {
        guard openSpacesTab() else { return false }
        scrollToTop(4)
        // Exact sample-address suffix, never a broad "Sample" container.
        // Lazy List rows may not exist until they have scrolled into view.
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", "(Sample)")
        for attempt in 0...10 {
            for query in [app.cells, app.buttons, app.staticTexts] {
                for element in query.matching(predicate).allElementsBoundByIndex where element.isHittable {
                    tap(element)
                    if waitForAny(ids: [], labels: ["This is a sample", "SAMPLE TOUR"], timeout: shortTimeout) {
                        return true
                    }
                }
            }
            guard attempt < 10 else { break }
            let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
            if list.exists { list.swipeUp() } else { app.swipeUp() }
            settle(0.4)
        }
        return false
    }

    /// The "which home?" gate. With no real home yet it asks for a name first;
    /// typing one and confirming lands straight in the tapped feature. A no-op
    /// when the gate did not appear.
    private func nameFirstProjectIfAsked() {
        if app.navigationBars["Pick a home"].waitForExistence(timeout: 1) {
            guard let fixture = scrollTo(ids: [], labels: [walkAddress, "1 Walk Test Street"], swipes: 6) else {
                note("Project picker has no known synthetic walk project; refusing to choose another listing")
                return
            }
            tap(fixture)
            return
        }
        guard waitForAny(ids: [], labels: ["Name this home first", "Save and continue"],
                         timeout: shortTimeout + 2) else { return }
        typeAddressIntoFirstField()
        dismissKeyboard()
        if let save = find(ids: [], labels: ["Save and continue"], timeout: shortTimeout) {
            tap(save)
        } else {
            note("New-project Save and continue control is missing")
        }
    }

    private func typeAddressIntoFirstField() {
        let named = app.textFields["Type the home's address"]
        let field = named.exists ? named : app.textFields.firstMatch
        guard field.waitForExistence(timeout: shortTimeout) else { note("New-project address field is missing"); return }
        field.tap()
        settle(0.4)
        field.typeText(walkAddress)
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

    /// Drag inside the tour player so the frame is mid-flight rather than the
    /// poster frame. The player scrubs on scroll and the web view swallows the
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
        return nil
    }

    /// Scroll back to the top of the current screen.
    ///
    /// LOAD-BEARING: `scrollTo` only ever walks DOWN the page, so a step that
    /// needs something ABOVE where the previous one left off — "Delete account"
    /// sits above "Legal & support" in Settings — never finds it without this.
    private func scrollToTop(_ swipes: Int = 8) {
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
        return window.frame.intersects(frame) && element.isHittable
    }

    private func tap(_ element: XCUIElement) {
        guard element.exists else { note("Required tap target disappeared"); return }
        if element.isHittable {
            element.tap()
        } else {
            // Visible to the accessibility tree but not to the hit-tester
            // (mid-animation, or just past the bottom edge).
            app.swipeUp()
            settle(0.35)
            if element.isHittable { element.tap() }
            else { note("Required tap target is not hittable: \(element.identifier) / \(element.label)") }
        }
        settle(0.8)
    }

    // MARK: - Screenshots, activities and waiting

    /// Full-screen capture, status bar included — the same recipe StoreShots
    /// uses, so a reviewer-walk PNG and a store PNG are directly comparable and
    /// the bridge script's 9:41 status-bar override actually shows up.
    private func shot(_ name: String) {
        capturedScreens.insert(name)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func activity(_ name: String, _ body: () -> Void) {
        XCTContext.runActivity(named: name) { _ in body() }
    }

    private func info(_ text: String) {
        XCTContext.runActivity(named: text) { _ in }
    }

    /// Every required step failure remains red even as later screenshots run.
    private func note(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTContext.runActivity(named: "REQUIRED COVERAGE FAILURE: \(text)") { _ in
            XCTFail(text, file: file, line: line)
        }
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
