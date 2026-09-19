import Foundation

// Unrelated UI/domain dependencies are minimal; CaptureAsset, RoomTag, and
// every PersistentStore/save/load/decoder implementation are real source.
enum SpaceType { case realEstate; static let current = Self.realEstate; var quickTags: [String] { [] } }
struct Listing: Codable { var id = UUID(); var isSample = false }
struct Render: Codable {}
struct AdoptionLocalBindings: Codable { func validate() throws {} }
enum AppModel {
    struct RenderedTour { var url: URL; var durationS: Double; var speedFactor: Double }
    struct UploadedRenderAsset: Codable {}
}

@main struct PersistenceRuntime {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        FileStore.documents = root
        let fm = FileManager.default
        try fm.createDirectory(at: FileStore.recordingsDir, withIntermediateDirectories: true)
        let original = FileStore.recordingsDir.appendingPathComponent("synthetic-original.mov")
        let untouched = Data("synthetic original retained".utf8)
        try untouched.write(to: original)
        let listing = Listing()
        var asset = CaptureAsset(localURL: original, durationS: 30, fps: 30,
                                 width: 1920, height: 1080, bytes: Int64(untouched.count))
        asset.roomTags = [RoomTag(name: "Kitchen", tMs: 1000)]
        asset.personVisibleRanges = [TimeRange(startS: 2, endS: 5), TimeRange(startS: 12, endS: 16)]
        let saved = PersistentStore.save(listings: [listing], assets: [listing.id: asset], tours: [:], renders: [:])
        let loaded = PersistentStore.load()
        guard let restored = loaded.assets[listing.id] else { fatalError("unrelated asset restore failed") }
        let persisted = try String(contentsOf: root.appendingPathComponent("rendprop-state.json"), encoding: .utf8)
        let results: [String: Any] = [
            "saved": saved,
            "before_person_ranges": asset.personVisibleRanges.count,
            "before_person_seconds": asset.personVisibleSeconds,
            "after_person_ranges": restored.personVisibleRanges.count,
            "after_person_seconds": restored.personVisibleSeconds,
            "before_tags": asset.roomTags.count,
            "after_tags": restored.roomTags.count,
            "snapshot_has_person_key": persisted.contains("personVisibleRanges"),
            "original_bytes_preserved": try Data(contentsOf: original) == untouched,
            "restored_same_asset": restored.id == asset.id && restored.localURL == asset.localURL
        ]
        let bytes = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try bytes.write(to: root.appendingPathComponent("persistence-results.json"))
        print(String(decoding: bytes, as: UTF8.self))
    }
}
