import Foundation

@main enum ProductionPlanTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        guard try condition() else { throw Failure(message: message) }
    }
    struct Failure: Error { let message: String }
    static func rejects(_ plan: ProductionPlan) -> Bool { (try? plan.checked()) == nil }

    static func main() throws {
        let listing = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        let source = "20000000-0000-4000-8000-000000000001"
        for recipe in ProductionRecipe.allCases {
            let starter = ProductionPlan.starter(listingID: listing, recipe: recipe)
            try expect(try starter.checked(listingID: listing) == starter, "Starter is valid for \(recipe)")
            try expect(starter.targetSeconds == 45, "Shared default length")
            try expect(starter.shots.allSatisfy { $0.status == .needed && $0.sourcePhotoIds.isEmpty && $0.sourceVideoIds.isEmpty }, "No invented capture or upload")
        }
        var plan = ProductionPlan.starter(listingID: listing)
        try expect(plan.shots.count == 8 && plan.remainingCount == 6, "Shared listing recipe and optional coverage")
        plan.shots[0].status = .captured; plan.shots[0].sourceVideoIds = [source]; plan.shots[0].notes = "Hold the porch at the end"
        plan.shots[1].status = .notNeeded
        try expect(plan.remainingCount == 4 && plan.linkedSourceCount == 1, "Manual status and genuine links are separate")
        try plan.changeRecipe(.marketUpdate)
        try expect(plan.shots.contains { $0.id == "exterior" && !$0.required && $0.sourceVideoIds == [source] && $0.notes == "Hold the porch at the end" }, "Changing format preserves completed work")
        try expect(plan.shots.contains { $0.id == "entry" && !$0.required && $0.status == .notNeeded }, "Skipped shot is retained as optional")
        try expect(plan.shots.first { $0.id == "closing" }?.status == .needed, "Shared closing is preserved")
        try plan.changeRecipe(.listingHighlight)
        try expect(plan.shots.contains { $0.id == "exterior" && $0.required && $0.sourceVideoIds == [source] && $0.notes == "Hold the porch at the end" }, "Switching back restores required coverage and keeps media and notes")
        let decoded = try JSONDecoder().decode(ProductionPlan.self, from: JSONEncoder().encode(plan))
        try expect(decoded == plan, "Round trip shared contract")
        let envelope = CloudProductionDocument(listing_id: listing, revision: 2, payload: plan)
        try expect(try envelope.checked(listingID: listing).revision == 2, "Correct revision accepted")
        try expect((try? envelope.checked(listingID: UUID())) == nil, "Wrong listing envelope rejected")
        let sent = ProductionPlanCache.Draft(plan: plan, revision: 1, dirty: true)
        let clean = try ProductionPlanAcknowledgement.apply(envelope, attempt: sent, current: sent)
        try expect(clean.revision == 2 && !clean.dirty && clean.plan == plan, "Exact reply acknowledges the sent snapshot")
        var typing = sent; typing.plan.notes = "Typed while the request was running"
        let rebased = try ProductionPlanAcknowledgement.apply(envelope, attempt: sent, current: typing)
        try expect(rebased.revision == 2 && rebased.dirty && rebased.plan.notes == typing.plan.notes, "Reply never overwrites newer local typing")
        try expect(ProductionPlanAcknowledgement.accepts(envelope, attempt: sent), "Lost POST reply can be reconciled from exact next revision")
        try expect(!ProductionPlanAcknowledgement.accepts(.init(listing_id: listing, revision: 3, payload: plan), attempt: sent), "Later remote revision cannot acknowledge this write")
        try expect(!ProductionPlanAcknowledgement.accepts(.init(listing_id: listing, revision: 2, payload: typing.plan), attempt: sent), "Another device’s payload cannot acknowledge this write")
        var alreadyAdvanced = typing; alreadyAdvanced.revision = 2
        try expect((try? ProductionPlanAcknowledgement.apply(envelope, attempt: sent, current: alreadyAdvanced)) == nil, "Stale acknowledgement cannot regress a newer revision")
        var bad = plan; bad.shots[0].sourcePhotoIds = [source, source]
        try expect(rejects(bad), "Duplicate linked source rejected")
        bad = plan; bad.shots[0].sourceVideoIds = ["file:///private/phone.mov"]
        try expect(rejects(bad), "Private paths rejected as source IDs")
        bad = plan; bad.shots[0].id = "../capture"
        try expect(rejects(bad), "Invalid shot slug rejected")
        bad = plan; bad.shots.append(bad.shots[0])
        try expect(rejects(bad), "Duplicate shots rejected")
        bad = plan; bad.shots = []
        try expect(rejects(bad), "Empty shared plan rejected")
        bad = plan; bad.notes = String(repeating: "🏠", count: 1001)
        try expect(rejects(bad), "UTF16 note limit matches web contract")
        bad = plan; bad.targetSeconds = 0
        try expect(rejects(bad), "Invalid target rejected")
        bad = plan; bad.listingId = "not-a-listing"
        try expect(rejects(bad), "Invalid listing rejected")

        let kitchen = ProductionGuidance.shots(for: .listingHighlight).first { $0.id == "kitchen" }!
        let matches = ProductionGuidance.matchingChapters(kitchen, names: [
            ("Kitchen", 4, false), ("KITCHEN", 6, false), ("Kitchen side", 7, true),
            ("Kitchen missing", 999, false), ("Kitchen invalid", -.infinity, false), ("Living", 1, false)
        ], duration: 10)
        try expect(matches == ["Kitchen"], "Only confirmed in-range chapter labels suggested, deduplicated")
        try expect(ProductionGuidance.matchingChapters(kitchen, names: [("Kitchen", 1, false)], duration: .nan).isEmpty, "Invalid asset duration cannot imply coverage")

        // A phone's old upload manifest is a cache, not a command to re-create
        // assignments the editor has removed or moved on another device.
        let entryID = UUID()
        let oldLink = ProductionVideoLink(entryID: entryID, assetID: source, shotID: "exterior", uploaded: true, pending: false)
        let removed = ProductionPlan.starter(listingID: listing)
        let afterRemoval = ProductionVideoLink.reconciling([oldLink], pullSnapshot: [oldLink], remote: removed)
        try expect(afterRemoval[0].shotID == nil && !afterRemoval[0].pending, "Loading a desktop removal clears the stale local assignment")
        try expect(ProductionVideoLink.applying(afterRemoval, to: removed).plan == removed, "Loading a desktop removal cannot resurrect the link")
        var moved = removed; moved.shots[3].sourceVideoIds = [source]
        let afterMove = ProductionVideoLink.reconciling([oldLink], pullSnapshot: [oldLink], remote: moved)
        try expect(afterMove[0].shotID == "kitchen" && !afterMove[0].pending, "Loading a desktop move updates the library's visible assignment")
        try expect(ProductionVideoLink.applying(afterMove, to: moved).plan == moved, "Loading a desktop move cannot add the old exterior link")
        var newReceipt = oldLink; newReceipt.pending = true
        let beforeReceipt = ProductionVideoLink(entryID: entryID, assetID: source, shotID: "exterior", uploaded: false, pending: true)
        let duringPull = ProductionVideoLink.reconciling([newReceipt], pullSnapshot: [beforeReceipt], remote: removed)
        let mergedReceipt = ProductionVideoLink.applying(duringPull, to: removed)
        try expect(mergedReceipt.plan.shots[0].sourceVideoIds == [source] && mergedReceipt.acknowledged == [entryID], "A newly completed upload during GET still joins the accepted cloud plan")
        var newerAssignment = oldLink; newerAssignment.shotID = "living"; newerAssignment.pending = true
        let duringAssignment = ProductionVideoLink.reconciling([newerAssignment], pullSnapshot: [oldLink], remote: moved)
        let reassigned = ProductionVideoLink.applying(duringAssignment, to: moved)
        try expect(reassigned.plan.shots[2].sourceVideoIds == [source] && reassigned.plan.shots[3].sourceVideoIds.isEmpty, "An explicit newer phone assignment survives GET and moves the link once")
        var explicitRemoval = oldLink; explicitRemoval.shotID = nil; explicitRemoval.pending = true
        try expect(ProductionVideoLink.applying([explicitRemoval], to: moved).plan.shots[3].sourceVideoIds.isEmpty, "An explicit phone unassignment removes the prior source link")
        try expect(ProductionVideoLink.applying([oldLink], to: removed).plan == removed, "An already acknowledged upload alone can never recreate a removed link")

        let suite = "rendprop-production-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let draft = ProductionPlanCache.Draft(plan: plan, revision: 3, dirty: true)
        try ProductionPlanCache.save(draft, owner: "owner-a", listingID: listing, defaults: defaults)
        try expect(try ProductionPlanCache.load(owner: "owner-a", listingID: listing, defaults: defaults) == draft, "Unsynced draft and revision survive reopening")
        try expect(try ProductionPlanCache.load(owner: "owner-b", listingID: listing, defaults: defaults) == nil, "Another account cannot load the draft")
        try expect(try ProductionPlanCache.load(owner: "owner-a", listingID: UUID(), defaults: defaults) == nil, "Another property cannot load the draft")
        var uncertain = typing
        uncertain.pendingWrite = .init(plan: sent.plan, revision: sent.revision)
        try ProductionPlanCache.save(uncertain, owner: "owner-a", listingID: listing, defaults: defaults)
        let reopened = try ProductionPlanCache.load(owner: "owner-a", listingID: listing, defaults: defaults)!
        try expect(reopened.pendingWrite?.plan == sent.plan && reopened.plan == typing.plan, "Relaunch preserves uncertain A separately from newer local B")
        let uncertainAttempt = ProductionPlanCache.Draft(plan: reopened.pendingWrite!.plan, revision: reopened.pendingWrite!.revision, dirty: true)
        let settled = try ProductionPlanAcknowledgement.apply(envelope, attempt: uncertainAttempt, current: reopened)
        try expect(settled.revision == 2 && settled.plan == typing.plan && settled.dirty && settled.pendingWrite == nil, "Settling A advances B without dropping typing or retaining stale attempt")
        let nextEnvelope = CloudProductionDocument(listing_id: listing, revision: 3, payload: settled.plan)
        let finished = try ProductionPlanAcknowledgement.apply(nextEnvelope, attempt: settled, current: settled)
        try expect(finished.revision == 3 && !finished.dirty && finished.plan == typing.plan, "B can then sync sequentially at the advanced base revision")
        ProductionPlanCache.remove(listingID: listing, defaults: defaults)
        try expect(try ProductionPlanCache.load(owner: "owner-a", listingID: listing, defaults: defaults) == nil, "Property deletion removes recovery draft")
        print("PASS: \(checks) production contract, preservation, coverage and account recovery checks")
    }
}
