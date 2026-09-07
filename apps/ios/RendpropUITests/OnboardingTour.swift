//
//  OnboardingTour.swift
//  The NARRATED WALKTHROUGH capture — one slow, deliberate pass through the app
//  for the onboarding video v2 (docs/marketing/onboarding-video-v2/SCRIPT.md).
//  v1's docs/marketing/onboarding-video-script.md documents the earlier cut
//  this test used to drive; that script's segment ids/order no longer match
//  what testOnboardingTour() below produces — v1 stays as a historical record
//  of its own take, not something this file re-cuts on request.
//
//  ONE test — `testOnboardingTour()` — performs the on-screen actions of the
//  script, segment by segment, in SCRIPT.md's order (see that method for the
//  authoritative v2 call order — segments below are not re-sorted in the
//  file to match it, only renumbered), while `bridge-cmd-onboardingtour.sh`
//  records the simulator's screen with `xcrun simctl io recordVideo`. Nothing
//  here takes screenshots: the deliverable is the recording, and this test's
//  job is to make it READ WELL — every action is followed by a pause of
//  1.5–4 s so a viewer can see what just happened, scrolls are slow drags
//  rather than flicks, and sheets are left up for a beat before they are
//  closed.
//
//  WHAT CHANGED FOR v2: a cold open (segment 00 — "Watch the sample tour",
//  filmed FIRST, before Home's own hero beat, since the hosted demo tour is
//  reachable on a cold launch with no home created yet) replaces v1's
//  mid-tour "07 — The tour" beat; "06 — Share the link" is a new beat split
//  out of what v1 folded into "11 — Publish, share, leads" (the Leads
//  banner's own text, read but not tapped); "09/10 — Aerial intro" and
//  "Floor plan" are now two marks instead of one; and the six-industries
//  switch (v1's "02") moves to the END of the tour (now "12"), right before
//  the closing honest line, so the video ends on "and it isn't just for
//  homes" rather than opening with it. v1's segments 05/06 (tag rooms /
//  create the tour) needed no code change at all — they were already here
//  and already correct; they simply had no clip in the simulator's photo
//  library on the run v1 shipped with. Seed one before recording (see the v2
//  README's `xcrun simctl addmedia` step) and they film like everything else.
//
//  THE MARKS. At the start of every segment the test writes one line
//
//      TOUR_MARK <segment-id> <seconds>
//
//  both as an `XCTContext.runActivity` (exported from the .xcresult by the
//  bridge into marks.txt) and as an `NSLog` (a fallback the bridge greps out of
//  the xcodebuild log). `<seconds>` is measured on the RECORDING's clock when
//  the bridge passes `TEST_RUNNER_RECORD_START_EPOCH` (the wall-clock moment it
//  started `recordVideo`), else since `app.launch()`; the line also carries
//  both raw numbers so post can re-derive either. `tools/video/
//  build_onboarding.py` cuts the recording at those marks, lays the narration
//  file for each segment at its mark, and burns the captions in. A final
//  `TOUR_MARK END` closes the last segment. A segment that cannot be reached
//  writes NO mark — the build drops its narration and caption too, so the
//  video never talks about a screen it does not show.
//
//  THINGS THIS TEST NEVER DOES
//
//  1. Never taps a purchase button. v2's narration never speaks a price (they
//     come from StoreKit, not the video) and does not visit the paywall at
//     all, but the StoreKit test environment (same recipe as PaywallShot /
//     IndustryWalk) is still set up below regardless — inherited, harmless,
//     and one less thing to change if a future cut adds the paywall back.
//  2. Never confirms a deletion — no delete flow is even opened.
//  3. Never runs an AI edit, never generates an aerial or a reel, never records
//     a voice take, never publishes. `-uiTesting` means `MockAPIClient`; the
//     two photos it adds go through the on-device Core Image enhancer only.
//     The one render ("Create my tour") is skipped unless the bridge sets
//     `TOUR_RENDER=1` — a simulator render takes a minute and the whole video
//     has a 150-second budget.
//  4. Never asserts. `continueAfterFailure = true`, one `XCTContext.runActivity`
//     per segment, and a step that cannot be reached writes the reason into the
//     result bundle and moves on — the recording is still worth having.
//
//  Element lookup is identifier first (grep `.accessibilityIdentifier(` in
//  apps/ios/Rendprop), visible label second, never coordinates — except the two
//  slow drags (`gentleScroll`, `scrubPlayer`), which are gestures, not taps.
//
//  Launch: `-uiTesting -hasOnboarded YES -appearance light
//  -ai.thirdPartyProcessing.consent.v1 YES` and NO `-space.type`, so the
//  top-left business-type menu can really be driven (an argument-domain value
//  would win over every pick — see IndustryWalk.swift's header). The tour
//  starts in real estate and switches back to it after showing the menu.
//
//  Pauses use `settle()` (an inverted expectation) rather than `Thread.sleep`
//  so the runner's runloop stays alive for the web view and the pickers;
//  `beat(_:)` is the same thing under the name the script uses.
//

import XCTest
import StoreKitTest

final class OnboardingTour: XCTestCase {

    // MARK: - Fixtures

    private var app: XCUIApplication!

    /// StoreKit test environment — verbatim recipe from PaywallShot, so the
    /// paywall renders real plan cards. Optional: with no session the paywall
    /// shows its empty state and the segment says so.
    private var storeKit: SKTestSession?
    private var storeKitNote = ""
    private let configurationName = "Rendprop"

