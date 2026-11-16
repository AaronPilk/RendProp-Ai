import Foundation

enum PhotoCapturePurpose: Equatable, Sendable { case interior, exterior }

/// Pure decisions shared by the real still camera and executable tests. Lens
/// names represent physical cameras at zoom 1, never simulated digital zoom.
enum PhotoCapturePolicy {
    enum Lens: Equatable, Sendable { case ultraWide, wide }
    enum Phase: Equatable, Sendable {
        case idle, awaitingPermission, opening, ready, orienting, capturing, reviewing, saving, failed, closed
        var canStart: Bool { self == .idle || self == .ready || self == .failed || self == .reviewing }
        var canResume: Bool { self == .idle || self == .ready || self == .failed }
        var canCapture: Bool { self == .ready }
        var canOrient: Bool { self == .ready }
        var isBusy: Bool { [.awaitingPermission, .opening, .orienting, .capturing, .saving].contains(self) }
    }
    /// Physical device orientation (the same naming convention as UIDevice).
    enum Orientation: Equatable, Sendable {
        case portrait, landscapeLeft, landscapeRight, portraitUpsideDown
        var isLandscape: Bool { self == .landscapeLeft || self == .landscapeRight }
        var canvasRotationRadians: Double {
            switch self { case .portrait: return 0; case .landscapeLeft: return .pi / 2; case .landscapeRight: return -.pi / 2; case .portraitUpsideDown: return .pi }
        }
        /// AVCaptureVideoOrientation names refer to the home-button side;
        /// UIDevice landscape names refer to device rotation, so they reverse.
        var captureOrientationRawValue: Int {
            switch self { case .portrait: return 1; case .portraitUpsideDown: return 2; case .landscapeLeft: return 3; case .landscapeRight: return 4 }
        }
    }
    struct Dimensions: Equatable, Sendable {
        let width: Int32
        let height: Int32
        var pixels: Int64 { Int64(width) * Int64(height) }
    }
    struct Level: Equatable, Sendable {
        let rollRadians: Double
        let tiltRadians: Double
        var isLevel: Bool { abs(rollRadians) <= 2 * .pi / 180 && abs(tiltRadians) <= 8 * .pi / 180 }
    }
    static func defaultLens(purpose: PhotoCapturePurpose, supportsUltraWide: Bool) -> Lens {
        purpose == .interior && supportsUltraWide ? .ultraWide : .wide
    }
    static func orientation(gravityX x: Double, gravityY y: Double, previous: Orientation) -> Orientation {
        guard x.isFinite, y.isFinite, max(abs(x), abs(y)) > 0.72 else { return previous }
        // Hysteresis keeps a tilted/face-up phone from flipping the controls.
        if abs(x) > abs(y) + 0.18 { return x < 0 ? .landscapeLeft : .landscapeRight }
        if abs(y) > abs(x) + 0.18 { return y < 0 ? .portrait : .portraitUpsideDown }
        return previous
    }
    static func level(gravityX x: Double, gravityY y: Double, gravityZ z: Double, orientation: Orientation) -> Level? {
        guard x.isFinite, y.isFinite, z.isFinite, hypot(x, y) > 0.2 else { return nil }
        let raw = atan2(x, -y) + orientation.canvasRotationRadians
        return Level(rollRadians: atan2(sin(raw), cos(raw)), tiltRadians: asin(max(-1, min(1, z))))
    }
    static func preferredDimensions(_ supported: [Dimensions]) -> Dimensions? {
        let valid = supported.filter { $0.width > 0 && $0.height > 0 }
        // A regular high-quality JPEG, not a slow 48MP/RAW capture. Every
        // returned value is a real advertised format dimension, not invented.
        let bounded = valid.filter { $0.pixels <= 13_000_000 }
        return bounded.max(by: { $0.pixels < $1.pixels }) ?? valid.min(by: { $0.pixels < $1.pixels })
    }
}
