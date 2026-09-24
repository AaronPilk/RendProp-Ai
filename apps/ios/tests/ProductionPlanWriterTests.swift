import Foundation

// Minimal identity dependency for the production writer, which is compiled
// unchanged into this offline executable. No app keychain or network is used.
@MainActor final class AuthStore {
    static let shared = AuthStore()
    var isIdentified = true
    var userID: String?
    var syncSessionRevision: UInt64 = 1
}

private actor TestWire: ProductionSyncAPI {
    enum Failure: Error { case disconnected, conflict }
    let listingID: UUID
    var document: CloudProductionDocument?
    var writes: [ProductionPlan] = []
    var holdNext = false
    var failNextRead = false
    var lostReply: CheckedContinuation<Void, Never>?
    init(listingID: UUID) { self.listingID = listingID }
    func prepareLostReply() { holdNext = true; failNextRead = true }
    func releaseLostReply() { lostReply?.resume(); lostReply = nil }
    func isHeld() -> Bool { lostReply != nil }
    func snapshot() -> (CloudProductionDocument?, [ProductionPlan]) { (document, writes) }
    func productionPlan(listingID: UUID, orgID: UUID) async throws -> CloudProductionDocument? {
        if failNextRead { failNextRead = false; throw Failure.disconnected }
        return document
    }
    func saveProductionPlan(_ plan: ProductionPlan, listingID: UUID, orgID: UUID, revision: Int) async throws -> CloudProductionDocument {
        writes.append(plan)
        guard revision == (document?.revision ?? 0) else { throw Failure.conflict }
        let accepted = CloudProductionDocument(listing_id: listingID, revision: revision + 1, payload: plan)
        document = accepted
        if holdNext {
            holdNext = false
            await withCheckedContinuation { lostReply = $0 }
            throw Failure.disconnected
        }
        return accepted
    }
    func competingEdit(_ note: String) {
        guard let current = document else { return }
        var plan = current.payload; plan.notes = note
        document = .init(listing_id: listingID, revision: current.revision + 1, payload: plan)
    }
}

@main @MainActor enum ProductionPlanWriterTests {
    enum Failure: Error { case assertion(String) }
    static var checks = 0
    static func expect(_ condition: Bool, _ message: String) throws {
        checks += 1
        guard condition else { throw Failure.assertion(message) }
    }
    static func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw Failure.assertion("Timed out waiting for the offline writer")
    }
    static func main() async throws {
        let listingID = UUID(), orgID = UUID(), owner = UUID().uuidString.lowercased()
        let context = ProductionPlanSyncStore.Context(owner: owner, listingID: listingID)
        let identity = "\(owner):1"
        AuthStore.shared.userID = owner
        defer { ProductionPlanCache.remove(listingID: listingID) }
        let store = ProductionPlanSyncStore()
        try store.load(context, serverID: listingID)
        var a = store.drafts[context.key]!
        a.plan.notes = "A: approved opening"; a.dirty = true
        try store.replace(a, context: context)
        let wire = TestWire(listingID: listingID)
        await wire.prepareLostReply()
        let first = Task { await store.save(context, serverID: listingID, orgID: orgID, api: wire, identity: identity) }
        try await wait { await wire.isHeld() }
        try expect(store.saving.contains(context.key), "Actual writer exposes in-flight state")
        let parallel = await store.save(context, serverID: listingID, orgID: orgID, api: wire, identity: identity)
        let dispatched = await wire.snapshot()
        try expect(!parallel && dispatched.1.count == 1, "One property cannot dispatch two simultaneous writers")
        var b = store.drafts[context.key]!
        b.plan.notes = "B: newer typing while A is in flight"; b.dirty = true
        try store.replace(b, context: context)
        await wire.releaseLostReply()
        try expect(!(await first.value), "Lost POST and GET replies stay unconfirmed")
        let uncertain = try ProductionPlanCache.load(owner: owner, listingID: listingID)!
        try expect(uncertain.pendingWrite?.plan.notes == a.plan.notes && uncertain.plan.notes == b.plan.notes, "Exact uncertain A and newer B are durably separate")
        try expect(store.errors[context.key] != nil && uncertain.dirty, "Failure is visible and keeps local edits dirty")

        // Simulate a process restart: all view/writer memory is discarded.
        let reopened = ProductionPlanSyncStore()
        try reopened.load(context, serverID: listingID)
        let reconciled = await reopened.save(context, serverID: listingID, orgID: orgID, api: wire, identity: identity)
        try expect(reconciled, "Retry confirms A at the exact next revision")
        try await wait { (await wire.snapshot()).0?.revision == 2 && reopened.drafts[context.key]?.dirty == false }
        let (remote, calls) = await wire.snapshot()
        try expect(calls.count == 3 && calls[0].notes == a.plan.notes && calls[1].notes == a.plan.notes && calls[2].notes == b.plan.notes, "Retry settles A before the debounced writer sends B")
        try expect(remote?.payload.notes == b.plan.notes && reopened.drafts[context.key]?.revision == 2 && reopened.drafts[context.key]?.pendingWrite == nil, "Cloud and reopened local draft agree on B")

        var c = reopened.drafts[context.key]!
        c.plan.notes = "C: local next edit"; c.dirty = true
        try reopened.replace(c, context: context)
        await wire.competingEdit("Another device’s edit")
        let conflict = await reopened.save(context, serverID: listingID, orgID: orgID, api: wire, identity: identity)
        try expect(!conflict && reopened.drafts[context.key]?.plan.notes == c.plan.notes && reopened.drafts[context.key]?.dirty == true, "A competing device never replaces the local draft")
        try expect((await wire.snapshot()).0?.payload.notes == "Another device’s edit", "A conflicting write never overwrites the remote edit")
        AuthStore.shared.userID = UUID().uuidString.lowercased()
        let otherAccount = await reopened.save(context, serverID: listingID, orgID: orgID, api: wire, identity: identity)
        try expect(!otherAccount, "Changed account cannot dispatch the former account’s draft")
        reopened.cancelPending(context)
        print("PASS: \(checks) actual sequential writer, lost reply, relaunch, autosync and conflict checks")
    }
}
