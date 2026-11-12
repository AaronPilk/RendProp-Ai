// Executes full production CoachAPI + CoachModel, with inert app/provider
// boundaries. Scripted failures and asynchronous workspace changes are local.
import Foundation
import Combine

typealias ObservableObject = Combine.ObservableObject
typealias Published<Value> = Combine.Published<Value>
enum ProjectFeature: Equatable { case tour, photos, reel, floorPlan, aerial }
struct SyncState { var reviewRequired = false; var conflict = false; var factsReviewRequired: Bool? = nil }
struct Listing {
    enum Status { case draft, uploading, processing, ready }
    var status: Status = .draft
    var serverID: UUID? = nil
    var cloudUnavailable: Bool? = nil
    var factsSync: SyncState? = nil
    var measurementSync: SyncState? = nil
    var lastError: String? = nil
    var needsAttention: Bool { !(lastError ?? "").isEmpty }
    let id: UUID
    var address: String
    var shareURL: String? = nil
    var serverOrgID: UUID? = nil
    var cloudDraftOrgID: UUID? = nil
    var serverLibraryOrgID: UUID? = nil
    var cloudSyncOwnerID: UUID? = nil
    var isSample = false
    var belongsToCurrentType = true
    var isSold = false
    var isArchived = false
    var isInactive: Bool { isSold || isArchived }
}
struct Asset { var roomTags: [String] = [] }
enum SpaceType: String {
    case realEstate = "real_estate", venue, restaurant, retail, fitness, other
    @MainActor static var current: Self = .realEstate
    var spaceNoun: String {
        switch self {
        case .realEstate: return "home"
        case .venue: return "venue"
        case .restaurant: return "place"
        case .retail: return "store"
        case .fitness: return "studio"
        case .other: return "space"
        }
    }
}
enum Config { static let useLiveBackend = true }
enum CloudSyncError: Error { case identityChanged }
@MainActor enum WorkspaceContext { static var selectedOrgID: UUID? }
@MainActor final class AuthStore {
    static let shared = AuthStore()
    var userID: String? = "aaaaaaaa-0000-0000-0000-000000000001"
    var syncSessionRevision: UInt64 = 1
}
@MainActor final class AppModel {
    var listings: [Listing] = []
    var realProjects: [Listing] { listings.filter { !$0.isSample && $0.belongsToCurrentType && !$0.isInactive && isInSelectedWorkspace($0) } }
    var libraryVisible = true
    func isInSelectedWorkspace(_ listing: Listing) -> Bool {
        if let owner = listing.cloudSyncOwnerID, owner != AuthStore.shared.userID.flatMap(UUID.init(uuidString:)) { return false }
        guard libraryVisible, let selected = WorkspaceContext.selectedOrgID else { return false }
        guard let org = listing.serverOrgID ?? listing.cloudDraftOrgID else { return true }
        if listing.cloudUnavailable == true { return org == selected && listing.serverLibraryOrgID == nil }
        return (listing.serverLibraryOrgID ?? org) == selected
    }
    var assets: [UUID: Asset] = [:]
    var tours: [UUID: String] = [:]
    var coachRoute: CoachRoute?
    let api = ScriptedAPI()
}
@MainActor final class ScriptedAPI {
    var requests: [CoachRequest] = []
    var failNext = false
    var reply = "Synthetic online help"
    var onRequest: (() -> Void)?
    func coach(_ request: CoachRequest) async throws -> CoachResponse {
        requests.append(request)
        onRequest?()
        await Task.yield()
        if failNext { failNext = false; throw URLError(.notConnectedToInternet) }
        return CoachResponse(reply: reply, actions: [], suggestedReplies: [], model: "synthetic")
    }
}
@MainActor enum Analytics {
    static var events: [(String, [String: String])] = []
    static func track(_ event: String, _ properties: [String: String] = [:]) { events.append((event, properties)) }
}
@MainActor final class AIConsent {
    static let shared = AIConsent()
    var granted = true
    var onEnsure: (() -> Void)?
    func ensureGranted() async -> Bool { onEnsure?(); await Task.yield(); return granted }
}
@MainActor final class PurchaseManager {
    static let shared = PurchaseManager()
    var activePlan: String? = "pro"
}
struct EnhancedPhoto {
    struct Version { let effects: [String] }
    var savedVersion: Version?
    static var samples: [EnhancedPhoto] = []
    static func loadAll(listingID: UUID) -> [EnhancedPhoto] { samples }
}
// Closed queue/media boundary only; actual Coach mapping/wire bodies are compiled.
struct SavedServerJob {
    struct Context { var actorID: UUID; var orgID: UUID; var localListingID: UUID; var listingID: UUID }
    struct Request { var operationID: UUID; var sources: [Int] }
    struct Result { var originalPhotoCount: Int }
    struct Reply {
        var operationID: UUID; var listingID: UUID; var selectedLibraryOrgID: UUID
        var sourceCount: Int; var state: String; var completedSources: Int? = nil
        var result: Result? = nil; var resumeAvailable = false
        var isTerminal: Bool { ["ready", "failed", "cancelled", "needs_reconciliation"].contains(state) }
        var mayResume: Bool { state == "failed" && resumeAvailable }
    }
    var context: Context; var request: Request; var reply: Reply? = nil
    var wasRefusedBeforeAdmission = false
}
@MainActor final class ReelWorkJob {
    enum Phase { case setup, generating, stitching, done, failed, paused }
    var listingID: UUID
    var serverJob: SavedServerJob? = nil
    var paused = false
    var pendingRequest: Int? = nil
    var phase: Phase = .generating
    var totalClips = 8
    var completedClips = 3
    var clipIssues: [Int] = []
    var originalPhotoMotionShots = 1
    init(listingID: UUID) { self.listingID = listingID }
}
@MainActor final class ReelWorkQueue {
    static let shared = ReelWorkQueue()
    var visibleJobs: [ReelWorkJob] = []
}

