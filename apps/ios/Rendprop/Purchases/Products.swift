import Foundation

// MARK: - What Rendprop sells
//
// ONE source of truth for the product ids, the plan they map to, and the
// "what you get" lines. Feature ceilings and seat counts mirror
// `services/supabase/migrations/20261027050000_four_tier_retail_plans.sql`;
// credit amounts are internal TestFlight candidates. They are not customer
// benefits until the server's verified-term wallet grant catalog and combined
// serving policy are active for the exact sold Apple product.
//
// A subscription trial begins only after Apple confirmation and server
// verification. New workspaces start on the free plan. Existing historical
// server trials may retain their original expiry, but are never newly granted
// by this app. Prices come exclusively from StoreKit's Product.displayPrice.

/// A sellable plan. Raw value === the `orgs.plan` / `plan_entitlements.plan`
/// string the server uses, so `activePlan` and `/me` speak the same language.
enum RendpropPlan: String, CaseIterable, Identifiable, Sendable {
    case pro
    case max
    case ultra
    case team

    var id: String { rawValue }

    /// Marketing name. Matches App Store Connect's localized display name.
    var displayName: String {
        switch self {
        case .pro:     return "Pro"
        case .max:     return "Max"
        case .ultra:   return "Ultra"
        case .team:    return "Team"
        }
    }

    /// One plain line under the name — who the plan is for. Real estate keeps
    /// its reviewed wording; every other business type is addressed as its own
    /// trade (a bar is never "an agent listing homes" — industry review P1-3).
    /// Every line stays under 60 characters.
    var tagline: String {
        let space = SpaceType.current
        switch self {
        case .pro:
            return space == .realEstate
                ? "For one agent listing a few homes a month."
                : "For one \(space.businessNoun) shooting a few tours a month."
        case .max:
            return space == .realEstate
                ? "For a busy agent shooting every week."
                : "For a busy \(space.businessNoun) shooting every week."
        case .ultra:  return "For a high-volume creator or small studio."
        case .team:    return "For a small team sharing one workspace."
        }
    }

    /// Exactly one plan may carry this badge.
    var isMostPopular: Bool { self == .max }

    /// Higher = more included. Used to pick which of several live entitlements
    /// to show, never to gate anything.
    var tier: Int {
        switch self {
        case .pro:   return 1
        case .max:   return 2
        case .ultra: return 3
        case .team:  return 4
        }
    }

    // The $49 Starter and $99 Pro Apple identifiers must keep restoring and
    // renewing. Their commercial tiers are now Max and Ultra respectively.
    // Pro at $29.99 therefore needs an entirely new Apple product identifier.
    var monthlyProductID: String {
        switch self {
        case .pro:   return "com.rendprop.app.pro29.monthly"
        case .max:   return "com.rendprop.app.starter.monthly"
        case .ultra: return "com.rendprop.app.pro.monthly"
        case .team:  return "com.rendprop.app.team.monthly"
        }
    }
    var annualProductID: String? {
        switch self {
        case .pro:   return nil // no Pro annual product has ever been issued
        case .max:   return "com.rendprop.app.starter.annual"
        case .ultra: return "com.rendprop.app.pro.annual"
        case .team:  return "com.rendprop.app.team.annual"
        }
    }

    func productID(for period: BillingPeriod) -> String? {
        switch period {
        case .monthly: return monthlyProductID
        case .annual:  return annualProductID
        }
    }

    /// True when this plan's product for `period` is on sale today — i.e. the
    /// app asks StoreKit for it and the paywall may show a price for it.
    /// See `RendpropProducts.notSoldAtLaunch`.
    func isSold(_ period: BillingPeriod) -> Bool {
        guard let productID = productID(for: period) else { return false }
        return !RendpropProducts.notSoldAtLaunch.contains(productID)
    }

    /// The period this plan actually bills at when the paywall's picker is on
    /// `period`: `period` itself when that product is on sale, otherwise the
    /// other one (Team on Yearly → monthly, today). nil only when the plan
    /// sells nothing at all, which no plan does.
    func soldPeriod(for period: BillingPeriod) -> BillingPeriod? {
        if isSold(period) { return period }
        let fallback: BillingPeriod = (period == .annual) ? .monthly : .annual
        return isSold(fallback) ? fallback : nil
    }