    /// Longest wait for a screen. A cold simulator compiles shaders and seeds
    /// the sample listings on the first launch.
    private let screenTimeout: TimeInterval = 15
    /// Wait for something that should already be there.
    private let shortTimeout: TimeInterval = 3
    /// How long the paywall gets to render a real price before the segment
    /// moves on with the empty state.
    private let productTimeout: TimeInterval = 12
    /// How long an imported walkthrough gets to land on Review & Submit.
    private let importTimeout: TimeInterval = 30

    /// The one real home the tour creates. FAIR HOUSING: a street address and
    /// nothing else — no neighbourhood, no school, no description of people.
    private let tourAddress = "24 Willow Bend Court"

    /// The two clocks a mark can be stamped on (see the file header).
    private var launchDate = Date()
    private var recordStart: Date?
    private var marks: [String] = []

    override func setUpWithError() throws {
        // One unreachable control must not stop the recording being useful.
        continueAfterFailure = true
        // ORDER MATTERS: the StoreKit test environment has to exist before the
        // app launches (PurchaseManager loads products in its first task).
        startStoreKitTestEnvironment()
        if let raw = ProcessInfo.processInfo.environment["RECORD_START_EPOCH"],
           let epoch = Double(raw), epoch > 0 {
            recordStart = Date(timeIntervalSince1970: epoch)
        }
        app = XCUIApplication()
        app.launchArguments = [
            // Mock API client — see Config.isUITesting.
            "-uiTesting",
            // RendpropApp.swift @AppStorage("hasOnboarded") → skip the intro.
            "-hasOnboarded", "YES",
            // Deterministic frames regardless of the simulator's theme.
            "-appearance", "light",
            // Guideline 5.1.2(i) consent — without it the AI screens show the
            // disclosure overlay and dismiss themselves when it is not answered.
            "-ai.thirdPartyProcessing.consent.v1", "YES",
        ]
    }

    override func tearDownWithError() throws {
        app = nil
        storeKit = nil
    }

    // MARK: - The tour

    /// THE AUTHORITATIVE v2 CALL ORDER. This is the order the segments below
    /// are written down in `docs/marketing/onboarding-video-v2/SCRIPT.md` —
    /// NOT the order their private methods sit in this file (those keep
    /// their v1 file position; a method's name and its mark id are what
    /// matter, not where it happens to be typed). `seg12Industries()` in
    /// particular is defined right after `seg01Home()` below (that is where
    /// v1's own "02 — Six industries" used to sit) but is CALLED last, on
    /// purpose — see WHAT CHANGED FOR v2 at the top of this file.
    func testOnboardingTour() {
        if !storeKitNote.isEmpty { note(storeKitNote) }
        if let start = recordStart {
            note(String(format: "CLOCK recording — marks are seconds since RECORD_START_EPOCH=%.3f", start.timeIntervalSince1970))
        } else {
            note("CLOCK launch — no RECORD_START_EPOCH in the environment, marks are seconds since app.launch(); "
                 + "pass --offset to the build for the recording's head.")
        }
        launchDate = Date()
        app.launch()

        seg00Hook()                            // 00 — cold open: "Watch the sample tour", filmed first
        seg01Home()                            // 01 — the hero
        seg02AddHome()                         // 02 — start with the space
        let hasVideo = seg03RecordOrUpload()   // 03 — film or upload the walk
        if hasVideo {
            seg04TagRooms()                    // 04 — tag rooms → chapters
            seg05CreateTour()                  // 05 — create the tour
        } else {
            note("SKIPPED 04 + 05: no walkthrough was imported, so there is no Review & Submit to tag or render. "
                 + "Seed a clip with `xcrun simctl addmedia` (bridge-cmd-onboardingtour.sh does).")
            popToRoot()
        }
        seg06Share()                           // 06 — share the link (the Leads banner, read not tapped)
        let inStudio = seg07PhotoStudio()      // 07 — AI Photo Studio
        seg08Reel(inStudio: inStudio)          // 08 — a reel, in your own voice
        seg09AerialAndFloorPlan()              // 09 + 10 — aerial intro, then floor plan
        seg11LeadsInbox()                      // 11 — leads inbox (same banner, now tapped)
        seg12Industries()                      // 12 — six kinds of space (was v1's "02", moved to the end)
        seg13Close()                           // 13 — the honest line
        mark("END")
        note("MARKS " + marks.joined(separator: " | "))
    }

    // MARK: 00 — Cold open ("Watch the sample tour", filmed before anything else)

    /// The hosted demo tour is `demoSection` on Home — reachable on a cold
    /// launch with no home created yet, for every business type (see
    /// RendpropApp.swift's `demoOpenLink` / `estateDemoFullURL`) — so this
    /// runs FIRST, before `seg01Home()`'s own hero beat, rather than mid-tour
    /// the way v1's `seg07TourPlayer` (this method's ancestor) did. Same
    /// action, same footage either way; only the timing changed.
    private func seg00Hook() {
        activity("00 — Cold open") {
            guard waitForHome(timeout: screenTimeout) else {
                note("Home never appeared within \(Int(screenTimeout))s for the cold open — marking anyway.")
                mark("00")
                return
            }
            scrollToTop()
            mark("00")
            guard let link = scrollTo(ids: [], labels: ["Watch the sample tour"], swipes: 8) else {
                note("SKIPPED: no \"Watch the sample tour\" link on Home for the cold open.")
                beat(2.0)
                return
            }
            tap(link)
            guard waitForAny(ids: [], labels: ["Demo listing page", "Sample tour"], timeout: screenTimeout) else {
                note("SKIPPED: the hosted demo page never opened (it needs network to rendprop.com) — no cold open shot.")
                popToRoot()
                return
            }
            beat(1.0)                   // let the page draw before the drag
            scrubPlayer()                // one slow drag: the house flies as you scroll — THE HOOK
            beat(0.6)
            popToRoot()
        }
    }

