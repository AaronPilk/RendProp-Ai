#if SPATIAL_CAPTURE_LAB
import XCTest

/// Release TestFlight-overlay UI coverage only. No camera, room capture,
/// reconstruction, share sheet, upload, account mutation, or GPU work occurs.
final class SpatialCaptureIntegrationTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw NSError(domain: "SpatialCaptureIntegrationTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Unsupported-hardware integration tests require an iOS simulator; never run camera-start probes on a device"])
        #endif
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-hasOnboarded", "YES", "-appearance", "light",
                               "-space.type", "real_estate", "-ui.spatial", "disabled",
                               "-ui.detailMetadataFixture", "republish"]
        app.launch()
        openCaptureFromSettings()
    }

    func testSettingsEntryShowsHonestIdleControlsAndDoneReturns() {
        assertIdleControls()
        XCTAssertTrue(app.staticTexts["spatial.lab.description"].exists,
                      "Experimental/no-upload disclosure is missing")
        attachScreen("spatial-integrated-idle")
        closeCapture()
        openCaptureFromSettings()
        assertIdleControls()
        closeCapture()
    }

    func testUnsupportedStartDoesNotRequestCameraOrOfferExport() {
        assertIdleControls()
        let start = app.buttons["spatial.start"]
        start.tap()
        start.tap()
        XCTAssertTrue(app.staticTexts["spatial.status"].label.contains("physical iPhone"))
        XCTAssertTrue(app.staticTexts["spatial.status"].label.contains("simulator cannot capture a room"))
        XCTAssertFalse(app.otherElements["spatial.preview"].exists,
                       "Unsupported simulator must not allocate an AR preview")
        XCTAssertFalse(app.buttons["spatial.stop"].isEnabled)
        XCTAssertFalse(app.buttons["spatial.export"].isEnabled)
        XCTAssertFalse(app.staticTexts["spatial.status"].label.contains("frames saved"),
                       "Unsupported start must not claim saved capture evidence")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 2),
                       "Unsupported start must not request camera permission")
        app.activate()
        XCTAssertTrue(app.navigationBars["Spatial capture"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["spatial.lab.description"].isHittable)
        XCTAssertTrue(app.buttons["spatial.done"].isHittable)
        // XCUITest may report foreground/idle before SwiftUI's wrapper has
        // composited after activating from SpringBoard. A screenshot taken
        // 82 ms later hid the header although Done immediately worked. Give
        // that transition a bounded settling interval, then reassert the exit.
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(app.staticTexts["spatial.lab.description"].isHittable)
        XCTAssertTrue(app.buttons["spatial.done"].isHittable)
        attachScreen("spatial-integrated-unsupported")
        closeCapture()
    }

    func testRelaunchAndReopenWithoutCaptureKeepExportUnavailable() {
        assertIdleControls()
        closeCapture()
        app.terminate()
        app.launch()
        openCaptureFromSettings()
        assertIdleControls()
        XCTAssertFalse(app.otherElements["spatial.preview"].exists)

        // The dedicated synthetic simulator has never captured a room. An
        // empty local library is expected, not a fabricated completed capture.
        let saved = app.buttons["spatial.saved"]
        XCTAssertTrue(saved.waitForExistence(timeout: 5) && saved.isHittable)
        XCTAssertTrue(saved.isEnabled)
        XCTAssertEqual(saved.label, "Saved captures")
        saved.tap()
        let library = app.tables["spatial.saved.list"]
        XCTAssertTrue(library.waitForExistence(timeout: 5), "Saved captures list did not open")
        let empty = app.staticTexts["spatial.saved.empty"]
        XCTAssertTrue(empty.waitForExistence(timeout: 10), "Expected empty capture library on this synthetic simulator")
        XCTAssertTrue(empty.label.contains("No saved captures yet"))
        XCTAssertFalse(app.staticTexts["spatial.saved.error"].exists,
                       "Library enumeration failure must not pass as an empty library")
        XCTAssertEqual(library.cells.count, 0, "No captured-room rows should exist on this simulator")
        attachScreen("spatial-integrated-saved-empty")
        let libraryDone = app.buttons["spatial.saved.done"]
        XCTAssertTrue(libraryDone.exists && libraryDone.isHittable)
        libraryDone.tap()
        let libraryDismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: library)
        XCTAssertEqual(XCTWaiter.wait(for: [libraryDismissed], timeout: 5), .completed,
                       "Saved captures Done did not return to capture")
        assertIdleControls()
        closeCapture()
    }

    private func openCaptureFromSettings(file: StaticString = #filePath, line: UInt = #line) {
        if !app.navigationBars["Settings"].exists {
            XCTAssertTrue(app.navigationBars["Detail fixture republish"].waitForExistence(timeout: 15),
                          "The identified offline fixture must be active", file: file, line: line)
            XCTAssertFalse(app.descendants(matching: .any)["detail.fixtureFailure"].exists, file: file, line: line)
            let settings = app.buttons["build58.fixture.settings"]
            XCTAssertTrue(settings.exists && settings.isHittable, file: file, line: line)
            settings.tap()
        }
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), file: file, line: line)
        let entry = app.buttons["settings.spatialTestingHub"]
        for _ in 0..<8 {
            if entry.exists && entry.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(entry.exists && entry.isHittable,
                      "Explicit TestFlight build must expose the shared 3D tours hub", file: file, line: line)
        XCTAssertEqual(entry.label, "3D tours", file: file, line: line)
        entry.tap()
        XCTAssertTrue(app.descendants(matching: .any)["spatial.hub.listingPicker"].waitForExistence(timeout: 10), file: file, line: line)
        let fixture = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "spatial.hub.chooseListing.")).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 5) && fixture.isHittable, file: file, line: line)
        XCTAssertEqual(fixture.label, "Detail fixture republish", "Only the known private fixture may be selected", file: file, line: line)
        fixture.tap()
        XCTAssertTrue(app.navigationBars["3D tours"].waitForExistence(timeout: 10), file: file, line: line)
        let walking = app.buttons["spatial.hub.walking"]
        for _ in 0..<8 {
            if walking.exists && walking.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(walking.exists && walking.isHittable && walking.isEnabled, file: file, line: line)
        XCTAssertFalse(app.otherElements["spatial.preview"].exists, "Opening the hub must not start capture", file: file, line: line)
        walking.tap()
        XCTAssertTrue(app.staticTexts["spatial.status"].waitForExistence(timeout: 10),
                      "The shared hub did not present the integrated capture controller", file: file, line: line)
    }

    private func assertIdleControls(file: StaticString = #filePath, line: UInt = #line) {
        let status = app.staticTexts["spatial.status"]
        XCTAssertTrue(status.exists && status.isHittable, file: file, line: line)
        XCTAssertTrue(status.label.contains("simulator cannot capture a room"), file: file, line: line)
        for identifier in ["spatial.start", "spatial.stop", "spatial.export", "spatial.done"] {
            XCTAssertTrue(app.buttons[identifier].exists, "Missing \(identifier)", file: file, line: line)
        }
        XCTAssertEqual(app.buttons["spatial.start"].label, "Start new room", file: file, line: line)
        XCTAssertTrue(app.buttons["spatial.start"].isEnabled, file: file, line: line)
        XCTAssertEqual(app.buttons["spatial.stop"].label, "Stop and save", file: file, line: line)
        XCTAssertFalse(app.buttons["spatial.stop"].isEnabled, file: file, line: line)
        XCTAssertEqual(app.buttons["spatial.export"].label, "Export completed capture", file: file, line: line)
        XCTAssertFalse(app.buttons["spatial.export"].isEnabled, file: file, line: line)
        XCTAssertTrue(app.buttons["spatial.done"].isEnabled, file: file, line: line)
    }

    private func closeCapture(file: StaticString = #filePath, line: UInt = #line) {
        let done = app.buttons["spatial.done"]
        XCTAssertTrue(done.exists && done.isHittable, "Capture has no safe Done exit", file: file, line: line)
        done.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                  object: app.staticTexts["spatial.status"])
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed,
                       "Done did not dismiss capture", file: file, line: line)
        XCTAssertTrue(app.navigationBars["3D tours"].waitForExistence(timeout: 5),
                      "Done did not return to the shared 3D tours hub", file: file, line: line)
        app.navigationBars["3D tours"].buttons.firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["spatial.hub.listingPicker"].waitForExistence(timeout: 5), file: file, line: line)
        app.navigationBars["3D tours"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5),
                      "The hub's picker must return to Settings", file: file, line: line)
    }

    private func attachScreen(_ name: String) {
        XCTAssertEqual(app.state, .runningForeground)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
