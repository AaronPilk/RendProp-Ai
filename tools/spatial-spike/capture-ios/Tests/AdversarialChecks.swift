import Foundation
import CoreVideo
import simd

// All input is synthetic and lives in a fresh temporary directory. These tests
// never read a user's capture or claim AR/device/reconstruction evidence.
@main
enum AdversarialChecks {
    static let cases = ["valid", "sidecar-link", "image-link", "directory-link", "unexpected-link", "oversized-sidecar", "oversized-manifest"]

    static func main() {
        let requested = Array(CommandLine.arguments.dropFirst())
        let selected = requested.isEmpty ? cases : requested
        guard selected.allSatisfy(cases.contains) else { fputs("FAIL: unknown adversarial case\n", stderr); exit(1) }
        var failures = 0
        for name in selected {
            do {
                let root = try fixture()
                let parent = root.deletingLastPathComponent()
                switch name {
                case "sidecar-link", "image-link", "directory-link":
                    let relative = name == "sidecar-link" ? "frames/000020.json" : name == "image-link" ? "images/000020.jpg" : "frames"
                    let source = root.appendingPathComponent(relative)
                    let outside = parent.appendingPathComponent("outside-" + source.lastPathComponent)
                    try FileManager.default.moveItem(at: source, to: outside)
                    try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
                case "unexpected-link":
                    let outside = parent.appendingPathComponent("outside.txt")
                    try Data("not part of this capture".utf8).write(to: outside)
                    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("extra-link"), withDestinationURL: outside)
                case "oversized-sidecar", "oversized-manifest":
                    let file = root.appendingPathComponent(name == "oversized-sidecar" ? "frames/000020.json" : "manifest.json")
                    var data = try Data(contentsOf: file)
                    let cap = name == "oversized-sidecar" ? 16 * 1024 * 1024 : 256 * 1024
                    data.append(Data(repeating: 32, count: cap + 1 - data.count)) // Valid JSON with excessive whitespace.
                    try data.write(to: file)
                default: break
                }
                let accepted = (try? NativeRasterWriter.validateCapture(at: root)) != nil
                guard accepted == (name == "valid") else {
                    failures += 1
                    fputs("FAIL: \(name) was \(accepted ? "accepted" : "rejected")\n", stderr)
                    continue
                }
                print("PASS: \(name)")
            } catch {
                failures += 1
                fputs("FAIL: fixture/setup for \(name): \(error)\n", stderr)
            }
        }
        print("Adversarial capture checks: \(selected.count - failures) passed, \(failures) failed, 0 skipped")
        exit(failures == 0 ? 0 : 1)
    }

    static func fixture() throws -> URL {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("spatial-adversarial-\(UUID().uuidString)")
        let sid = UUID().uuidString
        let root = temporary.appendingPathComponent(sid)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("frames"), withIntermediateDirectories: true)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 80, 48, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw CaptureError.invalid("Could not allocate synthetic raster.") }
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer)!, 128, CVPixelBufferGetBytesPerRow(buffer) * 48)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let writer = NativeRasterWriter()
        let encoder = JSONEncoder()
        var manifest = CaptureManifest(sessionID: sid, deviceModel: "synthetic-adversarial-test", operatingSystem: "test")
        manifest.status = "complete"
        for index in 1...20 {
            let imagePath = String(format: "images/%06d.jpg", index)
            let framePath = String(format: "frames/%06d.json", index)
            if index == 1 { try writer.write(buffer, resolution: ImageResolution(width: 80, height: 48), to: root.appendingPathComponent(imagePath)) }
            else { try FileManager.default.copyItem(at: root.appendingPathComponent("images/000001.jpg"), to: root.appendingPathComponent(imagePath)) }
            let frame = FrameRecord(session_id: sid, image: imagePath,
                camera_to_world: CaptureGeometry.rows(matrix_identity_float4x4), intrinsics: [[100, 0, 40], [0, 100, 24], [0, 0, 1]],
                image_resolution: ImageResolution(width: 80, height: 48), timestamp: Double(index),
                tracking_state: TrackingRecord(state: "normal", reason: nil), raw_feature_points: [FeaturePoint(id: String(index), position: [0, 0, -2])],
                exposure_duration_seconds: 0.01, exposure_offset_ev: 0, world_mapping_status: "mapped")
            try encoder.encode(frame).write(to: root.appendingPathComponent(framePath))
            manifest.frames.append(framePath)
        }
        manifest.feature_point_observations = 20
        try encoder.encode(manifest).write(to: root.appendingPathComponent("manifest.json"))
        return root
    }
}
