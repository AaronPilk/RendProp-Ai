import Foundation

struct APIError: Error { let status: Int; let code: String? }

@MainActor final class SelectionFixture: ListingPhotoCloudSelectionAPI {
    let identity = PhotoCloudSelectionIdentity(actorID: UUID(), libraryOrgID: UUID(), localListingID: UUID(), serverListingID: UUID())
    let physical = UUID(), a = UUID(), a2 = UUID(), b = UUID(), b2 = UUID()
    var ids: [UUID]? = [], cover: String?, receipts: [UUID: PhotoCloudSelectionSnapshot.Receipt] = [:]
    var abandoned: [UUID:PhotoCloudSelectionRequest] = [:]
    var abandonCount = 0
    var patchCount = 0, getCount = 0, prepareCount = 0, validateCount = 0
    var rejectTargetValidation = false
    var loseReply = false, failGET = false, refusal: APIError?, wrongReceipt = false, wrongRequest = false
    var beforeGET: (() -> Void)?
    var beforePATCH: (() -> Void)?
    var afterPATCH: (() -> Void)?
    var catalog: [PhotoCloudLocalVersion] = []
    var lastOperation: PhotoCloudSelectionOperation?
    func key(_ id: UUID) -> String { "renders/\(physical.uuidString.lowercased())/\(identity.serverListingID.uuidString.lowercased())/gallery-\(id.uuidString.lowercased()).jpg" }
    func digest(_ n: Int) -> String { String(repeating: String(n), count: 64) }
    func reset() {
        ids = [a,b]; cover = key(b); receipts = [:]; abandoned = [:]; abandonCount = 0; patchCount = 0; getCount = 0; prepareCount = 0; validateCount = 0; rejectTargetValidation = false
        loseReply = false; failGET = false; refusal = nil; wrongReceipt = false; wrongRequest = false; beforeGET = nil; beforePATCH = nil; afterPATCH = nil; lastOperation = nil
        catalog = [local("a", "A", a, 1),local("a2", "A", a2, 2),local("b", "B", b, 3),local("b2", "B", b2, 4)]
    }
    func local(_ id: String, _ family: String, _ asset: UUID?, _ n: Int, complete: Bool = true) -> PhotoCloudLocalVersion {
        .init(id: id, familyID: family, imageFile: id + ".jpg", sha256: digest(n), bytes: Int64(n * 100), knownAssetID: asset, historyComplete: complete)
    }
    func snapshot(operationID: UUID?, patch: Bool = false) throws -> PhotoCloudSelectionSnapshot {
        let assets: [[String: Any]] = (ids ?? [a,b]).compactMap { id in
            let canonical: (String,Int64)? = id == a ? (digest(1),100) : id == a2 ? (digest(2),200)
                : id == b ? (digest(3),300) : id == b2 ? (digest(4),400)
                : catalog.first(where: { $0.knownAssetID == id }).map { ($0.sha256,$0.bytes) }
            guard let canonical else { return nil }
            return ["asset_id":id.uuidString,"sha256":canonical.0,"bytes":canonical.1,"storage_key":key(id)]
        }
        let receipt = operationID.flatMap { receipts[$0] }
        var body: [String: Any] = ["schema":1,"actor_id":identity.actorID.uuidString,"org_id":physical.uuidString,
            "library_org_id":identity.libraryOrgID.uuidString,"listing_id":identity.serverListingID.uuidString,
            "gallery_asset_ids":ids.map { $0.map(\.uuidString) as Any } ?? NSNull(),"main_photo_key":cover as Any? ?? NSNull(),
            "effective_asset_ids":(ids ?? [a,b]).map(\.uuidString),"gallery_assets":assets,"operation":NSNull(),"operation_status":operationID == nil ? NSNull() : (receipt == nil ? "not_found" : "accepted") as Any,"abandoned_operation":NSNull()]
        if let receipt { body["operation"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) }
        if let operationID, let request = abandoned[operationID], receipt == nil {
            body["operation_status"] = "abandoned"
            body["abandoned_operation"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(PhotoCloudSelectionSnapshot.AbandonedReceipt(operationID:operationID,request:request)))
        }
        if patch { body["ok"] = true; body["replayed"] = false }
        return try JSONDecoder().decode(PhotoCloudSelectionSnapshot.self, from: JSONSerialization.data(withJSONObject: body))
    }
    func photoCloudSelection(identity: PhotoCloudSelectionIdentity, physicalOrgID: UUID?, operationID: UUID?) async throws -> PhotoCloudSelectionSnapshot {
        getCount += 1
        beforeGET?()
        if failGET { throw URLError(.notConnectedToInternet) }
        return try snapshot(operationID: operationID)
    }
    func changePhotoCloudSelection(_ operation: PhotoCloudSelectionOperation) async throws -> PhotoCloudSelectionSnapshot {
        patchCount += 1; lastOperation = operation
        beforePATCH?()
        if let refusal { throw refusal }
        let request = operation.request
        if abandoned[operation.operationID] != nil { throw APIError(status:409,code:"abandoned") }
        guard request.expectedSelection == PhotoCloudSelectionRaw(galleryAssetIDs: ids, mainPhotoKey: cover) else {
            throw APIError(status: 409, code: "gallery_selection_changed")
        }
        if request.promoteCover {
            guard let target = request.target, (ids ?? [a,b]).contains(target.assetID),
                  (ids ?? [a,b]).filter({ request.familyAssetIDs.contains($0) }).count == 1 else { throw APIError(status:409,code:"not_selected") }
            cover = key(target.assetID)
            receipts[operation.operationID] = .init(operationID:operation.operationID,request:request,result:.init(galleryAssetIDs:ids,mainPhotoKey:cover))
            afterPATCH?()
            if loseReply { throw URLError(.timedOut) }
            return try snapshot(operationID:operation.operationID,patch:true)
        }
        var next: [UUID] = [], inserted = false
        for id in ids ?? [a,b] {
            if request.familyAssetIDs.contains(id) {
                if let target = request.target, !inserted { next.append(target.assetID); inserted = true }
            } else { next.append(id) }
        }
        if let target = request.target, !inserted { next.append(target.assetID) }
        let familyCover = request.familyAssetIDs.contains { key($0) == cover }
        ids = next
        if familyCover { cover = request.target.map { key($0.assetID) } }
        receipts[operation.operationID] = .init(operationID: wrongReceipt ? UUID() : operation.operationID,
            request: wrongRequest ? .init(familyAssetIDs:request.familyAssetIDs,target:request.target,
                expectedSelection:request.expectedSelection,followFamilyCover:request.followFamilyCover,reviewed:!request.reviewed) : request,
            result: .init(galleryAssetIDs: ids, mainPhotoKey: cover))
        afterPATCH?()
        if loseReply { throw URLError(.timedOut) }
        return try snapshot(operationID: operation.operationID, patch: true)
    }
    func abandonPhotoCloudSelection(_ operation:PhotoCloudSelectionOperation) async throws -> PhotoCloudSelectionSnapshot {
        abandonCount += 1
        if receipts[operation.operationID] == nil { abandoned[operation.operationID] = operation.request }
        var body = try JSONSerialization.jsonObject(with:JSONEncoder().encode(snapshot(operationID:operation.operationID,patch:true))) as! [String:Any]
        body["abandoned"] = receipts[operation.operationID] == nil
        if loseReply { throw URLError(.timedOut) }
        return try JSONDecoder().decode(PhotoCloudSelectionSnapshot.self,from:JSONSerialization.data(withJSONObject:body))
    }

}

