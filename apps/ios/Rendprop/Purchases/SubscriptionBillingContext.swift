import Foundation

/// Current funded photo admissions and a separate balance for other AI work.
/// An absent package preserves legacy and private-testing displays. These
/// counters describe the server's interval; they never authorize a purchase.
struct ServingPhotoPackageSummary: Codable, Hashable, Sendable {
    struct Admissions: Codable, Hashable, Sendable {
        let cap: Int
        let used: Int
        let remaining: Int
        var isValid: Bool {
            (0...10_000).contains(cap) && (0...cap).contains(used) && remaining == cap - used
        }
    }
    struct OtherAI: Codable, Hashable, Sendable {
        let capCents: Int
        let usedCents: Int
        let remainingCents: Int
        var isValid: Bool {
            (0...100_000_000).contains(capCents) && (0...capCents).contains(usedCents)
                && remainingCents == capCents - usedCents
        }
    }
    let orgId: UUID
    let startsAt: String
    let endsAt: String
    let policy: String
    let tariffVersion: String
    let photoAdmissions: Admissions
    let photoHoldCents: Double
    let protectedPhotoCents: Int
    let otherAi: OtherAI

    func checked(org: UUID, now: Date = Date()) -> Self? {
        guard orgId == org,
              policy == "one-gemini-1k-4096-plus-one-kontext-20261007",
              tariffVersion == "published-standard-20261006",
              let start = TrialUsageSummary.date(startsAt), let end = TrialUsageSummary.date(endsAt),
              start <= now, end > now, end > start,
              photoAdmissions.isValid, otherAi.isValid,
              photoHoldCents == 35.1296,
              protectedPhotoCents == Int(ceil(Double(photoAdmissions.cap) * 35.1296)) else { return nil }
        return self
    }
    var rows: [(title: String, value: String)] {
        [("AI photo edits", "\(photoAdmissions.used) of \(photoAdmissions.cap) used · \(photoAdmissions.remaining) remaining"),
         ("Other AI tools", otherAi.capCents == 0 ? "Not included" : "\(otherAi.remainingCents * 100 / otherAi.capCents)% available")]
    }
    static let explanation = "Photo edits and the budget for other AI tools are separate. These are the workspace's actual configured limits for this interval, shared on iPhone and Studio. An accepted photo edit uses an admission even if generation fails. Work is admitted by the server. Pull down to refresh."
}

/// The shared AI budget the server admits work against in ceiling serving
/// mode (`/me` → `serving_envelope`, from `serving_envelope_state`). Cents are
/// server numbers rounded to 2 dp; `held` is provider liability on holds not
/// yet ledgered. Absent on funded-mode servers and on any RPC failure — the
/// screen then shows the meters alone. Never a local permission to start work.
struct ServingEnvelopeSummary: Codable, Hashable, Sendable {
    struct Pool: Codable, Hashable, Sendable {
        let capCents: Double?
        let spentCents: Double?
        let startsAt: String?
        let endsAt: String?
    }
    let kind: String?
    let ceilingCents: Double?
    let spentCents: Double?
    let heldCents: Double?
    let availableCents: Double?
    let periodStart: String?
    let periodEnd: String?
    let window: String?
    let pool: Pool?

