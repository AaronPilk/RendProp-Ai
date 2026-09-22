// SYNTHETIC NOT A ROOM: cross-language serialization/JPEG contract fixture only.
// Compile alongside the capture harness's actual CaptureModel and RasterWriter.
import Foundation
import simd
import CoreVideo
import Darwin

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CaptureError.invalid(message) }
}

do {
    let args = CommandLine.arguments
    try require(args.count == 2 || (args.count == 3 && ["--transpose-first-pose", "--pose-roundoff"].contains(args[2])),
        "Usage: synthetic-capture /new/output/directory [--transpose-first-pose | --pose-roundoff]")
    let output = URL(fileURLWithPath: args[1]).standardizedFileURL
    // POSIX mkdir fails atomically for an existing path: no overwrite, including
    // when another process creates the target between checking and creating it.
    guard mkdir(output.path, 0o700) == 0 else {
        throw CaptureError.invalid("Output must not already exist and its parent must exist: \(output.path)")
    }
    let negative = args.count == 3 && args[2] == "--transpose-first-pose"
    let roundoff = args.count == 3 && args[2] == "--pose-roundoff"
    let fm = FileManager.default
    try fm.createDirectory(at: output.appendingPathComponent("images"), withIntermediateDirectories: false)
    try fm.createDirectory(at: output.appendingPathComponent("frames"), withIntermediateDirectories: false)
    // Keep synthetic labeling in the directory name, manifest and CLI output.
    // An extra marker file violates the production export file-set contract.

    let width = 160, height = 120
    let resolution = ImageResolution(width: width, height: height)
    let intrinsics = simd_float3x3(columns: (SIMD3(120, 0, 0), SIMD3(0, 120, 0), SIMD3(80, 60, 1)))
    let session = "00000000-0000-4000-8000-000000000001"
    var points: [FeaturePoint] = []
    for index in 0..<120 {
        let identifier = String(UInt64.max - UInt64(index))
        let x: Double = Double(index % 12) * 0.1 - 0.55
        let y: Double = Double(index / 12) * 0.1 - 0.45
        let z: Double = -2.0 - Double(index % 3) * 0.05
        points.append(FeaturePoint(id: identifier, position: [x, y, z]))
    }
    var manifest = CaptureManifest(sessionID: session,
        deviceModel: "SYNTHETIC-NOT-A-ROOM Swift CLI", operatingSystem: "Synthetic fixture on \(ProcessInfo.processInfo.operatingSystemVersionString)")
    manifest.status = "complete"
    manifest.status_detail = negative ? "SYNTHETIC invalid transposed-pose fixture; MUST be refused." :
        (roundoff ? "SYNTHETIC Float32 roundoff serialization fixture; NOT phone capture or reconstruction." :
         "SYNTHETIC serialization fixture; NOT phone capture or reconstruction.")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let rasterWriter = NativeRasterWriter()

    for index in 1...20 {
        try autoreleasepool {
            let translation = Float(index - 1) * 0.01 - 0.095
            var c2w = matrix_identity_float4x4
            c2w.columns.3 = SIMD4(translation, 0, 0, 1)
            if roundoff {
                // Exercise the actual Float -> Double row serializer with a
                // noncanonical affine residual, without normalizing the pose.
                c2w.columns.3.w = Float(1).nextUp
            }
            let image = String(format: "images/%06d.jpg", index)
            let sidecar = String(format: "frames/%06d.json", index)
            var frame = FrameRecord(session_id: session, image: image,
                camera_to_world: CaptureGeometry.rows(c2w), intrinsics: CaptureGeometry.rows(intrinsics),
                image_resolution: resolution, timestamp: 100 + Double(index) * 0.5,
                tracking_state: TrackingRecord(state: "normal", reason: nil), raw_feature_points: points,
                exposure_duration_seconds: 0.01, exposure_offset_ev: 0, world_mapping_status: "mapped")
            try frame.validate(expectedSession: session)
            if roundoff {
                try require(frame.camera_to_world[3] == [0, 0, 0, Double(Float(1).nextUp)],
                    "Synthetic Float32 homogeneous residual was changed by serialization or validation")
            }

            var created: CVPixelBuffer?
            try require(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
                &created) == kCVReturnSuccess, "Could not allocate synthetic pixel buffer")
            let buffer = created!
            CVPixelBufferLockBaseAddress(buffer, [])
            let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height { for x in 0..<width {
                let offset = y * stride + x * 4
                bytes[offset] = 32; bytes[offset + 1] = UInt8(40 + y / 2)
                bytes[offset + 2] = UInt8(40 + x / 2); bytes[offset + 3] = 255
            } }
            // Put each synthetic 3D seed at its calibrated raster projection.
            // ARKit cameras look down -Z; image y runs down while world y runs up.
            for (number, point) in points.enumerated() {
                let p = point.position
                let u = Int(120 * (p[0] - Double(translation)) / -p[2] + 80)
                let v = Int(120 * -p[1] / -p[2] + 60)
                try require((2..<(width - 2)).contains(u) && (2..<(height - 2)).contains(v), "Synthetic feature fell outside raster")
                for y in (v - 1)...(v + 1) { for x in (u - 1)...(u + 1) {
                    let offset = y * stride + x * 4
                    bytes[offset] = UInt8(60 + number % 128)
                    bytes[offset + 1] = 200; bytes[offset + 2] = 220
                } }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let imageURL = output.appendingPathComponent(image)
            try rasterWriter.write(buffer, resolution: resolution, to: imageURL)
            try NativeRasterWriter.validateJPEG(at: imageURL, resolution: resolution)
            manifest.image_bytes += Int64((try fm.attributesOfItem(atPath: imageURL.path)[.size] as! NSNumber).int64Value)

            if negative && index == 1 {
                // Start from the real serializer, then deliberately model the
                // column/row mistake. Preserve this separate negative fixture.
                frame.camera_to_world = CaptureGeometry.rows(c2w.transpose)
            }
            try encoder.encode(frame).write(to: output.appendingPathComponent(sidecar), options: .withoutOverwriting)
            manifest.frames.append(sidecar)
            manifest.feature_point_observations += points.count
        }
    }
    manifest.finished_at = ISO8601DateFormatter().string(from: Date())
    try encoder.encode(manifest).write(to: output.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
    if negative {
        try require((try? NativeRasterWriter.validateCapture(at: output)) == nil,
            "Synthetic transposed-pose negative fixture unexpectedly passed Swift validation")
    } else {
        let validated = try NativeRasterWriter.validateCapture(at: output)
        try require(validated.frames.count == 20 && validated.feature_point_observations == 2400, "Unexpected synthetic capture counts")
    }
    print("Wrote SYNTHETIC NOT A ROOM: 20 native JPEGs, 20 Swift sidecars, 120 unique points; \(negative ? "invalid transpose expected" : (roundoff ? "raw Float32 roundoff preserved; Swift validation passed" : "Swift validation passed"))")
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
