import XCTest
import StoreKitTest

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

    func testProfileBusinessCardAndExplicitPortfolioSelection() {
        launchProfile()
        let card = app.buttons["profile.sendBusinessCard"]
        scrollTo(card); XCTAssertTrue(card.isEnabled); card.tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.otherElements["LP.CaptionBar.TopCaption"].label.hasPrefix("rendprop-business-card-"))
        XCTAssertTrue(app.otherElements["LP.CaptionBar.BottomCaption"].label.contains("Contact Card"))
        attach("profile-business-card-only")
        closeProfileShare()
        let portfolio = app.buttons["profile.sharePortfolio"]
        scrollTo(portfolio); XCTAssertTrue(portfolio.label.contains("3")); portfolio.tap()
        let share = app.buttons["profile.portfolio.shareSelection"]
        XCTAssertTrue(share.waitForExistence(timeout: 10)); XCTAssertFalse(share.isEnabled)
        let houses = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "profile.portfolio.listing."))
        XCTAssertEqual(houses.count, 3, "Only published, active houses in the selected workspace are offered")
        for excluded in ["Unpublished control", "Sold control", "Other workspace control", "Sample control", "Unbound workspace control"] {
            XCTAssertFalse(app.staticTexts[excluded].exists, app.debugDescription)
        }
        houses.element(boundBy: 0).tap(); houses.element(boundBy: 2).tap()
        XCTAssertEqual(share.label, "Share (2)"); XCTAssertTrue(share.isEnabled)
        attach("profile-explicit-two-houses")
        share.tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 15), "The chosen portfolio must reach the actual OS share sheet: \(app.debugDescription)")
        XCTAssertTrue(app.otherElements["LP.CaptionBar.TopCaption"].label.hasPrefix("rendprop-portfolio-"))
        attach("profile-selected-portfolio-share")
        closeProfileShare()
        scrollTo(portfolio); portfolio.tap()
        XCTAssertTrue(share.waitForExistence(timeout: 10)); XCTAssertFalse(share.isEnabled, "Reopening the selector does not silently select houses")
        app.navigationBars["Share portfolio"].buttons["Cancel"].tap()
    }

    func testProfileLogoIsSeparateAndPhoneKeepsInternationalNumber() {
        launchProfile()
        XCTAssertTrue(element("profile.businessLogo").exists)
        let edit = app.buttons["Edit card"]
        scrollTo(edit); edit.tap()
        let retry = app.buttons["profile.logo.retry"]
        scrollProfileFormTo(retry); retry.tap() // Closed MockAPIClient only.
        let finished = NSPredicate { _, _ in !retry.exists }
        expectation(for: finished, evaluatedWith: app); waitForExpectations(timeout: 10)
        let phone = app.textFields["profile.phone"]
        scrollProfileFormTo(phone)
        XCTAssertEqual(phone.value as? String, "555-123-4567")
        // A center tap can place the caret inside the formatted number. Use
        // the text's trailing edge before replacing every existing character.
        phone.coordinate(withNormalizedOffset: CGVector(dx: 0.999, dy: 0.5)).tap()
        replace(phone, with: "+44 20 7946 0958")
        XCTAssertEqual(phone.value as? String, "+44 20 7946 0958", "International digits are never truncated or regrouped as a US number")
        app.swipeDown() // Dismiss keyboard interactively; do not invoke Photos.
        let remove = app.buttons["profile.logo.remove"]
        scrollProfileFormTo(remove); remove.tap()
        let absent = NSPredicate { _, _ in !remove.exists }
        expectation(for: absent, evaluatedWith: app); waitForExpectations(timeout: 10)
        XCTAssertFalse(app.staticTexts["profile.logo.error"].exists, app.debugDescription)
        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == %@", "Synthetic Agent")).firstMatch.exists,
                      "Removing the business logo preserves the person's card identity")
        attach("profile-logo-removed-phone-preserved")
    }

    func testProfileExplicitSaveAboveKeyboardAndTeamKeepsPersonalCard() {
        launchProfile()
        let edit = app.buttons["Edit card"]
        scrollTo(edit); edit.tap()
        let name = app.textFields["profile.name"]
        scrollProfileFormTo(name)
        name.coordinate(withNormalizedOffset: CGVector(dx: 0.999, dy: 0.5)).tap()
        replace(name, with: "My own saved card")
        let phone = app.textFields["profile.phone"]
        scrollProfileFormTo(phone)
        phone.coordinate(withNormalizedOffset: CGVector(dx: 0.999, dy: 0.5)).tap()
        replace(phone, with: "+44 20 7946 0958")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        let save = app.buttons["profile.save"]
        XCTAssertTrue(save.isHittable && save.isEnabled, "Explicit Save remains above the phone keyboard")
        attach("profile-save-above-phone-keyboard")
        save.tap()
        let receipt = app.staticTexts["profile.saveReceipt"]
        let saved = NSPredicate { _, _ in receipt.exists && receipt.label == "Saved to your personal card." }
        expectation(for: saved, evaluatedWith: app); waitForExpectations(timeout: 10)
        app.navigationBars.buttons["Profile"].tap()
        XCTAssertEqual(app.staticTexts["profile.personalName"].label, "My own saved card")
        app.buttons["profile.fixture.switchWorkspace"].tap()
        XCTAssertEqual(app.staticTexts["profile.personalName"].label, "My own saved card", "Inviter brand cannot replace the person's account card")
        XCTAssertFalse(app.staticTexts["Inviting agent"].exists)
        scrollTo(edit); edit.tap()
        XCTAssertEqual(app.textFields["profile.name"].value as? String, "My own saved card")
        scrollProfileFormTo(phone)
        XCTAssertEqual(phone.value as? String, "+44 20 7946 0958", "Explicit Save persists the international number across a team switch")
        app.swipeDown()
        let choose = app.buttons["profile.logo.choose"]
        scrollProfileFormTo(choose)
        XCTAssertFalse(choose.isEnabled, "A team member's personal Save does not grant agency-logo write access")
        attach("profile-own-card-after-team-switch")
    }

    func testClientSaveExplainsChangedWorkspaceAndRemainsInvalidAfterABA() {
        launchProfile()
        app.tabBars.buttons["Client"].tap()
        let save = app.buttons["clientContact.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10)); XCTAssertTrue(save.isEnabled)
        app.buttons["profile.fixture.switchWorkspace"].tap()
        XCTAssertTrue(app.staticTexts["clientContact.staleContext"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(save.isEnabled)
        XCTAssertTrue(app.buttons["Close editor"].isHittable, "Stale editor keeps a reachable explanation and exit")
        app.buttons["profile.fixture.switchWorkspace"].tap()
        XCTAssertFalse(save.isEnabled, "Returning to the same workspace cannot revive an old editor epoch")
        attach("client-contact-stale-workspace-explanation")
    }

    @available(iOS 17.0, *)
    func testCompactPaywallUsesLocalStoreKitAndGuideIsReachableAtLargeText() throws {
        let config = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Rendprop", withExtension: "storekit"))
        let store = try SKTestSession(contentsOf: config)
        store.resetToDefaultState(); store.clearTransactions(); store.disableDialogs = true
        defer { store.clearTransactions() }
        guard store.disableDialogs else { throw NSError(domain: "ProfileLocalStoreKitUnavailable", code: 1) }
        store.storefront = "USA"; store.locale = Locale(identifier: "en_US")
        launchProfile()
        app.tabBars.buttons["Plans"].tap()
        let pro = app.buttons["paywall.plan.pro"]
        XCTAssertTrue(pro.waitForExistence(timeout: 25), "All choices require actual local StoreKit products: \(app.debugDescription)")
        XCTAssertTrue(app.buttons["paywall.plan.starter"].exists && app.buttons["paywall.plan.team"].exists)
        XCTAssertTrue(app.buttons["Start 7-day free trial"].exists, "The original eligible offer remains explicit")
        XCTAssertTrue(element("paywall.selectedDetails").exists)
        attach("paywall-compact-pro-local-products")
        app.buttons["paywall.plan.starter"].tap()
        XCTAssertTrue(app.staticTexts["paywall.selection"].label.contains("Starter"))
        app.segmentedControls["paywall.period"].buttons["Yearly"].tap()
        XCTAssertTrue(app.staticTexts["paywall.selection"].label.contains("Yearly"))
        XCTAssertTrue(store.allTransactions().isEmpty, "Opening and choosing plans never purchases or starts a trial")
        attach("paywall-compact-yearly-no-purchase")
    }

    func testProfileGuideIsReachableAtLargeText() {
        launchProfile(largeText: true)
        app.tabBars.buttons["Guide"].tap()
        XCTAssertTrue(app.navigationBars["App walkthrough"].waitForExistence(timeout: 10))
        let contact = app.buttons["guide.contact"]
        // At accessibility sizes a whole guide card is taller than the
        // viewport. A visible hittable portion is sufficient to open it.
        for _ in 0..<18 { if contact.exists && contact.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(contact.isHittable, app.debugDescription); contact.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Send business card")).firstMatch.waitForExistence(timeout: 10))
        attach("profile-guide-large-text")
    }

    func testProfileGuestArchiveRequiresReviewAndExplicitSave() {
        launchProfile(archive: true)
        XCTAssertEqual(app.staticTexts["profile.personalName"].label, "Synthetic Agent", "Guest archive cannot replace current identity on opening Profile")
        let edit = app.buttons["Edit card"]
        scrollTo(edit); edit.tap()
        let review = app.buttons["profile.reviewGuestCard"]
        scrollProfileFormTo(review); XCTAssertTrue(review.isHittable); review.tap()
        let load = app.buttons["Review saved details"]
        XCTAssertTrue(load.waitForExistence(timeout: 10)); load.tap()
        let name = app.textFields["profile.name"]
        let reviewed = NSPredicate { _, _ in name.exists && name.value as? String == "Saved guest agent" }
        expectation(for: reviewed, evaluatedWith: app); waitForExpectations(timeout: 10)
        attach("profile-guest-archive-editor-only")
        app.navigationBars.buttons["Profile"].tap()
        XCTAssertEqual(app.staticTexts["profile.personalName"].label, "Synthetic Agent", "Review without Save leaves existing personal identity unchanged")
        scrollTo(edit); edit.tap()
        scrollProfileFormTo(review); review.tap()
        XCTAssertTrue(load.waitForExistence(timeout: 10)); load.tap()
        expectation(for: reviewed, evaluatedWith: app); waitForExpectations(timeout: 10)
        let save = app.buttons["profile.save"]
        XCTAssertTrue(save.isHittable && save.isEnabled); save.tap()
        let receipt = app.staticTexts["profile.saveReceipt"]
        expectation(for: NSPredicate { _, _ in receipt.exists && receipt.label == "Saved to your personal card." }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        app.navigationBars.buttons["Profile"].tap()
        XCTAssertEqual(app.staticTexts["profile.personalName"].label, "Saved guest agent", "Only deliberate Save applies the reviewed card")
        attach("profile-guest-archive-explicit-save")
    }

    private func launchProfile(largeText: Bool = false, archive: Bool = false) {
        app.launchArguments = baseArguments + ["-ui.profileFeedbackFixture", "-auth.supabase.userID", "b3710000-0000-4000-8000-000000000001"]
        if largeText { app.launchArguments += ["-ui.profileFeedbackLargeText"] }
        if archive { app.launchArguments += ["-ui.profileGuestArchiveFixture"] }
        app.launch()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertFalse(element("profile.fixture.failure").exists)
    }

    private func closeProfileShare() {
        let close = app.buttons["header.closeButton"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription); close.tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 10), app.debugDescription)
    }

    private func scrollProfileFormTo(_ control: XCUIElement) {
        let form = app.collectionViews.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<20 {
            if control.exists && control.isHittable { return }
            // The collection's accessibility frame can extend behind the
            // keyboard. Keep the gesture inside its actually visible content.
            let keyboardTop = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY - 60 : form.frame.maxY
            let visibleBottom = min(form.frame.maxY, keyboardTop, app.buttons["profile.save"].frame.minY)
            let top = max(form.frame.minY, app.navigationBars.firstMatch.frame.maxY) + 24
            let bottom = max(top + 40, visibleBottom - 24)
            // Short moves keep a virtualized field from passing through the
            // visible area between snapshots. Reverse if it is above us.
            let step = min(120, (bottom - top) / 3)
            let movingDown = control.exists && control.frame.midY < top
            let startY = movingDown ? top : bottom
            let endY = movingDown ? top + step : bottom - step
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: form.frame.midX, dy: startY))
            let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: form.frame.midX, dy: endY))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Profile form control is unreachable: \(control.debugDescription)\n\(app.debugDescription)")
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
        XCTAssertTrue(app.buttons["All edits"].exists, "Saved edit history remains accessible without another paid edit")
        XCTAssertTrue(app.buttons["Earlier source"].exists, "The legacy source stays available without claiming a verified original")
        XCTAssertTrue(app.buttons["Decluttered"].exists, "The saved decluttered version remains available for comparison")
        attach("photo-work-reviewed-output-history")
        app.buttons["Close"].tap()
        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 10), app.debugDescription)
        app.navigationBars["Photos"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Detail fixture rich"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(finished.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(finished.isHittable, "Completed status is still available on the main screen")
        attach("photo-work-completed-global-status")
    }

    func testLegacyGalleryKeepsSiblingsAndStagedCoverRequiresReview() {
        launchDetail() // Three enh-/orig- pairs, deliberately no history file.
        openDetail("detail.photos", title: "Photos")
        let cards = app.buttons.matching(NSPredicate(format: "label == %@", "Photo — opens before-and-after compare"))
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(cards.matching(NSPredicate(format: "value == %@", "Selected for listing")).count, 3,
                       "Every pre-history sibling remains eligible for publication")
        // First history mutation is removal, not an all-photo fixture import.
        scrollTo(cards.firstMatch); cards.firstMatch.press(forDuration: 1)
        let remove = app.buttons.matching(NSPredicate(format: "label == %@", "Remove from gallery")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5), app.debugDescription); remove.tap()
        XCTAssertTrue(remove.waitForExistence(timeout: 5), app.debugDescription); remove.tap()
        let two = NSPredicate { _, _ in cards.count == 2 }
        expectation(for: two, evaluatedWith: app); waitForExpectations(timeout: 10)
        XCTAssertEqual(cards.matching(NSPredicate(format: "value == %@", "Selected for listing")).count, 2,
                       "Removing one legacy family cannot empty the selected gallery")
        let cover = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "photos.cover.")).firstMatch
        scrollTo(cover); cover.tap()
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "This is the cover photo")).count, 1,
                       "A legacy cover is also an indexed publication choice")
        app.navigationBars["Photos"].buttons.element(boundBy: 0).tap()
        openDetail("detail.photoStudio", title: "AI Photo Studio")
        let modern = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Modern — pick the photos")).firstMatch
        scrollTo(modern); modern.tap()
        let apply = app.buttons["studio.batchApply"]
        scrollTo(apply); XCTAssertEqual(apply.label, "Apply to 2 photos"); apply.tap()
        let finished = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Staging · Modern", "2 photos changed")).firstMatch
        XCTAssertTrue(finished.waitForExistence(timeout: 40), app.debugDescription)
        app.navigationBars["AI Photo Studio"].buttons.element(boundBy: 0).tap()
        openDetail("detail.photos", title: "Photos")
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards.matching(NSPredicate(format: "value == %@", "Earlier version on listing")).count, 2,
                       "Staging leaves both retained legacy choices on the listing")
        let stagedCover = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "photos.cover.")).firstMatch
        scrollTo(stagedCover)
        let versionID = String(stagedCover.identifier.dropFirst("photos.cover.".count))
        stagedCover.tap()
        assertCompareContains("Virtually staged")
        let use = app.buttons["photoVersion.useOnListing"]
        XCTAssertTrue(use.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(use.label, "Use this version on listing", "The cover star opens review instead of publishing staging immediately")
        attach("legacy-staging-cover-review-gate")
        use.tap(); XCTAssertEqual(use.label, "Selected for listing")
        app.buttons["Close"].tap()
        let reviewedCover = app.buttons["photos.cover.\(versionID)"]
        scrollTo(reviewedCover)
        XCTAssertEqual(reviewedCover.label, "This is the cover photo", "The explicit review completes the requested cover change")
        let reviewedCard = app.buttons["photos.version.\(versionID)"]
        XCTAssertEqual(reviewedCard.value as? String, "Selected for listing")
        // Hiding the family with the cover must choose a selected predecessor
        // from the remaining family, never its unreviewed latest staging.
        reviewedCard.press(forDuration: 1)
        XCTAssertTrue(remove.waitForExistence(timeout: 5)); remove.tap()
        XCTAssertTrue(remove.waitForExistence(timeout: 5)); remove.tap()
        let one = NSPredicate { _, _ in cards.count == 1 }
        expectation(for: one, evaluatedWith: app); waitForExpectations(timeout: 10)
        XCTAssertEqual(cards.firstMatch.value as? String, "Earlier version on listing")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "This is the cover photo")).count, 0,
                       "Fallback cover must not approve the remaining staged preview")
        attach("legacy-gallery-retained-clean-cover-fallback")
    }

    func testSavedDeclutterAndStagingLibrariesKeepDownloadsAndListingChoiceSeparate() {
        launchDetail() // Existing procedural legacy fixture; MockAPIClient only.
        let desktop = element("studio.desktopLink")
        scrollTo(desktop)
        XCTAssertTrue(desktop.isHittable, "Uploaded listings need a discoverable desktop continuation")
        XCTAssertTrue(app.staticTexts["studio.rendprop.com"].exists)
        openDetail("detail.photoStudio", title: "AI Photo Studio")
        let declutter = app.buttons["studio.edit.declutter"]
        scrollTo(declutter); declutter.tap()
        applyThreeFixturePhotosAndWait(for: "Declutter")
        let modern = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Modern — pick the photos")).firstMatch
        scrollTo(modern); modern.tap()
        applyThreeFixturePhotosAndWait(for: "Staging · Modern")
        app.navigationBars["AI Photo Studio"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Detail fixture rich"].waitForExistence(timeout: 10), app.debugDescription)
        openDetail("detail.photos", title: "Photos")
        let library = app.segmentedControls["photos.savedVersions"]
        scrollTo(library)
        XCTAssertTrue(library.exists, app.debugDescription)
        library.buttons["Decluttered"].tap()
        let cards = app.buttons.matching(NSPredicate(format: "label == %@", "Photo — opens before-and-after compare"))
        XCTAssertEqual(cards.count, 3, "There is one saved clean photo per family after staging")
        XCTAssertEqual(cards.matching(NSPredicate(format: "value == %@", "Selected for listing")).count, 3,
                       "Each retained declutter must expose its actual listing selection")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Change this photo with AI")).count, 0,
                       "Browsing old clean versions must not replace the current editing workspace")
        scrollTo(cards.firstMatch); cards.firstMatch.tap()
        assertCompareContains("Digitally decluttered")
        assertSelectedExportForCompareButton("Download decluttered photo", original: false)
        app.buttons["Close"].tap()
        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 10), app.debugDescription)

        scrollTo(library); library.buttons["Staged"].tap()
        XCTAssertEqual(cards.count, 3, "The staged library keeps one newest preview per family")
        XCTAssertEqual(cards.matching(NSPredicate(format: "value == %@", "Selected for listing")).count, 0,
                       "Unselected staged previews must not acquire a listing badge")
        scrollTo(cards.firstMatch); cards.firstMatch.tap()
        assertCompareContains("Virtually staged")
        let choices = app.scrollViews["photoVersion.savedChoices"]
        XCTAssertTrue(choices.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(choices.buttons["Decluttered"].exists && choices.buttons["Staged"].exists, app.debugDescription)
        // Rich's enh-/orig- files predate the durable capture history. They
        // must remain explicitly unverified, never gain a certified-original
        // label just because the offline edit runner touched them.
        let source = choices.buttons["Earlier source"]
        XCTAssertTrue(source.exists && !choices.buttons["Original"].exists, app.debugDescription)
        assertSelectedExportForCompareButton("Download staged photo", original: false)
        source.tap()
        XCTAssertTrue(source.isSelected, app.debugDescription)
        assertSelectedExportForCompareButton("Download earlier source", original: true)
        choices.buttons["Decluttered"].tap()
        XCTAssertTrue(choices.buttons["Decluttered"].isSelected, app.debugDescription)
        assertCompareContains("Digitally decluttered")
        assertSelectedExportForCompareButton("Download decluttered photo", original: false)
        let publication = app.buttons["photoVersion.useOnListing"]
        XCTAssertEqual(publication.label, "Selected for listing", "Staging stays a preview until explicitly chosen")
        choices.buttons["Staged"].tap()
        let stageNotSelected = NSPredicate { _, _ in publication.exists && publication.label == "Use this version on listing" }
        expectation(for: stageNotSelected, evaluatedWith: app); waitForExpectations(timeout: 5)
        publication.tap()
        XCTAssertEqual(publication.label, "Selected for listing")
        choices.buttons["Decluttered"].tap()
        let cleanNotSelected = NSPredicate { _, _ in publication.exists && publication.label == "Use this version on listing" }
        expectation(for: cleanNotSelected, evaluatedWith: app); waitForExpectations(timeout: 5)
        publication.tap()
        XCTAssertEqual(publication.label, "Selected for listing")
        attach("saved-photo-library-public-clean-selection")
        app.buttons["Close"].tap()
        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 10), app.debugDescription)
        scrollTo(library); library.buttons["Latest"].tap()
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(cards.matching(NSPredicate(format: "value == %@", "Selected for listing")).count, 0,
                       "Selecting an older declutter keeps the latest staged tiles unselected")
        XCTAssertEqual(cards.matching(NSPredicate(format: "value == %@", "Decluttered version on listing")).count, 3,
                       "Latest staging must explain that the saved clean version is on the listing")
        scrollTo(cards.firstMatch); cards.firstMatch.tap()
        assertCompareContains("Virtually staged")
        XCTAssertTrue(app.scrollViews["photoVersion.savedChoices"].buttons["Staged"].isSelected,
                      "Choosing the declutter for publication must not change the latest staging workspace")
        XCTAssertEqual(app.buttons["photoVersion.useOnListing"].label, "Use this version on listing")
        attach("saved-photo-library-latest-stage-retained")
        app.buttons["Close"].tap()
        app.navigationBars["Photos"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Detail fixture rich"].waitForExistence(timeout: 10))
        // Exercise the exact listing file grid reported in beta feedback, not
        // only the separate Photos library. File-row ids are kind-prefixed;
        // the first compare action must still target the saved version id.
        let filePhotos = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "listing.filePhoto.photo-"))
        scrollTo(filePhotos.firstMatch)
        XCTAssertEqual(filePhotos.count, 3)
        let fileSaves = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "listing.savePhoto.photo-"))
        XCTAssertEqual(fileSaves.count, 3)
        XCTAssertTrue(fileSaves.allElementsBoundByIndex.allSatisfy { $0.label == "Save this photo to your Photos app" },
                      "Download controls must not inherit the open-photo label or selected state")
        XCTAssertEqual(filePhotos.matching(NSPredicate(format: "value == %@", "Selected for listing")).count, 0)
        XCTAssertEqual(filePhotos.matching(NSPredicate(format: "value == %@", "Decluttered version on listing")).count, 3,
                       "The listing file grid must identify each family's selected clean version")
        filePhotos.firstMatch.tap()
        let fileSelection = app.buttons["photoVersion.useOnListing"]
        XCTAssertTrue(fileSelection.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(fileSelection.label, "Use this version on listing")
        fileSelection.tap() // No version-chip tap to repair a malformed id.
        XCTAssertEqual(fileSelection.label, "Selected for listing", app.debugDescription)
        app.buttons["Close"].tap()
        let selectedFiles = filePhotos.matching(NSPredicate(format: "value == %@", "Selected for listing"))
        let refreshed = NSPredicate { _, _ in selectedFiles.count == 1 }
        expectation(for: refreshed, evaluatedWith: app); waitForExpectations(timeout: 10)
        scrollTo(selectedFiles.firstMatch)
        attach("listing-file-grid-selected-version")
        selectedFiles.firstMatch.tap()
        XCTAssertTrue(fileSelection.waitForExistence(timeout: 10))
        let persisted = NSPredicate { _, _ in fileSelection.label == "Selected for listing" }
        expectation(for: persisted, evaluatedWith: app); waitForExpectations(timeout: 5)
        XCTAssertEqual(fileSelection.label, "Selected for listing", "The file viewer must use the persisted photo version id on first open")
        app.buttons["Close"].tap()
    }

    func testManualMeasurementsCreateEditExportAndKeepScanChoice() {
        launchDetail()
        openDetail("detail.floorPlan", title: "Floor plan")
        let measurements = app.buttons["floorPlan.measurements"]
        scrollTo(measurements); measurements.tap()
        XCTAssertTrue(app.navigationBars["Measurements"].waitForExistence(timeout: 10), app.debugDescription)
        addMeasuredRoom("Living room", length: "12", width: "10")
        addMeasuredRoom("Office", length: "8", width: "9")
        let roomButtons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "measurements.room."))
        XCTAssertEqual(roomButtons.count, 2, app.debugDescription)
        scrollTo(roomButtons.firstMatch); roomButtons.firstMatch.tap()
        let width = app.textFields["measurements.width"]
        XCTAssertTrue(width.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(width.value as? String, "10")
        width.tap(); replace(width, with: "11")
        app.buttons["measurements.saveRoom"].tap()
        let overlap = app.staticTexts["measurements.formError"]
        XCTAssertTrue(overlap.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(overlap.label.lowercased().contains("overlap"), overlap.label)
        app.navigationBars["Room measurements"].buttons["Cancel"].tap()
        let units = app.segmentedControls["measurements.units"]
        scrollTo(units); units.buttons["Metres"].tap()
        scrollTo(roomButtons.firstMatch); roomButtons.firstMatch.tap()
        XCTAssertEqual(app.textFields["measurements.width"].value as? String, "3.048")
        app.buttons["measurements.saveRoom"].tap()
        XCTAssertTrue(app.navigationBars["Measurements"].waitForExistence(timeout: 10))
        let export = app.buttons["measurements.export"]
        scrollTo(export); export.tap()
        XCTAssertTrue(app.navigationBars["Export room plan"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.buttons["measurements.sharePDF"].exists, "The actual rendered plan has an image and PDF export")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Drawn from entered measurements")).firstMatch.exists)
        attach("measured-plan-export")
        app.navigationBars["Export room plan"].buttons["Done"].tap()
        let threeD = app.buttons["measurements.view3D"]
        scrollTo(threeD); threeD.tap()
        XCTAssertTrue(app.navigationBars["3D measurement layout"].waitForExistence(timeout: 15), app.debugDescription)
        attach("measured-room-layout-3d")
        app.navigationBars["3D measurement layout"].buttons["Done"].tap()
        app.navigationBars["Measurements"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Floor plan"].waitForExistence(timeout: 10))
        scrollTo(measurements)
        XCTAssertTrue(measurements.label.contains("2 rooms"), measurements.label)
        measurements.tap()
        XCTAssertTrue(app.navigationBars["Measurements"].waitForExistence(timeout: 10))
        scrollTo(roomButtons.firstMatch); roomButtons.firstMatch.tap()
        XCTAssertEqual(app.textFields["measurements.width"].value as? String, "3.048")
        XCTAssertEqual(app.textFields["measurements.length"].value as? String, "3.658")
        app.navigationBars["Room measurements"].buttons["Cancel"].tap()
        attach("measured-plan-reopened")
        for _ in 0..<2 {
            scrollTo(roomButtons.firstMatch); roomButtons.firstMatch.tap()
            let delete = app.buttons["Delete this room"]
            XCTAssertTrue(app.navigationBars["Room measurements"].waitForExistence(timeout: 10))
            for _ in 0..<4 where !delete.isHittable { app.collectionViews.firstMatch.swipeUp() }
            XCTAssertTrue(delete.isHittable, app.debugDescription); delete.tap()
            XCTAssertTrue(app.buttons["Delete room"].waitForExistence(timeout: 5), app.debugDescription)
            app.buttons["Delete room"].tap()
            XCTAssertTrue(app.navigationBars["Measurements"].waitForExistence(timeout: 10))
        }
        XCTAssertEqual(roomButtons.count, 0)
        XCTAssertFalse(app.buttons["measurements.export"].exists, "An empty plan cannot export stale geometry")
        app.navigationBars["Measurements"].buttons.element(boundBy: 0).tap()
        scrollTo(measurements); measurements.tap()
        XCTAssertTrue(app.navigationBars["Measurements"].waitForExistence(timeout: 10))
        XCTAssertEqual(roomButtons.count, 0, "Deleting the last room must not resurrect the raw cloud plan")
        attach("measured-plan-cleared")
    }

    func testIrregularOutlinesDeductAreaExportReopenAndDeleteLinkedOpenings() {
        launchDetail()
        openDetail("detail.floorPlan", title: "Floor plan")
        let measurements = app.buttons["floorPlan.measurements"]
        scrollTo(measurements); measurements.tap()
        XCTAssertTrue(app.navigationBars["Measurements"].waitForExistence(timeout: 10), app.debugDescription)
        let units = app.segmentedControls["measurements.units"]
        scrollTo(units); units.buttons["Metres"].tap()

        // This concave L is 16 m², not the 24 m² bounding rectangle.
        beginMeasuredOutline("Main L")
        let mainWalls = [("6", "Right →"), ("4", "Down ↓"), ("2", "Left ←"),
                         ("2", "Up ↑"), ("4", "Left ←"), ("2", "Up ↑")]
        for (index, wall) in mainWalls.enumerated() {
            addOutlineWall(length: wall.0, direction: wall.1, expectedCount: index + 1)
        }
        reviewOutlineClosingWall()
        XCTAssertTrue(app.staticTexts["Your entered walls close the outline."].exists, app.debugDescription)
        XCTAssertFalse(element("measurements.calculatedClosingWarning").exists,
                       "All six measured walls close the L; none may be relabeled as calculated")
        saveMeasuredOutline()
        assertFinishedOutlineArea("16.00")

        // A 1 m² opening shares its parent's plan origin, remains fully inside
        // the L, and is explicitly deducted once from that parent's area.
        beginMeasuredOutline("Opening")
        chooseOutlineMenu("measurements.outlineCategory", label: "Open below")
        chooseOutlineMenu("measurements.deductionParent", label: "Main L")
        for (index, wall) in [("1", "Right →"), ("1", "Down ↓"), ("1", "Left ←")].enumerated() {
            addOutlineWall(length: wall.0, direction: wall.1, expectedCount: index + 1)
        }
        let startX = app.textFields["measurements.startX"]
        scrollMeasurementFormTo(startX); replaceTrailingMeasurementField(startX, with: "1")
        dismissMeasurementKeyboard()
        let startY = app.textFields["measurements.startY"]
        scrollMeasurementFormTo(startY); replaceTrailingMeasurementField(startY, with: "0.5")
        dismissMeasurementKeyboard()
        XCTAssertEqual(startX.value as? String, "1", app.debugDescription)
        XCTAssertEqual(startY.value as? String, "0.5", app.debugDescription)
        reviewOutlineClosingWall()
        XCTAssertTrue(element("measurements.calculatedClosingWarning").exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "calculated, not measured")).firstMatch.exists,
                      "The unentered final opening wall must remain explicitly calculated")
        attach("outline-opening-calculated-closing-wall")
        saveMeasuredOutline()

        let outlineButtons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "measurements.outline."))
        XCTAssertEqual(outlineButtons.count, 2, app.debugDescription)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "measurements.room.")).count, 0)
        assertFinishedOutlineArea("15.00")
        let calculation = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Main L", "16.00 m² − 1.00 m² deductions = 15.00 m²")).firstMatch
        XCTAssertTrue(calculation.exists, app.debugDescription)
        let deduction = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "1.00 m² deducted from Main L")).firstMatch
        XCTAssertTrue(deduction.exists, app.debugDescription)
        attach("irregular-outline-area-worksheet")

        // Closing/reopening the editor must preserve precise walls and the
        // measured closing basis while a metadata-only name edit is saved.
        let mainButton = outlineButtons.matching(NSPredicate(format: "label CONTAINS %@", "Main L")).firstMatch
        scrollTo(mainButton); mainButton.tap()
        XCTAssertTrue(app.navigationBars["Edit floor outline"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.staticTexts["measurements.wallCount"].label, "6 walls entered")
        XCTAssertFalse(element("measurements.calculatedClosingWarning").exists, app.debugDescription)
        let name = app.textFields["measurements.outlineName"]
        scrollMeasurementFormTo(name); name.tap(); replace(name, with: "Main L verified")
        dismissMeasurementKeyboard()
        saveMeasuredOutline()
        assertFinishedOutlineArea("15.00")

        let export = app.buttons["measurements.export"]
        scrollTo(export); export.tap()
        XCTAssertTrue(app.navigationBars["Export room plan"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.buttons["measurements.sharePDF"].exists,
                      "The actual polygon drawing and worksheet must produce a downloadable PDF")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Drawn from entered measurements")).firstMatch.exists)
        attach("irregular-outline-plan-and-pdf-export")
        app.navigationBars["Export room plan"].buttons["Done"].tap()

        let threeD = app.buttons["measurements.view3D"]
        scrollTo(threeD); threeD.tap()
        XCTAssertTrue(app.navigationBars["3D measurement layout"].waitForExistence(timeout: 15), app.debugDescription)
        attach("irregular-outline-polygon-layout-3d")
        app.navigationBars["3D measurement layout"].buttons["Done"].tap()

        app.navigationBars["Measurements"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Floor plan"].waitForExistence(timeout: 10), app.debugDescription)
        scrollTo(measurements)
        XCTAssertTrue(measurements.label.contains("2 outlines"), measurements.label)
        measurements.tap()
        XCTAssertTrue(app.navigationBars["Measurements"].waitForExistence(timeout: 10), app.debugDescription)
        assertFinishedOutlineArea("15.00")
        XCTAssertEqual(outlineButtons.count, 2, "Both outlines survive reopening the saved listing")
        attach("irregular-outline-plan-reopened")

        let renamedMain = outlineButtons.matching(NSPredicate(format: "label CONTAINS %@", "Main L verified")).firstMatch
        scrollTo(renamedMain); renamedMain.tap()
        XCTAssertTrue(app.navigationBars["Edit floor outline"].waitForExistence(timeout: 10), app.debugDescription)
        let delete = app.buttons["measurements.deleteOutline"]
        scrollMeasurementFormTo(delete); delete.tap()
        let confirm = app.buttons["Delete outline and linked openings"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Delete Main L verified and its 1 linked opening?"].exists,
                      "The parent-deletion confirmation must explicitly name its linked opening")
        confirm.tap()
        XCTAssertTrue(app.navigationBars["Measurements"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(outlineButtons.count, 0)
        XCTAssertFalse(app.buttons["measurements.export"].exists, "An empty plan cannot export stale geometry")
        app.navigationBars["Measurements"].buttons.element(boundBy: 0).tap()
        scrollTo(measurements)
        XCTAssertEqual(measurements.label, "Enter measurements")
        measurements.tap()
        XCTAssertTrue(app.navigationBars["Measurements"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(outlineButtons.count, 0, "Deleting the final outline and linked opening must not resurrect raw cloud geometry")
        XCTAssertFalse(app.buttons["measurements.export"].exists)
        attach("irregular-outline-and-linked-opening-cleared")
    }

    private func beginMeasuredOutline(_ name: String) {
        let add = app.buttons["measurements.addOutline"]
        scrollTo(add); add.tap()
        XCTAssertTrue(app.navigationBars["Draw a floor outline"].waitForExistence(timeout: 10), app.debugDescription)
        let field = app.textFields["measurements.outlineName"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.tap(); field.typeText(name)
        dismissMeasurementKeyboard()
    }

    private func addOutlineWall(length: String, direction: String, expectedCount: Int) {
        let field = app.textFields["measurements.wallLength"]
        scrollMeasurementFormTo(field); field.tap(); field.typeText(length)
        dismissMeasurementKeyboard()
        chooseOutlineMenu("measurements.wallDirection", label: direction)
        let add = app.buttons["measurements.addWall"]
        scrollMeasurementFormTo(add); add.tap()
        let count = app.staticTexts["measurements.wallCount"]
        let expected = "\(expectedCount) wall\(expectedCount == 1 ? "" : "s") entered"
        let updated = NSPredicate { _, _ in count.exists && count.label == expected }
        expectation(for: updated, evaluatedWith: app); waitForExpectations(timeout: 5)
        XCTAssertFalse(element("measurements.outlineError").exists, app.debugDescription)
    }

    private func chooseOutlineMenu(_ id: String, label: String) {
        let picker = app.buttons[id]
        scrollMeasurementFormTo(picker); picker.tap()
        let option = app.buttons[label].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
        option.tap()
    }

    private func reviewOutlineClosingWall() {
        let close = app.buttons["measurements.closeOutline"]
        scrollMeasurementFormTo(close)
        XCTAssertTrue(close.isEnabled, app.debugDescription); close.tap()
        XCTAssertFalse(element("measurements.outlineError").exists, app.debugDescription)
        let save = app.buttons["measurements.saveOutline"]
        let ready = NSPredicate { _, _ in save.exists && save.isEnabled }
        expectation(for: ready, evaluatedWith: app); waitForExpectations(timeout: 5)
    }

    private func saveMeasuredOutline() {
        let save = app.buttons["measurements.saveOutline"]
        let ready = NSPredicate { _, _ in save.exists && save.isEnabled }
        expectation(for: ready, evaluatedWith: app); waitForExpectations(timeout: 5)
        save.tap()
        XCTAssertTrue(app.navigationBars["Measurements"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(element("measurements.outlineError").exists, app.debugDescription)
    }

    private func assertFinishedOutlineArea(_ value: String) {
        let total = app.staticTexts.matching(NSPredicate(format: "label == %@", "Finished outline area: \(value) m²")).firstMatch
        scrollTo(total)
        XCTAssertTrue(total.exists, app.debugDescription)
    }

    private func dismissMeasurementKeyboard() {
        guard app.keyboards.firstMatch.exists else { return }
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), app.debugDescription); done.tap()
        let hidden = NSPredicate { _, _ in !self.app.keyboards.firstMatch.exists }
        expectation(for: hidden, evaluatedWith: app); waitForExpectations(timeout: 5)
    }

    private func replaceTrailingMeasurementField(_ field: XCUIElement, with value: String) {
        // A center tap on these right-aligned fields puts the caret before the
        // digits. The old generic helper then inserted instead of replacing.
        // Tap the trailing text edge to select an end caret before deletion.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.999, dy: 0.5)).tap()
        replace(field, with: value)
        XCTAssertEqual(field.value as? String, value,
                       "Position entry must contain exactly the requested synthetic coordinate: \(app.debugDescription)")
    }

    private func scrollMeasurementFormTo(_ control: XCUIElement) {
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        guard let form = app.collectionViews.allElementsBoundByIndex.reversed().first(where: {
            $0.frame.width >= app.frame.width - 8 && $0.isHittable
        }) else { XCTFail("No frontmost measurement form: \(app.debugDescription)"); return }
        let navigation = app.navigationBars.allElementsBoundByIndex.reversed().first { $0.isHittable }
        var rewinds = 0
        for _ in 0..<18 {
            let top = max(form.frame.minY, navigation?.frame.maxY ?? form.frame.minY) + 8
            var bottom = min(form.frame.maxY, app.frame.maxY) - 28
            if app.keyboards.firstMatch.exists { bottom = min(bottom, app.keyboards.firstMatch.frame.minY - 8) }
            let height = max(0, bottom - top)
            XCTAssertGreaterThan(height, 80, app.debugDescription)
            let origin = form.coordinate(withNormalizedOffset: CGVector(dx: 0.025, dy: 0))
            let upper = origin.withOffset(CGVector(dx: 0, dy: top - form.frame.minY + height * 0.2))
            let lower = origin.withOffset(CGVector(dx: 0, dy: top - form.frame.minY + height * 0.8))
            guard control.exists else {
                if rewinds < 4 { upper.press(forDuration: 0.01, thenDragTo: lower); rewinds += 1 }
                else { lower.press(forDuration: 0.01, thenDragTo: upper) }
                continue
            }
            if control.frame.height > 0, control.frame.minY >= top, control.frame.maxY <= bottom, control.isHittable { return }
            if control.frame.minY < top { upper.press(forDuration: 0.01, thenDragTo: lower) }
            else { lower.press(forDuration: 0.01, thenDragTo: upper) }
        }
        XCTFail("Measurement control did not enter the form viewport: \(control.debugDescription)\n\(app.debugDescription)")
    }

    private func addMeasuredRoom(_ name: String, length: String, width: String) {
        let add = app.buttons["measurements.addRoom"]
        scrollTo(add); add.tap()
        XCTAssertTrue(app.navigationBars["Add room"].waitForExistence(timeout: 10), app.debugDescription)
        let field = app.textFields["measurements.roomName"]
        field.tap(); field.typeText(name)
        app.textFields["measurements.length"].tap(); app.textFields["measurements.length"].typeText(length)
        app.textFields["measurements.width"].tap(); app.textFields["measurements.width"].typeText(width)
        app.buttons["measurements.saveRoom"].tap()
        XCTAssertTrue(app.navigationBars["Measurements"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.staticTexts["measurements.formError"].exists, app.debugDescription)
    }

    private func applyThreeFixturePhotosAndWait(for title: String) {
        let apply = app.buttons["studio.batchApply"]
        scrollTo(apply)
        XCTAssertEqual(apply.label, "Apply to 3 photos")
        apply.tap()
        let completed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", title, "3 photos changed")).firstMatch
        XCTAssertTrue(completed.waitForExistence(timeout: 40), app.debugDescription)
        XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
    }

    private func assertCompareContains(_ phrase: String) {
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", phrase)).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
    }

    private func assertSelectedExportForCompareButton(_ label: String, original: Bool) {
        let download = app.buttons[label]
        XCTAssertTrue(download.waitForExistence(timeout: 10) && download.isHittable, app.debugDescription)
        download.tap()
        XCTAssertTrue(app.navigationBars["Export photos"].waitForExistence(timeout: 10), app.debugDescription)
        let selectedVersion = original ? "Earlier source files" : "Selected saved edits"
        let selected = app.staticTexts[selectedVersion]
        XCTAssertTrue(selected.exists, "Export starts with the version currently viewed: \(app.debugDescription)")
        let footer = original
            ? "Older files have no complete edit history. These earlier sources may already contain AI edits; verify them before publishing."
            : "Full available resolution is kept. AI output resolution may be lower than your capture. Stored photos and originals are never changed."
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", footer)).firstMatch.exists, app.debugDescription)
        // Opening the native sheet checks initial selection only. Never invoke
        // share, photo-library permission, a save, an upload or a paid provider.
        app.navigationBars["Export photos"].buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10), app.debugDescription)
    }

    private var baseArguments: [String] {
        ["-uiTesting", "-hasOnboarded", "YES", "-space.type", "real_estate", "-appearance", "light",
         "-ai.thirdPartyProcessing.consent.v3", "YES"]
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