@main struct PhotoCloudSelectionChecks {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fixture = SelectionFixture(); fixture.reset()
        var count = 0, serial = 0
        func check(_ passed: Bool, _ message: String) {
            guard passed else { fputs("FAIL: \(message)\n",stderr); exit(1) }; count += 1
        }
        func make() -> (PhotoCloudSelectionCoordinator,PhotoCloudSelectionJournal) {
            serial += 1
            let store = PhotoCloudSelectionJournal(directory: root.appendingPathComponent("case-\(serial)"))
            return (PhotoCloudSelectionCoordinator(store:store),store)
        }
        func refresh(_ c: PhotoCloudSelectionCoordinator, identityCheck: @escaping @MainActor () throws -> Void = {}) async throws -> PhotoCloudSelectionProjection {
            try await c.refresh(identity:fixture.identity,physicalOrgID:fixture.physical,api:fixture,
                catalog:{ fixture.catalog },requireIdentity:identityCheck)
        }
        func change(_ c: PhotoCloudSelectionCoordinator, _ id:String = "a2", selecting:Bool = true,
                    follow:Bool = false, promote:Bool = false, identityCheck: @escaping @MainActor () throws -> Void = {}) async throws -> PhotoCloudSelectionProjection {
            try await c.change(identity:fixture.identity,physicalOrgID:fixture.physical,versionID:id,selecting:selecting,
                followFamilyCover:follow,reviewed:false,promoteCover:promote,api:fixture,catalog:{ fixture.catalog },prepare:{ _,_ in fixture.prepareCount += 1 },
                validateTarget: { version, asset, storageKey in
                    fixture.validateCount += 1
                    guard version.id == id, version.knownAssetID == asset,
                          storageKey == nil || storageKey == fixture.key(asset), !fixture.rejectTargetValidation else {
                        throw PhotoCloudSelectionFailure.changed
                    }
                }, requireIdentity:identityCheck)
        }
        func refuses(_ name:String,_ work: () async throws -> Void) async {
            do { try await work(); check(false,name) } catch { check(true,name) }
        }
        var (c,store) = make()
        var projection = try await refresh(c)
        check(projection.selectedVersionIDs == ["a","b"],"Read projects exact selected versions")
        check(projection.coverVersionIDs == ["b"],"Cover uses exact cloud storage key")
        check(projection.label(versionID:"a2") == "Another version on listing","Saved edit does not inherit selected badge")
        check(fixture.patchCount == 0 && fixture.prepareCount == 0,"Refresh cannot prepare or mutate")
        projection = try await change(c)
        check(fixture.ids == [fixture.a2,fixture.b],"One-family choice preserves unrelated slot")
        check(fixture.cover == fixture.key(fixture.b),"One-family choice preserves unrelated cover")
        check(projection.selectedVersionIDs == ["a2","b"],"Acknowledged current snapshot drives publication")
        check(try store.load(fixture.identity) == nil,"Exact receipt retires only its saved operation")
        check(fixture.lastOperation?.request.familyAssetIDs == [fixture.a,fixture.a2].sorted { $0.uuidString < $1.uuidString },"Complete family footprint is captured")
        check(fixture.validateCount == 1, "selected target is validated before the cloud mutation")

