// Only importer/UI persistence boundaries are replaced. The render engine,
// AVFoundation, CaptureAsset and RoomTag are the actual production sources.
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
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: env["RENDER_QUALITY_FIXTURE_ROOT"]!).standardizedFileURL
        let directory = URL(fileURLWithPath: env["RENDER_FIXTURE_DIRECTORY"]!).standardizedFileURL
        precondition(root.lastPathComponent.hasPrefix("rendprop-render-concurrency-hd-"))
        precondition(directory.deletingLastPathComponent() == root)
        return directory.appendingPathComponent("renders", isDirectory: true)
    }
}
