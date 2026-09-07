//
//  IndustryWalk.swift
//  The PER-INDUSTRY walk — every business type the app sells to, every screen
//  a user of that type can reach under `-uiTesting`.
//
//  SIX tests, one per `SpaceType` — `testRealEstate` (the control), `testVenue`,
//  `testRestaurant`, `testRetail`, `testFitness`, `testOther`. Each one launches
//  the app on a booted simulator, puts it into that business type, walks Home →
//  the collection tab → a sample's detail → the new-listing form → the AI Photo
//  Studio (through the "which home?" gate, which creates the walk's one real
//  project for that type) → that project's detail, Aerial intro, Floor plan,
//  reel entry and edit sheet → Leads → Profile and the card editor → Settings,
//  Business type, Plan & usage, the paywall, Legal & support and the
//  delete-account confirmation. Every screen gets a `keepAlways` screenshot
//  named `<type>-NN-<screen>` and a set of CHECK activities.
//
//  CHECKS, NOT ASSERTIONS. Every expectation is written into the result bundle
//  as an activity named `CHECK PASS <what>` or `CHECK FAIL <what>: <actual>`.
//  `bridge-cmd-industrywalk.sh` greps those out into checks.txt. The expected
//  strings are derived from the app's own code — `SpaceType` in
//  Models/Listing.swift (display names, nouns, hero copy, sample listings,
//  detail fields, area tags, CTA titles), the form in NewListingView.swift, the
//  studio's `EditWords` in FlythroughDetailView.swift, the card editor and the
//  Business type preview in SettingsView.swift — never invented. Each screen is
//  also scanned for vocabulary that must not leak across the line: a venue /
//  bar / store / gym must never read "listing", "beds", "baths", "MLS",
//  "buyers", "agent", "brokerage", "Zillow", "showing", "sold", "staging" or
//  "home(s)"; the real-estate control must never read "venue", "planners",
//  "guests", "shoppers", "members" or "archived". A leak is a CHECK FAIL that
//  quotes the offending label; the static review in docs/qa/industry-review.md
//  says which ones are known.
//
//  HOW THE BUSINESS TYPE IS SELECTED — and why not `-space.type`. `-key value`
//  launch arguments land in UserDefaults' NSArgumentDomain, which WINS over the
//  persisted domain on every read. That is what makes `-hasOnboarded YES` work,
//  and it is also why the Home switcher cannot be exercised under
//  `-space.type venue`: `@AppStorage("space.type")` would write "restaurant" to
//  the persisted domain and read "venue" straight back. So each test launches
//  WITHOUT `-space.type`, reads whatever type Home shows, and drives the
//  top-left business-type menu to its own industry the way a user does — that
//  IS the switcher test, and Home re-theming (hero headline) is the proof. If
//  the menu cannot be driven the test relaunches pinned with
//  `-space.type <raw>` so the rest of the walk still runs, and says so.
//
//  THINGS THIS TEST NEVER DOES
//
//  1. NEVER CONFIRMS AN ACCOUNT DELETION. The last step taps "Delete account"
//     ONCE to photograph the confirmation, then presses Cancel and nothing
//     else. `SettingsView.deleteAccount()` calls the REAL server
//     (`serverAccountsEnabled` is `Config.useLiveBackend && Config.enableAuth`,
//     neither of which `-uiTesting` turns off). `confirmDeletionIsNeverTapped`
//     is the only button list that step may press.
//  2. Never taps a purchase button. The paywall is opened, photographed and
//     closed. The StoreKit test environment (same recipe as PaywallShot) only
//     makes the plan cards render so their copy can be checked per industry.
//  3. Never runs an AI edit, never adds a photo, never records or uploads a
//     video, never publishes. `-uiTesting` means `MockAPIClient`; the reel
//     card stays disabled (it needs two photos) and is photographed as such.
//  4. Never asserts. `continueAfterFailure = true`, one `XCTContext.runActivity`
//     per step, and a step that cannot be reached writes the reason into the
//     result bundle instead of failing the run.
//
//  Element lookup is identifier first (grep `.accessibilityIdentifier(` in
//  apps/ios/Rendprop), visible label second, never coordinates.
//
//  NOT TESTABLE HERE (plan the device test around these): the onboarding intro
//  and its type picker (`-hasOnboarded YES` is in the argument domain — see
//  above; ReviewerWalk covers them), real capture, RoomPlan scanning (no LiDAR
//  in the simulator), Reel Studio past its disabled card, a StoreKit purchase,
//  publish / share links / the MLS link card, the COMPLIANCE card and the
//  hosted tour page (all need a published listing on the live backend).
//

import XCTest
import StoreKitTest

// MARK: - The six industries, in the app's own words

/// Everything the walk expects to read for one business type. Every value is
/// copied from `SpaceType` (Models/Listing.swift) or the screen that shows it.
private struct Industry {
    let raw: String                 // SpaceType.rawValue
    let tag: String                 // screenshot prefix
    let displayName: String         // SpaceType.displayName
    let noun: String                // SpaceType.spaceNoun
    let customer: String            // SpaceType.customerNoun
    let cta: String                 // SpaceType.ctaTitle
    let heroLine1: String           // SpaceType.heroHeadline, first line
    let heroLine2: String           // SpaceType.heroHeadline, second line
    let heroSubline: String         // SpaceType.heroSubline
    let emptyStateLine1: String     // SpaceType.emptyStateLine, first line
    let pitch: String               // SpaceType.pitch
    let archiveVerb: String         // SpaceType.archiveVerb
    let businessLabel: String       // SpaceType.businessLabel
    let profileCardName: String     // SpaceType.profileCardName
    let profileNameLabel: String    // SpaceType.profileNameLabel
    let profileOrgLabel: String     // SpaceType.profileOrgLabel
    let profilePhotoLabel: String   // SpaceType.profilePhotoLabel
    let sampleAddress: String       // SpaceType.sampleListings.first.address
    let sampleSubtitle: String      // Listing.subtitleLine of that sample
    let sampleDetailRows: [(label: String, value: String)]   // DETAILS rows on the sample's detail
    let detailFieldLabels: [String] // SpaceType.detailFields labels (non-RE form fields)
    let quickTags: [String]         // SpaceType.quickTags, first six
    let studioChips: [String]       // PhotoStudioView.emptyShowcase chips offered
    let studioChipsAbsent: [String] // chips that must NOT be offered
    let taglinePlaceholder: String  // ListingFieldsForm.taglinePlaceholder(for:)
    let walkName: String            // the one real project this walk creates
    let forbiddenRegex: String      // vocabulary that must not appear on this type's screens
    let forbiddenDescription: String
    let allowedExactLabels: [String]

    var nounCap: String { noun.prefix(1).uppercased() + noun.dropFirst() }
    var customerCap: String { customer.prefix(1).uppercased() + customer.dropFirst() }
    var tabTitle: String { nounCap + "s" }                       // RootTabView: "\(spaceNounCap)s"
    var collectionTitle: String { "My " + nounCap + "s" }        // SpaceType.collectionTitle
    var newItemTitle: String { "New " + nounCap }                // SpaceType.newItemTitle
    var isRealEstate: Bool { raw == "real_estate" }
    /// ListingFieldsForm: the optional-details disclosure title.
    var formDetailsHeader: String { isRealEstate ? "Home details (optional)" : "\(displayName) details (optional)" }
    /// ListingFieldsForm / StartProjectSheet: the name field's placeholder.
    var addressPlaceholder: String { isRealEstate ? "Type the home's address" : "Name or address of your \(noun)" }
    /// FlythroughDetailView toolbox + ReviewSubmitView.
    var tagAreasTitle: String { isRealEstate ? "Tag rooms" : "Tag areas" }
    var tagAreasWrongTitle: String { isRealEstate ? "Tag areas" : "Tag rooms" }

    /// What a venue / bar / store / gym must never read. Word-anchored; the
    /// exact tab title "Home" is allowed (see `allowedExactLabels`).
    static let realEstateOnlyWords =
        "[\\s\\S]*\\b(listings?|beds?|baths?|bedrooms?|bathrooms?|mls|buyers?|agents?|brokerage|zillow|"
        + "showings?|sold|staging|realtor|homes?|real[ -]estate|open house)\\b[\\s\\S]*"
    static let realEstateOnlyDescription =
        "real-estate-only vocabulary (listing / beds / baths / MLS / buyers / agent / brokerage / Zillow / showing / sold / staging / home)"
    /// What the real-estate control must never read.
    static let otherIndustryWords =
        "[\\s\\S]*\\b(venues?|planners|guests|shoppers|members|archived|business card|business name|furnish it|tagline)\\b[\\s\\S]*"
    static let otherIndustryDescription =
        "non-real-estate vocabulary (venue / planners / guests / shoppers / members / archived / business card)"

