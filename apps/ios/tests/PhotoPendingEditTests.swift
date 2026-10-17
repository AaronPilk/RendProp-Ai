import Foundation

@main struct PhotoPendingEditTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = PhotoPendingEdit.Identity(actor: "owner-a", library: UUID(), listing: UUID(), sourceVersion: "original-1")
        var request = AIPhotoEditRequest(imageBase64: "aW1tdXRhYmxlLXBob3Rv", edit: "stage")
        request.style = "modern"; request.originalAssetID = UUID().uuidString; request.listingServerID = UUID()
        let first = try PhotoPendingEdit.begin(request, identity: identity, directory: directory)
        let replay = try PhotoPendingEdit.begin(request, identity: identity, directory: directory)
        precondition(first.request == replay.request && first.url == replay.url, "A lost answer must retain the exact paid request")
        var refreshed = request; refreshed.label = "New display label"; refreshed.originalAssetID = UUID().uuidString
        let refreshReplay = try PhotoPendingEdit.begin(refreshed, identity: identity, directory: directory)
        precondition(refreshReplay.request == first.request, "Recovery must retain the dispatched source receipt and body")
        let otherActor = PhotoPendingEdit.Identity(actor: "owner-b", library: identity.library, listing: identity.listing, sourceVersion: identity.sourceVersion)
        let different16 = try PhotoPendingEdit.begin(request, identity: otherActor, directory: directory).request.idempotencyKey != first.request.idempotencyKey
        precondition(different16)
        let otherLibrary = PhotoPendingEdit.Identity(actor: identity.actor, library: UUID(), listing: identity.listing, sourceVersion: identity.sourceVersion)
        let different18 = try PhotoPendingEdit.begin(request, identity: otherLibrary, directory: directory).request.idempotencyKey != first.request.idempotencyKey
        precondition(different18)
        let otherListing = PhotoPendingEdit.Identity(actor: identity.actor, library: identity.library, listing: UUID(), sourceVersion: identity.sourceVersion)
        let different20 = try PhotoPendingEdit.begin(request, identity: otherListing, directory: directory).request.idempotencyKey != first.request.idempotencyKey
        precondition(different20)
        let otherVersion = PhotoPendingEdit.Identity(actor: identity.actor, library: identity.library, listing: identity.listing, sourceVersion: "other-original")
        let different22 = try PhotoPendingEdit.begin(request, identity: otherVersion, directory: directory).request.idempotencyKey != first.request.idempotencyKey
        precondition(different22)
        var otherStyle = request; otherStyle.style = "contemporary"
        let different24 = try PhotoPendingEdit.begin(otherStyle, identity: identity, directory: directory).request.idempotencyKey != first.request.idempotencyKey
        precondition(different24)
        var otherPixels = request; otherPixels.imageBase64 = "ZGlmZmVyZW50LXBpeGVscw=="
        let different26 = try PhotoPendingEdit.begin(otherPixels, identity: identity, directory: directory).request.idempotencyKey != first.request.idempotencyKey
        precondition(different26)
        let originalData = try Data(contentsOf: first.url)
        var entry = try JSONDecoder().decode(PhotoPendingEdit.Entry.self, from: originalData)
        var forged = entry.request; forged.imageBase64 = "bXV0YXRlZA=="
        entry = .init(schema: entry.schema, identity: entry.identity, fingerprint: entry.fingerprint, request: forged)
        try JSONEncoder().encode(entry).write(to: first.url)
        do { _ = try PhotoPendingEdit.begin(request, identity: identity, directory: directory); preconditionFailure("Changed saved bytes must fail closed") }
        catch is PhotoPendingEdit.Failure { }
        try originalData.write(to: first.url)
        try PhotoPendingEdit.finish(first)
        let nextExplicitEdit = try PhotoPendingEdit.begin(request, identity: identity, directory: directory)
        precondition(nextExplicitEdit.request.idempotencyKey != first.request.idempotencyKey, "Only a finished operation permits a new explicit paid attempt")
        try Data("corrupt".utf8).write(to: nextExplicitEdit.url)
        do { _ = try PhotoPendingEdit.begin(request, identity: identity, directory: directory); preconditionFailure("Unreadable receipt cannot silently create a new paid request") }
        catch is PhotoPendingEdit.Failure { }
        print("Photo pending edit: exact recovery, source integrity and account/library isolation passed")
    }
}
