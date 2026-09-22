import Foundation

// MARK: - What a notification can be about

/// Account notification choices shared with Studio.
///
/// The two the pre-prompt promises — leads and renders — are deliberately
/// FIRST: those are the ones a person says yes for, and the copy names exactly
/// them. The other two are quieter account matters that already have in-app
/// surfaces; they are opt-outable individually for the same reason.
enum NotificationCategory: String, CaseIterable, Identifiable {
    case leads
    case renders
    case freeWeekEnding = "free_week_ending"
    case allowanceLow = "allowance_low"
    case uploadStuck = "upload_stuck"
    case firstTourNudge = "first_tour_nudge"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leads:          return "New enquiries"
        case .renders:        return "Renders finished"
        case .freeWeekEnding: return "Free week ending"
        case .allowanceLow:   return "Allowance running low"
        case .uploadStuck:    return "Upload needs attention"
        case .firstTourNudge: return "First tour reminder"
        }
    }

    var blurb: String {
        switch self {
        case .leads:          return "Someone filled in the form on one of your tours."
        case .renders:        return "A tour finished rendering and is ready to publish."
        case .freeWeekEnding: return "Your free week is nearly up."
        case .allowanceLow:   return "You're close to this month's limit on a plan feature."
        case .uploadStuck:    return "An upload needs help before work can continue."
        case .firstTourNudge: return "A reminder to finish and share your first tour."
        }
    }
}

// MARK: - The preferences themselves

/// What the account wants to be told about.
///
/// Read from `GET /me` → `notifications`, written with `PATCH /me/notifications`.
/// Every field is a plain `Bool` with a safe default because this is exactly the
/// shape that must survive a server which sends half of it, all of it or none
/// of it.
struct NotificationPrefs: Sendable, Hashable {
    /// The master switch. False means the account wants nothing at all, whatever
    /// the four below say.
    var enabled: Bool = true
    var leads: Bool = true
    var renders: Bool = true
    var freeWeekEnding: Bool = true
    var allowanceLow: Bool = true
    /// These share the same defaults and stored values as Studio.
    var uploadStuck: Bool = true
    var firstTourNudge: Bool = true
    var mutedUntil: String? = nil

    subscript(category: NotificationCategory) -> Bool {
        get {
            switch category {
            case .leads:          return leads
            case .renders:        return renders
            case .freeWeekEnding: return freeWeekEnding
            case .allowanceLow:   return allowanceLow
            case .uploadStuck:    return uploadStuck
            case .firstTourNudge: return firstTourNudge
            }
        }
        set {
            switch category {
            case .leads:          leads = newValue
            case .renders:        renders = newValue
            case .freeWeekEnding: freeWeekEnding = newValue
            case .allowanceLow:   allowanceLow = newValue
            case .uploadStuck:    uploadStuck = newValue
            case .firstTourNudge: firstTourNudge = newValue
            }
        }
    }

    /// The PATCH body. Snake case, like every other route this app talks to.
    var wire: [String: Any] {
        let activeMute = mutedUntil.flatMap { value in CloudListingMerge.date(value).map { $0 > Date() ? value : nil } } ?? nil
        return [
            "lead_received": leads,
            "render_ready": renders,
            "upload_stuck": uploadStuck,
            "first_tour_nudge": firstTourNudge,
            "muted_until": enabled ? NSNull() : (activeMute ?? "2099-01-01T00:00:00Z") as Any,
            NotificationCategory.freeWeekEnding.rawValue: freeWeekEnding,
            NotificationCategory.allowanceLow.rawValue: allowanceLow,
        ]
    }

    /// Decode whatever the server sent, tolerantly. `push_enabled` is accepted
    /// alongside `enabled` so the app and the route cannot miss each other over
    /// one word; a missing key keeps the default rather than reading as `false`,
    /// because "the server did not say" and "the person said no" are different
    /// facts and only one of them should silence a notification.
    init(wire: [String: Any]) {
        func flag(_ keys: [String], _ fallback: Bool) -> Bool {
            for key in keys {
                if let b = wire[key] as? Bool { return b }
                if let n = wire[key] as? NSNumber { return n.boolValue }
                if let s = wire[key] as? String {
                    let t = s.trimmingCharacters(in: .whitespaces).lowercased()
                    if ["true", "1", "yes", "on"].contains(t) { return true }
                    if ["false", "0", "no", "off"].contains(t) { return false }
                }
            }
            return fallback
        }
        mutedUntil = wire["muted_until"] as? String
        if let mutedUntil, let date = CloudListingMerge.date(mutedUntil) { enabled = date <= Date() }
        else { enabled = flag(["enabled", "push_enabled"], true) }
        leads = flag(["lead_received", "leads", "lead"], true)
        renders = flag(["render_ready", "renders", "render"], true)
        uploadStuck = flag(["upload_stuck"], true)
        firstTourNudge = flag(["first_tour_nudge"], true)
        freeWeekEnding = flag([NotificationCategory.freeWeekEnding.rawValue, "freeWeekEnding"], true)
        allowanceLow = flag([NotificationCategory.allowanceLow.rawValue, "allowanceLow"], true)
    }

    init() {}
}
