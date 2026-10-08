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
    /// Device-only help/consent fallbacks never join a later online transcript.
    /// The display text stays available locally; this flag is not sent anywhere.
    var localOnly = false
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
    /// A closed screen hint — never load-bearing; see
    /// `CoachRequest.Context.screen`.
    private let originScreen: String?
    private let selectedListingID: UUID?
    private let ownerAtOpen: String?
    private let revisionAtOpen: UInt64
    private let workspaceAtOpen: UUID?
    private let liveBackend: Bool
    /// Remember cached addresses before an edit/refresh can rename them. This
    /// private in-memory map is used only to remove automatic address content.
    private var addressRedactions: [String: String] = [:]

    init(model: AppModel, originScreen: String? = nil, starters: [String]? = nil, listingID: UUID? = nil) {
        self.starterChips = (starters?.isEmpty == false ? starters! : Self.defaultStarters)
        self.model = model
        self.space = SpaceType.current
        self.originScreen = originScreen
        self.selectedListingID = listingID
        self.ownerAtOpen = AuthStore.shared.userID
        self.revisionAtOpen = AuthStore.shared.syncSessionRevision
        self.workspaceAtOpen = WorkspaceContext.selectedOrgID
        self.liveBackend = Config.useLiveBackend
        self.messages = [CoachMessage(role: .assistant, text: Self.greeting, localOnly: true)]
        rememberAddresses()
        Analytics.track("coach_opened", originScreen.map { ["screen": $0] } ?? [:])
    }

    private static let greeting =
        "Hi, I'm Coach. Tell me what you're working on, or ask me anything about Rendprop — " +
        "publishing, your plan, filming tips, whatever you need."

    // MARK: - Sending

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        guard currentContext else { invalidateContext(); return }
        rememberAddresses()
        messages.append(CoachMessage(role: .user, text: trimmed))
        Analytics.track("coach_message_sent", ["length_bucket": Self.lengthBucket(trimmed)])
        isSending = true

        Task {
            await self.reply(to: trimmed)
            self.isSending = false
        }
    }

    private func reply(to text: String) async {
        guard currentContext else { invalidateContext(); return }
        if let help = CoachOffline.recovery(to: text, model: model, space: space, orgID: workspaceAtOpen,
                                            liveBackend: liveBackend, selectedListingID: selectedListingID) {
            messages.append(CoachMessage(role: .assistant, text: help.text, localOnly: true,
                                         actions: help.action.map { [$0] } ?? []))
            return
        }
        // 5.1.2(i): what the person types goes to Anthropic or OpenAI on the
        // server, so the same consent every other AI tool asks for is asked
        // here — once per device, through AIConsentGate on CoachView. Declining
        // does NOT close the coach: it keeps answering from CoachOffline, which
        // runs entirely on the phone. Customer service must never be a dead end.
        let consent = await AIConsent.shared.ensureGranted()
        guard currentContext else { invalidateContext(); return }
        guard consent else {
            let (offlineText, offlineAction) = offlineAnswer(to: text)
            messages.append(CoachMessage(
                role: .assistant,
                text: offlineText,
                localOnly: true,
                actions: offlineAction.map { [$0] } ?? []
            ))
            return
        }
        do {
            // A local draft may have no workspace while signed out. It can
            // receive on-device help, but cannot choose a paid server context.
            guard !liveBackend || workspaceAtOpen != nil else { throw CloudSyncError.identityChanged }
            let request = CoachRequest(
                messages: history(),
                spaceType: space.rawValue,
                context: CoachRequest.Context(
                    listings: Self.contextListings(from: model, orgID: workspaceAtOpen, liveBackend: liveBackend, selectedListingID: selectedListingID),
                    plan: PurchaseManager.shared.activePlan ?? "free",
                    screen: originScreen,
                    selectedListingID: Self.contextProjects(from: model, orgID: workspaceAtOpen, liveBackend: liveBackend).contains(where: { $0.id == selectedListingID }) ? selectedListingID?.uuidString.lowercased() : nil
                ),
                orgID: workspaceAtOpen
            )
            guard currentContext else { invalidateContext(); return }
            let response = try await model.api.coach(request)
            guard currentContext else { invalidateContext(); return }
            let reply = response.reply.trimmingCharacters(in: .whitespacesAndNewlines)
            messages.append(CoachMessage(
                role: .assistant,
                text: reply.isEmpty ? offlineAnswer(to: text).text : reply,
                localOnly: reply.isEmpty,
                actions: reply.isEmpty ? offlineAnswer(to: text).action.map { [$0] } ?? [] : response.actions,
                suggestedReplies: response.suggestedReplies
            ))
        } catch {
            guard currentContext else { invalidateContext(); return }
            // Signed out, offline, rate-limited, or the server had a bad day
            // — all land here. The chat still answers; see CoachOffline.
            let (offlineText, offlineAction) = offlineAnswer(to: text)
            messages.append(CoachMessage(
                role: .assistant,
                text: offlineText,
                localOnly: true,
                actions: offlineAction.map { [$0] } ?? []
            ))
        }
    }

    private func offlineAnswer(to text: String) -> (text: String, action: CoachResponse.Action?) {
        CoachOffline.answer(to: text, model: model, space: space, orgID: workspaceAtOpen,
                            liveBackend: liveBackend, selectedListingID: selectedListingID)
    }

    /// Oldest-first, newest-last — matches the server's own expectation
    /// (coach/prompt.ts `buildUserTurn`). A generous local cap; the server
    /// trims further to its own window (`MAX_HISTORY_MESSAGES` in index.ts).
    private func history() -> [CoachRequest.Message] {
        messages.filter { !$0.localOnly }.suffix(20).map {
            CoachRequest.Message(role: $0.role == .user ? "user" : "assistant",
                                 content: Self.redactedTranscript($0.text, addresses: addressRedactions))
        }
    }

    /// Redact at the request boundary too: a legacy bubble or provider reply
    /// can still contain an address even after the offline generator is fixed.
    static func redactedTranscript(_ text: String, addresses: [String: String]) -> String {
        addresses.keys.sorted { $0.count > $1.count }.reduce(text) { result, address in
            guard !address.isEmpty else { return result }
            return result.replacingOccurrences(of: address, with: addresses[address] ?? "this project", options: .caseInsensitive)
        }
    }

    private func rememberAddresses() {
        for listing in model.realProjects {
            let address = listing.address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty else { continue }
            let label = Self.redactedStreet(address) ?? "this \(space.spaceNoun)"
            addressRedactions[address] = label
            // Prior bubbles can use just the numbered street line, without
            // the city/ZIP suffix. Protect that cached variant as well.
            let streetLine = address.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? address
            if !streetLine.isEmpty { addressRedactions[streetLine] = label }
        }
    }

    private var currentContext: Bool {
        AuthStore.shared.userID == ownerAtOpen && AuthStore.shared.syncSessionRevision == revisionAtOpen &&
            WorkspaceContext.selectedOrgID == workspaceAtOpen && SpaceType.current == space
    }

    private func invalidateContext() {
        // Drop prior workspace messages/actions, including a response that
        // finished after selection changed. No old transcript can be retried.
        messages = [CoachMessage(role: .assistant,
                                 text: "Your account or workspace changed. Reopen Coach to continue.", localOnly: true)]
        addressRedactions.removeAll()
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
        guard currentContext else { invalidateContext(); return }
        guard let kind = action.kind else { return }   // out-of-enum — dropped
        Analytics.track("coach_action_tapped", ["type": action.type])
        guard let route = route(for: kind, action: action) else { return }
        model.coachRoute = route
    }

    private func route(for kind: CoachActionType, action: CoachResponse.Action) -> CoachRoute? {
        if kind.needsListing {
            guard let idString = action.listingID,
                  let listingID = UUID(uuidString: idString),
                  Self.contextProjects(from: model, orgID: workspaceAtOpen, liveBackend: liveBackend)
                    .contains(where: { $0.id == listingID }) else { return nil }
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

    static func contextProjects(from model: AppModel, orgID: UUID?, liveBackend: Bool) -> [Listing] {
        guard liveBackend else { return model.realProjects }
        guard let orgID else { return [] }
        return model.realProjects.filter { ($0.serverOrgID ?? $0.cloudDraftOrgID) == orgID }
    }

    static func contextListings(from model: AppModel) -> [CoachRequest.ListingContext] {
        contextListings(from: model, orgID: WorkspaceContext.selectedOrgID, liveBackend: Config.useLiveBackend)
    }

    static func contextListings(from model: AppModel, orgID: UUID?, liveBackend: Bool, selectedListingID: UUID? = nil) -> [CoachRequest.ListingContext] {
        let projects = contextProjects(from: model, orgID: orgID, liveBackend: liveBackend)
        let selected = projects.filter { $0.id == selectedListingID }
        let listings = Array((selected + projects.filter { $0.id != selectedListingID }).prefix(25))
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
                reels: reelCount(for: listing.id),
                attention: attention(for: listing, model: model),
                serverID: listing.serverID?.uuidString.lowercased(),
                localDraft: listing.serverID == nil && listing.cloudDraftOrgID == orgID && listing.cloudUnavailable != true
            )
        }
    }

    static func attention(for listing: Listing, model: AppModel) -> String? {
        if listing.cloudUnavailable == true { return "cloud_access" }
        if listing.factsSync?.reviewRequired == true || listing.factsSync?.conflict == true || listing.measurementSync?.factsReviewRequired == true { return "facts_review" }
        guard listing.needsAttention else { return nil }
        if listing.status == .uploading { return "upload" }
        if model.tours[listing.id] != nil { return "publish" }
        if model.assets[listing.id] != nil { return "render" }
        return "unknown"
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
        let unitTokens = ["apt", "apt.", "unit", "ste", "ste.", "suite", "#"]
        if let f = parts.first?.lowercased(), unitTokens.contains(f) || f.hasPrefix("#") {
            parts.removeFirst()
            if !f.hasPrefix("#") || f == "#", !parts.isEmpty { parts.removeFirst() }
            while let first = parts.first, first.first?.isNumber == true { parts.removeFirst() }
        }
        // Units usually occur at the END of the street line, not its front.
        if let unit = parts.firstIndex(where: { unitTokens.contains($0.lowercased()) || $0.hasPrefix("#") }) {
            parts = Array(parts.prefix(unit))
        }
        let street = parts.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = street.lowercased()
        guard street.count >= 2, street.rangeOfCharacter(from: .letters) != nil,
              !lower.hasPrefix("po box"), !lower.hasPrefix("p.o. box") else { return nil }
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
            "In Settings → \"Your data\" → \"Delete account.\" Guests using an anonymous session " +
            "also have a server account, so this is not a local-only wipe. Server cleanup may " +
            "remain pending, and shared-team data is not all deleted with your account. " +
            "Deleting the account does not cancel an App Store subscription."),
        Topic(keywords: ["film", "record", "walkthrough tip", "how do i shoot", "how to record"], reply:
            "Walk at a normal, steady pace — the way you'd show a friend around. Hold the phone " +
            "upright at chest height, keep it level, and turn the lights on first. One continuous " +
            "take, ending on your best shot."),
        Topic(keywords: ["floor plan", "lidar", "roomplan", "measurements"], reply:
            "Open a listing's Measurements card. Draw an outline by entering each wall's " +
            "length and direction, or enter rectangular room dimensions. Review the area worksheet " +
            "and export an image or PDF. Garage, porch and unfinished areas stay separate. " +
            "Choose a finished outline when adding an open-below deduction. " +
            "Calculated closing walls need checking, and these totals do not set advertised living area. " +
            "Use tape or laser measurements, or the ruler button for an approximate phone distance. " +
            "Any phone can upload a plan you already have. Automatic 3D floor plans and 3D " +
            "walkthroughs are Coming soon. Plan your video is no longer an ordinary listing detail entry; " +
            "agency and Studio capture planning remain in their own workflows."),
        // The introductory trial starts only after Apple's purchase confirmation.
        Topic(keywords: ["trial", "free week", "first week"], reply:
            "Open Settings → Plan & usage → View plans. Eligible subscriptions offer 7 days free, " +
            "but the trial starts only after you confirm the subscription with Apple. Apple shows " +
            "the renewal price before you confirm. Manage or cancel it in Settings → Plan & usage."),
        Topic(keywords: ["reel", "social video"], reply:
            "Reels turn a handful of your photos into a short vertical video — a gliding camera " +
            "move on each photo, a voiceover, and captions that land on the beat."),
        Topic(keywords: ["sign in", "guest", "account needed", "do i need an account"], reply:
            // Account-first since build 50: Apple sign-in owns the cloud workspace.
            "Rendprop is an account-based workspace: sign in with Apple to create or " +
            "open your account. Recording and editing work offline once you are signed in; " +
            "publishing and AI tools need an internet connection. Your first published " +
            "listing is free, and a plan adds AI tools and more listings."),
    ]

    private static let offlineNote = "\n\n(I'm answering offline right now, so this is from what I already know.)"

    /// Never returns an empty string — callers always get something to show,
    /// never a blank bubble.
    static func answer(to userText: String, model: AppModel, space: SpaceType, orgID: UUID? = nil,
                       liveBackend: Bool = false, selectedListingID: UUID? = nil) -> (text: String, action: CoachResponse.Action?) {
        let haystack = userText.lowercased()
        if let help = recovery(to: userText, model: model, space: space, orgID: orgID, liveBackend: liveBackend, selectedListingID: selectedListingID) {
            return help
        }
        if let hit = topics.first(where: { topic in topic.keywords.contains(where: haystack.contains) }) {
            let kind: CoachActionType = hit.keywords.contains("cancel") || hit.keywords.contains("trial") ? .openPlanUsage : .openSupport
            return (hit.reply + offlineNote,
                    CoachResponse.Action(type: kind.rawValue,
                                         label: kind.defaultLabel, listingID: nil))
        }
        if ["account", "my plan", "usage", "allowance", "renewal"].contains(where: haystack.contains) {
            return ("I can't verify your current plan, renewal or usage offline. Open Plan & usage for the selected workspace's latest account details." + offlineNote,
                    CoachResponse.Action(type: CoachActionType.openPlanUsage.rawValue,
                                         label: CoachActionType.openPlanUsage.defaultLabel, listingID: nil))
        }
        let step = nextStep(model: model, space: space, orgID: orgID, liveBackend: liveBackend, selectedListingID: selectedListingID)
        return (step.text + offlineNote, step.action)
    }

    /// Local recovery never sends the raw lastError to a model and never
    /// executes a paid retry. It opens the project for the user's review.
    static func recovery(to text: String, model: AppModel, space: SpaceType, orgID: UUID?,
                         liveBackend: Bool, selectedListingID: UUID?) -> (text: String, action: CoachResponse.Action?)? {
        let query = text.lowercased()
        guard ["needs attention", "stuck", "failed", "error", "what next", "continue", "retry", "wrong", "can't publish", "cannot publish"].contains(where: query.contains),
              let selectedListingID,
              let listing = CoachModel.contextProjects(from: model, orgID: orgID, liveBackend: liveBackend).first(where: { $0.id == selectedListingID }),
              let reason = CoachModel.attention(for: listing, model: model) else { return nil }
        let kind: CoachActionType
        let reply: String
        switch reason {
        case "cloud_access":
            kind = .openHome
            reply = "Your local files are still on this phone. Open Home and confirm the workspace and listing access before trying to sync or publish."
        case "facts_review":
            kind = .openHome
            reply = "Your edits are saved on this phone. Open the listing's details and Measurements to review the shared version before syncing. A retry cannot choose which teammate's changes to keep."
        case "upload":
            kind = .openTour
            reply = "Open this project's tour and check the upload. Reconnect before retrying; keep the saved video on this phone until it completes."
        case "render":
            kind = .openTour
            reply = "Open this project's tour to review the saved video and try building it again. Needs attention means the previous attempt did not finish; it does not mean your source video was deleted."
        case "publish":
            kind = .openTour
            reply = "Your saved tour is on this phone. Open it to review the publish status, then retry sharing when connected. Normal upload and feature limits still apply."
        default:
            kind = .openTour
            reply = "Open this project's tour to review the saved work and its next available action. If it still cannot continue, contact support."
        }
        return (reply, CoachResponse.Action(type: kind.rawValue, label: kind.defaultLabel,
                                            listingID: kind.needsListing ? listing.id.uuidString : nil))
    }

    /// The same step ladder as coach/prompt.ts's `systemInstruction`, run
    /// locally over state the phone already has — no network needed. Only
    /// ever names a listing when exactly one real project exists; with two
    /// or more, offline mode points at Home rather than guessing which one.
    static func nextStep(model: AppModel, space: SpaceType, orgID: UUID? = nil, liveBackend: Bool = false,
                         selectedListingID: UUID? = nil) -> (text: String, action: CoachResponse.Action?) {
        let noun = space.spaceNoun
        let scoped = CoachModel.contextProjects(from: model, orgID: orgID, liveBackend: liveBackend)
        let projects = selectedListingID.map { selected in scoped.filter { $0.id == selected } } ?? scoped
        if selectedListingID != nil && projects.isEmpty {
            return ("This project is unavailable in the selected workspace. Open Home to check its access.",
                    CoachResponse.Action(type: CoachActionType.openHome.rawValue,
                                         label: CoachActionType.openHome.defaultLabel, listingID: nil))
        }
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
            let title = CoachModel.redactedStreet(listing.address) ?? "this \(noun)"
            return ("Next: add the walkthrough video for \(title).",
                    CoachResponse.Action(type: CoachActionType.openTour.rawValue,
                                         label: CoachActionType.openTour.defaultLabel, listingID: id))
        }
        if model.tours[listing.id] == nil {
            return ("Your video is in — next, finish building the tour.",
                    CoachResponse.Action(type: CoachActionType.openTour.rawValue,
                                         label: CoachActionType.openTour.defaultLabel, listingID: id))
        }
        let title = CoachModel.redactedStreet(listing.address) ?? "this \(noun)"
        return ("Your tour for \(title) is ready to share.",
                CoachResponse.Action(type: CoachActionType.shareTour.rawValue,
                                     label: CoachActionType.shareTour.defaultLabel, listingID: id))
    }
}
