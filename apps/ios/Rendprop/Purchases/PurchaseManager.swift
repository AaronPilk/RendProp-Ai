import Foundation
import StoreKit
import UIKit

// MARK: - StoreKit 2 purchase engine
//
// The rules this file exists to enforce:
//
//  1. A transaction is only ever trusted after `VerificationResult.verified`.
//     `.unverified` is dropped on the floor — not finished, not granted.
//  2. A transaction is `finish()`ed ONLY after our server accepted it. If the
//     network is down, the transaction stays unfinished so StoreKit redelivers
//     it through `Transaction.updates`, and we retry on the next foreground.
//     Finishing an unsynced transaction is how people end up paying for
//     nothing.
//  3. `activePlan` is DISPLAY ONLY. Every real gate is the server's (`orgs.plan`
//     + `plan_entitlements`, enforced on each route). Nothing in the app should
//     unlock a feature because this property says so.
//  4. No prices here. `Product.displayPrice` is the only price the user sees.
//
// Everything runs on the main actor: the published state drives SwiftUI, and
// `Product.purchase(options:)` and `AppStore.showManageSubscriptions(in:)` are
// `@MainActor` anyway.

@MainActor
final class PurchaseManager: ObservableObject {
    static let shared = PurchaseManager()

    // MARK: Published state

    /// Loaded StoreKit products, in `RendpropProducts.all` order. Empty is a
    /// legitimate state (simulator with no StoreKit config file, no App Store
    /// account, products not yet approved) — the paywall says so plainly.
    @Published private(set) var products: [Product] = []

    /// The plan the SERVER last confirmed ("starter" | "pro" | "team"), or a
    /// local product-id mapping when we have a verified entitlement but the
    /// sync hasn't landed yet. nil = nothing active that we know of.
    @Published private(set) var activePlan: String?

    /// The product id behind `activePlan`, so the paywall can mark the exact
    /// row (monthly vs yearly) as "Your plan".
    @Published private(set) var activeProductID: String?

    /// End of the current paid period, when the server told us.
    @Published private(set) var activeExpiresAt: Date?

    /// True while a purchase sheet is up or its sync is in flight.
    @Published private(set) var isPurchasing = false

    /// True while `AppStore.sync()` (Restore) is running.
    @Published private(set) var isRestoring = false

    /// True while the first product load is running.
    @Published private(set) var isLoadingProducts = false

    /// Set once a product load has finished, successfully or not. Until then
    /// the paywall shows a spinner rather than an empty state.
    @Published private(set) var didLoadProducts = false

    /// Plain-language failure for the paywall. nil = nothing to say.
    @Published var lastError: String?

    /// Plain-language non-failure notice (Ask to Buy is pending, restore found
    /// nothing). nil = nothing to say.
    @Published var notice: String?

    /// productID → "this customer may still use the introductory offer".
    /// From `Product.SubscriptionInfo.isEligibleForIntroOffer`, which is
    /// per subscription GROUP, so every id answers the same. The paywall must
    /// still check that the product actually HAS an introductory offer before
    /// promising a free trial.
    @Published private(set) var introOfferEligible: [String: Bool] = [:]

    /// Number of verified transactions we could not get the server to accept.
    /// Shown nowhere; drives the "still syncing" line and the foreground retry.
    @Published private(set) var unsyncedCount = 0

    // MARK: Dependencies

    /// The entitlement-sync client. Defaults to whatever `Config` builds
    /// (Live when `useLiveBackend`, Mock offline) — both conform.
    var api: PurchasesAPI?

    // MARK: Private state

    private var started = false
    private var updatesTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    /// Verified transactions the server has not accepted yet, keyed by
    /// `Transaction.id`. NOT persisted on purpose: StoreKit itself is the
    /// durable queue — an unfinished transaction comes back through
    /// `Transaction.updates` on the next launch.
    private var unsynced: [UInt64: PendingSync] = [:]

    /// Transaction ids the server already accepted during THIS app run. Stops
    /// the launch/foreground sweep from re-POSTing the same entitlement every
    /// time the app comes forward. A purchase and anything from
    /// `Transaction.updates` always syncs, sweep or no sweep.
    private var syncedThisSession: Set<UInt64> = []

    private struct PendingSync {
        let transaction: Transaction
        let signedTransaction: String
        let signedRenewalInfo: String?
    }

    private init() {
        api = Config.makeAPIClient() as? PurchasesAPI
    }

    // MARK: - Lifecycle

