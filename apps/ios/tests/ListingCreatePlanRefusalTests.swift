import Foundation
import CryptoKit

// Closed transport and identity boundaries; product methods below are extracted unchanged.
enum FileStore { static func url(fromRelativePath path: String) -> URL { URL(fileURLWithPath: "/isolated/\(path)") } }
enum Config { static let useLiveBackend = true; static let enableAuth = true }
func coarseCoordinate(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
__API_ERROR__
__ENTITLEMENTS__
struct UsageSummary { var entitlements: Entitlements? }
@MainActor enum WorkspaceContext { static var selectedOrgID: UUID? = UUID(uuidString: "22222222-2222-4222-8222-222222222222") }
@MainActor final class WorkspaceStore {
    static let shared = WorkspaceStore()
    func canViewLibrary(_ org: UUID) -> Bool { org == WorkspaceContext.selectedOrgID }
    func refresh() async {}
}
@MainActor final class AuthStore {
    static let shared = AuthStore()
    var isIdentified = true
    var isSignedIn = true
    var userID: String? = "11111111-1111-4111-8111-111111111111"
    var syncSessionRevision: UInt64 = 1
    static func validAccessToken() async -> String? { "closed-fixture-token" }
}
struct AssertionFailure: Error { let message: String }
@MainActor final class HeldBoundary {
    var arrivals = 0
    var continuation: CheckedContinuation<Void, Never>?
    func hold() async { arrivals += 1; await withCheckedContinuation { continuation = $0 } }
    func release() { let waiting = continuation; continuation = nil; waiting?.resume() }
}
@MainActor final class ClosedAPI {
    var creates = 0
    var updates = 0
    var reads = 0
    var plan: Entitlements? = Entitlements(plan: "free", rendersPerMonth: 0, photoEditsPerMonth: 0, reelsPerMonth: 0, aerialsPerMonth: 0, topazPerMonth: 0, used: [:], leads: 0)
    var read: (() async throws -> UsageSummary)?
    var createError: Error? = APIError.server(status: 402, code: "plan_required", message: "Listing creation starts after the free week")
    var duringCreate: (() -> Void)?
    var updateError: Error?
    func me() async throws -> UsageSummary { reads += 1; if let read { return try await read() }; return UsageSummary(entitlements: plan) }
    func createListing(_ draft: Listing) async throws -> Listing {
        creates += 1; duringCreate?()
        if let createError { throw createError }
        var saved = draft; saved.serverID = UUID(); saved.serverOrgID = draft.cloudDraftOrgID
        return saved
    }
    func deleteListing(serverID: UUID) async throws {}
    func updateListing(_ listing: Listing) async throws -> Listing { updates += 1; if let updateError { throw updateError }; return listing }
    func updateMeasurements(_ listing: Listing) async throws -> Listing { listing }
}
@MainActor final class PlanSyncModel {
    var listings: [Listing]
    var syncInFlight = Set<UUID>()
__BATCH_STATE__
    var serverCreationInFlight = Set<UUID>()
    var cloudRefreshTask: Task<Void, Never>?
    var cloudRefreshOperation: UUID?
    let api = ClosedAPI()
    init(_ listings: [Listing]) { self.listings = listings }
    func index(of id: UUID) -> Int? { listings.firstIndex { $0.id == id } }
    func pendingAdoptionBlocksServerListing(_ id: UUID) -> Bool { false }
    func refreshCloudWorkspace() async {
        // Closed remote read between the two real draft-sync passes, matching
        // the real refresh's source-checked batch lifetime.
        let batch = beginDraftCreationPlanBatch()
        defer { endDraftCreationPlanBatch(batch) }
        await syncDirtyListings()
        await Task.yield()
        await syncDirtyListings()
    }
    func planChanged() async { await refreshCloudWorkspaceAfterCurrent(retryPlanRequired: false) }
    func planChangedDuringStandaloneBatch() async {
        let batch = beginDraftCreationPlanBatch()
        defer { endDraftCreationPlanBatch(batch) }
        await syncDirtyListings()
        api.plan?.plan = "pro"; api.createError = nil
        await planChanged()
    }
__MESSAGE__
__BEGIN_BATCH__
__END_BATCH__
__PUBLISH_ERROR__
__USER_MESSAGE__
__WORKSPACE__
__CAN_RETRY__
__FAILURE__
__ENSURE__
__SYNC__
__DIRTY__
__RETRY__
__AFTER_CURRENT__
}
@main struct ListingCreatePlanRefusalChecks {
    @MainActor static func main() async {
        do { try await run() } catch { print("FAIL: \(error)"); exit(1) }
    }
    @MainActor static func run() async throws {
        var count = 0
        func check(_ ok: Bool, _ name: String) throws { if !ok { throw AssertionFailure(message: name) }; count += 1 }
        func wait(_ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !predicate() { if Date() > deadline { throw AssertionFailure(message: "Closed boundary did not arrive") }; await Task.yield() }
        }
        let actor = UUID(uuidString: AuthStore.shared.userID!)!, org = WorkspaceContext.selectedOrgID!
        func reset() { AuthStore.shared.userID = actor.uuidString; AuthStore.shared.syncSessionRevision = 1; AuthStore.shared.isIdentified = true; WorkspaceContext.selectedOrgID = org }
        func draft() -> Listing {
            var value = Listing(address: "Synthetic saved draft", beds: 2, baths: 1, sqft: 900, price: Money(cents: 10000))
            value.cloudSyncOwnerID = actor; value.cloudDraftOrgID = org
            value.mainPhotoRelPath = "synthetic-photo.jpg"
            return value
        }
        func model() -> PlanSyncModel { reset(); return PlanSyncModel([draft()]) }
        let m = model(), id = m.listings[0].id
        await m.syncListing(id)
        try check(m.api.creates == 1 && m.listings[0].cloudCreatePlanBlocked == true, "Typed plan refusal saves a create pause")
        try check(m.api.reads == 0, "Ordinary draft creation makes no extra plan read")
        try check(m.listings[0].lastError == PlanSyncModel.draftCreationPlanMessage && m.listings[0].mainPhotoRelPath == "synthetic-photo.jpg", "Plan refusal explains the saved local draft without deleting photos")
        let firstKey = m.listings[0].cloudCreateFingerprint
        for _ in 0..<15 { await m.syncListing(id) }
        try check(m.api.creates == 1, "Known refusal suppresses fifteen automatic creates")
        try check(m.api.reads == 15, "Only paused draft attempts read fresh plan state")
        m.api.plan?.used["renders"] = 4
        await m.syncDirtyListings()
        try check(m.api.creates == 1, "Usage changes do not unlock draft creation")
        let restored = try JSONDecoder().decode(Listing.self, from: JSONEncoder().encode(m.listings[0]))
        try check(restored.cloudCreatePlanBlocked == true && restored.cloudCreatePlanSignature == m.listings[0].cloudCreatePlanSignature, "The create pause survives snapshot restoration")
        let old = try JSONDecoder().decode(Listing.self, from: Data("{}".utf8))
        try check(old.cloudCreatePlanBlocked == nil && old.cloudCreatePlanSignature == nil, "Older snapshots remain readable")
        do { _ = try await m.ensureServerListing(m.listings[0]) } catch {}
        try check(m.api.creates == 1, "Direct creation honors the saved pause")
        await m.retryCloudWorkspace()
        try check(m.api.creates == 2 && m.listings[0].cloudCreatePlanBlocked == true, "Explicit retry makes one new attempt and preserves a repeated refusal")
        try check(m.listings[0].cloudCreateFingerprint == firstKey, "Retry preserves the exact durable create fingerprint")
        m.api.plan?.plan = "pro"; m.api.createError = nil
        await m.syncDirtyListings()
        try check(m.api.creates == 3 && m.listings[0].serverID != nil, "A changed fresh entitlement permits one automatic create")
        try check(m.listings[0].cloudCreatePlanBlocked == nil && m.listings[0].cloudCreatePlanSignature == nil && m.listings[0].lastError == nil, "Successful create retires only the plan pause and its warning")

        let newlyPaid = model(); await newlyPaid.syncDirtyListings()
        newlyPaid.api.plan?.plan = "pro"; newlyPaid.api.plan?.planSource = "app_review"; newlyPaid.api.createError = nil
        await newlyPaid.syncDirtyListings()
        try check(newlyPaid.api.creates == 2 && newlyPaid.listings[0].serverID != nil, "A paid grant before the first paused refresh recovers automatically")
        let paidRefusal = model(); await paidRefusal.syncDirtyListings(); paidRefusal.api.plan?.plan = "pro"
        await paidRefusal.syncDirtyListings(); await paidRefusal.syncDirtyListings(); await paidRefusal.syncDirtyListings()
        try check(paidRefusal.api.creates == 2 && paidRefusal.listings[0].cloudCreatePlanBlocked == true, "A newly observed paid plan permits only one refused retry")
        reset()
        var batchDrafts = [draft(), draft(), draft()]
        for i in batchDrafts.indices { batchDrafts[i].cloudCreatePlanBlocked = true }
        let batch = PlanSyncModel(batchDrafts)
        await batch.syncDirtyListings()
        try check(batch.api.reads == 1 && batch.api.creates == 0, "Paused drafts share one fresh plan read per batch")
        let readsBeforeRefresh = batch.api.reads
        await batch.refreshCloudWorkspace()
        try check(batch.api.reads == readsBeforeRefresh + 1, "A whole refresh shares one plan read across both real sync passes")
        batch.api.plan?.plan = "pro"; batch.api.createError = nil
        await batch.syncDirtyListings()
        try check(batch.api.reads == 3 && batch.api.creates == 3, "Next batch refreshes plan once and recovers all matching drafts")

        let generic: [Error] = [APIError.server(status: 400, code: "plan_required", message: "validation"), APIError.server(status: 402, code: nil, message: "old server"), APIError.server(status: 402, code: "quota_exceeded", message: "quota"), APIError.server(status: 503, code: "plan_required", message: "unavailable")]
        for error in generic {
            let v = model(); v.api.createError = error
            await v.syncListing(v.listings[0].id); await v.syncListing(v.listings[0].id)
            try check(v.api.creates == 2 && v.listings[0].cloudCreatePlanBlocked == nil, "Generic errors retain automatic recovery")
        }
        let cancelled = model(); cancelled.api.createError = CancellationError()
        await cancelled.syncDirtyListings()
        try check(cancelled.listings[0].cloudCreatePlanBlocked == nil && cancelled.listings[0].lastError == nil, "Cancellation does not create a plan pause")
        let unavailable = model(); unavailable.api.read = { throw APIError.badResponse(503) }
        await unavailable.syncDirtyListings()
        try check(unavailable.api.creates == 1, "Unavailable plan read does not block an unpaused draft")
        await unavailable.syncDirtyListings()
        try check(unavailable.api.creates == 1, "Unavailable plan read cannot unlock a paused draft")
        unavailable.api.read = nil
        await unavailable.syncDirtyListings(); await unavailable.syncDirtyListings()
        try check(unavailable.api.creates == 1 && unavailable.listings[0].cloudCreatePlanSignature != nil, "First later plan read establishes an unknown baseline without retry")
        unavailable.api.plan?.plan = "pro"; unavailable.api.createError = nil
        await unavailable.syncDirtyListings()
        try check(unavailable.api.creates == 2, "Changed later plan can recover an initially unknown baseline")

        for mutation in 0..<3 {
            let v = model(); v.listings[0].cloudCreatePlanBlocked = true
            v.api.read = {
                if mutation == 0 { AuthStore.shared.syncSessionRevision += 1 }
                if mutation == 1 { AuthStore.shared.userID = UUID().uuidString }
                if mutation == 2 { WorkspaceContext.selectedOrgID = UUID() }
                return UsageSummary(entitlements: v.api.plan)
            }
            await v.syncDirtyListings()
            try check(v.api.creates == 0 && v.listings[0].cloudCreatePlanSignature == nil, "Stale plan response cannot create after session change")
        }
        let late = model(); late.api.duringCreate = { AuthStore.shared.syncSessionRevision += 1 }
        await late.syncDirtyListings()
        try check(late.listings[0].cloudCreatePlanBlocked == nil && late.listings[0].lastError == nil, "Late refusal cannot poison a replacement session")
        let deleted = model(); deleted.listings[0].cloudCreatePlanBlocked = true; deleted.api.read = { deleted.listings = []; return UsageSummary(entitlements: deleted.api.plan) }
        await deleted.syncDirtyListings()
        try check(deleted.api.creates == 0 && deleted.listings.isEmpty, "Deleted draft is not recreated after a plan read")
        let foreign = model(); foreign.listings[0].cloudDraftOrgID = UUID(); foreign.listings[0].cloudCreatePlanBlocked = true
        await foreign.retryCloudWorkspace()
        try check(foreign.listings[0].cloudCreatePlanBlocked == true && foreign.api.creates == 0, "Explicit retry preserves another library pause")
        let foreignActor = model(); foreignActor.listings[0].cloudSyncOwnerID = UUID(); foreignActor.listings[0].cloudCreatePlanBlocked = true
        await foreignActor.retryCloudWorkspace()
        try check(foreignActor.listings[0].cloudCreatePlanBlocked == true && foreignActor.api.creates == 0, "Explicit retry preserves another actor pause")
        let updating = model(); updating.listings[0].serverID = UUID(); updating.listings[0].serverOrgID = org; updating.listings[0].needsServerSync = true
        updating.api.updateError = APIError.server(status: 402, code: "plan_required", message: "write refused")
        await updating.syncDirtyListings()
        try check(updating.api.updates == 1 && updating.listings[0].cloudCreatePlanBlocked == nil, "An existing listing write does not become a create pause")
        let busy = model(); await busy.syncDirtyListings()
        let held = HeldBoundary(); busy.cloudRefreshOperation = UUID()
        busy.cloudRefreshTask = Task { await held.hold() }
        try await wait { held.arrivals == 1 }
        var retryStarted = false
        let retry = Task { retryStarted = true; await busy.retryCloudWorkspace() }
        try await wait { retryStarted }
        try check(busy.api.creates == 1, "Explicit retry waits for an existing refresh before creating")
        held.release(); await retry.value
        try check(busy.api.creates == 2, "Explicit retry starts a new pass after an existing refresh")

        let staleRetry = model(); await staleRetry.syncDirtyListings()
        let oldRefresh = HeldBoundary(); staleRetry.cloudRefreshOperation = UUID()
        staleRetry.cloudRefreshTask = Task { await oldRefresh.hold() }
        try await wait { oldRefresh.arrivals == 1 }
        var oldRetryStarted = false
        let oldRetry = Task { oldRetryStarted = true; await staleRetry.retryCloudWorkspace() }
        try await wait { oldRetryStarted }
        AuthStore.shared.syncSessionRevision += 1
        oldRefresh.release(); await oldRetry.value
        try check(staleRetry.api.creates == 1 && staleRetry.listings[0].cloudCreatePlanBlocked == true, "A retry requested by an old session preserves the saved pause")

        let event = model(); await event.syncDirtyListings(); await event.syncDirtyListings()
        let previousRefresh = HeldBoundary(); event.cloudRefreshOperation = UUID()
        event.cloudRefreshTask = Task { await previousRefresh.hold() }
        try await wait { previousRefresh.arrivals == 1 }
        event.api.plan?.plan = "pro"; event.api.createError = nil
        var eventStarted = false
        let eventTask = Task { eventStarted = true; await event.planChanged() }
        try await wait { eventStarted }
        try check(event.api.creates == 1, "Plan change waits for the current refresh")
        previousRefresh.release(); await eventTask.value
        try check(event.api.creates == 2 && event.listings[0].serverID != nil, "Plan change schedules a new fresh pass rather than joining stale work")
        let overlapping = model(); await overlapping.syncDirtyListings()
        await overlapping.planChangedDuringStandaloneBatch()
        try check(overlapping.api.creates == 2 && overlapping.api.reads == 2 && overlapping.listings[0].serverID != nil, "Plan event discards the old standalone batch plan read")
        reset()
        print("PASS: \(count) assertions")
    }
}