    // MARK: 01 — Home

    private func seg01Home() {
        activity("01 — Home") {
            guard waitForHome(timeout: screenTimeout) else {
                note("Home never appeared within \(Int(screenTimeout))s — marking anyway.")
                mark("01")
                return
            }
            ensureRealEstate()          // before the mark: the switch is not part of the take
            settle(1.0)
            mark("01")
            beat(2.5)                   // the hero: "Win the listing. Skip the film crew."
            gentleScroll(down: true)    // reveal "Make something"
            beat(1.5)
            gentleScroll(down: false)   // and back up to the hero
            beat(0.8)
        }
    }

    // MARK: 12 — Six kinds of space (v1's "02" — CALLED LAST, see testOnboardingTour())

    private func seg12Industries() {
        activity("12 — Six kinds of space") {
            scrollToTop()
            mark("12")
            guard let capsule = typeCapsule() else {
                note("SKIPPED: no business-type capsule in Home's navigation bar.")
                beat(3.0)
                return
            }
            capsule.tap()
            beat(2.5)                   // the six types, on screen for a beat
            guard let venue = menuItem("Event venue") else {
                note("SKIPPED: the business-type menu did not list \"Event venue\".")
                closeTypeMenu()
                return
            }
            venue.tap()
            _ = labelElement(containing: "Book the date before", timeout: 6)
            beat(2.5)                   // Home re-themed for a venue
            if let again = typeCapsule() {
                again.tap()
                beat(1.5)
            }
            if let estate = menuItem("Real estate") {
                estate.tap()
            } else {
                note("The menu did not list \"Real estate\" the second time — closing it.")
                closeTypeMenu()
            }
            _ = labelElement(containing: "Win the listing", timeout: 6)
            beat(2.0)
            if currentTypeOnHome()?.raw != "real_estate" {
                note("Home did not return to real estate — relaunching pinned so the rest of the tour is a home.")
                relaunchPinnedToRealEstate()
            }
        }
    }

    // MARK: 02 — Start with the space (v1's "03")

    private func seg02AddHome() {
        activity("02 — Start with the space") {
            scrollToTop()
            mark("02")
            guard let add = scrollTo(ids: ["home.addHome"], labels: ["Add a home"], swipes: 4) else {
                note("SKIPPED: no `home.addHome` and no \"Add a home\" button on Home.")
                beat(3.0)
                return
            }
            tap(add)
            guard waitForAny(ids: [], labels: ["New Home", "Step 1 · The home"], timeout: screenTimeout) else {
                note("SKIPPED: the New Home form did not open.")
                return
            }
            beat(1.5)
            typeIntoField(tourAddress, placeholder: "Type the home's address")
            beat(1.0)
            dismissKeyboard()
            beat(2.0)                   // Step 2 · The video — Upload / Record
        }
    }

    // MARK: 03 — Film or upload the walk (v1's "04" — the walkthrough comes in from Photos)

    /// - Returns: true when the clip imported and Review & Submit is on screen.
    private func seg03RecordOrUpload() -> Bool {
        var imported = false
        activity("03 — Film or upload the walk") {
            mark("03")
            guard let upload = scrollTo(ids: [], labels: ["Upload a video"], swipes: 3) else {
                note("SKIPPED: no \"Upload a video\" button — the address may not have been accepted.")
                beat(3.0)
                return
            }
            tap(upload)
            guard waitForAny(ids: [], labels: ["Where is your video?", "Photos"], timeout: shortTimeout + 2) else {
                note("SKIPPED: the \"Where is your video?\" sheet did not appear.")
                return
            }
            beat(1.5)                   // Photos / Files, on screen
            let sheetButton = app.sheets.buttons["Photos"]
            let photos: XCUIElement? = sheetButton.exists ? sheetButton : find(ids: [], labels: ["Photos"], timeout: shortTimeout)
            guard let photos, photos.isHittable else {
                note("SKIPPED: no \"Photos\" choice on the sheet.")
                dismissTopScreen()
                return
            }
            photos.tap()
            guard let cell = waitForPickerCell(timeout: 8) else {
                note("SKIPPED: the video picker showed no clip — the simulator's library has no video. "
                     + "Seed one with `xcrun simctl addmedia <udid> walkthrough.mp4`.")
                cancelPicker()
                return
            }
            beat(1.5)
            cell.tap()                  // selectionLimit 1: the picker finishes on the tap
            if !waitForAny(ids: [], labels: ["Review & Submit", "YOUR VIDEO"], timeout: 6),
               let add = find(ids: [], labels: ["Add", "Done"], timeout: 1), add.isHittable {
                add.tap()               // an OS build that still wants a confirmation
            }
            guard waitForAny(ids: [], labels: ["Review & Submit", "YOUR VIDEO"], timeout: importTimeout) else {
                note("SKIPPED: the clip was picked but Review & Submit never appeared within \(Int(importTimeout))s.")
                return
            }
            beat(2.0)
            imported = true
        }
        return imported
    }

    // MARK: 04 — Tag rooms, get chapters (v1's "05")

