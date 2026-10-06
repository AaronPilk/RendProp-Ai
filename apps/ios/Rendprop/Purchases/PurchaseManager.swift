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
    @Published private(set) var activeOriginalTransactionID: String?

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
    @Published private(set) var billingContext: SubscriptionBillingContext?
    private var billingRefreshGeneration: UInt64 = 0
    @Published private(set) var billingError: String?
    @Published private(set) var preparedTrialReservation: TrialPurchaseReservation?
    private var preparedTrialSnapshot: TrialPurchaseSnapshot?

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
    private var syncedThisSession: Set<String> = []
    private var activeBillingOwner: UUID?

    private struct PendingSync {
        let transaction: Transaction
        let signedTransaction: String
        let signedRenewalInfo: String?
        let expectedOrgID: UUID?
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
            await self.refreshIntroEligibility()
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
        trialEligibility(for: product) == true && heldTrialOffer(for: product) != nil
    }

    /// nil means StoreKit has not confirmed eligibility for a configured
    /// seven-day offer. It cannot authorize an introductory purchase.
    func trialEligibility(for product: Product) -> Bool? {
        guard hasFreeIntroductoryOffer(for: product) else { return false }
        guard hasSevenDayTrial(for: product) else {
            return introOfferEligible[product.id] == false ? false : nil
        }
        return introOfferEligible[product.id]
    }

    private func hasFreeIntroductoryOffer(for product: Product) -> Bool {
        product.subscription?.introductoryOffer?.paymentMode == .freeTrial
    }

    private func hasSevenDayTrial(for product: Product) -> Bool {
        guard let offer = product.subscription?.introductoryOffer else { return false }
        let unit: SubscriptionOfferPolicy.PeriodUnit
        switch offer.period.unit {
        case .day: unit = .day
        case .week: unit = .week
        case .month: unit = .month
        case .year: unit = .year
        @unknown default: unit = .unknown
        }
        return SubscriptionOfferPolicy.isSevenDayFreeTrial(eligible: true,
            free: offer.paymentMode == .freeTrial, value: offer.period.value, unit: unit, count: offer.periodCount)
    }

    func canStartNewPurchase(for product: Product) -> Bool {
        guard Config.useLiveBackend && !Config.isUITesting else { return true }
        let current = TrialPurchaseSnapshot(actor: AuthStore.shared.userID,
            revision: AuthStore.shared.syncSessionRevision, org: WorkspaceContext.selectedOrgID)
        if trialEligibility(for: product) == true, heldTrialOffer(for: product) == nil { return false }
        return TrialPurchaseAdmission.allows(eligibleIntro: trialEligibility(for: product),
            billing: billingContext, captured: current, current: current)
    }

    func heldTrialOffer(for product: Product) -> TrialOfferSummary? {
        let current = TrialPurchaseSnapshot(actor: AuthStore.shared.userID,
            revision: AuthStore.shared.syncSessionRevision, org: WorkspaceContext.selectedOrgID)
        guard let captured = preparedTrialSnapshot,
              TrialPurchaseAdmission.allowsHeld(preparedTrialReservation, product: product.id,
                captured: captured, current: current) else { return nil }
        return preparedTrialReservation?.trialOffer
    }

    func canCheckTrialAvailability(for product: Product) -> Bool {
        guard Config.useLiveBackend && !Config.isUITesting else { return false }
        return trialEligibility(for: product) != false && AuthStore.shared.isSignedIn && AuthStore.shared.isIdentified
            && AuthStore.shared.userID.flatMap(UUID.init(uuidString:)) != nil
            && billingContext?.orgID == WorkspaceContext.selectedOrgID
            && billingContext?.role == "owner" && billingContext?.canManageSubscription == true
    }

    private func trialRegionSupported(for product: Product, captured: TrialPurchaseSnapshot) async -> Bool {
        let storefront = await Storefront.current
        let current = TrialPurchaseSnapshot(actor: AuthStore.shared.userID,
            revision: AuthStore.shared.syncSessionRevision, org: WorkspaceContext.selectedOrgID)
        return captured == current && TrialPurchaseAdmission.supportsTrialRegion(
            country: storefront?.countryCode, currency: product.priceFormatStyle.currencyCode)
    }

    private func validateHeldTrialPurchase(productID: String, captured: TrialPurchaseSnapshot,
                                          expectedReservationID: UUID?) async throws -> TrialPurchaseReservation {
        guard let api, let owner = captured.actor.flatMap(UUID.init(uuidString:)), let org = captured.org else { throw APIError.notConfigured }
        let before = TrialPurchaseSnapshot(actor: AuthStore.shared.userID,
            revision: AuthStore.shared.syncSessionRevision, org: WorkspaceContext.selectedOrgID)
        guard before == captured else { throw CloudSyncError.identityChanged }
        let held = try await api.prepareTrialPurchase(orgID: org, productID: productID, appAccountToken: owner)
        let current = TrialPurchaseSnapshot(actor: AuthStore.shared.userID,
            revision: AuthStore.shared.syncSessionRevision, org: WorkspaceContext.selectedOrgID)
        guard TrialPurchaseAdmission.allowsHeld(held, product: productID, captured: captured, current: current),
              expectedReservationID.map({ held.reservationId == $0 }) ?? true else { throw CloudSyncError.identityChanged }
        return held
    }

    private func validateCurrentHeldTrialPurchase(_ held: TrialPurchaseReservation,
                                                  captured: TrialPurchaseSnapshot) async throws -> Bool {
        guard let api else { throw APIError.notConfigured }
        let fresh = try await api.billingContext()
        let current = TrialPurchaseSnapshot(actor: AuthStore.shared.userID,
            revision: AuthStore.shared.syncSessionRevision, org: WorkspaceContext.selectedOrgID)
        return TrialPurchaseAdmission.matchesFreshHold(held, billing: fresh, captured: captured, current: current)
    }

    /// Explicit user action only. A failed/uncertain response is never retried
    /// here, and the original workspace intent is kept for receipt recovery.
    func checkTrialAvailability(_ product: Product, expectedOrgID: UUID?) async {
        guard !isPurchasing, !isRestoring else { return }
        isPurchasing = true; lastError = nil; notice = nil
        defer { isPurchasing = false }
        let captured = TrialPurchaseSnapshot(actor: AuthStore.shared.userID,
            revision: AuthStore.shared.syncSessionRevision, org: expectedOrgID)
        do {
            guard let owner = captured.actor.flatMap(UUID.init(uuidString:)), let org = expectedOrgID,
                  AuthStore.shared.isSignedIn, AuthStore.shared.isIdentified, let api else { throw APIError.notConfigured }
            let fresh = try await api.billingContext()
            let eligible = await product.subscription?.isEligibleForIntroOffer
            let current = TrialPurchaseSnapshot(actor: AuthStore.shared.userID,
                revision: AuthStore.shared.syncSessionRevision, org: WorkspaceContext.selectedOrgID)
            guard current == captured, fresh.orgID == org, fresh.role == "owner", fresh.canManageSubscription else {
                throw CloudSyncError.identityChanged
            }
            billingContext = fresh; billingError = nil
            if let eligible { introOfferEligible[product.id] = eligible }
            else { introOfferEligible.removeValue(forKey: product.id) }
            guard eligible == true, hasSevenDayTrial(for: product) else {
                lastError = eligible == false
                    ? "Apple does not confirm trial eligibility for this account. No reservation or purchase has started. You can choose a paid subscription with a separate Subscribe with Apple tap."
                    : "Apple trial eligibility could not be confirmed. No reservation or purchase has started. Refresh or Restore before checking again."
                return
            }
            guard await trialRegionSupported(for: product, captured: captured) else {
                lastError = TrialPurchaseAdmission.unsupportedRegionMessage; return
            }
            _ = try PurchaseWorkspaceBindingStore.prepare(owner: owner, productID: product.id, orgID: org)
            let held = try await validateHeldTrialPurchase(productID: product.id, captured: captured,
                expectedReservationID: heldTrialOffer(for: product) == nil ? nil : preparedTrialReservation?.reservationId)
            preparedTrialReservation = held; preparedTrialSnapshot = captured
            introOfferEligible[product.id] = true
            await refreshBillingContext()
            let finished = TrialPurchaseSnapshot(actor: AuthStore.shared.userID,
                revision: AuthStore.shared.syncSessionRevision, org: WorkspaceContext.selectedOrgID)
            guard finished == captured else { return }
            notice = "Trial availability is reserved for this plan and workspace. Review the included usage and Apple's confirmation before continuing. No Apple billing has started."
        } catch {
            let current = TrialPurchaseSnapshot(actor: AuthStore.shared.userID,
                revision: AuthStore.shared.syncSessionRevision, org: WorkspaceContext.selectedOrgID)
            guard current == captured else { return }
            lastError = Self.message(for: error, fallback: "Trial availability could not be confirmed. A reservation may still be pending. No Apple billing has started. Restore or explicitly check this same plan again; no reservation is automatically released or restarted.")
        }
    }

    private func validateTrialPurchase(eligibleIntro: Bool?, captured: TrialPurchaseSnapshot) async throws -> Bool {
        guard let api else { throw APIError.notConfigured }
        let fresh = try await api.billingContext()
        let current = TrialPurchaseSnapshot(actor: AuthStore.shared.userID,
            revision: AuthStore.shared.syncSessionRevision, org: WorkspaceContext.selectedOrgID)
        return TrialPurchaseAdmission.allows(eligibleIntro: eligibleIntro, billing: fresh,
            captured: captured, current: current)
    }

    func refreshBillingContext() async {
        let actor = AuthStore.shared.userID, revision = AuthStore.shared.syncSessionRevision
        let selectedOrg = WorkspaceContext.selectedOrgID
        billingRefreshGeneration &+= 1
        let generation = billingRefreshGeneration
        billingContext = nil
        billingError = nil
        do {
            guard let api else { throw APIError.notConfigured }
            let value = try await api.billingContext()
            guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision,
                  WorkspaceContext.selectedOrgID == selectedOrg,
                  billingRefreshGeneration == generation else { return }
            billingContext = value; billingError = nil
        } catch {
            guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision,
                  WorkspaceContext.selectedOrgID == selectedOrg,
                  billingRefreshGeneration == generation else { return }
            billingContext = nil
            billingError = "We couldn’t confirm this workspace’s billing permissions. Refresh before subscribing. Restore and Apple subscription management remain available."
        }
    }

    // MARK: - Buying

    func purchase(_ product: Product, expectedOrgID: UUID?, continuingHeldTrial: Bool = false) async {
        guard !isPurchasing else { return }
        let operationActor = AuthStore.shared.userID, operationRevision = AuthStore.shared.syncSessionRevision
        isPurchasing = true
        lastError = nil
        notice = nil
        defer { isPurchasing = false }

        // A live purchase must have a current workspace identity before Apple
        // confirms it. A stale ID after sign-out must never bind a new purchase.
        if Config.useLiveBackend && !Config.isUITesting {
            guard await AuthStore.validAccessToken() != nil, AuthStore.shared.isSignedIn,
                  AuthStore.shared.userID.flatMap(UUID.init(uuidString:)) != nil else {
                lastError = "Connect to Rendprop before subscribing so the plan is linked to your workspace. Nothing has been purchased."
                return
            }
        }
        guard AuthStore.shared.userID == operationActor, AuthStore.shared.syncSessionRevision == operationRevision else { return }
        // Await discovery even if the products rendered before StoreKit finished
        // its launch sweep. An existing subscription must be checked first.
        let existingConfirmed = await refreshEntitlements()
        guard AuthStore.shared.userID == operationActor, AuthStore.shared.syncSessionRevision == operationRevision else { return }
        if activeProductID != nil, !existingConfirmed, Config.useLiveBackend && !Config.isUITesting {
            lastError = "Your existing Apple subscription must be restored to its original Rendprop account and workspace before changing plans. Nothing has been purchased."
            return
        }
        let actor = operationActor, identityRevision = operationRevision
        var preparedBinding: PurchaseWorkspaceBindingStore.Binding?
        var createdBinding = false
        // Captured before any await: a button offering a held trial cannot
        // silently become a paid purchase when Apple's eligibility changes.
        let heldAtTap = continuingHeldTrial ? preparedTrialReservation : nil
        var retainTrialBinding = continuingHeldTrial
        if Config.useLiveBackend && !Config.isUITesting {
            guard let owner = actor.flatMap(UUID.init(uuidString:)), let api else { return }
            do {
                let context = try await api.billingContext()
                guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == identityRevision,
                      let expectedOrgID, WorkspaceContext.selectedOrgID == expectedOrgID, context.orgID == expectedOrgID else {
                    lastError = "Your workspace changed. Refresh the plan screen before subscribing. Nothing has been purchased."
                    return
                }
                guard context.canManageSubscription else { lastError = context.unavailableMessage; return }
                if let activeProductID {
                    let previous = try PurchaseWorkspaceBindingStore.resolve(tokenOwner: activeBillingOwner, currentOwner: owner, productID: activeProductID)
                    let serverMatches = activeOriginalTransactionID.map { context.originalTransactionIDs?.contains($0) == true } == true
                    guard previous?.orgID == context.orgID || (previous == nil && serverMatches) else {
                        lastError = "Your Apple subscription belongs to another workspace. Return to that workspace before changing its plan, or use Manage subscription below. Nothing has been purchased."
                        return
                    }
                }
                createdBinding = try PurchaseWorkspaceBindingStore.prepare(owner: owner, productID: product.id, orgID: context.orgID)
                preparedBinding = .init(owner: owner, productID: product.id, orgID: context.orgID)
            } catch {
                guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == identityRevision else { return }
                lastError = "This subscription’s workspace couldn’t be confirmed. Refresh this screen, or manage your existing Apple subscription below. Nothing has been purchased."
                return
            }
        }
        // Eligibility may have changed since the paywall loaded. Recheck it
        // with Apple, then fetch fresh server authority before Apple's sheet.
        if Config.useLiveBackend && !Config.isUITesting, hasFreeIntroductoryOffer(for: product) {
            let captured = TrialPurchaseSnapshot(actor: actor, revision: identityRevision, org: expectedOrgID)
            let storeEligibility = await product.subscription?.isEligibleForIntroOffer
            let eligible: Bool? = storeEligibility == true && !hasSevenDayTrial(for: product) ? nil : storeEligibility
            let current = TrialPurchaseSnapshot(actor: AuthStore.shared.userID,
                revision: AuthStore.shared.syncSessionRevision, org: WorkspaceContext.selectedOrgID)
            guard captured == current else {
                lastError = "Your account or workspace changed. Refresh before subscribing. No Apple billing has started."
                return
            }
            do {
                if continuingHeldTrial || eligible == true {
                    retainTrialBinding = true
                    guard eligible == true, let heldAtTap,
                          TrialPurchaseAdmission.allowsHeld(heldAtTap, product: product.id,
                            captured: preparedTrialSnapshot ?? captured, current: current) else {
                        lastError = "Trial eligibility changed or the reservation is not confirmed. No Apple billing has started. Refresh or Restore, then explicitly check trial availability or choose a paid subscription."
                        return
                    }
                    guard await trialRegionSupported(for: product, captured: captured) else {
                        lastError = TrialPurchaseAdmission.unsupportedRegionMessage; return
                    }
                    // A replay confirms the same durable hold; it cannot
                    // release, replace, or mint another reservation.
                    let held = try await validateHeldTrialPurchase(productID: product.id, captured: captured,
                        expectedReservationID: heldAtTap.reservationId)
                    guard held == heldAtTap else { throw SubscriptionBillingContext.TrialPresentationError.invalidResponse }
                    let finalEligibility = await product.subscription?.isEligibleForIntroOffer
                    guard finalEligibility == true, hasSevenDayTrial(for: product) else {
                        lastError = "Apple no longer confirms this trial. No purchase has started. Refresh or Restore before choosing an explicit paid subscription. Your reservation is retained."
                        return
                    }
                    guard await trialRegionSupported(for: product, captured: captured) else {
                        lastError = TrialPurchaseAdmission.unsupportedRegionMessage; return
                    }
                    // Last await before the sheet: a converted hold or changed
                    // owner authority cannot be replaced by cached terms.
                    // Apple and server state remain independent observations.
                    guard try await validateCurrentHeldTrialPurchase(held, captured: captured) else {
                        throw SubscriptionBillingContext.TrialPresentationError.invalidResponse
                    }
                } else {
                    guard try await validateTrialPurchase(eligibleIntro: eligible, captured: captured) else {
                        throw SubscriptionBillingContext.TrialPresentationError.invalidResponse
                    }
                }
            } catch {
                if !retainTrialBinding, createdBinding, let binding = preparedBinding {
                    PurchaseWorkspaceBindingStore.discardUnpurchased(owner: binding.owner, productID: binding.productID, orgID: binding.orgID)
                }
                guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == identityRevision,
                      WorkspaceContext.selectedOrgID == expectedOrgID else { return }
                lastError = retainTrialBinding ? "The same trial reservation could not be confirmed. No Apple purchase has started. The reservation is retained; Restore or explicitly check this same plan again." : TrialPurchaseAdmission.unavailableMessage
                return
            }
        }
        guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == identityRevision,
              (!Config.useLiveBackend || Config.isUITesting || WorkspaceContext.selectedOrgID == expectedOrgID) else { return }
        PaywallEvents.track("purchase_started", product: product)

        let result: Product.PurchaseResult
        do {
            let options: Set<Product.PurchaseOption> = actor.flatMap(UUID.init(uuidString:)).map { [.appAccountToken($0)] } ?? []
            result = try await product.purchase(options: options)
        } catch {
            // `.userCancelled` can also arrive as a thrown StoreKitError.
            if Self.isCancellation(error) {
                if !retainTrialBinding, createdBinding, let binding = preparedBinding {
                    PurchaseWorkspaceBindingStore.discardUnpurchased(owner: binding.owner, productID: binding.productID, orgID: binding.orgID)
                }
                return
            }
            guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == identityRevision else { return }
            let message = Self.message(for: error, fallback: retainTrialBinding ? "Apple's purchase result could not be confirmed. Your reservation and workspace binding are retained. Restore purchases before explicitly continuing; no reservation is automatically released or restarted." : "That purchase didn't go through. Please try again.")
            lastError = message
            PaywallEvents.track("purchase_failed", product: product, extra: ["reason": "storekit"])
            return
        }

        guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == identityRevision else { return }
        switch result {
        case .success(let verification):
            let ok = await handle(verification, event: "purchase")
            if ok {
                await refreshIntroEligibility()
                guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == identityRevision else { return }
                if notice == nil { notice = "Your plan is active. Manage or cancel it in Settings → Plan & usage." }
                PaywallEvents.track("purchase_completed", product: product)
            } else {
                PaywallEvents.track("purchase_failed", product: product, extra: ["reason": "sync"])
            }
        case .pending:
            // Ask to Buy / Strong Customer Authentication. Nothing failed —
            // somebody else has to approve it, and it will arrive through
            // `Transaction.updates`.
            notice = "Your request is awaiting Apple's approval. Service activates after Apple and Rendprop verify it. Any trial reservation and its workspace binding are retained; you can close this."
            PaywallEvents.track("purchase_failed", product: product, extra: ["reason": "pending"])
        case .userCancelled:
            if !retainTrialBinding, createdBinding, let binding = preparedBinding {
                PurchaseWorkspaceBindingStore.discardUnpurchased(owner: binding.owner, productID: binding.productID, orgID: binding.orgID)
            }
            break
        @unknown default:
            lastError = retainTrialBinding ? "Apple's purchase result is unresolved. Your trial reservation is retained. Restore purchases before explicitly continuing; it is not automatically released or restarted." : "That purchase didn't finish. Please try again."
            PaywallEvents.track("purchase_failed", product: product, extra: ["reason": "unknown"])
        }
    }

    /// Restore: ask the App Store to refresh this device's transactions, then
    /// re-read entitlements. `AppStore.sync()` prompts for the Apple ID
    /// password, so it belongs on an explicit "Restore purchases" tap only.
    func restore() async {
        guard !isRestoring else { return }
        let actor = AuthStore.shared.userID, revision = AuthStore.shared.syncSessionRevision
        isRestoring = true
        lastError = nil
        notice = nil
        defer { isRestoring = false }

        PaywallEvents.track("restore")

        do {
            try await AppStore.sync()
        } catch {
            if Self.isCancellation(error) { return }
            guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision else { return }
            lastError = Self.message(for: error, fallback: "We couldn't reach the App Store. Please try again.")
            return
        }
        guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision else { return }
        let confirmed = await refreshEntitlements()
        guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision else { return }
        if activePlan == nil {
            notice = "No subscription found on this Apple ID."
        } else if confirmed && unsyncedCount == 0 && notice == nil {
            notice = "Your subscription is restored."
        }
        await refreshIntroEligibility()
    }

    /// Apple's own subscription-management sheet — the only correct place to
    /// cancel or switch plans (3.1.2 / the App Store's rules on cancellation).
    func manageSubscriptions() async {
        let actor = AuthStore.shared.userID, revision = AuthStore.shared.syncSessionRevision
        guard let scene = Self.activeWindowScene() else {
            lastError = "We couldn't open the App Store subscription settings. Open Settings → Apple ID → Subscriptions."
            return
        }
        do {
            try await AppStore.showManageSubscriptions(in: scene)
            guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision else { return }
            await refreshEntitlements()
            guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision else { return }
            await refreshIntroEligibility()
        } catch {
            guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision else { return }
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
    @discardableResult func refreshEntitlements() async -> Bool {
        let identity = "\(AuthStore.shared.userID ?? "none"):\(AuthStore.shared.syncSessionRevision)"
        var found: [VerificationResult<Transaction>] = []
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement else { continue }
            guard RendpropProducts.plan(for: transaction.productID) != nil else { continue }
            if transaction.revocationDate != nil { continue }
            if let expiry = transaction.expirationDate, expiry <= Date() { continue }
            found.append(entitlement)
        }

        guard identity == "\(AuthStore.shared.userID ?? "none"):\(AuthStore.shared.syncSessionRevision)" else { return false }
        guard !found.isEmpty else {
            // Nothing active on this Apple ID. Do NOT write "free" anywhere —
            // the org's plan may be a manual/comped one the server owns.
            activePlan = nil
            activeProductID = nil
            activeOriginalTransactionID = nil
            activeExpiresAt = nil
            return false
        }

        // Show the local answer straight away (highest tier wins if there is
        // more than one live entitlement) so the paywall can mark "Your plan"
        // without waiting on a round trip. Still display only.
        applyLocalPlan(from: found)

        var confirmed = true
        for entitlement in found {
            guard case .verified(let transaction) = entitlement else { continue }
            // A different app account or session must reconfirm with the server.
            if syncedThisSession.contains("\(identity):\(transaction.id)"), unsynced[transaction.id] == nil { continue }
            if !(await handle(entitlement, event: "entitlement")) { confirmed = false }
        }
        return confirmed && identity == "\(AuthStore.shared.userID ?? "none"):\(AuthStore.shared.syncSessionRevision)"
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
        activeBillingOwner = best.transaction.appAccountToken
        activeProductID = best.transaction.productID
        activeOriginalTransactionID = String(best.transaction.originalID)
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
        let actor = AuthStore.shared.userID, revision = AuthStore.shared.syncSessionRevision
        let signedTransaction = verification.jwsRepresentation
        let signedRenewalInfo = await renewalInfoJWS(forProductID: transaction.productID)

        guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision else { return false }
        let bindingOwner = transaction.appAccountToken
        var expectedOrgID: UUID?
        do {
            expectedOrgID = try PurchaseWorkspaceBindingStore.resolve(tokenOwner: bindingOwner,
                currentOwner: actor.flatMap(UUID.init(uuidString:)), productID: transaction.productID)?.orgID
            if expectedOrgID == nil, Config.useLiveBackend && !Config.isUITesting {
                guard let api else { throw APIError.notConfigured }
                let context = try await api.billingContext()
                guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision else { return false }
                guard context.originalTransactionIDs?.contains(String(transaction.originalID)) == true else {
                    lastError = "This Apple subscription is not linked to the selected workspace. Choose its original workspace and restore. If the purchase is still pending on your other device, open Rendprop there first."
                    return false
                }
                expectedOrgID = context.orgID
            }
        } catch {
            guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision else { return false }
            lastError = "Your purchase’s saved workspace needs recovery. It has not been discarded. Contact support before changing accounts."
            return false
        }
        let pending = PendingSync(transaction: transaction,
                                  signedTransaction: signedTransaction,
                                  signedRenewalInfo: signedRenewalInfo, expectedOrgID: expectedOrgID)
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

        let actor = AuthStore.shared.userID, revision = AuthStore.shared.syncSessionRevision
        do {
            let result = try await api.syncEntitlement(signedTransaction: pending.signedTransaction,
                                                       signedRenewalInfo: pending.signedRenewalInfo,
                                                       expectedOrgID: pending.expectedOrgID)
            guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision else {
                remember(pending)
                return false
            }
            applyServerPlan(result, productID: pending.transaction.productID)
            if result.servingActivation?.available == false {
                notice = ServingActivationSummary.pendingExplanation
            }
            // ONLY now. Before this line, a crash or a dead network leaves the
            // transaction with StoreKit, which is exactly what we want.
            await pending.transaction.finish()
            guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision else { return false }
            syncedThisSession.insert("\(actor ?? "none"):\(revision):\(pending.transaction.id)")
            forget(pending.transaction.id)
            lastError = nil
            NotificationCenter.default.post(name: .rendpropPlanChanged, object: nil)
            return true
        } catch {
            remember(pending)
            guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision else { return false }
            let apiError = error as? APIError
            if apiError?.isUnauthorized == true {
                lastError = "Sign in to finish turning on your plan. Your purchase is safe — nothing is lost."
            } else if apiError?.code == "sandbox_testing_required" {
                lastError = "Your test purchase is saved. This workspace needs authorized testing access before it can activate a test subscription. Once access is enabled, tap Restore purchases."
            } else if let apiError, case .server(let status, _, _) = apiError, status == 409 || status == 403 {
                lastError = "Your Apple purchase is saved, but this workspace cannot activate it. Return to the workspace you selected when subscribing, then tap Restore purchases. Manage or cancel the subscription with Apple if needed."
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