    static let realEstate = Industry(
        raw: "real_estate", tag: "realestate",
        displayName: "Real estate", noun: "home", customer: "buyers", cta: "Book a showing",
        heroLine1: "Win the listing.", heroLine2: "Skip the film crew.",
        heroSubline: "One walkthrough becomes a cinematic tour, polished photos and a link buyers can't stop scrolling — in minutes, from your phone.",
        emptyStateLine1: "Walk through with your phone.",
        pitch: "Sell homes with cinematic tours",
        archiveVerb: "sold", businessLabel: "Brokerage",
        profileCardName: "Agent card", profileNameLabel: "Full name",
        profileOrgLabel: "Brokerage", profilePhotoLabel: "Headshot",
        sampleAddress: "1247 Hillcrest Drive (Sample)",
        sampleSubtitle: "4 bd · 3 ba · 2,850 sqft",
        sampleDetailRows: [],
        detailFieldLabels: [],
        quickTags: ["Exterior", "Entry", "Living Room", "Kitchen", "Dining", "Primary"],
        studioChips: ["Make it twilight", "Make the sky blue", "Make the lawn green",
                      "Declutter", "Add furniture", "Turn it into video"],
        studioChipsAbsent: ["Ask for anything", "Furnish it"],
        taglinePlaceholder: "e.g. Sun-filled craftsman near the park",
        walkName: "1 Walk Test Street",
        forbiddenRegex: Industry.otherIndustryWords, forbiddenDescription: Industry.otherIndustryDescription,
        allowedExactLabels: [])

    static let venue = Industry(
        raw: "venue", tag: "venue",
        displayName: "Event venue", noun: "venue", customer: "planners", cta: "Plan your event",
        heroLine1: "Book the date before", heroLine2: "they ever visit.",
        heroSubline: "Walk the room once. Get a cinematic tour, polished photos and a link planners share before they've booked a visit.",
        emptyStateLine1: "Walk the space with your phone.",
        pitch: "Book more events",
        archiveVerb: "archived", businessLabel: "Business",
        profileCardName: "Business card", profileNameLabel: "Business name",
        profileOrgLabel: "Owner or manager (optional)", profilePhotoLabel: "Logo or photo",
        sampleAddress: "The Grand Atrium (Sample)",
        sampleSubtitle: "Historic ballroom · Seats 220",
        sampleDetailRows: [
            (label: "Max seated guests", value: "220"),
            (label: "Max standing", value: "350"),
            (label: "Starting price", value: "$3,500"),
            (label: "Event types", value: "Wedding · Corporate · Gala"),
            (label: "Catering", value: "In-house or outside"),
            (label: "Indoor / Outdoor", value: "Both"),
            (label: "Amenities", value: "Tables & Chairs · AV / Sound · Stage · Dance Floor · Parking · Bar"),
        ],
        detailFieldLabels: ["Max seated guests", "Max standing", "Starting price", "Event types",
                            "Catering", "Indoor / Outdoor", "Amenities", "Booking / inquiry link"],
        quickTags: ["Entrance", "Main Hall", "Stage", "Bar", "Lounge", "Patio"],
        studioChips: ["Make it twilight", "Make the sky blue", "Declutter",
                      "Furnish it", "Turn it into video", "Ask for anything"],
        studioChipsAbsent: ["Make the lawn green", "Add furniture"],
        taglinePlaceholder: "e.g. Historic ballroom · Seats 220",
        walkName: "Walk Test Venue",
        forbiddenRegex: Industry.realEstateOnlyWords, forbiddenDescription: Industry.realEstateOnlyDescription,
        allowedExactLabels: ["Home"])

    static let restaurant = Industry(
        raw: "restaurant", tag: "restaurant",
        displayName: "Restaurant / Bar", noun: "place", customer: "guests", cta: "Book a table",
        heroLine1: "Fill the room before", heroLine2: "they see the menu.",
        heroSubline: "Walk it once. Get a cinematic tour, mouth-watering photos and a link guests share — in minutes, from your phone.",
        emptyStateLine1: "Walk the room with your phone.",
        pitch: "Fill more tables",
        archiveVerb: "archived", businessLabel: "Business",
        profileCardName: "Business card", profileNameLabel: "Business name",
        profileOrgLabel: "Owner or manager (optional)", profilePhotoLabel: "Logo or photo",
        sampleAddress: "Bella Notte (Sample)",
        sampleSubtitle: "Italian · Wine Bar · $$$",
        sampleDetailRows: [
            (label: "Cuisine", value: "Italian · Wine Bar"),
            (label: "Price", value: "$$$"),
            (label: "Hours", value: "Tue–Sun 5–11pm"),
            (label: "Features", value: "Outdoor Seating · Full Bar · Private Dining · Happy Hour"),
            (label: "Phone", value: "(555) 014-2200"),
        ],
        detailFieldLabels: ["Cuisine", "Price", "Hours", "Reservations link", "Menu link", "Features", "Phone"],
        quickTags: ["Entrance", "Dining", "Bar", "Patio", "Private Room", "Kitchen"],
        studioChips: ["Make it twilight", "Make the sky blue", "Declutter",
                      "Furnish it", "Turn it into video", "Ask for anything"],
        studioChipsAbsent: ["Make the lawn green", "Add furniture"],
        taglinePlaceholder: "e.g. Rooftop cocktail bar with skyline views",
        walkName: "Walk Test Place",
        forbiddenRegex: Industry.realEstateOnlyWords, forbiddenDescription: Industry.realEstateOnlyDescription,
        allowedExactLabels: ["Home"])

    static let retail = Industry(
        raw: "retail", tag: "retail",
        displayName: "Retail / Grocery", noun: "store", customer: "shoppers", cta: "Visit us",
        heroLine1: "Get them in the door", heroLine2: "from their couch.",
        heroSubline: "One walkthrough becomes a cinematic tour, polished photos and a link shoppers can scroll before they visit.",
        emptyStateLine1: "Walk the aisles with your phone.",
        pitch: "Bring shoppers through the door",
        archiveVerb: "archived", businessLabel: "Business",
        profileCardName: "Business card", profileNameLabel: "Business name",
        profileOrgLabel: "Owner or manager (optional)", profilePhotoLabel: "Logo or photo",
        sampleAddress: "Fresh Market (Sample)",
        sampleSubtitle: "Neighborhood grocery · Open daily 7am–9pm",
        sampleDetailRows: [
            (label: "Store type", value: "Grocery"),
            (label: "Hours", value: "Daily 7am–9pm"),
            (label: "Weekly special / promo", value: "Local strawberries — 2 for 1 this week"),
            (label: "How to shop", value: "In-store · Curbside Pickup · Local Delivery"),
            (label: "Departments", value: "Produce · Deli · Bakery · Dairy · Frozen"),
        ],
        detailFieldLabels: ["Store type", "Hours", "Phone", "Online store / website",
                            "Weekly special / promo", "How to shop", "Departments"],
        quickTags: ["Entrance", "Front", "Aisles", "Produce", "Deli", "Checkout"],
        studioChips: ["Make it twilight", "Make the sky blue", "Declutter",
                      "Furnish it", "Turn it into video", "Ask for anything"],
        studioChipsAbsent: ["Make the lawn green", "Add furniture"],
        taglinePlaceholder: "e.g. Neighborhood grocery · Open daily 7am–9pm",
        walkName: "Walk Test Store",
        forbiddenRegex: Industry.realEstateOnlyWords, forbiddenDescription: Industry.realEstateOnlyDescription,
        allowedExactLabels: ["Home"])

    static let fitness = Industry(
        raw: "fitness", tag: "fitness",
        displayName: "Gym / Studio", noun: "studio", customer: "members", cta: "Book a session",
        heroLine1: "Sell the feeling", heroLine2: "before the first class.",
        heroSubline: "Walk the floor once. Get a cinematic tour, polished photos and a link that sells the space before the first class.",
        emptyStateLine1: "Walk the floor with your phone.",
        pitch: "Sign up more members",
        archiveVerb: "archived", businessLabel: "Business",
        profileCardName: "Business card", profileNameLabel: "Business name",
        profileOrgLabel: "Owner or manager (optional)", profilePhotoLabel: "Logo or photo",
        sampleAddress: "Iron & Oak Strength Co. (Sample)",
        sampleSubtitle: "Strength gym · Open 24/7 · Classes daily",
        sampleDetailRows: [
            (label: "Facility type", value: "Gym"),
            (label: "Membership / mo", value: "$49"),
            (label: "Day pass", value: "$15"),
            (label: "Open 24/7", value: "Yes"),
            (label: "Amenities", value: "Showers · Sauna · Lockers · Parking · Smoothie Bar"),
            (label: "Free trial / intro offer", value: "7-day free trial"),
        ],
        detailFieldLabels: ["Facility type", "Membership / mo", "Day pass", "Open 24/7", "Hours",
                            "Amenities", "Free trial / intro offer", "Booking / schedule link"],
        quickTags: ["Entrance", "Reception", "Main Floor", "Weights", "Studio", "Cardio"],
        studioChips: ["Make it twilight", "Make the sky blue", "Declutter",
                      "Furnish it", "Turn it into video", "Ask for anything"],
        studioChipsAbsent: ["Make the lawn green", "Add furniture"],
        taglinePlaceholder: "e.g. Strength gym · Open 24/7 · Classes daily",
        walkName: "Walk Test Studio",
        forbiddenRegex: Industry.realEstateOnlyWords, forbiddenDescription: Industry.realEstateOnlyDescription,
        allowedExactLabels: ["Home"])