    private func seg04TagRooms() {
        activity("04 — Tag rooms, get chapters") {
            mark("04")
            guard let tagButton = scrollTo(ids: [], labels: ["Tag rooms on the video", "Tag areas on the video"], swipes: 4) else {
                note("SKIPPED: no \"Tag rooms on the video\" button on Review & Submit.")
                beat(3.0)
                return
            }
            tap(tagButton)
            // Labels unique to the tagger sheet — "Tag rooms" alone would also
            // match the Review screen's own button underneath it.
            guard waitForAny(ids: [], labels: ["Scrub to where", "Custom room name", "Custom area name"],
                             timeout: screenTimeout) else {
                note("SKIPPED: the tagger sheet did not open.")
                dismissTopScreen()
                return
            }
            beat(1.5)
            tapQuickTag("Entry")        // a marker at the start of the walk
            beat(1.0)
            scrubTagger(to: 0.55)
            beat(0.8)
            tapQuickTag("Kitchen")
            beat(1.5)                   // two rows in the tag list
            let done = app.buttons["Done"]
            if done.exists && done.isHittable { done.tap() } else { dismissTopScreen() }
            beat(1.5)                   // ROOMS on Review & Submit lists both
        }
    }

    // MARK: 05 — Create the tour (v1's "06")

    private func seg05CreateTour() {
        activity("05 — Create the tour") {
            mark("05")
            let button = scrollTo(ids: [], labels: ["Create my tour"], swipes: 6)
            if button == nil { note("The \"Create my tour\" button never scrolled into view — resting on Review & Submit as it stands.") }
            beat(3.0)                   // PICK YOUR QUALITY + the button
            if ProcessInfo.processInfo.environment["TOUR_RENDER"] == "1", let button, button.isHittable {
                note("TOUR_RENDER=1 — tapping \"Create my tour\" and waiting for the render.")
                tap(button)
                if waitForAny(ids: [], labels: ["View tour", "YOUR TOUR", "Tour ready"], timeout: 150) {
                    beat(3.0)
                } else {
                    note("The render did not finish within 150s — moving on.")
                }
            }
            beat(0.5)
            popToRoot()                 // Review & Submit → New Home → Home; the home and its video stay
        }
    }

    // MARK: 06 — Share the link (split out of v1's "11 — Publish, share, leads";
    // the OTHER half — actually tapping the banner — is seg11LeadsInbox() below,
    // filmed much later so the beats between them get their own footage)

    private func seg06Share() {
        activity("06 — Share the link") {
            popToRoot()
            _ = openHomeTab()
            scrollToTop()
            mark("06")
            guard scrollToLabel(containing: "Opens your leads.", swipes: 6) != nil else {
                note("SKIPPED: no leads banner on Home for the share beat.")
                beat(3.0)
                return
            }
            beat(3.0)                   // "Every tour is one link with a lead form built in." — rest, do not tap yet
            popToRoot()
        }
    }

    // MARK: 07 — AI Photo Studio (v1's "08")

    /// - Returns: true when the studio is on screen at the end of the segment.
    private func seg07PhotoStudio() -> Bool {
        var reached = false
        activity("07 — AI Photo Studio") {
            popToRoot()
            _ = openHomeTab()
            scrollToTop()
            mark("07")
            guard let tile = scrollTo(ids: ["home.feature.photos"], labels: ["Take photos"], swipes: 6) else {
                note("SKIPPED: no \"Take photos\" tile on Home.")
                beat(3.0)
                return
            }
            tap(tile)
            resolveProjectGate()
            guard waitForAny(ids: [], labels: ["AI Photo Studio"], timeout: screenTimeout) else {
                note("SKIPPED: the AI Photo Studio did not open.")
                popToRoot()
                return
            }
            reached = true
            beat(2.5)                   // the one-tap edits: twilight · blue sky · lawn · tidy · furniture
            addTwoPhotosFromLibrary()   // local Core Image only — no AI edit is run
            beat(2.5)                   // a wand on every photo + the disclosure line
        }
        return reached
    }

    // MARK: 08 — A reel, in your own voice (v1's "09")

    private func seg08Reel(inStudio: Bool) {
        activity("08 — A reel, in your own voice") {
            mark("08")
            guard inStudio else {
                note("SKIPPED: the studio was never reached, so its reel card is unreachable too.")
                beat(3.0)
                return
            }
            scrollToTop()
            let card = find(ids: ["detail.reelStudio"], labels: ["Make a reel"], timeout: shortTimeout)
            guard let card, card.isEnabled, card.isHittable else {
                note("The \"Make a reel\" card is disabled (it needs 2 photos) — resting on it instead of opening Reel Studio.")
                beat(4.0)
                return
            }
            tap(card)
            guard waitForAny(ids: [], labels: ["Reel Studio", "PICK PHOTOS"], timeout: screenTimeout) else {
                note("SKIPPED: Reel Studio did not open.")
                beat(2.0)
                return
            }
            beat(1.5)
            if scrollTo(ids: ["reel.step.voice"], labels: ["STEP 2 · ADD YOUR VOICE", "My voice"], swipes: 6) != nil {
                if let myVoice = find(ids: [], labels: ["My voice"], timeout: 2), myVoice.isHittable {
                    myVoice.tap()       // shows the Record pane; nothing is recorded
                }
                beat(3.0)
            } else {
                note("The Voice step never scrolled into view — resting on Reel Studio as it stands.")
                beat(2.0)
            }
            dismissTopScreen()          // Close
            beat(0.5)
        }
    }

    // MARK: 09 + 10 — Aerial intro, then floor plan (v1's single "10")

