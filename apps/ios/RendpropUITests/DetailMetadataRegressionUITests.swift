import XCTest

/// Run with -configuration Release. Each test cold-launches the actual detail
/// screen so metadata is first instantiated for that state. Procedural local
/// photos/video exercise production SwiftUI/AVFoundation views, without a
/// camera, microphone, customer account, upload, AI call or destructive action.
final class DetailMetadataRegressionUITests: XCTestCase {
    private var app: XCUIApplication!
    private let tileIDs = ["detail.photos", "detail.photoStudio", "detail.reelStudio", "detail.roomTags",
                           "detail.floorPlan", "detail.aerialIntro", "detail.clientContact"]

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

    func testSampleHasAllSevenToolsDisabled() {
        launch("sample")
        assertTiles(sample: true, hasCapture: false)
        XCTAssertFalse(element("detail.rerenderTour").exists)
        XCTAssertFalse(element("detail.rerenderUnavailable").exists)
        XCTAssertFalse(app.buttons["listing.clientContact"].exists)
    }

    func testEmptyListingStillOpensPhotoLibraryStudioAndFloorPlan() {
        launch("empty")
        assertTiles(sample: false, hasCapture: false)
        XCTAssertFalse(element("detail.rerenderTour").exists)
        XCTAssertFalse(element("detail.rerenderUnavailable").exists)
        openLink("detail.photos", title: "Photos")
        XCTAssertTrue(app.buttons["photos.takePhoto"].exists) // Inspect only; never tap camera.
        back(from: "Photos")
        openLink("detail.photoStudio", title: "AI Photo Studio")
        XCTAssertTrue(app.buttons["studio.edit.declutter"].exists, app.debugDescription)
        back(from: "AI Photo Studio")
        openLink("detail.floorPlan", title: "Floor plan")
        back(from: "Floor plan")
        openSheet("detail.aerialIntro", title: "Aerial intro", close: "Close")
    }

    func testCapturedUnrenderedListingKeepsRoomTaggingAndNoRerenderTile() {
        launch("capture")
        assertTiles(sample: false, hasCapture: true)
        XCTAssertFalse(element("detail.rerenderTour").exists)
        XCTAssertFalse(element("detail.rerenderUnavailable").exists)
        openSheet("detail.roomTags", title: "Tag rooms", close: "Done")
    }

    func testPhotosCaptureTourAerialAndClientNavigateEveryTool() {
        launch("rich")
        assertTiles(sample: false, hasCapture: true)
        let photos = app.buttons["detail.photos"]
        scrollTo(photos)
        XCTAssertTrue(photos.label.contains("3 photos"), photos.label)
        let aerial = app.buttons["detail.aerialIntro"]
        scrollTo(aerial)
        XCTAssertTrue(aerial.label.contains("Aerial ready"), aerial.label)
        let rerender = app.buttons["detail.rerenderTour"]
        scrollTo(rerender)
        XCTAssertTrue(rerender.isEnabled)
        XCTAssertFalse(element("detail.rerenderUnavailable").exists)
        attach("detail-rich-toolbox")

        openLink("detail.photos", title: "Photos")
        back(from: "Photos")
        openLink("detail.photoStudio", title: "AI Photo Studio")
        XCTAssertTrue(app.buttons["studio.edit.declutter"].exists, app.debugDescription)
        back(from: "AI Photo Studio")
        openLink("detail.floorPlan", title: "Floor plan")
        back(from: "Floor plan")
        openLink("detail.clientContact", title: "Listing contact")
        XCTAssertEqual(app.textFields["clientContact.name"].value as? String, "Fixture client")
        back(from: "Listing contact") // No save or client photo picker.
        openSheet("detail.roomTags", title: "Tag rooms", close: "Done")
        openLink("detail.rerenderTour", title: "Review & Submit")
        back(from: "Review & Submit") // Never submit or change render source.
        openSheet("detail.aerialIntro", title: "Aerial intro", close: "Close")

        let reel = app.buttons["detail.reelStudio"]
        scrollTo(reel); reel.tap()
        XCTAssertTrue(app.navigationBars["Reel Studio"].waitForExistence(timeout: 15), app.debugDescription)
        let firstPhoto = app.buttons["reel.photo.fixture-0"]
        scrollTo(firstPhoto)
        XCTAssertTrue(firstPhoto.exists, "Reel must receive the detail listing's local photos")
        // The presenting detail remains in the accessibility tree behind the
        // cover and has the same title. Match the actual Reel clips control,
        // whose existing subtitle distinguishes it from the toolbox tile.
        let aerialClips = app.buttons.matching(NSPredicate(format:
            "label CONTAINS %@ AND label CONTAINS %@", "Aerial intro", "Opens the reel"))
        XCTAssertEqual(aerialClips.count, 1, "Reel must receive exactly one local aerial clip")
        let reelAerial = aerialClips.firstMatch
        scrollTo(reelAerial)
        XCTAssertTrue(reelAerial.exists, "Reel must receive the detail listing's aerial clip")
        attach("detail-rich-reel")
        app.navigationBars["Reel Studio"].buttons["Close"].tap()
        XCTAssertTrue(app.navigationBars["Detail fixture rich"].waitForExistence(timeout: 10))
        scrollTo(app.buttons["detail.photos"])
        XCTAssertTrue(app.buttons["detail.photos"].isEnabled)
    }

    func testMissingSourceIsAPlainUnavailableCardEvenWithLocalTour() {
        launch("missing-source")
        assertTiles(sample: false, hasCapture: true) // Existing room-tag gate is asset presence.
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
        XCTAssertFalse(app.buttons["detail.roomTags"].isEnabled)
        openLink("detail.clientContact", title: "Listing contact")
        back(from: "Listing contact")
    }

    func testVenueKeepsIndustryAreaNounsAndRerenderNavigation() {
        launch("venue")
        assertTiles(sample: false, hasCapture: true)
        XCTAssertTrue(app.buttons["detail.roomTags"].label.contains("Tag areas"))
        openSheet("detail.roomTags", title: "Tag areas", close: "Done")
        openLink("detail.rerenderTour", title: "Review & Submit")
        back(from: "Review & Submit")
    }

    private func launch(_ fixture: String) {
        app.launchArguments = ["-uiTesting", "-hasOnboarded", "YES", "-space.type", fixture == "venue" ? "venue" : "real_estate",
                               "-appearance", "light", "-ai.thirdPartyProcessing.consent.v2", "YES",
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
            XCTAssertEqual(tile.isEnabled, !sample && (id != "detail.roomTags" || hasCapture), id)
        }
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
        XCTAssertTrue(app.buttons["detail.photos"].waitForExistence(timeout: 10), app.debugDescription)
    }

    private func openSheet(_ id: String, title: String, close: String) {
        let tile = app.buttons[id]
        scrollTo(tile); tile.tap()
        let navigation = app.navigationBars[title]
        XCTAssertTrue(navigation.waitForExistence(timeout: 15), app.debugDescription)
        attach("destination-\(id)")
        let done = navigation.buttons[close]
        XCTAssertTrue(done.exists, app.debugDescription); done.tap()
        XCTAssertTrue(app.buttons["detail.photos"].waitForExistence(timeout: 10), app.debugDescription)
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
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