    /// Base paid allowances after the introductory week. Feature quantities
    /// are hidden safety ceilings; credits require a verified paid period and
    /// a server ledger grant. These credit numbers are not customer copy.
    var allowances: PlanAllowances {
        switch self {
        case .pro:   return PlanAllowances(credits: 60,  renders: 2,  photoEdits: 50,  reels: 15,  aerials: 1, topaz: 0, seats: 1)
        case .max:   return PlanAllowances(credits: 120, renders: 4,  photoEdits: 100, reels: 30,  aerials: 2, topaz: 0, seats: 1)
        case .ultra: return PlanAllowances(credits: 250, renders: 10, photoEdits: 200, reels: 60,  aerials: 4, topaz: 0, seats: 1)
        case .team:  return PlanAllowances(credits: 600, renders: 25, photoEdits: 400, reels: 150, aerials: 8, topaz: 2, seats: 3)
        }
    }

    /// Short plan-card benefits. The feature quantities above remain server
    /// safety limits. Until the funded retail catalog is live, never advertise
    /// a monthly credit grant that the server cannot mint.
    var benefits: [String] {
        allowances.benefitLines
    }
}

/// Monthly catalog amounts and server safety ceilings.
struct PlanAllowances: Hashable, Sendable {
    let credits: Int
    let renders: Int
    let photoEdits: Int
    let reels: Int
    let aerials: Int
    /// Optional video-quality upscales. 0 means the tier is not included.
    let topaz: Int
    let seats: Int

    /// "2 seats" / "1 seat".
    var seatsPhrase: String { "\(seats) \(seats == 1 ? "seat" : "seats")" }

    var benefitLines: [String] { customerBenefitLines(seats: seats) }

    func customerBenefitLines(seats: Int) -> [String] {
        [
            "AI photo editing with your plan after the trial",
            "Review available AI usage before creating",
            "Create and share tours",
            "\(seats) \(seats == 1 ? "seat" : "seats") in one workspace",
        ]
    }

    static let videoAllowanceExplanation = "Cloud tour renders process existing footage. Publishing a tour video made on your iPhone doesn't use that allowance. Video quality upgrades are separate AI upscales; they improve resolution and detail but don't turn walking footage into a real drone shot. Each AI video shot animates one photo for about 5 seconds. Make a video combines shots into a Listing or Social video; the count is shots, not finished videos. Aerial openings are optional, separately processed clips. Review the provider terms and allow AI processing before creating one."
}

/// How often the subscription bills.
enum BillingPeriod: String, CaseIterable, Identifiable, Sendable {
    case monthly
    case annual

    var id: String { rawValue }

    /// Segmented-control label.
    var pickerLabel: String {
        switch self {
        case .monthly: return "Monthly"
        case .annual:  return "Yearly"
        }
    }

    /// What follows the price on a card: "$49.00/month".
    var priceSuffix: String {
        switch self {
        case .monthly: return "/month"
        case .annual:  return "/year"
        }
    }

    /// One caption under the price.
    var billingNote: String {
        switch self {
        case .monthly: return "Billed every month."
        case .annual:  return "Billed once a year."
        }
    }

    /// Small note on a card that sells only this period while the picker is on
    /// the other one — Team, on the Yearly tab, today.
    var onlyNote: String {
        switch self {
        case .monthly: return "Monthly only"
        case .annual:  return "Yearly only"
        }
    }

    /// The badge on the Yearly tab. 12 months for the price of 10 — see the
    /// annual prices in docs/LAUNCH-CONTRACT.md (490 / 990). It names the plans
    /// it is true for: Team has no yearly product at launch (see
    /// `RendpropProducts.notSoldAtLaunch`), so promising it "2 months free"
    /// would be a lie.
    static let annualBadge = "Billed once a year"
}

// MARK: - Product id ⇄ plan

/// Exact Apple subscription identifiers for Team capacity above the existing
/// three-seat product. These are known for restore, but remain unsold until
/// App Store Connect prices and the server's paid-period catalog are active.
/// An Apple renewal preference never changes the currently verified seat count.
struct TeamSeatVariant: Hashable, Sendable {
    let productID: String
    let seats: Int
    let monthlyCredits: Int

    static let all: [Self] = [
        .init(productID: "com.rendprop.app.team4.monthly", seats: 4, monthlyCredits: 700),
        .init(productID: "com.rendprop.app.team5.monthly", seats: 5, monthlyCredits: 800),
        .init(productID: "com.rendprop.app.team6.monthly", seats: 6, monthlyCredits: 900),
        .init(productID: "com.rendprop.app.team7.monthly", seats: 7, monthlyCredits: 1000),
        .init(productID: "com.rendprop.app.team8.monthly", seats: 8, monthlyCredits: 1100),
        .init(productID: "com.rendprop.app.team9.monthly", seats: 9, monthlyCredits: 1200),
    ]

    static func forProduct(_ productID: String) -> Self? {
        all.first { $0.productID == productID }
    }
}

enum RendpropProducts {
    /// App Store Connect subscription group reference name. Every product
    /// lives in ONE group so Apple manages upgrades/downgrades for us.
    static let subscriptionGroupReferenceName = "rendprop_plans"