        fixture.reset(); (c,store) = make(); fixture.rejectTargetValidation = true
        await refuses("Invalid target is refused before mutation") { _ = try await change(c) }
        let pendingAfterTargetRefusal = try store.load(fixture.identity)
        check(fixture.validateCount == 1 && fixture.patchCount == 0 && pendingAfterTargetRefusal == nil,
              "target validation refusal never opens a mutation journal or PATCHes")

        fixture.reset(); (c,store) = make(); fixture.loseReply = true
        await refuses("Lost reply remains an error") { _ = try await change(c) }
        check(fixture.patchCount == 1,"Lost reply dispatched one PATCH")
        let pending = try store.load(fixture.identity)
        check(pending != nil,"Lost reply persists immutable operation")
        fixture.ids = [fixture.b2,fixture.a]; fixture.cover = fixture.key(fixture.b2)
        let relaunched = PhotoCloudSelectionCoordinator(store:store)
        projection = try await refresh(relaunched)
        check(projection.selectedVersionIDs == ["a","b2"] && projection.coverVersionIDs == ["b2"],"Historical receipt cannot undo later Studio choice")
        check(fixture.patchCount == 1 && !projection.pending,"Relaunch reconciles GET only")
        check(try store.load(fixture.identity) == nil,"Exact recovery receipt retires journal")
        _ = try await refresh(relaunched)
        check(fixture.patchCount == 1,"Repeated refresh never replays PATCH")

