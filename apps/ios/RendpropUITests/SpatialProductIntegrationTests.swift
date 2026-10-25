import XCTest

/// Synthetic navigation only. No camera, upload, provider or account work.
/// Physical capture acceptance belongs to the owner's real iPhone.
final class SpatialProductIntegrationTests: XCTestCase {
    func testSpatialEntryObeysTheBuildBoundary() throws {
        let app = try launch()
#if SPATIAL_CAPTURE_LAB
        openHomeHub(app)
        XCTAssertTrue(app.navigationBars["3D tours"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["spatial.hub.guided"].exists)
        reveal(app.buttons["spatial.hub.walking"], in: app)
        XCTAssertTrue(app.buttons["spatial.hub.walking"].exists)
        XCTAssertFalse(app.staticTexts["spatial.lab.description"].exists,
                       "Opening the hub must not start walking capture")
        XCTAssertFalse(app.otherElements["spatial.preview"].exists)
        XCTAssertFalse(app.buttons["Publish this reviewed room"].exists)
        app.navigationBars["3D tours"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))
#else
        let tile = app.descendants(matching: .any)["home.comingSoon.spatial"]
        reveal(tile, in: app)
        XCTAssertTrue(tile.exists && tile.label.contains("3D tours") && tile.label.contains("Coming soon"))
        XCTAssertFalse(app.buttons["home.feature.spatial"].exists)
        tile.tap()
        XCTAssertFalse(app.navigationBars["3D tours"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Home"].exists)
#endif
        attach(app, "spatial-entry-build-boundary")
    }

    func testLocalHubDoesNotDependOnCloudAvailability() throws {
        let app = try launch(cloudDisabled: true)
#if SPATIAL_CAPTURE_LAB
        openHomeHub(app)
        let guided = app.buttons["spatial.hub.guided"]
        XCTAssertTrue(guided.waitForExistence(timeout: 10) && guided.isEnabled)
        let walking = app.buttons["spatial.hub.walking"]
        reveal(walking, in: app)
        XCTAssertTrue(walking.exists && walking.isEnabled)
        let retry = app.buttons["spatial.hub.checkCloud"]
        reveal(retry, in: app)
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["spatial.hub.cloud"].exists,
                       "A disabled service cannot expose the cloud-generation route")
        XCTAssertFalse(app.otherElements["spatial.product.root"].exists)
#else
        let tile = app.descendants(matching: .any)["home.comingSoon.spatial"]
        reveal(tile, in: app)
        XCTAssertTrue(tile.exists)
        XCTAssertFalse(app.buttons["home.feature.spatial"].exists)
#endif
        attach(app, "spatial-local-entry-cloud-off")
    }

    private func launch(cloudDisabled: Bool = false) throws -> XCUIApplication {
#if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic navigation fixtures require the simulator; they do not certify physical capture.")
#endif
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-hasOnboarded", "YES", "-appearance", "light", "-space.type", "real_estate"]
        if cloudDisabled { app.launchArguments += ["-ui.spatial", "disabled"] }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Home"].tap()
        return app
    }

#if SPATIAL_CAPTURE_LAB
    private func openHomeHub(_ app: XCUIApplication) {
        let card = app.buttons["home.feature.spatial"]
        reveal(card, in: app)
        XCTAssertTrue(card.exists && card.isHittable && card.label.contains("3D tours"))
        card.tap()
        if app.navigationBars["Pick a home"].waitForExistence(timeout: 2) {
            let candidates = ["1 Walk Test Street", "24 Willow Bend Court", "1 Spatial Fixture Street"]
                .map { app.staticTexts[$0].firstMatch }
            let fixture = candidates.first { $0.exists && $0.isHittable }
            XCTAssertNotNil(fixture, "Only known synthetic listings may be selected")
            fixture?.tap()
        } else if app.buttons["Save and continue"].waitForExistence(timeout: 2) {
            let name = app.textFields.firstMatch
            XCTAssertTrue(name.exists)
            name.tap(); name.typeText("1 Spatial Fixture Street")
            if app.keyboards.buttons["Done"].isHittable { app.keyboards.buttons["Done"].tap() }
            app.buttons["Save and continue"].tap()
        }
        XCTAssertTrue(app.navigationBars["3D tours"].waitForExistence(timeout: 10))
    }
#endif

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
