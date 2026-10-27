import Foundation
import StoreKit

/// StoreKit owns payment; the server owns credits and the workspace ledger.
/// No transaction is finished until its signed JWS has an exact server receipt.
@MainActor final class CreditWalletStore: ObservableObject {
    static let shared = CreditWalletStore()
    @Published private(set) var snapshot: CreditWalletSnapshot?
    @Published private(set) var snapshotContext: CreditWalletContext?
    @Published private(set) var environment: String?
    @Published private(set) var product: Product?
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published private(set) var messageContext: CreditWalletContext?

    private let api: CreditWalletAPI?
    private var updatesTask: Task<Void, Never>?
    private var processing: [UInt64: Task<Void, Error>] = [:]

    init(api: CreditWalletAPI? = Config.makeAPIClient() as? CreditWalletAPI) { self.api = api }

    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self, case .verified(let transaction) = result,
                      RendpropCreditProduct.quantities[transaction.productID] != nil else { continue }
                await self.recoverUpdate(result)
            }
        }
    }

    func load(context: CreditWalletContext, refreshProduct: Bool = true) async {
        start()
        guard context.isCurrent, let api else { return }
        do {
            guard let verifiedEnvironment = await storeEnvironment() else { throw CloudSyncError.invalidResponse }
            let fetched = try await api.creditWallet(context: context, environment: verifiedEnvironment)
            guard context.isCurrent else { return }
            snapshot = fetched; snapshotContext = context; environment = verifiedEnvironment
            // A temporary StoreKit catalog failure must not hide an already
            // purchased balance or a server-authoritative action quote.
            if refreshProduct {
                let apple = (try? await Product.products(for: Array(RendpropCreditProduct.quantities.keys))) ?? []
                guard context.isCurrent else { return }
                product = apple.first { item in item.type == .consumable &&
                    fetched.products.contains(where: { $0.productID == item.id }) }
            }
            message = nil; messageContext = context
        } catch {
            guard context.isCurrent else { return }
            snapshot = nil; snapshotContext = context; product = nil; environment = nil
            setMessage("Credits are unavailable right now. Pull down or try again shortly.", context: context)
        }
    }

    func purchase(context: CreditWalletContext) async {
        guard !isBusy, context.isCurrent else { return }
        isBusy = true; defer { isBusy = false }
        setMessage(nil, context: context)
        do {
            guard let api, let wallet = snapshot, snapshotContext == context,
                  wallet.canPurchase,
                  let product, product.type == .consumable,
                  wallet.products.contains(where: { $0.productID == product.id &&
                      $0.credits == RendpropCreditProduct.quantities[product.id] }) else {
                throw CloudSyncError.invalidResponse
            }
            guard try CreditPurchaseIntentStore.load(actor: context.actorID) == nil else {
                setMessage("A credit purchase is still pending. Recover it before buying again.", context: context)
                return
            }
            let prepared = try await api.prepareCreditPurchase(productID: product.id, context: context)
            guard context.isCurrent else { throw CloudSyncError.identityChanged }
            if prepared.replay == true {
                // A server intent may outlive a crash before the device saved
                // it, or a pending Ask-to-Buy. Never invent a local Apple
                // transaction from that server-only record. Its signed token
                // remains recoverable if Apple later completes the purchase.
                setMessage("An earlier credit purchase may still be pending with Apple. Check pending purchase, then try again shortly if Apple did not start it.", context: context)
                return
            }
            let intent = CreditPurchaseIntent(intentID: prepared.intentID, actorID: context.actorID,
                                              orgID: context.servingOrgID, productID: product.id,
                                              appAccountToken: prepared.appAccountToken,
                                              createdAt: Date(), transactionID: nil, signedTransaction: nil)
            try CreditPurchaseIntentStore.save(intent)
            let result: Product.PurchaseResult
            do {
                result = try await product.purchase(options: [.appAccountToken(prepared.appAccountToken), .quantity(1)])
            } catch {
                // A known no-charge result can release the local pin. Unknown
                // transport errors and Apple approvals preserve it for recovery.
                if WebsitePurchasePretransactionRecovery.isKnownNoCharge(error) {
                    var noCharge = intent
                    noCharge.knownNoCharge = true
                    try CreditPurchaseIntentStore.save(noCharge)
                    guard context.isCurrent else { throw CloudSyncError.identityChanged }
                    try await api.abandonCreditPurchase(intent: noCharge, context: context)
                    try CreditPurchaseIntentStore.clear(noCharge)
                    setMessage("The App Store did not start a credit purchase. No credits were charged.", context: context)
                    return
                }
                throw error
            }
            switch result {
            case .success(let verified):
                try await settle(verified, intent: intent, context: context)
            case .userCancelled:
                var noCharge = intent
                noCharge.knownNoCharge = true
                try CreditPurchaseIntentStore.save(noCharge)
                guard context.isCurrent else { throw CloudSyncError.identityChanged }
                try await api.abandonCreditPurchase(intent: noCharge, context: context)
                try CreditPurchaseIntentStore.clear(noCharge)
                setMessage("Purchase cancelled. No credits were charged.", context: context)
            case .pending:
                setMessage("Apple is awaiting approval. These credits remain linked to the workspace you selected.", context: context)
            @unknown default:
                setMessage("Apple has not confirmed this purchase. Check pending purchases before buying again.", context: context)
            }
        } catch {
            if (try? CreditPurchaseIntentStore.load(actor: context.actorID))?.knownNoCharge == true {
                setMessage("No Apple charge was made. We could not clear the pending record yet; tap Check pending purchase to retry.", context: context)
            } else {
                setMessage("Your purchase has not been discarded. Check pending purchases, then contact support if it remains unavailable.", context: context)
            }
        }
    }

    func recover(context: CreditWalletContext) async {
        guard !isBusy, context.isCurrent else { return }
        isBusy = true; defer { isBusy = false }
        setMessage(nil, context: context)
        do {
            guard let api else { throw CloudSyncError.invalidResponse }
            let saved = try CreditPurchaseIntentStore.load(actor: context.actorID)
            if let saved, saved.knownNoCharge == true {
                try await api.abandonCreditPurchase(intent: saved, context: context)
                try CreditPurchaseIntentStore.clear(saved)
                setMessage("The cancelled credit purchase is cleared. No credits were charged.", context: context)
                return
            }
            let pending = try await api.openCreditPurchaseIntents(context: context)
            guard context.isCurrent else { throw CloudSyncError.identityChanged }
            var unfinished: [VerificationResult<Transaction>] = []
            for await result in Transaction.unfinished {
                guard case .verified(let transaction) = result,
                      RendpropCreditProduct.quantities[transaction.productID] != nil else { continue }
                unfinished.append(result)
            }
            guard context.isCurrent else { throw CloudSyncError.identityChanged }
            if let saved, let transactionID = saved.transactionID, let signed = saved.signedTransaction,
               !unfinished.contains(where: { result in
                   guard case .verified(let item) = result else { return false }
                   return String(item.id) == transactionID
               }) {
                let receipt = try await api.settleCreditPurchase(signedTransaction: signed,
                    intentID: saved.intentID, expectedOrgID: saved.orgID, context: context)
                guard receipt.transactionID == transactionID, receipt.orgID == saved.orgID else {
                    throw CloudSyncError.invalidResponse
                }
                try CreditPurchaseIntentStore.clear(saved)
                await load(context: context)
                setMessage("Your credit purchase is recorded in this workspace.", context: context)
            }
            var recovered = 0
            var notThisAccount = 0
            for result in unfinished.prefix(20) {
                guard case .verified(let transaction) = result else { continue }
                let matching = saved?.appAccountToken == transaction.appAccountToken ? saved : nil
                do {
                    try await settle(result, intent: matching, context: context)
                    recovered += 1
                } catch {
                    // StoreKit may contain a purchase for a different Rendprop
                    // account on the same Apple ID. The server checks the
                    // signed intent token; never finish a denied transaction.
                    notThisAccount += 1
                }
            }
            if recovered == 0 {
                let detail = pending.intents.isEmpty
                    ? "No completed credit purchase is ready yet."
                    : "Apple may still be waiting for approval of a credit purchase."
                setMessage(notThisAccount > 0
                    ? "A purchase needs its original Rendprop account. Sign in there to recover it."
                    : detail, context: context)
            }
        } catch {
            if (try? CreditPurchaseIntentStore.load(actor: context.actorID))?.knownNoCharge == true {
                setMessage("No Apple charge was made. The pending record is still being cleared; try again shortly.", context: context)
            } else {
                setMessage("The purchase is retained for recovery. Return to its original Rendprop account and try again.", context: context)
            }
        }
    }

    func recoverAfterSignIn() async {
        guard let context = try? CreditWalletContext.capture(), context.isCurrent else { return }
        let saved = try? CreditPurchaseIntentStore.load(actor: context.actorID)
        var unfinished = false
        for await result in Transaction.unfinished {
            switch result {
            case .verified(let transaction), .unverified(let transaction, _):
                if RendpropCreditProduct.quantities[transaction.productID] != nil {
                    unfinished = true; break
                }
            }
        }
        if saved != nil || unfinished { await recover(context: context) }
    }

    private func storeEnvironment() async -> String? {
        guard let result = try? await AppTransaction.shared,
              case .verified(let app) = result else { return nil }
        if app.environment == .production { return "Production" }
        if app.environment == .sandbox { return "Sandbox" }
        return nil
    }

    private func recoverUpdate(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result,
              let context = try? CreditWalletContext.capture(),
              context.isCurrent else { return }
        let saved = try? CreditPurchaseIntentStore.load(actor: context.actorID)
        let matching = saved?.appAccountToken == transaction.appAccountToken ? saved : nil
        try? await settle(result, intent: matching, context: context)
    }

    private func settle(_ result: VerificationResult<Transaction>, intent: CreditPurchaseIntent?,
                        context: CreditWalletContext) async throws {
        guard case .verified(let transaction) = result,
              RendpropCreditProduct.quantities[transaction.productID] != nil,
              transaction.productType == .consumable, transaction.purchasedQuantity == 1,
              transaction.ownershipType == .purchased,
              transaction.appAccountToken != nil,
              intent?.knownNoCharge != true,
              intent == nil || (intent?.actorID == context.actorID &&
                                intent?.productID == transaction.productID &&
                                intent?.appAccountToken == transaction.appAccountToken)
        else { throw CloudSyncError.invalidResponse }
        guard context.isCurrent else { throw CloudSyncError.identityChanged }
        if let active = processing[transaction.id] {
            try await active.value
            return
        }
        let active = Task { @MainActor in
            try await self.settleOnce(result, intent: intent, context: context)
        }
        processing[transaction.id] = active
        defer { processing.removeValue(forKey: transaction.id) }
        try await active.value
    }

    private func settleOnce(_ result: VerificationResult<Transaction>, intent: CreditPurchaseIntent?,
                            context: CreditWalletContext) async throws {
        guard case .verified(let transaction) = result else { throw CloudSyncError.invalidResponse }
        var durable = intent
        if var saved = durable {
            guard saved.transactionID == nil || saved.transactionID == String(transaction.id) else {
                throw CloudSyncError.invalidResponse
            }
            saved.transactionID = String(transaction.id)
            saved.signedTransaction = result.jwsRepresentation
            try CreditPurchaseIntentStore.save(saved)
            durable = saved
        }
        guard context.isCurrent, let api else { throw CloudSyncError.identityChanged }
        let receipt = try await api.settleCreditPurchase(signedTransaction: result.jwsRepresentation,
            intentID: durable?.intentID, expectedOrgID: durable?.orgID, context: context)
        _ = try receipt.checked(transactionID: transaction.id,
                                productID: transaction.productID, boundOrgID: durable?.orgID)
        // Only the server's durable, exact receipt permits StoreKit completion.
        await transaction.finish()
        if let durable { try CreditPurchaseIntentStore.clear(durable) }
        if context.isCurrent {
            if receipt.orgID == context.servingOrgID { await load(context: context) }
            setMessage(receipt.orgID == context.servingOrgID
                ? "Credits added to this workspace."
                : "Credits were recovered for the original workspace. Switch there to see the balance.",
                context: context)
        }
    }

    private func setMessage(_ value: String?, context: CreditWalletContext) {
        guard context.isCurrent else { return }
        messageContext = context
        message = value
    }
}
