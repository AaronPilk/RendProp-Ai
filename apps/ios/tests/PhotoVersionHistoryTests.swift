import Foundation

@main
struct PhotoVersionHistoryTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        func rejected(_ message: String, _ operation: () throws -> Void) {
            do { try operation(); preconditionFailure(message) } catch { checks += 1 }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("photo-history-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("home")
        let original = Data("unaltered-capture".utf8), enhanced = Data("local-enhancement".utf8)
        try PhotoVersionHistory.saveCapture(original: original, enhanced: enhanced, id: "capture", directory: dir)
        var index = try PhotoVersionHistory.load(directory: dir)
        check(index.versions.count == 1, "capture persisted")
        check(index.versions["capture"]?.originalVerified == true, "retained capture explicitly known")
        check(index.versions["capture"]?.visibleLabel == nil, "exposure enhancement is not staging")
        check(index.current["capture"] == "capture", "capture current")
        let before = try Data(contentsOf: dir.appendingPathComponent("orig-capture.jpg"))
        check(before == original, "retained bytes intact")

        let declutter = try PhotoVersionHistory.saveEdit(jpeg: Data("decluttered".utf8), id: "declutter", parentID: "capture", sourceID: "capture",
            edit: "declutter", style: nil, disclosure: "Items digitally removed.", provenanceID: "provider-row", provenanceRecorded: true, directory: dir)
        check(declutter.originalFile == "orig-capture.jpg", "declutter uses true root original")
        check(declutter.visibleLabel == "Digitally decluttered", "declutter not mislabeled staging")
        index = try PhotoVersionHistory.load(directory: dir)
        check(!index.isVisible("capture") && index.isVisible("declutter"), "only latest primary visible")
        check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("enh-capture.jpg").path), "superseded file retained for existing reel")
        check(index.versions["declutter"]?.disclosure == "Items digitally removed.", "disclosure survives disk reload")
        check(index.versions["declutter"]?.provenanceID == "provider-row", "provenance row survives disk reload")
        check(index.versions["declutter"]?.provenanceRecorded == true, "recording status retained")

        let stagingInput = try PhotoVersionHistory.source(for: "declutter", edit: "stage", directory: dir)
        check(stagingInput.id == "declutter", "first stage uses decluttered image")
        let stage = try PhotoVersionHistory.saveEdit(jpeg: Data("modern-furniture".utf8), id: "stage", parentID: "declutter", sourceID: stagingInput.id,
            edit: "stage", style: "modern", disclosure: "Furniture digitally added. The architecture, dimensions, and views are unchanged.", provenanceID: nil, provenanceRecorded: false, directory: dir)
        check(stage.disclosure?.contains("are unchanged") == true, "historical audit sentence remains immutable")
        check(stage.reviewDisclosure?.contains("are unchanged") == false, "native presentation does not certify AI geometry")
        check(stage.caption.contains("Compare with the original") && !stage.caption.contains("are unchanged"), "download caption uses honest review disclosure")
        check(stage.originalFile == "orig-capture.jpg", "declutter to stage preserves true original")
        check(stage.stagingBaseID == "declutter", "pre-furniture image persisted")
        check(stage.visibleLabel == "Virtually staged · Digitally decluttered", "both actual alterations disclosed")
        let restyleInput = try PhotoVersionHistory.source(for: "stage", edit: "stage", directory: dir)
        check(restyleInput.id == "declutter", "relaunch restyle uses pre-furniture image")
        let rustic = try PhotoVersionHistory.saveEdit(jpeg: Data("rustic-furniture".utf8), id: "rustic", parentID: "stage", sourceID: restyleInput.id,
            edit: "stage", style: "rustic", disclosure: "Rustic virtual staging.", provenanceID: nil, provenanceRecorded: false, directory: dir)
        check(rustic.sourceID == "declutter" && rustic.parentID == "stage", "record input and superseded version separately")
        check(rustic.effects == ["declutter", "stage"], "restyling does not accumulate duplicate furniture effects")
        index = try PhotoVersionHistory.load(directory: dir)
        check(index.history(for: "rustic").count == 4, "all four versions remain accessible")
        check(index.current["capture"] == "rustic", "latest remains current after relaunch")
        check((try? Data(contentsOf: dir.appendingPathComponent("orig-capture.jpg"))) == original, "edits never replace original")
        rejected("stale edit cannot create second primary") {
            _ = try PhotoVersionHistory.saveEdit(jpeg: Data("late".utf8), id: "late", parentID: "stage", sourceID: "stage", edit: "sky", style: nil,
                disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: dir)
        }
        check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("edit-late.jpg").path), "failed stale write leaves no visible image")
        rejected("duplicate capture cannot overwrite original") {
            try PhotoVersionHistory.saveCapture(original: Data("bad".utf8), enhanced: Data("bad".utf8), id: "capture", directory: dir)
        }
        check((try? Data(contentsOf: dir.appendingPathComponent("orig-capture.jpg"))) == original, "collision preserves originals")

        check(index.listingSelections?["capture"] == "declutter", "unreviewed staging keeps approved declutter on public listing")
        try PhotoVersionHistory.select(id: "stage", directory: dir)
        index = try PhotoVersionHistory.load(directory: dir)
        check(index.current["capture"] == "stage" && index.listingSelections?["capture"] == "stage", "reviewed saved version selected without a paid rerun")
        try PhotoVersionHistory.select(id: "declutter", directory: dir)
        index = try PhotoVersionHistory.load(directory: dir)
        check(index.current["capture"] == "declutter" && index.listingSelections?["capture"] == "declutter", "declutter restored after staging")
        check(index.versions.count == 4 && (try? Data(contentsOf: dir.appendingPathComponent("edit-rustic.jpg"))) != nil, "reverting preserves rejected staging and lineage")
        rejected("missing saved version cannot become public") { try PhotoVersionHistory.select(id: "missing", directory: dir) }
        let publishChoices = try PhotoVersionHistory.publicationVersions(directory: dir)
        check(publishChoices?.map(\.id) == ["declutter"], "publication uses reviewed versions rather than newest staging")
        let missingSelected = dir.appendingPathComponent("edit-declutter.jpg")
        let retainedSelected = try Data(contentsOf: missingSelected)
        try FileManager.default.removeItem(at: missingSelected)
        rejected("missing selected publication file preserves cloud rather than clearing it") { _ = try PhotoVersionHistory.publicationVersions(directory: dir) }
        try retainedSelected.write(to: missingSelected)
        let indexURL = dir.appendingPathComponent(".photo-history.json")
        let goodIndex = try Data(contentsOf: indexURL)
        try Data("corrupt".utf8).write(to: indexURL)
        rejected("corrupt publication index cannot silently fall back to old photos") { _ = try PhotoVersionHistory.publicationVersions(directory: dir) }
        try goodIndex.write(to: indexURL)
        try PhotoVersionHistory.select(id: "rustic", directory: dir)
        try PhotoVersionHistory.hide(id: "rustic", directory: dir)
        index = try PhotoVersionHistory.load(directory: dir)
        check(!index.isVisible("rustic") && !index.isVisible("capture"), "gallery removal does not resurrect a predecessor")
        check(index.history(for: "rustic").count == 4, "gallery removal preserves history")
        check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("edit-stage.jpg").path), "gallery removal preserves old reel sources")
        rejected("hidden family cannot be republished through stale compare") { try PhotoVersionHistory.select(id: "stage", directory: dir) }
        rejected("hidden family cannot accept delayed edit") { _ = try PhotoVersionHistory.source(for: "rustic", edit: "sky", directory: dir) }

        let legacyDir = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try Data("old-altered-photo".utf8).write(to: legacyDir.appendingPathComponent("enh-old.jpg"))
        try Data("prior-altered-photo".utf8).write(to: legacyDir.appendingPathComponent("orig-old.jpg"))
        let legacy = try PhotoVersionHistory.trackExisting(id: "old", imageFile: "enh-old.jpg", priorFile: "orig-old.jpg", directory: legacyDir)
        check(!legacy.originalVerified && !legacy.sourceHistoryKnown, "legacy orig file never silently certified")
        check(legacy.visibleLabel == "Earlier edits unverified", "legacy uncertainty visible")
        let legacyEdit = try PhotoVersionHistory.saveEdit(jpeg: Data("new-ai-photo".utf8), id: "new", parentID: "old", sourceID: "old",
            edit: "sky", style: nil, disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: legacyDir)
        check(!legacyEdit.originalVerified && !legacyEdit.sourceHistoryKnown, "new edit cannot launder unknown history")
        check(legacyEdit.originalFile == "orig-old.jpg", "earlier source preserved without relabeling")
        check(legacyEdit.visibleLabel == "AI edited · Earlier edits unverified", "known edit and unknown ancestry both shown")
        rejected("traversal rejected") { _ = try PhotoVersionHistory.trackExisting(id: "bad", imageFile: "../enh-old.jpg", priorFile: nil, directory: legacyDir) }
        rejected("unrelated family source rejected") {
            _ = try PhotoVersionHistory.saveEdit(jpeg: Data("x".utf8), id: "wrong", parentID: "new", sourceID: "capture", edit: "sky", style: nil,
                disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: legacyDir)
        }
        try FileManager.default.removeItem(at: legacyDir.appendingPathComponent("edit-new.jpg"))
        rejected("missing source does not silently fall back") { _ = try PhotoVersionHistory.source(for: "new", edit: "sky", directory: legacyDir) }
        let badDir = root.appendingPathComponent("bad")
        try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
        try Data("broken-json".utf8).write(to: badDir.appendingPathComponent(".photo-history.json"))
        rejected("corrupt history refuses new writes") {
            try PhotoVersionHistory.saveCapture(original: original, enhanced: enhanced, id: "new", directory: badDir)
        }
        check(!FileManager.default.fileExists(atPath: badDir.appendingPathComponent("enh-new.jpg").path), "corrupt history does not leave untracked ingest")

        enum DiskFailure: Error { case full }
        let failureDir = root.appendingPathComponent("metadata-failure")
        rejected("metadata failure rolls back freshly written capture pair") {
            try PhotoVersionHistory.saveCapture(original: original, enhanced: enhanced, id: "retry", directory: failureDir) { bytes, url in
                if url.lastPathComponent == ".photo-history.json" { throw DiskFailure.full }
                try bytes.write(to: url, options: .atomic)
            }
        }
        check(!FileManager.default.fileExists(atPath: failureDir.appendingPathComponent("orig-retry.jpg").path)
              && !FileManager.default.fileExists(atPath: failureDir.appendingPathComponent("enh-retry.jpg").path),
              "failed metadata leaves no orphan current photo")
        try PhotoVersionHistory.saveCapture(original: original, enhanced: enhanced, id: "retry", directory: failureDir)
        rejected("edit metadata failure must not replace current photo") {
            _ = try PhotoVersionHistory.saveEdit(jpeg: Data("new-output".utf8), id: "failed-edit", parentID: "retry", sourceID: "retry",
                edit: "declutter", style: nil, disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: failureDir) { bytes, url in
                    if url.lastPathComponent == ".photo-history.json" { throw DiskFailure.full }
                    try bytes.write(to: url, options: .atomic)
                }
        }
        let unchanged = try PhotoVersionHistory.load(directory: failureDir)
        check(unchanged.current["retry"] == "retry" && unchanged.versions.count == 1, "prior current/history survives metadata failure")
        check(!FileManager.default.fileExists(atPath: failureDir.appendingPathComponent("edit-failed-edit.jpg").path), "uncommitted AI output cleaned up")
        check((try? Data(contentsOf: failureDir.appendingPathComponent("orig-retry.jpg"))) == original, "metadata failure never deletes existing original")

        typealias Layout = PhotoExportLayout
        check(Layout.size(width: 4032, height: 3024, aspect: .original, framing: .crop) == .init(width: 4032, height: 3024), "default preserves every original pixel")
        check(Layout.size(width: 4032, height: 3024, aspect: .landscape, framing: .crop) == .init(width: 4032, height: 3024), "4:3 same source")
        check(Layout.size(width: 4000, height: 3000, aspect: .wide, framing: .crop) == .init(width: 4000, height: 2250), "wide crop removes top and bottom")
        check(Layout.size(width: 4000, height: 3000, aspect: .portrait, framing: .crop) == .init(width: 1688, height: 3000), "portrait crop trims sides")
        check(Layout.size(width: 4000, height: 3000, aspect: .portrait, framing: .fit) == .init(width: 2250, height: 4000), "fit canvas bounded by source long edge")
        check(Layout.size(width: 3000, height: 4000, aspect: .wide, framing: .fit) == .init(width: 4000, height: 2250), "landscape fit never increases longest side")
        for width in [1024, 2048, 4032, 6000] {
            for height in [768, 2048, 4032] {
                for aspect in Layout.Aspect.allCases {
                    for framing in Layout.Framing.allCases {
                        let size = Layout.size(width: width, height: height, aspect: aspect, framing: framing)
                        check(size.width > 0 && size.height > 0, "positive export dimensions")
                        check(max(size.width, size.height) <= max(width, height), "no upscale across ratios")
                        if framing == .crop { check(size.width <= width && size.height <= height, "crop never stretches source") }
                    }
                }
            }
        }
        print("Photo history/export geometry: \(checks) passed")
    }
}
