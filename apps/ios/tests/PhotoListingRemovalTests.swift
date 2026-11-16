import Foundation

@MainActor private final class RemovalAPI: ListingGalleryRemovalAPI {
    enum Lost: Error { case reply }
    let selection: PhotoGallerySelection
    var calls: [PhotoGalleryRemovalOperation] = []
    var loseReply = true
    init(selection: PhotoGallerySelection) { self.selection = selection }
    func gallerySelection(serverID: UUID, libraryOrgID: UUID) async throws -> PhotoGallerySelection { selection }
    func removeGalleryAssets(_ operation: PhotoGalleryRemovalOperation) async throws -> PhotoGalleryRemovalReply {
        calls.append(operation)
        if loseReply { throw Lost.reply }
        return .init(selection: selection, operationID: operation.operationID, replayed: true,
                     requestedAssetIDs: operation.requestedAssetIDs, removedAssetIDs: operation.requestedAssetIDs)
    }
}

@main struct PhotoListingRemovalTests {
    @MainActor static func main() async throws {
        var assertions = 0
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
            assertions += 1
        }
        func refuses(_ message: String, _ action: () throws -> Void) {
            do { try action(); check(false, message) } catch { check(true, message) }
        }
        let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        func folder(_ name: String) throws -> URL {
            let value = base.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
            return value
        }
        let actor = UUID(), library = UUID(), local = UUID(), server = UUID(), asset = UUID(), other = UUID()
        func operation(id: UUID = UUID(), actorID: UUID? = nil, libraryID: UUID? = nil,
                       localID: UUID? = nil, serverID: UUID? = nil, family: String = "capture",
                       version: String = "capture-original", requested: [UUID]? = nil,
                       expected: [UUID]? = nil, key: String? = nil) -> PhotoGalleryRemovalOperation {
            .init(operationID: id, actorID: actorID ?? actor, libraryOrgID: libraryID ?? library,
                  localListingID: localID ?? local, serverListingID: serverID ?? server, familyID: family,
                  selectedVersionID: version, requestedAssetIDs: requested ?? [asset],
                  expectedGalleryAssetIDs: expected, expectedMainPhotoKey: key)
        }
        func journalFiles(_ directory: URL) throws -> [URL] {
            let path = directory.appendingPathComponent(".photo-listing-removals")
            guard FileManager.default.fileExists(atPath: path.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
        }
        let original = operation(expected: [asset, other], key: "renders/org/listing/gallery-photo.jpg")
        let root = try folder("lost-reply"), journal = PhotoListingRemovalJournal(directory: root)
        check(try journal.load(scope: original.scope) == nil, "No operation exists before persistence")
        let prepared = try journal.begin(original)
        let urls = try journalFiles(root); check(urls.count == 1, "Begin exposes one complete journal entry before HTTP")
        let bytes = try Data(contentsOf: urls[0])
        let permissions = try FileManager.default.attributesOfItem(atPath: urls[0].path)[.posixPermissions] as! NSNumber
        let folderPermissions = try FileManager.default.attributesOfItem(atPath: urls[0].deletingLastPathComponent().path)[.posixPermissions] as! NSNumber
        check(permissions.intValue == 0o600 && folderPermissions.intValue == 0o700, "Journal file and directory are private0600/0700")
        check(try PhotoListingRemovalJournal(directory: root).load(scope: original.scope) == prepared, "Fresh instance recovers exact scope/body/UUID after restart")
        let proposedAgain = operation(expected: original.expectedGalleryAssetIDs, key: original.expectedMainPhotoKey)
        check(try journal.begin(proposedAgain) == prepared, "Same intent with a new proposed UUID reuses the saved exact operation")
        check(try Data(contentsOf: urls[0]) == bytes, "Idempotent recovery never rewrites saved operation bytes")
        let selection = PhotoGallerySelection(listingID: server, orgID: UUID(), libraryOrgID: library,
            galleryAssetIDs: [other], mainPhotoKey: nil,
            galleryAssets: [.init(assetID: other, sha256: String(repeating: "a", count: 64), bytes: 100)])
        let api = RemovalAPI(selection: selection)
        do { _ = try await api.removeGalleryAssets(prepared); check(false, "Synthetic transport must lose first reply") } catch {}
        let recovered = try PhotoListingRemovalJournal(directory: root).load(scope: original.scope)!
        check(recovered == prepared, "Lost reply retains the exact compare-and-set request")
        api.loseReply = false
        let reply = try await api.removeGalleryAssets(recovered)
        check(api.calls.count == 2 && api.calls[0] == api.calls[1] && reply.operationID == prepared.operationID,
              "Explicit recovery sends the same saved operation to the injected API, never a new identity")
        check(try journal.load(scope: original.scope) == prepared, "Even successful transport does not implicitly erase pending journal")
        check(try JSONDecoder().decode(PhotoGalleryRemovalReply.self, from: JSONEncoder().encode(reply)) == reply,
              "Closed gallery asset and reply models round-trip without credentials")
        check(PhotoGallerySelection(listingID: server, orgID: library, libraryOrgID: library, galleryAssetIDs: nil, mainPhotoKey: nil).galleryAssets.isEmpty,
              "Legacy callers have an explicit empty descriptor projection by default")

        let conflicts = [operation(expected: [other, asset], key: original.expectedMainPhotoKey),
                         operation(version: "different-version", expected: original.expectedGalleryAssetIDs, key: original.expectedMainPhotoKey),
                         operation(requested: [other], expected: original.expectedGalleryAssetIDs, key: original.expectedMainPhotoKey),
                         operation(expected: nil, key: original.expectedMainPhotoKey),
                         operation(expected: original.expectedGalleryAssetIDs, key: nil)]
        for conflict in conflicts {
            refuses("Changed pending intent must not overwrite saved operation") { _ = try journal.begin(conflict) }
            check(try Data(contentsOf: urls[0]) == bytes, "Conflicting begin preserves exact prior bytes")
        }
        refuses("Wrong operation UUID cannot finish pending request") { try journal.finish(proposedAgain) }
        let wrongBody = operation(id: prepared.operationID, requested: [other], expected: prepared.expectedGalleryAssetIDs, key: prepared.expectedMainPhotoKey)
        refuses("Same UUID with changed body cannot finish pending request") { try journal.finish(wrongBody) }
        check(try Data(contentsOf: urls[0]) == bytes, "Mismatched completion preserves pending request")

        let foreign = [operation(actorID: UUID()), operation(libraryID: UUID()), operation(localID: UUID()),
                       operation(serverID: UUID()), operation(family: "different-family")]
        for scoped in foreign {
            check(try journal.load(scope: scoped.scope) == nil, "Other actor/library/listing/family cannot adopt pending operation")
            let targetDir = try folder(UUID().uuidString), targetJournal = PhotoListingRemovalJournal(directory: targetDir)
            _ = try targetJournal.begin(scoped)
            let target = try journalFiles(targetDir)[0]
            try bytes.write(to: target)
            refuses("A foreign copied envelope cannot bypass scope digest") { _ = try targetJournal.load(scope: scoped.scope) }
            check(try Data(contentsOf: target) == bytes, "Foreign scope refusal preserves evidence")
        }
        try journal.finish(prepared)
        check(try journal.load(scope: prepared.scope) == nil, "Matching confirmed operation clears its journal")
        try journal.finish(prepared)
        check(try journalFiles(root).isEmpty, "Finishing an already completed operation is idempotent")

        let invalid = [operation(family: ""), operation(family: "../other"), operation(version: ""),
                       operation(version: String(repeating: "a", count: 241)), operation(requested: []),
                       operation(requested: [asset, asset]), operation(requested: (0...100).map { _ in UUID() }),
                       operation(expected: [asset, asset]), operation(expected: (0...100).map { _ in UUID() }),
                       operation(key: "https://example.invalid/asset?token=secret"), operation(key: "renders/../other"),
                       operation(key: "renders/key?signature=private")]
        for bad in invalid {
            let path = try folder(UUID().uuidString), isolated = PhotoListingRemovalJournal(directory: path)
            refuses("Invalid or credential-shaped operation is rejected before HTTP") { _ = try isolated.begin(bad) }
            check(try journalFiles(path).isEmpty, "Invalid request never creates a sendable journal")
        }
        for expected in [[UUID](), (0..<100).map { _ in UUID() }] {
            let path = try folder(UUID().uuidString), isolated = PhotoListingRemovalJournal(directory: path)
            let valid = operation(requested: Array((0..<100).map { _ in UUID() }), expected: expected)
            check(try isolated.begin(valid) == valid, "Exact unique100 requested IDs and0/100 snapshot bounds are supported")
            check(try isolated.load(scope: valid.scope) == valid, "Boundary operation preserves ordered IDs and nil/empty semantics")
        }
        for corrupt in [Data("not-json".utf8), Data(repeating: 120, count: 32 * 1024 + 1)] {
            let path = try folder(UUID().uuidString), isolated = PhotoListingRemovalJournal(directory: path)
            let pending = try isolated.begin(operation()), target = try journalFiles(path)[0]
            try corrupt.write(to: target)
            refuses("Malformed/oversized journal never authorizes a replacement") { _ = try isolated.begin(pending) }
            check(try Data(contentsOf: target) == corrupt, "Unreadable pending evidence is not deleted or rewritten")
        }
        do {
            let path = try folder("symbolic-journal"), isolated = PhotoListingRemovalJournal(directory: path)
            let pending = try isolated.begin(operation()), target = try journalFiles(path)[0]
            let external = path.appendingPathComponent("external.json"); try bytes.write(to: external)
            try FileManager.default.removeItem(at: target)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: external)
            refuses("Symlinked pending journal is never followed/adopted") { _ = try isolated.load(scope: pending.scope) }
            check(try Data(contentsOf: external) == bytes, "Symlink refusal leaves the other file untouched")
        }
        print("PASS PhotoListingRemoval: \(assertions) assertions; Foundation-only journal/model/injected lost-reply transport; no network/UI")
    }
}
