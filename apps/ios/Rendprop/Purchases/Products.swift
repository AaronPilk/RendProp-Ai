import Foundation

// MARK: - What Rendprop sells
//
// ONE source of truth for the product ids, the plan they map to, and the
// "what you get" lines. The numbers below are COPIED from
// `services/supabase/migrations/0010_pricing_entitlements_and_spend_ceiling.sql`
// (`plan_entitlements`), which is what the server actually enforces — if that
// table changes, change these in the same commit or the paywall starts lying.
//
// PRICES ARE NOT HERE, ON PURPOSE. Every price the user sees comes from
// StoreKit (`Product.displayPrice`), so it is correct in their currency, on
// their storefront, after any App Store price change — and there is nothing to
// keep in sync. Never hardcode a price string in this app.
//
// `trial` is Apple's 7-day introductory offer on each product, not a product.
// `free` is the lapsed floor (no product). `solo` is a legacy alias of
// `starter` that is never sold.

/// A sellable plan. Raw value === the `orgs.plan` / `plan_entitlements.plan`
/// string the server uses, so `activePlan` and `/me` speak the same language.
enum RendpropPlan: String, CaseIterable, Identifiable, Sendable {
    case starter
    case pro
    case team

    var id: String { rawValue }

    /// Marketing name. Matches App Store Connect's localized display name.
    var displayName: String {
        switch self {
        case .starter: return "Starter"
        case .pro:     return "Pro"
        case .team:    return "Team"
        }
    }

    /// One plain line under the name — who the plan is for.
    var tagline: String {
        switch self {
        case .starter: return "For one agent listing a few homes a month."
        case .pro:     return "For a busy agent shooting every week."
        case .team:    return "For a small team sharing one workspace."
        }
    }

    /// Pro is the one most people should pick. Exactly one plan may say this.
    var isMostPopular: Bool { self == .pro }

    /// Higher = more included. Used to pick which of several live entitlements
    /// to show, never to gate anything.
    var tier: Int {
        switch self {
        case .starter: return 1
        case .pro:     return 2
        case .team:    return 3
        }
    }

    var monthlyProductID: String { "com.rendprop.app.\(rawValue).monthly" }
    var annualProductID: String  { "com.rendprop.app.\(rawValue).annual" }

    func productID(for period: BillingPeriod) -> String {
        switch period {
        case .monthly: return monthlyProductID
        case .annual:  return annualProductID
        }
    }

    /// The server-enforced monthly allowances for this plan.
    var allowances: PlanAllowances {
        switch self {
        // plan_entitlements: renders, photo_edits, reels, aerials, topaz, seats
        case .starter: return PlanAllowances(renders: 8,  photoEdits: 150, reels: 8,  aerials: 2,  topaz: 0, seats: 1)
        case .pro:     return PlanAllowances(renders: 25, photoEdits: 300, reels: 20, aerials: 6,  topaz: 0, seats: 1)
        case .team:    return PlanAllowances(renders: 80, photoEdits: 600, reels: 40, aerials: 15, topaz: 2, seats: 3)
        }
    }

    /// 4–5 short lines for the plan card. Plain words, same nouns Settings →
    /// Plan & usage already uses, so "8 of 8" there matches "8 tours" here.
    var benefits: [String] {
        allowances.benefitLines
    }
}

/// Monthly allowances, straight out of `plan_entitlements`.
struct PlanAllowances: Hashable, Sendable {
    let renders: Int
    let photoEdits: Int
    let reels: Int
    let aerials: Int
    /// Topaz "drone-glide" upscales. 0 means the tier is not included.
    let topaz: Int
    let seats: Int

    var benefitLines: [String] {
        var lines: [String] = [
            "\(renders) tour \(renders == 1 ? "render" : "renders") a month",
            "\(photoEdits) AI photo edits",
            "\(reels) reel clips",
            "\(aerials) aerial \(aerials == 1 ? "intro" : "intros")",
        ]
        if topaz > 0 {
            lines.append("\(topaz) drone-glide upscales · \(seats) seats")
        } else {
            lines.append(seats == 1 ? "1 seat · unlimited tours to share" : "\(seats) seats · unlimited tours to share")
        }
        return lines
    }
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

    /// The badge on the Yearly tab. 12 months for the price of 10 — see the
    /// annual prices in docs/LAUNCH-CONTRACT.md (490 / 990 / 2490).
    static let annualBadge = "2 months free"
}

// MARK: - Product id ⇄ plan

enum RendpropProducts {
    /// App Store Connect subscription group reference name. All six products
    /// live in ONE group so Apple manages upgrades/downgrades for us.
    static let subscriptionGroupReferenceName = "rendprop_plans"

    /// Every product id the app asks StoreKit for, in the order the paywall
    /// shows them.
    static let all: [String] = RendpropPlan.allCases.flatMap {
        [$0.monthlyProductID, $0.annualProductID]
    }

    /// "com.rendprop.app.pro.annual" → .pro. nil for anything we don't sell.
    static func plan(for productID: String) -> RendpropPlan? {
        RendpropPlan.allCases.first {
            $0.monthlyProductID == productID || $0.annualProductID == productID
        }
    }

    /// "com.rendprop.app.pro.annual" → .annual.
    static func period(for productID: String) -> BillingPeriod? {
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
        if raw == "solo" { return .starter }
        return RendpropPlan(rawValue: raw)
    }

    /// True when a `/me` plan string means "there is nothing paid here yet" —
    /// the state that should see an Upgrade button.
    static func isUpgradeable(planName: String?) -> Bool {
        let raw = (planName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch raw {
        case "", "free", "trial", "starter", "solo": return true
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

    /// Shown under a trial button so nobody is surprised by the first charge.
    static let trialDisclosure =
        "Free for 7 days, then the plan price. Cancel any time before it ends and you pay nothing."
}