    enum CodingKeys: String, CodingKey {
        case kind, ceilingCents, spentCents, heldCents, availableCents, periodStart, periodEnd, window, pool
    }
    init(kind: String?, ceilingCents: Double?, spentCents: Double?, heldCents: Double?, availableCents: Double?,
         periodStart: String?, periodEnd: String?, window: String?, pool: Pool?) {
        self.kind = kind; self.ceilingCents = ceilingCents; self.spentCents = spentCents; self.heldCents = heldCents
        self.availableCents = availableCents; self.periodStart = periodStart; self.periodEnd = periodEnd
        self.window = window; self.pool = pool
    }
    /// Lenient by design: this block is additive to /me, so a field of the
    /// wrong type (or a non-object value) yields an empty summary that
    /// `checked()` rejects, never a decoding error that blanks Plan & usage.
    init(from decoder: Decoder) throws {
        guard let keys = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init(kind: nil, ceilingCents: nil, spentCents: nil, heldCents: nil, availableCents: nil,
                      periodStart: nil, periodEnd: nil, window: nil, pool: nil)
            return
        }
        func text(_ key: CodingKeys) -> String? { (try? keys.decodeIfPresent(String.self, forKey: key)) ?? nil }
        func number(_ key: CodingKeys) -> Double? {
            if let value = (try? keys.decodeIfPresent(Double.self, forKey: key)) ?? nil { return value }
            if let value = text(key), let parsed = Double(value.trimmingCharacters(in: .whitespaces)) { return parsed }
            return nil
        }
        self.init(kind: text(.kind), ceilingCents: number(.ceilingCents), spentCents: number(.spentCents),
                  heldCents: number(.heldCents), availableCents: number(.availableCents),
                  periodStart: text(.periodStart), periodEnd: text(.periodEnd), window: text(.window),
                  pool: (try? keys.decodeIfPresent(Pool.self, forKey: .pool)) ?? nil)
    }

    /// Only a self-consistent envelope is drawn; anything odd hides the rows
    /// rather than showing a wrong dollar figure.
    func checked() -> Self? {
        // Sponsored testers are unlimited: there is no budget to draw.
        guard let kind, !kind.isEmpty, kind != "sponsored", let ceilingCents, let spentCents, let heldCents, let availableCents,
              ceilingCents.isFinite, spentCents.isFinite, heldCents.isFinite, availableCents.isFinite,
              ceilingCents >= 0, ceilingCents <= 100_000_000,
              spentCents >= 0, spentCents <= 100_000_000,
              heldCents >= 0, heldCents <= 100_000_000, availableCents >= 0,
              availableCents <= ceilingCents + 0.01,
              abs(availableCents - max(0, ceilingCents - spentCents - heldCents)) <= 0.02 else { return nil }
        if let pool {
            guard let cap = pool.capCents, let spent = pool.spentCents, cap.isFinite, spent.isFinite,
                  cap >= 0, cap <= 100_000_000, spent >= 0, spent <= 100_000_000 else {
                // A bad pool hides only the pool line, never the customer's own budget.
                return Self(kind: kind, ceilingCents: ceilingCents, spentCents: spentCents, heldCents: heldCents,
                            availableCents: availableCents, periodStart: periodStart, periodEnd: periodEnd,
                            window: window, pool: nil)
            }
        }
        return self
    }
    /// Spend and holds round up, what is left rounds down — the screen never
    /// promises a cent the server would refuse.
    static func money(_ cents: Double, up: Bool = true) -> String {
        Money(cents: Int(max(0, cents).rounded(up ? .up : .down))).formatted
    }
    var periodEndDate: Date? { periodEnd.flatMap(TrialUsageSummary.date) }
    var isFree: Bool { kind == "free" }
    var isTrial: Bool { kind == "trial" }
    var isGrace: Bool { kind == "grace" }
    var budgetTitle: String {
        switch kind {
        case "free": return "Free AI allowance"
        case "trial": return "Free-trial AI budget"
        case "grace": return "AI budget (billing grace)"
        default: return "AI budget"
        }
    }
    var budgetValue: String {
        let used = spentCents.map { Self.money($0) } ?? "—"
        let avail = availableCents.map { Self.money($0, up: false) } ?? "—"
        let ceiling = ceilingCents.map { Self.money($0, up: false) } ?? "—"
        return "\(used) used · \(avail) available of \(ceiling)"
    }
    /// One line on when the budget resets or ends, by window kind.
    var resetLine: String? {
        if isFree { return "Lifetime allowance for free workspaces. It does not reset; subscribe for a monthly budget." }
        guard let end = periodEndDate else { return nil }
        let when = end.formatted(date: .abbreviated, time: .omitted)
        switch window {
        case "trial_window": return "Trial budget ends \(when)."
        case "apple_grace": return "Billing grace ends \(when). Renew to restore the full budget."
        case "intro_window": return "Trial allowance ends \(when). Your paid subscription starts after the trial unless canceled."
        case "apple_term", "apple_slice": return "Resets \(when) with your subscription period."
        case "calendar_month": return "Resets \(when)."
        default: return "Resets \(when)."
        }
    }
    var poolLine: String? { capacityLine(now: Date()) }
    func capacityLine(now: Date) -> String? {
        guard isTrial else { return nil }
        guard let pool, let cap = pool.capCents, let spent = pool.spentCents,
              cap.isFinite, spent.isFinite, cap > 0, spent >= 0, spent < cap,
              let start = pool.startsAt.flatMap(TrialUsageSummary.date),
              let end = pool.endsAt.flatMap(TrialUsageSummary.date),
              start <= now, end > now, end > start else { return "Trial AI capacity is unavailable right now." }
        return "Trial AI is available until \(end.formatted(date: .abbreviated, time: .omitted)), while trial capacity remains."
    }
    var heldLine: String? {
        guard let heldCents, heldCents > 0 else { return nil }
        return "\(Self.money(heldCents)) is reserved for work still running."
    }
    static let explanation = "Photos, videos and other AI tools share this allowance on iPhone and Studio. Check the available allowance before starting a new edit."
}

