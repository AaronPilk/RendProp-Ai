import Foundation

func makeHold(actor: UUID, org: UUID, product: String, reservation: UUID = UUID(uuidString: "00000000-0000-4000-8000-000000000099")!,
              enabled: Bool = true, photos: Int = 5, days: Int = 7) -> TrialPurchaseReservation {
    .init(reservationId: reservation, actorId: actor, appAccountToken: actor, orgId: org, productId: product,
          heldAt: "2026-10-06T00:00:00Z", trialOffer: .init(enabled: enabled,
            walkthroughs: 1, photoEdits: photos, publishedListings: 1, maxDays: days,
            maxVideoSeconds: 90, uploadBudgetBytes: 1_073_741_824))
}

@main struct TrialPurchaseHoldTests {
    @MainActor static func main() async throws {
        let actor = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let org = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let other = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
        let sku = "com.rendprop.app.pro.monthly"
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            guard value else { fatalError(message) }; checks += 1
        }
        func snapshot() -> TrialPurchaseSnapshot {
            .init(actor: AuthStore.shared.userID, revision: AuthStore.shared.syncSessionRevision, org: WorkspaceContext.selectedOrgID)
        }
        func fixture(ready: Bool = false) -> (PurchaseFixture, HeldAPI, Product) {
            AuthStore.shared.userID = actor.uuidString; AuthStore.shared.syncSessionRevision = 1
            AuthStore.shared.isSignedIn = true; AuthStore.shared.isIdentified = true
            AuthStore.shared.refreshes = 0; AuthStore.token = "synthetic-bearer"
            WorkspaceContext.selectedOrgID = org
            UserDefaults.standard.values = [:]
            Storefront.values = ["USA"]; Storefront.reads = 0; Storefront.onRead = nil
            Product.sheetCalls = 0; Product.receivedOptions = []; Product.result = .userCancelled; Product.error = nil
            URLSession.requests = []; URLSession.status = 200; URLSession.onResponse = nil
            let api = HeldAPI(org: org, actor: actor, product: sku)
            let value = PurchaseFixture(api)
            if ready {
                api.held = makeHold(actor: actor, org: org, product: sku)
                value.preparedTrialReservation = api.held; value.preparedTrialSnapshot = snapshot()
                value.introOfferEligible[sku] = true
            }
            return (value, api, Product(id: sku))
        }
        let hold = makeHold(actor: actor, org: org, product: sku)
        check(hold.checked(actor: actor, org: org, product: sku) == hold, "Exact held identity refused")
        check(hold.checked(actor: other, org: org, product: sku) == nil, "Wrong held actor accepted")
        let wrongActor = TrialPurchaseReservation(reservationId: hold.reservationId, actorId: other,
            appAccountToken: actor, orgId: org, productId: sku, heldAt: hold.heldAt, trialOffer: hold.trialOffer)
        check(wrongActor.checked(actor: actor, org: org, product: sku) == nil, "Wrong held actor accepted")
        check(hold.checked(actor: actor, org: other, product: sku) == nil, "Wrong held workspace accepted")
        check(hold.checked(actor: actor, org: org, product: "com.rendprop.app.starter.monthly") == nil, "Wrong held product accepted")
        check(makeHold(actor: actor, org: org, product: sku, photos: 4).checked(actor: actor, org: org, product: sku) == nil, "Wrong held allowance accepted")
        check(makeHold(actor: actor, org: org, product: sku, enabled: false).checked(actor: actor, org: org, product: sku) == nil, "Disabled held offer accepted")
        check(makeHold(actor: actor, org: org, product: sku, days: 6).checked(actor: actor, org: org, product: sku) == nil, "Non-seven-day held schedule accepted")
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let wire = try encoder.encode(hold)
        check(try TrialPurchaseReservation.decode(wire, actor: actor, org: org, product: sku) == hold, "Wire receipt round trip failed")
        var malformed = try JSONSerialization.jsonObject(with: wire) as! [String: Any]
        malformed["app_account_token"] = other.uuidString
        do { _ = try TrialPurchaseReservation.decode(JSONSerialization.data(withJSONObject: malformed), actor: actor, org: org, product: sku); fatalError("Wrong echoed appAccountToken accepted") }
        catch { checks += 1 }
        malformed.removeValue(forKey: "app_account_token")
        do { _ = try TrialPurchaseReservation.decode(JSONSerialization.data(withJSONObject: malformed), actor: actor, org: org, product: sku); fatalError("Missing echoed appAccountToken accepted") }
        catch { checks += 1 }
        malformed["app_account_token"] = actor.uuidString
        malformed["held_at"] = "not-a-date"
        do { _ = try TrialPurchaseReservation.decode(JSONSerialization.data(withJSONObject: malformed), actor: actor, org: org, product: sku); fatalError("Invalid hold timestamp accepted") }
        catch { checks += 1 }