        fixture.reset(); (c,store) = make(); fixture.loseReply = true
        await refuses("Set up absent receipt uncertainty") { _ = try await change(c) }
        fixture.receipts = [:]
        projection = try await refresh(c)
        check(projection.pending && projection.mutableFamilyIDs.isEmpty,"Missing receipt keeps truthful pending fence")
        await refuses("Pending cannot authorize a new PATCH") { _ = try await change(c,"b2") }
        check(fixture.patchCount == 1,"Pending never reposts")
        fixture.failGET = true
        await refuses("Failed GET retains uncertainty") { _ = try await refresh(c) }
        check(try store.load(fixture.identity) != nil,"Failed recovery GET cannot retire journal")

        fixture.reset(); (c,store) = make(); fixture.refusal = .init(status:409,code:"gallery_selection_changed")
        await refuses("CAS409 is still surfaced") { _ = try await change(c) }
        check(try store.load(fixture.identity) == nil,"Only exact CAS code retires refused attempt")
        fixture.reset(); (c,store) = make(); fixture.refusal = .init(status:409,code:"photo_qc_hold")
        await refuses("QC refusal remains refusal") { _ = try await change(c) }
        check(try store.load(fixture.identity) != nil,"Other409 does not erase uncertainty")
        fixture.reset(); (c,store) = make(); fixture.wrongReceipt = true
        await refuses("Wrong operation receipt rejected") { _ = try await change(c) }
        check(try store.load(fixture.identity) != nil,"Wrong receipt cannot retire journal")

        fixture.reset(); (c,store) = make(); var current = true
        fixture.afterPATCH = { current = false }
        await refuses("Account change after dispatch fences acknowledgment") {
            _ = try await change(c,identityCheck:{ if !current { throw PhotoCloudSelectionFailure.identityChanged } })
        }
        check(try store.load(fixture.identity) != nil,"Identity change retains saved operation")
        current = true; fixture.afterPATCH = nil
        fixture.catalog[1] = fixture.local("a2","A",fixture.a2,8)
        await refuses("Changed captured bytes refuse recovery") { _ = try await refresh(c) }
        check(try store.load(fixture.identity) != nil,"Changed bytes do not falsely acknowledge old local version")

        fixture.reset(); (c,store) = make()
        fixture.catalog.append(fixture.local("alias","C",fixture.a,1))
        projection = try await refresh(c)
        check(projection.mutableFamilyIDs.isEmpty,"Cross-family byte aliases remain unmapped")
        await refuses("Ambiguous mapping cannot mutate") { _ = try await change(c) }
        check(fixture.patchCount == 0,"Unmapped family has zero PATCHes")
        fixture.reset(); (c,store) = make(); fixture.ids = [fixture.a,UUID()]
        projection = try await refresh(c)
        check(projection.mutableFamilyIDs.isEmpty,"Unknown selected cloud asset blocks partial family mutation")
        fixture.reset(); (c,store) = make(); fixture.catalog[0] = fixture.local("a","A",fixture.a,1,complete:false)
        projection = try await refresh(c)
        check(projection.mutableFamilyIDs.isEmpty,"Incomplete local history cannot certify cloud footprint")

        fixture.reset(); (c,store) = make(); fixture.cover = fixture.key(fixture.a)
        await refuses("Cover follow requires explicit confirmation") { _ = try await change(c) }
        check(fixture.patchCount == 0,"No implicit cover change")
        projection = try await change(c,follow:true)
        check(fixture.cover == fixture.key(fixture.a2) && projection.coverVersionIDs == ["a2"],"Explicit existing-family cover follows target")
        fixture.reset(); (c,store) = make()
        await refuses("Cannot promote another family through follow flag") { _ = try await change(c,follow:true) }
        check(fixture.patchCount == 0,"Cover endpoint gap cannot invent promotion")

