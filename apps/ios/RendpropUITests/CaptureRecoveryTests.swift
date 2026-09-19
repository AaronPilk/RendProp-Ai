import XCTest

/// Synthetic media is seeded externally into a newly-created isolated simulator.
/// No login, uploads, AI calls, customer footage, or existing simulator data.
final class CaptureRecoveryTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-hasOnboarded", "YES", "-space.type", "real_estate",
                               "-appearance", "light", "-ai.thirdPartyProcessing.consent.v2", "NO"]
    }

    override func tearDownWithError() throws {
        shot("recovery-final-state")
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "recovery-final-accessibility-tree"
        tree.lifetime = .keepAlways
        add(tree)
        app.terminate()
    }

    func testSavedTakeRelaunchRetryAndManualExport() throws {
        app.launch()
        openCapture()
        openLibrary()
        XCTAssertTrue(app.staticTexts["Other recordings on this phone"].waitForExistence(timeout: 5))
        shot("01-recovery-library-including-legacy")

        selectSavedTake()
        XCTAssertTrue(app.buttons["Save part 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Save part 2"].exists)
        app.buttons["Keep for later"].tap()

        // A process relaunch must rediscover the journal and the same originals.
        app.terminate()
        app.launch()
        openCapture()
        openLibrary()
        XCTAssertTrue(app.staticTexts["Other recordings on this phone"].exists)
        selectSavedTake()
        shot("02-recovery-after-process-relaunch")
        app.buttons["capture.retry-join"].tap()
        let use = app.buttons["Use this take"]
        XCTAssertTrue(use.waitForExistence(timeout: 20), "Retry must reach playable review even with camera unavailable.\n" + app.debugDescription)
        XCTAssertTrue(use.isEnabled)
        XCTAssertTrue(app.buttons["Record another"].exists)
        shot("03-recovered-take-review-camera-unavailable")
        app.buttons["Record another"].tap()
        openLibrary()

        // Target the exact original even if earlier retries retained additional
        // joined outputs. No external destination or recipient is selected.
        let legacy = app.buttons["capture.other-recording.walkthrough-legacy-ui.mov"]
        XCTAssertTrue(legacy.waitForExistence(timeout: 5), app.debugDescription)
        legacy.tap()
        assertShareSheet("04-legacy-file-export")
        dismissShareSheet()
        selectSavedTake()
        XCTAssertTrue(app.buttons["Save part 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Save part 2"].exists)
        app.buttons["Save part 2"].tap()
        assertShareSheet("05-ordered-part-export")
        dismissShareSheet()
        shot("06-recovery-retry-and-export-controls")
        app.buttons["Keep for later"].tap()
    }

    private func openCapture() {
        let add = app.buttons["home.addHome"]
        XCTAssertTrue(add.waitForExistence(timeout: 20), app.debugDescription)
        add.tap()
        let address = app.textFields["Type the home's address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10), app.debugDescription)
        address.tap()
        address.typeText("Recovery fixture")
        let record = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Record a walkthrough'")).firstMatch
        for _ in 0..<4 where !record.isHittable { app.swipeUp() }
        XCTAssertTrue(record.isHittable, app.debugDescription)
        record.tap()
        XCTAssertTrue(app.buttons["capture.saved-takes"].waitForExistence(timeout: 15), app.debugDescription)
    }

    private func openLibrary() {
        app.buttons["capture.saved-takes"].tap()
        XCTAssertTrue(app.navigationBars["Saved takes"].waitForExistence(timeout: 5))
    }

    private func selectSavedTake() {
        let take = app.buttons.matching(NSPredicate(format: "label CONTAINS '2 parts'")).firstMatch
        XCTAssertTrue(take.waitForExistence(timeout: 5), app.debugDescription)
        take.tap()
        XCTAssertTrue(app.buttons["capture.retry-join"].waitForExistence(timeout: 5))
    }

    private func assertShareSheet(_ name: String) {
        let save = app.cells["Save to Files"]
        if !save.waitForExistence(timeout: 2) {
            // iOS can anchor this activity controller as a compact popover.
            // An app-wide swipe hits the recovery screen behind it. Expand
            // the actual observed action row, then scroll its own collection.
            let more = app.cells["View More"]
            XCTAssertTrue(more.waitForExistence(timeout: 3), app.debugDescription)
            more.tap()
            if !save.waitForExistence(timeout: 2) {
                app.collectionViews["activityCollectionView"].swipeUp()
            }
        }
        XCTAssertTrue(save.waitForExistence(timeout: 5), app.debugDescription)
        shot(name)
    }

    private func dismissShareSheet() {
        let close = app.buttons["header.closeButton"]
        if close.exists { close.tap() }
        else if app.otherElements["PopoverDismissRegion"].exists {
            app.otherElements["PopoverDismissRegion"].tap()
        }
        else {
            let cancel = app.buttons["Cancel"]
            XCTAssertTrue(cancel.exists, app.debugDescription)
            cancel.tap()
        }
    }

    private func shot(_ name: String) {
        guard app != nil else { return }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
