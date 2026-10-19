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

    func testLeadsPropertyFilterAndContactControlsFitNormalAndLargestText() {
        executionTimeAllowance = 180
        for largestText in [false, true] {
            if app.state != .notRunning { app.terminate() }
            app.launchArguments = baseArguments + ["-ui.profileFeedbackFixture", "-ui.sampleLeads",
                "-auth.supabase.userID", "b3710000-0000-4000-8000-000000000001"]
            if largestText { app.launchArguments += ["-ui.leadsFeedbackLargestText"] }
            app.launch()
            XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 25), app.debugDescription)
            app.tabBars.buttons["Leads"].tap()
            XCTAssertTrue(app.navigationBars["Leads"].waitForExistence(timeout: 10), app.debugDescription)
            let filter = element("leads.listingFilter")
            expectation(for: NSPredicate(format: "value == %@", "All listings, 3 leads"), evaluatedWith: filter)
            waitForExpectations(timeout: 10)
            let mode = largestText ? "largest-text" : "normal"
            attach("leads-\(mode)-all-properties")
            filter.tap()
            let property = app.buttons["leads.filter.unassigned"]
            XCTAssertTrue(property.waitForExistence(timeout: 5), app.debugDescription)
            let title = property.label
            property.tap()
            expectation(for: NSPredicate(format: "value == %@", "\(title), 3 leads"), evaluatedWith: filter)
            waitForExpectations(timeout: 5)
            XCTAssertEqual(app.staticTexts.matching(identifier: "leads.propertyHeading").count, 0,
                           "The selected property is already named by the filter")
            XCTAssertGreaterThanOrEqual(filter.frame.height, 44)
            XCTAssertGreaterThanOrEqual(filter.frame.minX, app.frame.minX + 15)
            XCTAssertLessThanOrEqual(filter.frame.maxX, app.frame.maxX - 15)
            let name = app.staticTexts.matching(identifier: "lead.name").firstMatch
            XCTAssertEqual(name.label, "Jordan Whitfield")
            XCTAssertLessThanOrEqual(name.frame.maxX, app.frame.maxX - 15)
            attach("leads-\(mode)-selected-property")
            var geometry = "Filter: \(filter.frame)\nName: \(name.frame)\n"
            for (id, label) in [("lead.call", "Call (555) 014-7720"), ("lead.email", "Email jordan.w@example.com")] {
                let control = element(id)
                let list = app.collectionViews.firstMatch
                XCTAssertTrue(list.waitForExistence(timeout: 5), app.debugDescription)
                for _ in 0..<10 {
                    if control.exists && control.isHittable && control.frame.minY >= app.navigationBars["Leads"].frame.maxY && control.frame.maxY < app.tabBars.firstMatch.frame.minY { break }
                    let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
                    let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
                    start.press(forDuration: 0.05, thenDragTo: end)
                }
                XCTAssertTrue(control.exists && control.isHittable, app.debugDescription)
                XCTAssertEqual(control.label, label, "Phone and email keep independent destinations")
                XCTAssertGreaterThanOrEqual(control.frame.height, 43.5)
                XCTAssertGreaterThanOrEqual(control.frame.minX, app.frame.minX + 15)
                XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.maxX - 15)
                XCTAssertLessThanOrEqual(control.frame.maxY, app.tabBars.firstMatch.frame.minY)
                geometry += "\(label): \(control.frame)\n"
                attach("leads-\(mode)-\(id)")
                // Inspect only: never open Phone/Mail, send, swipe-delete or confirm.
            }
            let attachment = XCTAttachment(string: geometry)
            attachment.name = "leads-\(mode)-geometry"; attachment.lifetime = .keepAlways; add(attachment)
        }
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
        // Monthly plans only (2026-10-09): no billing-period picker, no Yearly price.
        XCTAssertFalse(app.segmentedControls["paywall.period"].exists, "Annual plans are not sold")
        XCTAssertTrue(app.staticTexts["paywall.selection"].label.contains("Monthly"))
        XCTAssertTrue(store.allTransactions().isEmpty, "Opening and choosing plans never purchases or starts a trial")
        attach("paywall-compact-monthly-no-purchase")
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

    func testProfileFixtureRejectsAnUnexpectedSyntheticOwner() {
        app.launchArguments = baseArguments + ["-ui.profileFeedbackFixture", "-auth.supabase.userID", "b3710000-0000-4000-8000-000000000099"]
        app.launch()
        XCTAssertTrue(element("profile.fixture.failure").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.navigationBars["Profile"].exists)
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
        let listings = app.tabBars.buttons["Listings"]
        XCTAssertTrue(listings.waitForExistence(timeout: 25), app.debugDescription)
        listings.tap()
        let newHome = app.buttons["Add a home"]
        XCTAssertTrue(newHome.waitForExistence(timeout: 25) && newHome.isHittable, app.debugDescription)
        newHome.tap()
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

    func testOrdinaryGalleryWithoutAIConsentShowsPhotosAndDeclinedEditKeepsThem() {
        var arguments = baseArguments
        let consent = arguments.firstIndex(of: "-ai.thirdPartyProcessing.consent.v3")!
        arguments[consent + 1] = "NO"
        app.launchArguments = arguments + ["-ui.detailMetadataFixture", "rich"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Detail fixture rich"].waitForExistence(timeout: 30), app.debugDescription)
        openDetail("detail.photos", title: "Photos")
        let cards = app.buttons.matching(NSPredicate(format: "label == %@", "Photo — opens before-and-after compare"))
        let ready = NSPredicate { _, _ in cards.count == 3 }
        expectation(for: ready, evaluatedWith: app); waitForExpectations(timeout: 10)
        XCTAssertFalse(element("aiConsent.root").exists, "Viewing ordinary photos does not require third-party AI consent")
        XCTAssertTrue(app.buttons["Add photos"].exists)
        attach("ordinary-photos-without-ai-consent")
        let edit = app.buttons.matching(NSPredicate(format: "label == %@", "Change this photo with AI")).firstMatch
        scrollTo(edit); edit.tap()
        let declutter = app.buttons["Declutter"].firstMatch
        XCTAssertTrue(declutter.waitForExistence(timeout: 5), app.debugDescription); declutter.tap()
        XCTAssertTrue(element("aiConsent.root").waitForExistence(timeout: 10), "The actual AI action asks before processing")
        let decline = app.buttons["aiConsent.decline"]
        scrollTo(decline); decline.tap()
        let ended = NSPredicate { _, _ in !self.element("aiConsent.root").exists }
        expectation(for: ended, evaluatedWith: app); waitForExpectations(timeout: 5)
        XCTAssertTrue(app.navigationBars["Photos"].exists)
        XCTAssertEqual(cards.count, 3, "Declining an AI edit keeps every seeded photo in the ordinary library")
        attach("declined-ai-edit-keeps-gallery")
    }

    func testEmptyReelAddPhotosReturnsToSameSetupWithoutGenerating() {
        app.launchArguments = baseArguments + ["-ui.detailMetadataFixture", "empty"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Detail fixture empty"].waitForExistence(timeout: 30), app.debugDescription)
        openDetail("detail.reelStudio", title: "Make a video", videoPurpose: "listing")
        let add = app.buttons["reel.addPhotos"]
        scrollTo(add); XCTAssertTrue(add.isEnabled)
        let wide = app.staticTexts["Landscape · 16:9 · 1920 × 1080"]
        scrollTo(wide); XCTAssertTrue(wide.exists)
        scrollTo(add); add.tap()
        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "photos.version.")).firstMatch.exists,
                       "The explicit empty source is preserved; no fixture imports a photo or opens the system picker")
        attach("empty-reel-add-photos-library")
        let done = app.navigationBars["Photos"].buttons["Done"]
        XCTAssertTrue(done.isHittable); done.tap()
        XCTAssertTrue(app.navigationBars["Make a video"].waitForExistence(timeout: 10), app.debugDescription)
        scrollTo(wide); XCTAssertTrue(wide.exists, "Returning from Photos preserves the user's listing video format")
        scrollTo(add); XCTAssertTrue(add.isEnabled)
        XCTAssertTrue(app.staticTexts["Add photos to this listing, then return to pick them for your reel."].exists)
        XCTAssertFalse(app.staticTexts["Your reel is ready"].exists, "The recovery path never automatically generates a video")
        attach("empty-reel-same-setup-after-photos")
    }

    func testPhotoQuotaInsideReelModalPresentsAndDismissesLocalPaywall() {
        app.launchArguments = baseArguments + ["-ui.detailMetadataFixture", "empty", "-ui.photoQuotaFixture"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Detail fixture empty"].waitForExistence(timeout: 30), app.debugDescription)
        openDetail("detail.reelStudio", title: "Make a video")
        let add = app.buttons["reel.addPhotos"]
        scrollTo(add); add.tap()
        let upgrade = app.alerts.buttons["Upgrade plan"]
        XCTAssertTrue(upgrade.waitForExistence(timeout: 10), "The actual PhotoStudio quota alert must appear inside its Photos sheet")
        attach("photo-quota-inside-reel-modal")
        upgrade.tap()
        XCTAssertTrue(element("paywall.root").waitForExistence(timeout: 15), "The visible feature modal must own the upgrade presentation")
        XCTAssertTrue(app.staticTexts["You've used all your photo edits this month. Pick a plan to keep going."].exists)
        attach("quota-local-paywall-presented")
        // No product selection, subscription confirmation or purchase. This
        // case accepts the useful missing-products UI as well as local products.
        // Nested sheets retain their underlying toolbar elements in the
        // accessibility tree. Select the visible paywall control explicitly.
        let closeButtons = app.buttons.matching(identifier: "Close").allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertEqual(closeButtons.count, 1, app.debugDescription)
        guard let close = closeButtons.first else { return }
        close.tap()
        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 10), app.debugDescription)
        let hidden = NSPredicate { _, _ in !self.element("paywall.root").exists }
        expectation(for: hidden, evaluatedWith: app); waitForExpectations(timeout: 5)
        app.navigationBars["Photos"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Make a video"].waitForExistence(timeout: 10), app.debugDescription)
        scrollTo(add); XCTAssertTrue(add.isEnabled, "Closing the paywall preserves the original reel setup")
        attach("quota-paywall-dismissed-to-same-reel")
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

    func testCustomPhotoClarifiesPreservesRequestAndReviewsSafeInstruction() {
        launchDetail() // Existing synthetic photos and closed MockAPIClient only.
        openDetail("detail.photoStudio", title: "AI Photo Studio")
        let custom = app.buttons["studio.edit.custom"]
        scrollTo(custom); custom.tap()
        let apply = app.buttons["studio.batchApply"]
        scrollTo(apply); XCTAssertTrue(apply.isEnabled); apply.tap()
        XCTAssertTrue(app.navigationBars["Custom AI edit"].waitForExistence(timeout: 10), app.debugDescription)
        let request = element("customPhoto.request")
        XCTAssertTrue(request.waitForExistence(timeout: 5))
        request.tap(); request.typeText("make it nicer")
        let review = app.buttons["customPhoto.reviewEdit"]
        scrollTo(review); review.tap()
        let lighting = app.buttons["customPhoto.choice.lighting"]
        scrollTo(lighting)
        XCTAssertTrue(lighting.isEnabled, app.debugDescription)
        XCTAssertEqual(request.value as? String, "make it nicer", "Clarification must not discard the user's original request")
        XCTAssertFalse(app.buttons["customPhoto.generatePreview"].exists, "A vague request cannot directly generate")
        lighting.tap()
        let prepared = app.staticTexts["customPhoto.preparedInstruction"]
        XCTAssertTrue(prepared.waitForExistence(timeout: 5))
        XCTAssertEqual(prepared.label, "Improve brightness and exposure only, preserving every paint color and material.")
        XCTAssertEqual(request.value as? String, "make it nicer", "The chosen explicit instruction is reviewed separately from original text")
        XCTAssertTrue(app.buttons["customPhoto.generatePreview"].exists)
        attach("custom-photo-explicit-lighting-instruction")
        scrollTo(request)
        request.coordinate(withNormalizedOffset: CGVector(dx: 0.999, dy: 0.5)).tap()
        replace(request, with: "repaint the garage white")
        XCTAssertFalse(app.buttons["customPhoto.generatePreview"].exists, "Changing the request invalidates the earlier prepared review")
        scrollTo(review); review.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "we can't repaint or remodel")).firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(request.value as? String, "repaint the garage white", "A refused permanent change is explained without silently changing the request")
        XCTAssertFalse(app.buttons["customPhoto.generatePreview"].exists)
        attach("custom-photo-garage-paint-refusal")
        scrollTo(request)
        request.coordinate(withNormalizedOffset: CGVector(dx: 0.999, dy: 0.5)).tap()
        let safe = "Improve brightness only; keep garage door and trim colors."
        replace(request, with: safe)
        scrollTo(review); review.tap()
        XCTAssertTrue(prepared.waitForExistence(timeout: 5))
        XCTAssertEqual(prepared.label, safe, "The explicit safe instruction must be exactly what the user reviews")
        XCTAssertTrue(app.buttons["customPhoto.generatePreview"].exists)
        attach("custom-photo-safe-request-reviewed-before-generation")
        // Deliberately stop before Generate: no image request, paid model,
        // camera, export or real transaction is exercised by this acceptance.
        app.navigationBars["Custom AI edit"].buttons["Cancel"].tap()
    }

    /// Exact mounted first-run cards on the existing offline Simulator route.
    /// Capture only: three Continue taps; never Get started, account, plans or AI.
    func testPhotoFirstOnboardingCardsAreVisibleBeforeGetStarted() {
        executionTimeAllowance = 120
        app.launchArguments = ["-uiTesting", "-ui.onboardingReset", "-space.type", "real_estate", "-appearance", "light"]
        app.launch()
        let cards: [(title: String, body: String)] = [
            ("Start with your home.\nAdd the details.",
             "Enter the address and property details. Your photos, video, website and leads stay grouped with that home."),
            ("Landscape photos.\nOptional AI edits.",
             "Add landscape photos and keep the camera level. Use 0.5× when needed and available. Keep your Originals and review optional AI edits."),
            ("Make a Listing video.\nReview the result.",
             "Choose landscape Listing or portrait Social media. Your selected order is kept, with automatic camera motion. Voice and music are optional."),
            ("Your website.\nShare and follow up.",
             "Choose your gallery and cover, check video and contact details, then publish. Share the link and follow up in Leads. Recorded walkthroughs are optional.")
        ]
        for (index, card) in cards.enumerated() {
            let title = app.staticTexts.matching(NSPredicate(format: "label == %@", card.title)).firstMatch
            let body = app.staticTexts.matching(NSPredicate(format: "label == %@", card.body)).firstMatch
            let next = app.buttons[index < 3 ? "Continue" : "Get started"]
            XCTAssertTrue(title.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(body.exists && next.exists, app.debugDescription)
            let visible = NSPredicate { _, _ in title.isHittable && body.isHittable && next.isHittable }
            expectation(for: visible, evaluatedWith: app); waitForExpectations(timeout: 10)
            for text in [title, body] {
                XCTAssertGreaterThan(text.frame.width, 0, text.label)
                XCTAssertGreaterThan(text.frame.height, 0, text.label)
                XCTAssertGreaterThanOrEqual(text.frame.minX, app.frame.minX - 1, text.label)
                XCTAssertLessThanOrEqual(text.frame.maxX, app.frame.maxX + 1, text.label)
                XCTAssertGreaterThanOrEqual(text.frame.minY, app.frame.minY - 1, text.label)
                XCTAssertLessThanOrEqual(text.frame.maxY, app.frame.maxY + 1, text.label)
            }
            XCTAssertLessThanOrEqual(title.frame.maxY, body.frame.minY + 1, "Card title and full explanation cannot overlap")
            XCTAssertLessThanOrEqual(body.frame.maxY, next.frame.minY + 1, "The full explanation stays above the action")
            XCTAssertGreaterThanOrEqual(next.frame.width, 44)
            XCTAssertGreaterThanOrEqual(next.frame.height, 44)
            XCTAssertGreaterThanOrEqual(next.frame.minY, app.frame.minY - 1)
            XCTAssertLessThanOrEqual(next.frame.maxY, app.frame.maxY + 1)
            attach("photo-first-onboarding-card-\(index + 1)")
            if index < 3 { next.tap() }
        }
        XCTAssertTrue(app.buttons["Get started"].isHittable)
        XCTAssertFalse(app.buttons["onboarding.explore"].exists, "Capture stops before the business picker")
    }

    /// Actual user navigation on the existing offline rich fixture. No import,
    /// camera, AI action, publication, export or Photos permission is invoked.
    func testLargestTextPhotoGridReviewEditCompareAndPagerAreReachable() {
        executionTimeAllowance = 180
        app.launchArguments = baseArguments + ["-ui.detailMetadataFixture", "rich",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Detail fixture rich"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(element("detail.fixtureFailure").exists)
        let photos = app.buttons["detail.photos"]
        revealForBoundedAcceptance(photos); photos.tap()
        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 15), app.debugDescription)
        let addPhotos = app.buttons["Add photos"], take = app.buttons["photos.takePhoto"]
        XCTAssertTrue(addPhotos.waitForExistence(timeout: 10) && take.exists, app.debugDescription)
        XCTAssertTrue(addPhotos.isHittable && take.isHittable, "Both import controls must be reachable without opening them")
        XCTAssertGreaterThanOrEqual(addPhotos.frame.height, 44)
        XCTAssertGreaterThanOrEqual(take.frame.height, 44)
        XCTAssertGreaterThanOrEqual(take.frame.minY, addPhotos.frame.maxY - 1, "Largest text stacks Add and Take without shrinking the labels")
        XCTAssertEqual(addPhotos.label, "Add photos"); XCTAssertEqual(take.label, "Take a photo")
        let before = take.frame
        attach("largest-text-photos-before-scroll")
        acceptancePageDrag(up: true)
        expectation(for: NSPredicate { _, _ in take.frame.minY < before.minY - 2 }, evaluatedWith: take)
        waitForExpectations(timeout: 5)
        attach("largest-text-photos-after-scroll")
        let movement = XCTAttachment(string: "Take before: \(before)\nTake after: \(take.frame)\nApp: \(app.frame)")
        movement.name = "largest-text-photo-scroll-geometry"; movement.lifetime = .keepAlways; add(movement)
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "photos.version.")).firstMatch
        revealForBoundedAcceptance(photo); photo.tap()
        let save = photoReviewFooterButton(download: true)
        XCTAssertTrue(save.waitForExistence(timeout: 10), app.debugDescription)
        assertAcceptanceFooterIsVisible()
        let title = app.staticTexts["photoVersion.headerTitle"]
        let history = app.buttons["photoVersion.history"]
        let close = app.buttons["Close"]
        XCTAssertTrue(title.waitForExistence(timeout: 5) && history.exists && close.exists, app.debugDescription)
        let headerGeometry = XCTAttachment(string: "Title: \(title.frame)\nHistory: \(history.frame)\nClose: \(close.frame)\nApp: \(app.frame)")
        headerGeometry.name = "largest-text-review-header-geometry"; headerGeometry.lifetime = .keepAlways; add(headerGeometry)
        attach("largest-text-review-full-width-header")
        XCTAssertEqual(title.label, "Photo versions"); XCTAssertEqual(history.label, "All edits")
        XCTAssertTrue(title.isHittable && history.isHittable && close.isHittable,
                      "The full title, saved-edit menu and Close must be visible together at largest text")
        XCTAssertGreaterThanOrEqual(title.frame.minX, app.frame.minX)
        XCTAssertEqual(title.frame.minX, history.frame.minX, accuracy: 1, "Title and history share the full row’s leading edge")
        XCTAssertGreaterThan(title.frame.width, 0); XCTAssertGreaterThan(title.frame.height, 0)
        XCTAssertGreaterThanOrEqual(title.frame.minY, app.frame.minY)
        XCTAssertLessThanOrEqual(title.frame.maxX, app.frame.maxX)
        XCTAssertLessThanOrEqual(title.frame.maxY, min(history.frame.minY, close.frame.minY) + 1,
                                 "Largest-text actions must sit below the title without overlap")
        XCTAssertLessThanOrEqual(history.frame.maxX, close.frame.minX + 1,
                                 "All edits must not overlap Close")
        XCTAssertGreaterThanOrEqual(history.frame.height, 44)
        XCTAssertTrue(element("photoVersion.savedChoices").exists)
        assertPhotoReviewChoicesAndToolsFitViewport("largest-text-polished-review")
        let position = app.staticTexts["photoVersion.position"]
        XCTAssertEqual(position.label, "Photo 1 of 3")
        let edit = app.buttons["photoVersion.editOriginal"]
        revealForBoundedAcceptance(edit)
        XCTAssertTrue(edit.isEnabled); attach("largest-text-review-edit-and-footer")
        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit original photo"].waitForExistence(timeout: 10), app.debugDescription)
        let declutter = app.buttons["photoVersion.edit.declutter"]
        revealForBoundedAcceptance(declutter)
        XCTAssertTrue(declutter.isEnabled)
        XCTAssertTrue(app.buttons["photoVersion.edit.stage"].exists)
        attach("largest-text-single-photo-actions-no-selection")
        // Opening this sheet is safe. Selecting an AI action is deliberately
        // outside this test, including when the transport is a mock.
        app.navigationBars["Edit original photo"].buttons["Cancel"].tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        let compare = app.buttons["photoVersion.fullSize"]
        revealForBoundedAcceptance(compare); XCTAssertTrue(compare.isEnabled); compare.tap()
        let done = app.buttons["photoComparison.close"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(element("photoComparison.image").exists)
        attach("largest-text-full-size-comparison")
        done.tap()
        let next = app.buttons["photoVersion.nextPhoto"], previous = app.buttons["photoVersion.previousPhoto"]
        revealForBoundedAcceptance(next)
        XCTAssertTrue(next.isEnabled); XCTAssertFalse(previous.isEnabled)
        next.tap()
        expectation(for: NSPredicate(format: "label == %@", "Photo 2 of 3"), evaluatedWith: position)
        waitForExpectations(timeout: 10)
        attach("largest-text-second-family")
        XCTAssertTrue(previous.isEnabled); previous.tap()
        expectation(for: NSPredicate(format: "label == %@", "Photo 1 of 3"), evaluatedWith: position)
        waitForExpectations(timeout: 10)
        assertAcceptanceFooterIsVisible()
        attach("largest-text-first-family-restored")
        app.buttons["Close"].tap()
    }

    /// The existing two-home host mounts the production HomeDashboardView.
    /// Inspect its current copy without creating, selecting or changing a home.
    func testMountedHomeExplainsPhotoFirstWorkflow() {
        executionTimeAllowance = 180
        app.launchArguments = baseArguments + ["-ui.homeProjectCreationFixture", "two-homes", "-ui.currentLocationFixture"]
        app.launch()
        XCTAssertTrue(app.buttons["home.getStarted"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(app.staticTexts["home.fixture.projectCount"].label, "2 synthetic homes")
        let steps = [
            ("Add home", "Enter the address and property details.", "add-home"),
            ("Create from photos", "Upload landscape photos, review any optional AI edits, then make a Listing video.", "create-from-photos"),
            ("Publish and share", "Choose your gallery and cover, check the video and contact details, then publish your website. Share its link and follow up in Leads.", "publish-and-share")
        ]
        revealForBoundedAcceptance(app.staticTexts["How it works"])
        for (title, detail, name) in steps {
            XCTAssertTrue(app.staticTexts[title].exists, title)
            revealForBoundedAcceptance(app.staticTexts.matching(NSPredicate(format: "label == %@", detail)).firstMatch)
            attach("home-photo-first-" + name)
        }
        let optional = "Optional: record a slow, steady walkthrough with a gimbal if available, or upload a walkthrough or drone clip."
        revealForBoundedAcceptance(app.staticTexts.matching(NSPredicate(format: "label == %@", optional)).firstMatch)
        attach("home-photo-first-optional-recording")
        XCTAssertFalse(app.staticTexts["Film it"].exists)
        XCTAssertFalse(app.staticTexts["Walk it at a steady, normal pace on the 0.5× wide lens — or upload a clip."].exists)
        XCTAssertEqual(app.staticTexts["home.fixture.projectCount"].label, "2 synthetic homes")
    }

    /// Compiled here for future UI acceptance; no provider or Photos writes.
    /// The fixed actions must remain reachable while scrolling larger text.
    func testPhotoReviewFixedActionsAcrossAppearanceAndAccessibilityText() {
        for appearance in ["light", "dark"] {
            if app.state != .notRunning { app.terminate() }
            app.launchArguments = baseArguments + ["-ui.detailMetadataFixture", "rich",
                "-appearance", appearance, "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            app.launch()
            XCTAssertTrue(app.navigationBars["Detail fixture rich"].waitForExistence(timeout: 30), app.debugDescription)
            openDetail("detail.photos", title: "Photos")
            let photo = app.buttons.matching(NSPredicate(format: "label == %@", "Photo — opens before-and-after compare")).firstMatch
            scrollTo(photo); photo.tap()
            let preview = element("photoVersion.preview")
            let save = photoReviewFooterButton(download: true)
            XCTAssertTrue(save.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(save.isHittable && save.frame.maxY <= app.frame.maxY, "Save stays inside the bottom safe area")
            XCTAssertTrue(element("photoVersion.savedChoices").exists)
            XCTAssertTrue(app.buttons["photoVersion.fullSize"].exists)
            if preview.exists {
                XCTAssertGreaterThan(preview.frame.height, 0)
                XCTAssertLessThanOrEqual(preview.frame.height, min(560, app.frame.height))
            }
            acceptancePageDrag(up: true)
            XCTAssertTrue(save.isHittable, "Scrolling review content cannot hide Save")
            attach("photo-review-fixed-actions-\(appearance)-large-text")
            app.buttons["Close"].tap()
        }
    }

    func testCustomPhotoDownloadReviewDoesNotPublishAndPersists() {
        launchDetail() // Procedural images and simulator-only MockAPIClient.
        openDetail("detail.photoStudio", title: "AI Photo Studio")
        let custom = app.buttons["studio.edit.custom"]
        scrollTo(custom); custom.tap()
        let apply = app.buttons["studio.batchApply"]
        scrollTo(apply); XCTAssertTrue(apply.isEnabled); apply.tap()
        XCTAssertTrue(app.navigationBars["Custom AI edit"].waitForExistence(timeout: 10), app.debugDescription)
        let request = element("customPhoto.request")
        request.tap(); request.typeText("Improve brightness only; keep all paint colors and materials.")
        let review = app.buttons["customPhoto.reviewEdit"]
        scrollTo(review); review.tap()
        let generate = app.buttons["customPhoto.generatePreview"]
        scrollTo(generate); XCTAssertTrue(generate.isEnabled); generate.tap()
        let finished = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Ask for anything", "3 photos changed")).firstMatch
        XCTAssertTrue(finished.waitForExistence(timeout: 40), app.debugDescription)
        app.navigationBars["AI Photo Studio"].buttons.element(boundBy: 0).tap()
        openDetail("detail.photos", title: "Photos")
        let cards = app.buttons.matching(NSPredicate(format: "label == %@", "Photo — opens before-and-after compare"))
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(cards.matching(NSPredicate(format: "value == %@", "Selected for listing")).count, 0,
                       "New custom previews cannot replace the published gallery")
        scrollTo(cards.firstMatch); cards.firstMatch.tap()
        let download = photoReviewFooterButton(download: true)
        let use = photoReviewFooterButton(download: false)
        XCTAssertTrue(download.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(download.isEnabled, "Edited custom downloads require exact comparison")
        XCTAssertFalse(use.isEnabled, "The same new custom remains unpublishable")
        let choices = element("photoVersion.savedChoices")
        choices.buttons["Earlier source"].tap()
        assertSelectedExportForCompareButton("Download earlier source", original: true)
        choices.buttons["Enhanced"].tap()
        XCTAssertFalse(download.isEnabled, "Opening the retained source alone does not approve the edit")
        for label in ["Structure and fixed features match the source",
                      "Paint colors, garage door, trim and materials match",
                      "Only the change I requested was made"] {
            let control = app.buttons[label]
            scrollTo(control)
            XCTAssertTrue(control.exists && control.isHittable, app.debugDescription)
            control.tap(); XCTAssertEqual(control.value as? String, "Confirmed")
        }
        XCTAssertTrue(download.isEnabled, "Complete exact comparison allows downloading")
        download.tap()
        XCTAssertTrue(app.navigationBars["Export photos"].waitForExistence(timeout: 10), app.debugDescription)
        app.navigationBars["Export photos"].buttons["Done"].tap()
        XCTAssertEqual(use.label, "Use this version on listing", "Download approval must never publish or change the cover")
        attach("custom-photo-download-reviewed-without-publication")
        app.buttons["Close"].tap()
        XCTAssertEqual(cards.matching(NSPredicate(format: "value == %@", "Selected for listing")).count, 0)
        scrollTo(cards.firstMatch); cards.firstMatch.tap()
        XCTAssertTrue(download.waitForExistence(timeout: 10)); XCTAssertTrue(download.isEnabled,
                      "Review of the exact saved custom output persists after closing comparison")
        XCTAssertFalse(app.otherElements["photoVersion.customReview"].exists)
        XCTAssertEqual(use.label, "Use this version on listing")
        // Only the offline mock output and native sheet are exercised. No real
        // model, permission, Photos write, transaction or camera is requested.
        app.buttons["Close"].tap()
    }

    /// Legacy files remain usable without being certified as Originals or AI inputs.
    func testLegacyPhotosStayUnverifiedAndRequireOriginalBeforeEditing() {
        executionTimeAllowance = 180
        launchLegacyPhotoDetail()
        openDetail("detail.photos", title: "Photos")
        let library = app.scrollViews["photos.savedVersions"]
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "photos.version."))
        XCTAssertTrue(library.buttons["Original"].isSelected)
        XCTAssertEqual(cards.count, 0, "A legacy filename must not create a verified Original")
        library.buttons["Latest"].tap()
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(cards.matching(NSPredicate(format: "value == %@", "Selected for listing")).count, 3,
                       "All legacy siblings remain selected before the first indexed mutation")
        scrollTo(cards.firstMatch); cards.firstMatch.press(forDuration: 1)
        let remove = app.buttons.matching(NSPredicate(format: "label == %@", "Remove from gallery")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5)); remove.tap()
        XCTAssertTrue(remove.waitForExistence(timeout: 5)); remove.tap()
        expectation(for: NSPredicate { _, _ in cards.count == 2 }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(cards.matching(NSPredicate(format: "value == %@", "Selected for listing")).count, 2,
                       "Hiding one family cannot erase its selected siblings")
        let cardID = cards.firstMatch.identifier
        let versionID = String(cardID.dropFirst("photos.version.".count))
        let card = app.buttons[cardID], cover = app.buttons["photos.cover.\(versionID)"]
        scrollTo(cover); cover.tap()
        XCTAssertEqual(cover.label, "This is the cover photo")
        scrollTo(card); card.tap()
        let choices = element("photoVersion.savedChoices")
        XCTAssertTrue(choices.buttons["Earlier source"].waitForExistence(timeout: 10))
        XCTAssertFalse(choices.buttons["Original"].exists, "Legacy source pixels are not certified by opening review")
        choices.buttons["Earlier source"].tap()
        assertSelectedExportForCompareButton("Download earlier source", original: true)
        choices.buttons["Enhanced"].tap()
        let edit = app.buttons["photoVersion.editOriginal"]
        revealForBoundedAcceptance(edit); edit.tap()
        let alert = app.alerts["Photo action needs attention"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(alert.staticTexts["A source photo is missing from this phone. Import it again before editing."].exists)
        XCTAssertFalse(app.navigationBars["Edit original photo"].exists)
        XCTAssertFalse(app.buttons["photoVersion.edit.stage"].exists)
        XCTAssertFalse(element("photoVersion.edit.progress").exists)
        attach("legacy-source-requires-original-import-no-AI")
        alert.buttons["OK"].tap()
        let use = photoReviewFooterButton(download: false)
        XCTAssertEqual(use.label, "Remove this photo from listing")
        use.tap()
        expectation(for: NSPredicate(format: "label == %@", "Use this version on listing"), evaluatedWith: use)
        waitForExpectations(timeout: 5)
        app.buttons["Close"].tap()
        XCTAssertEqual(cards.count, 2, "Unselecting keeps both source families and files visible")
        XCTAssertEqual(cards.matching(NSPredicate(format: "value == %@", "Selected for listing")).count, 1)
        XCTAssertNotEqual(cover.label, "This is the cover photo", "An unselected family cannot remain cover")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "This is the cover photo")).count, 1,
                       "The remaining selected sibling supplies the cover")
        scrollTo(card); card.tap()
        XCTAssertTrue(use.waitForExistence(timeout: 10)); XCTAssertEqual(use.label, "Use this version on listing")
        XCTAssertTrue(choices.buttons["Earlier source"].exists); XCTAssertFalse(choices.buttons["Original"].exists)
        use.tap()
        expectation(for: NSPredicate(format: "label == %@", "Remove this photo from listing"), evaluatedWith: use)
        waitForExpectations(timeout: 5)
        app.buttons["Close"].tap()
        XCTAssertEqual(cards.matching(NSPredicate(format: "value == %@", "Selected for listing")).count, 2)
        scrollTo(card); card.tap()
        XCTAssertTrue(use.waitForExistence(timeout: 10)); XCTAssertEqual(use.label, "Remove this photo from listing")
        XCTAssertTrue(choices.buttons["Earlier source"].exists); XCTAssertFalse(choices.buttons["Original"].exists)
        attach("legacy-selection-reopen-source-stays-unverified")
        app.buttons["Close"].tap()
    }

    /// Actual optional-feedback SwiftUI and local queue only. The existing
    /// republish host supplies a fixed synthetic actor/library and MockAPIClient;
    /// the latter has no feedback transport, so this cannot prove delivery or
    /// touch a production output, provider, purchase or customer account.
    func testOptionalPhotoFeedbackFitsNormalAndLargestTextWithoutChangingSelection() {
        executionTimeAllowance = 300
        for largestText in [false, true] {
            if app.state != .notRunning { app.terminate() }
            app.launchArguments = baseArguments + ["-ui.detailMetadataFixture", "republish", "-ui.photoFeedbackFixture"]
            if largestText {
                app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            }
            app.launch()
            XCTAssertTrue(app.navigationBars["Detail fixture republish"].waitForExistence(timeout: 30), app.debugDescription)
            XCTAssertFalse(element("detail.fixtureFailure").exists)
            openDetail("detail.photos", title: "Photos")
            let library = app.scrollViews["photos.savedVersions"]
            XCTAssertTrue(library.buttons["Original"].isSelected)
            library.buttons["Latest"].tap()
            let photo = app.buttons["photos.version.fixture-0"]
            revealForBoundedAcceptance(photo); photo.tap()
            let choices = element("photoVersion.savedChoices")
            XCTAssertTrue(choices.buttons["Staged"].waitForExistence(timeout: 10))
            XCTAssertTrue(choices.buttons["Staged"].isSelected)
            XCTAssertFalse(app.alerts["Photo action needs attention"].exists,
                           "The local feedback fixture must not enter an unmapped cloud-selection flow")
            let use = photoReviewFooterButton(download: false)
            XCTAssertTrue(use.waitForExistence(timeout: 10), app.debugDescription)
            let selectedBefore = use.label
            assertAcceptanceFooterIsVisible()
            let useful = app.buttons["photoVersion.feedback.useful"]
            let needsWork = app.buttons["photoVersion.feedback.needsWork"]
            let mode = largestText ? "largest-text" : "normal"
            for control in [useful, needsWork] {
                revealForBoundedAcceptance(control)
                XCTAssertTrue(control.isEnabled && control.isHittable)
                XCTAssertGreaterThanOrEqual(control.frame.height, 44)
                XCTAssertGreaterThanOrEqual(control.frame.minX, app.frame.minX)
                XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.maxX)
            }
            attach("photo-feedback-\(mode)-optional-control")
            revealForBoundedAcceptance(useful); useful.tap()
            let status = app.staticTexts["photoVersion.feedback.status"]
            XCTAssertTrue(status.waitForExistence(timeout: 5))
            XCTAssertTrue(status.label.hasPrefix("Saved on this phone."), status.label)
            XCTAssertTrue(useful.isSelected)
            XCTAssertEqual(use.label, selectedBefore, "Feedback never changes the listing selection")
            revealForBoundedAcceptance(needsWork); needsWork.tap()
            let save = app.buttons["photoVersion.feedback.save"]
            XCTAssertTrue(save.exists); XCTAssertFalse(save.isEnabled, "Needs work requires a reason")
            let reason = app.buttons["photoVersion.feedback.reason.changed_permanent_features"]
            revealForBoundedAcceptance(reason); reason.tap()
            XCTAssertTrue(reason.isSelected)
            let note = app.textFields["photoVersion.feedback.note"]
            revealForBoundedAcceptance(note)
            XCTAssertTrue(note.isHittable, "The optional note remains reachable")
            attach("photo-feedback-\(mode)-reasons-and-note")
            revealForBoundedAcceptance(save)
            XCTAssertTrue(save.isEnabled && save.isHittable)
            XCTAssertGreaterThanOrEqual(save.frame.height, 44)
            save.tap()
            XCTAssertTrue(needsWork.isSelected)
            XCTAssertTrue(status.label.hasPrefix("Saved on this phone."), status.label)
            XCTAssertEqual(use.label, selectedBefore)
            assertAcceptanceFooterIsVisible()
            attach("photo-feedback-\(mode)-saved-local-opinion")
            let original = choices.buttons["Original"]
            // The lazy chip may be unrealized above this long feedback form.
            // Its always-mounted strip retains negative geometry, so the same
            // eight-gesture helper correctly scrolls back toward Original.
            revealForBoundedAcceptance(choices)
            XCTAssertTrue(original.exists && original.isHittable)
            original.tap()
            XCTAssertFalse(useful.exists || needsWork.exists, "Original has no AI-output feedback")
            XCTAssertEqual(photoReviewFooterButton(download: true).label, "Download original photo")
            assertAcceptanceFooterIsVisible()
            choices.buttons["Staged"].tap()
            revealForBoundedAcceptance(needsWork)
            XCTAssertTrue(needsWork.isSelected, "Browsing Original preserves the local opinion for the exact saved output")
            XCTAssertEqual(use.label, selectedBefore)
            app.buttons["Close"].tap()
            revealForBoundedAcceptance(photo); photo.tap()
            revealForBoundedAcceptance(needsWork)
            XCTAssertTrue(needsWork.isSelected, "Reopening the same output retains its queued opinion")
            XCTAssertEqual(use.label, selectedBefore)
            attach("photo-feedback-\(mode)-reopened-same-output")
            app.buttons["Close"].tap()
        }
    }

    /// The normal rich fixture has genuine captures and an explicitly reviewed saved stage.
    /// This tests saved selection, never claims a fresh-stage approval or generation.
    func testVerifiedSavedVersionsKeepSelectionAndUnselectAcrossReopen() {
        executionTimeAllowance = 180
        launchDetail()
        openDetail("detail.photos", title: "Photos")
        let library = app.scrollViews["photos.savedVersions"]
        XCTAssertTrue(library.buttons["Original"].isSelected)
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "photos.version."))
        XCTAssertEqual(cards.count, 3)
        library.buttons["Latest"].tap()
        let stage = app.buttons["photos.version.fixture-0"]
        XCTAssertTrue(stage.exists); XCTAssertEqual(stage.value as? String, "Selected for listing")
        scrollTo(stage); stage.tap()
        let choices = element("photoVersion.savedChoices")
        XCTAssertTrue(choices.buttons["Staged"].waitForExistence(timeout: 10))
        XCTAssertTrue(choices.buttons["Staged"].isSelected)
        XCTAssertTrue(choices.buttons["Original"].exists); XCTAssertFalse(choices.buttons["Earlier source"].exists)
        assertPhotoReviewChoicesAndToolsFitViewport("normal-polished-review")
        let use = photoReviewFooterButton(download: false)
        XCTAssertTrue(use.waitForExistence(timeout: 10)); XCTAssertEqual(use.label, "Remove this photo from listing")
        XCTAssertTrue(use.isEnabled, "This saved fixture stage was already explicitly reviewed")
        use.tap()
        expectation(for: NSPredicate(format: "label == %@", "Use this version on listing"), evaluatedWith: use)
        waitForExpectations(timeout: 5)
        app.buttons["Close"].tap()
        XCTAssertTrue(stage.exists); XCTAssertNotEqual(stage.value as? String, "Selected for listing")
        scrollTo(stage); stage.tap()
        XCTAssertTrue(use.waitForExistence(timeout: 10)); XCTAssertEqual(use.label, "Use this version on listing")
        XCTAssertTrue(choices.buttons["Staged"].isSelected)
        use.tap()
        expectation(for: NSPredicate(format: "label == %@", "Remove this photo from listing"), evaluatedWith: use)
        waitForExpectations(timeout: 5)
        app.buttons["Close"].tap()
        XCTAssertEqual(stage.value as? String, "Selected for listing")
        scrollTo(stage); stage.tap()
        XCTAssertTrue(use.waitForExistence(timeout: 10)); XCTAssertEqual(use.label, "Remove this photo from listing")
        choices.buttons["Original"].tap()
        expectation(for: NSPredicate(format: "label == %@", "Use this version on listing"), evaluatedWith: use)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(choices.buttons["Original"].isSelected)
        XCTAssertEqual(photoReviewFooterButton(download: true).label, "Download original photo")
        app.buttons["Close"].tap()
        XCTAssertEqual(stage.value as? String, "Selected for listing", "Browsing Original never publishes it")
        scrollTo(stage); stage.tap()
        XCTAssertTrue(use.waitForExistence(timeout: 10)); XCTAssertEqual(use.label, "Remove this photo from listing")
        choices.buttons["Original"].tap()
        expectation(for: NSPredicate(format: "label == %@", "Use this version on listing"), evaluatedWith: use)
        waitForExpectations(timeout: 5)
        use.tap()
        expectation(for: NSPredicate(format: "label == %@", "Remove this photo from listing"), evaluatedWith: use)
        waitForExpectations(timeout: 5)
        app.buttons["Close"].tap()
        XCTAssertTrue(stage.exists); XCTAssertEqual(stage.value as? String, "Earlier version on listing")
        scrollTo(stage); stage.tap()
        XCTAssertTrue(use.waitForExistence(timeout: 10)); XCTAssertEqual(use.label, "Use this version on listing")
        choices.buttons["Original"].tap()
        expectation(for: NSPredicate(format: "label == %@", "Remove this photo from listing"), evaluatedWith: use)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(choices.buttons["Original"].isSelected && choices.buttons["Staged"].exists)
        XCTAssertEqual(photoReviewFooterButton(download: true).label, "Download original photo")
        attach("verified-saved-selection-unselect-original-and-reopen")
        app.buttons["Close"].tap()
    }

    /// Build 57: the listing page shows Measurements as a Coming soon card, the
    /// same as Home, so no user-reachable route lands on `FloorPlanView` or
    /// `FloorMeasurementsView`. The two measurement flows below are parked, not
    /// deleted: flip `measurementsToolboxLinkRestored` when the
    /// `detail.floorPlan` link returns and they resume as written.
    private static let measurementsToolboxLinkRestored = false
    private static let measurementsParked = "Measurements is Coming soon on the listing page (build 57); no UI route reaches the measurements screen."

    func testMeasurementsIsComingSoonOnTheListingPage() {
        launchDetail()
#if SPATIAL_CAPTURE_LAB
        let plans = app.buttons["detail.floorPlanLab"]
        scrollTo(plans)
        XCTAssertTrue(plans.exists && plans.isEnabled, app.debugDescription)
        XCTAssertTrue(plans.label.contains("Floor plans & measurements"), plans.label)
        XCTAssertFalse(element("detail.measurementsComingSoon").exists)
#else
        let card = element("detail.measurementsComingSoon")
        scrollTo(card)
        XCTAssertTrue(card.exists, app.debugDescription)
        XCTAssertTrue(card.label.contains("Floor plans & measurements"), card.label)
        XCTAssertTrue(card.label.contains("Coming soon"), card.label)
        XCTAssertFalse(app.buttons["detail.measurementsComingSoon"].exists, "Coming soon must not open a feature")
        XCTAssertFalse(app.buttons["detail.floorPlan"].exists, "The listing toolbox must not keep a live Measurements link")
        XCTAssertFalse(element("detail.floorPlan").exists, app.debugDescription)
        // The owner's report was "still clickable": tapping must do nothing.
        card.tap()
        attach("listing-measurements-coming-soon-tapped")
        XCTAssertFalse(app.navigationBars["Floor plans & measurements"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(app.navigationBars["Floor plan"].exists, app.debugDescription)
        XCTAssertFalse(app.navigationBars["Measurements"].exists, app.debugDescription)
        XCTAssertFalse(app.buttons["floorPlan.measurements"].exists, app.debugDescription)
        XCTAssertTrue(app.navigationBars["Detail fixture rich"].exists, "Tapping Coming soon must not navigate: \(app.debugDescription)")
        XCTAssertTrue(app.buttons["detail.photos"].waitForExistence(timeout: 10), app.debugDescription)
        // Its neighbours keep the identical contract.
        for id in ["detail.spatialComingSoon"] {
            let neighbour = element(id)
            scrollTo(neighbour)
            XCTAssertTrue(neighbour.exists && neighbour.label.contains("Coming soon"), "\(id): \(neighbour.label)")
            XCTAssertFalse(app.buttons[id].exists, "Coming soon must not open a feature: \(id)")
        }
#endif
    }

    func testManualMeasurementsCreateEditExportAndKeepScanChoice() throws {
        try XCTSkipUnless(Self.measurementsToolboxLinkRestored, Self.measurementsParked)
        launchDetail()
        openDetail("detail.floorPlan", title: "Measurements & plans")
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
        XCTAssertTrue(app.navigationBars["Measurements & plans"].waitForExistence(timeout: 10))
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

    func testIrregularOutlinesDeductAreaExportReopenAndDeleteLinkedOpenings() throws {
        try XCTSkipUnless(Self.measurementsToolboxLinkRestored, Self.measurementsParked)
        launchDetail()
        openDetail("detail.floorPlan", title: "Measurements & plans")
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
        XCTAssertTrue(app.navigationBars["Measurements & plans"].waitForExistence(timeout: 10), app.debugDescription)
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
        if title.hasPrefix("Staging") {
            XCTAssertEqual(apply.label, "Apply"); XCTAssertFalse(apply.isEnabled, "Staging requires explicit selection")
            app.buttons["Select all"].tap()
        }
        XCTAssertEqual(apply.label, "Apply to 3 photos")
        apply.tap()
        if title.hasPrefix("Staging") { confirmSyntheticStaging(count: 3) }
        let completed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", title, "3 photos changed")).firstMatch
        XCTAssertTrue(completed.waitForExistence(timeout: 40), app.debugDescription)
        XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
    }

    private func confirmSyntheticStaging(count: Int) {
        XCTAssertTrue(app.navigationBars["Stage selected photos"].waitForExistence(timeout: 10), app.debugDescription)
        let confirm = app.buttons["photoStage.apply"]
        XCTAssertTrue(confirm.exists && confirm.isEnabled, app.debugDescription)
        XCTAssertEqual(confirm.label, "Stage \(count) photo\(count == 1 ? "" : "s")")
        confirm.tap()
        XCTAssertTrue(app.navigationBars["AI Photo Studio"].waitForExistence(timeout: 10), app.debugDescription)
    }

    private func reviewSyntheticStagingForPublication() {
        let use = photoReviewFooterButton(download: false)
        XCTAssertFalse(use.isEnabled, "Unreviewed staging must remain unpublishable")
        let choices = element("photoVersion.savedChoices")
        choices.buttons["Earlier source"].tap()
        XCTAssertTrue(choices.buttons["Earlier source"].isSelected, app.debugDescription)
        choices.buttons["Staged"].tap()
        XCTAssertTrue(app.staticTexts["Source comparison opened"].waitForExistence(timeout: 5), app.debugDescription)
        let checks = ["Windows, walls and fixed appliances match the source",
                      "Doors, exits and walking routes remain clear",
                      "Furniture matches my other published views, or this is the only view"]
        for label in checks {
            let control = app.buttons[label]
            scrollTo(control)
            XCTAssertTrue(control.exists && control.isHittable, app.debugDescription)
            XCTAssertEqual(control.value as? String, "Not confirmed")
            control.tap()
            XCTAssertEqual(control.value as? String, "Confirmed", "The explicit review check must turn on")
        }
        let complete = NSPredicate { _, _ in use.isEnabled }
        expectation(for: complete, evaluatedWith: app); waitForExpectations(timeout: 5)
    }

    private func assertCompareContains(_ phrase: String) {
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", phrase)).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
    }

    private func assertSelectedExportForCompareButton(_ label: String, original: Bool) {
        let download = app.buttons[label]
        XCTAssertTrue(download.waitForExistence(timeout: 10) && download.isHittable, app.debugDescription)
        download.tap()
        XCTAssertTrue(app.navigationBars["Export photos"].waitForExistence(timeout: 10), app.debugDescription)
        let selectedVersion = original ? "Earlier source files" : "Selected photos · JPEG copies"
        let selected = app.staticTexts[selectedVersion]
        XCTAssertTrue(selected.exists, "Export starts with the version currently viewed: \(app.debugDescription)")
        let footer = original
            ? "Older files have no complete edit history. These earlier sources may already contain AI edits; verify them before publishing."
            : "Selected photos download as JPEG (.jpg) copies at full available resolution. AI output resolution may be lower than your capture. Stored photos and originals are never changed."
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
    private func launchLegacyPhotoDetail() {
        app.launchArguments = baseArguments + ["-ui.detailMetadataFixture", "rich", "-ui.legacyPhotoPairs"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Detail fixture rich"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(element("detail.fixtureFailure").exists, app.debugDescription)
    }
    private func launchDetail() {
        app.launchArguments = baseArguments + ["-ui.detailMetadataFixture", "rich"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Detail fixture rich"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(element("detail.fixtureFailure").exists, app.debugDescription)
    }
    private func openDetail(_ id: String, title: String, videoPurpose: String = "social_media") {
        let control = app.buttons[id]
        scrollTo(control); control.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 15), app.debugDescription)
        if id == "detail.reelStudio" {
            let purpose = app.buttons["video.purpose.\(videoPurpose)"]
            XCTAssertTrue(purpose.waitForExistence(timeout: 10), app.debugDescription)
            scrollTo(purpose); XCTAssertTrue(purpose.isHittable); purpose.tap()
            XCTAssertFalse(element("video.purposeChooser").exists, "A destination opens the existing video setup")
        }
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
    private func assertPhotoReviewChoicesAndToolsFitViewport(_ name: String) {
        let choices = element("photoVersion.savedChoices")
        XCTAssertTrue(choices.waitForExistence(timeout: 5), app.debugDescription)
        let buttons = choices.buttons.allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(buttons.count, 2, "Every saved category remains a visible choice")
        XCTAssertTrue(["Original", "Earlier source"].contains(buttons.first?.label ?? ""),
                      "The retained source appears before saved edits")
        var geometry = "App: \(app.frame)\n"
        for button in buttons {
            revealForBoundedAcceptance(button)
            XCTAssertTrue(button.isHittable, button.label + " must be reachable without horizontal scrolling")
            XCTAssertGreaterThanOrEqual(button.frame.height, 43.5)
            XCTAssertGreaterThanOrEqual(button.frame.minX, app.frame.minX + 15)
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX - 15,
                                     button.label + " must not clip beyond the right edge")
            XCTAssertGreaterThanOrEqual(button.frame.minY, app.frame.minY)
            XCTAssertLessThanOrEqual(button.frame.maxY, photoReviewFooterButton(download: true).frame.minY + 1)
            geometry += button.label + ": " + String(describing: button.frame) + "\n"
        }
        let edit = app.buttons["photoVersion.editOriginal"], compare = app.buttons["photoVersion.fullSize"]
        for button in [edit, compare] {
            revealForBoundedAcceptance(button)
            XCTAssertTrue(button.isHittable && button.isEnabled)
            XCTAssertGreaterThanOrEqual(button.frame.height, 43.5)
            XCTAssertGreaterThanOrEqual(button.frame.minX, app.frame.minX + 15)
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX - 15)
            XCTAssertGreaterThanOrEqual(button.frame.minY, app.frame.minY)
            XCTAssertLessThanOrEqual(button.frame.maxY, photoReviewFooterButton(download: true).frame.minY + 1)
            geometry += button.label + ": " + String(describing: button.frame) + "\n"
        }
        XCTAssertEqual(edit.label, "Edit original photo"); XCTAssertEqual(compare.label, "Compare")
        XCTAssertFalse(edit.frame.intersects(compare.frame), "Edit and Compare must not overlap")
        let attachment = XCTAttachment(string: geometry)
        attachment.name = name + "-geometry"; attachment.lifetime = .keepAlways; add(attachment)
        attach(name)
    }

    private func photoReviewFooterButton(download: Bool) -> XCUIElement {
        // SwiftUI Group can propagate fixedActions onto both child buttons.
        // Keep the known IDs and exact production accessibility labels so Save
        // can never resolve to Use/Unselect, or to a covered unrelated action.
        let childID = download ? "photoVersion.download" : "photoVersion.useOnListing"
        let labels = download
            ? ["Download original", "Download earlier source", "Download original photo",
               "Download earlier source photo", "Download enhanced photo", "Download decluttered photo", "Download staged photo"]
            : ["Use this version on listing", "Remove this photo from listing"]
        return app.buttons.matching(NSPredicate(format: "(identifier == %@ OR identifier == %@) AND label IN %@",
            childID, "photoVersion.fixedActions", labels as NSArray)).firstMatch
    }
    private func acceptanceViewport() -> (XCUIElement, CGFloat, CGFloat)? {
        guard let outer = app.scrollViews.allElementsBoundByIndex.reversed().first(where: {
            $0.frame.width >= app.frame.width - 8 && $0.isHittable
        }) else { XCTFail("No visible app page scroll view: \(app.debugDescription)"); return nil }
        let navigation = app.navigationBars.allElementsBoundByIndex.reversed().first { $0.isHittable }
        let top = max(outer.frame.minY, navigation?.frame.maxY ?? outer.frame.minY) + 8
        var bottom = min(outer.frame.maxY, app.frame.maxY) - 20
        let footer = element("photoVersion.fixedActions")
        if footer.exists && footer.isHittable { bottom = min(bottom, footer.frame.minY - 8) }
        if let tabs = app.tabBars.allElementsBoundByIndex.first(where: { $0.isHittable }) {
            bottom = min(bottom, tabs.frame.minY - 8)
        }
        guard bottom - top > 80 else { XCTFail("No usable app scroll viewport: \(app.debugDescription)"); return nil }
        return (outer, top, bottom)
    }
    private func acceptancePageDrag(up: Bool) {
        guard let (outer, top, bottom) = acceptanceViewport() else { return }
        // App-local gutter coordinates avoid image horizontal paging, buttons,
        // covered sheets and the fixed footer. No desktop input is involved.
        let origin = outer.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0))
        let high = origin.withOffset(CGVector(dx: 0, dy: top - outer.frame.minY + (bottom - top) * 0.2))
        let low = origin.withOffset(CGVector(dx: 0, dy: top - outer.frame.minY + (bottom - top) * 0.8))
        (up ? low : high).press(forDuration: 0.05, thenDragTo: up ? high : low)
    }
    private func revealForBoundedAcceptance(_ control: XCUIElement) {
        for attempt in 0...8 {
            guard let (_, top, bottom) = acceptanceViewport() else { return }
            if control.exists && control.isHittable && control.frame.height > 0
                && control.frame.minY >= top && control.frame.maxY <= bottom { return }
            if attempt < 8 { acceptancePageDrag(up: !control.exists || control.frame.minY >= top) }
        }
        XCTFail("Control was unreachable after eight app-local gestures: \(control.debugDescription)\n\(app.debugDescription)")
    }
    private func assertAcceptanceFooterIsVisible() {
        let save = photoReviewFooterButton(download: true), use = photoReviewFooterButton(download: false)
        for button in [save, use] {
            XCTAssertTrue(button.exists && button.isHittable, button.debugDescription)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            XCTAssertGreaterThanOrEqual(button.frame.minY, app.frame.minY)
            XCTAssertLessThanOrEqual(button.frame.maxY, app.frame.maxY)
        }
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
