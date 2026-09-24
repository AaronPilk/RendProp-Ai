import XCTest

/// Exercises navigation and local checklist recovery with MockAPIClient.
/// No camera, microphone, live account, upload or paid provider is used.
final class ProductionPlanUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-hasOnboarded", "YES", "-space.type", "real_estate", "-appearance", "light"]
    }
    override func tearDownWithError() throws {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "production-plan-accessibility"; tree.lifetime = .keepAlways; add(tree)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "production-plan-screen"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.terminate()
    }

    func testPhotoFirstPropertyCanPlanWithoutVideoAndPreservesChecklist() {
        app.launch()
        let addHome = app.buttons["home.addHome"]
        XCTAssertTrue(addHome.waitForExistence(timeout: 20), app.debugDescription)
        addHome.tap()
        let address = app.textFields["Type the home's address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10), app.debugDescription)
        address.tap(); address.typeText("Production plan fixture")
        let photos = app.buttons["newListing.startWithPhotos"]
        scrollTo(photos); photos.tap()
        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 10), app.debugDescription)
        app.navigationBars["Photos"].buttons.element(boundBy: 0).tap()
        let open = app.buttons["listing.productionPlan"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), app.debugDescription)
        open.tap()
        XCTAssertTrue(app.navigationBars["Plan your video"].waitForExistence(timeout: 10), app.debugDescription)
        let firstShot = app.buttons["production.shot.exterior"]
        scrollTo(firstShot); firstShot.tap()
        app.buttons["Captured — review footage"].tap()
        XCTAssertTrue(app.staticTexts["5 required shots still to capture or account for."].exists, app.debugDescription)

        app.navigationBars["Plan your video"].buttons.element(boundBy: 0).tap()
        app.buttons["listing.productionPlan"].tap()
        scrollTo(app.buttons["production.shot.exterior"])
        XCTAssertTrue(app.staticTexts["5 required shots still to capture or account for."].exists, app.debugDescription)
        XCTAssertTrue(app.buttons["production.shot.exterior"].label.contains("Captured"), app.debugDescription)
        // File count does not claim that the fixture has captured actual media.
        for _ in 0..<4 { app.swipeDown() }
        XCTAssertTrue(app.staticTexts["0 photos · No local walkthrough"].exists, app.debugDescription)
        XCTAssertFalse(app.buttons["production.save"].exists, "Mock/signed-out plan must not pretend to cloud-sync")
    }

    private func scrollTo(_ element: XCUIElement) {
        for _ in 0..<8 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }
}