    /// Two marks from one method, on purpose: nothing else is filmed between
    /// them (see testOnboardingTour()'s call order), so there is no need to
    /// re-open the home's detail screen twice just to give each its own mark.
    private func seg09AerialAndFloorPlan() {
        activity("09/10 — open the home") {
            popToRoot()
            _ = openHomeTab()
            scrollToTop()
        }
        activity("09 — Aerial intro") {
            mark("09")
            guard let row = scrollTo(ids: ["home.listing.first"], labels: [tourAddress], swipes: 4) else {
                note("SKIPPED: no `home.listing.first` row on Home — the tour has no home of its own.")
                beat(3.0)
                return
            }
            tap(row)
            guard waitForAny(ids: ["detail.photoStudio"], labels: ["TOOLBOX"], timeout: shortTimeout + 4) else {
                note("SKIPPED: the home's detail did not open.")
                popToRoot()
                return
            }
            beat(1.0)
            if let aerial = scrollTo(ids: [], labels: ["Aerial intro"], swipes: 8), aerial.isEnabled {
                tap(aerial)
                if waitForAny(ids: [], labels: ["Golden hour", "Rise & reveal"], timeout: screenTimeout) {
                    beat(3.0)           // the shot settings + the AI disclosure
                } else {
                    note("The aerial sheet did not open.")
                }
                dismissTopScreen()      // Close — nothing generated
            } else {
                note("SKIPPED aerial: the \"Aerial intro\" tool card is absent or disabled.")
            }
        }
        activity("10 — Floor plan") {
            mark("10")
            beat(0.5)
            if let plan = scrollTo(ids: [], labels: ["Floor plan"], swipes: 8), plan.isEnabled {
                tap(plan)
                if waitForAny(ids: [], labels: ["Add a floor plan", "Scan one room", "Floor plan ready", "Room plan ready"],
                              timeout: screenTimeout) {
                    beat(2.5)
                } else {
                    note("The Floor plan screen did not open.")
                }
                dismissTopScreen()      // Back
            } else {
                note("SKIPPED floor plan: the \"Floor plan\" tool card is absent or disabled.")
            }
        }
    }

    // MARK: 11 — Leads inbox (the other half of v1's "11" — see seg06Share() above)

    private func seg11LeadsInbox() {
        activity("11 — Leads inbox") {
            popToRoot()
            _ = openHomeTab()
            scrollToTop()
            mark("11")
            guard let banner = scrollToLabel(containing: "Opens your leads.", swipes: 6) else {
                note("SKIPPED: no leads banner on Home for the leads-inbox beat.")
                beat(3.0)
                return
            }
            beat(0.8)
            tap(banner)
            guard waitForAny(ids: [], labels: ["No leads yet", "Loading leads…", "Leads"], timeout: screenTimeout) else {
                note("SKIPPED: the Leads screen did not open.")
                popToRoot()
                return
            }
            beat(3.0)
            popToRoot()
        }
    }

    // MARK: Plans and the free trial (v1's "12") — UNUSED in v2. No price is
    // spoken; the trial is the closing CTA card instead (build_onboarding.py
    // --end-card). Left in place, called from nowhere — the StoreKit
    // environment it needs is already set up in setUpWithError() regardless.
    // NOTE: its own mark("12") below is dead code, never written — v2's real
    // "12" is seg12Industries() above ("Six kinds of space"). Don't call both.

    private func seg12Plans() {
        activity("12 — Plans and the free trial") {
            popToRoot()
            guard openSettingsTab() else {
                note("SKIPPED: no Settings tab.")
                mark("12")
                beat(3.0)
                return
            }
            mark("12")
            scrollToTop()
            if scrollTo(ids: [], labels: ["Plan & usage"], swipes: 8) == nil {
                note("The \"Plan & usage\" header never scrolled into view.")
            }
            beat(1.5)
            guard let upgrade = scrollTo(ids: ["settings.upgradePlan"], labels: ["Upgrade plan"],
                                         swipes: 6, perSwipeTimeout: 0.5) else {
                note("SKIPPED: no `settings.upgradePlan` / \"Upgrade plan\" row (hidden when /me reports a paid plan).")
                beat(2.0)
                return
            }
            tap(upgrade)
            guard waitForAny(ids: ["paywall.root"], labels: ["Turn any phone walkthrough", "Pick a plan"],
                             timeout: screenTimeout) else {
                note("SKIPPED: tapped \"Upgrade plan\" but no `paywall.root` appeared.")
                return
            }
            let loaded = waitForProducts()
            note(loaded ? "Paywall rendered StoreKit prices."
                        : "Paywall EMPTY state — no StoreKit price rendered within \(Int(productTimeout))s. See the STOREKIT note.")
            beat(3.0)                   // the plan cards, on screen
            closePaywall()              // never a purchase button
        }
    }

    // MARK: 13 — The honest line

    private func seg13Close() {
        activity("13 — The honest line") {
            popToRoot()
            _ = openHomeTab()
            scrollToTop()
            mark("13")
            beat(4.0)                   // resting on the hero for the end card
        }
    }

    // MARK: - Marks and pacing

    /// One `TOUR_MARK` line, on the recording's clock when the bridge gave us
    /// one, else since launch. Written as an activity (exported to marks.txt)
    /// and to the console (grep fallback).
    private func mark(_ id: String) {
        let now = Date()
        let sinceLaunch = now.timeIntervalSince(launchDate)
        let seconds = recordStart.map { now.timeIntervalSince($0) } ?? sinceLaunch
        let line = String(format: "TOUR_MARK %@ %.2f sinceLaunch=%.2f epoch=%.3f",
                          id, seconds, sinceLaunch, now.timeIntervalSince1970)
        NSLog("%@", line)
        marks.append(String(format: "%@=%.2f", id, seconds))
        XCTContext.runActivity(named: line) { _ in }
    }