    /// Start the `Transaction.updates` listener and do the first entitlement
    /// check. Safe to call on every view appearance — it runs once.
    func start() {
        guard !started else { return }
        started = true

        // Listener FIRST, before anything can produce a transaction: Apple's
        // guidance is that the app must be able to receive a transaction that
        // was interrupted by a crash or delivered from another device.
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                await self.handle(update, event: "update")
            }
        }

        Task { [weak self] in
            await self?.loadProducts()
            await self?.refreshEntitlements()
        }
    }

    /// Called when the scene becomes active. Cheap: re-reads current
    /// entitlements and retries anything the server hasn't accepted.
    func refreshOnForeground() {
        guard started else { start(); return }
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            if self.products.isEmpty { await self.loadProducts() }
            await self.retryUnsynced()
            await self.refreshEntitlements()
            self.refreshTask = nil
        }
    }

    // MARK: - Products

    /// Ask StoreKit for the subscription products we currently sell
    /// (`RendpropProducts.all` — which leaves out `notSoldAtLaunch` ids, Team
    /// Yearly today). An empty result is not
    /// an error — it is the simulator with no `.storekit` file attached, or a
    /// device with no App Store account, or products still "Waiting for
    /// Review". The paywall says "Plans aren't available right now" and offers
    /// Retry. It never spins forever and it never crashes.
    func loadProducts() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        defer {
            isLoadingProducts = false
            didLoadProducts = true
        }
        do {
            let fetched = try await Product.products(for: RendpropProducts.all)
            let order = RendpropProducts.all
            products = fetched.sorted {
                (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max)
            }
            if !products.isEmpty { lastError = nil }
            await refreshIntroEligibility()
        } catch {
            products = []
            lastError = Self.message(for: error, fallback: "We couldn't load the plans. Check your connection and try again.")
        }
    }

    func product(for productID: String) -> Product? {
        products.first { $0.id == productID }
    }

    /// Eligibility is per subscription group, so one lookup answers for every
    /// id — but ask through whichever product we actually have.
    private func refreshIntroEligibility() async {
        guard let subscription = products.compactMap({ $0.subscription }).first else {
            introOfferEligible = [:]
            return
        }
        let eligible = await subscription.isEligibleForIntroOffer
        var map: [String: Bool] = [:]
        for product in products { map[product.id] = eligible }
        introOfferEligible = map
    }

    /// True when the paywall may honestly say "Start 7-day free trial" for this
    /// product: the customer is eligible AND the product really carries an
    /// introductory offer.
    func showsIntroOffer(for product: Product) -> Bool {
        guard introOfferEligible[product.id] == true else { return false }
        return product.subscription?.introductoryOffer != nil
    }

    // MARK: - Buying

    func purchase(_ product: Product) async {
        guard !isPurchasing else { return }
        isPurchasing = true
        lastError = nil
        notice = nil
        defer { isPurchasing = false }

        PaywallEvents.track("purchase_started", product: product)

        let result: Product.PurchaseResult
        do {
            result = try await product.purchase(options: Self.accountBinding())
        } catch {
            // `.userCancelled` can also arrive as a thrown StoreKitError.
            if Self.isCancellation(error) { return }
            let message = Self.message(for: error, fallback: "That purchase didn't go through. Please try again.")
            lastError = message
            PaywallEvents.track("purchase_failed", product: product, extra: ["reason": "storekit"])
            return
        }

        switch result {
        case .success(let verification):
            let ok = await handle(verification, event: "purchase")
            if ok {
                PaywallEvents.track("purchase_completed", product: product)
            } else {
                PaywallEvents.track("purchase_failed", product: product, extra: ["reason": "sync"])
            }
        case .pending:
            // Ask to Buy / Strong Customer Authentication. Nothing failed —
            // somebody else has to approve it, and it will arrive through
            // `Transaction.updates`.
            notice = "Your request was sent for approval. Your plan turns on as soon as it's approved — you can close this."
            PaywallEvents.track("purchase_failed", product: product, extra: ["reason": "pending"])
        case .userCancelled:
            // Silent, by design. Nothing went wrong.
            break
        @unknown default:
            lastError = "That purchase didn't finish. Please try again."
            PaywallEvents.track("purchase_failed", product: product, extra: ["reason": "unknown"])
        }
    }

    /// Restore: ask the App Store to refresh this device's transactions, then
    /// re-read entitlements. `AppStore.sync()` prompts for the Apple ID
    /// password, so it belongs on an explicit "Restore purchases" tap only.
    func restore() async {
        guard !isRestoring else { return }
        isRestoring = true
        lastError = nil
        notice = nil
        defer { isRestoring = false }

        PaywallEvents.track("restore")

        do {
            try await AppStore.sync()
        } catch {
            if Self.isCancellation(error) { return }
            lastError = Self.message(for: error, fallback: "We couldn't reach the App Store. Please try again.")
            return
        }
        await refreshEntitlements()
        if activePlan == nil {
            notice = "No subscription found on this Apple ID."
        }
    }

    /// Apple's own subscription-management sheet — the only correct place to
    /// cancel or switch plans (3.1.2 / the App Store's rules on cancellation).
    func manageSubscriptions() async {
        guard let scene = Self.activeWindowScene() else {
            lastError = "We couldn't open the App Store subscription settings. Open Settings → Apple ID → Subscriptions."
            return
        }
        do {
            try await AppStore.showManageSubscriptions(in: scene)
        } catch {
            if Self.isCancellation(error) { return }
            lastError = "We couldn't open the App Store subscription settings. Open Settings → Apple ID → Subscriptions."
        }
    }


    /// Binds the purchase to the signed-in account. StoreKit signs the
    /// `appAccountToken` into the transaction and into every later notification
    /// for this subscription, permanently; the server refuses a token that
    /// names another user (migration 0021), which is what makes a copied
    /// `jwsRepresentation` worthless to anyone but the buyer. Supabase user ids
    /// are already UUIDs, so the id itself is the token. Signed-out purchases
    /// (none today — the paywall sits behind sign-in) simply carry no token.
    private static func accountBinding() -> Set<Product.PurchaseOption> {
        guard let id = AuthStore.shared.userID, let uuid = UUID(uuidString: id) else { return [] }
        return [.appAccountToken(uuid)]
    }

    // MARK: - Entitlements

    /// Walk `Transaction.currentEntitlements` and sync anything that is ours.
    /// Runs at launch, on foreground, and after a restore.
    func refreshEntitlements() async {
        var found: [VerificationResult<Transaction>] = []
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement else { continue }
            guard RendpropProducts.plan(for: transaction.productID) != nil else { continue }
            if transaction.revocationDate != nil { continue }
            if let expiry = transaction.expirationDate, expiry <= Date() { continue }
            found.append(entitlement)
        }

        guard !found.isEmpty else {
            // Nothing active on this Apple ID. Do NOT write "free" anywhere —
            // the org's plan may be a manual/comped one the server owns.
            activePlan = nil
            activeProductID = nil
            activeExpiresAt = nil
            return
        }

        // Show the local answer straight away (highest tier wins if there is
        // more than one live entitlement) so the paywall can mark "Your plan"
        // without waiting on a round trip. Still display only.
        applyLocalPlan(from: found)

        for entitlement in found {
            guard case .verified(let transaction) = entitlement else { continue }
            // Already accepted this run and nothing outstanding → nothing to say.
            if syncedThisSession.contains(transaction.id), unsynced[transaction.id] == nil { continue }
            _ = await handle(entitlement, event: "entitlement")
        }
    }

    /// Best local guess at the plan from StoreKit alone. Never a gate.
    private func applyLocalPlan(from entitlements: [VerificationResult<Transaction>]) {
        var best: (plan: RendpropPlan, transaction: Transaction)?
        for entitlement in entitlements {
            guard case .verified(let transaction) = entitlement,
                  let plan = RendpropProducts.plan(for: transaction.productID) else { continue }
            if let current = best, plan.tier <= current.plan.tier { continue }
            best = (plan, transaction)
        }
        guard let best else { return }
        activePlan = best.plan.rawValue
        activeProductID = best.transaction.productID
        activeExpiresAt = best.transaction.expirationDate
    }

    /// One verified transaction, end to end.
    ///
    /// Returns true only when the server accepted it AND we finished it.
    @discardableResult
    private func handle(_ verification: VerificationResult<Transaction>, event: String) async -> Bool {
        // 1. Verification. `.unverified` means the JWS did not check out on
        //    device — never grant, never finish, never send.
        guard case .verified(let transaction) = verification else {
            lastError = "We couldn't confirm that purchase with the App Store. Try Restore purchases."
            return false
        }
        // 2. Ours?
        guard RendpropProducts.plan(for: transaction.productID) != nil else {
            // Something we don't sell (a leftover from an older build). Finish
            // it so StoreKit stops redelivering it forever.
            await transaction.finish()
            return false
        }
        // 3. Revoked/refunded: let the server hear about it too — it is what
        //    turns the plan back to free — then finish.
        let signedTransaction = verification.jwsRepresentation
        let signedRenewalInfo = await renewalInfoJWS(forProductID: transaction.productID)

        let pending = PendingSync(transaction: transaction,
                                  signedTransaction: signedTransaction,
                                  signedRenewalInfo: signedRenewalInfo)
        return await sync(pending, event: event)
    }

    /// POST the signed transaction; finish it only on success.
    private func sync(_ pending: PendingSync, event: String) async -> Bool {
        guard let api else {
            // No client at all (misconfigured build). Keep the transaction
            // unfinished so a fixed build can still claim it.
            remember(pending)
            lastError = "This build can't reach the Rendprop server, so your plan can't switch on yet."
            return false
        }

        // Optimistic display value so the paywall stops looking broken while
        // the round trip happens. Never a gate — the server decides.
        if activePlan == nil {
            activePlan = RendpropProducts.planName(for: pending.transaction.productID)
            activeProductID = pending.transaction.productID
        }

        do {
            let result = try await api.syncEntitlement(signedTransaction: pending.signedTransaction,
                                                       signedRenewalInfo: pending.signedRenewalInfo)
            applyServerPlan(result, productID: pending.transaction.productID)
            // ONLY now. Before this line, a crash or a dead network leaves the
            // transaction with StoreKit, which is exactly what we want.
            await pending.transaction.finish()
            syncedThisSession.insert(pending.transaction.id)
            forget(pending.transaction.id)
            lastError = nil
            NotificationCenter.default.post(name: .rendpropPlanChanged, object: nil)
            return true
        } catch {
            remember(pending)
            let apiError = error as? APIError
            if apiError?.isUnauthorized == true {
                lastError = "Sign in to finish turning on your plan. Your purchase is safe — nothing is lost."
            } else {
                lastError = "Your purchase went through. We couldn't reach Rendprop to switch your plan on yet — it retries by itself, or pull down to refresh in Settings."
            }
            _ = event
            return false
        }
    }

    /// The plan the server just wrote wins over any local guess.
    private func applyServerPlan(_ result: EntitlementSync, productID: String) {
        let plan = result.plan.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if plan.isEmpty || plan == "free" {
            activePlan = nil
            activeProductID = nil
            activeExpiresAt = nil
            return
        }
        activePlan = plan
        activeProductID = result.productId ?? productID
        activeExpiresAt = result.expiresAt
    }

    private func remember(_ pending: PendingSync) {
        unsynced[pending.transaction.id] = pending
        unsyncedCount = unsynced.count
    }

    private func forget(_ id: UInt64) {
        unsynced.removeValue(forKey: id)
        unsyncedCount = unsynced.count
    }

    /// Retry every transaction the server hasn't accepted. Called on foreground
    /// and by the paywall's Retry button.
    func retryUnsynced() async {
        guard !unsynced.isEmpty else { return }
        // Snapshot: `sync` mutates `unsynced` as it succeeds or fails.
        for pending in Array(unsynced.values) {
            _ = await sync(pending, event: "retry")
        }
    }

    /// The signed `RenewalInfo` for a product, when StoreKit has one. Optional
    /// by contract — the server can work from the transaction alone.
    private func renewalInfoJWS(forProductID productID: String) async -> String? {
        guard let subscription = product(for: productID)?.subscription else { return nil }
        guard let statuses = try? await subscription.status, !statuses.isEmpty else { return nil }
        for status in statuses {
            if case .verified(let transaction) = status.transaction, transaction.productID == productID {
                return status.renewalInfo.jwsRepresentation
            }
        }
        return statuses.first?.renewalInfo.jwsRepresentation
    }

    // MARK: - Helpers

    /// The scene Apple's subscription sheet needs. Prefer the foreground-active
    /// one; fall back to any window scene rather than failing outright.
    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let skError = error as? StoreKitError, case .userCancelled = skError { return true }
        return false
    }

    /// Plain words. Never a raw StoreKit error string, never a code.
    static func message(for error: Error, fallback: String) -> String {
        if let apiError = error as? APIError, let text = apiError.errorDescription, !text.isEmpty {
            return text
        }
        guard let skError = error as? StoreKitError else { return fallback }
        switch skError {
        case .networkError:
            return "You're offline — check your connection and try again."
        case .systemError:
            return "The App Store had a problem. Please try again in a moment."
        case .notAvailableInStorefront:
            return "These plans aren't sold in your country's App Store yet."
        case .notEntitled:
            return "This app isn't set up to sell plans on this device."
        default:
            // `.userCancelled`, `.unknown`, and anything a later OS adds.
            // A plain `default` rather than naming every case + `@unknown
            // default`: StoreKitError has gained cases between iOS releases, and
            // this has to build unchanged against whichever SDK we ship from.
            return fallback
        }
    }
}
