//
//  ReviewerWalk.swift
//  The FIRST-RUN capture — what an App Store reviewer sees, in the order they
//  see it (docs/appstore/…, and the review notes the integrator writes).
//
//  ONE test — `testReviewerWalk()` — launches the app the way a reviewer's
//  fresh install launches it and attaches a `keepAlways` screenshot of each
//  screen, named `r01-…` … `r11-…`. `bridge-cmd-reviewerwalk.sh` runs it,
//  uninstalls the app first so UserDefaults really are empty, and exports the
//  PNGs to ~/Rendprop AI/_bridge/out/reviewerwalk/.
//
//  This is NOT the UI walk and NOT the store-shot set. The other two both pass
//  `-hasOnboarded YES` and `-ai.thirdPartyProcessing.consent.v1 YES` so they
//  land straight on Home with every gate already answered. That is exactly the
//  part a reviewer never gets. So this test passes ONLY:
//
//      -uiTesting        → Config.makeAPIClient() returns MockAPIClient
//      -appearance light → deterministic screenshots
//
//  and NOTHING else. No `-hasOnboarded`, so `RendpropApp`'s
//  `@AppStorage("hasOnboarded")` is false and `OnboardingView` is the root. No
//  consent override, so the Guideline 5.1.2(i) disclosure really appears the
//  first time an AI surface is opened — which is the single most-asked-about
//  screen in an AI app's review, and r11 is the proof it exists.
//
//  `-space.type` is deliberately absent too: the default is
//  `SpaceType.realEstate`, which is what the onboarding type picker
//  pre-selects, so the walk simply accepts the default the way a reviewer
//  would.
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
//     would be a misleading screenshot. r11 stops at the consent sheet and
//     declines it.
//  3. Never assert. `continueAfterFailure = true`, one `XCTContext.runActivity`
//     per step, and a step that cannot be reached writes the reason into the
//     result bundle instead of failing the run. Ten good screenshots beat a red
//     test.
//
//  Element lookup is identifier first (grep `.accessibilityIdentifier(` in
//  apps/ios/Rendprop), visible label second, never coordinates.
//

import XCTest

final class ReviewerWalk: XCTestCase {

    // MARK: - Fixtures

    private var app: XCUIApplication!

    /// Longest wait for a screen. A cold simulator compiles shaders and seeds
    /// the sample listings on the first launch.
    private let screenTimeout: TimeInterval = 15
    /// Wait for something that should already be there.
    private let shortTimeout: TimeInterval = 3
    /// How long a hosted page gets in its web view before the shot is taken.
    /// The demo listing page is a real network round trip to rendprop.com.
    private let webTimeout: TimeInterval = 12

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
        // A BRAND-NEW INSTALL. Two arguments, no more. Anything else here
        // would answer a gate the reviewer has to answer themselves, which is
        // the whole point of this capture.
        //   RendpropApp.swift  @AppStorage("hasOnboarded")  → NOT set: the intro shows
        //   AIConsent          "ai.thirdPartyProcessing.consent.v1" → NOT set: r11 shows
        //   RendpropApp.swift  @AppStorage("appearance") / Appearance.light == "light"
        app.launchArguments += [
            "-uiTesting",
            "-appearance", "light",
        ]
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