enum FileStore {
    // Never point the production reel counter at a customer directory.
    static let documents = URL(fileURLWithPath: "/synthetic-coach-no-customer-files")
}

@main @MainActor struct CoachPrivacyTests {
    enum Failure: Error { case assertion(String) }
    static var assertions = 0
    static let orgA = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
    static let orgB = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!
    static let listingA = UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!
    static let address = "1180 Crestline Ridge Apt 4B, Naples FL 34100"

    static func check(_ value: Bool, _ reason: String) throws {
        assertions += 1
        if !value { throw Failure.assertion(reason) }
    }
    static func reset() {
        WorkspaceContext.selectedOrgID = orgA
        AuthStore.shared.userID = "aaaaaaaa-0000-0000-0000-000000000001"
        AuthStore.shared.syncSessionRevision = 1
        SpaceType.current = .realEstate
        AIConsent.shared.granted = true; AIConsent.shared.onEnsure = nil
        Analytics.events = []
        ReelWorkQueue.shared.visibleJobs = []; EnhancedPhoto.samples = []
    }
    static func model() -> AppModel {
        let value = AppModel()
        value.listings = [Listing(id: listingA, address: address, serverOrgID: orgA)]
        return value
    }
    static func finish(_ coach: CoachModel) async throws {
        for _ in 0..<1000 {
            if !coach.isSending { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw Failure.assertion("actual Coach send did not finish")
    }
    static func send(_ text: String, through coach: CoachModel) async throws {
        coach.send(text); try await finish(coach)
    }

    static func main() async {
        do {
            reset()
            let app = model(), coach = CoachModel(model: app, originScreen: "floor_plan")
            app.api.failNext = true
            try await send("What should I do next?", through: coach)
            try check(app.api.requests.count == 1, "first actual API failure exercised")
            try check(coach.messages.last?.localOnly == true, "offline reply is local-only")
            try check(!(coach.messages.last?.text.contains("1180") ?? true), "offline display excludes house number")
            try check(!(coach.messages.last?.text.contains("4B") ?? true), "offline display excludes apartment")
            try await send("Help me continue", through: coach)
            let afterOffline = app.api.requests[1]
            try check(afterOffline.orgID == orgA, "request pins the workspace captured at open")
            try check(afterOffline.messages.allSatisfy { $0.role == "user" }, "offline-to-online transcript excludes local assistant bubbles")
            try check(afterOffline.messages.count == 2, "offline-to-online retains both real user turns")
            try check(afterOffline.context.listings.first?.title == "Crestline Ridge", "live context is street-only")

            // A prior-generation bubble/provider echo is deliberately supplied
            // through the real reply path. Redaction must apply even though it
            // was not tagged as a new local fallback.
            app.api.reply = "Legacy walkthrough for \(address)."
            try await send("Another question", through: coach)
            app.listings[0].address = "920 New Street Unit 7, Synthetic City 28000"
            try await send("Help with 1180 Crestline Ridge Apt 4B", through: coach)
            let legacy = app.api.requests[3]
            try check(legacy.messages.contains { $0.role == "assistant" && $0.content.contains("Legacy walkthrough for Crestline Ridge") }, "legacy assistant reply is redacted at the actual history boundary")
            try check(legacy.messages.allSatisfy { !$0.content.contains("1180") && !$0.content.contains("4B") && !$0.content.contains("34100") }, "legacy cached addresses never reach the next online transcript")
            try check(legacy.messages.last?.content == "Help with Crestline Ridge", "cached street-line variant is redacted without a city suffix")
            try check(legacy.context.listings.first?.title == "New Street", "renamed context excludes trailing unit")

            let draft = UUID(), foreign = UUID(), unbound = UUID(), misleading = UUID()
            app.listings.append(contentsOf: [
                Listing(id: draft, address: "200 Draft Street", cloudDraftOrgID: orgA),
                Listing(id: foreign, address: "300 Foreign Street", serverOrgID: orgB),
                Listing(id: unbound, address: "400 Unbound Street"),
                Listing(id: misleading, address: "500 Other Street", serverOrgID: orgB, cloudDraftOrgID: orgA),
            ])
            let scoped = CoachModel.contextListings(from: app, orgID: orgA, liveBackend: true)
            try check(Set(scoped.map(\.id)) == Set([listingA.uuidString, draft.uuidString]), "live context excludes foreign and unbound cached projects")
            try check(CoachModel.contextListings(from: app, orgID: nil, liveBackend: true).isEmpty, "unselected workspace has no online project context")
            coach.perform(CoachResponse.Action(type: "open_photos", label: "Open", listingID: foreign.uuidString))
            try check(app.coachRoute == nil, "foreign cached action target is rejected")
            coach.perform(CoachResponse.Action(type: "open_photos", label: "Open", listingID: listingA.uuidString))
            try check(app.coachRoute == .project(listingID: listingA, feature: .photos), "owned action retains its existing route")
            try check(Analytics.events.allSatisfy { !$0.1.values.contains(where: { $0.contains("1180") || $0.contains("Crestline") }) }, "no addresses or chat text in analytics")

            for change in ["workspace", "owner", "revision", "industry"] {
                reset()
                let value = model(), guarded = CoachModel(model: value)
                AIConsent.shared.onEnsure = {
                    switch change {
                    case "workspace": WorkspaceContext.selectedOrgID = orgB
                    case "owner": AuthStore.shared.userID = "bbbbbbbb-0000-0000-0000-000000000002"
                    case "revision": AuthStore.shared.syncSessionRevision += 1
                    default: SpaceType.current = .retail
                    }
                }
                try await send("Next please", through: guarded)
                try check(value.api.requests.isEmpty, "context-change-during-consent cannot dispatch a paid request: \(change)")
                try check(guarded.messages.count == 1 && guarded.messages[0].localOnly, "changed context clears previous transcript")
            }

            reset()
            let responseApp = model(), responseCoach = CoachModel(model: responseApp)
            responseApp.api.reply = "Must not appear in another workspace"
            responseApp.api.onRequest = { WorkspaceContext.selectedOrgID = orgB }
            try await send("Next please", through: responseCoach)
            try check(responseApp.api.requests[0].orgID == orgA, "in-flight request remains pinned to its original workspace")
            try check(!responseCoach.messages.contains { $0.text.contains("Must not appear") }, "late response is not displayed in the new workspace")
            responseCoach.perform(CoachResponse.Action(type: "open_photos", label: "Old action", listingID: listingA.uuidString))
            try check(responseApp.coachRoute == nil, "stale response action cannot navigate another workspace")

            reset(); WorkspaceContext.selectedOrgID = nil
            let unselectedApp = model(), unselectedCoach = CoachModel(model: unselectedApp)
            try await send("Next", through: unselectedCoach)
            try check(unselectedApp.api.requests.isEmpty, "missing workspace uses local help without any server call")
            try check(unselectedCoach.messages.last?.localOnly == true, "missing-workspace fallback remains local-only")

            reset()
            let many = model()
            for n in 1...30 { many.listings.append(Listing(id: UUID(), address: "\(n) Synthetic Street", serverOrgID: orgA)) }
            let selected = many.listings.last!.id
            many.listings[many.listings.count - 1].serverID = UUID()
            let focused = CoachModel(model: many, originScreen: "listing", listingID: selected)
            try await send("Help with this project", through: focused)
            let request = many.api.requests.last!
            try check(request.context.listings.count == 25, "selected context remains bounded to twenty-five projects")
            try check(request.context.listings.first?.id == selected.uuidString, "selected project is retained before the context cap")
            try check(request.context.selectedListingID == selected.uuidString.lowercased(), "actual send carries the selected device route id")
            try check(request.context.listings.first?.serverID == many.listings.last!.serverID?.uuidString.lowercased(), "cloud row id stays distinct from the local action id")

            many.listings[many.listings.count - 1].lastError = "PRIVATE_PROVIDER_ERROR synthetic-secret/private prompt"
            many.assets[selected] = Asset()
            try await send("Why does this say Needs attention?", through: focused)
            try check(many.api.requests.count == 1, "Needs attention recovery requires no provider request")
            try check(focused.messages.last?.actions.first?.listingID == selected.uuidString, "recovery targets the selected project among many")
            try check(focused.messages.last?.actions.first?.kind == .openTour, "render recovery opens a safe review action")
            try check(!(focused.messages.last?.text.contains("PRIVATE_PROVIDER_ERROR") ?? true), "raw upstream errors never become recovery copy")
            try check(focused.messages.last?.localOnly == true, "deterministic recovery never joins an online transcript")
            many.listings[many.listings.count - 1].factsSync = SyncState(reviewRequired: true)
            try await send("How do I continue?", through: focused)
            try check(focused.messages.last?.actions.first?.kind == .openHome, "facts conflict opens review rather than retrying stale edits")
            try check(many.api.requests.count == 1, "facts review is deterministic without paid work")
            many.listings[many.listings.count - 1].factsSync = nil
            many.listings[many.listings.count - 1].cloudUnavailable = true
            try await send("Why is this stuck?", through: focused)
            try check(focused.messages.last?.actions.first?.kind == .openHome, "lost cloud access cannot offer publication")
            let foreignOnly = model()
            foreignOnly.listings = [Listing(id: UUID(), address: "820 Other Account Street", serverOrgID: orgB)]
            let fallback = CoachOffline.nextStep(model: foreignOnly, space: .realEstate, orgID: orgA, liveBackend: true, selectedListingID: foreignOnly.listings[0].id)
            try check(fallback.action?.kind == .openHome && fallback.action?.listingID == nil, "offline recovery cannot target a cached foreign project")
            let offlineAccount = CoachOffline.answer(to: "What's my current account usage?", model: many, space: .realEstate, orgID: orgA, liveBackend: true, selectedListingID: selected)
            try check(offlineAccount.action?.kind == .openPlanUsage, "offline account question opens verified account screen")
            try check(offlineAccount.text.contains("can't verify"), "offline account help does not invent live plan or usage")

            try check(CoachModel.redactedStreet("Unit B 1180 Crestline Ridge, Synthetic City") == "Crestline Ridge", "leading unit cannot preserve the house number")
            try check(CoachModel.redactedStreet("PO Box 421, Synthetic City") == nil, "postal boxes must use a generic label")
            reset()
            let reelApp = model(), job = ReelWorkJob(listingID: listingA)
            ReelWorkQueue.shared.visibleJobs = [job]
            EnhancedPhoto.samples = [.init(savedVersion: .init(effects: [])), .init(savedVersion: .init(effects: ["stage"])), .init(savedVersion: nil)]
            let reelCoach = CoachModel(model: reelApp, originScreen: "reel_studio", listingID: listingA)
            try await send("What is happening here?", through: reelCoach)
            var sent = reelApp.api.requests.last!
            try check(sent.context.listings.first?.photos == 3 && sent.context.listings.first?.edits == 1, "ordinary enhancement and unknown history are not counted as AI edits")
            try check(sent.context.reelState == .init(phase: .generating, completed: 3, total: 8, stillPhotoShots: 1), "selected reel receives current closed phase and counts")
            job.paused = true
            try await send("What is happening here?", through: reelCoach)
            try check(reelApp.api.requests.last!.context.reelState?.phase == .paused, "reel state is refreshed at send rather than frozen at sheet open")
            reelApp.api.failNext = true
            try await send("Why is this paused?", through: reelCoach)
            try check(reelCoach.messages.last?.localOnly == true && reelCoach.messages.last?.text.contains("saved reel is paused") == true, "online refusal retains screen-specific local pause help")
            try check(reelCoach.messages.last?.actions.first?.kind == .openReel, "online refusal opens the current reel instead of walkthrough capture")
            job.paused = false; job.pendingRequest = 1; job.phase = .failed
            try await send("What is happening here?", through: reelCoach)
            sent = reelApp.api.requests.last!
            try check(sent.context.reelState?.phase == .savedRequest, "durable request overrides a generic failed job for support recovery")
            let bytes = try JSONSerialization.data(withJSONObject: sent.wireBody)
            let wire = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            let context = wire["context"] as! [String: Any]
            let state = context["reel_state"] as! [String: Any]
            try check(Set(state.keys) == Set(["phase", "completed", "total", "still_photo_shots", "execution", "server_phase", "resume_available"]), "actual wire state contains only allowlisted fields")
            try check(state["phase"] as? String == "saved_request" && state["still_photo_shots"] as? Int == 1, "actual JSON carries exact closed state vocabulary")
            try check(wire["org_id"] == nil && context["org_id"] == nil, "workspace routing identity never enters prompt body")
            try check(CoachModel.reelState(from: reelApp, screen: "photos", selectedListingID: listingA, orgID: orgA, liveBackend: true) == nil, "other screen cannot transmit reel progress")
            job.listingID = UUID()
            try check(CoachModel.reelState(from: reelApp, screen: "reel_studio", selectedListingID: listingA, orgID: orgA, liveBackend: true) == nil, "wrong listing job cannot become selected context")
            job.listingID = listingA
            try check(CoachModel.reelState(from: reelApp, screen: "reel_studio", selectedListingID: listingA, orgID: orgB, liveBackend: true) == nil, "foreign cached project cannot expose a job snapshot")
            var legacyContext = sent; legacyContext.context.reelState = nil
            try check((legacyContext.wireBody["context"] as! [String: Any])["reel_state"] == nil, "legacy request omits optional reel state")
            let photoStep = CoachOffline.nextStep(model: reelApp, space: .realEstate, orgID: orgA, liveBackend: true, selectedListingID: listingA, intent: "Edit these photos")
            try check(photoStep.action?.kind == .openPhotos, "photo intent starts Photos without requiring a walkthrough")
            let reelStep = CoachOffline.nextStep(model: reelApp, space: .realEstate, orgID: orgA, liveBackend: true, selectedListingID: listingA, screen: "reel_studio")
            try check(reelStep.action?.kind == .openReel, "current Reel Studio wins over walkthrough onboarding offline")
            let emptyPhotos = CoachOffline.nextStep(model: AppModel(), space: .realEstate, intent: "Edit my photos")
            try check(emptyPhotos.action?.kind == .startProject && emptyPhotos.text.contains("address and details"), "new photo project starts address/details rather than capture")
            let allowance = CoachOffline.answer(to: "My AI allowance is exhausted", model: reelApp, space: .realEstate, orgID: orgA, liveBackend: true, selectedListingID: listingA)
            try check(allowance.action?.kind == .openPlanUsage && allowance.text.contains("can't verify"), "budget refusal has local account help without any paid request")

            let aerialHelp = CoachOffline.nextStep(model: reelApp, space: .realEstate, orgID: orgA, liveBackend: true, selectedListingID: listingA, intent: "Make an aerial")
            try check(aerialHelp.action?.kind == .openAerial && aerialHelp.action?.listingID == listingA.uuidString && aerialHelp.text.contains("AI aerial intro"), "selected-project opening help keeps the exact listing")
            reelApp.coachRoute = nil
            reelCoach.perform(.init(type: "open_photos", label: "Photos remain available", listingID: listingA.uuidString))
            try check(reelApp.coachRoute == .project(listingID: listingA, feature: .photos), "same current Coach context can still open photos")
            reelApp.coachRoute = nil
            reelCoach.perform(.init(type: "open_aerial", label: "Open the accepted opening flow", listingID: listingA.uuidString))
            try check(reelApp.coachRoute == .project(listingID: listingA, feature: .aerial), "available opening action retains the selected listing and workspace")
            // An acknowledged actor/listing-bound server row permits different
            // support guidance; a local phase or missing reply never proves it.
            reset()
            let serverApp = model(), serverJob = ReelWorkJob(listingID: listingA)
            let op = UUID(), actor = UUID(uuidString: AuthStore.shared.userID!)!
            serverJob.serverJob = SavedServerJob(context: .init(actorID: actor, orgID: orgA, localListingID: listingA, listingID: listingA), request: .init(operationID: op, sources: [0,1,2]))
            ReelWorkQueue.shared.visibleJobs = [serverJob]
            let pending = CoachModel.reelState(from: serverApp, screen: "reel_studio", selectedListingID: listingA, orgID: orgA, liveBackend: true)
            try check(pending?.execution == .awaitingAcceptance && pending?.serverPhase == nil, "saved request without reply cannot prove server acceptance")
            let pendingHelp = CoachOffline.answer(to: "Can I lock my phone while waiting?", model: serverApp, space: .realEstate, orgID: orgA, liveBackend: true, selectedListingID: listingA, screen: "reel_studio")
            try check(pendingHelp.text.contains("no accepted server-job receipt") && !pendingHelp.text.contains("It can continue"), "pending operation gets no background completion promise")
            serverJob.serverJob?.reply = .init(operationID: op, listingID: listingA, selectedLibraryOrgID: orgA, sourceCount: 3, state: "generating", completedSources: 1, result: .init(originalPhotoCount: 1))
            let acknowledged = CoachModel.reelState(from: serverApp, screen: "reel_studio", selectedListingID: listingA, orgID: orgA, liveBackend: true)
            try check(acknowledged?.execution == .serverAccepted && acknowledged?.completed == 1 && acknowledged?.stillPhotoShots == 1, "acknowledged scoped server state preserves exact counts")
            let backgroundHelp = CoachOffline.answer(to: "Can I lock my phone while waiting?", model: serverApp, space: .realEstate, orgID: orgA, liveBackend: true, selectedListingID: listingA, screen: "reel_studio")
            try check(backgroundHelp.text.contains("can continue after you close the app") && backgroundHelp.text.contains("does not regenerate"), "accepted job receives truthful background recovery help")
            serverJob.serverJob?.reply?.state = "failed"; serverJob.serverJob?.reply?.resumeAvailable = true
            let resumable = CoachOffline.answer(to: "Why is this waiting?", model: serverApp, space: .realEstate, orgID: orgA, liveBackend: true, selectedListingID: listingA, screen: "reel_studio")
            try check(resumable.text.contains("Resume saved video") && resumable.text.contains("completed shots are retained"), "resume support requires exact failed server flag")
            serverJob.serverJob?.reply?.resumeAvailable = false
            let failed = CoachOffline.answer(to: "Why is this waiting?", model: serverApp, space: .realEstate, orgID: orgA, liveBackend: true, selectedListingID: listingA, screen: "reel_studio")
            try check(failed.text.contains("needs review") && !failed.text.contains("can continue after"), "terminal job is not described as working")
            serverJob.serverJob?.reply?.operationID = UUID()
            try check(CoachModel.reelState(from: serverApp, screen: "reel_studio", selectedListingID: listingA, orgID: orgA, liveBackend: true) == nil, "mismatched operation cannot supply accepted state")
            serverJob.serverJob?.reply?.operationID = op; serverJob.serverJob?.context.actorID = UUID()
            try check(CoachModel.reelState(from: serverApp, screen: "reel_studio", selectedListingID: listingA, orgID: orgA, liveBackend: true) == nil, "other actor saved job is private")
            // Photo-only publication routes to listing Share controls, without
            // needing a recorded walkthrough and without executing publication.
            let sharing = CoachModel(model: serverApp, originScreen: "listing", listingID: listingA)
            serverApp.listings[0].shareURL = "https://example.invalid/property/synthetic"
            sharing.perform(.init(type: "share_tour", label: "Share", listingID: listingA.uuidString))
            try check(serverApp.coachRoute == .listingDetails(listingID: listingA) && serverApp.assets.isEmpty && serverApp.tours.isEmpty, "photo-only published website opens listing details instead of capture")
            serverApp.coachRoute = nil; serverApp.listings[0].shareURL = nil
            sharing.perform(.init(type: "share_tour", label: "Share", listingID: listingA.uuidString))
            try check(serverApp.coachRoute == nil, "unpublished listing cannot offer Share")
            serverApp.listings[0].shareURL = "https://example.invalid/property/synthetic"; serverApp.listings[0].cloudUnavailable = true
            sharing.perform(.init(type: "share_tour", label: "Share", listingID: listingA.uuidString))
            try check(serverApp.coachRoute == nil, "revoked listing cannot open Share controls")
            serverApp.listings[0].cloudUnavailable = false
            let photoCoach = CoachModel(model: serverApp, originScreen: "photo_studio", listingID: listingA, photoState: .init(tab: .staged, selectedCount: 2))
            try await send("Which photos am I reviewing?", through: photoCoach)
            try check(serverApp.api.requests.last?.context.photoState == .init(tab: .staged, selectedCount: 2), "current saved-results tab supplies closed hints")
            photoCoach.updatePhotoState(.init(tab: .original, selectedCount: 4))
            try await send("What is selected now?", through: photoCoach)
            let photoRequest = serverApp.api.requests.last!
            try check(photoRequest.context.photoState == .init(tab: .original, selectedCount: 4), "photo tab and count refresh at next send")
            let photoWire = (photoRequest.wireBody["context"] as! [String: Any])["photo_state"] as! [String: Any]
            try check(Set(photoWire.keys) == Set(["tab", "selected_count"]) && photoWire["tab"] as? String == "original", "photo hints never include version/style/media contents")
            var unrelatedScreen = photoRequest; unrelatedScreen.context.screen = "home"
            try check((unrelatedScreen.wireBody["context"] as! [String: Any])["photo_state"] == nil, "other screen cannot transmit Photo Studio selection")
            let photoFirst = CoachOffline.nextStep(model: model(), space: .realEstate, orgID: orgA, liveBackend: true, selectedListingID: listingA)
            try check(photoFirst.action?.kind == .openPhotos && photoFirst.text.contains("landscape"), "new listing starts photos without forcing capture")
            reset()
            // The actual Home picker excludes Sold/Archived. A context opened
            // from one of those homes must retain only that explicit home.
            let inactive = model(), soldID = UUID(), archivedID = UUID()
            var sold = Listing(id: soldID, address: "985 Closed Home Avenue, Synthetic City", shareURL: "https://fixture.invalid/sold", serverOrgID: orgA)
            sold.isSold = true; sold.serverID = UUID()
            var archived = Listing(id: archivedID, address: "987 Archived Home Avenue, Synthetic City", serverOrgID: orgA)
            archived.isArchived = true
            inactive.listings += [sold, archived]
            try check(!inactive.realProjects.contains { $0.id == soldID || $0.id == archivedID }, "fixture models real active-only feature picker")
            let soldCoach = CoachModel(model: inactive, originScreen: "listing", listingID: soldID)
            try await send("How do I change this home's website design?", through: soldCoach)
            let soldRequest = inactive.api.requests.last!
            try check(soldRequest.context.selectedListingID == soldID.uuidString.lowercased() && soldRequest.context.listings.first?.id == soldID.uuidString, "selected Sold home remains the current website support context")
            try check(!soldRequest.context.listings.contains { $0.id == archivedID.uuidString }, "unselected inactive homes stay out of support context")
            try check(soldRequest.context.listings.first?.title == "Closed Home Avenue", "selected Sold home title remains redacted")
            try await send("Help with 985 Closed Home Avenue, Synthetic City", through: soldCoach)
            try check(inactive.api.requests.last?.messages.last?.content == "Help with Closed Home Avenue", "selected inactive home address is redacted at history boundary")
            soldCoach.perform(.init(type: "share_tour", label: "Open website", listingID: soldID.uuidString))
            try check(inactive.coachRoute == .listingDetails(listingID: soldID), "selected Sold website action retains its exact listing route")
            inactive.coachRoute = nil
            soldCoach.perform(.init(type: "open_photos", label: "Other archived home", listingID: archivedID.uuidString))
            try check(inactive.coachRoute == nil, "unselected inactive action cannot borrow selected exception")
            let soldOffline = CoachOffline.nextStep(model: inactive, space: .realEstate, orgID: orgA, liveBackend: true, selectedListingID: soldID)
            try check(soldOffline.action?.kind == .shareTour && soldOffline.action?.listingID == soldID.uuidString, "offline help keeps the exact selected Sold website")
            inactive.listings[1].lastError = "Synthetic private failure"
            inactive.assets[soldID] = Asset()
            let soldRecovery = CoachOffline.recovery(to: "Why is this failed?", model: inactive, space: .realEstate, orgID: orgA, liveBackend: true, selectedListingID: soldID)
            try check(soldRecovery?.action?.listingID == soldID.uuidString, "recovery retains selected Sold home without paid retry")
            let archivedCoach = CoachModel(model: inactive, originScreen: "photos", listingID: archivedID, photoState: .init(tab: .original, selectedCount: 1))
            try await send("What can I do with this photo?", through: archivedCoach)
            try check(inactive.api.requests.last?.context.selectedListingID == archivedID.uuidString.lowercased() && inactive.api.requests.last?.context.photoState?.selectedCount == 1, "explicit selected Archived home retains photo screen context")
            for reason in ["sample", "type", "unavailable", "owner", "library", "visibility"] {
                let forbidden = model(); var candidate = sold
                switch reason {
                case "sample": candidate.isSample = true
                case "type": candidate.belongsToCurrentType = false
                case "unavailable": candidate.cloudUnavailable = true
                case "owner": candidate.cloudSyncOwnerID = UUID()
                case "library": candidate.serverLibraryOrgID = orgB
                default: forbidden.libraryVisible = false
                }
                forbidden.listings = [candidate]
                let scoped = CoachModel.contextListings(from: forbidden, orgID: orgA, liveBackend: true, selectedListingID: soldID)
                try check(!scoped.contains { $0.id == soldID.uuidString }, "inactive selected exception refuses \(reason)")
                let guardCoach = CoachModel(model: forbidden, originScreen: "listing", listingID: soldID)
                guardCoach.perform(.init(type: "share_tour", label: "Forbidden", listingID: soldID.uuidString))
                try check(forbidden.coachRoute == nil, "inactive selected action refuses \(reason)")
                let safe = CoachOffline.nextStep(model: forbidden, space: .realEstate, orgID: orgA, liveBackend: true, selectedListingID: soldID)
                try check(safe.action?.kind == .openHome && safe.action?.listingID == nil, "inactive selected fallback refuses \(reason)")
            }
            let delegated = model(); var delegatedSold = sold
            delegatedSold.serverOrgID = orgB; delegatedSold.serverLibraryOrgID = orgA
            delegated.listings = [delegatedSold]
            try check(CoachModel.contextListings(from: delegated, orgID: orgA, liveBackend: true, selectedListingID: soldID).first?.id == soldID.uuidString, "authorized selected inactive library grouping does not rewrite physical org")
            var delegatedActive = delegatedSold; delegatedActive.isSold = false
            delegated.listings = [delegatedActive]
            try check(CoachModel.contextListings(from: delegated, orgID: orgA, liveBackend: true, selectedListingID: soldID).first?.id == soldID.uuidString && delegated.listings[0].serverOrgID == orgB, "authorized active logical library is retained without changing physical org")
            delegatedActive.serverOrgID = orgA; delegatedActive.serverLibraryOrgID = orgB
            delegated.listings = [delegatedActive]
            try check(CoachModel.contextListings(from: delegated, orgID: orgA, liveBackend: true, selectedListingID: soldID).isEmpty, "foreign active logical library stays excluded")

            print("PASS: \(assertions) production Coach privacy/scope assertions; actual offline-to-online sends, no network/providers/customer files")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
