import Foundation

// Listing has unrelated local-image convenience properties. No host files are used.
enum FileStore { static func url(fromRelativePath path: String) -> URL { URL(fileURLWithPath: "/nonexistent/" + path) } }

@main enum AdoptionProductionLibraryTests {
    enum Failure: Error { case assertion(String) }
    static var checks = 0
    static func expect(_ value: Bool, _ label: String) throws {
        checks += 1
        guard value else { throw Failure.assertion(label) }
    }
    static func rejects(_ label: String, _ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }
        throw Failure.assertion(label)
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let defaults = UserDefaults(suiteName: "RendpropAdoptionTests." + UUID().uuidString)!
        defer { for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("production-plan.") { defaults.removeObject(forKey: key) } }
        let source = UUID(), destination = UUID(), localID = UUID(), ignoredID = UUID(), operation = UUID()
        let sourceOwner = source.uuidString.lowercased(), destinationOwner = destination.uuidString.lowercased()
        var binding = AdoptionLocalBindings(version: 1, operationID: operation, sourceUserID: source,
            destinationUserID: destination, entries: [], confirmedOrgID: UUID(), appliedToCurrentState: true,
            productionLocalIDs: [localID])
        let sourceDirectory = AdoptionProductionLibrary.directory(owner: sourceOwner, listingID: localID, documents: root)
        let destinationDirectory = AdoptionProductionLibrary.directory(owner: destinationOwner, listingID: localID, documents: root)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let clipID = UUID(), bytes = Data("synthetic immutable original".utf8)
        let filename = clipID.uuidString.lowercased() + ".mp4"
        try bytes.write(to: sourceDirectory.appendingPathComponent(filename))
        let manifest = try JSONSerialization.data(withJSONObject: [["id": clipID.uuidString, "filename": filename,
            "name": "Synthetic clip", "bytes": bytes.count, "duration": 2.0, "fps": 30.0,
            "width": 1920, "height": 1080, "uploaded": false, "shotID": "hero"]])
        try manifest.write(to: sourceDirectory.appendingPathComponent("library.json"))
        var draft = ProductionPlanCache.Draft(plan: .starter(listingID: localID), revision: 0, dirty: true)
        draft.plan.notes = "Guest's approved facts and editing instructions"
        try ProductionPlanCache.save(draft, owner: sourceOwner, listingID: localID, defaults: defaults)
        try ProductionPlanCache.save(draft, owner: sourceOwner, listingID: ignoredID, defaults: defaults)

        // Regression reproducer: switching user identity alone finds neither
        // source draft nor clips, even though both are still on the phone.
        try expect(try ProductionPlanCache.load(owner: destinationOwner, listingID: localID, defaults: defaults) == nil,
                   "Guest draft is absent from the new account before verified transfer")
        try expect(!FileManager.default.fileExists(atPath: destinationDirectory.path), "Guest clips are absent from new account before transfer")
        var unconfirmed = binding; unconfirmed.appliedToCurrentState = false; unconfirmed.confirmedOrgID = nil
        try rejects("An ordinary account switch cannot copy guest data") {
            try AdoptionProductionLibrary.restore(unconfirmed, survivingIDs: [localID], documents: root, defaults: defaults)
        }
        try AdoptionProductionLibrary.restore(binding, survivingIDs: [localID, ignoredID], documents: root, defaults: defaults)
        let adopted = try ProductionPlanCache.load(owner: destinationOwner, listingID: localID, defaults: defaults)!
        try expect(adopted.plan == draft.plan && adopted.dirty && adopted.revision == 0 && adopted.adoptedOperationID == operation,
                   "Exact guest draft transfers and remains unsynced until cloud acknowledgement")
        try expect(try Data(contentsOf: destinationDirectory.appendingPathComponent(filename)) == bytes, "Exact clip bytes survive sign-in")
        try expect(try Data(contentsOf: destinationDirectory.appendingPathComponent("library.json")) == manifest, "Clip IDs and shot assignment survive")
        try expect(try Data(contentsOf: sourceDirectory.appendingPathComponent(filename)) == bytes, "Guest originals are retained")
        try expect(try ProductionPlanCache.load(owner: destinationOwner, listingID: ignoredID, defaults: defaults) == nil,
                   "Other local IDs cannot inherit the transfer")

