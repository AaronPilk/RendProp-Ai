//
//  StoreShots.swift
//  The App Store screenshot capture (docs/appstore/screenshots/README.md).
//
//  ONE test — `testStoreShots()` — drives a booted 6.9-inch simulator through the
//  screens that sell the app and attaches a `keepAlways` screenshot of each,
//  named `s01-…` … `s15-…`. `bridge-cmd-storeshots.sh` runs it, exports the
//  PNGs, and checks every one is exactly 1320 × 2868. The raw captures are
//  then framed (headline + brand background) by tools/screenshots/compose.py
//  following docs/appstore/screenshots/plan.json, which also says which of
//  them the store set actually uses.
//
//  TWO WAVES. s01–s08 are the real-estate set, launched pinned to
//  `-space.type real_estate`. s12–s15 add the tools a real home unlocks (reel
//  entry, floor plan), the leads inbox and the share surfaces. s09–s11 are
//  Home for the other business types (venue, restaurant, gym) and come LAST:
//  a `-key value` launch argument lands in UserDefaults' argument domain,
//  which wins over anything the top-left switcher persists, so those three
//  relaunch the app WITHOUT `-space.type` and drive the switcher the way a
//  user does (IndustryWalk.swift explains this in full). If the menu cannot
//  be driven the step relaunches pinned to that type and says so.
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
//  3. THE PAYWALL IS NEVER CAPTURED HERE. This test attaches no StoreKit
//     configuration, so `Product.products(for:)` returns an empty array and the
//     paywall correctly renders "Plans aren't available right now". That empty
//     state must never reach the App Store. The IAP review screenshot comes
//     from `PaywallShot.swift`, which opens an `SKTestSession` first so the
//     real prices render — see docs/appstore/iap-review/README.md.
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

    /// One business type as the Home switcher shows it. `displayName` is the
    /// capsule's label and the menu row; `heroLine1` is the first line of
    /// `SpaceType.heroHeadline`, which is how the capture knows Home really
    /// re-themed. Both copied from Models/Listing.swift, never invented.
    /// `shotName` is nil for the types the store set does not use.
    private struct StoreIndustry {
        let raw: String
        let displayName: String
        let heroLine1: String
        let shotName: String?
    }

    /// `SpaceType.allCases`, in order. Venue, restaurant and gym are the three
    /// the store's industry frame shows (docs/appstore/screenshots/plan.json).
    private let industries: [StoreIndustry] = [
        StoreIndustry(raw: "real_estate", displayName: "Real estate",
                      heroLine1: "Win the listing.", shotName: nil),
        StoreIndustry(raw: "venue", displayName: "Event venue",
                      heroLine1: "Book the date before", shotName: "s09-venue-home"),
        StoreIndustry(raw: "restaurant", displayName: "Restaurant / Bar",
                      heroLine1: "Fill the room before", shotName: "s10-restaurant-home"),
        StoreIndustry(raw: "retail", displayName: "Retail / Grocery",
                      heroLine1: "Get them in the door", shotName: nil),
        StoreIndustry(raw: "fitness", displayName: "Gym / Studio",
                      heroLine1: "Sell the feeling", shotName: "s11-gym-home"),
        StoreIndustry(raw: "other", displayName: "Other business",
                      heroLine1: "Show your space", shotName: nil),
    ]

    /// Identical to RendpropUITests.setUpWithError() — same mock backend, same
    /// skipped gates, same deterministic light appearance — minus the business
    /// type, which `setUpWithError` pins to real estate and
    /// `step09to11IndustryHomes` drops again. Keys verified against source:
    /// RendpropApp.swift @AppStorage("hasOnboarded"), RootTabView
    /// @AppStorage("space.type"), @AppStorage("appearance"), AIConsent
    /// "ai.thirdPartyProcessing.consent.v1".
    private var baseLaunchArguments: [String] {
        var args = [
            "-uiTesting",
            "-hasOnboarded", "YES",
            "-appearance", "light",
            "-ai.thirdPartyProcessing.consent.v1", "YES",
            "-ui.sampleLeads",       // the mock's three invented leads (s14)
        ]
        // STORESHOT_PHOTOS (bridge-cmd-storeshots.sh passes it as
        // TEST_RUNNER_STORESHOT_PHOTOS): a folder of seed photos the studio
        // imports itself, since the system picker cannot be driven. With it,
        // s04 shows photos in the studio and s05 (Reel Studio) can open.
        if let dir = ProcessInfo.processInfo.environment["STORESHOT_PHOTOS"], !dir.isEmpty {
            args += ["-ui.seedPhotosDir", dir]
        }
        return args
    }

    override func setUpWithError() throws {
        // Fifteen screenshots. One unreachable control must not cost us the
        // other fourteen.
        continueAfterFailure = true

        app = XCUIApplication()
        app.launchArguments += baseLaunchArguments + ["-space.type", "real_estate"]
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
        // The second wave — see the file header. Everything that needs the real
        // home step 04 created comes first; the industry switch relaunches the
        // app, so it goes last.
        step12ReelStudioEntry()
        step13FloorPlan()
        step14Leads()
        step15ShareLink()
        step09to11IndustryHomes()
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
            // With STORESHOT_PHOTOS the studio imports the seed photos itself
            // (on-device enhance only, NO AI EDIT IS EVER RUN here); wait for
            // its "Working on your photo…" cover to clear so the grid is up.
            // Without it, the studio's own showcase — "Add a photo, then tap one
            // button" and the six one-tap edits — is the store shot: the system
            // photo picker is a separate process that cannot be driven reliably.
            if let dir = ProcessInfo.processInfo.environment["STORESHOT_PHOTOS"], !dir.isEmpty {
                let deadline = Date().addingTimeInterval(25)
                settle(1.0)
                while Date() < deadline, labelElement(containing: "Working on your photo", timeout: 0.3) != nil {
                    settle(0.5)
                }
                note("Seed photos imported from \(dir).")
            }
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

    // MARK: s12 — Reel Studio entry

    /// The way into the reel maker: the real home's TOOLBOX → "Make a reel",
    /// which lands in the studio with the reel card ringed. The card itself
    /// is `.disabled` until the home has two photos and this test adds none
    /// (the system photo picker cannot be driven reliably — see step 04), so
    /// on a clean simulator this is the ENTRY, photographed honestly with the
    /// card's own words on it. When a previous run left two photos on the
    /// home the card is enabled and the Reel Studio itself is captured
    /// instead. Nothing is generated either way.
    private func step12ReelStudioEntry() {
        activity("s12 — Reel Studio entry") {
            popToRoot()
            guard openHomeTab(), waitForHome(timeout: screenTimeout) else {
                note("SKIPPED: Home tab unavailable.")
                return
            }
            scrollToTop()
            guard openFirstRealHome() else {
                note("SKIPPED: no real home on the Home dashboard — step 04 creates one through the "
                     + "\"Take photos\" gate, and every tool is disabled on a sample by design.")
                return
            }
            scrollToTop()
            guard let tile = scrollTo(ids: ["detail.reelStudio"], labels: ["Make a reel"], swipes: 8),
                  tile.isEnabled else {
                note("SKIPPED: the \"Make a reel\" tool card is absent or disabled on this home.")
                popToRoot()
                return
            }
            tap(tile)
            guard waitForAny(ids: [], labels: ["AI Photo Studio"], timeout: screenTimeout) else {
                note("SKIPPED: the studio did not open from the reel tile.")
                popToRoot()
                return
            }
            settle(1.5)
            // Inside the studio the same identifier is the reel card (ringed,
            // because we arrived through the reel tile). Only a HITTABLE match
            // counts: the toolbox tile underneath may still be in the tree.
            if let card = hittableElement(id: "detail.reelStudio"), card.isEnabled {
                tap(card)
                if waitForAny(ids: [], labels: ["Reel Studio"], timeout: screenTimeout) {
                    settle(1.5)
                    shot("s12-reel-studio")
                    note("s12 is the Reel Studio itself — this home already had two photos.")
                    dismissTopScreen()          // Close → back to the studio
                    popToRoot()
                    return
                }
                note("Tapped the enabled reel card but Reel Studio did not open — capturing the studio entry instead.")
            } else {
                note("The reel card is disabled (it needs 2 photos on this home and the test adds none), "
                     + "so s12 is the studio with the reel card ringed — the entry, not the Reel Studio itself.")
            }
            shot("s12-reel-studio")
            popToRoot()
        }
    }

    // MARK: s13 — Floor plan

    /// The Floor plan screen from the real home's TOOLBOX. A simulator has no
    /// LiDAR, so this is the upload-a-blueprint path and the screen says so —
    /// the note below tells the reader that a store-worthy version of this
    /// screen comes from a LiDAR iPhone, where it reads "Scan one room".
    private func step13FloorPlan() {
        activity("s13 — Floor plan") {
            popToRoot()
            guard openHomeTab(), waitForHome(timeout: screenTimeout) else {
                note("SKIPPED: Home tab unavailable.")
                return
            }
            scrollToTop()
            guard openFirstRealHome() else {
                note("SKIPPED: no real home on the Home dashboard (step 04 creates it).")
                return
            }
            scrollToTop()
            guard let tile = scrollTo(ids: [], labels: ["Floor plan"], swipes: 8), tile.isEnabled else {
                note("SKIPPED: the \"Floor plan\" tool card is absent or disabled on this home.")
                popToRoot()
                return
            }
            tap(tile)
            guard waitForAny(ids: [],
                             labels: ["Add a floor plan", "Scan one room", "Room plan ready", "Floor plan ready"],
                             timeout: screenTimeout) else {
                note("SKIPPED: the Floor plan screen did not open.")
                popToRoot()
                return
            }
            settle(1)
            shot("s13-floor-plan")
            if find(ids: [], labels: ["Add a floor plan"], timeout: 0.5) != nil {
                note("s13 shows the upload path and says the device has no LiDAR — true of every simulator. "
                     + "plan.json leaves it out; capture this screen on a LiDAR iPhone (\"Scan one room\") "
                     + "if the set should carry it.")
            }
            popToRoot()
        }
    }

    // MARK: s14 — Leads

    /// The leads inbox, from Home's leads banner. Under `-uiTesting` the mock
    /// returns no leads, so this is the empty inbox — honest, but a weak
    /// store image, which is why plan.json does not use it by default.
    private func step14Leads() {
        activity("s14 — Leads") {
            popToRoot()
            guard openHomeTab(), waitForHome(timeout: screenTimeout) else {
                note("SKIPPED: Home tab unavailable.")
                return
            }
            scrollToTop()
            guard let banner = scrollToLabel(containing: "Opens your leads.", swipes: 6) else {
                note("SKIPPED: no leads banner on Home.")
                return
            }
            tap(banner)
            // With -ui.sampleLeads the mock answers with three invented leads
            // (the frame plan.json uses); without it, the honest empty inbox.
            let opened = waitForAny(ids: [], labels: ["No leads yet", "Loading leads…", "Sign in to see your leads",
                                                      "Jordan Whitfield", "Priya Raman"],
                                    timeout: screenTimeout)
                || app.navigationBars["Leads"].waitForExistence(timeout: 2)
            guard opened else {
                note("SKIPPED: the Leads screen did not open.")
                popToRoot()
                return
            }
            settle(2)                       // let the list settle (mock latency + animation)
            shot("s14-leads")
            if labelElement(containing: "No leads yet", timeout: 0.5) != nil {
                note("s14 is the empty inbox (launch without -ui.sampleLeads). plan.json expects the sample inbox.")
            } else {
                note("s14 is the sample inbox (-ui.sampleLeads): three invented leads.")
            }
            popToRoot()
        }
    }

    // MARK: s15 — Share link

    /// The share surface. Three sources, tried in order:
    ///   1. A share action on the sample home's own screen. Samples never
    ///      publish (their `serverShareURL` is nil by design), so this is
    ///      expected to miss — it is checked anyway so a build that ever gives
    ///      samples a link is captured the moment it does. Nothing is sent.
    ///   2. The HOSTED demo page (Home → "Watch the sample tour"), scrolled to
    ///      its agent card and lead form: what the person who receives a share
    ///      link sees, and where the leads in s14 come from. Needs network and
    ///      the deployed tour-host worker, like s08.
    ///   3. The Profile tab's card — the card that rides on every published
    ///      tour — when the page never loads.
    private func step15ShareLink() {
        activity("s15 — Share link") {
            popToRoot()
            if openFirstSampleHome() {
                if let share = scrollTo(ids: [], labels: ["Share your link"], swipes: 8, perSwipeTimeout: 0.4) {
                    tap(share)
                    if waitForShareSheet(timeout: shortTimeout + 3) {
                        settle(1.5)
                        shot("s15-share-link")
                        note("s15 is the system share sheet for the sample's link. Nothing was sent.")
                        dismissShareSheet()
                        popToRoot()
                        return
                    }
                    note("Tapped \"Share your link\" but no share sheet appeared.")
                }
                popToRoot()
            }

            if openHomeTab() {
                scrollToTop()
            }
            if let link = scrollTo(ids: [], labels: ["Watch the sample tour"], swipes: 8) {
                tap(link)
                if waitForAny(ids: [], labels: ["Demo listing page", "Sample tour"], timeout: screenTimeout) {
                    settle(webTimeout)      // the hosted page is a real download
                    // The hosted page is a 137 s scroll-scrub track (240 px per
                    // second, ~33,000 px) followed by the listing sections; the
                    // agent card + lead form are the END card. ~420 px a swipe
                    // (measured), so the lead form is ~100 swipes down.
                    if scrollWebPage(toLabelContaining: "Book a showing", swipes: 220, checkEvery: 5) {
                        settle(1.5)
                        shot("s15-share-link")
                        note("s15 is the hosted demo page at its agent card and lead form — what a share "
                             + "link's recipient sees.")
                    } else {
                        shot("s15-share-link")
                        note("Scrolled the hosted demo page but its lead form never came into view — "
                             + "captured the page where the scroll stopped.")
                    }
                    popToRoot()
                    return
                }
                note("Tapped \"Watch the sample tour\" but the hosted demo page never titled itself.")
                popToRoot()
            }

            note("Falling back to the Profile tab's card — the hosted demo needs network plus a "
                 + "deployed tour-host worker.")
            guard openProfileTab() else {
                note("SKIPPED: no Profile tab either. Nothing to capture for s15.")
                return
            }
            settle(1.5)
            shot("s15-share-link")
        }
    }

    // MARK: s09–s11 — Home for the other business types

    /// Relaunch without `-space.type`, then drive Home's top-left menu to each
    /// industry the store frame shows and capture the top of Home. The hero
    /// headline changing is the proof the switch happened; a switch that
    /// cannot be driven falls back to a relaunch pinned to that type.
    private func step09to11IndustryHomes() {
        activity("s09–s11 — Home for the other business types") {
            popToRoot()
            relaunch(pinnedTo: nil)
            guard waitForHome(timeout: screenTimeout) else {
                note("SKIPPED: Home never appeared after relaunching without -space.type.")
                return
            }
            note("Relaunched without -space.type; Home came up as "
                 + "\(currentTypeOnHome()?.displayName ?? "an unrecognised business type").")
            for industry in industries {
                guard let name = industry.shotName else { continue }
                captureIndustryHome(industry, as: name)
            }
            // Leave the simulator the way it was found. Best effort: the next
            // run pins real estate for its own set regardless.
            if let realEstate = industries.first(where: { $0.raw == "real_estate" }),
               !switchType(to: realEstate) {
                note("Could not switch Home back to Real estate at the end — harmless, the next run pins it.")
            }
        }
    }

    private func captureIndustryHome(_ industry: StoreIndustry, as name: String) {
        activity("\(name) — Home · \(industry.displayName)") {
            var themed = switchType(to: industry)
            if !themed {
                note("FALLBACK: the switcher did not move Home to \(industry.displayName) — relaunching "
                     + "pinned to -space.type \(industry.raw).")
                relaunch(pinnedTo: industry.raw)
                themed = labelElement(containing: industry.heroLine1, timeout: screenTimeout) != nil
            }
            guard themed else {
                note("SKIPPED: Home never showed the \(industry.displayName) hero \"\(industry.heroLine1)\".")
                return
            }
            _ = openHomeTab()
            scrollToTop()
            settle(2)                       // the spring re-theme + the sample reseed
            shot(name)
        }
    }

    // MARK: - The business-type switcher (mirroring IndustryWalk)

    /// The nav-bar capsule on Home (`HomeDashboardView.businessTypeMenu`): a
    /// Menu whose label is the current type's display name.
    private func typeCapsule() -> XCUIElement? {
        for industry in industries {
            let predicate = NSPredicate(format: "label BEGINSWITH[c] %@", industry.displayName)
            let inBar = app.navigationBars.buttons.matching(predicate).firstMatch
            if inBar.exists { return inBar }
        }
        for industry in industries {
            let predicate = NSPredicate(format: "label BEGINSWITH[c] %@", industry.displayName)
            let anyButton = app.buttons.matching(predicate).firstMatch
            if anyButton.exists { return anyButton }
        }
        return nil
    }

    /// Which type the capsule shows, read from its label.
    private func currentTypeOnHome() -> StoreIndustry? {
        guard let capsule = typeCapsule() else { return nil }
        let label = capsule.label
        return industries.first { label.hasPrefix($0.displayName) }
    }

    /// Open the capsule's menu and pick `target`. True once Home shows the
    /// target's hero headline. A no-op (still true) when Home already does.
    private func switchType(to target: StoreIndustry) -> Bool {
        _ = openHomeTab()
        scrollToTop()
        if currentTypeOnHome()?.raw == target.raw {
            return labelElement(containing: target.heroLine1, timeout: shortTimeout) != nil
        }
        guard let capsule = typeCapsule() else {
            note("SKIPPED: no business-type capsule in Home's navigation bar.")
            return false
        }
        capsule.tap()
        settle(0.9)
        guard let item = menuItem(target.displayName) else {
            note("SKIPPED: the business-type menu did not list \"\(target.displayName)\".")
            closeTypeMenu()
            return false
        }
        item.tap()
        settle(0.9)
        let themed = labelElement(containing: target.heroLine1, timeout: 6) != nil
        if themed { settle(1.5) }           // the spring re-theme + the sample reseed
        return themed
    }

    /// A row of the open business-type menu. SwiftUI's Menu items surface as
    /// buttons / cells / static texts depending on the OS build, so every
    /// shape is tried.
    private func menuItem(_ title: String) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(shortTimeout)
        repeat {
            for query in [app.menuItems, app.buttons, app.cells, app.staticTexts, app.otherElements] {
                let element = query[title]
                if element.exists && element.isHittable { return element }
            }
            settle(0.3)
        } while Date() < deadline
        return nil
    }

    /// Close an open menu without changing anything: re-pick the current type
    /// (a no-op), else tap the Home tab.
    private func closeTypeMenu() {
        if let current = currentTypeOnHome() {
            let query = app.buttons.matching(NSPredicate(format: "label ==[c] %@", current.displayName))
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

    /// Relaunch with the base arguments, plus `-space.type <raw>` when given.
    /// `nil` drops the pin so the persisted type — whatever the switcher
    /// wrote — is what Home shows.
    private func relaunch(pinnedTo raw: String?) {
        app.terminate()
        app.launchArguments = baseLaunchArguments + (raw.map { ["-space.type", $0] } ?? [])
        app.launch()
        _ = waitForHome(timeout: screenTimeout)
        settle(1.5)
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

    /// Swipe up INSIDE the hosted page's web view until an element whose
    /// label contains `text` is on screen. The web view swallows the gesture,
    /// so this scrolls the page rather than the screen. False when the label
    /// never appeared within `swipes`.
    private func scrollWebPage(toLabelContaining text: String, swipes: Int, checkEvery: Int = 1) -> Bool {
        let web = app.webViews.firstMatch
        guard web.exists else { return false }
        for i in 0...swipes {
            if i % max(1, checkEvery) == 0,
               let element = labelElement(containing: text, timeout: 0.4), isOnScreen(element) {
                settle(0.8)     // let the scroll-scrub settle on its frame
                return true
            }
            web.swipeUp()
            settle(checkEvery > 1 ? 0.3 : 0.6)
        }
        return labelElement(containing: text, timeout: 0.5).map(isOnScreen) ?? false
    }

    /// The system share sheet (UIActivityViewController) after a ShareLink
    /// tap: its activity list, or any of the row buttons it always carries.
    private func waitForShareSheet(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if app.otherElements["ActivityListView"].exists { return true }
            for title in ["Copy", "Messages", "Mail", "AirDrop"] {
                if app.buttons[title].exists || app.cells[title].exists || app.staticTexts[title].exists {
                    return true
                }
            }
            settle(0.4)
        } while Date() < deadline
        return false
    }

    /// Leave the share sheet without sharing: its own Close, else a swipe down.
    private func dismissShareSheet() {
        let close = app.buttons["Close"]
        if close.exists && close.isHittable {
            close.tap()
        } else {
            app.swipeDown()
        }
        settle(0.8)
    }

    /// The first HITTABLE element carrying `identifier`. Two elements can share
    /// an identifier across a pushed screen and the one underneath it
    /// (`detail.reelStudio` is both the toolbox tile and the studio's reel
    /// card); the hittable one is the one on screen.
    private func hittableElement(id identifier: String) -> XCUIElement? {
        let matches = app.descendants(matching: .any).matching(identifier: identifier)
        for index in 0..<matches.count {
            let element = matches.element(boundBy: index)
            if element.exists && element.isHittable { return element }
        }
        return nil
    }

    /// First element of ANY type whose label contains `text` (case-insensitive),
    /// polling until `timeout`.
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

    /// Swipe up until an element whose label contains `text` is on screen.
    private func scrollToLabel(containing text: String, swipes: Int) -> XCUIElement? {
        for _ in 0...swipes {
            if let element = labelElement(containing: text, timeout: 0.6), isOnScreen(element) {
                return element
            }
            app.swipeUp()
            settle(0.35)
        }
        return labelElement(containing: text, timeout: 0.6)
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