        fixture.reset(); (c,store) = make(); fixture.ids = nil
        _ = try await change(c)
        check(fixture.lastOperation?.request.expectedSelection.galleryAssetIDs == nil,"Raw NULL remains NULL in CAS")
        let body = try fixture.lastOperation!.request.body(operationID:fixture.lastOperation!.operationID)
        check((body["expected_selection"] as? [String:Any])?["gallery_asset_ids"] is NSNull,"Wire explicitly retains NULL")
        fixture.reset(); (c,store) = make(); fixture.ids = []
        _ = try await change(c)
        check(fixture.lastOperation?.request.expectedSelection.galleryAssetIDs == [],"Empty selection is not legacy NULL")
        check(fixture.catalog.count == 4,"Read and choose do not rewrite local history")
        fixture.reset(); (c,store) = make()
        projection = try await change(c,"a",promote:true)
        check(fixture.ids == [fixture.a,fixture.b] && fixture.cover == fixture.key(fixture.a),"Explicit selected-only star preserves selection/order")
        check(fixture.lastOperation?.request.promoteCover == true,"Only explicit star carries promote marker")
        fixture.reset(); (c,store) = make(); fixture.ids = nil
        _ = try await change(c,"a",promote:true)
        check(fixture.ids == nil && fixture.lastOperation?.request.expectedSelection.galleryAssetIDs == nil,"Cover-only star preserves raw NULL")
        fixture.reset(); (c,store) = make()
        await refuses("Unselected star cannot borrow promotion authority") { _ = try await change(c,"a2",promote:true) }
        check(fixture.patchCount == 0,"Unselected promotion has zero PATCHes")

        fixture.reset(); (c,store) = make(); fixture.loseReply = true
        await refuses("Prepare pending accepted choice for abandon") { _ = try await change(c) }
        fixture.loseReply = false; fixture.ids = [fixture.b2,fixture.a]; fixture.cover = fixture.key(fixture.b2)
        projection = try await c.abandon(identity:fixture.identity,physicalOrgID:fixture.physical,api:fixture,catalog:{fixture.catalog},requireIdentity:{})
        check(fixture.abandonCount == 1 && fixture.patchCount == 1,"Abandon does not repeat accepted PATCH")
        let acceptedJournal = try store.load(fixture.identity)
        check(projection.selectedVersionIDs == ["a","b2"] && acceptedJournal == nil,"Accepted choice wins abandon; newer current state wins UI")
        fixture.reset(); (c,store) = make(); fixture.loseReply = true
        await refuses("Prepare never-accepted pending choice") { _ = try await change(c) }
        fixture.receipts = [:]; fixture.loseReply = false
        projection = try await c.abandon(identity:fixture.identity,physicalOrgID:fixture.physical,api:fixture,catalog:{fixture.catalog},requireIdentity:{})
        let closedJournal = try store.load(fixture.identity)
        check(!projection.pending && closedJournal == nil,"Exact terminal tombstone retires pending request")
        let abandonedOp = fixture.lastOperation!
        do { _ = try await fixture.changePhotoCloudSelection(abandonedOp);check(false,"Delayed abandoned request must refuse") } catch {}
        check(fixture.receipts[abandonedOp.operationID] == nil,"Abandoned request cannot create acceptance receipt")
        fixture.reset(); (c,store) = make(); fixture.loseReply = true
        await refuses("Prepare lost abandon setup") { _ = try await change(c) }
        fixture.receipts = [:]
        await refuses("Lost abandon reply remains pending") {
            _ = try await c.abandon(identity:fixture.identity,physicalOrgID:fixture.physical,api:fixture,catalog:{fixture.catalog},requireIdentity:{})
        }
        check(try store.load(fixture.identity) != nil,"Lost POST cannot retire journal")
        projection = try await refresh(c)
        check(!projection.pending && fixture.abandonCount == 1,"Refresh reads terminal tombstone without repeating POST")

