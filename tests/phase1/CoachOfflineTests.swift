// Executes the complete production CoachModel.swift and CoachAPI.swift.
// Only unrelated app/environment dependencies are small inert stand-ins.
// No network, disk-backed app state, auth, purchase or deletion is invoked.
import Foundation
import Combine

typealias ObservableObject = Combine.ObservableObject
typealias Published<Value> = Combine.Published<Value>
enum ProjectFeature: Equatable { case tour, photos, reel, floorPlan, aerial }
struct Listing { let id: UUID; let address: String; var shareURL: String? = nil }
struct Asset { var roomTags: [String] = [] }
enum SpaceType: String {
    case realEstate = "real_estate"
    static var current: Self { .realEstate }
    var spaceNoun: String { "home" }
}
@MainActor final class AppModel {
    var listings: [Listing] = []
    var realProjects: [Listing] { listings }
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
enum EnhancedPhoto {
    static func loadAll(listingID: UUID) -> [Int] { fatalError("No real photo reads") }
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
            let expected = "No account is required to record, edit, build or publish a tour. " +
                "Publishing needs an internet connection. Sign in with Apple is optional " +
                "for accessing your workspace on another device."
            for query in queries {
                let response = CoachOffline.answer(to: query, model: model, space: .realEstate)
                try check(response.text.hasPrefix(expected), "actual account reply still requires identity: \(query)")
                try check(response.text.contains("I'm answering offline right now"), "offline disclosure missing")
                try check(response.action?.kind == .openSupport, "existing support action changed")
                try check(response.action?.listingID == nil, "account help must not invent a listing")
                try check(!response.text.contains("fully signed out"), "do not confuse anonymous session with no session")
            }
            let listing = Listing(id: UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!,
                                  address: "SYNTHETIC TEST HOME")
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
            print("PASS: \(assertions) actual offline Coach response assertions; 0 skipped; no API/app-state access")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
