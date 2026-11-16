import Foundation

enum StationCaptureLimits {
    static let maximumStations = 8
    static let maximumFramesPerStation = 48
    static let maximumTourBytes: Int64 = 1_610_612_736
    static let minimumFreeBytes: Int64 = 268_435_456
    static let frameReservationBytes: Int64 = 90 * 1024 * 1024
    static let maximumManifestBytes = 512 * 1024
    static let maximumDepthPixels = 1024 * 1024
    static let maximumPivotDriftMeters = 0.10
}

enum StationCaptureStatus: String, Codable { case capturing, complete, partial, interrupted, failed }

/// Supported capture geometry is explicit in the archive. The handheld profile
/// permits more movement from the first photo without increasing v1's maximum
/// possible separation between any two accepted camera positions.
enum StationCaptureGeometryProfile: String, Codable {
    case legacyPivotV1 = "station-pivot-10cm-v1"
    case handheldV2 = "station-handheld-20cm-span-v2-provisional"

    var maximumPivotDriftMetres: Double { self == .legacyPivotV1 ? 0.10 : 0.20 }
    var maximumCameraSpanMetres: Double { 0.20 }
    var targetPlan: String {
        self == .legacyPivotV1 ? "station-spherical-38-v1-provisional" : "station-spherical-38-v2-handheld-provisional"
    }
    var targets: [StationCaptureTarget] { self == .legacyPivotV1 ? StationCaptureTarget.standard : StationCaptureTarget.handheld }
}

struct StationCaptureTarget: Codable, Equatable {
    let id: String
    let index: Int
    let yaw_degrees: Double
    let pitch_degrees: Double
    let instruction: String

    // Presentation is computed separately from the persisted v1 targets. Changing
    // their stored instruction strings would invalidate existing local archives.
    var phaseTitle: String {
        if id.hasPrefix("middle-") { return "Walls" }
        if id.hasPrefix("upper-") { return "Upper walls" }
        if id.hasPrefix("lower-") { return "Lower walls" }
        return id == "ceiling" ? "Ceiling" : "Floor"
    }
    var phasePhotoNumber: Int { index < 36 ? index % 12 + 1 : 1 }
    var phasePhotoCount: Int { index < 36 ? 12 : 1 }
    var progressTitle: String { "\(phaseTitle) · photo \(phasePhotoNumber) of \(phasePhotoCount)" }

    static let standard: [StationCaptureTarget] = {
        var targets: [StationCaptureTarget] = []
        for (ring, pitch, instruction) in [("middle", 0.0, "Turn slowly to the left"),
                                            ("upper", 50.0, "Tilt up, then turn slowly to the left"),
                                            ("lower", -50.0, "Tilt down, then turn slowly to the left")] {
            for heading in 0..<12 {
                targets.append(.init(id: "\(ring)-\(heading)", index: targets.count,
                                     yaw_degrees: -Double(heading) * 30, pitch_degrees: pitch, instruction: instruction))
            }
        }
        targets.append(.init(id: "ceiling", index: targets.count, yaw_degrees: 0, pitch_degrees: 90, instruction: "Point toward the ceiling"))
        targets.append(.init(id: "floor", index: targets.count, yaw_degrees: 0, pitch_degrees: -90, instruction: "Point toward the floor"))
        return targets
    }()

    /// Same 38 photographic directions and order; ordinary phone optics include
    /// the exact poles without requiring the lens to face completely vertical.
    /// Actual pole coverage still has to pass the native calibrated image test.
    static let handheld: [StationCaptureTarget] = standard.map { target in
        guard target.id == "ceiling" || target.id == "floor" else { return target }
        return .init(id: target.id, index: target.index, yaw_degrees: target.yaw_degrees,
                     pitch_degrees: target.id == "ceiling" ? 80 : -80, instruction: target.instruction)
    }

    func direction(referenceYawDegrees: Double) -> [Double] {
        let yaw = (referenceYawDegrees + yaw_degrees) * .pi / 180
        let pitch = pitch_degrees * .pi / 180
        return [sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch)]
    }
}