/// Recorded Apple subscription identity and usable service are separate.
/// This is fresh workspace-scoped serving authority, not a locally chosen plan.
struct ServingActivationSummary: Codable, Hashable, Sendable {
    enum Authority: String, Codable, Sendable {
        case privateSponsorship = "private_sponsorship", appReview = "app_review"
        case brokerage, existingNonApple = "existing_non_apple", verifiedRetail = "verified_retail"
        case fundedTrial = "funded_trial", unavailable = "subscription_activation_unavailable"
    }
    let orgId: UUID
    let available: Bool
    let funded: Bool
    let authority: Authority
    enum CodingKeys: String, CodingKey { case orgId, rawOrgId = "org_id", available, funded, authority }
    init(orgId: UUID, available: Bool, funded: Bool, authority: Authority) {
        self.orgId = orgId; self.available = available; self.funded = funded; self.authority = authority
    }
    init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        orgId = try keys.decodeIfPresent(UUID.self, forKey: .orgId) ?? keys.decode(UUID.self, forKey: .rawOrgId)
        available = try keys.decode(Bool.self, forKey: .available)
        funded = try keys.decode(Bool.self, forKey: .funded)
        authority = try keys.decode(Authority.self, forKey: .authority)
    }
    func encode(to encoder: Encoder) throws {
        var keys = encoder.container(keyedBy: CodingKeys.self)
        try keys.encode(orgId, forKey: .rawOrgId); try keys.encode(available, forKey: .available)
        try keys.encode(funded, forKey: .funded); try keys.encode(authority, forKey: .authority)
    }
    func checked(org: UUID) -> Self? {
        guard orgId == org else { return nil }
        switch authority {
        case .privateSponsorship, .brokerage, .existingNonApple:
            return available && !funded ? self : nil
        case .appReview, .verifiedRetail, .fundedTrial:
            return available && funded ? self : nil
        case .unavailable:
            return !available && !funded ? self : nil
        }
    }
    func shouldShowPending(plan: String?, recordedTrial: TrialUsageSummary?) -> Bool {
        guard !available else { return false }
        if let recordedTrial { return recordedTrial.status == .active }
        return !["free", "trial"].contains((plan ?? "").lowercased())
    }
    static let pendingTitle = "Service activation pending"
    static let pendingExplanation = "Your Apple subscription is recorded. Rendprop service is still waiting for activation. Restore purchases to check again, or manage your subscription with Apple. Your saved work remains available under your workspace's access and retention terms."
}

