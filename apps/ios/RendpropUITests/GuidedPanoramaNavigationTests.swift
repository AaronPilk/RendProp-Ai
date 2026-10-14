#if SPATIAL_CAPTURE_LAB
import XCTest

/// Navigation and readable instructions only. These tests never tap Start,
/// request camera access, synthesize a room capture, or contact a GPU provider.
final class GuidedPanoramaNavigationTests: XCTestCase {
    private var app: XCUIApplication!
    private let savedOnly = "Saved on this iPhone. This test does not publish a tour or provide measurements. Keep the app open while scanning."
    private let emptyLibrary = "Your saved room tours will appear here. You can close the app and open them again later."

    override func setUpWithError() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw NSError(domain: "GuidedPanoramaNavigationTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Navigation checks run only on a dedicated simulator; the owner tests the camera on their phone."])
        #endif
        app = XCUIApplication()
    }

    func testHomeEntryInstructionsAndEmptyLibraryReopen() {
        launch()
        openFromHome()
        assertInstructionsAndLocalScope()
        attach("guided-tour-home-instructions")
        scrollTo(app.staticTexts[emptyLibrary])
        XCTAssertTrue(app.staticTexts[emptyLibrary].isHittable)
        XCTAssertFalse(app.buttons["panorama.openTour"].exists)
        XCTAssertFalse(app.buttons["panorama.exportTour"].exists)
        attach("guided-tour-empty-library")
        closeHub(backLabel: "Home")
        openFromHome()
        XCTAssertTrue(app.buttons["panorama.start"].waitForExistence(timeout: 5))
        closeHub(backLabel: "Home")
    }

    func testSettingsEntryAndRelaunchReachTheSameHub() {
        launch(fromSettings: true)
        openFromSettings()
        assertInstructionsAndLocalScope()
        attach("guided-tour-settings-instructions")
        closeHub(backLabel: "Settings")
        app.terminate()
        launch(fromSettings: true)
        openFromSettings()
        scrollTo(app.staticTexts[emptyLibrary])
        XCTAssertTrue(app.staticTexts[emptyLibrary].isHittable)
        XCTAssertFalse(app.buttons["panorama.openTour"].exists)
        closeHub(backLabel: "Settings")
    }

    func testAccessibilityTextKeepsInstructionsStartAndBackReachable() {
        launch(largeText: true)
        openFromHome()
        XCTAssertTrue(app.staticTexts["Look around, then choose a spot"].waitForExistence(timeout: 5))
        attach("guided-tour-accessibility-top")
        scrollTo(app.staticTexts["Let the phone take all 38 photos"])
        XCTAssertTrue(app.staticTexts["Let the phone take all 38 photos"].isHittable)
        scrollTo(app.staticTexts["Preview before moving"])
        XCTAssertTrue(app.staticTexts["Preview before moving"].isHittable)
        scrollTo(app.buttons["panorama.start"])
        XCTAssertTrue(app.buttons["panorama.start"].isHittable)
        XCTAssertTrue(app.buttons["panorama.start"].isEnabled)
        scrollTo(app.staticTexts[savedOnly])
        XCTAssertTrue(app.staticTexts[savedOnly].isHittable)
        attach("guided-tour-accessibility-start-and-scope")
        scrollTo(app.staticTexts[emptyLibrary])
        XCTAssertTrue(app.staticTexts[emptyLibrary].isHittable)
        attach("guided-tour-accessibility-library")
        closeHub(backLabel: "Home")
    }

    private func launch(largeText: Bool = false, fromSettings: Bool = false) {
        app.launchArguments = ["-uiTesting", "-hasOnboarded", "YES", "-appearance", "light",
                               "-space.type", "real_estate", "-ui.spatial", "disabled"]
        // Both hosts are closed, identified, offline simulator fixtures. Never
        // select a remembered customer's listing or create one for this test.
        app.launchArguments += fromSettings
            ? ["-ui.detailMetadataFixture", "republish"]
            : ["-ui.homeProjectCreationFixture", "two-homes"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        if fromSettings {
            XCTAssertTrue(app.navigationBars["Detail fixture republish"].waitForExistence(timeout: 20))
            XCTAssertFalse(app.descendants(matching: .any)["detail.fixtureFailure"].exists)
        } else {
            XCTAssertTrue(app.buttons["home.getStarted"].waitForExistence(timeout: 20))
            XCTAssertEqual(app.staticTexts["home.fixture.projectCount"].label, "2 synthetic homes")
            XCTAssertFalse(app.descendants(matching: .any)["home.fixture.failure"].exists)
        }
    }

    private func openFromHome() {
        XCTAssertTrue(app.buttons["home.getStarted"].waitForExistence(timeout: 20))
        let entry = app.buttons["home.feature.spatial"]
        scrollTo(entry)
        XCTAssertTrue(entry.isHittable)
        entry.tap()
        XCTAssertTrue(app.navigationBars["Pick a home"].waitForExistence(timeout: 10))
        let fixture = app.staticTexts["100 First Fixture Lane"].firstMatch
        XCTAssertTrue(fixture.exists && fixture.isHittable, "Only the known private Home fixture may be selected")
        fixture.tap()
        openGuidedFromHub()
    }

    private func openGuidedFromHub() {
        XCTAssertTrue(app.navigationBars["3D tours"].waitForExistence(timeout: 10))
        let guided = app.buttons["spatial.hub.guided"]
        scrollTo(guided)
        XCTAssertTrue(guided.isEnabled)
        XCTAssertFalse(app.otherElements["panorama.cameraPreview"].exists)
        guided.tap()
        XCTAssertTrue(app.navigationBars["Room tour"].waitForExistence(timeout: 10))
    }

    private func openFromSettings() {
        let settings = app.buttons["build58.fixture.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "The closed detail fixture must expose its Settings door")
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let entry = app.buttons["settings.spatialTestingHub"]
        scrollTo(entry)
        XCTAssertTrue(entry.isHittable)
        entry.tap()
        XCTAssertTrue(app.descendants(matching: .any)["spatial.hub.listingPicker"].waitForExistence(timeout: 10))
        let fixture = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "spatial.hub.chooseListing.")).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 5) && fixture.isHittable)
        XCTAssertEqual(fixture.label, "Detail fixture republish", "The Settings picker must select the identified private fixture")
        fixture.tap()
        openGuidedFromHub()
    }

    private func assertInstructionsAndLocalScope() {
        for text in ["Look around, then choose a spot", "Let the phone take all 38 photos", "Preview before moving"] {
            XCTAssertTrue(app.staticTexts[text].exists, "Missing capture instruction: \(text)")
        }
        scrollTo(app.buttons["panorama.start"])
        XCTAssertTrue(app.buttons["panorama.start"].isHittable)
        XCTAssertTrue(app.buttons["panorama.start"].isEnabled)
        XCTAssertEqual(app.buttons["panorama.start"].label, "Start a room tour")
        scrollTo(app.staticTexts[savedOnly])
        XCTAssertTrue(app.staticTexts[savedOnly].isHittable)
        XCTAssertFalse(app.otherElements["panorama.cameraPreview"].exists)
    }

    private func scrollTo(_ element: XCUIElement) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable, "Expected control or text remains inaccessible after scrolling: \(element)")
    }

    private func closeHub(backLabel: String) {
        let back = app.navigationBars["Room tour"].buttons.firstMatch
        XCTAssertTrue(back.exists && back.isHittable, "The room-tour hub must keep its Back control reachable")
        back.tap()
        let disappeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.navigationBars["Room tour"])
        XCTAssertEqual(XCTWaiter.wait(for: [disappeared], timeout: 5), .completed)
        XCTAssertTrue(app.navigationBars["3D tours"].waitForExistence(timeout: 5), "Back must return to the shared 3D tours hub")
        app.navigationBars["3D tours"].buttons.firstMatch.tap()
        if backLabel == "Settings" {
            XCTAssertTrue(app.descendants(matching: .any)["spatial.hub.listingPicker"].waitForExistence(timeout: 5))
            app.navigationBars["3D tours"].buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
            app.navigationBars["Settings"].buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Detail fixture republish"].waitForExistence(timeout: 5))
        } else {
            XCTAssertTrue(app.buttons["home.getStarted"].waitForExistence(timeout: 5))
        }
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