struct StationCaptureDepth: Codable {
    let path: String
    let width: Int
    let height: Int
    var format = "float32-little-endian-packed-rows"
    var units = "metres"
    var source = "ARFrame.sceneDepth"
    var calibration = "Same ARFrame camera intrinsics; depth raster is scaled relative to image_resolution. No depth interpolation or invalid-value repair performed."
    let confidence_path: String?
    var confidence_format = "uint8-packed-rows; 0=low,1=medium,2=high"
}

struct StationCaptureFrame: Codable {
    var schema_version = 1
    let station_id: String
    let target_id: String
    let frame: FrameRecord
    let depth: StationCaptureDepth?
    let depth_availability: String
    let pivot_drift_metres: Double
    let angular_error_degrees: Double
}

struct StationCaptureStation: Codable {
    let id: String
    let index: Int
    var origin: [Double]
    var reference_yaw_degrees: Double
    let started_timestamp: Double
    var targets = StationCaptureTarget.standard
    var frames: [String] = []
    var status: StationCaptureStatus = .capturing
    var status_detail = "Follow the targets while keeping the camera at this position."
    var finished_at: String?
    var label: String { "Position \(index + 1)" }
}

struct StationCaptureManifest: Codable {
    var schema_version = 1
    var format = "rendprop-station-capture"
    let session_id: String
    let started_at: String
    let device_model: String
    let operating_system: String
    let depth_supported: Bool
    var coordinate_system = "arkit-right-handed-y-up-camera-minus-z-forward"
    var image_orientation = "sensor-native-exif-1"
    var matrix_layout = "row-major"
    var units = "metres"
    var target_plan = "station-spherical-38-v1-provisional"
    var geometry_note = "Measured ARKit camera poses and optional scene depth. Stations are not a verified mesh, floor plan or measurement product."
    var maximum_pivot_drift_metres = StationCaptureLimits.maximumPivotDriftMeters
    var capture_policy: String?
    var maximum_camera_span_metres: Double?
    private var containsNewGeometryFields = false
    var status: StationCaptureStatus = .capturing
    var status_detail = "Capture in progress."
    var finished_at: String?
    var stations: [StationCaptureStation] = []
    var stored_bytes: Int64 = 0
    var frameCount: Int { stations.reduce(0) { $0 + $1.frames.count } }

    var geometryProfile: StationCaptureGeometryProfile? {
        if schema_version == 1, maximum_pivot_drift_metres == 0.10,
           !containsNewGeometryFields, capture_policy == nil, maximum_camera_span_metres == nil { return .legacyPivotV1 }
        if schema_version == 2, capture_policy == StationCaptureGeometryProfile.handheldV2.rawValue,
           maximum_pivot_drift_metres == 0.20, maximum_camera_span_metres == 0.20 { return .handheldV2 }
        return nil
    }

