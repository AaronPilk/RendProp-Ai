import XCTest

/// The simulator has no camera. These checks verify the real entry points,
/// honest unavailable state and exit; they never invent a photo.
final class GuidedPhotoNavigationTests: XCTestCase {
    private var app: XCUIApplication!
    private let address = "Guided Photo Camera Test"

    override func setUpWithError() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw NSError(domain: "GuidedPhotoNavigationTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Software navigation checks require a dedicated simulator; the owner tests real photos on their phone."])
        #endif
        app = XCUIApplication()
    }

    func testPhotosCameraUnavailableCloseAndReopen() {
        launch()
        openFeature("photos")
        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 10))
        openCamera(id: "photos.takePhoto", title: "Room photo")
        assertUnavailable()
        XCTAssertFalse(app.buttons["camera.retry"].exists)
        closeCamera()
        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 5))
        openCamera(id: "photos.takePhoto", title: "Room photo")
        assertUnavailable()
        closeCamera()
    }

    func testExteriorCameraAndLargeTextKeepCloseReachable() {
        launch(largeText: true)
        openFeature("aerial")
        XCTAssertTrue(app.navigationBars["Aerial intro"].waitForExistence(timeout: 10))
        openCamera(id: "aerial.takePhoto", title: "Exterior photo")
        assertUnavailable()
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "guided-photo-camera-unavailable-large-text"
        attachment.lifetime = .keepAlways
        add(attachment)
        closeCamera()
        XCTAssertTrue(app.navigationBars["Aerial intro"].waitForExistence(timeout: 5))
    }

    private func launch(largeText: Bool = false) {
        app.launchArguments = ["-uiTesting", "-hasOnboarded", "YES", "-space.type", "real_estate",
                               "-appearance", "light", "-ai.thirdPartyProcessing.consent.v3", "YES"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Home"].tap()
    }

    private func openFeature(_ feature: String) {
        let entry = app.buttons["home.feature.\(feature)"]
        scrollTo(entry)
        entry.tap()
        if app.navigationBars["Pick a home"].waitForExistence(timeout: 1) {
            let project = app.buttons.containing(.staticText, identifier: address).firstMatch
            if project.waitForExistence(timeout: 2) { scrollTo(project); project.tap(); return }
            // Only fixtures created by the isolated release walks are allowed.
            for name in ["1 Walk Test Street", "24 Willow Bend Court"] {
                let known = app.buttons.containing(.staticText, identifier: name).firstMatch
                if known.exists { scrollTo(known); known.tap(); return }
            }
            XCTFail("No known software-test project in picker")
            return
        }
        let save = app.buttons["Save and continue"]
        if save.waitForExistence(timeout: 3) {
            let field = app.textFields.firstMatch
            XCTAssertTrue(field.exists)
            field.tap(); field.typeText(address)
            if app.keyboards.buttons["Done"].isHittable { app.keyboards.buttons["Done"].tap() }
            scrollTo(save); save.tap()
        }
    }

    private func openCamera(id: String, title: String) {
        let entry = app.buttons[id]
        scrollTo(entry)
        XCTAssertTrue(entry.isEnabled)
        entry.tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["camera.close"].exists)
    }

    private func assertUnavailable() {
        let message = app.staticTexts["A camera is not available on this device. You can close this screen and add an existing photo instead."]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["camera.capture"].exists)
        XCTAssertFalse(app.buttons["camera.lens.ultraWide"].exists)
        XCTAssertFalse(app.buttons["camera.review.use"].exists)
    }

    private func closeCamera() {
        let close = app.buttons["camera.close"]
        XCTAssertTrue(close.isHittable)
        close.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
    }

    private func scrollTo(_ element: XCUIElement) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }
}
