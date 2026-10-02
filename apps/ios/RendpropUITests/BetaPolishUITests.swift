import XCTest

/// Actual SwiftUI text entry/navigation on dedicated synthetic simulator data.
/// No camera/photo picker, GPS permission, upload, email, AI call or purchase.
final class BetaPolishUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if targetEnvironment(simulator)
        continueAfterFailure = false
        app = XCUIApplication()
#else
        throw XCTSkip("Synthetic beta-polish fixtures are simulator-only.")
#endif
    }

    override func tearDownWithError() throws {
        guard app != nil else { return }
        attach("beta-polish-final")
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "beta-polish-accessibility"; tree.lifetime = .keepAlways; add(tree)
        app.terminate()
    }

    func testClientCardHasLabelsPrivateRoutingAndSaveAboveKeyboard() {
        launchDetail()
        openDetail("detail.clientContact", title: "Listing contact")
        let name = app.textFields["clientContact.name"]
        scrollTo(name)
        XCTAssertEqual(name.label, "Client or business name")
        XCTAssertEqual(name.value as? String, "Fixture client")
        XCTAssertTrue(app.staticTexts["Client or business name"].exists, "A label must remain after the field is filled")
        let publicEmail = app.textFields["clientContact.publicEmail"]
        scrollTo(publicEmail); publicEmail.tap(); replace(publicEmail, with: "public@example.invalid")
        app.buttons["clientContact.keyboardDone"].tap()
        let recipient = app.textFields["clientContact.recipient"]
        scrollTo(recipient); recipient.tap(); replace(recipient, with: "private-route@example.invalid")
        XCTAssertEqual(recipient.label, "Client's lead email")
        XCTAssertTrue(app.staticTexts["Private delivery email · not part of the public card."].exists)
        let save = app.buttons["clientContact.save"]
        assertAboveKeyboard(save)
        attach("client-contact-keyboard-save")
        app.buttons["clientContact.keyboardDone"].tap()
        // SwiftUI propagates this container identifier to its text children;
        // firstMatch is the heading, not a parent containing the whole card.
        let preview = app.staticTexts.matching(identifier: "clientContact.publicPreview")
        let publicAddress = preview.matching(NSPredicate(format: "label == %@", "public@example.invalid"))
        scrollTo(publicAddress.firstMatch)
        XCTAssertEqual(publicAddress.count, 1, app.debugDescription)
        XCTAssertEqual(preview.matching(NSPredicate(format: "label == %@", "private-route@example.invalid")).count, 0,
                       "A private delivery email must never appear in the public preview")
        scrollTo(recipient); recipient.tap()
        assertAboveKeyboard(save); save.tap()
        XCTAssertTrue(app.navigationBars["Detail fixture rich"].waitForExistence(timeout: 15), app.debugDescription)
        openDetail("detail.clientContact", title: "Listing contact")
        scrollTo(app.textFields["clientContact.recipient"])
        XCTAssertEqual(app.textFields["clientContact.recipient"].value as? String, "private-route@example.invalid")
        XCTAssertEqual(app.textFields["clientContact.publicEmail"].value as? String, "public@example.invalid")
        attach("client-contact-saved-routing")
    }

    func testRoomTagKeyboardKeepsPlayerInputAddAndDoneReachable() {
        launchDetail()
        openDetail("detail.roomTags", title: "Tag rooms")
        let input = app.textFields["roomTagger.customName"]
        XCTAssertTrue(input.waitForExistence(timeout: 10), app.debugDescription)
        input.tap(); input.typeText("Synthetic den")
        assertAboveKeyboard(input)
        let add = app.buttons["roomTagger.addCustom"]
        assertAboveKeyboard(add)
        let player = element("roomTagger.player")
        let shrunk = NSPredicate { _, _ in player.exists && player.frame.height <= 130 }
        expectation(for: shrunk, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        XCTAssertGreaterThanOrEqual(player.frame.minY, app.navigationBars["Tag rooms"].frame.maxY, "The player cannot sit beneath navigation controls")
        XCTAssertTrue(app.buttons["roomTagger.done"].isHittable)
        attach("room-tagger-keyboard-layout")
        add.tap()
        XCTAssertTrue(app.staticTexts["Synthetic den"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Adding a custom tag finishes text entry")
        XCTAssertEqual(input.value as? String, "Custom room name")
        app.buttons["roomTagger.done"].tap()
        XCTAssertTrue(app.navigationBars["Detail fixture rich"].waitForExistence(timeout: 10), app.debugDescription)
        openDetail("detail.roomTags", title: "Tag rooms")
        XCTAssertTrue(app.staticTexts["Synthetic den"].waitForExistence(timeout: 5), "A confirmed manual tag survives closing/reopening")
        attach("room-tagger-saved-manual-tag")
        app.buttons["roomTagger.done"].tap()
    }

    func testCurrentLocationPreservesEnteredUnitThroughCreateAndEdit() {
        app.launchArguments = baseArguments + ["-ui.currentLocationFixture"]
        app.launch()
        let newHome = app.buttons["home.addHome"]
        XCTAssertTrue(newHome.waitForExistence(timeout: 25), app.debugDescription); newHome.tap()
        let unit = app.textFields["newListing.unit"]
        scrollTo(unit); unit.tap(); unit.typeText("4B")
        app.buttons["newListing.keyboardDone"].tap()
        let location = app.buttons["newListing.currentLocation"]
        scrollTo(location); location.tap() // Explicit simulator-only fixture, never GPS.
        XCTAssertEqual(app.textFields["newListing.address"].value as? String, "100 Synthetic Condo Way, Fixture City, NC 28000")
        XCTAssertEqual(unit.value as? String, "4B")
        attach("unit-current-location")
        let photos = app.buttons["newListing.startWithPhotos"]
        scrollTo(photos); photos.tap()
        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 15), app.debugDescription)
        app.navigationBars["Photos"].buttons.element(boundBy: 0).tap()
        let title = "100 Synthetic Condo Way #4B, Fixture City, NC 28000"
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10), app.debugDescription)
        let edit = app.buttons["listing.editDetails"]
        scrollTo(edit); edit.tap()
        XCTAssertTrue(app.navigationBars["Edit home"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.textFields["newListing.unit"].value as? String, "4B")
        XCTAssertEqual(app.textFields["newListing.address"].value as? String, "100 Synthetic Condo Way, Fixture City, NC 28000")
        attach("unit-edit-roundtrip")
        app.navigationBars["Edit home"].buttons["Cancel"].tap()
    }

    func testExistingListingDetailsOpenExpandedAndSaveFacts() {
        launchDetail()
        let edit = app.buttons["listing.editDetails"]
        scrollTo(edit); edit.tap()
        XCTAssertTrue(app.navigationBars["Edit home"].waitForExistence(timeout: 10), app.debugDescription)
        let beds = app.steppers["listing.beds"]
        scrollTo(beds)
        XCTAssertTrue(beds.exists, "Property details must be expanded on the edit screen")
        let baths = app.steppers["listing.baths"]
        XCTAssertTrue(baths.exists)
        let size = app.textFields["listing.sqft"]
        scrollTo(size); size.tap(); replace(size, with: "2100")
        let price = app.textFields["listing.price"]
        scrollTo(price); price.tap(); replace(price, with: "499000")
        let save = app.buttons["listing.edit.save"]
        XCTAssertTrue(save.isEnabled && save.isHittable, app.debugDescription)
        attach("listing-details-keyboard-save")
        save.tap()
        XCTAssertTrue(app.navigationBars["Detail fixture rich"].waitForExistence(timeout: 10), app.debugDescription)
        scrollTo(edit); edit.tap()
        scrollTo(app.textFields["listing.sqft"])
        XCTAssertEqual(app.textFields["listing.sqft"].value as? String, "2100")
        XCTAssertEqual(app.textFields["listing.price"].value as? String, "499000")
        attach("listing-details-saved-facts")
        app.navigationBars["Edit home"].buttons["Cancel"].tap()
    }

    func testPhotoWorkContinuesAfterLeavingStudioAndReviewShowsNewVersions() {
        app.launchArguments = baseArguments + ["-ui.detailMetadataFixture", "rich", "-ui.photoWorkFixture"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Detail fixture rich"].waitForExistence(timeout: 30), app.debugDescription)
        openDetail("detail.photoStudio", title: "AI Photo Studio")
        let declutter = app.buttons["studio.edit.declutter"]
        scrollTo(declutter); declutter.tap()
        let apply = app.buttons["studio.batchApply"]
        scrollTo(apply)
        XCTAssertEqual(apply.label, "Apply to 3 photos", "The actual default selection includes all three synthetic photos")
        apply.tap() // MockAPIClient only; explicit simulator flag delays each edit.
        let banner = element("photoWork.banner")
        let bannerText = banner.descendants(matching: .staticText)
        let running = bannerText.matching(NSPredicate(format: "label CONTAINS %@", "You can use other screens")).firstMatch
        XCTAssertTrue(running.waitForExistence(timeout: 5), app.debugDescription)
        let navigation = app.navigationBars["AI Photo Studio"]
        XCTAssertGreaterThanOrEqual(navigation.frame.minY, banner.frame.maxY - 2,
                                    "Photo status must not cover navigation or intercept Back")
        let back = navigation.buttons.element(boundBy: 0)
        XCTAssertTrue(back.isHittable); back.tap()
        XCTAssertTrue(app.navigationBars["Detail fixture rich"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(running.isHittable, "Actual global status remains visible after leaving the studio")
        let progress = bannerText.matching(NSPredicate(format: "label BEGINSWITH %@", "Declutter ·")).firstMatch
        XCTAssertTrue(progress.exists && progress.label.contains("%"), app.debugDescription)
        attach("photo-work-after-navigation")
        let review = app.buttons["photoWork.review"]
        XCTAssertTrue(review.isHittable); review.tap()
        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 10), app.debugDescription)
        let finished = bannerText.matching(NSPredicate(format: "label == %@", "3 of 3 photos ready")).firstMatch
        let cards = app.buttons.matching(NSPredicate(format: "label == %@", "Photo — opens before-and-after compare"))
        let changes = app.buttons.matching(NSPredicate(format: "label == %@", "Change this photo with AI"))
        // The Review sheet intentionally hides the underlying global banner
        // from accessibility. Observe the actual open library's ready cards and
        // re-enabled controls, then verify global completion after dismissing it.
        let ready = NSPredicate { _, _ in
            cards.count == 3 && changes.count == 3 && changes.allElementsBoundByIndex.allSatisfy(\.isEnabled)
        }
        expectation(for: ready, evaluatedWith: app)
        waitForExpectations(timeout: 40)
        XCTAssertEqual(cards.count, 3, "Review reloads completed photos while its screen is already open")
        scrollTo(cards.firstMatch); cards.firstMatch.tap()
        let label = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Digitally decluttered")).firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 10), "The grid must open the newly saved version, not its stale pre-edit photo")
        XCTAssertTrue(app.buttons["Versions (2)"].exists, "The original and output remain accessible without another paid edit")
        attach("photo-work-reviewed-output-history")
        app.buttons["Close"].tap()
        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 10), app.debugDescription)
        app.navigationBars["Photos"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Detail fixture rich"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(finished.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(finished.isHittable, "Completed status is still available on the main screen")
        attach("photo-work-completed-global-status")
    }

    private var baseArguments: [String] {
        ["-uiTesting", "-hasOnboarded", "YES", "-space.type", "real_estate", "-appearance", "light",
         "-ai.thirdPartyProcessing.consent.v2", "YES"]
    }
    private func launchDetail() {
        app.launchArguments = baseArguments + ["-ui.detailMetadataFixture", "rich"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Detail fixture rich"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(element("detail.fixtureFailure").exists, app.debugDescription)
    }
    private func openDetail(_ id: String, title: String) {
        let control = app.buttons[id]
        scrollTo(control); control.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 15), app.debugDescription)
    }
    private func replace(_ field: XCUIElement, with value: String) {
        let old = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + value)
    }
    private func assertAboveKeyboard(_ control: XCUIElement) {
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        let visible = NSPredicate { _, _ in
            control.exists && control.isHittable && control.frame.maxY <= self.app.keyboards.firstMatch.frame.minY + 2
        }
        expectation(for: visible, evaluatedWith: app)
        waitForExpectations(timeout: 5)
    }
    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func scrollTo(_ control: XCUIElement) {
        XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        // An Edit sheet leaves the covered detail page in the hierarchy. Its
        // scroll view must not receive our gestures. Pick the frontmost visible
        // full-width outer page; narrow horizontal strips remain excluded.
        let outer = app.scrollViews.allElementsBoundByIndex.reversed().first {
            $0.frame.width >= app.frame.width - 8 && $0.isHittable
        }
        guard let outer else { XCTFail("No frontmost page scroll view: \(app.debugDescription)"); return }
        let navigation = app.navigationBars.allElementsBoundByIndex.reversed().first { $0.isHittable }
        var missingRewinds = 0
        for _ in 0..<24 {
            var bottom = min(outer.frame.maxY, app.frame.maxY) - 70
            if app.keyboards.firstMatch.exists { bottom = min(bottom, app.keyboards.firstMatch.frame.minY - 8) }
            if app.buttons["clientContact.save"].exists { bottom = min(bottom, app.buttons["clientContact.save"].frame.minY - 8) }
            let top = max(outer.frame.minY, navigation?.frame.maxY ?? outer.frame.minY) + 8
            // The sheet's accessibility frame can include the keyboard area.
            // Derive both gutter gesture endpoints from the visible viewport,
            // so a number-pad keyboard never consumes a supposed page swipe.
            let height = max(0, bottom - top)
            XCTAssertGreaterThan(height, 80, app.debugDescription)
            let origin = outer.coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: 0))
            let upper = origin.withOffset(CGVector(dx: 0, dy: top - outer.frame.minY + height * 0.2))
            let lower = origin.withOffset(CGVector(dx: 0, dy: top - outer.frame.minY + height * 0.8))
            guard control.exists else {
                if missingRewinds < 6 { upper.press(forDuration: 0.01, thenDragTo: lower); missingRewinds += 1 }
                else { lower.press(forDuration: 0.01, thenDragTo: upper) }
                continue
            }
            if control.frame.height > 0, control.frame.minY >= top, control.frame.maxY <= bottom, control.isHittable { return }
            if control.frame.minY < top { upper.press(forDuration: 0.01, thenDragTo: lower) }
            else { lower.press(forDuration: 0.01, thenDragTo: upper) }
        }
        XCTFail("Control did not enter the safe scroll viewport: \(control.debugDescription)\n\(app.debugDescription)")
    }
    private func attach(_ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
}