    /// Product ids that are DEFINED but NOT SOLD. They still map to their plan
    /// below — an existing (sandbox or production) purchase of one keeps its
    /// entitlement — they are simply never requested from StoreKit and never
    /// shown a price.
    ///
    /// 2026-10-09 — Rendprop sells MONTHLY plans only (owner decision). The
    /// annual products cannot carry the advertised allowances inside the
    /// per-month AI budget (ten monthly prices over twelve months), so none is
    /// offered. Their ids stay mapped below so a stray historical or Sandbox
    /// annual purchase still resolves to its plan; they are never requested
    /// from StoreKit and never shown a price. The products must also be
    /// removed from sale in App Store Connect. The six Team capacity variants
    /// also stay dormant pending exact ASC prices, funded schedules and an
    /// over-capacity downgrade policy.
    static let notSoldAtLaunch: Set<String> = Set(RendpropPlan.allCases.compactMap(\.annualProductID))
        .union(TeamSeatVariant.all.map(\.productID))

    /// True when at least one annual product is on sale. Drives whether the
    /// paywall shows the Monthly / Yearly picker at all.
    static var sellsAnnual: Bool {
        RendpropPlan.allCases.contains { $0.isSold(.annual) }
    }

    /// Every product id the app asks StoreKit for, in the order the paywall
    /// shows them. Ids in `notSoldAtLaunch` are left out: asking the App Store
    /// for a product that isn't on sale just returns nothing.
    static let known: [String] = RendpropPlan.allCases
        .flatMap { [$0.monthlyProductID, $0.annualProductID].compactMap { $0 } }
        + TeamSeatVariant.all.map(\.productID)
    static let all: [String] = known
        .filter { !RendpropProducts.notSoldAtLaunch.contains($0) }

    /// "com.rendprop.app.pro.annual" → .ultra. nil for an id that was never ours.
    /// Deliberately covers `notSoldAtLaunch` ids too: entitlement mapping is
    /// about what somebody already bought, not about what is on sale today.
    static func plan(for productID: String) -> RendpropPlan? {
        if TeamSeatVariant.forProduct(productID) != nil { return .team }
        return RendpropPlan.allCases.first {
            $0.monthlyProductID == productID || $0.annualProductID == productID
        }
    }

    /// "com.rendprop.app.pro.annual" → .annual.
    static func period(for productID: String) -> BillingPeriod? {
        if TeamSeatVariant.forProduct(productID) != nil { return .monthly }
        if RendpropPlan.allCases.contains(where: { $0.annualProductID == productID }) { return .annual }
        if RendpropPlan.allCases.contains(where: { $0.monthlyProductID == productID }) { return .monthly }
        return nil
    }

    /// The plan string (`"pro"`) for a product id — what the server calls it.
    static func planName(for productID: String) -> String? {
        plan(for: productID)?.rawValue
    }

    /// A plan string from anywhere (server `/me`, a StoreKit product id) mapped
    /// onto a sellable plan. `solo` is the legacy alias of `starter`.
    static func plan(fromPlanName raw: String?) -> RendpropPlan? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return nil }
        if raw == "solo" || raw == "starter" { return .max }
        if raw == "legacy_pro" { return .ultra }
        return RendpropPlan(rawValue: raw)
    }

    /// True when a `/me` plan string means "there is nothing paid here yet" —
    /// the state that should see an Upgrade button.
    static func isUpgradeable(planName: String?) -> Bool {
        let raw = (planName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch raw {
        case "", "free", "trial", "starter", "solo", "pro", "max", "legacy_pro", "ultra": return true
        default: return false
        }
    }
}

// MARK: - Legal (App Review 3.1.2 — auto-renewable subscriptions)

enum PaywallLegal {
    /// Apple's standard EULA. 3.1.2 requires a functional link to the terms of
    /// use from the paywall; this is the link Apple names when the app uses the
    /// standard licence agreement rather than a custom one.
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")

    static let privacyURL = URL(string: "https://rendprop.com/privacy")

    /// The one-sentence auto-renew disclosure 3.1.2 requires next to the price.
    static let autoRenewDisclosure =
        "Renews automatically until cancelled. Cancel anytime in Settings → Apple ID → Subscriptions."

    /// Legacy copy retained for old clients; current UI uses the selected
    /// product's localized price in SubscriptionOfferPolicy.disclosure.
    /// Shown under a trial button so nobody is surprised by the first charge.
    /// "At least 24 hours": Apple bills the first period unless the
    /// subscription is cancelled at least a day before the offer ends.
    static let trialDisclosure =
        "Free for 7 days, then the plan price. Cancel at least 24 hours before it ends and you pay nothing."
}
