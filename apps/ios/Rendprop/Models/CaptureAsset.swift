import Foundation

/// A recorded or imported walkthrough video living in the app container,
/// plus its (optional) gyro sidecar and room-tag chapters.
struct CaptureAsset: Identifiable, Codable, Hashable {
    var id = UUID()
    var localURL: URL
    var motionSidecarURL: URL?
    var durationS: Double
    var fps: Double
    var width: Int
    var height: Int
    var bytes: Int64
    var isDrone: Bool = false
    var roomTags: [RoomTag] = []

    var hasGyro: Bool { motionSidecarURL != nil }

    var resolutionLabel: String {
        if min(width, height) >= 2160 { return "4K" }
        if min(width, height) >= 1080 { return "1080p" }
        return "\(height)p"
    }
}