        // Explicit check reserves terms only, without an Apple sheet.
        do {
            let (manager, api, product) = fixture()
            await manager.checkTrialAvailability(product, expectedOrgID: org)
            check(api.prepareCalls == 1 && Product.sheetCalls == 0, "Checking availability opened Apple sheet")
            check(manager.preparedTrialReservation == api.held && manager.heldTrialOffer(for: product)?.photoEdits == 5,
                  "Prepared terms not displayed from exact hold")
            check(manager.canStartNewPurchase(for: product), "Held terms could not continue")
            await manager.purchase(product, expectedOrgID: org, continuingHeldTrial: true)
            check(Product.sheetCalls == 1 && Product.receivedOptions == [.appAccountToken(actor)], "Held purchase did not bind captured actor")
            check(api.prepareCalls == 2 && manager.preparedTrialReservation?.reservationId == api.held?.reservationId,
                  "Continue replaced the original reservation")
            check(try PurchaseWorkspaceBindingStore.load(owner: actor, productID: sku)?.orgID == org,
                  "Cancellation discarded trial workspace binding")
        }
        for country in ["CAN", "GBR", nil] as [String?] {
            let (manager, api, product) = fixture(); Storefront.values = [country]
            await manager.checkTrialAvailability(product, expectedOrgID: org)
            check(api.prepareCalls == 0 && Product.sheetCalls == 0, "Foreign country created a hold")
            check(manager.lastError?.contains("United States") == true, "Unsupported region lacked explanation")
        }
        do {
            let (manager, api, original) = fixture(); var product = original; product.priceFormatStyle.currencyCode = "CAD"
            await manager.checkTrialAvailability(product, expectedOrgID: org)
            check(api.prepareCalls == 0 && Product.sheetCalls == 0, "Non-USD currency created a hold")
        }
        do {
            let (manager, api, product) = fixture()
            Storefront.onRead = { AuthStore.shared.syncSessionRevision += 1 }
            await manager.checkTrialAvailability(product, expectedOrgID: org)
            check(api.prepareCalls == 0 && Product.sheetCalls == 0, "Late storefront identity accepted")
        }
        do {
            let (manager, _, product) = fixture(); let captured = snapshot()
            Storefront.onRead = { WorkspaceContext.selectedOrgID = other }
            check(!(await manager.trialRegionSupported(for: product, captured: captured)), "Late storefront identity accepted")
        }
        do {
            let (manager, api, product) = fixture(ready: true); Storefront.values = ["USA", "CAN"]
            await manager.purchase(product, expectedOrgID: org, continuingHeldTrial: true)
            check(api.prepareCalls == 1 && Product.sheetCalls == 0, "Changed final region opened Apple sheet")
            check(try PurchaseWorkspaceBindingStore.load(owner: actor, productID: sku)?.orgID == org, "Changed region discarded held binding")
        }
        do {
            let (manager, api, product) = fixture(ready: true); Storefront.values = [nil]
            await manager.purchase(product, expectedOrgID: org, continuingHeldTrial: true)
            check(api.prepareCalls == 0 && Product.sheetCalls == 0, "Unknown held region replayed reservation")
        }
        do {
            let (manager, api, product) = fixture(ready: true)
            var fresh = try await api.billingContext(); fresh.trialReservation = nil
            api.overrideContext = fresh
            await manager.purchase(product, expectedOrgID: org, continuingHeldTrial: true)
            check(Product.sheetCalls == 0, "Converted hold opened Apple sheet")
        }
        do {
            let (manager, api, product) = fixture(ready: true)
            var fresh = try await api.billingContext(); fresh.trialOffer = nil
            api.overrideContext = fresh
            await manager.purchase(product, expectedOrgID: org, continuingHeldTrial: true)
            check(Product.sheetCalls == 0, "Changed fresh terms opened Apple sheet")
        }
        for change in [0, 1] {
            let (manager, api, product) = fixture(ready: true)
            Storefront.onRead = {
                guard Storefront.reads == 2 else { return }
                if change == 0 {
                    var value = SubscriptionBillingContext(orgID: org, orgName: "Synthetic workspace", role: "member", canManageSubscription: false, source: nil)
                    value.trialReservation = api.held; value.trialOffer = api.held?.trialOffer
                    api.overrideContext = value
                } else { api.converted = true }
            }
            await manager.purchase(product, expectedOrgID: org, continuingHeldTrial: true)
            check(Product.sheetCalls == 0 && api.prepareCalls == 1, "Late server authority during Apple await opened sheet")
        }
        for eligibility in [false, nil] as [Bool?] {
            let (manager, api, product) = fixture(ready: true); product.subscription?.values = [eligibility]
            await manager.purchase(product, expectedOrgID: org, continuingHeldTrial: true)
            check(Product.sheetCalls == 0 && api.prepareCalls == 0, "Changed held eligibility opened Apple sheet")
        }
        for eligibility in [false, nil] as [Bool?] {
            let (manager, api, product) = fixture(ready: true); product.subscription?.values = [true, eligibility]
            await manager.purchase(product, expectedOrgID: org, continuingHeldTrial: true)
            check(Product.sheetCalls == 0 && api.prepareCalls == 1, "Late eligibility change opened Apple sheet")
        }
        do {
            let (manager, api, product) = fixture(); product.subscription?.values = [false]
            await manager.purchase(product, expectedOrgID: org)
            check(Product.sheetCalls == 1 && api.prepareCalls == 0, "Explicit noneligible paid purchase was blocked")
        }
        do {
            let (manager, api, product) = fixture(); product.subscription?.values = [false]
            await manager.checkTrialAvailability(product, expectedOrgID: org)
            check(api.prepareCalls == 0 && Product.sheetCalls == 0, "Ineligible availability check created hold or purchase")
            check(manager.trialEligibility(for: product) == false && manager.lastError?.contains("separate Subscribe with Apple tap") == true,
                  "Fresh ineligible result trapped paid CTA")
            check(manager.canStartNewPurchase(for: product), "Fresh ineligible result trapped paid CTA")
            await manager.purchase(product, expectedOrgID: org)
            check(Product.sheetCalls == 1 && api.prepareCalls == 0, "Explicit paid tap after check was blocked")
        }
        do {
            let (manager, api, product) = fixture(); manager.introOfferEligible[sku] = true
            product.subscription?.values = [nil]
            await manager.checkTrialAvailability(product, expectedOrgID: org)
            check(api.prepareCalls == 0 && Product.sheetCalls == 0 && manager.trialEligibility(for: product) == nil,
                  "Unknown eligibility reused stale trial authority")
        }
        do {
            let (manager, api, product) = fixture()
            await manager.purchase(product, expectedOrgID: org, continuingHeldTrial: true)
            check(Product.sheetCalls == 0 && api.prepareCalls == 0, "Missing held intent authorized sheet")
        }
        do {
            let (manager, api, product) = fixture(); api.failPrepare = true
            await manager.checkTrialAvailability(product, expectedOrgID: org)
            check(api.prepareCalls == 1 && Product.sheetCalls == 0 && api.held != nil, "Uncertain hold was retried or cleared")
            check(try PurchaseWorkspaceBindingStore.load(owner: actor, productID: sku)?.orgID == org, "Uncertain hold discarded original workspace")
            api.failPrepare = false
            await manager.checkTrialAvailability(product, expectedOrgID: org)
            check(api.prepareCalls == 2 && manager.preparedTrialReservation?.reservationId == api.held?.reservationId,
                  "Explicit recovery did not reuse same reservation")
        }
        for result in [Product.PurchaseResult.userCancelled, .pending] {
            let (manager, api, product) = fixture(ready: true); Product.result = result
            await manager.purchase(product, expectedOrgID: org, continuingHeldTrial: true)
            check(Product.sheetCalls == 1 && api.prepareCalls == 1, "Held sheet repeated dispatch")
            check(try PurchaseWorkspaceBindingStore.load(owner: actor, productID: sku)?.orgID == org, "Cancellation discarded trial workspace binding")
        }
        for error in [SheetError.cancelled, .timeout] {
            let (manager, api, product) = fixture(ready: true); Product.error = error
            await manager.purchase(product, expectedOrgID: org, continuingHeldTrial: true)
            check(Product.sheetCalls == 1 && api.prepareCalls == 1, "Thrown sheet error repeated dispatch")
            check(try PurchaseWorkspaceBindingStore.load(owner: actor, productID: sku)?.orgID == org, "Thrown sheet error discarded binding")
        }
        do {
            let (manager, api, _) = fixture()
            let captured = snapshot(); AuthStore.shared.syncSessionRevision += 1
            do { _ = try await manager.validateHeldTrialPurchase(productID: sku, captured: captured, expectedReservationID: nil) }
            catch {}
            check(api.prepareCalls == 0, "Changed pre-prepare snapshot dispatched")
        }
        for change in [0, 1, 2] {
            let (manager, api, _) = fixture(); let captured = snapshot()
            api.onPrepare = {
                if change == 0 { AuthStore.shared.userID = other.uuidString }
                if change == 1 { AuthStore.shared.syncSessionRevision += 1 }
                if change == 2 { WorkspaceContext.selectedOrgID = other }
            }
            var accepted = false
            do { _ = try await manager.validateHeldTrialPurchase(productID: sku, captured: captured, expectedReservationID: nil); accepted = true }
            catch {}
            check(!accepted && api.prepareCalls == 1, "Late hold response accepted")
        }
        do {
            let (manager, api, _) = fixture()
            api.overrideHold = makeHold(actor: actor, org: org, product: sku, reservation: other)
            var accepted = false
            do { _ = try await manager.validateHeldTrialPurchase(productID: sku, captured: snapshot(), expectedReservationID: hold.reservationId); accepted = true }
            catch {}
            check(!accepted, "Replacement reservation accepted")
        }

