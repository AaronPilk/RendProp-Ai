import Foundation

@main struct PhotoReelEgressTests {
    static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ note: String) { precondition(value(), note); checks += 1 }
        func refused(_ note: String, _ call: () throws -> Void) {
            do { try call(); preconditionFailure(note) }
            catch { checks += 1 }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reel-egress-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("same retained bytes".utf8)
        try PhotoVersionHistory.saveCapture(original: bytes, enhanced: bytes, id: "base", directory: directory)
        let custom = try PhotoVersionHistory.saveEdit(jpeg: bytes, id: "custom", parentID: "base", sourceID: "base", edit: "custom", style: nil, disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: directory)
        refused("saved custom source remains held before reel continuation") { try PhotoVersionHistory.requireReelReview(versionID: custom.id, directory: directory) }
        try PhotoVersionHistory.select(id: "base", directory: directory)
        let stage = try PhotoVersionHistory.saveEdit(jpeg: bytes, id: "stage", parentID: "base", sourceID: "base", edit: "stage", style: "modern", disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: directory)
        refused("saved staging source remains held before reel composition") { try PhotoVersionHistory.requireReelReview(versionID: stage.id, directory: directory) }
        try PhotoVersionHistory.selectForPublication(id: stage.id, directory: directory, reviewed: true)
        try PhotoVersionHistory.requireReelReview(versionID: stage.id, directory: directory)
        check(true, "exact staged approval admits saved source without new image bytes")
        try PhotoVersionHistory.requireReelReview(versionID: "unknown-legacy", directory: directory)
        check(true, "unknown legacy is not retroactively certified or erased")
        check((try? Data(contentsOf: directory.appendingPathComponent("orig-base.jpg"))) == bytes, "review admission preserves retained bytes")
        let old = ReelWorkJob.Configuration(extras: [URL(fileURLWithPath: "/saved/aerial.mp4")], captions: "saved title", voice: "saved voice", captionStyle: .standard, shotStyle: .highlightBox, transition: .whip, aspect: "16:9")
        let reopened = ReelWorkJob.Configuration(extras: [], captions: nil, voice: nil, captionStyle: .off, shotStyle: .off, transition: .cut, aspect: "9:16")
        let saved = ReelDecision.parkedReelSettings(configuration: old, batchAspect: "16:9", fallback: reopened)
        check(saved.renderSize.width == 1920 && saved.renderSize.height == 1080, "parked reel keeps saved wide shape despite reopened tall setup")
        check(saved.configuration.extras == old.extras && saved.configuration.captions == old.captions && saved.configuration.voice == old.voice && saved.configuration.captionStyle == old.captionStyle && saved.configuration.shotStyle == old.shotStyle && saved.configuration.transition == old.transition, "parked reel keeps saved extras title voice and caption transition choices")
        let durable = ReelDecision.parkedReelSettings(configuration: reopened, batchAspect: "16:9", fallback: reopened)
        check(durable.renderSize.width == 1920 && durable.renderSize.height == 1080, "durable batch shape wins over in-memory defaults")
        let memory = ReelDecision.parkedReelSettings(configuration: old, batchAspect: nil, fallback: reopened)
        check(memory.renderSize.width == 1920 && memory.renderSize.height == 1080, "saved job shape applies when batch metadata is absent")
        let legacy = ReelDecision.parkedReelSettings(configuration: nil, batchAspect: nil, fallback: reopened)
        check(legacy.renderSize.width == 1080 && legacy.renderSize.height == 1920 && legacy.configuration.extras.isEmpty, "legacy clips without saved settings use explicit current fallback")
        print("Photo reel egress: \(checks) passed")
    }
}