/// Server-recorded trial counters. These are a lifetime window, never a paid
/// plan's monthly allowance, and never a local permission to start paid work.
struct TrialUsageCounter: Codable, Hashable, Sendable {
    let used: Int
    let cap: Int
    let remaining: Int
    var isValid: Bool {
        used >= 0 && cap > 0 && cap <= 5 && used <= cap && remaining == cap - used
    }
    var displayValue: String { "\(used) of \(cap) used · \(remaining) remaining" }
}

struct TrialUsageSummary: Codable, Hashable, Sendable {
    enum Status: String, Codable, Sendable { case active, exhausted, expired }
    let orgId: UUID
    let status: Status
    let startsAt: String
    let endsAt: String
    let walkthroughs: TrialUsageCounter
    let photoEdits: TrialUsageCounter
    let publishedListings: TrialUsageCounter
    let uploadBudgetBytes: Int64
    let uploadUsedBytes: Int64
    var endDate: Date? { Self.date(endsAt) }
    func checked(org: UUID) -> Self? {
        guard orgId == org, let start = Self.date(startsAt), let end = endDate, end > start,
              end.timeIntervalSince(start) <= 7 * 24 * 60 * 60,
              walkthroughs.isValid, photoEdits.isValid, publishedListings.isValid,
              walkthroughs.cap <= 1, publishedListings.cap <= 1,
              uploadBudgetBytes > 0, uploadBudgetBytes <= 1_073_741_824,
              uploadUsedBytes >= 0, uploadUsedBytes <= uploadBudgetBytes else { return nil }
        return self
    }
    static func date(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: raw) { return value }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
    var statusLabel: String {
        switch status {
        case .active: return "Trial access"
        case .exhausted: return "Trial allowance used"
        case .expired: return "Trial access ended"
        }
    }
    var uploadSpaceValue: String {
        let remaining = uploadBudgetBytes - uploadUsedBytes
        let remainingLabel = remaining == 0 ? "0 bytes" : ByteCountFormatter.string(fromByteCount: remaining, countStyle: .binary)
        return "\(ByteCountFormatter.string(fromByteCount: uploadUsedBytes, countStyle: .binary)) used · \(remainingLabel) remaining of \(ByteCountFormatter.string(fromByteCount: uploadBudgetBytes, countStyle: .binary))"
    }
    var rows: [(title: String, value: String)] {
        [("Hosted walkthroughs", walkthroughs.displayValue),
         ("AI photo edit credits", photoEdits.displayValue),
         ("Published listings", publishedListings.displayValue),
         ("Trial upload space", uploadSpaceValue)]
    }
    static let explanation = "These trial allowances belong to the account that started the trial in this workspace. The same counters apply on iPhone and Studio. Each allowance is separate and does not reset. Your saved work stays available to view and download under your workspace's access and retention terms. Using your allowance does not change Apple's renewal date."
}

/// A numeric trial promise is displayed only from an enabled server offer.
/// Disabled/absent configuration does not invent a funded trial from StoreKit
/// eligibility, the selected paid plan, or a saved trial's recorded counters.
struct TrialOfferSummary: Codable, Hashable, Sendable {
    let enabled: Bool
    let walkthroughs: Int?
    let photoEdits: Int?
    let publishedListings: Int?
    let maxDays: Int?
    let maxVideoSeconds: Int?
    let uploadBudgetBytes: Int64?
    func checked() -> Self? {
        guard enabled else { return self }
        guard let walkthroughs, let photoEdits, let publishedListings,
              maxDays == 7, let maxVideoSeconds, let uploadBudgetBytes,
              walkthroughs == 1, photoEdits > 0, photoEdits <= 5, publishedListings == 1,
              maxVideoSeconds > 0, maxVideoSeconds <= 90,
              uploadBudgetBytes > 0, uploadBudgetBytes <= 1_073_741_824 else { return nil }
        return self
    }
    var benefitLines: [String] {
        guard enabled, checked() != nil, let walkthroughs, let photoEdits,
              let publishedListings, let maxVideoSeconds else { return [] }
        return ["\(walkthroughs) hosted walkthrough\(walkthroughs == 1 ? "" : "s") from your captured or imported footage",
                "\(photoEdits) AI photo edit credit\(photoEdits == 1 ? "" : "s")",
                "\(publishedListings) distinct published listing\(publishedListings == 1 ? "" : "s")",
                "Each walkthrough up to \(maxVideoSeconds) seconds"]
    }
}