    static let other = Industry(
        raw: "other", tag: "other",
        displayName: "Other business", noun: "space", customer: "customers", cta: "Get in touch",
        heroLine1: "Show your space", heroLine2: "like a film.",
        heroSubline: "One walkthrough becomes a cinematic tour, polished photos and a link customers can scroll — in minutes, from your phone.",
        emptyStateLine1: "Walk through with your phone.",
        pitch: "Show off any space",
        archiveVerb: "archived", businessLabel: "Business",
        profileCardName: "Business card", profileNameLabel: "Business name",
        profileOrgLabel: "Owner or manager (optional)", profilePhotoLabel: "Logo or photo",
        sampleAddress: "The Workshop (Sample)",
        sampleSubtitle: "Creative studio & community space",
        sampleDetailRows: [
            (label: "Hours", value: "Mon–Sat 9am–6pm"),
        ],
        detailFieldLabels: ["Hours", "Phone", "Website"],
        quickTags: ["Entrance", "Main Area", "Front", "Back", "Outside", "Restrooms"],
        studioChips: ["Make it twilight", "Make the sky blue", "Declutter",
                      "Furnish it", "Turn it into video", "Ask for anything"],
        studioChipsAbsent: ["Make the lawn green", "Add furniture"],
        taglinePlaceholder: "e.g. Creative studio & community space",
        walkName: "Walk Test Space",
        forbiddenRegex: Industry.realEstateOnlyWords, forbiddenDescription: Industry.realEstateOnlyDescription,
        allowedExactLabels: ["Home"])

    /// The order of `SpaceType.allCases`.
    static let all: [Industry] = [Industry.realEstate, Industry.venue, Industry.restaurant,
                                  Industry.retail, Industry.fitness, Industry.other]
}

// MARK: - The walk

final class IndustryWalk: XCTestCase {

    // MARK: Fixtures

    private var app: XCUIApplication!

    /// The StoreKit test environment — so the paywall renders plan cards whose
    /// copy can be checked per industry. Same recipe as PaywallShot; kept alive
    /// for the whole test and released in tearDown. Optional on purpose: with
    /// no session the paywall shows its empty state and the step says so.
    private var storeKit: SKTestSession?
    private var storeKitNote = ""
    private let configurationName = "Rendprop"

    /// Longest wait for a screen. A cold simulator compiles shaders and seeds
    /// the sample listings on the first launch.
    private let screenTimeout: TimeInterval = 15
    /// Wait for something that should already be there.
    private let shortTimeout: TimeInterval = 3
    /// How long the paywall gets to render a real price before the step
    /// captures the empty state instead.
    private let productTimeout: TimeInterval = 20

    /// Buttons the delete-account step is allowed to press to leave the alert.
    /// "Delete" is NOT here and must never be added — see the file header.
    private let confirmDeletionIsNeverTapped = ["Cancel"]

    /// Everything but the business type — see the file header for why
    /// `-space.type` is not in this list.
    private var baseLaunchArguments: [String] {
        [
            // Mock API client — see Config.isUITesting.
            "-uiTesting",
            // RendpropApp.swift @AppStorage("hasOnboarded") → skip the intro.
            "-hasOnboarded", "YES",
            // Deterministic screenshots regardless of the simulator's theme.
            "-appearance", "light",
            // Guideline 5.1.2(i) consent — without it the AI screens show the
            // disclosure overlay and dismiss themselves when it is not answered.
            "-ai.thirdPartyProcessing.consent.v1", "YES",
        ]
    }

    override func setUpWithError() throws {
        // Dozens of screenshots per industry. One unreachable control must not
        // cost us the rest.
        continueAfterFailure = true
        // ORDER MATTERS: the StoreKit test environment has to exist before the
        // app launches (PurchaseManager loads products in its first task).
        startStoreKitTestEnvironment()
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
        storeKit = nil
    }

    // MARK: The six tests

    func testRealEstate() { walk(Industry.realEstate) }
    func testVenue()      { walk(Industry.venue) }
    func testRestaurant() { walk(Industry.restaurant) }
    func testRetail()     { walk(Industry.retail) }
    func testFitness()    { walk(Industry.fitness) }
    func testOther()      { walk(Industry.other) }