    /// A deliberate on-camera pause. Same mechanism as `settle` — the name says
    /// this one is for the viewer, not for the UI.
    private func beat(_ seconds: TimeInterval) {
        settle(seconds)
    }

    /// A drag through the middle of the screen at a pace a viewer can follow —
    /// no flick, no inertia. Gestures, not taps, so coordinates are allowed.
    /// `down: true` moves the content up (reveals what is below).
    private func gentleScroll(down: Bool) {
        let window = app.windows.firstMatch
        guard window.exists else { return }
        let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.78 : 0.42))
        let to = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.42 : 0.78))
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0.2)
    }

    /// One scroll step for `scrollTo` — about a third of the screen, dragged
    /// rather than flicked, so a search for something further down still reads
    /// as scrolling on camera. Falls back to a flick with no window to drag in.
    private func gentleStep() {
        let window = app.windows.firstMatch
        guard window.exists else { app.swipeUp(); return }
        let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.80))
        let to = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0.1)
    }

    /// Drag slowly inside the tour player so the flythrough advances on camera.
    /// The player scrubs on scroll and the web view swallows the gesture; if it
    /// does not, the page scrolls instead and the shot is still the hosted page.
    private func scrubPlayer() {
        let web = app.webViews.firstMatch
        guard web.exists else { return }
        let from = web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
        let to = web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    // MARK: - StoreKit test environment (verbatim from PaywallShot)

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
            let bundle = Bundle(for: OnboardingTour.self)
            if let url = bundle.url(forResource: configurationName, withExtension: "storekit") {
                do {
                    session = try SKTestSession(contentsOf: url)
                    attempts.append("SKTestSession(contentsOf: \(url.lastPathComponent)) OK")
                } catch {
                    attempts.append("contentsOf \(url.lastPathComponent) failed: \(error.localizedDescription)")
                }
            } else {
                attempts.append("\(configurationName).storekit is NOT in the test bundle — the paywall will show its empty state.")
            }
        }

        guard let session else {
            storeKitNote = "STOREKIT: no test session — the paywall segment shows the empty state. "
                + attempts.joined(separator: " | ")
            return
        }

        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        session.storefront = "USA"
        session.locale = Locale(identifier: "en_US")

        storeKit = session
        storeKitNote = "STOREKIT: test environment up (storefront USA, en_US, dialogs off, transactions cleared). "
            + attempts.joined(separator: " | ")
    }

    // MARK: - The business-type switcher (mirrors IndustryWalk)

    private let typeNames = ["Real estate", "Event venue", "Restaurant / Bar",
                             "Retail / Grocery", "Gym / Studio", "Other business"]

    /// The nav-bar capsule on Home (`HomeDashboardView.businessTypeMenu`): a
    /// Menu whose label is the current type's display name.
    private func typeCapsule() -> XCUIElement? {
        for name in typeNames {
            let predicate = NSPredicate(format: "label BEGINSWITH[c] %@", name)
            let inBar = app.navigationBars.buttons.matching(predicate).firstMatch
            if inBar.exists { return inBar }
        }
        for name in typeNames {
            let predicate = NSPredicate(format: "label BEGINSWITH[c] %@", name)
            let anyButton = app.buttons.matching(predicate).firstMatch
            if anyButton.exists { return anyButton }
        }
        return nil
    }

    /// Which type the capsule shows, as (raw value, display name).
    private func currentTypeOnHome() -> (raw: String, name: String)? {
        guard let capsule = typeCapsule() else { return nil }
        let raws = ["real_estate", "venue", "restaurant", "retail", "fitness", "other"]
        for (raw, name) in zip(raws, typeNames) where capsule.label.hasPrefix(name) {
            return (raw, name)
        }
        return nil
    }

    /// A row of the open business-type menu. SwiftUI's Menu items surface as
    /// buttons / cells / static texts depending on the OS build. The capsule
    /// itself carries the same label as the row for the CURRENT type, so an
    /// element sitting in the capsule's frame is skipped — it is the button
    /// that opened the menu, not a row of it.
    private func menuItem(_ title: String) -> XCUIElement? {
        let capsuleFrame = typeCapsule()?.frame ?? .null
        let predicate = NSPredicate(format: "label ==[c] %@", title)
        let deadline = Date().addingTimeInterval(shortTimeout)
        repeat {
            for query in [app.menuItems, app.buttons, app.cells, app.staticTexts, app.otherElements] {
                for element in query.matching(predicate).allElementsBoundByIndex
                where element.exists && element.isHittable && element.frame != capsuleFrame {
                    return element
                }
            }
            settle(0.3)
        } while Date() < deadline
        return nil
    }

    /// Close an open menu without changing anything: re-pick the current type
    /// (a no-op), else tap the Home tab.
    private func closeTypeMenu() {
        if let current = currentTypeOnHome() {
            let query = app.buttons.matching(NSPredicate(format: "label ==[c] %@", current.name))
            if query.count > 1 {
                query.element(boundBy: 1).tap()
                settle(0.5)
                return
            }
        }
        let home = app.tabBars.buttons["Home"]
        if home.exists && home.isHittable {
            home.tap()
            settle(0.5)
        }
    }

    /// The tour is a real-estate walk. A container left over from another
    /// capture may open in any type; drive the menu back before the first mark.
    private func ensureRealEstate() {
        guard let current = currentTypeOnHome(), current.raw != "real_estate" else { return }
        note("Home came up as \(current.name) — switching to Real estate before the take.")
        scrollToTop()
        guard let capsule = typeCapsule() else { return }
        capsule.tap()
        settle(0.9)
        if let estate = menuItem("Real estate") { estate.tap() } else { closeTypeMenu() }
        _ = labelElement(containing: "Win the listing", timeout: 6)
        settle(1.0)
        if currentTypeOnHome()?.raw != "real_estate" { relaunchPinnedToRealEstate() }
    }

    /// The fallback: `-space.type real_estate` in the argument domain.
    private func relaunchPinnedToRealEstate() {
        app.terminate()
        app.launchArguments += ["-space.type", "real_estate"]
        app.launch()
        _ = waitForHome(timeout: screenTimeout)
        settle(1.5)
    }

    // MARK: - Navigation helpers (mirroring IndustryWalk / ReviewerWalk)

    /// Home is up when its one unmissable action is on screen.
    private func waitForHome(timeout: TimeInterval) -> Bool {
        waitForAny(ids: ["home.addHome"], labels: ["Make something"], timeout: timeout)
    }

    /// CAREFUL with the confirming labels: "Add a home" and "My Homes" appear
    /// on BOTH the Home dashboard and the collection tab, so only `home.addHome`
    /// and "Make something" are unique to the dashboard.
    @discardableResult
    private func openHomeTab() -> Bool {
        openTab("Home", ids: ["home.addHome"], confirmedBy: ["Make something"])
    }

    @discardableResult
    private func openSettingsTab() -> Bool {
        openTab("Settings", ids: [], confirmedBy: ["Plan & usage", "Business type"])
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

    /// The "which home?" gate after a Home feature tile:
    ///   • no home yet → "Name this home first" → type the address → Save and continue
    ///   • two or more → "Pick a home" → the first row
    ///   • exactly one → pushed straight in, nothing to do.
    private func resolveProjectGate() {
        if waitForAny(ids: [], labels: ["Name this home first", "Save and continue"], timeout: shortTimeout) {
            typeIntoField(tourAddress, placeholder: "Type the home's address")
            dismissKeyboard()
            if let save = find(ids: [], labels: ["Save and continue"], timeout: shortTimeout) {
                tap(save)
            }
            return
        }
        if waitForAny(ids: [], labels: ["Pick a home"], timeout: 1.5) {
            note("The \"Pick a home\" picker appeared (two or more homes already exist — a re-run on a dirty "
                 + "simulator). Choosing the first row.")
            let row = app.cells.firstMatch
            if row.waitForExistence(timeout: shortTimeout) { tap(row) }
            return
        }
        // Exactly one home: the studio was pushed directly.
    }

    /// Best effort: bring two photos in from the simulator's library so the reel
    /// card unlocks and the grid shows the wand. PHPicker is a separate process
    /// and a fresh simulator has an empty library, so every stage is allowed to
    /// come up empty. Ingest is on-device Core Image — no AI, no network.
    private func addTwoPhotosFromLibrary() {
        guard let add = find(ids: [], labels: ["Add photos"], timeout: shortTimeout), add.isHittable else {
            note("No \"Add photos\" button — the studio rests on its one-tap-edit showcase.")
            return
        }
        tap(add)
        guard waitForPickerCell(timeout: 8) != nil else {
            note("The simulator's photo library is empty — the studio rests on its one-tap-edit showcase, "
                 + "and the reel card stays disabled. Seed photos with `xcrun simctl addmedia`.")
            cancelPicker()
            return
        }
        settle(1.0)
        // Labelled cells ("Photo, …") when the OS names them, else the first
        // two images of the picker, as StoreShots does.
        let named = app.images.matching(pickerCellLabel)
        let cells: XCUIElementQuery = named.count >= 2 ? named : app.images
        for index in 0..<2 {
            let cell = cells.element(boundBy: index)
            if cell.exists && cell.isHittable { cell.tap(); settle(0.6) }
        }
        if let done = find(ids: [], labels: ["Add", "Done"], timeout: 2), done.isHittable {
            done.tap()
        } else {
            cancelPicker()
        }
        settle(3)                       // ingest writes the files and rebuilds the grid
    }

    /// How PHPicker labels an asset cell on recent iOS builds ("Photo, …",
    /// "Video, twelve seconds, …"). Older builds leave the cells unlabelled.
    private let pickerCellLabel = NSPredicate(format: "label BEGINSWITH[c] 'Video' OR label BEGINSWITH[c] 'Photo'")

    /// The first asset cell of a PHPicker. The picker is out of process; its
    /// cells surface as images. Waits for the picker's OWN navigation-bar
    /// Cancel first, so an image on the screen behind it (the studio's wand,
    /// the form's icons) is never mistaken for a cell.
    private func waitForPickerCell(timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            // The picker's bar has a Cancel; the "Where is your video?" action
            // sheet has one too, so a Cancel only counts once no sheet is up.
            let pickerUp = app.navigationBars.buttons["Cancel"].exists
                || (app.buttons["Cancel"].exists && !app.sheets.firstMatch.exists)
            if pickerUp {
                let named = app.images.matching(pickerCellLabel).firstMatch
                if named.exists && named.isHittable { return named }
                let first = app.images.element(boundBy: 0)
                if first.exists && first.isHittable { return first }
            }
            settle(0.4)
        } while Date() < deadline
        return nil
    }

    /// Leave a picker without choosing anything.
    private func cancelPicker() {
        for cancel in [app.navigationBars.buttons["Cancel"], app.buttons["Cancel"]] where cancel.exists && cancel.isHittable {
            cancel.tap()
            settle(0.8)
            return
        }
        dismissTopScreen()
    }

    /// One chip of the tagger's quick-tag strip (SpaceType.quickTags).
    private func tapQuickTag(_ name: String) {
        let chip = app.buttons[name]
        if chip.waitForExistence(timeout: 2), chip.isHittable {
            chip.tap()
            settle(0.4)
        } else if let any = find(ids: [], labels: [name], timeout: 1), any.isHittable {
            any.tap()
            settle(0.4)
        } else {
            note("The quick tag \"\(name)\" was not on screen.")
        }
    }

    /// Move the tagger's scrubber (a Slider) to a fraction of the clip.
    private func scrubTagger(to fraction: CGFloat) {
        let slider = app.sliders.firstMatch
        guard slider.waitForExistence(timeout: 2) else { return }
        slider.adjust(toNormalizedSliderPosition: fraction)
        settle(0.5)
    }

    private func typeIntoField(_ text: String, placeholder: String) {
        let named = app.textFields[placeholder]
        let field = named.exists ? named : app.textFields.firstMatch
        guard field.waitForExistence(timeout: shortTimeout) else { return }
        field.tap()
        settle(0.4)
        field.typeText(text)
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

    /// Unwind any pushed screens and sheets so the next segment starts from a
    /// tab root. Bounded, so a screen that refuses to dismiss cannot spin.
    private func popToRoot() {
        for _ in 0..<5 {
            let hasBack = app.navigationBars.buttons.count > 0
                && app.navigationBars.buttons.element(boundBy: 0).exists
            let hasSheetButton = ["Close", "Cancel", "Done"].contains {
                app.buttons[$0].exists && app.buttons[$0].isHittable
            }
            guard hasBack || hasSheetButton else { return }
            dismissTopScreen()
        }
    }

    // MARK: - Paywall helpers (verbatim from PaywallShot)

    /// True once a real StoreKit price is on screen. When the empty state
    /// shows first, presses the paywall's OWN "Try again" — a plain product
    /// reload, never a purchase — up to three times inside the same budget.
    private func waitForProducts() -> Bool {
        let deadline = Date().addingTimeInterval(productTimeout)
        var retries = 0
        repeat {
            if let price = waitForLabel(containing: "/month", timeout: 0.5) {
                note("Price rendered: \(String(price.label.prefix(140)))")
                return true
            }
            if retries < 3, let retry = emptyStateRetryButton() {
                retries += 1
                note("The paywall showed \"Plans aren't available right now\" — tapping its own "
                     + "\"Try again\" (\(retries) of 3).")
                tap(retry)
                settle(2)
            }
        } while Date() < deadline
        return false
    }

    /// The paywall's "Try again", only while the unavailable card is showing.
    private func emptyStateRetryButton() -> XCUIElement? {
        guard find(ids: [], labels: ["Plans aren't available right now"], timeout: 0.3) != nil else {
            return nil
        }
        let button = app.buttons["Try again"]
        return button.exists ? button : nil
    }

    /// The sheet's toolbar "Close" (PaywallView, `.cancellationAction`).
    private func closePaywall() {
        let close = app.buttons["Close"]
        guard close.waitForExistence(timeout: shortTimeout), close.isHittable else { return }
        close.tap()
        settle(0.8)
    }

    /// First element of ANY type whose label contains `text` (case-sensitive,
    /// as PaywallShot does for "/month"), polling until `timeout`.
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

    /// First element of ANY type whose label contains `text` (case-insensitive).
    private func labelElement(containing text: String, timeout: TimeInterval) -> XCUIElement? {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", text)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let element = app.descendants(matching: .any).matching(predicate).firstMatch
            if element.exists { return element }
            settle(0.25)
        } while Date() < deadline
        return nil
    }

    /// Scroll down, one gentle step at a time, until the target is actually on
    /// screen — "exists" is not enough for a recording, the thing has to be in
    /// frame. `swipes` is the step budget (same parameter as the other walks).
    private func scrollTo(ids: [String], labels: [String],
                          swipes: Int, perSwipeTimeout: TimeInterval = 0.8) -> XCUIElement? {
        for _ in 0...swipes {
            if let element = find(ids: ids, labels: labels, timeout: perSwipeTimeout),
               isOnScreen(element) {
                return element
            }
            gentleStep()
            settle(0.5)
        }
        if let element = find(ids: ids, labels: labels, timeout: perSwipeTimeout) { return element }
        return nil
    }

    /// Scroll down gently until an element whose label contains `text` is on screen.
    private func scrollToLabel(containing text: String, swipes: Int) -> XCUIElement? {
        for _ in 0...swipes {
            if let element = labelElement(containing: text, timeout: 0.6), isOnScreen(element) {
                return element
            }
            gentleStep()
            settle(0.5)
        }
        return labelElement(containing: text, timeout: 0.6)
    }

    /// Scroll back to the top of the current screen. LOAD-BEARING: `scrollTo`
    /// only ever walks DOWN the page.
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

    // MARK: - Activities and waiting

    private func activity(_ name: String, _ body: () -> Void) {
        XCTContext.runActivity(named: name) { _ in body() }
    }

    /// A line in the result bundle. Named activities are the only place a
    /// non-failing note — and every TOUR_MARK — survives into the `.xcresult`.
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
