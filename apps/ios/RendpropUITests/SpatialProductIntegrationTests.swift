import XCTest

/// The real Home route, listing gate, empty product state and safe exits. No
/// camera is requested or tapped; a simulator cannot establish AR acceptance.
final class SpatialProductIntegrationTests: XCTestCase {
    func testHomeCardOpensListingScopedProductWithoutCameraOrFakeRoom() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw NSError(domain: "SpatialProductTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Use a synthetic simulator for the non-camera product walk"])
        #endif
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-hasOnboarded", "YES", "-appearance", "light",
                               "-space.type", "real_estate"]
        app.launch()
        let home = app.tabBars.buttons["Home"]
        XCTAssertTrue(home.waitForExistence(timeout: 15))
        home.tap()
        let card = app.buttons["home.feature.spatial"]
        for _ in 0..<8 {
            if card.exists && card.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(card.exists && card.isHittable, "First-class Home 3D card is missing")
        XCTAssertTrue(card.label.contains("3D walkthrough"))
        XCTAssertTrue(card.label.contains("Scan rooms. Walk through them."))
        let cardShot = XCTAttachment(screenshot: app.screenshot())
        cardShot.name = "spatial-home-card"; cardShot.lifetime = .keepAlways; add(cardShot)
        card.tap()
        if app.navigationBars["Pick a home"].waitForExistence(timeout: 2) {
            var fixture: XCUIElement?
            for label in ["1 Walk Test Street", "24 Willow Bend Court", "1 Spatial Fixture Street"] {
                let candidate = app.staticTexts[label].firstMatch
                if candidate.exists && candidate.isHittable { fixture = candidate; break }
            }
            XCTAssertNotNil(fixture, "Only known synthetic walk listings may be selected")
            fixture?.tap()
        } else if app.buttons["Save and continue"].waitForExistence(timeout: 2) {
            let name = app.textFields.firstMatch
            XCTAssertTrue(name.exists)
            name.tap(); name.typeText("1 Spatial Fixture Street")
            if app.keyboards.buttons["Done"].isHittable { app.keyboards.buttons["Done"].tap() }
            app.buttons["Save and continue"].tap()
        }
        XCTAssertTrue(app.navigationBars["3D walkthrough"].waitForExistence(timeout: 10),
                      "Home card must open the product, not the export-only lab")
        XCTAssertFalse(app.staticTexts["spatial.lab.description"].exists)
        XCTAssertTrue(app.textFields["spatial.roomName"].exists)
        XCTAssertTrue(app.buttons["spatial.capture"].exists)
        XCTAssertFalse(app.buttons["spatial.capture"].isEnabled, "Simulator cannot capture, so don't offer a broken shutter")
        XCTAssertTrue(app.staticTexts["spatial.capture.unsupported"].exists)
        XCTAssertFalse(app.otherElements["spatial.preview"].exists)
        XCTAssertFalse(app.buttons["spatial.export"].exists)
        XCTAssertFalse(app.buttons["Publish this reviewed room"].exists)
        XCTAssertFalse(app.buttons["Share 3D walkthrough"].exists)
        let empty = app.staticTexts["spatial.empty"]
        for _ in 0..<4 {
            if empty.exists && empty.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(empty.exists, "An offline mock must not fabricate a generated room")
        XCTAssertFalse(app.staticTexts["spatial.error"].exists, "An enumeration error is not an empty-library pass")
        let productShot = XCTAttachment(screenshot: app.screenshot())
        productShot.name = "spatial-product-empty"; productShot.lifetime = .keepAlways; add(productShot)
        let refresh = app.buttons["spatial.refresh"]
        XCTAssertTrue(refresh.exists && refresh.isHittable)
        refresh.tap()
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        app.navigationBars["3D walkthrough"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5), "Product must have a working Home exit")
    }
}
