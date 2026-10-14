import XCTest

/// Drives Home's full new-home entry and its separate tool picker/name sheet
/// on an offline two-home fixture. Never opens camera, Photos or paid actions.
final class HomeProjectCreationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if targetEnvironment(simulator)
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-hasOnboarded", "YES", "-space.type", "real_estate",
            "-appearance", "light", "-ui.homeProjectCreationFixture", "two-homes", "-ui.currentLocationFixture"]
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

    func testGetStartedOpensFullNewHomeFormWithoutChoosingAnExistingHome() {
        app.buttons["home.getStarted"].tap()
        XCTAssertTrue(app.navigationBars["New Home"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.textFields["newListing.address"].exists)
        XCTAssertTrue(app.textFields["newListing.unit"].exists)
        XCTAssertFalse(app.navigationBars["Pick a home"].exists)
        XCTAssertFalse(app.textFields["home.startProject.name"].exists)
        let photos = app.buttons["newListing.startWithPhotos"]
        if !photos.isHittable { app.swipeUp() }
        XCTAssertTrue(photos.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Home details (optional)"].exists,
            "The main entry must retain the full listing details form")
        app.navigationBars["New Home"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["home.getStarted"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["home.fixture.projectCount"].label, "2 synthetic homes",
            "Opening and backing out of the form must not create or choose a home")
    }

    func testTourToolWithTwoHomesCanNameANewHomeAndCancelWithoutCreatingIt() {
        openPicker()
        app.buttons["home.picker.newProject"].tap()
        XCTAssertTrue(app.navigationBars["Add a home"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.navigationBars["Pick a home"].exists, "The picker must dismiss before the name sheet opens")
        let name = app.textFields["home.startProject.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let save = app.buttons["home.startProject.save"]
        XCTAssertTrue(save.exists)
        XCTAssertFalse(save.isEnabled, "An empty name cannot create a draft")
        XCTAssertTrue(app.staticTexts["Next: make a tour."].exists, "The tour tool must retain its destination")
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

    func testNewHomeAcceptsAddressSuggestionsAndDeterministicCurrentLocation() {
        openPicker()
        app.buttons["home.picker.newProject"].tap()
        XCTAssertTrue(app.navigationBars["Add a home"].waitForExistence(timeout: 10), app.debugDescription)
        let name = app.textFields["home.startProject.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("855 Cen")
        XCTAssertEqual(name.value as? String, "855 Cen", "The real Home field must accept a partial address")

        // MapKit's network service can be unavailable on the runner. Record
        // that one optional observation and still run the location regression.
        let suggestions = app.descendants(matching: .any)["home.startProject.suggestions"].firstMatch
        let observed = suggestions.waitForExistence(timeout: 8)
        let observation = XCTAttachment(string: observed
            ? "MapKit completer suggestions appeared for 855 Cen."
            : "MapKit completer returned no suggestions on this runner; partial input and deterministic current location were still tested.")
        observation.name = "home-address-completer-observation"
        observation.lifetime = .keepAlways
        add(observation)
        if observed { XCTAssertTrue(suggestions.exists) }

        let currentLocation = app.buttons["home.startProject.currentLocation"]
        XCTAssertTrue(currentLocation.exists)
        if !currentLocation.isHittable { app.swipeUp() }
        XCTAssertTrue(currentLocation.isHittable, app.debugDescription)
        currentLocation.tap()
        XCTAssertEqual(name.value as? String, "100 Synthetic Condo Way, Fixture City, NC 28000")
        XCTAssertTrue(app.buttons["home.startProject.save"].isEnabled)
        app.navigationBars["Add a home"].buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["home.getStarted"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["home.fixture.projectCount"].label, "2 synthetic homes")
    }

    private func openPicker() {
        let tour = app.buttons["home.feature.tour"]
        if !tour.isHittable { app.swipeUp() }
        XCTAssertTrue(tour.waitForExistence(timeout: 5), app.debugDescription)
        tour.tap()
        XCTAssertTrue(app.navigationBars["Pick a home"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["home.picker.newProject"].exists,
            "A user with existing homes must still have a new-home action")
        for address in ["100 First Fixture Lane", "200 Second Fixture Lane"] {
            XCTAssertTrue(app.staticTexts[address].exists, "Existing homes must remain selectable: \(address)")
        }
    }
}
