import Foundation

enum FileStore {
    static var documents = URL(fileURLWithPath: "/nonexistent/fixture-not-initialized")
    static func url(fromRelativePath path: String) -> URL { documents.appendingPathComponent(path) }
}
enum FixturePreferences {
    static let domain = "rendprop.synthetic.adoption-owned." + UUID().uuidString
    static let defaults = UserDefaults(suiteName: domain)!
}
enum AIImagePrep { static func error(_ message: String) -> Error { NSError(domain: "synthetic", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) } }

@main enum AdoptionOwnedIdentityTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message); checks += 1 }
    static func rejects(_ message: String, _ body: () throws -> Void) {
        do { try body(); preconditionFailure(message) } catch { checks += 1 }
    }
    static func cardReceipt(_ owner: UUID, card: [String: String], type: String = "real_estate") -> Data {
        try! JSONSerialization.data(withJSONObject: ["ok":true, "user_id":owner.uuidString.lowercased(), "space_type":type, "public_card":card])
    }
    static func fixture() throws -> (AdoptionLocalBindings, UUID, UUID) {
        let source = UUID(), target = UUID(), id = UUID(), org = UUID()
        let binding = AdoptionLocalBindings(version: 1, operationID: UUID(), sourceUserID: source, destinationUserID: target,
            entries: [.init(localID: id, serverID: UUID(), shareSlug: nil, shareURL: nil, unbrandedShareURL: nil, publishedRenderID: nil)],
            confirmedOrgID: org, appliedToCurrentState: true, productionLocalIDs: [id], personalCardDisposition: "source_copied")
        let d = FixturePreferences.defaults
        for type in SpaceType.allCases.map(\.rawValue) {
            d.set("Guest " + type, forKey: AdoptionOwnedIdentity.fieldKey(source, type: type, field: "name"))
            d.set("+44 20 7946 0958", forKey: AdoptionOwnedIdentity.fieldKey(source, type: type, field: "phone"))
        }
        d.set("real_estate", forKey: AdoptionOwnedIdentity.prefix(source) + "brand.primaryType")
        d.set(true, forKey: AdoptionOwnedIdentity.prefix(source) + "dirty.real_estate")
        d.set(cardReceipt(source, card: ["name":"Guest reviewed"]), forKey: AdoptionOwnedIdentity.prefix(source) + "receipt")
        d.set(Data("synthetic pending explicit guest save".utf8), forKey: AdoptionOwnedIdentity.prefix(source) + "pending")
        try Data("synthetic portrait bytes".utf8).write(to: AdoptionOwnedIdentity.portrait(source, type:"real_estate", documents: FileStore.documents))
        return (binding, id, org)
    }
    static func restore(_ binding: AdoptionLocalBindings, id: UUID, card: [String:String]? = ["name":"Guest reviewed"],
                        verified: Bool = true, active: UUID? = nil) throws {
        try AdoptionOwnedIdentity.restore(binding, activeOwner: active ?? binding.destinationUserID, survivingIDs: [id], documents: FileStore.documents,
            verifiedDestinationCard: card, verifiedDestinationType: "real_estate", destinationCardWasVerified: verified,
            defaults: FixturePreferences.defaults)
    }
    static func pending(_ binding: AdoptionLocalBindings, id: UUID, org: UUID?) -> PendingReelRequest {
        .init(context: .init(listingID:id, serverListingID:binding.entries.first?.serverID,
            owner:binding.sourceUserID.uuidString.lowercased(), workspace:org), photoNumber:1,
            job:.init(requestId:UUID().uuidString, statusUrl:"synthetic-status", responseUrl:"synthetic-response", kind:"reel"),
            operationID:"synthetic-operation", inputDigest:String(repeating:"a", count:64))
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory:true)
        FileStore.documents = root
        defer { FixturePreferences.defaults.removePersistentDomain(forName: FixturePreferences.domain) }
        let d = FixturePreferences.defaults
        let (binding, id, org) = try fixture()
        let foreign = UUID()
        var unconfirmed = binding; unconfirmed.appliedToCurrentState = false; unconfirmed.confirmedOrgID = nil
        rejects("Unconfirmed adoption cannot expose guest personal identity") { try restore(unconfirmed, id:id) }
        rejects("Another account cannot claim a verified adoption") { try restore(binding, id:id, active:foreign) }
        check(d.data(forKey: AdoptionOwnedIdentity.key(binding)) == nil, "Refused adoption creates no recipient journal")
        let sourceRequest = pending(binding, id:id, org:org)
        try sourceRequest.save()
        let destinationContext = PendingReelRequest.Context(listingID:id, serverListingID:binding.entries.first!.serverID,
            owner:binding.destinationUserID.uuidString.lowercased(), workspace:org)
        try restore(binding, id:id)
        for type in SpaceType.allCases.map(\.rawValue) {
            check(d.string(forKey: AdoptionOwnedIdentity.fieldKey(binding.destinationUserID, type:type, field:"name")) == "Guest " + type,
                  "Verified adoption preserves guest card for " + type)
            check(d.string(forKey: AdoptionOwnedIdentity.fieldKey(binding.destinationUserID, type:type, field:"phone")) == "+44 20 7946 0958",
                  "Verified adoption preserves international phone for " + type)
        }
        check(d.bool(forKey: AdoptionOwnedIdentity.prefix(binding.destinationUserID) + "dirty.real_estate"), "Guest local explicit draft remains dirty for deliberate Save")
        check(d.data(forKey: AdoptionOwnedIdentity.prefix(binding.destinationUserID) + "pending") == nil, "Guest pending PATCH is never rebound or automatically queued")
        check(d.data(forKey: AdoptionOwnedIdentity.prefix(binding.destinationUserID) + "receipt") == nil, "Guest acknowledgement is never represented as target receipt")
        check(d.string(forKey: AdoptionOwnedIdentity.prefix(binding.destinationUserID) + "brand.primaryType") == "real_estate", "Primary selection follows verified empty recipient")
        check(d.integer(forKey: AdoptionOwnedIdentity.prefix(binding.destinationUserID) + "generation") > 0, "Adoption invalidates earlier named-account cloud reads")
        check(try! Data(contentsOf:AdoptionOwnedIdentity.portrait(binding.destinationUserID, type:"real_estate", documents:root)) == Data("synthetic portrait bytes".utf8), "Exact local portrait survives adoption")
        check(try! Data(contentsOf:AdoptionOwnedIdentity.portrait(binding.sourceUserID, type:"real_estate", documents:root)) == Data("synthetic portrait bytes".utf8), "Guest original portrait remains intact")
        let reviewed = PendingReelRequest.load(destinationContext)
        check(reviewed?.submissionUnconfirmed == true && reviewed?.job.requestId == sourceRequest.job.requestId, "Adopted paid receipt becomes review-only and blocks generation")
        check(PendingReelRequest.exists(destinationContext), "Adopted exact workspace/listing marker remains authoritative")
        check(PendingReelRequest.exists(.init(listingID:id, serverListingID:destinationContext.serverListingID, owner:destinationContext.owner, workspace:nil)), "Unselected named workspace cannot evade adopted paid marker")
        check(!PendingReelRequest.exists(.init(listingID:id, serverListingID:destinationContext.serverListingID, owner:foreign.uuidString.lowercased(), workspace:nil)), "Other account cannot inherit an adoption paid marker")
        check(!PendingReelRequest.exists(.init(listingID:id, serverListingID:destinationContext.serverListingID, owner:destinationContext.owner, workspace:UUID())), "Other workspace cannot inherit adopted paid marker")
        check(PendingReelRequest.load(sourceRequest.context)?.job.requestId == sourceRequest.job.requestId, "Original guest paid receipt remains intact")
        let archived = try! JSONDecoder().decode(AdoptionOwnedIdentity.Journal.self, from:d.data(forKey:AdoptionOwnedIdentity.key(binding))!)
        check(archived.sourcePending == Data("synthetic pending explicit guest save".utf8) && archived.sourceReceipt != nil,
              "Exact guest pending draft and acknowledgement are archived, not discarded")
        d.set("Newer named edit", forKey: AdoptionOwnedIdentity.fieldKey(binding.destinationUserID, type:"real_estate", field:"name"))
        PendingReelRequest.forget(destinationContext)
        try restore(binding, id:id)
        check(d.string(forKey:AdoptionOwnedIdentity.fieldKey(binding.destinationUserID, type:"real_estate", field:"name")) == "Newer named edit", "Receipt replay never overwrites newer target card edits")
        check(!PendingReelRequest.exists(destinationContext), "Receipt replay never revives deliberately retired paid marker")
        for field in AdoptionOwnedIdentity.fields { d.removeObject(forKey:AdoptionOwnedIdentity.fieldKey(binding.destinationUserID, type:"real_estate", field:field)) }
        try? FileManager.default.removeItem(at:AdoptionOwnedIdentity.portrait(binding.destinationUserID, type:"real_estate", documents:root))
        try restore(binding, id:id)
        check(d.object(forKey:AdoptionOwnedIdentity.fieldKey(binding.destinationUserID, type:"real_estate", field:"name")) == nil, "Completed adoption never resurrects deliberately cleared identity")

        for mode in ["newer-cloud", "explicit-empty-cloud", "unverified", "legacy-receipt", "destination-preserved"] {
            var (next, nextID, _) = try fixture()
            if mode == "legacy-receipt" { next.personalCardDisposition = nil }
            if mode == "destination-preserved" { next.personalCardDisposition = "destination_preserved" }
            let cloud: [String:String]? = mode == "newer-cloud" ? ["name":"Office reviewed identity"] : mode == "explicit-empty-cloud" ? [:] : ["name":"Guest reviewed"]
            try restore(next, id:nextID, card:cloud, verified:mode != "unverified")
            check(d.object(forKey:AdoptionOwnedIdentity.fieldKey(next.destinationUserID, type:"real_estate", field:"name")) == nil,
                  "Guest local absence cannot overwrite " + mode)
            check(d.object(forKey:AdoptionOwnedIdentity.prefix(next.destinationUserID) + "brand.primaryType") == nil,
                  "Archive-only " + mode + " cannot become hosted primary")
            check(d.data(forKey:AdoptionOwnedIdentity.key(next)) != nil, "Archive-only " + mode + " retains original guest data")
        }
        let (existing, existingID, _) = try fixture()
        d.set("Existing recipient", forKey:AdoptionOwnedIdentity.fieldKey(existing.destinationUserID, type:"real_estate", field:"name"))
        try restore(existing, id:existingID)
        check(d.string(forKey:AdoptionOwnedIdentity.fieldKey(existing.destinationUserID, type:"real_estate", field:"name")) == "Existing recipient", "Existing recipient local identity wins as whole card")
        check(d.object(forKey:AdoptionOwnedIdentity.fieldKey(existing.destinationUserID, type:"real_estate", field:"phone")) == nil, "Guest contact fields are not mixed into existing recipient card")
        let (localOnly, localID, localOrg) = try fixture()
        let localMarker = pending(localOnly, id:localID, org:nil)
        try localMarker.save()
        try restore(localOnly, id:localID)
        let localTarget = PendingReelRequest.Context(listingID:localID, serverListingID:localMarker.context.serverListingID, owner:localOnly.destinationUserID.uuidString.lowercased(), workspace:localOrg)
        check(PendingReelRequest.exists(localTarget), "Original nil-workspace guest marker blocks generation in adopted workspace")
        check(PendingReelRequest.load(localTarget)?.submissionUnconfirmed == true, "Nil-workspace transfer grants no invented provider recovery permission")
        PendingReelRequest.forget(.init(listingID:localID, serverListingID:localTarget.serverListingID, owner:localTarget.owner, workspace:nil))
        try restore(localOnly, id:localID)
        check(!PendingReelRequest.exists(localTarget), "Explicit unselected review retirement does not revive on replay")
        let (unreadable, unreadableID, unreadableOrg) = try fixture()
        let sourceFile = AdoptionOwnedIdentity.requestFile(listingID:unreadableID, owner:unreadable.sourceUserID, org:unreadableOrg, documents:root)
        try Data("corrupt authoritative marker".utf8).write(to:sourceFile)
        d.set(try JSONEncoder().encode(pending(unreadable,id:unreadableID,org:unreadableOrg)), forKey:AdoptionOwnedIdentity.requestKey(listingID:unreadableID,owner:unreadable.sourceUserID,org:unreadableOrg))
        try restore(unreadable, id:unreadableID)
        let unreadableContext = PendingReelRequest.Context(listingID:unreadableID,serverListingID:unreadable.entries.first!.serverID,owner:unreadable.destinationUserID.uuidString.lowercased(),workspace:unreadableOrg)
        check(PendingReelRequest.exists(unreadableContext) && PendingReelRequest.load(unreadableContext) == nil, "Unreadable authoritative guest marker blocks new paid POST without legacy fallback")
        check(try! Data(contentsOf:sourceFile) == Data("corrupt authoritative marker".utf8), "Unreadable guest original is never deleted")
        let (both, bothID, bothOrg) = try fixture()
        try pending(both,id:bothID,org:bothOrg).save(); try pending(both,id:bothID,org:nil).save()
        try restore(both,id:bothID)
        let bothContext = PendingReelRequest.Context(listingID:bothID,serverListingID:both.entries.first!.serverID,owner:both.destinationUserID.uuidString.lowercased(),workspace:bothOrg)
        check(PendingReelRequest.exists(bothContext) && PendingReelRequest.load(bothContext) == nil, "Multiple paid scopes remain one opaque review blocker, not silently selected result")
        let bothArchive = try! JSONDecoder().decode(AdoptionOwnedIdentity.Journal.self,from:d.data(forKey:AdoptionOwnedIdentity.key(both))!)
        check(bothArchive.paidRequests.count == 2, "Both original paid operation records remain available in private archive")
        let (link, linkID, linkOrg) = try fixture()
        let brokenSource = AdoptionOwnedIdentity.requestFile(listingID:linkID, owner:link.sourceUserID, org:linkOrg, documents:root)
        try FileManager.default.createSymbolicLink(at:brokenSource, withDestinationURL:root.appendingPathComponent("missing-synthetic-target"))
        check(PendingReelRequest.exists(pending(link,id:linkID,org:linkOrg).context), "Broken authoritative symlink cannot admit a new paid POST")
        try restore(link,id:linkID)
        let linkTarget = PendingReelRequest.Context(listingID:linkID, serverListingID:link.entries.first!.serverID, owner:link.destinationUserID.uuidString.lowercased(), workspace:linkOrg)
        check(PendingReelRequest.exists(linkTarget) && PendingReelRequest.load(linkTarget) == nil, "Broken source symlink transfers only an opaque paid blocker")
        check(AdoptionOwnedIdentity.pathIsOccupied(brokenSource), "Broken source symlink is never replaced or removed")
        let deniedParent = root.appendingPathComponent("denied-synthetic-parent")
        try FileManager.default.createDirectory(at:deniedParent,withIntermediateDirectories:true)
        try FileManager.default.setAttributes([.posixPermissions:0],ofItemAtPath:deniedParent.path)
        check(AdoptionOwnedIdentity.pathIsOccupied(deniedParent.appendingPathComponent("unreadable-marker")), "Inaccessible authoritative parent cannot become absence")
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:deniedParent.path)
        for mode in ["malformed", "non-data", "oversized"] {
            let (damaged, damagedID, damagedOrg) = try fixture()
            try pending(damaged,id:damagedID,org:damagedOrg).save()
            try restore(damaged,id:damagedID)
            let named = PendingReelRequest.Context(listingID:damagedID,serverListingID:damaged.entries.first!.serverID,owner:damaged.destinationUserID.uuidString.lowercased(),workspace:damagedOrg)
            let nilContext = PendingReelRequest.Context(listingID:damagedID,serverListingID:named.serverListingID,owner:named.owner,workspace:nil)
            let key = AdoptionOwnedIdentity.key(damaged)
            if mode == "non-data" { d.set("invalid journal object",forKey:key) }
            else { d.set(mode == "malformed" ? Data("bad-json".utf8) : Data(repeating:0,count:300_001),forKey:key) }
            check(PendingReelRequest.exists(nilContext), "Damaged owner journal blocks nil-workspace paid POST: " + mode)
            check(PendingReelRequest.hasUnreadableAdoptionMetadata(nilContext), "Damaged journal exposes a recoverable UI error: " + mode)
            PendingReelRequest.forget(nilContext)
            check(PendingReelRequest.exists(named) && d.object(forKey:key) != nil, "Unknown damaged metadata cannot silently forget a paid request: " + mode)
            rejects("Damaged saved journal cannot be recaptured as absent: " + mode) { try restore(damaged,id:damagedID) }
        }
        let (wrongTyped, wrongTypedID, wrongTypedOrg) = try fixture()
        let wrongTypedSource = pending(wrongTyped,id:wrongTypedID,org:nil).context
        d.set("damaged legacy paid marker",forKey:PendingReelRequest.key(wrongTypedSource))
        check(PendingReelRequest.exists(wrongTypedSource) && PendingReelRequest.load(wrongTypedSource) == nil, "Wrong-type legacy marker blocks the actual new paid POST consumer")
        try restore(wrongTyped,id:wrongTypedID)
        let wrongTypedTarget = PendingReelRequest.Context(listingID:wrongTypedID,serverListingID:wrongTyped.entries.first!.serverID,owner:wrongTyped.destinationUserID.uuidString.lowercased(),workspace:wrongTypedOrg)
        check(PendingReelRequest.exists(wrongTypedTarget) && PendingReelRequest.load(wrongTypedTarget) == nil, "Wrong-type guest marker transfers an opaque blocker without provider permission")
        check(d.string(forKey:PendingReelRequest.key(wrongTypedSource)) == "damaged legacy paid marker", "Wrong-type guest legacy evidence is not discarded")
        let (targetWrongTyped, targetWrongTypedID, targetWrongTypedOrg) = try fixture()
        try pending(targetWrongTyped,id:targetWrongTypedID,org:targetWrongTypedOrg).save()
        let existingTargetKey = AdoptionOwnedIdentity.requestKey(listingID:targetWrongTypedID,owner:targetWrongTyped.destinationUserID,org:targetWrongTypedOrg)
        d.set("existing damaged named marker",forKey:existingTargetKey)
        try restore(targetWrongTyped,id:targetWrongTypedID)
        check(d.string(forKey:existingTargetKey) == "existing damaged named marker" && !FileManager.default.fileExists(atPath:AdoptionOwnedIdentity.requestFile(listingID:targetWrongTypedID,owner:targetWrongTyped.destinationUserID,org:targetWrongTypedOrg,documents:root).path), "Wrong-type existing named marker wins over guest paid request")
        let (alias,aliasID,aliasOrg) = try fixture()
        try pending(alias,id:aliasID,org:aliasOrg).save(); try restore(alias,id:aliasID)
        let aliasKey = AdoptionOwnedIdentity.requestKey(listingID:aliasID,owner:alias.destinationUserID,org:aliasOrg)
        try FileManager.default.removeItem(at:AdoptionOwnedIdentity.requestFile(listingID:aliasID,owner:alias.destinationUserID,org:aliasOrg,documents:root))
        d.set("damaged adopted named legacy marker",forKey:aliasKey)
        check(PendingReelRequest.exists(.init(listingID:aliasID,serverListingID:alias.entries.first!.serverID,owner:alias.destinationUserID.uuidString.lowercased(),workspace:nil)), "Unselected named workspace cannot evade wrong-type adopted marker")
        for mode in ["matching-partial", "newer-name", "explicit-blank", "newer-portrait", "unreadable-portrait"] {
            let (interrupted,interruptedID,_) = try fixture()
            let sourceKey = PendingReelRequest.key(pending(interrupted,id:interruptedID,org:nil).context)
            d.set(try JSONEncoder().encode(pending(interrupted,id:interruptedID,org:nil)),forKey:sourceKey)
            let requests = root.appendingPathComponent("reel-requests",isDirectory:true)
            try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:requests.path)
            rejects("Actual failed paid-marker persistence leaves a recoverable incomplete journal") { try restore(interrupted,id:interruptedID) }
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:requests.path)
            let bytes = d.data(forKey:AdoptionOwnedIdentity.key(interrupted))!
            let journal = try JSONDecoder().decode(AdoptionOwnedIdentity.Journal.self,from:bytes)
            check(!journal.completed, "Interrupted source journal is produced by the actual restore body")
            // Model a partial preference flush at process death, then a named
            // edit before replay. No physical kill/camera claim is made.
            let phoneKey = AdoptionOwnedIdentity.fieldKey(interrupted.destinationUserID,type:"real_estate",field:"phone")
            let nameKey = AdoptionOwnedIdentity.fieldKey(interrupted.destinationUserID,type:"real_estate",field:"name")
            d.removeObject(forKey:phoneKey)
            let portrait = AdoptionOwnedIdentity.portrait(interrupted.destinationUserID,type:"real_estate",documents:root)
            if mode == "newer-name" { d.set("Newer named whole identity",forKey:nameKey) }
            if mode == "explicit-blank" { d.set("",forKey:nameKey) }
            if mode == "newer-portrait" { try Data("newer named portrait".utf8).write(to:portrait) }
            if mode == "unreadable-portrait" { try FileManager.default.setAttributes([.posixPermissions:0],ofItemAtPath:portrait.path) }
            try restore(interrupted,id:interruptedID)
            check(mode == "matching-partial" ? d.string(forKey:phoneKey) == "+44 20 7946 0958" : d.object(forKey:phoneKey) == nil,
                mode == "matching-partial" ? "Matching partial installation can finish safely" : "Newer named whole identity cannot mix with guest fields: " + mode)
            if mode == "unreadable-portrait" { try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:portrait.path) }
            if mode == "newer-portrait" { check(try! Data(contentsOf:portrait) == Data("newer named portrait".utf8), "Partial replay preserves a newer named portrait") }
            if mode == "newer-name" { check(d.string(forKey:nameKey) == "Newer named whole identity", "Partial replay preserves newer named text") }
            if mode == "explicit-blank" { check(d.string(forKey:nameKey) == "", "Partial replay preserves deliberately blank named fields") }
            check(AdoptionOwnedIdentity.reviews(owner:interrupted.destinationUserID,type:"real_estate",defaults:d).count == 1, "Skipped partial identity retains user-reviewable guest archive")
        }
        try await exerciseActualArchiveEditor(root:root)
        print("PASS: \(checks) actual profile/adoption/paid-marker assertions; no camera, provider or network")
    }
}
