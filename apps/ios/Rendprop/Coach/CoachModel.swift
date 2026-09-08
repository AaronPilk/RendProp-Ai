import Foundation

// coach — the chat's on-device brain. Builds context from AppModel, calls
// the API, and — whenever the call can't be made at all (signed out) or
// fails (network, rate limit, a bad response) — answers from a small
// on-device knowledge base instead, so the chat is NEVER dead. Full
// contract: docs/COACH-CONTRACT.md.
//
// TEXT ONLY, NEVER LOGGED. `contextListings(from:)` sends counts and
// booleans only — never a photo, a video, or room-tag TEXT (only its count)
// — mirroring `CoachListingCtx` on the server (coach/prompt.ts) exactly.
// Message text is never passed to `Analytics.track` — only categorical
// values (a length bucket, an action's closed-enum type).

/// One bubble in the chat. Local-only — never sent to or received from the
/// server as a value in its own right (only its `.text`/`.role` feed the
/// wire `messages` array). Lives only in memory for this screen's lifetime;
/// never persisted to disk.
struct CoachMessage: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant }
    let id = UUID()
    var role: Role
    var text: String
    var actions: [CoachResponse.Action] = []
    var suggestedReplies: [String] = []
}

/// Where a resolved Coach action should land. The ONLY new published
/// property this feature adds to `AppModel` (`coachRoute`) — `RootTabView`
/// and `HomeDashboardView` each react to it with a small `.onChange`; see
/// docs/handoff/coach.md for both edits at file:line. Reuses `ProjectFeature`
/// (RendpropApp.swift) so "which screen" logic is never duplicated —
/// `HomeDashboardView.go(_:_:)` already knows `.aerial` is a sheet and
/// everything else is a push.
enum CoachRoute: Equatable {
    case project(listingID: UUID, feature: ProjectFeature)
    case startProject
    case planUsage
    case support
    case home
}

@MainActor
final class CoachModel: ObservableObject {
    @Published private(set) var messages: [CoachMessage]
    @Published private(set) var isSending = false

    /// The four questions offered before the first reply. SCREEN-SPECIFIC
    /// now: `AskAIScreen.starters` supplies them, so "Ask AI" on the floor-plan
    /// screen opens on floor-plan questions instead of "Start my first tour".
    /// The array below is the fallback for a caller that names no screen —
    /// which is Home, where these four were written for.
    let starterChips: [String]

    static let defaultStarters = [
        "Start my first tour",
        "How do I share to the MLS?",
        "What does the AI do to my photos?",
        "Cancel or change my plan",
    ]

    private unowned let model: AppModel
    private let space: SpaceType
    /// A hint only ("home" | "settings") — never load-bearing; see
    /// `CoachRequest.Context.screen`.
    private let originScreen: String?

    init(model: AppModel, originScreen: String? = nil, starters: [String]? = nil) {
        self.starterChips = (starters?.isEmpty == false ? starters! : Self.defaultStarters)
        self.model = model
        self.space = SpaceType.current
        self.originScreen = originScreen
        self.messages = [CoachMessage(role: .assistant, text: Self.greeting)]
        Analytics.track("coach_opened", originScreen.map { ["screen": $0] } ?? [:])
    }

    private static let greeting =
        "Hi, I'm Coach. Tell me what you're working on, or ask me anything about Rendprop — " +
        "publishing, your plan, filming tips, whatever you need."

    // MARK: - Sending

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        messages.append(CoachMessage(role: .user, text: trimmed))
        Analytics.track("coach_message_sent", ["length_bucket": Self.lengthBucket(trimmed)])
        isSending = true

