import XCTest

/// Drives the real Home gate, picker and name-it sheet on an offline, two-home
/// fixture. Never opens camera, Photos, account, purchase or paid AI actions.
final class HomeProjectCreationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if targetEnvironment(simulator)
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-hasOnboarded", "YES", "-space.type", "real_estate",
            "-appearance", "light", "-ui.homeProjectCreationFixture", "two-homes"]
        app.launch()
        XCTAssertTrue(app.buttons["home.getStarted"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(app.staticTexts["home.fixture.projectCount"].label, "2 synthetic homes")
#else
        throw XCTSkip("The closed Home creation fixture exists only on the simulator.")
#endif
    }

    override func tearDownWithError() throws {
        guard app != nil else { return }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "home-creation-final"; screenshot.lifetime = .keepAlways; add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "home-creation-accessibility"; tree.lifetime = .keepAlways; add(tree)
        app.terminate()
    }

    func testGetStartedWithTwoHomesCanNameANewHomeAndCancelWithoutCreatingIt() {
        openPicker()
        app.buttons["home.picker.newProject"].tap()
        XCTAssertTrue(app.navigationBars["Add a home"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.navigationBars["Pick a home"].exists, "The picker must dismiss before the name sheet opens")
        let name = app.textFields["home.startProject.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let save = app.buttons["home.startProject.save"]
        XCTAssertTrue(save.exists)
        XCTAssertFalse(save.isEnabled, "An empty name cannot create a draft")
        XCTAssertTrue(app.staticTexts["Next: make a tour."].exists, "Get started must retain its tour destination")
        name.tap(); name.typeText("300 New Fixture Lane")
        XCTAssertTrue(save.isEnabled)
        app.navigationBars["Add a home"].buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["home.getStarted"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["home.fixture.projectCount"].label, "2 synthetic homes",
            "Cancel must leave both existing homes intact and create nothing")

        openPicker()
        XCTAssertFalse(app.staticTexts["300 New Fixture Lane"].exists)
        app.navigationBars["Pick a home"].buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["home.getStarted"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["Add a home"].exists,
            "A canceled picker must not replay a previously queued new-home sheet")
        XCTAssertEqual(app.staticTexts["home.fixture.projectCount"].label, "2 synthetic homes")
    }

    func testCanceledPickerDoesNotPresentNewHomeSheet() {
        openPicker()
        app.navigationBars["Pick a home"].buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["home.getStarted"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["Add a home"].exists)
        XCTAssertEqual(app.staticTexts["home.fixture.projectCount"].label, "2 synthetic homes")
    }

    private func openPicker() {
        app.buttons["home.getStarted"].tap()
        XCTAssertTrue(app.navigationBars["Pick a home"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["home.picker.newProject"].exists,
            "A user with existing homes must still have a new-home action")
        for address in ["100 First Fixture Lane", "200 Second Fixture Lane"] {
            XCTAssertTrue(app.staticTexts[address].exists, "Existing homes must remain selectable: \(address)")
        }
    }
}
