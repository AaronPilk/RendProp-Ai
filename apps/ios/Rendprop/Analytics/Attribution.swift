import Foundation
import StoreKit

// MARK: - Attribution (SKAdNetwork)
//
// The ONLY thing in this app that talks to an ad platform, and it does it
// Apple's way: SKAdNetwork postbacks. There is no Meta SDK, no pixel, no IDFA
// and no App Tracking Transparency prompt — the app never asks who you are on
// another app, so it never has to ask permission to.
//
// ── WHAT ACTUALLY HAPPENS ────────────────────────────────────────────────────
//
// Someone taps a Meta ad, installs Rendprop, and the App Store tells iOS which
// ad network to credit. iOS holds a per-install "conversion value" that only
// this app may raise. When the measurement window closes, IOS — not us — sends
// a signed postback to Meta containing that value and no identifier of any
// kind. Meta learns "an install from campaign X reached value 4"; it never
// learns who, and neither do we. That number is what lets Meta optimise for
// subscribers instead of for installs.
//
// ── THE LADDER (docs/LAUNCH-CONTRACT.md §Events) ─────────────────────────────
//
//   0 install · 1 signup · 2 home_created · 3 tour_published
//   4 paywall_viewed · 5 purchase_completed
//   Coarse: 0–1 low · 2–3 medium · 4–5 high
//
// ── THE TWO RULES ────────────────────────────────────────────────────────────
//
// 1. MONOTONIC. A conversion value may only ever go UP. Apple's window resets
//    on each update, and a value that went backwards would tell Meta the person
//    un-subscribed. The high-water mark lives in UserDefaults and every call
//    is filtered through it, so an out-of-order event (a `paywall_viewed`
//    after a purchase, which happens on the manage-subscription path) cannot
//    lower it.
//
// 2. LOCK ONLY AT THE TOP. `lockWindow: true` tells iOS to send the postback
//    immediately instead of waiting out the window. That is right exactly once
//    — at 5, when the person has subscribed and there is nothing better to
//    report — and wrong everywhere else, because locking early throws away
//    every conversion that would have happened later.
//
// iOS 16.0 has only the fine-value API; the coarse value and `lockWindow`
// arrived in 16.1. Both paths are implemented, so a 16.0 device still reports.
enum Attribution {

    /// The ladder. Raw values are the fine conversion values Meta will see.
    enum ConversionStep: Int, CaseIterable, Comparable {
        case install           = 0
        case signup            = 1
        case homeCreated       = 2
        case tourPublished     = 3
        case paywallViewed     = 4
        case purchaseCompleted = 5

        static func < (lhs: ConversionStep, rhs: ConversionStep) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        /// The event name that raises this step, or nil for `install` (which is
        /// posted at launch, not by an event).
        var eventName: String? {
            switch self {
            case .install:           return nil
            case .signup:            return "signup"
            case .homeCreated:       return "home_created"
            case .tourPublished:     return "tour_published"
            case .paywallViewed:     return "paywall_viewed"
            case .purchaseCompleted: return "purchase_completed"
            }
        }

        /// Apple's three-bucket coarse value, which is what gets sent when the
        /// campaign has too little data to justify the fine value.
        @available(iOS 16.1, *)
        var coarse: SKAdNetwork.CoarseConversionValue {
            switch rawValue {
            case 0, 1: return .low
            case 2, 3: return .medium
            default:   return .high
            }
        }

        /// Only the top of the ladder locks the window — see rule 2 above.
        var locksWindow: Bool { self == .purchaseCompleted }
    }

    /// The high-water mark. -1 means "nothing posted yet", which is different
    /// from 0 ("install posted") and must stay different, or the install
    /// postback would be skipped on first launch.
    private static let storageKey = "attribution.conversionValue"

    private static var highWaterMark: Int {
        get {
            let d = UserDefaults.standard
            return d.object(forKey: storageKey) as? Int ?? -1
        }
        set { UserDefaults.standard.set(newValue, forKey: storageKey) }
    }

    /// Post conversion value 0 at launch. Idempotent: on every launch after the
    /// first the high-water mark is already ≥ 0, so nothing is sent.
    ///
    /// (`SKAdNetwork.registerAppForAdNetworkAttribution()` is deprecated as of
    /// iOS 16.0 — posting an initial value is Apple's replacement for it.)
    static func registerInstall() {
        reached(.install)
    }

    /// Raise the conversion value to `step`, if that is a raise.
    ///
    /// Silent no-op when the mark is already at or above `step`, so call sites
    /// do not have to think about ordering — which is the point, since the
    /// events that drive this arrive in whatever order the person taps.
    static func reached(_ step: ConversionStep) {
        guard step.rawValue > highWaterMark else { return }
        highWaterMark = step.rawValue

        if #available(iOS 16.1, *) {
            SKAdNetwork.updatePostbackConversionValue(
                step.rawValue,
                coarseValue: step.coarse,
                lockWindow: step.locksWindow
            ) { error in
                #if DEBUG
                if let error { print("[attribution] \(step.rawValue) failed: \(error.localizedDescription)") }
                else { print("[attribution] fine \(step.rawValue) coarse \(step.coarse) lock \(step.locksWindow)") }
                #endif
            }
        } else {
            // iOS 16.0: fine value only. No coarse bucket, no early lock.
            SKAdNetwork.updatePostbackConversionValue(step.rawValue) { error in
                #if DEBUG
                if let error { print("[attribution] \(step.rawValue) failed: \(error.localizedDescription)") }
                #endif
            }
        }
    }

    /// The bridge from the analytics vocabulary. `Analytics.track` calls this
    /// for every event; the five that map to a rung raise the value and the
    /// rest cost one dictionary lookup.
    ///
    /// Keeping the mapping HERE rather than at the five call sites is what
    /// guarantees the conversion value and the funnel can never drift apart:
    /// there is exactly one way to record that a person got somewhere.
    static func reachedStep(for eventName: String) {
        guard let step = stepsByEvent[eventName] else { return }
        reached(step)
    }

    private static let stepsByEvent: [String: ConversionStep] = {
        var map: [String: ConversionStep] = [:]
        for step in ConversionStep.allCases {
            if let name = step.eventName { map[name] = step }
        }
        return map
    }()
}
