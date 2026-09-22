// Harness-only boundaries: use the real RenderEngine, CaptureAsset and RoomTag.
// Media import/UI storage are not exercised. Never write an app's Documents.
import Foundation

enum SpaceType {
    case fixture
    static var current: SpaceType { .fixture }
    var quickTags: [String] { [] }
}
enum MediaImporter {
    static let maxDurationSeconds: Double = 600
    static let minDurationSeconds: Double = 0.2
}
enum FileStore {
    static var recordingsDir: URL {
        let value = ProcessInfo.processInfo.environment["RENDER_FIXTURE_DIRECTORY"]!
        precondition(value.hasPrefix("/tmp/rendprop-render-concurrency-"))
        return URL(fileURLWithPath: value).appendingPathComponent("renders", isDirectory: true)
    }
}
