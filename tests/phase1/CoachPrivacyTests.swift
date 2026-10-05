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
    var realProjects: [Listing] { listings }
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
enum EnhancedPhoto { static func loadAll(listingID: UUID) -> [Int] { [] } }
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
            print("PASS: \(assertions) production Coach privacy/scope assertions; actual offline-to-online sends, no network/providers/customer files")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
