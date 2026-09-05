import SwiftUI
import StoreKit

// MARK: - Presenting the paywall from anywhere
//
// One sheet, mounted once at the app root (`.paywallHost()` in RendpropApp).
// Every CTA in the app — Settings, the three 402 "Upgrade plan" buttons — calls
// `PaywallRouter.shared.present(reason:)` instead of pushing its own sheet, so
// there is exactly one paywall, one place it can be styled, and no chance of
// two sheets fighting for the same slot.

/// Why the paywall is on screen. Drives one context line and the analytics
/// `reason` prop — nothing else.
enum PaywallReason: Equatable, Sendable {
    /// The user asked for it (Settings → Upgrade plan).
    case upgrade
    /// A 402 from the server: this month's allowance for `feature` is used up.
    /// `feature` is one of the `plan_entitlements` keys — renders, photo_edits,
    /// reels, aerials, drone — or a plain noun the caller passes.
    case quota(feature: String)
    /// The 7-day trial has ended.
    case trialEnded
    /// A tier the current plan does not include at all.
    case featureLocked(String)

    /// The `reason` analytics prop. Never carries user text.
    var analyticsValue: String {
        switch self {
        case .upgrade:              return "upgrade"
        case .quota:                return "quota"
        case .trialEnded:           return "trial_ended"
        case .featureLocked:        return "feature_locked"
        }
    }

    /// One short sentence at the top of the sheet, or nil for a plain upgrade.
    var contextLine: String? {
        switch self {
        case .upgrade:
            return nil
        case .quota(let feature):
            return "You've used all your \(PaywallReason.featureNoun(feature)) this month. Pick a plan to keep going."
        case .trialEnded:
            return "Your free trial has ended. Pick a plan to keep making tours."
        case .featureLocked(let name):
            return "\(name) isn't in your current plan. Pick a plan that includes it."
        }
    }

    /// `plan_entitlements` key → the words Settings → Plan & usage already uses.
    /// Anything unrecognised prints itself rather than pretending.
    static func featureNoun(_ raw: String) -> String {
        switch raw.lowercased() {
        case "renders", "render":         return "tour renders"
        case "photo_edits", "photo_edit": return "photo edits"
        case "reels", "reel":             return "reel clips"
        case "aerials", "aerial":         return "aerial intros"
        case "drone", "topaz":            return "drone-glide upscales"
        case "":                          return "monthly allowance"
        default:                          return raw.replacingOccurrences(of: "_", with: " ")
        }
    }
}

@MainActor
final class PaywallRouter: ObservableObject {
    static let shared = PaywallRouter()

    @Published var isPresented = false
    /// Why it's up. Read by `PaywallView`; set only through `present(reason:)`.
    @Published private(set) var reason: PaywallReason?

    private init() {}

    func present(reason: PaywallReason) {
        self.reason = reason
        isPresented = true
    }

    func dismiss() {
        isPresented = false
    }
}

// MARK: - Analytics seam
//
// P3 owns `Analytics.track`. This file must not depend on it (the two land on
// different branches), so the purchase flow calls a sink that starts nil and
// costs nothing. Wired once at launch, in RendpropApp:
//
//     PaywallEvents.sink = Analytics.externalSink
//
// The names emitted here are exactly the ones in
// docs/LAUNCH-CONTRACT.md § Events: paywall_viewed, purchase_started,
// purchase_completed, purchase_failed, restore. Props are `plan`, `product_id`,
// `period`, `reason` — no PII, ever, and never a price.

@MainActor
enum PaywallEvents {
    static var sink: ((String, [String: String]) -> Void)?

    static func track(_ name: String, _ props: [String: String] = [:]) {
        sink?(name, props)
    }

    /// Convenience for the product-shaped events.
    static func track(_ name: String, product: Product, extra: [String: String] = [:]) {
        var props = extra
        props["product_id"] = product.id
        if let plan = RendpropProducts.planName(for: product.id) { props["plan"] = plan }
        if let period = RendpropProducts.period(for: product.id) { props["period"] = period.rawValue }
        sink?(name, props)
    }
}

// MARK: - Plan-changed broadcast
//
// After the server accepts an entitlement, anything showing the plan is stale.
// `AppModel` has no usage/plan cache to invalidate (Settings loads `/me` into
// its own @State), so the signal is a notification rather than a model call.
//
// OBSERVED BY: SettingsView's "Plan & usage" section (re-runs `loadUsage()`).
// If another screen starts showing the plan, observe this there too.

extension Notification.Name {
    /// Posted on the main actor right after `POST /me/entitlement` succeeds.
    static let rendpropPlanChanged = Notification.Name("RendpropPlanChanged")
}

// MARK: - The host modifier

struct PaywallHostModifier: ViewModifier {
    @ObservedObject private var router = PaywallRouter.shared
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task {
                // Idempotent: starts the Transaction.updates listener once and
                // does the first entitlement check.
                PurchaseManager.shared.start()
            }
            .onChange(of: scenePhase) { phase in
                guard phase == .active else { return }
                // Re-check entitlements and retry any purchase the server
                // hasn't accepted yet (rule 2 in PurchaseManager).
                PurchaseManager.shared.refreshOnForeground()
            }
            .sheet(isPresented: $router.isPresented) {
                PaywallView(reason: router.reason ?? .upgrade)
            }
    }
}

extension View {
    /// Mount the one paywall sheet + the StoreKit lifecycle. Apply ONCE, at the
    /// app root.
    func paywallHost() -> some View {
        modifier(PaywallHostModifier())
    }
}
