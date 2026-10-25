import Foundation

/// A stretch of a take, in seconds on the FINISHED video's clock — i.e. after
/// a paused take has been joined, not wall time.
struct TimeRange: Codable, Hashable {
    var startS: Double
    var endS: Double

    var durationS: Double { max(0, endS - startS) }
}

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
    /// Stretches where a PERSON was visible while filming — the photographer in
    /// a mirror or a window, or somebody walking through the shot.
    ///
    /// Recorded on-device during capture (Vision, free, no upload, ~2 Hz) for
    /// two reasons. The first is the warning on the capture screen, which is
    /// the only fix that actually costs nothing: step out of shot and there is
    /// nothing to repair. The second is economics. The server CAN erase a
    /// person from video — `/ai-video/declutter`, Bria's video eraser — but its
    /// source has to be under five seconds, and a walkthrough is two to fifteen
    /// MINUTES. Running an eraser over a whole take is not a thing that can be
    /// bought at this price; running it over the eleven seconds where somebody
    /// was actually visible is. These ranges are what make that difference, so
    /// they are captured now even though nothing consumes them yet.
    var personVisibleRanges: [TimeRange] = []

    var hasGyro: Bool { motionSidecarURL != nil }

    /// Total seconds of this take with a person visible in it.
    var personVisibleSeconds: Double {
        personVisibleRanges.reduce(0) { $0 + $1.durationS }
    }

    var resolutionLabel: String {
        if min(width, height) >= 2160 { return "4K" }
        if min(width, height) >= 1080 { return "1080p" }
        return "\(height)p"
    }
}