        // Simulate a kill after library copy but before AppModel's final commit,
        // followed by destination edits and the exact receipt retry.
        var edited = adopted; edited.plan.notes = "Newer edit after sign-in"
        try ProductionPlanCache.save(edited, owner: destinationOwner, listingID: localID, defaults: defaults)
        let editedManifest = Data("[]".utf8)
        try editedManifest.write(to: destinationDirectory.appendingPathComponent("library.json"), options: .atomic)
        try AdoptionProductionLibrary.restore(binding, survivingIDs: [localID], documents: root, defaults: defaults)
        try expect(try ProductionPlanCache.load(owner: destinationOwner, listingID: localID, defaults: defaults) == edited,
                   "Retry does not overwrite destination draft edits")
        try expect(try Data(contentsOf: destinationDirectory.appendingPathComponent("library.json")) == editedManifest,
                   "Retry does not resurrect deleted or changed destination clip records")
        let attempt = ProductionPlanCache.Draft(plan: edited.plan, revision: 0, dirty: true)
        let accepted = try ProductionPlanAcknowledgement.apply(.init(listing_id: localID, revision: 1, payload: edited.plan), attempt: attempt, current: edited)
        try expect(accepted.adoptedOperationID == operation, "Cloud acknowledgement retains local transfer provenance")

        let another = AdoptionLocalBindings(version: 1, operationID: UUID(), sourceUserID: source,
            destinationUserID: destination, entries: [], confirmedOrgID: binding.confirmedOrgID, appliedToCurrentState: true,
            productionLocalIDs: [localID])
        try rejects("A different receipt cannot claim an existing destination") {
            try AdoptionProductionLibrary.restore(another, survivingIDs: [localID], documents: root, defaults: defaults)
        }
        let deletedID = UUID()
        binding.productionLocalIDs = [deletedID]
        try ProductionPlanCache.save(draft, owner: sourceOwner, listingID: deletedID, defaults: defaults)
        try AdoptionProductionLibrary.restore(binding, survivingIDs: [], documents: root, defaults: defaults)
        try expect(try ProductionPlanCache.load(owner: destinationOwner, listingID: deletedID, defaults: defaults) == nil,
                   "A deleted listing never returns during recovery")

        let conflictID = UUID()
        binding.productionLocalIDs = [conflictID]
        try ProductionPlanCache.save(draft, owner: sourceOwner, listingID: conflictID, defaults: defaults)
        var conflict = draft; conflict.plan.notes = "Existing destination content"
        try ProductionPlanCache.save(conflict, owner: destinationOwner, listingID: conflictID, defaults: defaults)
        try rejects("Existing unbound destination draft is never overwritten") {
            try AdoptionProductionLibrary.restore(binding, survivingIDs: [conflictID], documents: root, defaults: defaults)
        }
        try expect(try ProductionPlanCache.load(owner: destinationOwner, listingID: conflictID, defaults: defaults) == conflict,
                   "Destination conflict preserves both drafts")

        let maliciousID = UUID()
        binding.productionLocalIDs = [maliciousID]
        let malicious = AdoptionProductionLibrary.directory(owner: sourceOwner, listingID: maliciousID, documents: root)
        try FileManager.default.createDirectory(at: malicious, withIntermediateDirectories: true)
        try manifest.write(to: malicious.appendingPathComponent("library.json"))
        try FileManager.default.createSymbolicLink(at: malicious.appendingPathComponent(filename), withDestinationURL: sourceDirectory.appendingPathComponent(filename))
        try rejects("Media symlink cannot escape the source library") {
            try AdoptionProductionLibrary.restore(binding, survivingIDs: [maliciousID], documents: root, defaults: defaults)
        }
        print("PASS: \(checks) actual adoption plan/filesystem checks; no camera, network or real media")
    }
}
