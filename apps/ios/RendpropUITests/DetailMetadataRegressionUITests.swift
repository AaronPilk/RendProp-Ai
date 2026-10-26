import XCTest

/// Run with -configuration Release. Each test cold-launches the actual detail
/// screen so metadata is first instantiated for that state. Procedural local
/// photos/video exercise production SwiftUI/AVFoundation views, without a
/// camera, microphone, customer account, upload, AI call or destructive action.
final class DetailMetadataRegressionUITests: XCTestCase {
    private var app: XCUIApplication!
    private let tileIDs = ["detail.photos", "detail.photoStudio", "detail.reelStudio",
                           "detail.recordedWalkthrough", "detail.roomTags", "detail.aerialOpening"]
    /// Floor plans and 3D remain plain Coming soon cards in release builds.
    /// Aerial intro is an active tool with its own review screen.
#if SPATIAL_CAPTURE_LAB
    private let comingSoonIDs: [String] = []
#else
    private let comingSoonIDs = ["detail.measurementsComingSoon", "detail.spatialComingSoon"]
#endif

    override func setUpWithError() throws {
#if targetEnvironment(simulator)
        continueAfterFailure = false
        app = XCUIApplication()
#else
        throw XCTSkip("Synthetic detail metadata fixtures exist only in simulator builds.")
#endif
    }

    override func tearDownWithError() throws {
        if app != nil {
            attach("detail-final")
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "detail-accessibility"; tree.lifetime = .keepAlways; add(tree)
            app.terminate()
        }
    }

    func testSampleHasAllSixToolsDisabledAndComingSoonCards() {
        launch("sample")
        assertTiles(sample: true, hasCapture: false)
        let share = app.buttons["detail.sharePackage"]; scrollTo(share)
        XCTAssertFalse(share.isEnabled, "Sample listings cannot export a package")
        XCTAssertFalse(element("detail.rerenderTour").exists)
        XCTAssertFalse(element("detail.rerenderUnavailable").exists)
        XCTAssertFalse(app.buttons["listing.clientContact"].exists)
    }