        Task {
            await self.reply(to: trimmed)
            self.isSending = false
        }
    }

    private func reply(to text: String) async {
        // 5.1.2(i): what the person types goes to Anthropic or OpenAI on the
        // server, so the same consent every other AI tool asks for is asked
        // here — once per device, through AIConsentGate on CoachView. Declining
        // does NOT close the coach: it keeps answering from CoachOffline, which
        // runs entirely on the phone. Customer service must never be a dead end.
        guard await AIConsent.shared.ensureGranted() else {
            let (offlineText, offlineAction) = CoachOffline.answer(to: text, model: model, space: space)
            messages.append(CoachMessage(
                role: .assistant,
                text: offlineText,
                actions: offlineAction.map { [$0] } ?? []
            ))
            return
        }
        do {
            let request = CoachRequest(
                messages: history(),
                spaceType: space.rawValue,
                context: CoachRequest.Context(
                    listings: Self.contextListings(from: model),
                    plan: PurchaseManager.shared.activePlan ?? "free",
                    screen: originScreen
                )
            )
            let response = try await model.api.coach(request)
            let reply = response.reply.trimmingCharacters(in: .whitespacesAndNewlines)
            messages.append(CoachMessage(
                role: .assistant,
                text: reply.isEmpty ? CoachOffline.nextStep(model: model, space: space).text : reply,
                actions: response.actions,
                suggestedReplies: response.suggestedReplies
            ))
        } catch {
            // Signed out, offline, rate-limited, or the server had a bad day
            // — all land here. The chat still answers; see CoachOffline.
            let (offlineText, offlineAction) = CoachOffline.answer(to: text, model: model, space: space)
            messages.append(CoachMessage(
                role: .assistant,
                text: offlineText,
                actions: offlineAction.map { [$0] } ?? []
            ))
        }
    }

    /// Oldest-first, newest-last — matches the server's own expectation
    /// (coach/prompt.ts `buildUserTurn`). A generous local cap; the server
    /// trims further to its own window (`MAX_HISTORY_MESSAGES` in index.ts).
    private func history() -> [CoachRequest.Message] {
        messages.suffix(20).map {
            CoachRequest.Message(role: $0.role == .user ? "user" : "assistant", content: $0.text)
        }
    }

    private static func lengthBucket(_ s: String) -> String {
        switch s.count {
        case 0..<20:  return "short"
        case 20..<80: return "medium"
        default:      return "long"
        }
    }

    // MARK: - Acting on a tap

    /// An action chip under an assistant bubble was tapped. Resolves the
    /// wire action into a `CoachRoute` — dropping anything outside the
    /// closed enum, or naming a project this phone doesn't actually have
    /// (never guessed, exactly like the server's own sanitizer) — and writes
    /// it to `AppModel.coachRoute` for the presenter (RootTabView /
    /// HomeDashboardView) to carry out. The CALLER (CoachView) is
    /// responsible for dismissing the sheet right after.
    func perform(_ action: CoachResponse.Action) {
        guard let kind = action.kind else { return }   // out-of-enum — dropped
        Analytics.track("coach_action_tapped", ["type": action.type])
        guard let route = route(for: kind, action: action) else { return }
        model.coachRoute = route
    }

    private func route(for kind: CoachActionType, action: CoachResponse.Action) -> CoachRoute? {
        if kind.needsListing {
            guard let idString = action.listingID,
                  let listingID = UUID(uuidString: idString),
                  model.listings.contains(where: { $0.id == listingID }) else { return nil }
            switch kind {
            case .openTour, .shareTour: return .project(listingID: listingID, feature: .tour)
            case .openPhotos:           return .project(listingID: listingID, feature: .photos)
            case .openReel:             return .project(listingID: listingID, feature: .reel)
            case .openFloorPlan:        return .project(listingID: listingID, feature: .floorPlan)
            case .openAerial:           return .project(listingID: listingID, feature: .aerial)
            default: return nil
            }
        }
        switch kind {
        case .startProject:  return .startProject
        case .openPlanUsage: return .planUsage
        case .openSupport:   return .support
        case .openHome:      return .home
        default: return nil
        }
    }

    // MARK: - Context (counts and booleans ONLY — see file header)

    static func contextListings(from model: AppModel) -> [CoachRequest.ListingContext] {
        let listings = Array(model.realProjects.prefix(25))
        let labels = Self.redactedLabels(for: listings)
        return listings.enumerated().map { idx, listing in
            CoachRequest.ListingContext(
                id: listing.id.uuidString,
                title: labels[idx],
                hasVideo: model.assets[listing.id] != nil,
                roomTags: model.assets[listing.id]?.roomTags.count ?? 0,
                hasTour: model.tours[listing.id] != nil,
                published: !(listing.shareURL ?? "").isEmpty,
                photos: photoCounts(for: listing.id).photos,
                edits: photoCounts(for: listing.id).edits,
                reels: reelCount(for: listing.id)
            )
        }
    }

    /// The label a listing travels to the LLM under — the STREET, never the
    /// address.
    ///
    /// THE DEFECT: `title` was `listing.address`, so up to 25 exact street
    /// addresses left the phone on every coach message, while the type's own
    /// contract comment said "counts and booleans ONLY". The comment was a
    /// hope, not a guard. It got worse the day Ask AI moved from two screens
    /// to eleven.
    ///
    /// WHY NOT AN ORDINAL. The coach's answers name the home back to the agent
    /// — "your tour for Crestline Ridge is ready to share" — and "home 3" makes
    /// that useless. The street name is what an agent actually recognises, and
    /// a street without a number is not a mailing address. Homes that share a
    /// street get a numeric suffix so the coach can still tell them apart.
    ///
    /// REDACTED HERE, ON THE PHONE, before the bytes exist. Not server-side:
    /// the server is what this protects against, and a scrub that runs after
    /// the network hop protects nobody.
    static func redactedLabels(for listings: [Listing]) -> [String] {
        var seen: [String: Int] = [:]
        return listings.enumerated().map { idx, listing in
            let base = redactedStreet(listing.address) ?? "Home \(idx + 1)"
            let n = (seen[base] ?? 0) + 1
            seen[base] = n
            return n == 1 ? base : "\(base) (\(n))"
        }
    }

    /// "1180 Crestline Ridge, Apt 4B, Naples FL" -> "Crestline Ridge".
    ///
    /// Everything from the first comma is dropped (city, state, ZIP, unit), a
    /// leading house number or number-range is dropped, and so is a leading
    /// unit token, which is how a real address string tends to lead. nil when
    /// nothing recognisable is left, so the caller falls back to an ordinal
    /// rather than sending a fragment it has not reasoned about.
    static func redactedStreet(_ address: String) -> String? {
        let head = address.split(separator: ",", maxSplits: 1,
                                 omittingEmptySubsequences: false)
            .first.map(String.init) ?? address
        var parts = head.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // Leading house number ("1180", "1180A", "12-14") — and only leading:
        // "Route 66" keeps its number because it is not in front.
        while let f = parts.first, f.rangeOfCharacter(from: .decimalDigits) != nil,
              f.first?.isNumber == true {
            parts.removeFirst()
        }
        // A unit token that survived the comma split ("Apt 4B", "#3", "Unit 2").
        if let f = parts.first?.lowercased(),
           ["apt", "apt.", "unit", "ste", "ste.", "suite", "#"].contains(f) || f.hasPrefix("#") {
            parts.removeFirst()
            if let n = parts.first, n.rangeOfCharacter(from: .decimalDigits) != nil { parts.removeFirst() }
        }
        let street = parts.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard street.count >= 2, street.rangeOfCharacter(from: .letters) != nil else { return nil }
        return String(street.prefix(48))
    }

    /// `EnhancedPhoto` (FlythroughDetailView.swift) is the only place this
    /// app counts a listing's studio photos, and every entry it returns
    /// already carries an AI edit (its `enh-*.jpg`) — there is no "added but
    /// not yet edited" state to report separately. `photos` and `edits` are
    /// therefore the same real number; this is a soft coaching signal (never
    /// billed, never a gate), so the approximation costs nothing but a
    /// slightly plainer sentence from the coach.
    fileprivate static func photoCounts(for listingID: UUID) -> (photos: Int, edits: Int) {
        let n = EnhancedPhoto.loadAll(listingID: listingID).count
        return (n, n)
    }

    /// Mirrors FlythroughDetailView's own (private) `reelFiles(for:)`
    /// exactly — `Documents/reels/<listingID>-<unix>.mp4` — re-implemented
    /// here because that one is private to its file.
    fileprivate static func reelCount(for listingID: UUID) -> Int {
        let dir = FileStore.documents.appendingPathComponent("reels", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        let prefix = "\(listingID.uuidString)-".lowercased()
        return files.filter {
            $0.lastPathComponent.lowercased().hasPrefix(prefix) && $0.pathExtension.lowercased() == "mp4"
        }.count
    }
}

