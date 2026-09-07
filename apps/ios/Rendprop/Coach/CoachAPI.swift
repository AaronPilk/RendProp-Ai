import Foundation

// coach — the wire-format types for `POST /coach`
// (services/supabase/functions/coach/, docs/COACH-CONTRACT.md).
//
// THREE INDEPENDENT COPIES BY NECESSITY. The closed action enum below mirrors
// `ACTION_TYPES` in coach/actions.ts, and the request/response shapes mirror
// the JSON contract in docs/COACH-CONTRACT.md — server (Deno), iOS (Swift)
// and the docs file can't share a source file, so all three must be kept in
// lockstep by hand. Adding a fourth action anywhere without the other two is
// a contract break — see docs/handoff/coach.md.

/// `POST /coach` request body.
struct CoachRequest: Sendable {
    struct Message: Sendable {
        var role: String   // "user" | "assistant"
        var content: String
    }

    /// One of the user's own projects, built from `AppModel` — never from a
    /// server round trip. Counts and booleans ONLY: no photo, no video, no
    /// room-tag text (only its count) ever leaves the phone for this feature.
    /// Mirrors `CoachListingCtx` in coach/prompt.ts field-for-field.
    struct ListingContext: Sendable {
        var id: String              // listing.id.uuidString — round-trips as listing_id
        var title: String
        var hasVideo: Bool
        var roomTags: Int
        var hasTour: Bool
        var published: Bool
        var photos: Int
        var edits: Int
        var reels: Int
    }

    struct Context: Sendable {
        var listings: [ListingContext]
        var plan: String
        /// A hint only, never load-bearing — e.g. "home" | "settings".
        var screen: String?
    }

    /// Oldest first; the LAST entry must be the user's newest message.
    var messages: [Message]
    var spaceType: String
    var context: Context
}

/// The closed action enum — MUST stay in lockstep with `ACTION_TYPES` in
/// coach/actions.ts and the enum in docs/COACH-CONTRACT.md.
enum CoachActionType: String, Sendable {
    case startProject = "start_project"
    case openTour = "open_tour"
    case openPhotos = "open_photos"
    case openReel = "open_reel"
    case openFloorPlan = "open_floor_plan"
    case openAerial = "open_aerial"
    case shareTour = "share_tour"
    case openPlanUsage = "open_plan_usage"
    case openSupport = "open_support"
    case openHome = "open_home"

    /// Mirrors `DEFAULT_LABEL` in coach/actions.ts — the server already
    /// guards against an empty label itself; this is belt-and-braces on the
    /// client, the same posture the server takes on itself.
    var defaultLabel: String {
        switch self {
        case .startProject:  return "Start my first project"
        case .openTour:      return "Open the tour"
        case .openPhotos:    return "Open Photo Studio"
        case .openReel:      return "Make a reel"
        case .openFloorPlan: return "Open floor plan"
        case .openAerial:    return "Make an aerial shot"
        case .shareTour:     return "Share the tour"
        case .openPlanUsage: return "Open Plan & usage"
        case .openSupport:   return "Contact support"
        case .openHome:      return "Go to Home"
        }
    }

    /// Actions that name a specific project — mirrors `LISTING_ACTIONS`.
    var needsListing: Bool {
        switch self {
        case .openTour, .openPhotos, .openReel, .openFloorPlan, .openAerial, .shareTour:
            return true
        case .startProject, .openPlanUsage, .openSupport, .openHome:
            return false
        }
    }
}

/// `POST /coach` response.
struct CoachResponse: Decodable, Sendable {
    struct Action: Decodable, Equatable, Sendable {
        /// Raw wire value, decoded as a plain string — never a strict enum —
        /// so ONE unrecognised action can never fail the whole response's
        /// decode. `kind` below is the safe way to consume it.
        var type: String
        var label: String
        var listingID: String?

        /// `nil` when `type` is outside the closed enum. Callers MUST treat
        /// `nil` as "drop this action" — never fall back to a guess, exactly
        /// like the server's own `sanitizeCoachOutput`.
        var kind: CoachActionType? { CoachActionType(rawValue: type) }

        enum CodingKeys: String, CodingKey {
            case type, label
            case listingID = "listing_id"
        }
    }

    var reply: String
    var actions: [Action]
    var suggestedReplies: [String]
    var model: String

    enum CodingKeys: String, CodingKey {
        case reply, actions
        case suggestedReplies = "suggested_replies"
        case model
    }
}