    init(sessionID: String, deviceModel: String, operatingSystem: String, depthSupported: Bool,
         profile: StationCaptureGeometryProfile = .legacyPivotV1) {
        session_id = sessionID
        started_at = ISO8601DateFormatter().string(from: Date())
        device_model = deviceModel
        operating_system = operatingSystem
        depth_supported = depthSupported
        target_plan = profile.targetPlan
        if profile == .handheldV2 {
            schema_version = 2
            capture_policy = profile.rawValue
            maximum_pivot_drift_metres = profile.maximumPivotDriftMetres
            maximum_camera_span_metres = profile.maximumCameraSpanMetres
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schema_version, format, session_id, started_at, device_model, operating_system, depth_supported
        case coordinate_system, image_orientation, matrix_layout, units, target_plan, geometry_note
        case maximum_pivot_drift_metres, capture_policy, maximum_camera_span_metres
        case status, status_detail, finished_at, stations, stored_bytes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema_version = try c.decode(Int.self, forKey: .schema_version)
        format = try c.decode(String.self, forKey: .format)
        session_id = try c.decode(String.self, forKey: .session_id)
        started_at = try c.decode(String.self, forKey: .started_at)
        device_model = try c.decode(String.self, forKey: .device_model)
        operating_system = try c.decode(String.self, forKey: .operating_system)
        depth_supported = try c.decode(Bool.self, forKey: .depth_supported)
        coordinate_system = try c.decode(String.self, forKey: .coordinate_system)
        image_orientation = try c.decode(String.self, forKey: .image_orientation)
        matrix_layout = try c.decode(String.self, forKey: .matrix_layout)
        units = try c.decode(String.self, forKey: .units)
        target_plan = try c.decode(String.self, forKey: .target_plan)
        geometry_note = try c.decode(String.self, forKey: .geometry_note)
        maximum_pivot_drift_metres = try c.decode(Double.self, forKey: .maximum_pivot_drift_metres)
        containsNewGeometryFields = c.contains(.capture_policy) || c.contains(.maximum_camera_span_metres)
        capture_policy = try c.decodeIfPresent(String.self, forKey: .capture_policy)
        maximum_camera_span_metres = try c.decodeIfPresent(Double.self, forKey: .maximum_camera_span_metres)
        status = try c.decode(StationCaptureStatus.self, forKey: .status)
        status_detail = try c.decode(String.self, forKey: .status_detail)
        finished_at = try c.decodeIfPresent(String.self, forKey: .finished_at)
        stations = try c.decode([StationCaptureStation].self, forKey: .stations)
        stored_bytes = try c.decode(Int64.self, forKey: .stored_bytes)
    }
}

struct StationCaptureArchiveEntry {
    let url: URL
    let manifest: StationCaptureManifest?
    let issue: String?
}

enum StationCaptureArchive {
    static func localRoot() throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return documents.appendingPathComponent("StationCaptures", isDirectory: true)
    }

    static func prepareRoot(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try requireDirectory(root)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var writable = root
        try writable.setResourceValues(values)
        writable.removeCachedResourceValue(forKey: .isExcludedFromBackupKey)
        guard try writable.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else {
            throw CaptureError.invalid("Could not keep local room captures out of device backups.")
        }
    }

    static func loadManifest(at root: URL) throws -> StationCaptureManifest {
        try requireDirectory(root)
        guard UUID(uuidString: root.lastPathComponent) != nil else { throw CaptureError.invalid("Invalid saved tour identifier.") }
        let data = try NativeRasterWriter.boundedJSONData(at: root.appendingPathComponent("manifest.json"), maximumBytes: StationCaptureLimits.maximumManifestBytes)
        let value = try JSONDecoder().decode(StationCaptureManifest.self, from: data)
        try validateManifest(value, directoryID: root.lastPathComponent)
        return value
    }

