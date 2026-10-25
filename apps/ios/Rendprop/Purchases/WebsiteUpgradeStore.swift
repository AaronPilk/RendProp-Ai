import Foundation
import StoreKit

/// Consumable website credits are separate from monthly plan entitlements.
/// Apple owns the payment; the server owns the single-property assignment.
@MainActor final class WebsiteUpgradeStore: ObservableObject {
    static let shared = WebsiteUpgradeStore()
    @Published private(set) var product: Product?
    @Published private(set) var environment: String?
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published private(set) var messageContext: WebsiteDesignContext?
    private var updatesTask: Task<Void, Never>?
    private var processing = Set<UInt64>()
    private let api: WebsiteDesignAPI?

    init(api: WebsiteDesignAPI? = Config.makeAPIClient() as? WebsiteDesignAPI) { self.api = api }

    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self, case .verified(let transaction) = result,
                      transaction.productID == WebsiteUpgradeProduct.id else { continue }
                await self.recoverSavedIntent(result)
            }
        }
    }

    func loadProduct() async {
        start()
        environment = await verifiedStoreEnvironment()
        do {
            let found = try await Product.products(for: [WebsiteUpgradeProduct.id])
            product = found.first(where: { $0.id == WebsiteUpgradeProduct.id && $0.type == .consumable })
        } catch { product = nil }
    }

    func purchase(context: WebsiteDesignContext) async {
        guard !isBusy, context.isCurrent else { return }
        isBusy = true; defer { isBusy = false }
        setMessage(nil, context: context)
        do {
            guard let api, let product, product.id == WebsiteUpgradeProduct.id,
                  product.type == .consumable else { throw APIError.notConfigured }
            let state = try await api.websiteDesignState(context: context).checked(for: context)
            guard context.isCurrent else { throw CloudSyncError.identityChanged }
            if state.premium.unlocked { setMessage("This property is already upgraded. Choose either luxury design.", context: context); return }
            let currentEnvironment = await verifiedStoreEnvironment()
            guard context.isCurrent else { throw CloudSyncError.identityChanged }
            environment = currentEnvironment
            guard state.premium.canPurchase(environment: currentEnvironment) else {
                setMessage("Luxury upgrades are being prepared. You can preview both designs now.", context: context); return
            }
            guard try WebsiteUpgradeIntentStore.load(actor: context.actorID) == nil else {
                setMessage("A previous website purchase is still pending. Recover it on its original property before buying again.", context: context); return
            }
            // A reinstalled app may have an unfinished paid credit but no local
            // property intent. Do not silently charge again or assign that credit.
            let unfinished = await matchingUnfinished(actor: context.actorID)
            guard context.isCurrent else { throw CloudSyncError.identityChanged }
            guard unfinished.isEmpty else {
                setMessage("Apple has a website purchase awaiting recovery. Recover it before making another purchase.", context: context); return
            }
            let intent = WebsiteUpgradeIntent(context: context)
            try WebsiteUpgradeIntentStore.save(intent)
            let result = try await product.purchase(options: [.appAccountToken(context.actorID), .quantity(1)])
            switch result {
            case .success(let verified):
                try await settle(verified, intent: intent, context: context)
            case .userCancelled:
                try WebsiteUpgradeIntentStore.clear(intent)
                setMessage("Purchase cancelled. Your included website is unchanged.", context: context)
            case .pending:
                setMessage("Apple is waiting for approval. Your purchase will stay linked to this property.", context: context)
            @unknown default:
                setMessage("Apple hasn't confirmed the purchase. Use Recover purchase before buying again.", context: context)
            }
        } catch {
            setMessage(recoveryMessage(error), context: context)
        }
    }

    private func verifiedStoreEnvironment() async -> String? {
        guard let result = try? await AppTransaction.shared, case .verified(let transaction) = result else { return nil }
        if transaction.environment == .production { return "Production" }
        if transaction.environment == .sandbox { return "Sandbox" }
        return nil
    }

    /// Called only after the user explicitly confirms this destination property.
    /// Saved intents always win; a credit is never retargeted by navigation.
    func recover(context: WebsiteDesignContext) async {
        guard !isBusy, context.isCurrent else { return }
        isBusy = true; defer { isBusy = false }
        setMessage(nil, context: context)
        do {
            guard let api else { throw APIError.notConfigured }
            let state = try await api.websiteDesignState(context: context).checked(for: context)
            guard context.isCurrent else { throw CloudSyncError.identityChanged }
            let saved = try WebsiteUpgradeIntentStore.load(actor: context.actorID)
            if let saved, !saved.matches(context) {
                setMessage("This pending purchase belongs to another property or library. Open that property to recover it.", context: context); return
            }
            let candidates = await matchingUnfinished(actor: context.actorID)
            guard context.isCurrent else { throw CloudSyncError.identityChanged }
            let filtered = candidates.filter { result in
                guard case .verified(let transaction) = result else { return false }
                return saved?.transactionID == nil || saved?.transactionID == String(transaction.id)
            }
            if filtered.isEmpty, saved == nil, state.premium.unlocked {
                setMessage("Your website upgrade is restored for this property.", context: context); return
            }
            // A crash after Apple finish but before deleting the local intent
            // leaves no unfinished transaction. The signed server receipt can
            // still confirm the original assignment and clear that exact intent.
            if filtered.isEmpty, let saved, let signed = saved.signedTransaction,
               let transactionID = saved.transactionID {
                let ack = try await api.assignWebsiteUpgrade(signedTransaction: signed, context: context)
                guard context.isCurrent, try ack.acknowledges(transactionID: transactionID, context: context) else {
                    throw CloudSyncError.invalidResponse
                }
                try WebsiteUpgradeIntentStore.clear(saved)
                setMessage(ack.revoked == true ? "Apple refunded this purchase. Your property's current website access has been refreshed."
                    : "Your website upgrade is recovered for this property.", context: context)
                return
            }
            guard filtered.count == 1, let verified = filtered.first else {
                setMessage(filtered.isEmpty
                    ? "No completed website purchase is awaiting recovery. Apple approval may still be pending; your saved property selection is retained."
                    : "More than one website purchase needs recovery. Contact support before making another purchase.", context: context)
                return
            }
            let intent = saved ?? WebsiteUpgradeIntent(context: context)
            // An orphan may already be assigned on the server. A refused
            // destination must not create a local pin to the wrong property.
            try await settle(verified, intent: intent, context: context, saveBeforeAcknowledgment: saved != nil)
        } catch { setMessage(recoveryMessage(error), context: context) }
    }

    private func matchingUnfinished(actor: UUID) async -> [VerificationResult<Transaction>] {
        var found: [VerificationResult<Transaction>] = []
        for await result in Transaction.unfinished {
            guard case .verified(let transaction) = result,
                  transaction.productID == WebsiteUpgradeProduct.id,
                  transaction.appAccountToken == actor else { continue }
            found.append(result)
        }
        return found
    }

    private func recoverSavedIntent(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result, let actor = transaction.appAccountToken,
              let intent = try? WebsiteUpgradeIntentStore.load(actor: actor),
              let context = try? WebsiteDesignContext.capture(listingID: intent.listingID),
              intent.matches(context), context.isCurrent else { return }
        do { try await settle(result, intent: intent, context: context) }
        catch { setMessage(recoveryMessage(error), context: context) }
    }

    private func settle(_ result: VerificationResult<Transaction>, intent: WebsiteUpgradeIntent,
                        context: WebsiteDesignContext, saveBeforeAcknowledgment: Bool = true) async throws {
        guard case .verified(let transaction) = result,
              transaction.productID == WebsiteUpgradeProduct.id,
              transaction.productType == .consumable, transaction.purchasedQuantity == 1,
              transaction.ownershipType == .purchased, transaction.appAccountToken == intent.actorID,
              intent.matches(context) else { throw CloudSyncError.invalidResponse }
        guard !processing.contains(transaction.id) else { return }
        processing.insert(transaction.id); defer { processing.remove(transaction.id) }
        var durable = intent
        guard durable.transactionID == nil || durable.transactionID == String(transaction.id) else {
            throw CloudSyncError.invalidResponse
        }
        durable.transactionID = String(transaction.id); durable.signedTransaction = result.jwsRepresentation
        if saveBeforeAcknowledgment { try WebsiteUpgradeIntentStore.save(durable) }
        guard context.isCurrent, let api else { throw CloudSyncError.identityChanged }
        let acknowledged = try await api.assignWebsiteUpgrade(signedTransaction: result.jwsRepresentation, context: context)
        guard context.isCurrent,
              try acknowledged.acknowledges(transactionID: String(transaction.id), context: context) else {
            throw CloudSyncError.invalidResponse
        }
        if !saveBeforeAcknowledgment { try WebsiteUpgradeIntentStore.save(durable) }
        // The durable server assignment survived the request. Only now may
        // Apple drop this transaction from its redelivery queue.
        await transaction.finish()
        try WebsiteUpgradeIntentStore.clear(durable)
        setMessage(acknowledged.revoked == true
            ? "Apple refunded this purchase. Your property's current website access has been refreshed."
            : "This property is upgraded. You can switch between both luxury designs.", context: context)
    }

    private func setMessage(_ value: String?, context: WebsiteDesignContext) {
        guard context.isCurrent else { return }
        messageContext = context; message = value
    }
    private func recoveryMessage(_ error: Error) -> String {
        if error is CloudSyncError { return "Your purchase is retained. Return to its original Rendprop account and property, then recover it." }
        return "The website purchase couldn't be completed or recovered. It has not been discarded. Use Recover purchase on its original property; contact support if it remains unavailable."
    }
}
