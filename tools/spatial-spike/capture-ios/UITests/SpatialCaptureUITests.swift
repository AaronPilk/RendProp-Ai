import XCTest

final class SpatialCaptureUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["spatial.status"].waitForExistence(timeout: 10), "Capture screen did not load")
    }

    func testIdleControlsAreLabeledAndExportIsUnavailable() {
        XCTAssertEqual(app.buttons["spatial.start"].label, "Start new room")
        XCTAssertTrue(app.buttons["spatial.start"].isEnabled)
        XCTAssertEqual(app.buttons["spatial.stop"].label, "Stop and save")
        XCTAssertFalse(app.buttons["spatial.stop"].isEnabled)
        XCTAssertEqual(app.buttons["spatial.export"].label, "Export completed capture")
        XCTAssertFalse(app.buttons["spatial.export"].isEnabled)
        attachScreen("idle-controls")
    }

    func testUnsupportedStartDoesNotRequestCameraOrClaimCapture() {
        // This is a simulator behavior test, never a camera/reconstruction substitute.
        XCTAssertTrue(app.staticTexts["spatial.status"].label.contains("simulator cannot capture a room"))
        app.buttons["spatial.start"].tap()
        app.buttons["spatial.start"].tap()
        XCTAssertTrue(app.staticTexts["spatial.status"].label.contains("physical iPhone"))
        XCTAssertFalse(app.otherElements["spatial.preview"].exists, "Unsupported hardware allocated an AR preview")
        XCTAssertFalse(app.buttons["spatial.stop"].isEnabled)
        XCTAssertFalse(app.buttons["spatial.export"].isEnabled)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 2), "Unsupported hardware requested camera permission")
        XCTAssertFalse(app.staticTexts["spatial.status"].label.contains("frames saved"))
        attachScreen("unsupported-no-capture")
    }

    func testRelaunchWithoutCaptureDoesNotOfferExport() {
        app.buttons["spatial.start"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["spatial.status"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["spatial.status"].label.contains("simulator cannot capture a room"))
        XCTAssertFalse(app.buttons["spatial.stop"].isEnabled)
        XCTAssertFalse(app.buttons["spatial.export"].isEnabled)
        XCTAssertFalse(app.otherElements["spatial.preview"].exists)
    }

    private func attachScreen(_ name: String) {
        // After probing SpringBoard, explicitly reassert foreground state and
        // capture the actual screen rather than relying on an app-only snapshot.
        app.activate()
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.staticTexts["spatial.status"].isHittable)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