struct SubscriptionBillingContext: Codable, Equatable, Sendable {
    let orgID: UUID
    let orgName: String?
    let role: String
    let canManageSubscription: Bool
    let source: String?
    var contentOrgID: UUID? = nil
    var servingOrgID: UUID? = nil
    var originalTransactionIDs: [String]? = nil
    // Additive top-level /me fields, attached only after current-org validation.
    var trialUsage: TrialUsageSummary? = nil
    var trialOffer: TrialOfferSummary? = nil
    var trialReservation: TrialPurchaseReservation? = nil
    var servingActivation: ServingActivationSummary? = nil
    var planName: String? = nil
    /// Server cost model (2026-10-08). "ceiling": ordinary StoreKit purchases
    /// and Apple's own introductory offer; no server-held trial exists.
    var servingMode: String? = nil
    var isCeilingMode: Bool { servingMode == "ceiling" }
    var showsServicePending: Bool {
        servingActivation?.shouldShowPending(plan: planName, recordedTrial: trialUsage) == true
    }
    enum CodingKeys: String, CodingKey {
        case orgID = "org_id", orgName = "org_name", role
        case canManageSubscription = "can_manage_subscription", source
        case contentOrgID = "content_org_id"
        case servingOrgID = "serving_org_id"
        case originalTransactionIDs = "original_transaction_ids"
    }
    var name: String { orgName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Your workspace" }
    var unavailableMessage: String {
        if role != "owner" && role != "admin" { return "Your workspace owner or admin manages this plan. You can still manage your own Apple subscriptions below." }
        return "This workspace’s plan is managed separately. Contact your workspace administrator before buying another subscription. Your existing Apple subscriptions can be managed below."
    }
    enum TrialPresentationError: Error { case invalidResponse }
    /// Decode the existing explicit billing keys separately from additive
    /// snake-case trial fields, then bind both to the request's workspace.
    static func fromMe(_ data: Data, selectedOrg: UUID?, billingOrg: UUID? = nil, servingOrg: UUID? = nil) throws -> Self {
        struct BillingResponse: Decodable { let billing: SubscriptionBillingContext }
        struct TrialResponse: Decodable {
            struct Org: Decodable { let id: UUID }
            let org: Org?
            let trialUsage: TrialUsageSummary?
            let trialOffer: TrialOfferSummary?
            let trialReservation: TrialPurchaseReservation?
            let servingActivation: ServingActivationSummary?
            let plan: String?
            let servingMode: String?
        }
        var value = try JSONDecoder().decode(BillingResponse.self, from: data).billing
        guard let selectedOrg, (value.contentOrgID ?? value.orgID) == selectedOrg,
              value.orgID == (billingOrg ?? selectedOrg),
              (value.servingOrgID ?? value.orgID) == (servingOrg ?? billingOrg ?? selectedOrg) else { throw TrialPresentationError.invalidResponse }
        let financialOrg = value.servingOrgID ?? value.orgID
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let trial = try decoder.decode(TrialResponse.self, from: data)
        if trial.trialUsage != nil || trial.trialOffer != nil || trial.trialReservation != nil || trial.servingActivation != nil {
            guard trial.org?.id == selectedOrg,
                  trial.trialUsage.map({ $0.checked(org: financialOrg) != nil }) ?? true,
                  trial.trialOffer.map({ $0.checked() != nil }) ?? true,
                  trial.trialReservation.map({ $0.checked(actor: $0.actorId, org: financialOrg, product: $0.productId) != nil }) ?? true,
                  trial.servingActivation.map({ $0.checked(org: financialOrg) != nil }) ?? true else { throw TrialPresentationError.invalidResponse }
        }
        value.trialUsage = trial.trialUsage
        value.trialOffer = trial.trialOffer
        value.trialReservation = trial.trialReservation
        value.servingActivation = trial.servingActivation
        value.planName = trial.plan
        value.servingMode = trial.servingMode
        return value
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

/// A fresh server offer is necessary before starting Apple's introductory
/// billing schedule. This gate does not create or reserve sponsor funding.
struct TrialPurchaseSnapshot: Equatable, Sendable {
    let actor: String?
    let revision: UInt64
    let org: UUID?
    var billingOrg: UUID? = nil
    var purchaseOrg: UUID? { billingOrg ?? org }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.actor == rhs.actor && lhs.revision == rhs.revision && lhs.org == rhs.org && lhs.purchaseOrg == rhs.purchaseOrg
    }
}

/// Cash already committed by the server before Apple's purchase sheet. A hold
/// has no client expiry or release operation: cancellation and an uncertain
/// response cannot make it safe to mint another trial.
struct TrialPurchaseReservation: Codable, Hashable, Sendable {
    let reservationId: UUID
    let actorId: UUID
    let appAccountToken: UUID
    let orgId: UUID
    let productId: String
    let heldAt: String
    let trialOffer: TrialOfferSummary
    func checked(actor: UUID, org: UUID, product: String) -> Self? {
        guard actorId == actor, appAccountToken == actor, orgId == org, productId == product,
              TrialUsageSummary.date(heldAt) != nil,
              trialOffer.enabled, trialOffer.checked() != nil,
              trialOffer.walkthroughs == 1, trialOffer.photoEdits == 5,
              trialOffer.publishedListings == 1 else { return nil }
        return self
    }
    static func decode(_ data: Data, actor: UUID, org: UUID, product: String) throws -> Self {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let value = try decoder.decode(Self.self, from: data)
        guard value.checked(actor: actor, org: org, product: product) != nil else {
            throw SubscriptionBillingContext.TrialPresentationError.invalidResponse
        }
        return value
    }
}

/// Temporary release gate: existing subscription/workspace authority cannot
/// authorize a new charge. A separately admitted held trial is the only live
/// purchase path until per-SKU paid funding admission is implemented.
enum PurchaseDispatchAdmission {
    static let paidUnavailableMessage = "Paid subscriptions are temporarily unavailable. No Apple purchase has started. You can restore purchases or manage an existing subscription below."

    static func allows(liveBackend: Bool, uiTesting: Bool, ceilingMode: Bool = false, verifiedHeldTrial: Bool,
                       captured: TrialPurchaseSnapshot, current: TrialPurchaseSnapshot) -> Bool {
        guard liveBackend && !uiTesting else { return true }
        guard captured == current, current.actor.flatMap(UUID.init(uuidString:)) != nil,
              current.org != nil, current.purchaseOrg != nil else { return false }
        // Ceiling serving mode (2026-10-08): the server meters and caps spend
        // per plan, so an ordinary StoreKit purchase is the live purchase path.
        if ceilingMode { return true }
        return verifiedHeldTrial
    }
}

enum TrialPurchaseAdmission {
    static let unavailableMessage = "Free trials are not available in this workspace yet. No Apple billing has started. Your saved work remains available under your workspace's access and retention terms."
    static let unsupportedRegionMessage = "Funded trials are currently supported only in the United States with a USD subscription. No Apple purchase has started. Any existing reservation remains retained. Restore and subscription management remain available."
    static func supportsTrialRegion(country: String?, currency: String) -> Bool {
        country == "USA" && currency == "USD"
    }
    static func allows(eligibleIntro: Bool?, billing: SubscriptionBillingContext?,
                       captured: TrialPurchaseSnapshot, current: TrialPurchaseSnapshot) -> Bool {
        guard captured == current, current.actor != nil, let org = current.purchaseOrg,
              let eligibleIntro else { return false }
        guard let billing, billing.orgID == org, billing.canManageSubscription else { return false }
        guard eligibleIntro else { return true }
        guard let offer = billing.trialOffer, offer.enabled, offer.checked() != nil else { return false }
        return true
    }
    static func allowsHeld(_ hold: TrialPurchaseReservation?, product: String,
                           captured: TrialPurchaseSnapshot, current: TrialPurchaseSnapshot) -> Bool {
        guard captured == current, let actor = current.actor.flatMap(UUID.init(uuidString:)),
              let org = current.purchaseOrg, let hold else { return false }
        return hold.checked(actor: actor, org: org, product: product) != nil
    }
    static func matchesFreshHold(_ hold: TrialPurchaseReservation, billing: SubscriptionBillingContext?,
                                 captured: TrialPurchaseSnapshot, current: TrialPurchaseSnapshot) -> Bool {
        guard allowsHeld(hold, product: hold.productId, captured: captured, current: current),
              let billing, billing.orgID == current.purchaseOrg, billing.role == "owner", billing.canManageSubscription,
              billing.trialReservation == hold, billing.trialOffer == hold.trialOffer else { return false }
        return true
    }
}

/// Non-secret intent written BEFORE Apple's purchase sheet. StoreKit can
/// redeliver after a restart, so an active-workspace change must not retarget it.
enum PurchaseWorkspaceBindingStore {
    struct Binding: Codable, Equatable {
        let owner: UUID
        let productID: String
        let orgID: UUID
    }
    enum Failure: Error { case unreadable, conflict, storage }
    static func key(owner: UUID, productID: String) -> String {
        "purchase-workspace.v1.\(owner.uuidString.lowercased()).\(productID)"
    }
    static func load(owner: UUID, productID: String, defaults: UserDefaults = .standard) throws -> Binding? {
        guard let data = defaults.data(forKey: key(owner: owner, productID: productID)) else { return nil }
        guard data.count < 4096, let value = try? JSONDecoder().decode(Binding.self, from: data),
              value.owner == owner, value.productID == productID else { throw Failure.unreadable }
        return value
    }
    static func resolve(tokenOwner: UUID?, currentOwner: UUID?, productID: String, defaults: UserDefaults = .standard) throws -> Binding? {
        let original = try tokenOwner.flatMap { try load(owner: $0, productID: productID, defaults: defaults) }
        let current = try currentOwner.flatMap { try load(owner: $0, productID: productID, defaults: defaults) }
        if let original, let current, original.orgID != current.orgID { throw Failure.conflict }
        return original ?? current
    }
    @discardableResult static func prepare(owner: UUID, productID: String, orgID: UUID,
                                          defaults: UserDefaults = .standard) throws -> Bool {
        if let prior = try load(owner: owner, productID: productID, defaults: defaults) {
            guard prior.orgID == orgID else { throw Failure.conflict }
            return false
        }
        let binding = Binding(owner: owner, productID: productID, orgID: orgID)
        defaults.set(try JSONEncoder().encode(binding), forKey: key(owner: owner, productID: productID))
        guard defaults.synchronize(), try load(owner: owner, productID: productID, defaults: defaults) == binding else {
            throw Failure.storage
        }
        return true
    }
    static func discardUnpurchased(owner: UUID, productID: String, orgID: UUID, defaults: UserDefaults = .standard) {
        guard (try? load(owner: owner, productID: productID, defaults: defaults))?.orgID == orgID else { return }
        defaults.removeObject(forKey: key(owner: owner, productID: productID))
    }
}
