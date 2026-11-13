// Executes the complete production CoachModel.swift and CoachAPI.swift.
// Only unrelated app/environment dependencies are small inert stand-ins.
// No network, disk-backed app state, auth, purchase or deletion is invoked.
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
    let id: UUID; let address: String; var shareURL: String? = nil
    var serverOrgID: UUID? = nil; var cloudDraftOrgID: UUID? = nil
    var serverLibraryOrgID: UUID? = nil
    var isSample = false; var belongsToCurrentType = true; var isInactive = false
}
struct Asset { var roomTags: [String] = [] }
enum SpaceType: String {
    case realEstate = "real_estate"
    static var current: Self { .realEstate }
    var spaceNoun: String { "home" }
}
enum Config { static let useLiveBackend = false }
@MainActor final class AuthStore {
    static let shared = AuthStore()
    var userID: String? = nil
    var syncSessionRevision: UInt64 = 0
}
enum WorkspaceContext { static let selectedOrgID: UUID? = nil }
enum CloudSyncError: Error { case identityChanged }
@MainActor final class AppModel {
    var listings: [Listing] = []
    var realProjects: [Listing] { listings.filter { !$0.isSample && $0.belongsToCurrentType && !$0.isInactive } }
    func isInSelectedWorkspace(_ listing: Listing) -> Bool { true } // Offline app boundary; Config.useLiveBackend=false.
    var assets: [UUID: Asset] = [:]
    var tours: [UUID: String] = [:]
    var coachRoute: CoachRoute?
    let api = UnusedAPI()
}
struct UnusedAPI {
    func coach(_ request: CoachRequest) async throws -> CoachResponse {
        fatalError("This offline-response test must not call an API")
    }
}
enum Analytics {
    static func track(_ event: String, _ properties: [String: String] = [:]) {
        fatalError("This offline-response test must not emit analytics")
    }
}
@MainActor final class AIConsent {
    static let shared = AIConsent()
    func ensureGranted() async -> Bool { fatalError("Call CoachOffline directly") }
}
@MainActor final class PurchaseManager {
    static let shared = PurchaseManager()
    var activePlan: String? { fatalError("No purchase state in this test") }
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
    static var documents: URL { fatalError("No real document reads") }
}

@main @MainActor
struct CoachOfflineTests {
    enum Failure: Error { case assertion(String) }
    static var assertions = 0
    static func check(_ value: Bool, _ reason: String) throws {
        assertions += 1
        if !value { throw Failure.assertion(reason) }
    }
    static func main() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            fputs("FAIL: offline Coach tests exceeded their deadline\n", stderr)
            exit(1)
        }
        do {
            if CommandLine.arguments.contains("--force-failure") {
                try check(false, "intentional offline Coach gate failure")
            }
            let model = AppModel()
            let queries = ["Do I need an account?", "Is an account needed?",
                           "Can I publish as a guest?", "Do I have to sign in?",
                           "CAN I PUBLISH AS A GUEST?"]
            let expected = "Local recording and saved photo work can stay on this phone. Publishing and online " +
                "AI tools require an identified account, an internet connection and the required " +
                "AI consent/access. Sign in with Apple to open or adopt your account; a guest session " +
                "cannot publish or use paid AI until sign-in."
            for query in queries {
                let response = CoachOffline.answer(to: query, model: model, space: .realEstate)
                try check(response.text.hasPrefix(expected), "actual account reply must distinguish local work from identified online tools: \(query)")
                try check(response.text.contains("I'm answering offline right now"), "offline disclosure missing")
                try check(response.action?.kind == .openSupport, "existing support action changed")
                try check(response.action?.listingID == nil, "account help must not invent a listing")
                try check(!response.text.contains("fully signed out"), "do not confuse anonymous session with no session")
            }
            let listing = Listing(id: UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!,
                                  address: "SYNTHETIC TEST HOME", shareURL: "https://example.invalid/property/synthetic")
            model.listings = [listing]
            model.assets[listing.id] = Asset()
            model.tours[listing.id] = "synthetic"
            let existing = CoachOffline.answer(to: "Do I need an account?", model: model, space: .realEstate)
            try check(existing.text.hasPrefix(expected), "existing project must not change account answer")

            // Detect a broken matcher that returns the new answer for everything.
            let mls = CoachOffline.answer(to: "How do I share to the MLS?", model: model, space: .realEstate)
            try check(mls.text.hasPrefix("Publishing gives you two links."), "unrelated MLS topic changed")
            try check(!mls.text.hasPrefix(expected), "account answer swallowed another topic")
            let next = CoachOffline.answer(to: "What next?", model: model, space: .realEstate)
            try check(next.action?.kind == .shareTour, "existing completed-project fallback changed")
            try check(next.action?.listingID == listing.id.uuidString, "fallback lost actual synthetic listing")
            model.listings = []
            let empty = CoachOffline.answer(to: "What next?", model: model, space: .realEstate)
            try check(empty.action?.kind == .startProject, "empty-project fallback changed")
            let deletion = CoachOffline.answer(to: "Delete my account", model: model, space: .realEstate)
            try check(deletion.text.contains("anonymous session"), "offline deletion must acknowledge guest server identity")
            try check(deletion.text.contains("not a local-only wipe"), "offline deletion must not pretend guests are local-only")
            try check(deletion.text.contains("cleanup may remain pending"), "do not promise immediate cleanup")
            try check(deletion.text.contains("shared-team data is not all deleted"), "do not promise deletion of colleagues' data")
            try check(deletion.text.contains("does not cancel an App Store subscription"), "preserve billing distinction")
            try check(deletion.action?.kind == .openSupport, "topic reply must not execute deletion")
            let measurements = CoachOffline.answer(to: "How do I use Measurements?", model: model, space: .realEstate)
            for required in ["Coming soon", "cards on Home", "do not open yet", "no plan includes them", "upload a plan", "certified survey"] {
                try check(measurements.text.contains(required), "actual offline Measurements guidance omitted: \(required)")
            }
            try check(!measurements.text.contains("LiDAR phones can also scan"), "ordinary offline help must not promise automatic generation")
            let aerial = CoachOffline.answer(to: "Make an aerial intro", model: model, space: .realEstate)
            try check(aerial.text.contains(LaunchFeatureAvailability.openingMessage) && aerial.text.contains("Resume earlier aerial"), "offline aerial help distinguishes the available opening from saved legacy work")
            try check(aerial.action?.kind == .openSupport, "offline aerial help does not dispatch generation without a selected listing")
            let aerialNext = CoachOffline.nextStep(model: model, space: .realEstate, intent: "Make an aerial")
            try check(aerialNext.action?.kind == .startProject && aerialNext.text.contains("address and details"), "no-project aerial intent starts a listing before an opening")
            print("PASS: \(assertions) actual offline Coach response assertions; 0 skipped; no API/app-state access")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