        fixture.reset(); (c,store) = make()
        let initial = try store.beginInitial(.init(identity:fixture.identity,versions:[fixture.catalog[1],fixture.catalog[3]]))
        check(initial.completedVersionIDs.isEmpty,"Initial publication captures ordered targets durably")
        fixture.loseReply = true
        await refuses("Initial first family accepted with lost reply") { _ = try await change(c) }
        check(try store.initialIntent(fixture.identity)?.completedVersionIDs == [],"Unknown reply cannot advance initial queue")
        fixture.ids = [fixture.a,fixture.b]; fixture.cover = fixture.key(fixture.b)
        _ = try await refresh(PhotoCloudSelectionCoordinator(store:store))
        check(try store.initialIntent(fixture.identity)?.completedVersionIDs == ["a2"],"Accepted recovery advances initial queue before retiring operation")
        check(fixture.ids == [fixture.a,fixture.b] && fixture.patchCount == 1,"Queue recovery cannot restore historical first-family choice")
        let reopened = PhotoCloudSelectionJournal(directory:root.appendingPathComponent("case-\(serial)"))
        check(try reopened.initialIntent(fixture.identity)?.completedVersionIDs == ["a2"],"Initial progress survives journal relaunch")
        fixture.loseReply = false
        _ = try await change(c,"b2",follow:true)
        check(try store.initialIntent(fixture.identity)?.completedVersionIDs == ["a2","b2"],"Separate second-family receipt advances ordered queue")
        try store.finishInitial(fixture.identity)
        check(try store.initialIntent(fixture.identity) == nil,"Only complete initial queue is retired")
        fixture.reset(); (c,store) = make(); fixture.catalog[0] = fixture.local("a","A",nil,1)
        projection = try await refresh(c)
        check(projection.mutableFamilyIDs.isEmpty && projection.selectedVersionIDs.isEmpty,"Uncached digest-only match remains neutral without scoped family receipt")
        await refuses("Uncached selected bytes cannot authorize family subtraction") { _ = try await change(c) }
        check(fixture.patchCount == 0,"Missing family receipt has zero PATCHes")
        fixture.reset(); (c,store) = make(); fixture.loseReply = true
        await refuses("Prepare accepted receipt for physical-org fence") { _ = try await change(c) }
        let prior = fixture.lastOperation!
        let oldOrgStore = PhotoCloudSelectionJournal(directory: root.appendingPathComponent("foreign-physical"))
        let foreignPhysical = PhotoCloudSelectionOperation(operationID:prior.operationID,identity:prior.identity,physicalOrgID:UUID(),
            familyID:prior.familyID,versionID:prior.versionID,imageFile:prior.imageFile,sha256:prior.sha256,bytes:prior.bytes,request:prior.request)
        try oldOrgStore.begin(foreignPhysical)
        let otherPhysical = PhotoCloudSelectionCoordinator(store:oldOrgStore)
        await refuses("Changed physical-org cannot acknowledge prior pending operation") {
            _ = try await otherPhysical.refresh(identity:fixture.identity,physicalOrgID:fixture.physical,api:fixture,catalog:{fixture.catalog},requireIdentity:{})
        }
        check(try oldOrgStore.load(fixture.identity) != nil,"Physical-org change cannot retire old journal")
        await refuses("Missing current physical mapping still compares returned scope to saved operation") {
            _ = try await otherPhysical.refresh(identity:fixture.identity,physicalOrgID:nil,api:fixture,catalog:{fixture.catalog},requireIdentity:{})
        }
        check(try oldOrgStore.load(fixture.identity) != nil,"Returned physical-org change cannot retire old journal")

        fixture.reset(); (c,store) = make(); fixture.wrongRequest = true
        await refuses("Matching operation ID with different frozen request must refuse") { _ = try await change(c) }
        check(try store.load(fixture.identity) != nil,"Changed receipt intent cannot retire journal")
        print("\(count) assertions PASS")
    }
}
