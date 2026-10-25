import Foundation
import StoreKit
import UIKit

/// Asks iOS's native "Enjoying Rendprop?" prompt at the two moments a
/// publish actually means something: the first tour that ever goes out, and
/// the third. Apple's own API caps the SYSTEM at three prompts per rolling
/// year, but it never tells the calling app whether one was actually shown —
/// so this keeps its own log in UserDefaults, and is stricter than Apple
/// requires: never twice within 120 days, and never at all under
/// `-uiTesting` (a screenshot run must never trigger a real system sheet).
///
/// NOTE ON THE 1st/3rd RULE COLLIDING WITH THE 120-DAY COOLDOWN: an agent who
/// publishes three tours inside the same busy week hits the "3rd publish"
/// trigger well before the 1st prompt's cooldown clears — that attempt is
/// silently skipped rather than queued or retried later. That's intentional
/// (better to under-ask than to ask twice in one week), but worth knowing if
/// the real-world prompt rate looks lower than the 1st/3rd rule implies.
@MainActor
final class ReviewPrompter {
    static let shared = ReviewPrompter()
    private init() {}

    private enum Storage {
        static let publishCountKey = "review.publishSuccessCount"
        static let lastPromptedAtKey = "review.lastPromptedAt"

        static var publishCount: Int {
            get { UserDefaults.standard.integer(forKey: publishCountKey) }
            set { UserDefaults.standard.set(newValue, forKey: publishCountKey) }
        }

        static var lastPromptedAt: Date? {
            get { UserDefaults.standard.object(forKey: lastPromptedAtKey) as? Date }
            set { UserDefaults.standard.set(newValue, forKey: lastPromptedAtKey) }
        }
    }

    /// The publish counts worth asking at.
    private static let promptedPublishCounts: Set<Int> = [1, 3]
    /// Our own floor, stricter than Apple's 3-per-365-days cap.
    private static let minimumDaysBetweenPrompts = 120
    /// Long enough for the publish success state (haptic + refreshed player)
    /// to be fully on screen first, so the system sheet never covers our own.
    private static let delayAfterSuccess: TimeInterval = 1.5

    /// Call once, right where a tour publish actually succeeds
    /// (`FlythroughDetailView.publishNow()`). Counts the success and, only on
    /// the 1st and 3rd, asks iOS to show the rating prompt a beat later.
    func tourPublished() {
        guard !Config.isUITesting else { return }
        let count = Storage.publishCount + 1
        Storage.publishCount = count
        guard Self.promptedPublishCounts.contains(count), isOutsideCooldown() else { return }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.delayAfterSuccess * 1_000_000_000))
            ReviewPrompter.shared.requestReview()
        }
    }

    private func isOutsideCooldown() -> Bool {
        guard let last = Storage.lastPromptedAt else { return true }
        let days = Calendar.current.dateComponents([.day], from: last, to: Date()).day ?? Int.max
        return days >= Self.minimumDaysBetweenPrompts
    }

    private func requestReview() {
        guard !Config.isUITesting else { return }
        // Same lookup as PurchaseManager.activeWindowScene() — prefer the
        // foreground-active scene, fall back to any window scene rather than
        // failing outright.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        Storage.lastPromptedAt = Date()
        Analytics.track("review_prompt_shown", ["publish_count": String(Storage.publishCount)])
        SKStoreReviewController.requestReview(in: scene)
    }
}

/// External review destinations shown from Settings → Legal & support.
/// `google` stays nil until the owner's Google Business Profile exists; the
/// row that reads it (SettingsView.swift) simply doesn't render until then.
enum ReviewLinks {
    static let google: URL? = nil
}
