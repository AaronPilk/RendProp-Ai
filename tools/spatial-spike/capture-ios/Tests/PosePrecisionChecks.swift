import Foundation
import simd
import CoreVideo

// These are synthetic numeric/file-ingestion tests, not ARFrame/device tests.
// Both producer and saved-export paths call the real FrameRecord validator.
@main
struct PosePrecisionChecks {
    static var checks = 0

    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        checks += 1
    }

    static func computedPose(_ index: Int) -> simd_float4x4 {
        let axis = simd_normalize(SIMD3<Float>(0.3, 0.7, 0.2))
        var source = simd_float4x4(simd_quatf(angle: Float(index) * 0.037, axis: axis))
        source.columns.3 = SIMD4<Float>(Float(index) * 0.013, -1.127, 3.14159, 1)
        return simd_inverse(source)
    }

    static func frame(_ pose: [[Double]], session: String, index: Int = 1) -> FrameRecord {
        FrameRecord(session_id: session, image: String(format: "images/%06d.jpg", index),
            camera_to_world: pose, intrinsics: [[60.25, 0, 31.5], [0, 61.125, 23.75], [0, 0, 1]],
            image_resolution: ImageResolution(width: 64, height: 48), timestamp: Double(index),
            tracking_state: TrackingRecord(state: "normal", reason: nil),
            raw_feature_points: [FeaturePoint(id: String(index), position: [0, 0, -2])],
            exposure_duration_seconds: 0.01, exposure_offset_ev: 0, world_mapping_status: "mapped")
    }

    static func validateAndRoundTrip(_ record: FrameRecord) throws {
        try record.validate(expectedSession: record.session_id)
        let encoded = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(FrameRecord.self, from: encoded)
        try decoded.validate(expectedSession: record.session_id)
        check(decoded.camera_to_world == record.camera_to_world, "every raw pose value must survive JSON unchanged")
        check(decoded.intrinsics == record.intrinsics, "calibration must not be repaired or rounded")
    }

    static func numericChecks() throws {
        let session = UUID().uuidString
        var pose = computedPose(1)
        // Explicit Float32 neighbors make the regression architecture-independent:
        // optimized SIMD inversion may choose different rounding on another CPU.
        for value in [Float(1).nextUp, Float(1).nextDown, 1 + 8 * Float.ulpOfOne] {
            pose.columns.3.w = value
            let rows = CaptureGeometry.rows(pose)
            check(rows[3][3] != 1, "fixture must exercise the old exact-equality failure")
            try validateAndRoundTrip(frame(rows, session: session))
        }
        for column in 0..<3 {
            for residual in [-0.0000005, 0.0000005, Double(0.000001).nextDown] {
                var rows = CaptureGeometry.rows(matrix_identity_float4x4)
                rows[3][column] = residual
                try validateAndRoundTrip(frame(rows, session: session))
            }
        }

        var nonexactInverses = 0
        var largestResidual = 0.0
        for index in 1...1000 {
            let inverse = computedPose(index)
            let rows = CaptureGeometry.rows(inverse)
            if rows[3] != [0, 0, 0, 1] { nonexactInverses += 1 }
            largestResidual = max(largestResidual, abs(rows[3][3] - 1))
            check(rows[0][3] == Double(inverse.columns.3.x)
                && rows[1][3] == Double(inverse.columns.3.y)
                && rows[2][3] == Double(inverse.columns.3.z), "SIMD translation remains the last column")
            try validateAndRoundTrip(frame(rows, session: session))
        }
        // Counts are diagnostic, not an assertion about every CPU's inverse.
        print("SIMD inverse samples: 1000; nonexact rows: \(nonexactInverses); largest w residual: \(largestResidual)")

        let identity = CaptureGeometry.rows(matrix_identity_float4x4)
        for residual in [0.000001, -0.000001, Double(0.000001).nextUp, 0.0001, 1.0] {
            for column in 0..<3 {
                var rows = identity
                rows[3][column] = residual
                check((try? frame(rows, session: session).validate(expectedSession: session)) == nil,
                    "strict absolute homogeneous-row boundary must reject \(residual)")
            }
        }
        var tooManyULPs = identity
        tooManyULPs[3][3] = Double(1 + 9 * Float.ulpOfOne)
        check((try? frame(tooManyULPs, session: session).validate(expectedSession: session)) == nil,
            "nine Float ULPs above one exceed the importer tolerance")
        for number in [Double.nan, .infinity, -.infinity] {
            var rows = identity
            rows[3][0] = number
            check((try? frame(rows, session: session).validate(expectedSession: session)) == nil, "nonfinite pose rejected before tolerance")
        }
        var transposed = computedPose(20)
        transposed = simd_transpose(transposed)
        check((try? frame(CaptureGeometry.rows(transposed), session: session).validate(expectedSession: session)) == nil,
            "translated transpose is still invalid; a pure zero-translation rotation is inherently ambiguous")
        var reflected = identity
        reflected[0][0] = -1
        check((try? frame(reflected, session: session).validate(expectedSession: session)) == nil, "reflection still rejected")
        var scaled = identity
        scaled[0][0] = 1.1
        check((try? frame(scaled, session: session).validate(expectedSession: session)) == nil, "non-rigid scale still rejected")
        var malformed = identity
        malformed[3].removeLast()
        check((try? frame(malformed, session: session).validate(expectedSession: session)) == nil, "shape checked before indexing the row")
    }

    static func exportChecks() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("spatial-pose-precision-\(UUID().uuidString)")
        let archive = CaptureArchive(root: temporary.appendingPathComponent("Captures"))
        check(try archive.prepareRoot(createIfMissing: true), "synthetic archive created")
        let session = UUID().uuidString
        let root = archive.root.appendingPathComponent(session)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("frames"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
        var pixelBuffer: CVPixelBuffer?
        check(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &pixelBuffer) == kCVReturnSuccess, "tiny synthetic raster allocated")
        let buffer = pixelBuffer!
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer)!, 128, CVPixelBufferGetBytesPerRow(buffer) * 48)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let seedImage = temporary.appendingPathComponent("synthetic-native.jpg")
        try NativeRasterWriter().write(buffer, resolution: ImageResolution(width: 64, height: 48), to: seedImage)
        var manifest = CaptureManifest(sessionID: session, deviceModel: "synthetic-pose-precision-test", operatingSystem: "test")
        manifest.status = "complete"
        let encoder = JSONEncoder()
        var originalSidecars: [String: Data] = [:]
        for index in 1...20 {
            var pose = computedPose(index)
            // Explicitly reproduce three durable records followed by a valid
            // nonexact Float row. This does not manufacture an ARFrame callback.
            pose.columns.3.w = index <= 3 ? 1 : Float(1).nextUp
            let record = frame(CaptureGeometry.rows(pose), session: session, index: index)
            do { try record.validate(expectedSession: session) }
            catch { throw CaptureError.invalid("Synthetic frame \(index) rejected after \(manifest.frames.count) saved: \(error.localizedDescription)") }
            let sidecar = String(format: "frames/%06d.json", index)
            let data = try encoder.encode(record)
            try data.write(to: root.appendingPathComponent(sidecar))
            try FileManager.default.copyItem(at: seedImage, to: root.appendingPathComponent(record.image))
            originalSidecars[sidecar] = data
            manifest.frames.append(sidecar)
            manifest.feature_point_observations += 1
        }
        let manifestURL = root.appendingPathComponent("manifest.json")
        try encoder.encode(manifest).write(to: manifestURL)
        check(try NativeRasterWriter.validateCapture(at: root).frames.count == 20, "complete nonexact-pose capture passes real export validator")
        check(try archive.validateForExport(id: session).lastPathComponent == session, "reopened/saved export uses the same precision policy")
        for (path, data) in originalSidecars {
            check(try Data(contentsOf: root.appendingPathComponent(path)) == data, "export validation leaves original sidecar bytes untouched")
        }
        let fourthURL = root.appendingPathComponent("frames/000004.json")
        var corrupted = try JSONDecoder().decode(FrameRecord.self, from: originalSidecars["frames/000004.json"]!)
        corrupted.camera_to_world[3][0] = 0.0001
        try encoder.encode(corrupted).write(to: fourthURL)
        check((try? archive.validateForExport(id: session)) == nil, "saved export still refuses a materially projective pose")
        try originalSidecars["frames/000004.json"]!.write(to: fourthURL)
        manifest.status = "failed"
        try encoder.encode(manifest).write(to: manifestURL)
        check((try? archive.validateForExport(id: session)) == nil, "failed phone attempts are not relabeled as successful captures")
        print("Synthetic 20-frame export/recovery checked; fixtures retained at \(temporary.path)")
    }

    static func main() {
        if CommandLine.arguments.contains("--force-failure") { check(false, "intentional pose-precision failure") }
        do {
            if !CommandLine.arguments.contains("--export-only") { try numericChecks() }
            try exportChecks()
            print("PASS: \(checks) pose precision assertions; 0 skipped")
        } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