// MARK: - Offline knowledge (never dead)

/// A small, offline mirror of coach/knowledge.ts (server) — shown ONLY when
/// there is no network reply to show (signed out, offline, or the call
/// failed). Deliberately modest: a handful of the most common
/// customer-service topics, plus the SAME onboarding step ladder as
/// coach/prompt.ts's `systemInstruction`, run locally over state AppModel
/// already has on the phone (no network needed for that half at all). The
/// two knowledge sets are independent by necessity (Swift can't share a
/// source file with Deno) — a fact that changes in knowledge.ts should
/// change here too; see docs/COACH-CONTRACT.md.
/// `@MainActor` because both entry points read AppModel — `realProjects`,
/// `assets`, `tours` — and AppModel is main-actor isolated. Its only caller,
/// `CoachModel.reply(to:)`, is already on the main actor, so this costs
/// nothing. (Guide/FirstProjectGuide.swift marks its AppModel helpers the
/// same way, for the same reason.)
@MainActor
enum CoachOffline {
    private struct Topic { let keywords: [String]; let reply: String }

    private static let topics: [Topic] = [
        Topic(keywords: ["mls", "unbranded", "branded link", "two link"], reply:
            "Publishing gives you two links. The branded one carries your card and contact form " +
            "— text or post that one. The unbranded one has no name or branding — that's the one " +
            "your MLS's virtual-tour field wants. Both are in the tour's Share sheet."),
        Topic(keywords: ["ai disclos", "real drone", "is it ai", "virtually staged", "is this fake"], reply:
            "Every AI photo edit is labelled \"Virtually staged\" right next to the untouched " +
            "original, and the aerial intro is always disclosed as AI-generated — never presented " +
            "as real drone footage."),
        Topic(keywords: ["cancel", "subscription", "manage my plan", "refund", "billing"], reply:
            "Subscriptions are billed by Apple, so managing or cancelling one happens there too: " +
            "Settings → Plan & usage → \"Manage subscription.\" Cancelling stops the next renewal " +
            "— your plan keeps working until the period you already paid for ends."),
        Topic(keywords: ["delete my account", "delete account", "remove my data"], reply:
            "In Settings → \"Your data\" → \"Delete account.\" That removes your Rendprop account, " +
            "unpublishes every tour link, and clears this phone."),
        Topic(keywords: ["film", "record", "walkthrough tip", "how do i shoot", "how to record"], reply:
            "Walk at a normal, steady pace — the way you'd show a friend around. Hold the phone " +
            "upright at chest height, keep it level, and turn the lights on first. One continuous " +
            "take, ending on your best shot."),
        Topic(keywords: ["floor plan", "lidar", "roomplan"], reply:
            "Scan a room in 3D by walking it with the phone — this needs an iPhone with LiDAR. Any " +
            "other iPhone can upload a floor plan you already have instead."),
        Topic(keywords: ["trial", "free week"], reply:
            "Every plan starts with a 7-day free trial, once per Apple ID."),
        Topic(keywords: ["reel", "social video"], reply:
            "Reels turn a handful of your photos into a short vertical video — a gliding camera " +
            "move on each photo, a voiceover, and captions that land on the beat."),
        Topic(keywords: ["sign in", "guest", "account needed", "do i need an account"], reply:
            "Recording, editing and building a tour all work fully signed out. Signing in is " +
            "needed only to publish a tour to the web, since that's the step that creates the " +
            "live link."),
    ]