        // Compile the real API method and request plumbing against a recorded
        // closed URLSession. No actual credentials or transport are used.
        do {
            _ = fixture(); URLSession.reply = wire
            let value = try await LiveAPIClient().prepareTrialPurchase(orgID: org, productID: sku, appAccountToken: actor)
            check(value == hold && URLSession.requests.count == 1, "Exact API receipt refused")
            let request = URLSession.requests[0]
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            check(Set(body.keys) == Set(["org_id", "actor_id", "app_account_token", "product_id"]), "Reservation payload has unexpected keys")
            check(body["actor_id"] == actor.uuidString.lowercased() && body["app_account_token"] == body["actor_id"] && body["org_id"] == org.uuidString.lowercased() && body["product_id"] == sku,
                  "Exact actor token workspace product payload missing")
            check(request.value(forHTTPHeaderField: "X-Org-Id") == org.uuidString.lowercased() && request.httpMethod == "POST" && request.timeoutInterval == 20,
                  "Reservation request scope or timeout differs")
        }
        do {
            _ = fixture(); URLSession.reply = wire
            do { _ = try await LiveAPIClient().prepareTrialPurchase(orgID: org, productID: sku, appAccountToken: other) }
            catch {}
            check(URLSession.requests.isEmpty, "Foreign appAccountToken dispatched")
        }
        do {
            _ = fixture(); URLSession.reply = wire
            do { _ = try await LiveAPIClient().prepareTrialPurchase(orgID: other, productID: sku, appAccountToken: actor) }
            catch {}
            check(URLSession.requests.isEmpty, "Foreign API workspace dispatched")
        }
        do {
            _ = fixture(); URLSession.status = 401; URLSession.reply = Data()
            do { _ = try await LiveAPIClient().prepareTrialPurchase(orgID: org, productID: sku, appAccountToken: actor) }
            catch {}
            check(URLSession.requests.count == 1 && AuthStore.shared.refreshes == 0, "Reservation retried after 401")
        }
        do {
            _ = fixture(); URLSession.reply = wire; URLSession.onResponse = { AuthStore.shared.syncSessionRevision += 1 }
            var accepted = false
            do { _ = try await LiveAPIClient().prepareTrialPurchase(orgID: org, productID: sku, appAccountToken: actor); accepted = true }
            catch {}
            check(!accepted && URLSession.requests.count == 1, "Late API response accepted")
        }
        do {
            _ = fixture(); AuthStore.token = nil; URLSession.reply = wire
            do { _ = try await LiveAPIClient().prepareTrialPurchase(orgID: org, productID: sku, appAccountToken: actor) }
            catch {}
            check(URLSession.requests.isEmpty, "Unauthenticated reservation dispatched")
        }
        print("Native trial hold: \(checks) checks passed")
    }
}
