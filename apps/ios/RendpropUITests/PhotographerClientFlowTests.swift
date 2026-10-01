import XCTest

/// Real navigation/text-entry with the offline mock. No camera, photo-library
/// selection, account, upload, email or AI provider is invoked.
final class PhotographerClientFlowTests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw NSError(domain: "PhotographerClientFlowTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "This no-camera navigation test runs only on a dedicated simulator."])
        #endif
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-ui.onboardingReset", "-space.type", "real_estate", "-appearance", "light"]
    }
    override func tearDownWithError() throws {
        let tree = XCTAttachment(string: app.debugDescription); tree.name = "photographer-client-tree"; tree.lifetime = .keepAlways; add(tree)
        let picture = XCTAttachment(screenshot: app.screenshot()); picture.name = "photographer-client-screen"; picture.lifetime = .keepAlways; add(picture)
        app.terminate()
    }
    func testOnboardingRoleAndClientCardSaveWithoutCapture() {
        app.launch()
        for _ in 0..<3 {
            let next = app.buttons["Continue"]
            XCTAssertTrue(next.waitForExistence(timeout: 10)); next.tap()
        }
        app.buttons["Get started"].tap()
        let next = app.buttons["onboarding.choosePlan"]
        XCTAssertTrue(next.waitForExistence(timeout: 10)); next.tap()
        let photographer = app.buttons["realEstateRole.photographer_videographer"]
        XCTAssertTrue(photographer.waitForExistence(timeout: 10)); photographer.tap()
        XCTAssertTrue(app.staticTexts["How do you work?"].exists)
        app.buttons["onboarding.role.explore"].tap()
        let add = app.buttons["home.addHome"]
        XCTAssertTrue(add.waitForExistence(timeout: 20)); add.tap()
        let address = app.textFields["Type the home's address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10)); address.tap(); address.typeText("Synthetic client delivery fixture")
        let photos = app.buttons["newListing.startWithPhotos"]
        scrollTo(photos); photos.tap()
        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 10))
        app.navigationBars["Photos"].buttons.element(boundBy: 0).tap()
        let contact = app.buttons["listing.clientContact"]
        scrollTo(contact); contact.tap()
        XCTAssertTrue(app.navigationBars["Listing contact"].waitForExistence(timeout: 10))
        let save = app.buttons["clientContact.save"]
        scrollTo(save); save.tap()
        XCTAssertTrue(app.staticTexts["clientContact.error"].waitForExistence(timeout: 10))
        for _ in 0..<5 { app.swipeDown() }
        let name = app.textFields["clientContact.name"]
        scrollTo(name); name.tap(); name.typeText("Synthetic Realtor One")
        let recipient = app.textFields["clientContact.recipient"]
        scrollTo(recipient); recipient.tap(); recipient.typeText("client@example.invalid")
        scrollTo(save); save.tap()
        XCTAssertTrue(app.buttons["listing.clientContact"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Synthetic Realtor One"].exists, app.debugDescription)
        app.buttons["listing.clientContact"].tap()
        XCTAssertTrue(app.textFields["clientContact.name"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["clientContact.name"].value as? String, "Synthetic Realtor One")
        app.navigationBars["Listing contact"].buttons.element(boundBy: 0).tap()
        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.exists); settings.tap()
        let role = app.buttons["settings.realEstateRole"]
        scrollTo(role); role.tap()
        XCTAssertTrue(app.buttons["realEstateRole.agent"].waitForExistence(timeout: 10))
        app.buttons["realEstateRole.agent"].tap(); app.buttons["realEstateRole.save"].tap()
        XCTAssertTrue(app.buttons["settings.realEstateRole"].waitForExistence(timeout: 10))
        // Change back so a subsequent dedicated simulator run retains no producer override.
        app.buttons["settings.realEstateRole"].tap()
        app.buttons["realEstateRole.agent"].tap(); app.buttons["realEstateRole.save"].tap()
    }
    private func scrollTo(_ element: XCUIElement) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable, app.debugDescription)
    }
}