    private static let offlineNote = "\n\n(I'm answering offline right now, so this is from what I already know.)"

    /// Never returns an empty string — callers always get something to show,
    /// never a blank bubble.
    static func answer(to userText: String, model: AppModel, space: SpaceType) -> (text: String, action: CoachResponse.Action?) {
        let haystack = userText.lowercased()
        if let hit = topics.first(where: { topic in topic.keywords.contains(where: haystack.contains) }) {
            return (hit.reply + offlineNote,
                    CoachResponse.Action(type: CoachActionType.openSupport.rawValue,
                                         label: CoachActionType.openSupport.defaultLabel, listingID: nil))
        }
        let step = nextStep(model: model, space: space)
        return (step.text + offlineNote, step.action)
    }

    /// The same step ladder as coach/prompt.ts's `systemInstruction`, run
    /// locally over state the phone already has — no network needed. Only
    /// ever names a listing when exactly one real project exists; with two
    /// or more, offline mode points at Home rather than guessing which one.
    static func nextStep(model: AppModel, space: SpaceType) -> (text: String, action: CoachResponse.Action?) {
        let noun = space.spaceNoun
        let projects = model.realProjects
        guard projects.count == 1, let listing = projects.first else {
            if projects.isEmpty {
                return ("Let's start your first \(noun).",
                        CoachResponse.Action(type: CoachActionType.startProject.rawValue,
                                             label: "Start my first \(noun)", listingID: nil))
            }
            return ("You have a few \(noun)s going — open Home to pick up where you left off.",
                    CoachResponse.Action(type: CoachActionType.openHome.rawValue,
                                         label: CoachActionType.openHome.defaultLabel, listingID: nil))
        }
        let id = listing.id.uuidString
        if model.assets[listing.id] == nil {
            return ("Next: add the walkthrough video for \(listing.address).",
                    CoachResponse.Action(type: CoachActionType.openTour.rawValue,
                                         label: CoachActionType.openTour.defaultLabel, listingID: id))
        }
        if model.tours[listing.id] == nil {
            return ("Your video is in — next, finish building the tour.",
                    CoachResponse.Action(type: CoachActionType.openTour.rawValue,
                                         label: CoachActionType.openTour.defaultLabel, listingID: id))
        }
        return ("Your tour for \(listing.address) is ready to share.",
                CoachResponse.Action(type: CoachActionType.shareTour.rawValue,
                                     label: CoachActionType.shareTour.defaultLabel, listingID: id))
    }
}