            note(photographedPicker
                 ? "r01 captured \(screens) onboarding screens: \(screens - 1) feature card(s) "
                   + "plus the \"What do you showcase?\" business-type picker."
                 : "r01 captured \(screens) onboarding screens but never reached the business-type "
                   + "picker within \(maxOnboardingScreens) pages.")
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
    /// Two sources, tried in order:
    ///   a) Home → "Watch the sample tour". On real estate that is a
    ///      `WKWebView` on the HOSTED demo listing page
    ///      (`rendprop.com/f/estate-demo`, nav title "Demo listing page") —
    ///      the whole auto-built microsite a shared link opens. It needs the
    ///      simulator to have network and the tour-host worker deployed.
    ///   b) The sample detail's own bundled player, scrubbed. It falls back to
    ///      "sample video unavailable" unless `demo.mp4` was dropped into
    ///      Rendprop/Resources/player/ (untracked — see apps/web/player/README.md),
    ///      so the activity says so when this path is used.
    private func step05SamplePlayer(reachedSampleDetail: Bool) {
        activity("r05 — Sample tour player") {
            popToRoot()
            if openHomeTab() {
                scrollToTop()
                if let link = scrollTo(ids: [], labels: ["Watch the sample tour"], swipes: 8) {
                    tap(link)
                    if waitForAny(ids: [], labels: ["Demo listing page"], timeout: screenTimeout) {
                        settle(webTimeout)          // a real download
                        shot("r05-sample-player")
                        popToRoot()
                        return
                    }
                    note("Tapped \"Watch the sample tour\" but the hosted demo page never titled "
                         + "itself \"Demo listing page\".")
                    popToRoot()
                }
            }

            guard reachedSampleDetail || openFirstSampleHome() else {
                note("SKIPPED: neither Home's \"Watch the sample tour\" link nor a sample home's "
                     + "detail was reachable, so there is no player to capture.")
                return
            }
            settle(2)
            scrubPlayer()
            shot("r05-sample-player")
            note("r05 came from the in-app sample player, not the hosted demo. If it shows "
                 + "\"sample video unavailable\", the bundled demo.mp4 is absent (it is untracked).")
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
    /// Cancel first. If the dialog somehow has no Cancel, press the first
    /// button that is NOT one of the data-destroying ones — the "Sign in to
    /// delete your account" variant, for instance, offers "Clear this phone
    /// only", which is every bit as destructive as "Delete". If nothing safe is
    /// on offer, the dialog is left standing on purpose; a stuck walk is a far
    /// better outcome than a confirmed deletion.
    private func dismissDeleteDialogSafely() {
        for title in confirmDeletionIsNeverTapped {
            let button = app.buttons[title]
            if button.exists && button.isHittable {
                button.tap()
                settle(1)
                return
            }
        }
        let destroysData = ["Delete", "Clear", "Erase", "Remove", "Confirm", "Sign out"]
        let alertButtons = app.alerts.firstMatch.buttons
        for index in 0..<alertButtons.count {
            let button = alertButtons.element(boundBy: index)
            guard button.exists, button.isHittable else { continue }
            let label = button.label
            if destroysData.contains(where: { label.localizedCaseInsensitiveContains($0) }) { continue }
            note("The delete dialog had no \"Cancel\" — leaving it through \"\(label)\", which is "
                 + "none of its destructive buttons. NOTHING was confirmed.")
            button.tap()
            settle(1)
            return
        }
        note("The delete dialog offered nothing safe to press, so it is LEFT OPEN on purpose. "
             + "NOTHING was confirmed. Later steps will find it in the way and skip themselves.")
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
                note("SKIPPED (expected): the app reports itself signed in for the whole run — "
                     + "AuthStore sets `isSignedIn = Config.isUITesting ? true : …`, so no publish "
                     + "or AI path raises SignInView and Settings shows \"Sign out\" instead. "
                     + "Capture the sign-in sheet by hand on a real device for the review notes.")
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
    /// Then "Not now" — declining is what `PhotoStudioView` handles by
    /// dismissing itself, and it leaves the consent flag false so a re-run
    /// captures the same sheet again. NO AI EDIT IS EVER RUN.
    private func step11AIConsent() {
        activity("r11 — AI processing consent") {
            popToRoot()
            guard openHomeTab(), waitForHome(timeout: screenTimeout) else {
                note("SKIPPED: Home tab unavailable, so there is no \"Take photos\" tile to open.")
                return
            }
            scrollToTop()
            guard let tile = scrollTo(ids: ["home.feature.photos"],
                                      labels: ["Take photos"], swipes: 6) else {
                note("SKIPPED: no \"Take photos\" tile on Home, so the AI Photo Studio — and the "
                     + "consent sheet at its door — cannot be reached.")
                return
            }
            tap(tile)
            nameFirstProjectIfAsked()

            guard waitForAny(ids: [],
                             labels: ["Rendprop's AI runs in the cloud", "Agree and continue"],
                             timeout: screenTimeout) else {
                if waitForAny(ids: [], labels: ["AI Photo Studio"], timeout: shortTimeout) {
                    note("SKIPPED: the studio opened with NO consent sheet. That means the consent "
                         + "was already granted on this simulator — uninstall the app before the "
                         + "run (bridge-cmd-reviewerwalk.sh does) so "
                         + "\"ai.thirdPartyProcessing.consent.v1\" is genuinely unset.")
                    popToRoot()
                } else {
                    note("SKIPPED: neither the consent sheet nor the AI Photo Studio appeared after "
                         + "the \"Take photos\" gate.")
                }
                return
            }
            settle(1.5)
            shot("r11-ai-consent")

            // Decline. `PhotoStudioView` dismisses itself on false, and the
            // flag stays unset so the next run sees the same sheet.
            if let notNow = find(ids: [], labels: ["Not now"], timeout: shortTimeout) {
                tap(notNow)
            } else {
                note("The consent sheet had no \"Not now\" — backing out instead. NOTHING was agreed.")
                dismissTopScreen()
            }
            settle(1)
            popToRoot()
        }
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
                // Soft confirmation only: the collection is the one tab with a
                // search field. The tap happened either way, so the caller
                // still gets true and the screenshot is still taken.
                if !app.searchFields.firstMatch.waitForExistence(timeout: shortTimeout) {
                    note("Tapped the \"\(title)\" tab but its search field never appeared — the "
                         + "shot may be whatever tab was already showing.")
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
        settle(1.5)
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", "Sample")
        for query in [app.buttons, app.cells, app.otherElements] {
            let element = query.matching(predicate).firstMatch
            if element.exists {
                tap(element)
                return waitForAny(ids: [],
                                  labels: ["TOOLBOX", "SAMPLE TOUR", "This is a sample"],
                                  timeout: screenTimeout)
            }
        }
        return false
    }

    /// The "which home?" gate. With no real home yet it asks for a name first;
    /// typing one and confirming lands straight in the tapped feature. A no-op
    /// when the gate did not appear.
    private func nameFirstProjectIfAsked() {
        guard waitForAny(ids: [], labels: ["Name this home first", "Save and continue"],
                         timeout: shortTimeout + 2) else { return }
        typeAddressIntoFirstField()
        dismissKeyboard()
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
        if let element = find(ids: ids, labels: labels, timeout: perSwipeTimeout) { return element }
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

    /// Full-screen capture, status bar included — the same recipe StoreShots
    /// uses, so a reviewer-walk PNG and a store PNG are directly comparable and
    /// the bridge script's 9:41 status-bar override actually shows up.
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
