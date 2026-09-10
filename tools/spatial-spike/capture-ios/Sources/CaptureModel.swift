import Foundation
import simd

enum CaptureError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let detail) = self { return detail }; return nil }
}

enum CaptureGeometry {
    // ARKit supplies Float transforms. Even a rigid affine Float matrix can gain
    // a few ULPs in its homogeneous row after matrix arithmetic. Exact equality
    // stops otherwise valid captures; match prepare_capture.py's strict absolute
    // bound instead. This is validation, not pose repair: never snap the row,
    // divide by w, or change the measured matrix written to the sidecar.
    static let homogeneousRowTolerance = 1e-6

    // Swift SIMD indexes columns first. JSON explicitly stores mathematical rows.
    static func rows(_ matrix: simd_float4x4) -> [[Double]] {
        (0..<4).map { row in (0..<4).map { Double(matrix[$0][row]) } }
    }
    static func rows(_ matrix: simd_float3x3) -> [[Double]] {
        (0..<3).map { row in (0..<3).map { Double(matrix[$0][row]) } }
    }
}

struct ImageResolution: Codable, Equatable { let width: Int; let height: Int }

enum CaptureRasterLimits {
    // Native 1920-wide preferred video and 4K/4032x3024 fallback rasters fit.
    // These are explicit Phase A resource limits, not a claim about every future
    // ARKit format. Never resize a frame to satisfy them: K must stay verbatim.
    static let maximumDimension = 8192
    static let maximumPixels = 16 * 1024 * 1024

    static func validate(_ resolution: ImageResolution) throws {
        guard resolution.width > 0, resolution.height > 0,
              resolution.width <= maximumDimension, resolution.height <= maximumDimension else {
            throw CaptureError.invalid("Native raster exceeds the 8192-pixel axis safety limit or has an invalid size.")
        }
        let (pixels, overflow) = resolution.width.multipliedReportingOverflow(by: resolution.height)
        guard !overflow, pixels <= maximumPixels else {
            throw CaptureError.invalid("Native raster exceeds the 16,777,216-pixel safety limit.")
        }
    }
}

struct TrackingRecord: Codable {
    let state: String
    let reason: String?
    // Keep null explicit so an absent tracking reason is never ambiguous.
    enum CodingKeys: String, CodingKey { case state, reason }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state)
        if let reason { try container.encode(reason, forKey: .reason) }
        else { try container.encodeNil(forKey: .reason) }
    }
}
struct FeaturePoint: Codable { let id: String; let position: [Double] }

struct FrameRecord: Codable {
    var schema_version = 1
    let session_id: String
    var image: String
    var camera_to_world: [[Double]]
    var intrinsics: [[Double]]
    let image_resolution: ImageResolution
    let timestamp: Double
    var tracking_state: TrackingRecord
    let raw_feature_points: [FeaturePoint]
    let exposure_duration_seconds: Double
    let exposure_offset_ev: Double
    let world_mapping_status: String

    func validate(expectedSession: String) throws {
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw CaptureError.invalid(message) }
        }
        try require(schema_version == 1 && session_id == expectedSession, "Capture epoch/schema mismatch.")
        try require(image.range(of: #"^images/[0-9]{6}\.jpg$"#, options: .regularExpression) != nil, "Invalid image path.")
        try require(tracking_state.state == "normal", "Frame tracking must be normal.")
        try require(timestamp.isFinite && timestamp >= 0, "Invalid timestamp.")
        try require(camera_to_world.count == 4 && camera_to_world.allSatisfy { $0.count == 4 && $0.allSatisfy(\.isFinite) }, "Invalid c2w matrix.")
        let homogeneousRowError = zip(camera_to_world[3], [0.0, 0, 0, 1])
            .map { abs($0 - $1) }.max()!
        // A bounded residual is enough to diagnose future device failures; do
        // not put camera positions or the full measured pose in error messages.
        try require(homogeneousRowError < CaptureGeometry.homogeneousRowTolerance,
                    "Invalid c2w homogeneous row (max error \(homogeneousRowError); must be below \(CaptureGeometry.homogeneousRowTolerance)).")
        let c = camera_to_world
        for a in 0..<3 {
            for b in 0..<3 {
                let dot = (0..<3).reduce(0.0) { $0 + c[$1][a] * c[$1][b] }
                try require(abs(dot - (a == b ? 1 : 0)) < 0.01, "Non-rigid camera rotation.")
            }
        }
        let det = c[0][0] * (c[1][1] * c[2][2] - c[1][2] * c[2][1])
            - c[0][1] * (c[1][0] * c[2][2] - c[1][2] * c[2][0])
            + c[0][2] * (c[1][0] * c[2][1] - c[1][1] * c[2][0])
        try require(abs(det - 1) < 0.01, "Reflected camera rotation.")
        try require(intrinsics.count == 3 && intrinsics.allSatisfy { $0.count == 3 && $0.allSatisfy(\.isFinite) }, "Invalid intrinsics.")
        try require(intrinsics[0][0] > 0 && intrinsics[1][1] > 0 && intrinsics[2] == [0, 0, 1], "Invalid calibration matrix.")
        try CaptureRasterLimits.validate(image_resolution)
        try require(exposure_duration_seconds.isFinite && exposure_offset_ev.isFinite, "Invalid exposure.")
        try require(raw_feature_points.count <= 50_000, "More than 50,000 feature points in one frame; capture stopped without truncation.")
        for point in raw_feature_points {
            try require(UInt64(point.id) != nil && point.position.count == 3 && point.position.allSatisfy(\.isFinite), "Invalid ARKit feature point.")
        }
    }
}

struct CaptureManifest: Codable {
    var schema_version = 1
    var format = "rendprop-arkit-capture"
    let session_id: String
    var image_orientation = "sensor-native-exif-1"
    var coordinate_system = "arkit-right-handed-y-up-camera-minus-z-forward"
    var matrix_layout = "row-major"
    var pose_type = "camera-to-world"
    var world_alignment = "gravity"
    var units = "metres"
    var timestamp_units = "ARFrame.timestamp monotonic seconds"
    var image_pixel_origin = "top-left; intrinsics copied verbatim from ARCamera"
    var feature_points_note = "ARKit estimated feature points are initialization hints, not a reconstructed mesh."
    var status = "recording"
    var status_detail = "Capture in progress."
    let started_at: String
    var finished_at: String?
    let device_model: String
    let operating_system: String
    var cadence_seconds = 0.5
    var maximum_frames = 400
    var maximum_duration_seconds = 600.0
    var frames: [String] = []
    var feature_point_observations = 0
    var skipped_tracking_frames = 0
    var skipped_busy_frames = 0
    var image_bytes: Int64 = 0

    init(sessionID: String, deviceModel: String, operatingSystem: String) {
        session_id = sessionID
        started_at = ISO8601DateFormatter().string(from: Date())
        device_model = deviceModel
        operating_system = operatingSystem
    }
    var isExportable: Bool { status == "complete" && frames.count >= 20 && feature_point_observations > 0 }
}

struct FrameCadence {
    private var lastTimestamp: Double?
    mutating func accept(timestamp: Double, normalTracking: Bool) -> Bool {
        guard normalTracking, timestamp.isFinite,
              lastTimestamp.map({ timestamp - $0 >= 0.5 }) ?? true else { return false }
        lastTimestamp = timestamp
        return true
    }
}
