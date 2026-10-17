import Foundation

@main struct DuplicateListingSnapshotTests {
    static func main() throws {
        if CommandLine.arguments.contains("--force-failure") {
            print("FAIL: deliberate negative control")
            exit(1)
        }
        var count = 0
        func check(_ condition: Bool, _ name: String) {
            count += 1
            guard condition else { print("FAIL: \(name)"); exit(1) }
        }
        FileStore.documents = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: FileStore.documents, withIntermediateDirectories: true)
        let media = FileStore.documents.appendingPathComponent("retained-video.mov")
        let tourURL = FileStore.documents.appendingPathComponent("retained-tour.mov")
        try Data("synthetic video bytes".utf8).write(to: media)
        try Data("synthetic tour bytes".utf8).write(to: tourURL)
        let first = Listing(address: "Synthetic first duplicate", beds: 1, baths: 1, sqft: 1,
                            price: Money(cents: 0), mainPhotoRelPath: "first-photo.jpg", serverID: UUID())
        var conflicting = first
        conflicting.address = "Synthetic conflicting duplicate"
        conflicting.serverID = UUID()
        conflicting.mainPhotoRelPath = "conflicting-photo.jpg"
        let asset = CaptureAsset(localURL: media, durationS: 59.6, fps: 29.97,
                                 width: 1920, height: 1080, bytes: 21)
        let tour = AppModel.RenderedTour(url: tourURL, durationS: 40, speedFactor: 1.5)
        let render = Render(listingID: first.id, tier: .smooth, durationS: 40)
        let uploaded = AppModel.UploadedRenderAsset(relPath: "retained-tour.mov", assetID: "synthetic-cloud-asset")
        check(PersistentStore.save(listings: [first, conflicting], assets: [first.id: asset],
                                   tours: [first.id: tour], renders: [first.id: render], pendingPublish: [first.id],
                                   uploadedRenderAssets: [first.id: uploaded]), "actual duplicate snapshot save")
        let savedURL = FileStore.documents.appendingPathComponent("rendprop-state.json")
        let savedBytes = try Data(contentsOf: savedURL)
        let restored = PersistentStore.load()
        check(restored.listings == [first, conflicting], "actual loader retains both conflicting rows and all facts")
        check(restored.assets[first.id] == asset, "actual loader retains capture binding")
        check(restored.tours[first.id]?.url == tourURL, "actual loader retains tour binding")
        check(restored.renders[first.id] == render, "actual loader retains render binding")
        check(restored.pendingPublish == [first.id], "actual loader retains pending publish")
        check(restored.uploadedRenderAssets[first.id] == uploaded, "actual loader retains uploaded media binding")
        let model = AppModel()
        model.listings = restored.listings
        do {
            _ = try model.snapshotBindings()
            check(false, "duplicate IDs must report recoverable invalidResponse")
        } catch CloudSyncError.invalidResponse {
            check(true, "duplicate IDs report recoverable invalidResponse")
        } catch {
            check(false, "unexpected error \(error)")
        }
        check(model.listings == [first, conflicting], "guard does not choose, merge, or discard either row")
        check(try Data(contentsOf: savedURL) == savedBytes, "guard leaves original snapshot bytes unchanged")
        check(try Data(contentsOf: media) == Data("synthetic video bytes".utf8), "guard leaves video bytes unchanged")
        check(try Data(contentsOf: tourURL) == Data("synthetic tour bytes".utf8), "guard leaves tour bytes unchanged")
        var distinct = conflicting
        distinct.id = UUID()
        model.listings = [first, distinct]
        let bindings = try model.snapshotBindings()
        check(bindings.count == 2, "unique listing map still has two entries")
        check(bindings[first.id] == first.serverID, "first unique server binding unchanged")
        check(bindings[distinct.id] == distinct.serverID, "second unique server binding unchanged")
        var localOnly = distinct
        localOnly.serverID = nil
        model.listings = [localOnly]
        let localMap = try model.snapshotBindings()
        check(localMap.keys.contains(localOnly.id), "nil serverID retains local identity key")
        check(localMap[localOnly.id]! == nil, "nil serverID remains nil")
        model.listings = []
        check(try model.snapshotBindings().isEmpty, "empty snapshot remains valid")
        print("PASS: \(count) actual snapshot and sync binding assertions")
    }
}
