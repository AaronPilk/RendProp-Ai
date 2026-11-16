import Foundation

private var assertions = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    guard condition() else { FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1) }
}

@main struct RoomTagWalkthroughTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("room-tags-" + UUID().uuidString)
        FileStore.documents = root
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Recordings", "Imports", "reels", "player"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        func source(_ path: String, bytes: Data = Data("actual closed source bytes".utf8)) throws -> CaptureAsset {
            let url = root.appendingPathComponent(path)
            try bytes.write(to: url)
            return CaptureAsset(localURL: url, durationS: 25, fps: 30, width: 1920, height: 1080, bytes: Int64(bytes.count))
        }
        let recorded = try source("Recordings/walkthrough-2026-10-15-" + UUID().uuidString + ".mov")
        let uploaded = try source("Imports/import-A12b34c5-DJI_0001.MP4")
        func qualifies(_ asset: CaptureAsset?, sample: Bool = false, current: Bool = true, generated: [URL] = []) -> Bool {
            RoomTagWalkthroughPolicy.sourceURL(asset: asset, documents: root, isSample: sample,
                isCurrent: current, generatedURLs: generated) != nil
        }
        check(qualifies(recorded), "real local recording qualifies")
        check(qualifies(uploaded), "validated uploaded raw walkthrough qualifies")
        check(!qualifies(nil), "missing raw source remains unavailable")
        check(!qualifies(recorded, sample: true), "sample listing cannot unlock tags")
        check(!qualifies(recorded, current: false), "changed account or listing cannot authorize tags")
        for path in ["Recordings/tour-12345678.mp4", "reels/generated-photo-video.mp4", "player/demo.mp4",
                     "Imports/cloud-" + UUID().uuidString + ".mp4", "Imports/import-A12b34c5-demo.mp4",
                     "Imports/import-A12b34c5-sample-tour.mp4", "Imports/import-notauuid-raw.mp4"] {
            let rejected = try source(path)
            check(!qualifies(rejected), "generated, untyped cloud and sample paths do not qualify: " + path)
        }
        check(!qualifies(uploaded, generated: [uploaded.localURL]), "known generated source cannot masquerade as upload")
        var invalid = recorded
        invalid.bytes += 1
        check(!qualifies(invalid), "changed source bytes cannot reuse stored capture metadata")
        invalid = recorded; invalid.durationS = .nan
        check(!qualifies(invalid), "nonfinite capture duration cannot qualify")
        invalid = recorded; invalid.width = 0
        check(!qualifies(invalid), "invalid picture metadata cannot qualify")
        invalid = recorded; invalid.localURL = URL(string: "https://example.invalid/raw.mov")!
        check(!qualifies(invalid), "remote URL never qualifies as locally available raw footage")
        let linked = root.appendingPathComponent("Imports/import-1234abcd-link.mov")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: recorded.localURL)
        invalid = recorded; invalid.localURL = linked
        check(!qualifies(invalid), "symlink cannot authorize another media path")
        let alias = root.deletingLastPathComponent().appendingPathComponent("room-tags-alias-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: alias) }
        invalid = recorded
        invalid.localURL = alias.appendingPathComponent("Recordings").appendingPathComponent(recorded.localURL.lastPathComponent)
        check(RoomTagWalkthroughPolicy.sourceURL(asset: invalid, documents: alias, isSample: false,
              isCurrent: true) != nil, "trusted document-root filesystem alias preserves real capture compatibility")
        let otherRoot = root.appendingPathComponent("OtherContainer")
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: otherRoot.appendingPathComponent("Recordings"),
              withDestinationURL: root.appendingPathComponent("Recordings"))
        invalid.localURL = otherRoot.appendingPathComponent("Recordings").appendingPathComponent(recorded.localURL.lastPathComponent)
        check(RoomTagWalkthroughPolicy.sourceURL(asset: invalid, documents: otherRoot, isSample: false,
              isCurrent: true) == nil, "raw media directory cannot symlink into a different container")

        let listing = TagFixtureListing(id: UUID())
        let fixture = RoomTagEntryFixture(listing: listing)
        fixture.model.assets[listing.id] = uploaded
        fixture.availableRoomTagAsset = uploaded
        check(fixture.canTagRooms, "eligible current raw asset enables the cached tile")
        fixture.openRoomTags()
        check(fixture.showRoomTagger && !fixture.showRoomTagsWalkthroughHelp, "actual tap opens tagger only for raw footage")
        let tag = RoomTag(name: "Kitchen", tMs: 2500)
        fixture.roomTagsBinding.set([tag])
        check(fixture.model.assets[listing.id]?.roomTags == [tag], "actual binding edits the same current raw timeline")
        fixture.showRoomTagger = false
        fixture.model.assets[listing.id] = try source("Recordings/tour-generated.mp4")
        fixture.openRoomTags()
        check(!fixture.showRoomTagger && fixture.showRoomTagsWalkthroughHelp, "actual entrypoint explains upload first for generated footage")
        let before = fixture.model.assets[listing.id]
        fixture.roomTagsBinding.set([RoomTag(name: "Unwanted", tMs: 0)])
        check(fixture.model.assets[listing.id] == before, "generated timeline cannot be mutated through retained tag binding")
        fixture.openWalkthroughForRoomTags()
        check(fixture.showWalkthroughForRoomTags && !fixture.showRoomTagsWalkthroughHelp, "help action opens existing walkthrough route")

        fixture.showRoomTagger = false; fixture.showWalkthroughForRoomTags = false
        fixture.model.assets[listing.id] = uploaded
        fixture.hasCurrentPresentationContext = false
        fixture.openRoomTags(); fixture.openWalkthroughForRoomTags()
        check(!fixture.showRoomTagger && !fixture.showRoomTagsWalkthroughHelp && !fixture.showWalkthroughForRoomTags,
              "changed account cannot enqueue tagger, help or walkthrough presentation")
        fixture.roomTagsBinding.set([RoomTag(name: "Foreign", tMs: 0)])
        check(fixture.model.assets[listing.id] == uploaded, "changed account cannot write old listing tags")
        fixture.hasCurrentPresentationContext = true
        fixture.model.listings = []
        fixture.openRoomTags()
        check(!fixture.showRoomTagger && !fixture.showRoomTagsWalkthroughHelp, "deleted listing cannot open retained presentation")
        fixture.model.listings = [listing]; fixture.model.inSelectedWorkspace = false
        fixture.openRoomTags()
        check(!fixture.showRoomTagger && !fixture.canTagRooms, "foreign library cannot open or light tag tile")
        fixture.model.inSelectedWorkspace = true
        fixture.model.listings[0].cloudUnavailable = true
        fixture.openRoomTags()
        check(!fixture.showRoomTagger, "revoked listing cannot open tagger")
        fixture.model.listings = [listing]
        try FileManager.default.removeItem(at: uploaded.localURL)
        fixture.openRoomTags()
        check(!fixture.showRoomTagger && fixture.showRoomTagsWalkthroughHelp && fixture.availableRoomTagAsset == nil,
              "deleted file is rechecked on tap despite previously enabled tile")
        print("PASSED \(assertions) actual raw-source predicate and entrypoint/binding controls; no UI, network or AI call")
    }
}