    private func walk(_ industry: Industry) {
        if !storeKitNote.isEmpty { note(storeKitNote) }
        note("Launch arguments: \(baseLaunchArguments.joined(separator: " ")) — the business type is selected "
             + "through the Home switcher (see the file header); `-space.type \(industry.raw)` is the fallback.")
        stepLaunchAndSwitch(industry)
        stepHome(industry)
        stepCollectionTab(industry)
        stepSampleDetail(industry)
        stepNewForm(industry)
        stepPhotoStudio(industry)
        stepOwnProject(industry)
        stepLeads(industry)
        stepProfile(industry)
        stepSettings(industry)
        stepBusinessType(industry)
        stepPlanAndPaywall(industry)
        stepLegal(industry)
        stepDeleteAccount(industry)
        note("NOT TESTED HERE (simulator / -uiTesting limits): the onboarding intro and its type picker "
             + "(-hasOnboarded YES sits in the argument domain, so \"Watch the intro again\" cannot flip it — "
             + "ReviewerWalk covers them), real capture, RoomPlan scanning, Reel Studio past its disabled card, "
             + "a StoreKit purchase, publish / share links / the MLS card, the COMPLIANCE card and the hosted tour page.")
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
            let bundle = Bundle(for: IndustryWalk.self)
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
            storeKitNote = "STOREKIT: no test session — the paywall step captures the empty state. "
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

    // MARK: 00 — launch + the business-type switcher

    /// Launch without `-space.type`, then drive Home's top-left menu to this
    /// industry. When Home already shows it, detour through another type first
    /// so the switcher is exercised on every run. Falls back to a pinned
    /// relaunch when the menu cannot be driven.
    private func stepLaunchAndSwitch(_ i: Industry) {
        activity("\(i.tag) — 00 launch + business-type switcher") {
            app.launchArguments = baseLaunchArguments
            app.launch()
            guard waitForHome(timeout: screenTimeout) else {
                note("Home never appeared within \(Int(screenTimeout))s after launch — relaunching pinned to "
                     + "-space.type \(i.raw).")
                shot("\(i.tag)-00-launch")
                relaunchPinned(i)
                return
            }
            settle(1.5)
            let before = currentTypeOnHome()
            note("Launched without -space.type; Home came up as \(before?.displayName ?? "an unrecognised business type").")

            if let before, before.raw == i.raw {
                let detour = i.raw == Industry.other.raw ? Industry.venue : Industry.other
                let moved = switchType(to: detour, menuShot: nil)
                check("\(i.tag): switcher moves Home to \(detour.displayName) (detour, Home already showed \(i.displayName))",
                      moved, actual: moved ? "" : "hero headline for \(detour.displayName) never appeared")
            }

            let switched = switchType(to: i, menuShot: "\(i.tag)-00-type-menu")
            let after = currentTypeOnHome()
            check("\(i.tag): switcher selects \"\(i.displayName)\" and Home re-themes to its hero \"\(i.heroLine1)\"",
                  switched && after?.raw == i.raw,
                  actual: switched ? "capsule reads \(after?.displayName ?? "nothing")" : "hero headline never changed")
            shot("\(i.tag)-00-switched")
            if !(switched && after?.raw == i.raw) {
                note("FALLBACK: relaunching pinned to -space.type \(i.raw) so the rest of the walk runs in "
                     + "\(i.displayName) mode. The switcher itself is the CHECK FAIL above.")
                relaunchPinned(i)
            }
        }
    }

    // MARK: 01 — Home dashboard

    private func stepHome(_ i: Industry) {
        activity("\(i.tag) — 01 Home dashboard") {
            popToRoot()
            guard openHomeTab(), waitForHome(timeout: screenTimeout) else {
                note("SKIPPED: Home never appeared — capturing whatever is on screen.")
                shot("\(i.tag)-01-home")
                return
            }
            scrollToTop()
            settle(1.2)
            shot("\(i.tag)-01-home")

            let capsule = currentTypeOnHome()
            check("\(i.tag): nav-bar business-type capsule reads \"\(i.displayName)\"",
                  capsule?.raw == i.raw, actual: capsule?.displayName ?? "no capsule found")
            checkContains("\(i.tag): hero headline line 1 is \"\(i.heroLine1)\" (SpaceType.heroHeadline)", i.heroLine1)
            checkContains("\(i.tag): hero headline line 2 is \"\(i.heroLine2)\" (SpaceType.heroHeadline)", i.heroLine2)
            checkContains("\(i.tag): hero subline matches SpaceType.heroSubline", i.heroSubline)
            checkText("\(i.tag): collection section titled \"\(i.collectionTitle)\"", i.collectionTitle)
            checkText("\(i.tag): \"Add a \(i.noun)\" button (home.addHome)", "Add a \(i.noun)")
            checkContains("\(i.tag): showroom caption \"Everything you make is saved to one \(i.noun).\"",
                          "Everything you make is saved to one \(i.noun).")
            checkContains("\(i.tag): profile tile is named \"\(i.profileCardName)\"", i.profileCardName)
            checkContains("\(i.tag): how-it-works step 1 \"Add the \(i.noun)\"", "Add the \(i.noun)")
            checkContains("\(i.tag): how-it-works step 3 addresses \(i.customerCap)", "\(i.customerCap) scroll it")
            checkContains("\(i.tag): demo caption says \"the tour your \(i.customer) get\"",
                          "this is the tour your \(i.customer) get")
            vocabularyScan(i, screen: "Home")

            if scrollTo(ids: [], labels: ["See it in action"], swipes: 6) != nil {
                settle(2)
                shot("\(i.tag)-02-home-demo")
                if !i.isRealEstate {
                    note("NOTE: for \(i.displayName) the Home demo is the bundled sample player, which needs the "
                         + "untracked Resources/player/demo.mp4 — if the shot reads \"Sample video unavailable\" that "
                         + "is the reason (real estate gets the hosted estate demo instead).")
                }
            } else {
                note("No \"See it in action\" section on Home — no demo shot.")
            }
            scrollToTop()
        }
    }

    // MARK: 03 — the collection tab (Homes / Venues / Places / Stores / Studios / Spaces)

    private func stepCollectionTab(_ i: Industry) {
        activity("\(i.tag) — 03 \(i.tabTitle) tab") {
            popToRoot()
            guard openCollectionTab(i) else {
                note("SKIPPED: no second tab titled \"\(i.tabTitle)\" (or any other industry's title).")
                shot("\(i.tag)-03-collection")
                return
            }
            settle(2)                       // the list seeds its samples on first appear
            shot("\(i.tag)-03-collection")

            check("\(i.tag): second tab is titled \"\(i.tabTitle)\"",
                  app.tabBars.buttons[i.tabTitle].exists, actual: "tab bar: \(tabTitles())")
            check("\(i.tag): collection nav title \"\(i.collectionTitle)\"",
                  app.navigationBars[i.collectionTitle].exists
                    || find(ids: [], labels: [i.collectionTitle], timeout: 1) != nil)
            checkContains("\(i.tag): first-tour card line \"\(i.emptyStateLine1)\" (SpaceType.emptyStateLine)", i.emptyStateLine1)
            checkContains("\(i.tag): sample \"\(i.sampleAddress)\" is listed", i.sampleAddress)
            checkContains("\(i.tag): sample card subtitle \"\(i.sampleSubtitle)\"", i.sampleSubtitle)
            checkContains("\(i.tag): samples caption says \"The \(i.noun)s below are samples\"",
                          "The \(i.noun)s below are samples")
            let field = app.searchFields.firstMatch
            let prompt = field.exists ? (field.placeholderValue ?? "") : "no search field"
            check("\(i.tag): search prompt \"Search \(i.noun)s\"", prompt == "Search \(i.noun)s", actual: prompt)
            for other in Industry.all where other.raw != i.raw {
                check("\(i.tag): \(other.displayName)'s project \"\(other.walkName)\" is NOT in this list",
                      labelElement(containing: other.walkName, timeout: 0.3) == nil)
            }
            vocabularyScan(i, screen: "\(i.tabTitle) tab")
        }
    }

    // MARK: 04–07 — a sample's detail

    private func stepSampleDetail(_ i: Industry) {
        activity("\(i.tag) — 04 sample \(i.noun) detail") {
            guard openFirstSample(i) else {
                note("SKIPPED: no row containing \"Sample\" on the \(i.tabTitle) tab, or its detail never opened.")
                return
            }
            settle(2)
            shot("\(i.tag)-04-sample-detail")

            check("\(i.tag): detail title is the sample address \"\(i.sampleAddress)\"",
                  app.navigationBars[i.sampleAddress].exists
                    || labelElement(containing: i.sampleAddress, timeout: 1) != nil)
            checkText("\(i.tag): SAMPLE TOUR kicker over the player", "SAMPLE TOUR")
            checkContains("\(i.tag): sample card says \"Create your own \(i.noun)\"", "Create your own \(i.noun)")
            checkText("\(i.tag): \"Create a \(i.noun)\" button", "Create a \(i.noun)")
            if i.isRealEstate {
                checkContains("\(i.tag): info line \"4 bd · 3 ba · 2,850 sqft · $1,175,000\"", "4 bd · 3 ba · 2,850 sqft · $1,175,000")
            } else {
                checkContains("\(i.tag): info line is the tagline \"\(i.sampleSubtitle)\"", i.sampleSubtitle)
                checkAbsent("\(i.tag): no beds/baths line on a \(i.noun)", " bd · ")
            }

            // TOOLBOX — every tool present, every AI tool dimmed on a sample.
            if scrollTo(ids: [], labels: ["TOOLBOX"], swipes: 8) != nil { settle(0.8) }
            shot("\(i.tag)-05-sample-toolbox")
            let studio = find(ids: ["detail.photoStudio"], labels: ["AI Photo Studio"], timeout: shortTimeout)
            let studioState: String
            if let studio { studioState = "isEnabled=\(studio.isEnabled)" } else { studioState = "tile missing" }
            check("\(i.tag): AI Photo Studio tile present and DISABLED on the sample",
                  studio != nil && studio?.isEnabled == false, actual: studioState)
            let reel = find(ids: ["detail.reelStudio"], labels: ["Make a reel"], timeout: shortTimeout)
            let reelState: String
            if let reel { reelState = "isEnabled=\(reel.isEnabled)" } else { reelState = "tile missing" }
            check("\(i.tag): Make a reel tile present and DISABLED on the sample",
                  reel != nil && reel?.isEnabled == false, actual: reelState)
            // The toolbox is a LazyVGrid: a row below the fold is not in the
            // hierarchy at all, so each tile is scrolled into view first.
            checkTile("\(i.tag): toolbox tagging tile says \"\(i.tagAreasTitle)\"", i.tagAreasTitle)
            checkAbsent("\(i.tag): toolbox never says \"\(i.tagAreasWrongTitle)\"", i.tagAreasWrongTitle)
            checkTile("\(i.tag): \"Floor plan\" tile", "Floor plan")
            checkTile("\(i.tag): \"Aerial intro\" tile", "Aerial intro")
            checkTile("\(i.tag): \"\(i.profileCardName)\" tile", i.profileCardName)
            checkContains("\(i.tag): dimmed tools say \"Create a \(i.noun) first\"", "Create a \(i.noun) first")
            checkAbsent("\(i.tag): no MANAGE section on a sample", "MANAGE")
            checkAbsent("\(i.tag): no \"Mark as \(i.archiveVerb)\" on a sample", "Mark as \(i.archiveVerb)")
            if !i.isRealEstate {
                checkAbsent("\(i.tag): no Zillow anywhere on a \(i.noun)", "Zillow")
                checkAbsent("\(i.tag): no MLS anywhere on a \(i.noun)", "MLS")
            }

            // LEADS — sample stats.
            if scrollTo(ids: [], labels: ["LEADS"], swipes: 8) != nil { settle(0.6) }
            shot("\(i.tag)-06-sample-leads")
            checkContains("\(i.tag): sample leads caption", "Sample data — leads from your published tours land here.")

            // DETAILS — the industry rows (non-real-estate only).
            if i.isRealEstate {
                checkAbsent("\(i.tag): no DETAILS section on a home (beds/baths live in the info line)", "DETAILS")
            } else {
                if scrollTo(ids: [], labels: ["DETAILS"], swipes: 8) != nil { settle(0.6) }
                shot("\(i.tag)-07-sample-details")
                checkText("\(i.tag): DETAILS section", "DETAILS")
                for row in i.sampleDetailRows {
                    checkText("\(i.tag): detail row \"\(row.label)\"", row.label)
                    checkText("\(i.tag): detail value \"\(row.value)\" for \(row.label)", row.value)
                }
            }
            note("COMPLIANCE card: not reachable on a sample (it needs a published listing with AI edits) — device test.")
            vocabularyScan(i, screen: "sample \(i.noun) detail")
            popToRoot()
        }
    }

    // MARK: 08 — the new-listing form

    private func stepNewForm(_ i: Industry) {
        activity("\(i.tag) — 08 \(i.newItemTitle) form") {
            popToRoot()
            guard openHomeTab(), waitForHome(timeout: screenTimeout) else {
                note("SKIPPED: Home tab unavailable.")
                return
            }
            scrollToTop()
            guard let add = scrollTo(ids: ["home.addHome"], labels: ["Add a \(i.noun)"], swipes: 6) else {
                note("SKIPPED: no `home.addHome` and no \"Add a \(i.noun)\" button on Home.")
                return
            }
            tap(add)
            guard waitForAny(ids: [], labels: [i.newItemTitle, "Step 1 · The \(i.noun)"], timeout: screenTimeout) else {
                note("SKIPPED: the \(i.newItemTitle) screen did not open — capturing whatever is on screen.")
                shot("\(i.tag)-08-new-form")
                popToRoot()
                return
            }
            settle(0.8)
            check("\(i.tag): form nav title \"\(i.newItemTitle)\" (SpaceType.newItemTitle)",
                  app.navigationBars[i.newItemTitle].exists
                    || find(ids: [], labels: [i.newItemTitle], timeout: 1) != nil)
            checkContains("\(i.tag): step 1 card \"Step 1 · The \(i.noun)\"", "Step 1 · The \(i.noun)")
            check("\(i.tag): name field placeholder \"\(i.addressPlaceholder)\"",
                  app.textFields[i.addressPlaceholder].exists, actual: firstTextFieldPlaceholder())
            checkText("\(i.tag): step 2 video card", "Step 2 · The video")
            checkContains("\(i.tag): \"Upload a video\" action", "Upload a video")
            checkContains("\(i.tag): \"Record a walkthrough\" action", "Record a walkthrough")
            checkContains("\(i.tag): video hint asks for the \(i.isRealEstate ? "address" : "name") first",
                          "Type the \(i.isRealEstate ? "address" : "name") first")
            if i.isRealEstate {
                checkAbsent("\(i.tag): no \"Description (optional)\" tagline card on the real-estate form", "Description (optional)")
            } else {
                checkText("\(i.tag): \"Description (optional)\" tagline card", "Description (optional)")
                check("\(i.tag): tagline placeholder \"\(i.taglinePlaceholder)\"",
                      app.textFields[i.taglinePlaceholder].exists)
            }

            if let header = scrollTo(ids: [], labels: [i.formDetailsHeader], swipes: 6) {
                check("\(i.tag): optional details disclosure titled \"\(i.formDetailsHeader)\"", true)
                tap(header)                 // expand the DisclosureGroup
                settle(0.8)
                if i.isRealEstate {
                    for label in ["Bedrooms", "Bathrooms", "Square feet", "Asking price"] {
                        checkContains("\(i.tag): property field \"\(label)\"", label)
                    }
                } else {
                    for label in i.detailFieldLabels {
                        checkContains("\(i.tag): \(i.displayName) field \"\(label)\" (SpaceType.detailFields)", label)
                    }
                    for label in ["Bedrooms", "Bathrooms", "Square feet", "Asking price"] {
                        checkAbsent("\(i.tag): no real-estate field \"\(label)\" on a \(i.noun)", label)
                    }
                }
            } else {
                check("\(i.tag): optional details disclosure titled \"\(i.formDetailsHeader)\"", false,
                      actual: "never scrolled into view")
            }
            settle(0.5)
            shot("\(i.tag)-08-new-form")
            vocabularyScan(i, screen: "\(i.newItemTitle) form")
            popToRoot()
        }
    }

    // MARK: 09 — AI Photo Studio, through the "which home?" gate

    /// Home's "Take photos" tile runs the project gate first: with no project
    /// of this type it asks for a name (and that name becomes the walk's one
    /// real project), with exactly one it goes straight in, with two or more
    /// it shows the picker. The studio itself is photographed with its
    /// one-tap edit showcase — NO photo is added and NO edit is run.
    private func stepPhotoStudio(_ i: Industry) {
        activity("\(i.tag) — 09 AI Photo Studio via the Take photos gate") {
            popToRoot()
            guard openHomeTab(), waitForHome(timeout: screenTimeout) else {
                note("SKIPPED: Home tab unavailable.")
                return
            }
            scrollToTop()
            guard let tile = scrollTo(ids: ["home.feature.photos"], labels: ["Take photos"], swipes: 6) else {
                note("SKIPPED: no \"Take photos\" tile on Home, so there is no way in.")
                return
            }
            tap(tile)
            resolveProjectGate(i)

            guard waitForAny(ids: [], labels: ["AI Photo Studio"], timeout: screenTimeout) else {
                note("SKIPPED: the AI Photo Studio did not open — capturing whatever is on screen.")
                shot("\(i.tag)-09-photo-studio")
                popToRoot()
                return
            }
            settle(1.5)
            shot("\(i.tag)-09-photo-studio")
            checkContains("\(i.tag): studio title bar names the project", i.walkName)
            for chip in i.studioChips {
                checkText("\(i.tag): one-tap edit \"\(chip)\" offered (PhotoStudioView.EditWords)", chip)
            }
            for chip in i.studioChipsAbsent {
                checkAbsent("\(i.tag): edit \"\(chip)\" NOT offered to a \(i.noun)", chip)
            }
            let reel = find(ids: ["detail.reelStudio"], labels: ["Make a reel"], timeout: shortTimeout)
            let reelState: String
            if let reel { reelState = "isEnabled=\(reel.isEnabled)" } else { reelState = "card missing" }
            check("\(i.tag): \"Make a reel\" card present and disabled with no photos", reel != nil && reel?.isEnabled == false,
                  actual: reelState)
            checkContains("\(i.tag): reel card explains \"Add 2 photos to start\"", "Add 2 photos to start")
            checkText("\(i.tag): \"Add photos\" button", "Add photos")
            checkText("\(i.tag): \"Take a photo\" button", "Take a photo")
            vocabularyScan(i, screen: "AI Photo Studio")
            note("Reel Studio is not opened: its card needs two photos on this \(i.noun) and the walk adds none.")
            popToRoot()
        }
    }

    // MARK: 10–15 — the walk's own project: detail, MANAGE, Aerial, Floor plan, reel entry, edit

    private func stepOwnProject(_ i: Industry) {
        activity("\(i.tag) — 10 your own \(i.noun): detail + MANAGE") {
            popToRoot()
            guard openHomeTab(), waitForHome(timeout: screenTimeout) else {
                note("SKIPPED: Home tab unavailable.")
                return
            }
            scrollToTop()
            checkContains("\(i.tag): Home lists the project \"\(i.walkName)\" under \(i.collectionTitle)", i.walkName)
            guard let row = scrollTo(ids: ["home.listing.first"], labels: [i.walkName], swipes: 4) else {
                note("SKIPPED: no `home.listing.first` row on Home — the gate in step 09 did not create a project.")
                return
            }
            tap(row)
            guard waitForAny(ids: ["detail.photoStudio"], labels: ["TOOLBOX"], timeout: shortTimeout + 4) else {
                note("SKIPPED: the project's detail did not open.")
                popToRoot()
                return
            }
            settle(1.5)
            shot("\(i.tag)-10-own-detail")
            checkText("\(i.tag): next step \"Add a walkthrough video\"", "Add a walkthrough video")
            let studio = find(ids: ["detail.photoStudio"], labels: ["AI Photo Studio"], timeout: shortTimeout)
            let studioState: String
            if let studio { studioState = "isEnabled=\(studio.isEnabled)" } else { studioState = "tile missing" }
            check("\(i.tag): AI Photo Studio tile ENABLED on your own \(i.noun)",
                  studio != nil && studio?.isEnabled == true, actual: studioState)

            if scrollTo(ids: [], labels: ["MANAGE"], swipes: 8) != nil { settle(0.5) }
            shot("\(i.tag)-11-own-manage")
            checkText("\(i.tag): MANAGE section on your own \(i.noun)", "MANAGE")
            checkText("\(i.tag): \"Edit details\" action", "Edit details")
            checkText("\(i.tag): archive action \"Mark as \(i.archiveVerb)\" (SpaceType.archiveVerb)", "Mark as \(i.archiveVerb)")
            checkText("\(i.tag): \"Delete \(i.noun)\" action", "Delete \(i.noun)")
            let zillow = app.textFields["Paste Zillow URL"].exists
            if i.isRealEstate {
                check("\(i.tag): Zillow row present on a home", zillow)
            } else {
                check("\(i.tag): NO Zillow row on a \(i.noun)", !zillow)
                checkAbsent("\(i.tag): no \"Zillow\" anywhere on your own \(i.noun)", "Zillow")
            }
            checkContains("\(i.tag): LEADS explains publishing first",
                          "Publish your tour to start collecting leads")
            note("COMPLIANCE card and the share / MLS link cards: not reachable — they need a published listing "
                 + "on the live backend. See docs/qa/industry-review.md for the static findings on both.")
            vocabularyScan(i, screen: "your own \(i.noun) detail")
        }
        stepAerial(i)
        stepFloorPlan(i)
        stepReelEntry(i)
        stepEditSheet(i)
        popToRoot()
    }

    /// The Aerial intro sheet in its form state — a real project, so the form
    /// is shown. Nothing is generated.
    private func stepAerial(_ i: Industry) {
        activity("\(i.tag) — 12 Aerial intro sheet") {
            guard onOwnProjectDetail(i) else {
                note("SKIPPED: not on the project's detail.")
                return
            }
            scrollToTop()
            guard let tile = scrollTo(ids: [], labels: ["Aerial intro"], swipes: 8), tile.isEnabled else {
                note("SKIPPED: the \"Aerial intro\" tool card is absent or disabled.")
                return
            }
            tap(tile)
            guard waitForAny(ids: [], labels: ["Golden hour", "Rise & reveal", "Generate generic scenery"],
                             timeout: screenTimeout) else {
                note("SKIPPED: the aerial sheet did not open.")
                dismissTopScreen()
                return
            }
            settle(1.2)
            shot("\(i.tag)-12-aerial")
            checkContains("\(i.tag): aerial header \"A cinematic AI opening shot for this \(i.noun)\"",
                          "A cinematic AI opening shot for this \(i.noun)")
            checkContains("\(i.tag): no-photo warning names a generic \(i.noun)", "invents a generic \(i.noun)")
            checkContains("\(i.tag): disclosure says \"not real drone footage of this \(i.noun)\"",
                          "not real drone footage of this \(i.noun)")
            checkText("\(i.tag): time of day \"Golden hour\"", "Golden hour")
            checkText("\(i.tag): camera move \"Rise & reveal\"", "Rise & reveal")
            checkContains("\(i.tag): \"Generate generic scenery\" button (no exterior photo)", "Generate generic scenery")
            if !i.isRealEstate, find(ids: [], labels: ["THE PROPERTY"], timeout: 0.5) != nil {
                note("NOTE: the aerial sheet's kicker reads \"THE PROPERTY\" for \(i.displayName) — shared copy, "
                     + "listed in docs/qa/industry-review.md.")
            }
            vocabularyScan(i, screen: "Aerial intro")
            dismissTopScreen()              // Close
            settle(0.5)
        }
    }

    /// The Floor plan screen. The simulator has no LiDAR, so this is the
    /// upload-a-blueprint path; RoomPlan scanning is a device test.
    private func stepFloorPlan(_ i: Industry) {
        activity("\(i.tag) — 13 Floor plan") {
            guard onOwnProjectDetail(i) else {
                note("SKIPPED: not on the project's detail.")
                return
            }
            scrollToTop()
            guard let tile = scrollTo(ids: [], labels: ["Floor plan"], swipes: 8), tile.isEnabled else {
                note("SKIPPED: the \"Floor plan\" tool card is absent or disabled.")
                return
            }
            tap(tile)
            guard waitForAny(ids: [],
                             labels: ["Add a floor plan", "Scan one room", "Room plan ready", "Floor plan ready"],
                             timeout: screenTimeout) else {
                note("SKIPPED: the Floor plan screen did not open.")
                dismissTopScreen()
                return
            }
            settle(1)
            shot("\(i.tag)-13-floor-plan")
            check("\(i.tag): floor plan screen offers a scan or an upload",
                  find(ids: [], labels: ["Upload floor plan (PDF or image)", "Start scan"], timeout: 1) != nil)
            note("RoomPlan scanning cannot run in the simulator (no LiDAR) — only the upload path shows here.")
            vocabularyScan(i, screen: "Floor plan")
            dismissTopScreen()              // Back
            settle(0.5)
        }
    }

    /// The toolbox's "Make a reel" entry lands in the studio with the reel
    /// card ringed. Still disabled — no photos — and photographed as such.
    private func stepReelEntry(_ i: Industry) {
        activity("\(i.tag) — 14 Make a reel entry (toolbox → studio)") {
            guard onOwnProjectDetail(i) else {
                note("SKIPPED: not on the project's detail.")
                return
            }
            scrollToTop()
            guard let tile = scrollTo(ids: ["detail.reelStudio"], labels: ["Make a reel"], swipes: 8), tile.isEnabled else {
                note("SKIPPED: the \"Make a reel\" tool card is absent or disabled.")
                return
            }
            tap(tile)
            guard waitForAny(ids: [], labels: ["AI Photo Studio"], timeout: screenTimeout) else {
                note("SKIPPED: the studio did not open from the reel tile.")
                dismissTopScreen()
                return
            }
            settle(1.2)
            shot("\(i.tag)-14-reel-entry")
            checkContains("\(i.tag): reel card names \"Voice + captions\"", "Voice + captions")
            checkContains("\(i.tag): reel card explains \"Add 2 photos to start\"", "Add 2 photos to start")
            dismissTopScreen()              // Back to the detail
            settle(0.5)
        }
    }

    /// MANAGE → Edit details: the same form, prefilled. Cancelled, never saved.
    private func stepEditSheet(_ i: Industry) {
        activity("\(i.tag) — 15 Edit \(i.noun) sheet") {
            guard onOwnProjectDetail(i) else {
                note("SKIPPED: not on the project's detail.")
                return
            }
            guard let edit = scrollTo(ids: [], labels: ["Edit details"], swipes: 8) else {
                note("SKIPPED: no \"Edit details\" action.")
                return
            }
            tap(edit)
            guard waitForAny(ids: [], labels: ["Edit \(i.noun)", i.formDetailsHeader], timeout: screenTimeout) else {
                note("SKIPPED: the edit sheet did not open.")
                dismissTopScreen()
                return
            }
            settle(1)
            shot("\(i.tag)-15-edit-sheet")
            check("\(i.tag): edit sheet titled \"Edit \(i.noun)\"",
                  app.navigationBars["Edit \(i.noun)"].exists || find(ids: [], labels: ["Edit \(i.noun)"], timeout: 1) != nil)
            // The sheet's own name field first (its label stays the placeholder
            // even when filled); `firstMatch` could be a field of the screen
            // underneath, such as the real-estate Zillow row.
            let named = app.textFields[i.addressPlaceholder]
            let field = named.exists ? named : app.textFields.firstMatch
            let value = (field.value as? String) ?? ""
            check("\(i.tag): edit sheet is prefilled with \"\(i.walkName)\"", value.contains(i.walkName), actual: value)
            checkText("\(i.tag): edit sheet shows \"\(i.formDetailsHeader)\"", i.formDetailsHeader)
            vocabularyScan(i, screen: "Edit \(i.noun) sheet")
            dismissTopScreen()              // Cancel — nothing is saved
            settle(0.5)
        }
    }

    // MARK: 16 — Leads (Home banner)

    private func stepLeads(_ i: Industry) {
        activity("\(i.tag) — 16 Leads") {
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
            guard waitForAny(ids: [], labels: ["No leads yet", "Loading leads…", "Sign in to see your leads"],
                             timeout: screenTimeout) else {
                note("SKIPPED: the Leads screen did not open — capturing whatever is on screen.")
                shot("\(i.tag)-16-leads")
                popToRoot()
                return
            }
            settle(2)                       // the mock answers with an empty list
            shot("\(i.tag)-16-leads")
            checkText("\(i.tag): empty state \"No leads yet\" (mock returns none)", "No leads yet")
            checkContains("\(i.tag): empty-state hint", "Leads from your tours appear here.")
            vocabularyScan(i, screen: "Leads")
            popToRoot()
        }
    }

    // MARK: 17–18 — Profile + the card editor

    private func stepProfile(_ i: Industry) {
        activity("\(i.tag) — 17 Profile + \(i.profileCardName)") {
            popToRoot()
            guard openProfileTab() else {
                note("SKIPPED: no Profile tab.")
                return
            }
            settle(1.5)
            shot("\(i.tag)-17-profile")
            check("\(i.tag): Profile offers \"Set up card\" / \"Edit card\"",
                  find(ids: [], labels: ["Set up card", "Edit card"], timeout: 1) != nil)
            vocabularyScan(i, screen: "Profile")

            guard let edit = find(ids: [], labels: ["Set up card", "Edit card"], timeout: shortTimeout) else {
                note("SKIPPED: no card button on Profile.")
                return
            }
            tap(edit)
            guard waitForAny(ids: [], labels: [i.profileCardName, "Your details"], timeout: screenTimeout) else {
                note("SKIPPED: the card editor did not open.")
                popToRoot()
                return
            }
            settle(1)
            shot("\(i.tag)-18-card-editor")
            check("\(i.tag): card editor titled \"\(i.profileCardName)\" (SpaceType.profileCardName)",
                  app.navigationBars[i.profileCardName].exists
                    || find(ids: [], labels: [i.profileCardName], timeout: 1) != nil)
            checkText("\(i.tag): photo section \"\(i.profilePhotoLabel)\" (SpaceType.profilePhotoLabel)", i.profilePhotoLabel)
            check("\(i.tag): name field \"\(i.profileNameLabel)\" (SpaceType.profileNameLabel)",
                  app.textFields[i.profileNameLabel].exists)
            check("\(i.tag): org field \"\(i.profileOrgLabel)\" (SpaceType.profileOrgLabel)",
                  app.textFields[i.profileOrgLabel].exists)
            checkContains("\(i.tag): footer names \(i.customer) and \"\(i.cta.lowercased())\"",
                          "This is the card \(i.customer) see at the end of every tour — how they reach you to \(i.cta.lowercased()).")
            checkContains("\(i.tag): preview placeholder \"\(i.businessLabel) · phone\" (SpaceType.businessLabel)",
                          "\(i.businessLabel) · phone")
            vocabularyScan(i, screen: i.profileCardName)
            popToRoot()
        }
    }

    // MARK: 19 — Settings

    private func stepSettings(_ i: Industry) {
        activity("\(i.tag) — 19 Settings") {
            popToRoot()
            guard openSettingsTab() else {
                note("SKIPPED: no Settings tab.")
                return
            }
            _ = waitForAny(ids: [], labels: ["Plan & usage", "Business type"], timeout: screenTimeout)
            scrollToTop()
            settle(1.5)
            shot("\(i.tag)-19-settings")
            checkContains("\(i.tag): Business type row reads \"\(i.displayName)\"", i.displayName)
            checkContains("\(i.tag): Brand kit row is \"\(i.profileCardName)\"", i.profileCardName)
            checkContains("\(i.tag): Brand kit footer addresses \(i.customer)",
                          "The card \(i.customer) see at the end of every tour")
            checkText("\(i.tag): \"AI processing\" row (Guideline 5.1.2(i))", "AI processing")
            vocabularyScan(i, screen: "Settings")
        }
    }

    // MARK: 20–21 — Settings › Business type

    private func stepBusinessType(_ i: Industry) {
        activity("\(i.tag) — 20 Settings › Business type") {
            popToRoot()
            guard openSettingsTab() else {
                note("SKIPPED: no Settings tab.")
                return
            }
            scrollToTop()
            guard let row = scrollTo(ids: [], labels: [i.displayName], swipes: 4) else {
                note("SKIPPED: no \"\(i.displayName)\" row under Business type.")
                return
            }
            tap(row)
            guard waitForAny(ids: [], labels: ["What do you show off?"], timeout: screenTimeout) else {
                note("SKIPPED: the Business type screen did not open.")
                popToRoot()
                return
            }
            settle(1)
            shot("\(i.tag)-20-business-type")
            for type in Industry.all {
                checkContains("\(i.tag): type card \"\(type.displayName)\" with pitch \"\(type.pitch)\"", type.pitch)
            }
            let selected = NSPredicate(format: "label BEGINSWITH[c] %@ AND label CONTAINS[c] %@", i.displayName, "Selected")
            check("\(i.tag): \"\(i.displayName)\" card is the selected one",
                  app.descendants(matching: .any).matching(selected).firstMatch.exists)
            checkContains("\(i.tag): preview \"How \(i.displayName) mode works\"", "How \(i.displayName) mode works")
            checkText("\(i.tag): preview \"TOUR STOPS \(i.customer.uppercased()) CAN JUMP TO\"",
                      "TOUR STOPS \(i.customer.uppercased()) CAN JUMP TO")
            for tagName in i.quickTags {
                checkText("\(i.tag): area tag chip \"\(tagName)\" (SpaceType.quickTags)", tagName)
            }
            checkText("\(i.tag): preview \"DETAILS YOU CAN SHOW\"", "DETAILS YOU CAN SHOW")
            let detailChips = i.isRealEstate ? ["Beds", "Baths", "Sq ft", "Price"] : Array(i.detailFieldLabels.prefix(5))
            for chip in detailChips {
                checkText("\(i.tag): details chip \"\(chip)\"", chip)
            }
            checkText("\(i.tag): preview \"YOUR TOUR'S BUTTON\"", "YOUR TOUR'S BUTTON")
            checkText("\(i.tag): tour button reads \"\(i.cta)\" (SpaceType.ctaTitle)", i.cta)
            if scrollTo(ids: [], labels: ["YOUR TOUR'S BUTTON"], swipes: 6) != nil {
                settle(0.6)
                shot("\(i.tag)-21-business-type-preview")
            }
            // No vocabulary scan here on purpose: this screen lists every type.
            popToRoot()
        }
    }

    // MARK: 22–23 — Plan & usage + the paywall

    private func stepPlanAndPaywall(_ i: Industry) {
        activity("\(i.tag) — 22 Plan & usage + paywall") {
            popToRoot()
            guard openSettingsTab() else {
                note("SKIPPED: no Settings tab.")
                return
            }
            scrollToTop()
            if scrollTo(ids: [], labels: ["Plan & usage"], swipes: 8) == nil {
                note("The \"Plan & usage\" header never scrolled into view — capturing Settings as it stands.")
            }
            settle(1.5)
            shot("\(i.tag)-22-plan-usage")
            checkContains("\(i.tag): usage row \"Tour renders\"", "Tour renders")

            guard let upgrade = scrollTo(ids: ["settings.upgradePlan"], labels: ["Upgrade plan"],
                                         swipes: 6, perSwipeTimeout: 0.5) else {
                note("SKIPPED: no `settings.upgradePlan` / \"Upgrade plan\" row (hidden when /me reports a paid plan).")
                return
            }
            tap(upgrade)
            guard waitForAny(ids: ["paywall.root"],
                             labels: ["Turn any phone walkthrough", "Pick a plan"],
                             timeout: screenTimeout) else {
                note("SKIPPED: tapped \"Upgrade plan\" but no `paywall.root` appeared — capturing whatever is on screen.")
                shot("\(i.tag)-23-paywall")
                return
            }
            check("\(i.tag): paywall opens from Settings › Upgrade plan", true)
            let loaded = waitForProducts()
            settle(1.5)
            shot("\(i.tag)-23-paywall")
            if loaded {
                checkContains("\(i.tag): paywall header is industry-neutral", "Turn any phone walkthrough into a cinematic tour")
                vocabularyScan(i, screen: "Paywall (plan cards)")
            } else {
                note("Paywall EMPTY state: no StoreKit price rendered within \(Int(productTimeout))s, so the plan-card "
                     + "copy could not be checked for \(i.displayName). See the STOREKIT note.")
            }
            closePaywall()
            check("\(i.tag): paywall closed without touching a purchase button", app.buttons["Close"].exists == false)
        }
    }

    // MARK: 24 — Legal & support

    private func stepLegal(_ i: Industry) {
        activity("\(i.tag) — 24 Settings › Legal & support") {
            popToRoot()
            guard openSettingsTab() else {
                note("SKIPPED: no Settings tab.")
                return
            }
            scrollToTop()
            if scrollTo(ids: [], labels: ["Legal & support", "Terms of Service"], swipes: 10) == nil {
                note("Neither \"Legal & support\" nor \"Terms of Service\" scrolled into view — capturing Settings as it stands.")
            }
            settle(1)
            shot("\(i.tag)-24-legal")
            checkText("\(i.tag): \"Terms of Service\" link", "Terms of Service")
            checkText("\(i.tag): \"Privacy Policy\" link", "Privacy Policy")
            checkContains("\(i.tag): \"Contact support\" link", "Contact support")
            checkContains("\(i.tag): report-content link", "Report a problem with AI content")
            note("The legal links are not tapped — they open Safari / Mail, outside the app.")
        }
    }

    // MARK: 25–26 — Delete account: the confirmation, then Cancel. NEVER Delete.

    private func stepDeleteAccount(_ i: Industry) {
        activity("\(i.tag) — 25 Settings › Delete account") {
            popToRoot()
            guard openSettingsTab() else {
                note("SKIPPED: no Settings tab.")
                return
            }
            scrollToTop()
            guard let row = scrollTo(ids: [], labels: ["Delete account"], swipes: 10) else {
                note("SKIPPED: no \"Delete account\" button in Settings (Guideline 5.1.1(v)).")
                return
            }
            settle(1)
            shot("\(i.tag)-25-delete-account")

            activity("\(i.tag) — 26 Delete account confirmation (Cancel only)") {
                tap(row)                    // ONCE. Never again in this test.
                guard waitForAny(ids: [],
                                 labels: ["Delete account?", "Sign in to delete your account"],
                                 timeout: shortTimeout + 3) else {
                    note("SKIPPED: tapping \"Delete account\" raised no confirmation within \(Int(shortTimeout) + 3)s. "
                         + "Nothing was confirmed.")
                    dismissDeleteDialogSafely()
                    return
                }
                settle(1)
                shot("\(i.tag)-26-delete-confirm")
                check("\(i.tag): delete-account confirmation appears before anything is deleted", true)
                dismissDeleteDialogSafely()
                check("\(i.tag): confirmation dismissed with Cancel — nothing deleted",
                      find(ids: [], labels: ["Delete account?"], timeout: 0.5) == nil)
            }
        }
    }

    /// Leave the delete flow without deleting anything. Cancel first; if the
    /// dialog somehow has no Cancel, press the first button that is NOT one of
    /// the data-destroying ones; if nothing safe is on offer the dialog is left
    /// standing on purpose. (Verbatim from ReviewerWalk.)
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

    // MARK: - The business-type switcher

    /// The nav-bar capsule on Home (`HomeDashboardView.businessTypeMenu`): a
    /// Menu whose label is the current type's display name.
    private func typeCapsule() -> XCUIElement? {
        for industry in Industry.all {
            let predicate = NSPredicate(format: "label BEGINSWITH[c] %@", industry.displayName)
            let inBar = app.navigationBars.buttons.matching(predicate).firstMatch
            if inBar.exists { return inBar }
        }
        for industry in Industry.all {
            let predicate = NSPredicate(format: "label BEGINSWITH[c] %@", industry.displayName)
            let anyButton = app.buttons.matching(predicate).firstMatch
            if anyButton.exists { return anyButton }
        }
        return nil
    }

    /// Which type the capsule shows, read from its label.
    private func currentTypeOnHome() -> Industry? {
        guard let capsule = typeCapsule() else { return nil }
        let label = capsule.label
        for industry in Industry.all where label.hasPrefix(industry.displayName) {
            return industry
        }
        return nil
    }

    /// Open the capsule's menu and pick `target`. True once Home shows the
    /// target's hero headline.
    private func switchType(to target: Industry, menuShot: String?) -> Bool {
        _ = openHomeTab()
        scrollToTop()
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
        if let menuShot { shot(menuShot) }
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

    /// The fallback: `-space.type <raw>` in the argument domain.
    private func relaunchPinned(_ i: Industry) {
        app.terminate()
        app.launchArguments = baseLaunchArguments + ["-space.type", i.raw]
        app.launch()
        _ = waitForHome(timeout: screenTimeout)
        settle(1.5)
    }

    // MARK: - Navigation helpers (mirroring StoreShots / ReviewerWalk)

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

    @discardableResult
    private func openProfileTab() -> Bool {
        openTab("Profile", ids: [], confirmedBy: ["Set up your card", "Set up card", "Edit card"])
    }

    /// The second tab, titled with this type's plural noun. Tapped directly
    /// rather than through `openTab`: every label it shows is also on the Home
    /// dashboard. When the expected title is missing, any other industry's
    /// title is tried so the shot is still taken — and that mismatch is a CHECK.
    private func openCollectionTab(_ i: Industry) -> Bool {
        let tab = app.tabBars.buttons[i.tabTitle]
        if tab.waitForExistence(timeout: shortTimeout) {
            // A tab tap while a screen is pushed on the current tab pops that
            // stack instead of switching (proven on the 6 Sep walk: every
            // "03-collection" shot was Home). Tap, confirm the tab is selected
            // and its nav title is up, and tap once more if it is not.
            for attempt in 0..<3 {
                tab.tap()
                settle(1.2)
                if tab.isSelected, find(ids: [], labels: [i.collectionTitle], timeout: shortTimeout) != nil { break }
                if attempt == 2 {
                    note("Tapped the \"\(i.tabTitle)\" tab three times but it never reported itself selected with "
                         + "\"\(i.collectionTitle)\" up — the shot may be whatever tab was already showing.")
                }
            }
            if !app.searchFields.firstMatch.waitForExistence(timeout: 1) {
                note("The \"\(i.tabTitle)\" tab's search field is not in the hierarchy (iOS 26 keeps it "
                     + "collapsed under the title until the list is pulled down) — the prompt check reads it as absent.")
            }
            return true
        }
        for other in Industry.all where other.raw != i.raw {
            let alt = app.tabBars.buttons[other.tabTitle]
            if alt.exists {
                check("\(i.tag): second tab is titled \"\(i.tabTitle)\"", false, actual: "tab bar shows \"\(other.tabTitle)\"")
                alt.tap()
                settle(1.5)
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

    /// Open this type's seeded sample from the collection tab — the row whose
    /// label carries the sample address, else any row labelled "(Sample)".
    private func openFirstSample(_ i: Industry) -> Bool {
        guard openCollectionTab(i) else { return false }
        settle(1.5)
        for needle in [i.sampleAddress, "Sample"] {
            let predicate = NSPredicate(format: "label CONTAINS[c] %@", needle)
            for query in [app.buttons, app.cells, app.otherElements] {
                let element = query.matching(predicate).firstMatch
                if element.exists {
                    tap(element)
                    return waitForAny(ids: [], labels: ["TOOLBOX", "SAMPLE TOUR", "This is a sample"],
                                      timeout: screenTimeout)
                }
            }
        }
        return false
    }

    /// True while the walk's own project detail is the top screen.
    private func onOwnProjectDetail(_ i: Industry) -> Bool {
        app.navigationBars[i.walkName].exists
            || (find(ids: ["detail.photoStudio"], labels: ["TOOLBOX"], timeout: 1) != nil
                && find(ids: [], labels: ["MANAGE"], timeout: 0.5) != nil)
    }

    /// The "which home?" gate after a Home feature tile:
    ///   • no project of this type → "Name this <noun> first" → type a name → Save and continue
    ///   • two or more → "Pick a <noun>" → the first row
    ///   • exactly one → pushed straight in, nothing to do.
    private func resolveProjectGate(_ i: Industry) {
        if waitForAny(ids: [], labels: ["Name this \(i.noun) first", "Save and continue"], timeout: shortTimeout) {
            checkText("\(i.tag): first-project gate titled \"Name this \(i.noun) first\"", "Name this \(i.noun) first")
            check("\(i.tag): gate field placeholder \"\(i.addressPlaceholder)\"",
                  app.textFields[i.addressPlaceholder].exists, actual: firstTextFieldPlaceholder())
            shot("\(i.tag)-09a-name-gate")
            typeIntoField(i.walkName, placeholder: i.addressPlaceholder)
            dismissKeyboard()
            if let save = find(ids: [], labels: ["Save and continue"], timeout: shortTimeout) {
                tap(save)
            }
            return
        }
        if waitForAny(ids: [], labels: ["Pick a \(i.noun)"], timeout: 1.5) {
            note("The \"Pick a \(i.noun)\" picker appeared (two or more projects of this type already exist — "
                 + "a re-run on a dirty simulator). Choosing the first row.")
            shot("\(i.tag)-09a-pick-gate")
            let row = app.cells.firstMatch
            if row.waitForExistence(timeout: shortTimeout) { tap(row) }
            return
        }
        // Exactly one project: the studio was pushed directly.
    }

    private func typeIntoField(_ text: String, placeholder: String) {
        let named = app.textFields[placeholder]
        let field = named.exists ? named : app.textFields.firstMatch
        guard field.waitForExistence(timeout: shortTimeout) else { return }
        field.tap()
        settle(0.4)
        field.typeText(text)
    }

    private func firstTextFieldPlaceholder() -> String {
        let field = app.textFields.firstMatch
        guard field.exists else { return "no text field" }
        return field.placeholderValue ?? "no placeholder"
    }

    private func tabTitles() -> String {
        app.tabBars.buttons.allElementsBoundByIndex.map { $0.label }.joined(separator: ", ")
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

    /// Unwind any pushed screens and sheets so the next step starts from a tab
    /// root. Bounded, so a screen that refuses to dismiss cannot spin forever.
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

    // MARK: - Checks (activities named CHECK PASS / CHECK FAIL — never assertions)

    /// One expectation, written into the result bundle. `actual` is appended
    /// to a failure so the reader sees what the screen said instead.
    private func check(_ what: String, _ condition: Bool, actual: String = "") {
        if condition {
            note("CHECK PASS \(what)")
        } else {
            let detail = actual.trimmingCharacters(in: .whitespacesAndNewlines)
            note("CHECK FAIL \(what)" + (detail.isEmpty ? "" : ": \(String(detail.prefix(240)))"))
        }
    }

    /// An element whose label IS (or begins with) `text` — the same lookup the
    /// other walks use to find buttons and titles.
    private func checkText(_ what: String, _ text: String, timeout: TimeInterval = 2) {
        let found = find(ids: [], labels: [text], timeout: timeout) != nil
        check(what, found, actual: found ? "" : "no element labelled \"\(text)\"")
    }

    /// A tile in a lazy grid or list: scrolled into view (down the page) before
    /// it is judged absent — off-screen lazy rows are not in the hierarchy.
    private func checkTile(_ what: String, _ text: String) {
        let found = scrollTo(ids: [], labels: [text], swipes: 3, perSwipeTimeout: 0.6) != nil
            || labelElement(containing: text, timeout: 0.5) != nil
        check(what, found, actual: found ? "" : "no element labelled \"\(text)\" (after scrolling)")
    }

    /// Any element whose label CONTAINS `text` — for sentences folded into a
    /// combined label, and for multi-line copy.
    private func checkContains(_ what: String, _ text: String, timeout: TimeInterval = 2) {
        let found = labelElement(containing: text, timeout: timeout) != nil
        check(what, found, actual: found ? "" : "no label containing \"\(text)\"")
    }

    /// No element's label may contain `text`. A short poll so a screen that is
    /// still animating in cannot pass by accident.
    private func checkAbsent(_ what: String, _ text: String) {
        let offender = labelElement(containing: text, timeout: 0.6)
        check(what, offender == nil, actual: offender.map { "found \"\(String($0.label.prefix(160)))\"" } ?? "")
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

    /// The cross-industry vocabulary check. Every element in the current
    /// accessibility tree whose label matches this type's forbidden-word regex
    /// is quoted in a CHECK FAIL; none is a CHECK PASS. Word-anchored so
    /// "In-house" or "personal" cannot trip it; the tab title "Home" is
    /// allowed by `allowedExactLabels`.
    private func vocabularyScan(_ i: Industry, screen: String) {
        let predicate = NSPredicate(format: "label MATCHES[c] %@", i.forbiddenRegex)
        let matches = app.descendants(matching: .any).matching(predicate).allElementsBoundByIndex
        var hits: [String] = []
        for element in matches.prefix(14) {
            let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty { continue }
            // The tab bar's "Home" is allowed whatever case the AX tree reports it in.
            if i.allowedExactLabels.contains(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) { continue }
            // Name the element, not just its words — so a hit can be traced
            // to the view that produced it ("home" [Button id=…]).
            let identifier = element.identifier.isEmpty ? "" : " id=\(element.identifier)"
            let short = String(label.replacingOccurrences(of: "\n", with: " ").prefix(110))
                + " [type=\(element.elementType.rawValue)\(identifier)]"
            if !hits.contains(short) { hits.append(short) }
            if hits.count >= 6 { break }
        }
        check("\(i.tag): no \(i.forbiddenDescription) on \(screen)", hits.isEmpty,
              actual: hits.map { "\"\($0)\"" }.joined(separator: " | "))
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

    // MARK: - Screenshots, activities and waiting

    /// Full-screen capture, status bar included — the same recipe StoreShots
    /// and ReviewerWalk use, so the bridge script's 9:41 status bar shows up.
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func activity(_ name: String, _ body: () -> Void) {
        XCTContext.runActivity(named: name) { _ in body() }
    }

    /// A line in the result bundle. Named activities are the only place a
    /// non-failing note — and every CHECK — survives into the `.xcresult`.
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