    static func listTours(at root: URL? = nil, offset: Int = 0, limit: Int = 30) throws -> [StationCaptureArchiveEntry] {
        guard offset >= 0, (1...50).contains(limit) else { throw CaptureError.invalid("Invalid saved-tour page.") }
        let directory = try root ?? localRoot()
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        try requireDirectory(directory)
        // Do not read all old images/manifests into memory. The directory iterator
        // bounds each page even if many earlier attempts exist.
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsSubdirectoryDescendants], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw CaptureError.invalid("Saved tours could not be listed.")
        }
        var skipped = 0
        var result: [StationCaptureArchiveEntry] = []
        while let url = enumerator.nextObject() as? URL {
            if let enumerationError { throw enumerationError }
            guard UUID(uuidString: url.lastPathComponent) != nil else { continue }
            if skipped < offset { skipped += 1; continue }
            if result.count == limit { break }
            do { result.append(.init(url: url, manifest: try loadManifest(at: url), issue: nil)) }
            catch { result.append(.init(url: url, manifest: nil, issue: "Saved files need recovery; they have not been deleted.")) }
        }
        if let enumerationError { throw enumerationError }
        return result
    }

    /// Fully validates raw originals, then returns compact rendering metadata.
    /// Returned FrameRecords omit raw_feature_points to bound retained memory;
    /// the complete, validated point arrays remain unchanged in the sidecars.
    static func loadFrames(at root: URL, stationID: String) throws -> [StationCaptureFrame] {
        let manifest = try loadManifest(at: root)
        guard let station = manifest.stations.first(where: { $0.id == stationID }) else { throw CaptureError.invalid("The saved position was not found.") }
        return try loadFrames(at: root, manifest: manifest, station: station)
    }

    static func validateForExport(at root: URL) throws -> StationCaptureManifest {
        try validateArchive(at: root, allowRecording: false)
    }

    /// Hub-only recovery after the previous capture controller/writer is gone.
    /// The caller must disable starting a camera session for the duration of
    /// this operation. No pose epoch is resumed and no raw file is changed.
    static func recoverAbandonedTour(at root: URL) throws -> StationCaptureManifest {
        let original = try loadManifest(at: root)
        guard original.status == .capturing else { return original }
        // Validate even an empty capture's exact declared file set. Orphan files
        // from a killed write block recovery instead of being silently dropped.
        var recovered = try validateArchive(at: root, allowRecording: true)
        let finished = ISO8601DateFormatter().string(from: Date())
        for index in recovered.stations.indices where recovered.stations[index].status == .capturing {
            recovered.stations[index].status = .interrupted
            recovered.stations[index].status_detail = "Recovered after the app closed. Only fully saved target photos are included."
            recovered.stations[index].finished_at = finished
        }
        recovered.status = .interrupted
        recovered.status_detail = "Recovered after the app closed. Saved photos are preserved; start a new tour for further capture."
        recovered.finished_at = finished
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(recovered)
        guard data.count <= StationCaptureLimits.maximumManifestBytes else { throw CaptureError.invalid("Recovered manifest exceeds its size limit.") }
        try data.write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
        return recovered
    }

    private static func validateArchive(at root: URL, allowRecording: Bool) throws -> StationCaptureManifest {
        let manifest = try loadManifest(at: root)
        guard allowRecording || (manifest.status != .capturing && manifest.frameCount > 0) else {
            throw CaptureError.invalid("Finish saving before exporting this tour.")
        }
        var expected: Set<String> = ["manifest.json", "images", "frames", "depth"]
        for station in manifest.stations {
            for (path, record) in zip(station.frames, try loadFrames(at: root, manifest: manifest, station: station)) {
                expected.insert(path); expected.insert(record.frame.image)
                if let depth = record.depth {
                    expected.insert(depth.path)
                    if let confidence = depth.confidence_path { expected.insert(confidence) }
                }
            }
        }
        var bytes: Int64 = 0
        var count = 0
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw CaptureError.invalid("Tour files could not be verified.")
        }
        while let url = enumerator.nextObject() as? URL {
            count += 1
            guard count <= 1700 else { throw CaptureError.invalid("Tour contains too many files.") }
            let relative: String
            switch enumerator.level {
            case 1: relative = url.lastPathComponent
            case 2: relative = url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
            default: throw CaptureError.invalid("Tour contains an unexpected nested directory.")
            }
            let properties = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            let directoryExpected = ["images", "frames", "depth"].contains(relative)
            guard expected.remove(relative) != nil, properties.isSymbolicLink != true,
                  directoryExpected ? properties.isDirectory == true : properties.isRegularFile == true else {
                throw CaptureError.invalid("Unexpected or unfinished files are preserved. This tour cannot be exported as verified yet.")
            }
            let size = Int64(properties.fileSize ?? 0)
            bytes += size
            guard bytes <= StationCaptureLimits.maximumTourBytes else { throw CaptureError.invalid("Tour exceeds its storage limit.") }
        }
        if let enumerationError { throw enumerationError }
        guard expected.isEmpty else { throw CaptureError.invalid("Tour is missing declared files or directories.") }
        return manifest
    }

    static func validateManifest(_ value: StationCaptureManifest, directoryID: String) throws {
        guard let profile = value.geometryProfile, value.format == "rendprop-station-capture",
              value.session_id.caseInsensitiveCompare(directoryID) == .orderedSame,
              value.coordinate_system == "arkit-right-handed-y-up-camera-minus-z-forward",
              value.image_orientation == "sensor-native-exif-1", value.matrix_layout == "row-major", value.units == "metres",
              value.target_plan == profile.targetPlan,
              ISO8601DateFormatter().date(from: value.started_at) != nil,
              value.stations.count <= StationCaptureLimits.maximumStations,
              value.stored_bytes >= 0, value.stored_bytes <= StationCaptureLimits.maximumTourBytes else {
            throw CaptureError.invalid("Saved tour format or limits are invalid.")
        }
        var ids: Set<String> = []; var paths: Set<String> = []
        var next = 1
        for (index, station) in value.stations.enumerated() {
            guard UUID(uuidString: station.id) != nil, ids.insert(station.id).inserted, station.index == index,
                  station.origin.count == 3, station.origin.allSatisfy(\.isFinite), station.reference_yaw_degrees.isFinite,
                  station.started_timestamp.isFinite, station.started_timestamp >= 0,
                  station.targets == profile.targets,
                  station.frames.count <= station.targets.count,
                  station.status != .complete || station.frames.count == station.targets.count else {
                throw CaptureError.invalid("Saved position metadata is invalid.")
            }
            for path in station.frames {
                guard path == String(format: "frames/%06d.json", next), paths.insert(path).inserted else {
                    throw CaptureError.invalid("Saved tour photo order is invalid.")
                }
                next += 1
            }
        }
        if value.status == .complete {
            guard !value.stations.isEmpty, value.stations.allSatisfy({ $0.status == .complete }) else {
                throw CaptureError.invalid("A completed tour contains an unfinished position.")
            }
        }
    }

    private static func loadFrames(at root: URL, manifest: StationCaptureManifest, station: StationCaptureStation) throws -> [StationCaptureFrame] {
        for directory in ["images", "frames", "depth"] { try requireDirectory(root.appendingPathComponent(directory)) }
        guard let profile = manifest.geometryProfile else { throw CaptureError.invalid("Saved tour capture policy is unsupported.") }
        var result: [StationCaptureFrame] = []
        var lastTimestamp = -Double.infinity
        for (index, path) in station.frames.enumerated() {
            let lightweight: StationCaptureFrame = try autoreleasepool {
                let record = try JSONDecoder().decode(StationCaptureFrame.self, from: NativeRasterWriter.boundedJSONData(at: root.appendingPathComponent(path), maximumBytes: NativeRasterWriter.maximumSidecarBytes))
                try record.frame.validate(expectedSession: manifest.session_id)
                let number = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                guard record.schema_version == 1, record.station_id == station.id, record.target_id == station.targets[index].id,
                      record.frame.image == "images/\(number).jpg", record.frame.timestamp > lastTimestamp,
                      record.frame.timestamp >= station.started_timestamp,
                      record.pivot_drift_metres.isFinite, (0...profile.maximumPivotDriftMetres).contains(record.pivot_drift_metres),
                      record.angular_error_degrees.isFinite, (0...StationCapturePolicy.targetToleranceDegrees).contains(record.angular_error_degrees) else {
                    throw CaptureError.invalid("Saved photo does not match its position and target.")
                }
                let actualDrift = sqrt((0..<3).reduce(0.0) { $0 + pow(record.frame.camera_to_world[$1][3] - station.origin[$1], 2) })
                guard abs(actualDrift - record.pivot_drift_metres) < 0.000_001 else { throw CaptureError.invalid("Saved photo position disagrees with its pivot measurement.") }
                guard let pose = StationCapturePolicy.pose(record.frame.camera_to_world) else { throw CaptureError.invalid("Saved camera pose is invalid.") }
                if profile == .handheldV2 {
                    guard actualDrift <= profile.maximumPivotDriftMetres else {
                        throw CaptureError.invalid("Saved handheld photo exceeds its measured viewpoint radius.")
                    }
                    guard StationCapturePolicy.poleIsPhotographed(target: station.targets[index], cameraToWorld: record.frame.camera_to_world,
                                                                 intrinsics: record.frame.intrinsics, resolution: record.frame.image_resolution) else {
                        throw CaptureError.invalid("Saved handheld pole photo does not include the ceiling or floor within its calibrated image.")
                    }
                    if index == 0 {
                        let yaw = atan2(pose.forward[0], -pose.forward[2]) * 180 / .pi
                        let yawDifference = (yaw - station.reference_yaw_degrees) * .pi / 180
                        guard actualDrift < 0.000_001, abs(atan2(sin(yawDifference), cos(yawDifference))) < 0.000_001 else {
                            throw CaptureError.invalid("Saved handheld viewpoint does not match its first photo.")
                        }
                    }
                    for previous in result {
                        let distance = sqrt((0..<3).reduce(0.0) { $0 + pow(record.frame.camera_to_world[$1][3] - previous.frame.camera_to_world[$1][3], 2) })
                        guard distance <= profile.maximumCameraSpanMetres else {
                            throw CaptureError.invalid("Saved handheld photos exceed their camera-position span.")
                        }
                    }
                }
                let direction = station.targets[index].direction(referenceYawDegrees: station.reference_yaw_degrees)
                let cosine = zip(pose.forward, direction).reduce(0.0) { $0 + $1.0 * $1.1 }
                let actualAngle = acos(min(1, max(-1, cosine))) * 180 / .pi
                guard abs(actualAngle - record.angular_error_degrees) < 0.000_001 else { throw CaptureError.invalid("Saved photo direction disagrees with its target measurement.") }
                try NativeRasterWriter.validateJPEG(at: root.appendingPathComponent(record.frame.image), resolution: record.frame.image_resolution)
                if let depth = record.depth {
                    guard record.depth_availability == "available", depth.path == "depth/\(number).f32",
                          depth.width > 0, depth.height > 0, depth.width <= 1024, depth.height <= 1024,
                          depth.width * depth.height <= StationCaptureLimits.maximumDepthPixels,
                          depth.format == "float32-little-endian-packed-rows", depth.units == "metres", depth.source == "ARFrame.sceneDepth",
                          depth.confidence_path == nil || depth.confidence_path == "depth/\(number).confidence" else {
                        throw CaptureError.invalid("Saved depth metadata is invalid.")
                    }
                    guard try NativeRasterWriter.boundedJSONData(at: root.appendingPathComponent(depth.path), maximumBytes: StationCaptureLimits.maximumDepthPixels * 4).count == depth.width * depth.height * 4 else {
                        throw CaptureError.invalid("Saved depth size does not match its calibration.")
                    }
                    if let confidence = depth.confidence_path {
                        let bytes = try NativeRasterWriter.boundedJSONData(at: root.appendingPathComponent(confidence), maximumBytes: StationCaptureLimits.maximumDepthPixels)
                        guard bytes.count == depth.width * depth.height, bytes.allSatisfy({ $0 <= 2 }) else { throw CaptureError.invalid("Saved depth confidence is invalid.") }
                    }
                } else if !["unsupported", "unavailable-on-this-frame"].contains(record.depth_availability) {
                    throw CaptureError.invalid("Missing depth is not explicitly recorded.")
                }
                lastTimestamp = record.frame.timestamp
                // Validate every raw point above, then release the potentially large
                // point cloud with this frame's autorelease pool. Preview and export
                // verification need only calibration/pose/depth references. Original
                // sidecar bytes retain the complete cloud and are never rewritten.
                let raw = record.frame
                let compact = FrameRecord(session_id: raw.session_id, image: raw.image, camera_to_world: raw.camera_to_world,
                                          intrinsics: raw.intrinsics, image_resolution: raw.image_resolution, timestamp: raw.timestamp,
                                          tracking_state: raw.tracking_state, raw_feature_points: [],
                                          exposure_duration_seconds: raw.exposure_duration_seconds, exposure_offset_ev: raw.exposure_offset_ev,
                                          world_mapping_status: raw.world_mapping_status, angular_speed_deg_s: raw.angular_speed_deg_s,
                                          predicted_smear_px: raw.predicted_smear_px, motion_previous_timestamp: raw.motion_previous_timestamp,
                                          motion_previous_camera_to_world: raw.motion_previous_camera_to_world)
                return StationCaptureFrame(station_id: record.station_id, target_id: record.target_id, frame: compact,
                                           depth: record.depth, depth_availability: record.depth_availability,
                                           pivot_drift_metres: record.pivot_drift_metres, angular_error_degrees: record.angular_error_degrees)
            }
            result.append(lightweight)
        }
        return result
    }

    private static func requireDirectory(_ url: URL) throws {
        let properties = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard properties.isDirectory == true, properties.isSymbolicLink != true else { throw CaptureError.invalid("Tour storage must be a local directory.") }
    }
}
