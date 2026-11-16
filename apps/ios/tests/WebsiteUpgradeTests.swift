import Foundation

@main struct WebsiteUpgradeTests {
    @MainActor static func main() async throws {
        let actor = UUID(), other = UUID(), org = UUID(), property = UUID(), secondProperty = UUID()
        func reset() throws -> (WebsiteDesignContext, FakeWebsiteAPI, WebsiteUpgradeStore, Product) {
            try? FileManager.default.removeItem(at: WebsiteUpgradeFixture.directory)
            AuthStore.shared.userID = actor.uuidString; AuthStore.shared.isSignedIn = true
            AuthStore.shared.syncSessionRevision = 1; WorkspaceContext.selectedOrgID = org
            Transaction.queue = []; Product.purchases = 0; Product.onPurchase = nil
            AppTransaction.fixtureEnvironment = .production
            let context = WebsiteDesignContext(actorID: actor, sessionRevision: 1, orgID: org, listingID: property)
            let api = FakeWebsiteAPI(context: context)
            // Actual dependency is injected into a fresh store for each case.
            let injected = WebsiteUpgradeStore(api: api)
            let product = Product()
            Product.catalog = [product]
            return (context, api, injected, product)
        }
        func receipt(_ owner: UUID = actor, quantity: Int = 1, id: UInt64 = 71) -> VerificationResult<Transaction> {
            .verified(Transaction(id: id, owner: owner, quantity: quantity))
        }
        func transaction(_ result: VerificationResult<Transaction>) -> Transaction {
            guard case .verified(let value) = result else { fatalError("fixture verification") }; return value
        }
        precondition(WebsitePurchasePretransactionRecovery.isKnownNoCharge(StoreKitError.userCancelled),
                     "A known Apple cancellation cannot retain a pretransaction blocker")
        precondition(WebsitePurchasePretransactionRecovery.isKnownNoCharge(Product.PurchaseError.purchaseNotAllowed)
                     && WebsitePurchasePretransactionRecovery.isKnownNoCharge(Product.PurchaseError.productUnavailable),
                     "Known no-charge purchase refusals can release the pretransaction intent")
        precondition(!WebsitePurchasePretransactionRecovery.isKnownNoCharge(StoreKitError.unknown)
                     && !WebsitePurchasePretransactionRecovery.isKnownNoCharge(Product.PurchaseError.unknown),
                     "Unknown StoreKit outcomes keep the original property intent")
        // Happy path exercises the actual purchase, durable intent, network
        // admission, receipt acknowledgment and Apple finish order.
        do {
            let (c, api, store, product) = try reset(), result = receipt(), tx = transaction(result)
            api.transactionID = String(tx.id); product.nextResult = .success(result)
            Product.onPurchase = {
                precondition((try? WebsiteUpgradeIntentStore.load(actor: actor))?.listingID == property, "Property intent missing before charge")
            }
            tx.onFinish = { precondition(api.assignments == 1, "Apple finished before server acknowledgment") }
            await store.loadProduct(); await store.purchase(context: c)
            precondition(Product.purchases == 1 && api.assignments == 1 && tx.finishes == 1, "Completed upgrade was not fulfilled exactly once")
            let cleared = try WebsiteUpgradeIntentStore.load(actor: actor)
            precondition(cleared == nil, "Acknowledged intent was not cleared")
        }
        do {
            let (c, api, store, product) = try reset(), result = receipt(), tx = transaction(result)
            api.error = URLError(.notConnectedToInternet); api.transactionID = String(tx.id); product.nextResult = .success(result)
            await store.loadProduct(); await store.purchase(context: c)
            precondition(tx.finishes == 0, "Refused purchase was finished")
            let saved = try WebsiteUpgradeIntentStore.load(actor: actor)
            precondition(saved?.signedTransaction == "signed-71" && saved?.listingID == property, "Offline receipt custody was lost")
            api.error = nil; Transaction.queue = [result]
            await store.recover(context: c)
            precondition(tx.finishes == 1 && api.assignments == 2, "Offline purchase did not recover")
        }
        do {
            let (c, api, store, product) = try reset(), result = receipt(), tx = transaction(result)
            api.transactionID = "999"; product.nextResult = .success(result)
            await store.loadProduct(); await store.purchase(context: c)
            precondition(tx.finishes == 0 && (try? WebsiteUpgradeIntentStore.load(actor: actor)) != nil, "Foreign transaction acknowledgment finished Apple")
        }
        do {
            let (c, api, store, product) = try reset(), result = receipt(), tx = transaction(result)
            api.transactionID = String(tx.id); api.onAssignment = { AuthStore.shared.userID = other.uuidString }
            product.nextResult = .success(result)
            await store.loadProduct(); await store.purchase(context: c)
            precondition(tx.finishes == 0, "Late replacement-account response finished Apple")
            precondition(store.message == nil, "Purchase message leaked to another account")
        }
        do {
            let (c, api, store, product) = try reset(), result = receipt(), tx = transaction(result)
            api.transactionID = String(tx.id); api.onAssignment = { WorkspaceContext.selectedOrgID = UUID() }
            product.nextResult = .success(result)
            await store.loadProduct(); await store.purchase(context: c)
            precondition(tx.finishes == 0, "Late replacement-library response finished Apple")
        }
        for failure in [receipt(other), receipt(quantity: 2), .unverified(Transaction(id: 72, owner: actor, quantity: 1), StoreKitError.unknown)] {
            let (c, api, store, product) = try reset()
            product.nextResult = .success(failure)
            await store.loadProduct(); await store.purchase(context: c)
            precondition(api.assignments == 0, "Untrusted purchase was sent for fulfillment")
            if case .verified(let tx) = failure { precondition(tx.finishes == 0, "Untrusted purchase was finished") }
        }
        do {
            let (c, api, store, _) = try reset()
            api.enabled = false; await store.loadProduct(); await store.purchase(context: c)
            precondition(Product.purchases == 0, "Disabled SKU charged Apple")
        }
        do {
            let (c, _, store, _) = try reset()
            AppTransaction.fixtureEnvironment = .sandbox
            await store.loadProduct(); await store.purchase(context: c)
            precondition(Product.purchases == 0, "Production flag charged a disabled Sandbox product")
        }
        do {
            let (c, api, store, _) = try reset()
            api.enabled = false; api.sandboxEnabled = true
            await store.loadProduct(); await store.purchase(context: c)
            precondition(Product.purchases == 0, "Sandbox flag charged a disabled Production product")
        }
        do {
            let (c, api, store, _) = try reset()
            api.unlocked = true; await store.loadProduct(); await store.purchase(context: c)
            precondition(Product.purchases == 0, "Already upgraded property charged again")
        }
        do {
            let (c, _, store, product) = try reset()
            product.nextResult = .userCancelled; await store.loadProduct(); await store.purchase(context: c)
            let cleared = try WebsiteUpgradeIntentStore.load(actor: actor)
            precondition(cleared == nil, "Cancellation retained a purchase blocker")
        }
        do {
            let (c, _, store, product) = try reset()
            product.nextResult = .pending; await store.loadProduct(); await store.purchase(context: c)
            precondition((try? WebsiteUpgradeIntentStore.load(actor: actor))?.listingID == property, "Apple pending lost frozen property")
            await store.purchase(context: c)
            precondition(Product.purchases == 1, "Pending purchase allowed another charge")
        }
        do {
            let (c, api, store, _) = try reset(), result = receipt()
            Transaction.queue = [result]; await store.loadProduct(); await store.purchase(context: c)
            precondition(Product.purchases == 0 && api.assignments == 0, "Orphan paid credit charged again or assigned without confirmation")
            api.transactionID = "71"; await store.recover(context: c)
            precondition(api.assignments == 1 && transaction(result).finishes == 1, "Explicit orphan recovery failed")
        }
        do {
            let (c, api, store, _) = try reset(), result = receipt()
            api.unlocked = true; api.transactionID = "71"; Transaction.queue = [result]
            await store.recover(context: c)
            precondition(transaction(result).finishes == 1 && api.assignments == 1,
                "Reinstall after assignment stranded an unfinished credit")
        }
        do {
            let (c, api, store, _) = try reset(), result = receipt()
            let destination = WebsiteDesignContext(actorID: actor, sessionRevision: 1, orgID: org, listingID: secondProperty)
            api.context = destination; api.error = APIError.notConfigured; Transaction.queue = [result]
            await store.recover(context: destination)
            precondition((try? WebsiteUpgradeIntentStore.load(actor: actor)) == nil && transaction(result).finishes == 0,
                "Refused orphan destination pinned the wrong property")
            api.context = c; api.error = nil; api.transactionID = "71"; api.unlocked = true
            await store.recover(context: c)
            precondition(transaction(result).finishes == 1, "Original property could not recover after a refused destination")
        }
        do {
            let (c, api, store, _) = try reset()
            var intent = WebsiteUpgradeIntent(context: c)
            intent.transactionID = "71"; intent.signedTransaction = "signed-71"
            try WebsiteUpgradeIntentStore.save(intent)
            api.transactionID = "71"; await store.recover(context: c)
            precondition(api.assignments == 1 && (try? WebsiteUpgradeIntentStore.load(actor: actor)) == nil, "Crash after finish stranded durable intent")
        }
        do {
            let (c, api, store, _) = try reset()
            let otherContext = WebsiteDesignContext(actorID: actor, sessionRevision: 1, orgID: org, listingID: secondProperty)
            try WebsiteUpgradeIntentStore.save(WebsiteUpgradeIntent(context: otherContext))
            Transaction.queue = [receipt()]; await store.recover(context: c)
            precondition(api.assignments == 0, "Recovery retargeted another property's purchase")
        }
        do {
            let (c, api, store, _) = try reset()
            Transaction.queue = [receipt(id: 71), receipt(id: 72)]; await store.recover(context: c)
            precondition(api.assignments == 0, "Ambiguous credits were assigned arbitrarily")
        }
        do {
            let (c, _, _, _) = try reset(), first = WebsiteUpgradeIntent(context: c)
            try WebsiteUpgradeIntentStore.save(first)
            do { try WebsiteUpgradeIntentStore.save(WebsiteUpgradeIntent(context: c)); fatalError("Durable purchase slot overwritten") }
            catch { }
            let saved = try WebsiteUpgradeIntentStore.load(actor: actor)
            precondition(saved?.id == first.id, "Saved property intent changed")
        }
        do {
            let (c, api, store, product) = try reset(), result = receipt(), tx = transaction(result)
            api.transactionID = "71"; api.revoked = true; product.nextResult = .success(result)
            await store.loadProduct(); await store.purchase(context: c)
            precondition(tx.finishes == 1 && store.message?.contains("refunded") == true, "Verified refunded receipt could not settle")
        }
        do {
            let (c, _, _, _) = try reset()
            let refunded = WebsiteDesignState(listingID: property, orgID: org, theme: .basic,
                premium: .init(unlocked: false), assigned: false, revoked: true,
                environment: "Sandbox", transactionID: "71")
            let accepted = try refunded.acknowledges(transactionID: "71", context: c)
            precondition(accepted, "Refund before property assignment stranded a paid receipt")
        }
        print("PASS: actual website purchase custody, charge prevention, identity fences and recovery")
    }
}