    func testPublishedShareControlsOpenQRWithTheDisplayedFallbackLink() {
        launch("published-no-source")
        let copy = app.buttons["Copy Your link"]
        scrollTo(copy)
        XCTAssertTrue(copy.isEnabled)
        let qr = app.buttons["QR code for Your link"]
        XCTAssertTrue(qr.exists && qr.isEnabled)
        attach("published-share-controls")
        qr.tap()
        let expected = "https://example.invalid/f/metadata-fixture"
        XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.images["QR code that opens \(expected)"].exists, app.debugDescription)
        attach("published-share-qr")
    }

    func testEmptyListingStillOpensPhotoLibraryAndStudioWhileMeasurementsIsComingSoon() {
        launch("empty")
        assertTiles(sample: false, hasCapture: false)
        let share = app.buttons["detail.sharePackage"]; scrollTo(share)
        XCTAssertFalse(share.isEnabled, "An empty listing has nothing to package")
        attach("detail-empty-balanced-toolbox")
        let tags = app.buttons["detail.roomTags"]
        scrollTo(tags); tags.tap()
        let help = app.alerts["Add a walkthrough first"]
        XCTAssertTrue(help.waitForExistence(timeout: 5), app.debugDescription)
        let prerequisite = help.staticTexts.matching(NSPredicate(format: "label == %@",
            "Record or upload a drone-style walkthrough before tagging rooms or areas. Tags follow that video's timeline. A photo-based listing video or sample tour doesn't add walkthrough footage.")).firstMatch
        XCTAssertTrue(prerequisite.exists, help.debugDescription)
        help.buttons["Cancel"].tap() // Inspect the prerequisite only; never open capture/upload.
        XCTAssertFalse(element("detail.rerenderTour").exists)
        XCTAssertFalse(element("detail.rerenderUnavailable").exists)
        openLink("detail.photos", title: "Photos")
        XCTAssertTrue(app.buttons["photos.takePhoto"].exists) // Inspect only; never tap camera.
        back(from: "Photos")
        openLink("detail.photoStudio", title: "AI Photo Studio")
        XCTAssertTrue(app.buttons["studio.edit.declutter"].exists, app.debugDescription)
        back(from: "AI Photo Studio")
        assertMeasurementsStaysComingSoon(fixture: "empty")
        XCTAssertTrue(app.buttons["detail.aerialOpening"].exists, "Aerial intro stays discoverable before a front exterior photo is added")
    }

    func testCapturedUnrenderedListingKeepsRoomTaggingAndNoRerenderTile() {
        launch("capture")
        assertTiles(sample: false, hasCapture: true)
        XCTAssertFalse(element("detail.rerenderTour").exists)
        XCTAssertFalse(element("detail.rerenderUnavailable").exists)
        openSheet("detail.roomTags", title: "Tag rooms", close: "Done")
    }

    func testAerialIntroReturnKeepsVideoToolReachable() {
        launch("rich")
        openLink("detail.aerialOpening", title: "Aerial intro")
        back(from: "Aerial intro")
        let video = app.buttons["detail.reelStudio"]
        scrollTo(video); video.tap()
        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Choose your photos"].exists, app.debugDescription)
        // Navigation only: no photo selection, processing or purchase.
    }

    func testPhotosCaptureTourAerialAndClientNavigateEveryTool() {
        launch("rich")
        assertTiles(sample: false, hasCapture: true)
        let photos = app.buttons["detail.photos"]
        scrollTo(photos)
        XCTAssertTrue(photos.label.contains("3 photos"), photos.label)
        let aerial = app.buttons["detail.aerialOpening"]
        scrollTo(aerial)
        XCTAssertTrue(aerial.isEnabled && aerial.label.contains("Front of home · opening only"), aerial.label)
        let rerender = app.buttons["detail.rerenderTour"]
        scrollTo(rerender)
        XCTAssertTrue(rerender.isEnabled)
#if SPATIAL_CAPTURE_LAB
        let lastMainTool = app.buttons["detail.spatialLab"]
#else
        let lastMainTool = element("detail.spatialComingSoon")
#endif
        XCTAssertTrue(lastMainTool.exists && lastMainTool.frame.height > 0, app.debugDescription)
        XCTAssertGreaterThanOrEqual(rerender.frame.minY, lastMainTool.frame.maxY,
            "Re-render follows the balanced main toolbox rows")
        let share = app.buttons["detail.sharePackage"]
        scrollTo(share)
        XCTAssertEqual(rerender.frame.width, share.frame.width, accuracy: 2,
            "Walkthrough re-render and sharing use full-width rows")
        XCTAssertGreaterThan(share.frame.minY, rerender.frame.maxY, "Sharing remains the last toolbox action")
        XCTAssertFalse(element("detail.rerenderUnavailable").exists)
        attach("detail-rich-toolbox")

        openLink("detail.photos", title: "Photos")
        back(from: "Photos")
        openLink("detail.photoStudio", title: "AI Photo Studio")
        XCTAssertTrue(app.buttons["studio.edit.declutter"].exists, app.debugDescription)
        back(from: "AI Photo Studio")
        assertMeasurementsStaysComingSoon(fixture: "rich")
        openLink("detail.aerialOpening", title: "Aerial intro")
        back(from: "Aerial intro") // Inspect the route only; never start a generation.
        openLink("listing.clientContact", title: "Listing contact")
        XCTAssertEqual(app.textFields["clientContact.name"].value as? String, "Fixture client")
        back(from: "Listing contact") // No save or client photo picker.
        openSheet("detail.roomTags", title: "Tag rooms", close: "Done")
        openLink("detail.rerenderTour", title: "Review & Submit")
        back(from: "Review & Submit") // Never submit or change render source.

        openVideo(purpose: "social_media")
        // The presenting detail remains in the accessibility tree behind the
        // cover. Match the clip's subtitle, which distinguishes it from the
        // toolbox tile without relying on the step's navigation title.
        let aerialClips = app.buttons.matching(NSPredicate(format:
            "label CONTAINS %@ AND label CONTAINS %@", "Aerial intro", "Opens the video"))
        XCTAssertEqual(aerialClips.count, 1, "Reel must receive exactly one local aerial clip")
        let reelAerial = aerialClips.firstMatch
        scrollTo(reelAerial)
        XCTAssertTrue(reelAerial.exists, "Reel must receive the detail listing's aerial clip")
        attach("detail-rich-reel")
        closeVideo()
        XCTAssertTrue(app.navigationBars["Detail fixture rich"].waitForExistence(timeout: 10))
        scrollTo(app.buttons["detail.photos"])
        XCTAssertTrue(app.buttons["detail.photos"].isEnabled)
    }

    private func openVideo(purpose: String, aiCamera: Bool = false) {
        let video = app.buttons["detail.reelStudio"]
        scrollTo(video); video.tap()
        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 15), app.debugDescription)
        let firstPhoto = app.buttons["reel.photo.fixture-0"]
        scrollTo(firstPhoto)
        XCTAssertTrue(firstPhoto.exists, "Video must receive the detail listing's local photos")
        firstPhoto.tap()
        let next = app.buttons["video.setup.next"]
        XCTAssertTrue(next.isEnabled, app.debugDescription)
        next.tap()
        XCTAssertTrue(app.navigationBars["Look"].waitForExistence(timeout: 10), app.debugDescription)
        let choiceID: String
        switch purpose {
        case "social_media": choiceID = "video.purpose.social_media"
        case "listing": choiceID = "video.purpose.listing"
        default: XCTFail("Unsupported video purpose: \(purpose)"); return
        }
        let choice = app.buttons[choiceID]
        XCTAssertTrue(choice.waitForExistence(timeout: 10), app.debugDescription)
        scrollTo(choice); XCTAssertTrue(choice.isHittable); choice.tap()
        XCTAssertTrue(choice.isSelected, app.debugDescription)
        if aiCamera {
            // The enclosing Movement style group supplies its identifier to
            // child pills in SwiftUI's accessibility tree. Match the label.
            let camera = app.buttons.matching(NSPredicate(format: "label == %@", "AI camera")).firstMatch
            scrollTo(camera); camera.tap()
            XCTAssertTrue(camera.isSelected, app.debugDescription)
        }
    }

    private func openVideoOptions() {
        let automatic = app.buttons["video.motion.automatic"]
        XCTAssertTrue(automatic.waitForExistence(timeout: 5), app.debugDescription)
        scrollTo(automatic)
        XCTAssertTrue(automatic.isEnabled && automatic.isHittable, app.debugDescription)
    }

    private func closeVideo() {
        let lookBack = app.navigationBars["Look"].buttons.firstMatch
        XCTAssertTrue(lookBack.exists, app.debugDescription)
        lookBack.tap()
        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["video.setup.back"].tap()
        XCTAssertTrue(app.navigationBars["Detail fixture rich"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testMissingSourceIsAPlainUnavailableCardEvenWithLocalTour() {
        launch("missing-source")
        assertTiles(sample: false, hasCapture: true) // The missing raw file must not unlock a timeline.
        let unavailable = element("detail.rerenderUnavailable")
        scrollTo(unavailable)
        XCTAssertTrue(unavailable.exists)
        XCTAssertFalse(app.buttons["detail.rerenderUnavailable"].exists, "Unavailable card must not become a navigation action")
        XCTAssertFalse(element("detail.rerenderTour").exists)
        XCTAssertTrue(app.buttons["detail.photos"].label.contains("1 photo"))
    }

    func testPublishedLinkWithoutCaptureKeepsShareAndDisabledRoomTagging() {
        launch("published-no-source")
        assertTiles(sample: false, hasCapture: false)
        scrollTo(element("detail.rerenderUnavailable"))
        XCTAssertTrue(element("detail.rerenderUnavailable").exists)
        XCTAssertFalse(element("detail.rerenderTour").exists)
        XCTAssertTrue(app.buttons["detail.roomTags"].isEnabled, "A missing walkthrough explains its prerequisite on tap")
        openLink("listing.clientContact", title: "Listing contact")
        back(from: "Listing contact")
    }

    func testVenueKeepsIndustryAreaNounsAndRerenderNavigation() {
        launch("venue")
        assertTiles(sample: false, hasCapture: true)
        // The Coming soon checks finish below this lazy-grid row. Bring the
        // actual area-tagging tile back into view before reading its label.
        scrollTo(app.buttons["detail.roomTags"])
        XCTAssertTrue(app.buttons["detail.roomTags"].label.contains("Tag areas"))
        openSheet("detail.roomTags", title: "Tag areas", close: "Done")
        openLink("detail.rerenderTour", title: "Review & Submit")
        back(from: "Review & Submit")
    }

    func testReelCameraPresetsAndPhotoZIPDeliveryChoice() {
        launch("rich")
        openVideo(purpose: "social_media", aiCamera: true)
        openVideoOptions()
        for title in ["Fly-through", "Slow push-in", "Side glide", "Pull-back"] {
            // The enclosing Optional group overrides child accessibility IDs.
            let buttons = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title))
            let button = buttons.firstMatch
            scrollTo(button)
            XCTAssertEqual(buttons.count, 1, app.debugDescription)
            XCTAssertTrue(button.exists && button.isEnabled, app.debugDescription)
            button.tap(); XCTAssertTrue(button.isSelected)
        }
        XCTAssertFalse(app.textFields["e.g. 'slow push-in, golden-hour feel'"].exists)
        attach("build58-four-camera-presets")
        closeVideo()
        openLink("detail.photos", title: "Photos")
        let all = app.buttons["photos.shareAll"]; revealActive(all); all.tap()
        let delivery = app.segmentedControls["export.deliverAs"]
        revealActive(delivery)
        XCTAssertTrue(delivery.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(delivery.buttons.count, 2)
        XCTAssertTrue(delivery.buttons.element(boundBy: 0).isSelected)
        delivery.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(delivery.buttons.element(boundBy: 1).isSelected)
        delivery.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(delivery.buttons.element(boundBy: 0).isSelected)
        revealActive(app.buttons["export.share"])
        XCTAssertTrue(app.buttons["export.share"].isEnabled)
        attach("build58-zip-and-separate-photo-delivery")
    }

    func testShareEverythingIncludesTourAndListingDetailsAsDefaultZIP() {
        launch("rich")
        let share = app.buttons["detail.sharePackage"]
        scrollTo(share)
        XCTAssertTrue(share.isEnabled, app.debugDescription)
        attach("detail-rich-balanced-toolbox")
        share.tap()
        XCTAssertTrue(app.navigationBars["Share everything"].waitForExistence(timeout: 15), app.debugDescription)
        let primary = app.buttons["export.share"]
        XCTAssertEqual(app.buttons.matching(identifier: "export.share").count, 1)
        XCTAssertEqual(primary.label, "Share ZIP")
        XCTAssertTrue(primary.isEnabled && primary.isHittable, app.debugDescription)
        XCTAssertGreaterThanOrEqual(primary.frame.height, 44)
        attach("listing-package-overview")

        let files = app.staticTexts["Files & review notes"]
        revealCoordinatorContent(files); files.tap()
        // SwiftUI inherits the disclosure identifier into its children; locate
        // the material by its exact expected names, not the overridden child ID.
        let extras = app.staticTexts.matching(NSPredicate(format:
            "label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@",
            "walkthrough-tour.mp4", "listing-details.txt", "aerial-intro.mp4")).firstMatch
        XCTAssertTrue(extras.waitForExistence(timeout: 5), app.debugDescription)
        revealCoordinatorContent(extras)
        XCTAssertTrue(extras.label.contains("walkthrough-tour.mp4"), extras.label)
        XCTAssertTrue(extras.label.contains("listing-details.txt"), extras.label)
        XCTAssertTrue(extras.label.contains("aerial-intro.mp4"), extras.label)
        attach("listing-package-files")
        revealCoordinatorContent(files); files.tap()

        let formats = app.staticTexts["Formats & disclosures"]
        revealCoordinatorContent(formats); formats.tap()
        let masters = app.staticTexts.matching(NSPredicate(format:
            "label CONTAINS %@", "Full saved masters and retained sources keep their stored bytes.")).firstMatch
        XCTAssertTrue(masters.waitForExistence(timeout: 5), app.debugDescription)
        let pending = app.staticTexts["Pending staging is preview-only, with no listing or social copies. Unreviewed custom edits are withheld."]
        XCTAssertTrue(pending.waitForExistence(timeout: 5), app.debugDescription)
        revealCoordinatorContent(pending)
        attach("listing-package-disclosures")
        XCTAssertTrue(primary.isEnabled && primary.isHittable, "The single share action remains reachable while details are open")
        // Inspect only: package rendering and the system share action are not invoked.
    }

    func testRepublishSameLinkAndRecentlyDeletedNavigation() {
        launch("republish")
        let publish = app.buttons["detail.republish"]; scrollTo(publish)
        XCTAssertTrue(publish.isEnabled); publish.tap()
        XCTAssertTrue(app.staticTexts["detail.republished"].waitForExistence(timeout: 20), app.debugDescription)
        attach("build58-republished-receipt")
        let settings = app.buttons["build58.fixture.settings"]
        XCTAssertTrue(settings.exists, app.debugDescription); settings.tap()
        let trash = app.buttons["settings.recentlyDeleted"]; revealActive(trash); trash.tap()
        XCTAssertTrue(app.navigationBars["Recently deleted"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["recentlyDeleted.empty"].exists)
        attach("build58-recently-deleted-empty")
    }

    func testRepublishClearsStaleWarningAndKeepsSameLink() {
        launch("republish-stale")
        let warning = app.staticTexts["build59.fixture.warning"]
        let link = app.staticTexts["build59.fixture.link"]
        XCTAssertEqual(warning.label, "Warning: stale")
        let originalLink = "https://example.invalid/f/metadata-fixture"
        XCTAssertEqual(link.label, originalLink)
        let publish = app.buttons["detail.republish"]; scrollTo(publish)
        XCTAssertTrue(publish.isEnabled); publish.tap()
        XCTAssertTrue(app.staticTexts["detail.republished"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(warning.label, "Warning: none", "The actual listing warning must clear after republish")
        XCTAssertEqual(link.label, originalLink, "Republish must preserve the original link")
        attach("build59-republish-stale-warning-cleared")
    }

    private func launch(_ fixture: String) {
        app.launchArguments = ["-uiTesting", "-hasOnboarded", "YES", "-space.type", fixture == "venue" ? "venue" : "real_estate",
                               "-appearance", "light", "-ai.thirdPartyProcessing.consent.v3", "YES",
                               "-ui.detailMetadataFixture", fixture]
        app.launch()
        XCTAssertTrue(app.navigationBars["Detail fixture \(fixture)"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(element("detail.fixtureFailure").exists, app.debugDescription)
        attach("detail-\(fixture)-cold-launch")
    }

    private func assertTiles(sample: Bool, hasCapture: Bool) {
        for id in tileIDs {
            let tile = app.buttons[id]
            scrollTo(tile)
            XCTAssertTrue(tile.exists, "Missing \(id): \(app.debugDescription)")
            // Missing walkthroughs explain their prerequisite on tap; samples stay disabled.
            XCTAssertEqual(tile.isEnabled, !sample, id)
        }
        // Coming soon cards are present in every state, sample or not, and are
        // never buttons — the same oracle Home's showroom test applies.
        for id in comingSoonIDs {
            let card = element(id)
            scrollTo(card)
            XCTAssertTrue(card.exists, "Missing \(id): \(app.debugDescription)")
            XCTAssertTrue(card.label.contains("Coming soon"), "\(id) must read Coming soon: \(card.label)")
            XCTAssertFalse(app.buttons[id].exists, "Coming soon must not open a feature: \(id)")
        }
#if SPATIAL_CAPTURE_LAB
        for id in ["detail.floorPlanLab", "detail.spatialLab"] {
            let tile = app.buttons[id]
            scrollTo(tile)
            XCTAssertTrue(tile.exists, "Missing lab entry: \(id)")
            XCTAssertEqual(tile.isEnabled, !sample, "Samples cannot open lab destinations: \(id)")
        }
#endif
        XCTAssertFalse(element("detail.floorPlanComingSoon").exists, "Plans and measurements must have one shared entry")
        XCTAssertFalse(element("detail.floorPlan").exists, "The listing toolbox must not keep a live Measurements link")
        XCTAssertFalse(element("detail.clientContact").exists, "Listing contact must not be duplicated in the Toolbox")
        if !sample {
            let contact = app.buttons["listing.clientContact"]
            scrollTo(contact)
            XCTAssertTrue(contact.exists && contact.isEnabled, "The original contact entry remains available")
            XCTAssertEqual(app.buttons.matching(identifier: "listing.clientContact").count, 1)
            XCTAssertTrue(contact.label.contains("Who should buyers contact?"), contact.label)
        }
    }

    /// The owner's build-56 defect: "on the listing page Measurements is still
    /// clickable". Tapping the card must leave the detail screen exactly where
    /// it was — no push, no sheet, no "Measurements & plans" or "Floor plan"
    /// navigation bar — and Measurements must not reappear as a button.
    private func assertMeasurementsStaysComingSoon(fixture: String) {
#if SPATIAL_CAPTURE_LAB
        let plans = app.buttons["detail.floorPlanLab"]
        scrollTo(plans)
        XCTAssertTrue(plans.exists && plans.isEnabled, app.debugDescription)
        XCTAssertTrue(plans.label.contains("Floor plans & measurements"), plans.label)
        XCTAssertFalse(element("detail.measurementsComingSoon").exists)
#else
        let card = element("detail.measurementsComingSoon")
        scrollTo(card)
        XCTAssertTrue(card.exists, app.debugDescription)
        XCTAssertTrue(card.label.contains("Floor plans & measurements"), card.label)
        XCTAssertTrue(card.label.contains("Coming soon"), card.label)
        XCTAssertFalse(app.buttons["detail.measurementsComingSoon"].exists, "Coming soon must not open a feature")
        XCTAssertFalse(app.buttons["detail.floorPlan"].exists, app.debugDescription)
        card.tap()
        attach("destination-detail.measurementsComingSoon")
        XCTAssertFalse(app.navigationBars["Floor plans & measurements"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(app.navigationBars["Floor plan"].exists, app.debugDescription)
        XCTAssertFalse(app.navigationBars["Measurements"].exists, app.debugDescription)
#endif
        XCTAssertTrue(app.navigationBars["Detail fixture \(fixture)"].exists, "Tapping Coming soon must not navigate: \(app.debugDescription)")
        // SwiftUI restores the detail scroll position. The first lazy-grid
        // row may be offscreen and absent from accessibility after returning
        // from Studio or tapping a lower Coming soon card. Materialize the
        // actual card with the existing outer-page scroll helper before
        // checking it; a missing card or failed return still fails the test.
        let photos = app.buttons["detail.photos"]
        scrollTo(photos)
        XCTAssertTrue(photos.waitForExistence(timeout: 10), app.debugDescription)
    }

    private func openLink(_ id: String, title: String) {
        let tile = app.buttons[id]
        scrollTo(tile); tile.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 15), app.debugDescription)
        attach("destination-\(id)")
    }

    private func back(from title: String) {
        let back = app.navigationBars[title].buttons.element(boundBy: 0)
        XCTAssertTrue(back.exists, app.debugDescription); back.tap()
        // SwiftUI restores the detail scroll position. The first lazy-grid
        // row may be offscreen and absent from accessibility after returning
        // from Studio or tapping a lower Coming soon card. Materialize the
        // actual card with the existing outer-page scroll helper before
        // checking it; a missing card or failed return still fails the test.
        let photos = app.buttons["detail.photos"]
        scrollTo(photos)
        XCTAssertTrue(photos.waitForExistence(timeout: 10), app.debugDescription)
    }

    private func openSheet(_ id: String, title: String, close: String) {
        let tile = app.buttons[id]
        scrollTo(tile); tile.tap()
        let navigation = app.navigationBars[title]
        XCTAssertTrue(navigation.waitForExistence(timeout: 15), app.debugDescription)
        attach("destination-\(id)")
        let done = navigation.buttons[close]
        XCTAssertTrue(done.exists, app.debugDescription); done.tap()
        // SwiftUI restores the detail scroll position. The first lazy-grid
        // row may be offscreen and absent from accessibility after returning
        // from Studio or tapping a lower Coming soon card. Materialize the
        // actual card with the existing outer-page scroll helper before
        // checking it; a missing card or failed return still fails the test.
        let photos = app.buttons["detail.photos"]
        scrollTo(photos)
        XCTAssertTrue(photos.waitForExistence(timeout: 10), app.debugDescription)
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// The coordinator sheet has a fixed footer; scroll only its content.
    private func revealCoordinatorContent(_ target: XCUIElement) {
        let primary = app.buttons["export.share"]
        for _ in 0..<24 {
            let top = app.navigationBars["Share everything"].frame.maxY + 12
            let bottom = primary.frame.minY - 12
            let span = bottom - top
            guard span >= 100, top > 0, bottom < app.frame.maxY else {
                XCTFail("No usable coordinator content viewport: \(app.debugDescription)")
                return
            }
            if target.exists, target.isHittable, target.frame.minY >= top, target.frame.maxY <= bottom { return }
            let upward = !target.exists || target.frame.minY >= top
            let high = top + span * 0.25, low = top + span * 0.80
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: app.frame.midX, dy: upward ? low : high))
                .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: app.frame.midX, dy: upward ? high : low)))
        }
        XCTFail("Coordinator detail did not enter its content viewport: \(target.identifier) \(app.debugDescription)")
    }

    private func revealActive(_ element: XCUIElement) {
        // A pushed Photos screen supplies its own toolbar. Do not calculate
        // its viewport using the underlying detail navigation bar.
        for _ in 0..<14 {
            if element.exists, element.isHittable, element.frame.midY > 150,
               element.frame.midY < app.frame.maxY - 70 { return }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.025, dy: 0.82))
                .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.025, dy: 0.28)))
        }
        XCTFail("Active screen did not reveal \(element.identifier): \(app.debugDescription)")
    }

    private func scrollTo(_ element: XCUIElement) {
        // Centre-screen swipes can scrub the nested player. Use only the outer
        // page's 16pt gutter for scrolling; controls still use actual .tap().
        let outer = app.scrollViews.firstMatch
        XCTAssertTrue(outer.waitForExistence(timeout: 5), app.debugDescription)
        let upper = outer.coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: 0.24))
        let lower = outer.coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: 0.78))
        let visibleTop = max(outer.frame.minY, app.navigationBars.firstMatch.frame.maxY) + 8
        let visibleBottom = min(outer.frame.maxY, app.frame.maxY) - 60
        var missingRewinds = 0
        // isHittable alone accepts partially clipped cards. Require the entire
        // target below the navigation bar and above the bottom safe area, so a
        // normal centre tap cannot land on navigation chrome instead of a tile.
        for _ in 0..<24 {
            guard element.exists else {
                // A lazy-grid target may not be instantiated. Rewind at most
                // six gestures, then advance through the page to locate it.
                if missingRewinds < 6 {
                    upper.press(forDuration: 0.01, thenDragTo: lower)
                    missingRewinds += 1
                } else {
                    lower.press(forDuration: 0.01, thenDragTo: upper)
                }
                continue
            }
            let frame = element.frame
            if frame.height > 0, frame.minY >= visibleTop, frame.maxY <= visibleBottom {
                XCTAssertTrue(element.isHittable, app.debugDescription)
                return
            }
            if frame.height > 0, frame.minY < visibleTop {
                upper.press(forDuration: 0.01, thenDragTo: lower)
            } else {
                lower.press(forDuration: 0.01, thenDragTo: upper)
            }
        }
        XCTFail("Target never fully entered the outer page viewport: \(element.debugDescription)\n\(app.debugDescription)")
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
