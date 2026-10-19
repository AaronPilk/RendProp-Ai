import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd

/// Generated color fields only. These deterministic coordinate/raster checks
/// do not test physical camera behavior, a real room, or reconstruction quality.
@main enum PanoramaChecks {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }
    static func rejects(_ message: String, _ operation: () throws -> Void) {
        do { try operation(); check(false, "accepted \(message)") }
        catch { checks += 1 }
    }
    static func matrix(yaw: Double = 0, pitch: Double = 0, roll: Double = 0,
                       x: Double = 0, y: Double = 0, z: Double = 0) -> [[Double]] {
        // Independent explicit rotation multiplication: Ry(-yaw) Rx(pitch) Rz(roll).
        let yawRotation = [[cos(yaw), 0, -sin(yaw)], [0, 1, 0], [sin(yaw), 0, cos(yaw)]]
        let p = [[1.0, 0, 0], [0, cos(pitch), -sin(pitch)], [0, sin(pitch), cos(pitch)]]
        let r = [[cos(roll), -sin(roll), 0], [sin(roll), cos(roll), 0], [0, 0, 1]]
        func multiply(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
            var product = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
            for row in 0..<3 { for col in 0..<3 { for k in 0..<3 { product[row][col] += a[row][k] * b[k][col] } } }
            return product
        }
        let result = multiply(multiply(yawRotation, p), r)
        return [result[0] + [x], result[1] + [y], result[2] + [z], [0, 0, 0, 1]]
    }
    static func color(_ ray: SIMD3<Double>) -> [UInt8] {
        [ray.x, ray.y, ray.z].map { UInt8(max(0, min(255, (127.5 + $0 * 100).rounded()))) }
    }
    static func writeFixture(_ url: URL, matrix m: [[Double]], width: Int = 320, height: Int = 240,
                             flat: [UInt8]? = nil, noisy: Bool = false) throws -> PanoramaFrameInput {
        let focal = Double(width) * 0.7, cx = Double(width - 1) / 2, cy = Double(height - 1) / 2
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let camera = simd_normalize(SIMD3((Double(x) - cx) / focal, -(Double(y) - cy) / focal, -1))
                let world = SIMD3(m[0][0] * camera.x + m[0][1] * camera.y + m[0][2] * camera.z,
                                  m[1][0] * camera.x + m[1][1] * camera.y + m[1][2] * camera.z,
                                  m[2][0] * camera.x + m[2][1] * camera.y + m[2][2] * camera.z)
                var rgb = flat ?? color(world)
                if noisy {
                    // High-entropy JPEG decode stress, deterministic and free
                    // of room media. The color-oracle checks use noisy=false.
                    var noise = UInt32(x) &* 73_856_093 ^ UInt32(y) &* 19_349_663 ^ 0x9e3779b9
                    noise ^= noise << 13; noise ^= noise >> 17; noise ^= noise << 5
                    rgb = [UInt8(noise & 255), UInt8((noise >> 8) & 255), UInt8((noise >> 16) & 255)]
                }
                let index = (y * width + x) * 4
                for channel in 0..<3 { pixels[index + channel] = rgb[channel] }
            }
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: space,
                            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationSetProperties(destination, [kCGImageDestinationOrientation: 1] as CFDictionary)
        CGImageDestinationAddImage(destination, image,
            [kCGImagePropertyOrientation: 1, kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: 1],
             kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.invalid("Fixture failed.") }
        return PanoramaFrameInput(imageURL: url, cameraToWorld: m, intrinsics: [[focal, 0, cx], [0, focal, cy], [0, 0, 1]],
                                  resolution: ImageResolution(width: width, height: height))
    }
    static func decoded(_ url: URL) -> (Int, Int, [UInt8]) {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return (image.width, image.height, pixels)
    }
    static func pixel(_ raster: (Int, Int, [UInt8]), yaw: Double, pitch: Double) -> [UInt8] {
        let x = max(0, min(raster.0 - 1, Int((yaw + .pi) / (2 * .pi) * Double(raster.0))))
        let y = max(0, min(raster.1 - 1, Int((.pi / 2 - pitch) / .pi * Double(raster.1))))
        return Array(raster.2[((y * raster.0 + x) * 4)..<((y * raster.0 + x) * 4 + 4)])
    }
    static func orientations() -> [[[Double]]] {
        var result: [[[Double]]] = []
        for pitch in [0.0, 50.0, -50.0] {
            for index in 0..<12 { result.append(matrix(yaw: Double(index) * .pi / 6, pitch: pitch * .pi / 180, roll: .pi / 2)) }
        }
        result.append(matrix(pitch: .pi / 2, roll: .pi / 2))
        result.append(matrix(pitch: -.pi / 2, roll: .pi / 2))
        return result
    }

    static func main() throws {
        if CommandLine.arguments.contains("--intentional-failure") { check(false, "checker proves failures are nonzero") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("panorama-checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let forward = try writeFixture(root.appendingPathComponent("forward.jpg"), matrix: matrix())
        let camera = try PanoramaProjection.Camera(cameraToWorld: forward.cameraToWorld, intrinsics: forward.intrinsics, resolution: forward.resolution)
        check(camera.pixel(for: SIMD3(0, 0, -1)) == SIMD2(159.5, 119.5), "-Z projects to native principal point")
        check(camera.pixel(for: simd_normalize(SIMD3(0, 0.1, -1)))!.y < 119.5, "world up maps to smaller native image y")
        check(camera.pixel(for: simd_normalize(SIMD3(0.1, 0, -1)))!.x > 159.5, "world right maps to larger native image x")
        check(camera.pixel(for: SIMD3(0, 0, 1)) == nil, "behind camera is not sampled")

        let singleURL = root.appendingPathComponent("single.png")
        let single = try PanoramaRenderer.render(PanoramaRenderRequest(frames: [forward], origin: [0, 0, 0], width: 512), to: singleURL)
        let raster = decoded(singleURL)
        check(pixel(raster, yaw: 0, pitch: 0)[3] == 255, "observed direction opaque")
        check(pixel(raster, yaw: .pi / 2, pitch: 0) == [0, 0, 0, 0], "unobserved direction remains exact transparent")
        check(pixel(raster, yaw: 0, pitch: 0.2)[1] > pixel(raster, yaw: 0, pitch: -0.2)[1] + 25, "native JPEG decode retains top/bottom orientation")
        check(single.solidAngleCoverage > single.pixelCoverage, "solid-angle coverage corrects equirectangular polar weighting")
        check(single.source_frame_count == 1 && single.width == 512 && single.height == 256, "report source count and dimensions")

        let fullFrames = try orientations().enumerated().map { index, rotation in
            try writeFixture(root.appendingPathComponent("full-\(index).jpg"), matrix: rotation)
        }
        let fullURL = root.appendingPathComponent("full.png")
        let full = try PanoramaRenderer.render(PanoramaRenderRequest(frames: fullFrames, origin: [0, 0, 0], width: 512), to: fullURL)
        let complete = decoded(fullURL)
        check(full.solidAngleCoverage > 0.999 && full.pixelCoverage > 0.999, "38 generated orientations cover sphere")
        var squaredError = 0.0, maximumError = 0, samples = 0
        for y in 0..<complete.1 {
            for x in 0..<complete.0 {
                let longitude = (Double(x) + 0.5) * 2 * .pi / Double(complete.0) - .pi
                let latitude = .pi / 2 - (Double(y) + 0.5) * .pi / Double(complete.1)
                let expected = color(SIMD3(sin(longitude) * cos(latitude), sin(latitude), -cos(longitude) * cos(latitude)))
                let index = (y * complete.0 + x) * 4
                if complete.2[index + 3] == 0 { continue }
                for channel in 0..<3 {
                    let error = abs(Int(complete.2[index + channel]) - Int(expected[channel]))
                    maximumError = max(maximumError, error)
                    squaredError += Double(error * error)
                    samples += 1
                }
            }
        }
        let rmse = sqrt(squaredError / Double(samples))
        check(rmse < 2.5 && maximumError <= 8, "render matches independent spherical color oracle; RMSE=\(rmse), max=\(maximumError)")
        let handheldFrames = try StationCaptureGeometryProfile.handheldV2.targets.enumerated().map { index, target in
            try writeFixture(root.appendingPathComponent("handheld-plan-\(index).jpg"),
                matrix: matrix(yaw: target.yaw_degrees * .pi / 180, pitch: target.pitch_degrees * .pi / 180, roll: .pi / 2))
        }
        for (index, pole) in [(36, SIMD3<Float>(0, 1, 0)), (37, SIMD3<Float>(0, -1, 0))] {
            let frame = handheldFrames[index]
            let camera = try PanoramaProjection.Camera(cameraToWorld: frame.cameraToWorld, intrinsics: frame.intrinsics, resolution: frame.resolution)
            let uv = camera.pixel(for: pole)
            check(uv != nil && uv!.x >= Float(frame.resolution.width) * 0.08
                  && uv!.x <= Float(frame.resolution.width - 1) - Float(frame.resolution.width) * 0.08
                  && uv!.y >= Float(frame.resolution.height) * 0.08
                  && uv!.y <= Float(frame.resolution.height - 1) - Float(frame.resolution.height) * 0.08,
                  "80-degree handheld pole stays inside calibrated image with an 8 percent margin")
        }
        let handheldFullURL = root.appendingPathComponent("handheld-full.png")
        let handheldFull = try PanoramaRenderer.render(
            PanoramaRenderRequest(frames: handheldFrames, origin: [0, 0, 0], geometryProfile: .handheldV2,
                maximumCameraDisplacementMetres: 0.20, width: 512), to: handheldFullURL)
        check(handheldFull.source_frame_count == 38 && handheldFull.solidAngleCoverage > 0.999 && handheldFull.pixelCoverage > 0.999,
              "38 handheld measured rotations including 80-degree poles photographically cover the sphere")
        let handheldComplete = decoded(handheldFullURL)
        check(pixel(handheldComplete, yaw: 0, pitch: .pi / 2)[3] == 255
              && pixel(handheldComplete, yaw: 0, pitch: -.pi / 2)[3] == 255,
              "handheld plan samples photographed ceiling and floor poles")
        for y in [1, complete.1 / 4, complete.1 / 2, complete.1 * 3 / 4, complete.1 - 2] {
            let first = (y * complete.0) * 4, last = (y * complete.0 + complete.0 - 1) * 4
            for channel in 0..<3 { check(abs(Int(complete.2[first + channel]) - Int(complete.2[last + channel])) < 5, "longitude wrap seam remains continuous") }
        }
        let shiftedURL = root.appendingPathComponent("shifted.png")
        _ = try PanoramaRenderer.render(PanoramaRenderRequest(frames: fullFrames, origin: [0, 0, 0], referenceYawRadians: .pi / 2, width: 256), to: shiftedURL)
        check(pixel(decoded(shiftedURL), yaw: 0, pitch: 0)[0] > 220, "reference yaw rotates output centre toward world +X")

        let red = try writeFixture(root.appendingPathComponent("red.jpg"), matrix: matrix(), flat: [240, 10, 10])
        let blue = try writeFixture(root.appendingPathComponent("blue.jpg"), matrix: matrix(yaw: .pi / 9), flat: [10, 10, 240])
        let selectionURL = root.appendingPathComponent("selection.png")
        _ = try PanoramaRenderer.render(PanoramaRenderRequest(frames: [red, blue], origin: [0, 0, 0], width: 512), to: selectionURL)
        let selection = decoded(selectionURL)
        check(pixel(selection, yaw: 0, pitch: 0)[0] > 230, "most-central first source wins at own axis")
        check(pixel(selection, yaw: .pi / 9, pitch: 0)[2] > 230, "most-central second source wins at own axis")

        let untouched = try Data(contentsOf: forward.imageURL)
        let invalidURL = root.appendingPathComponent("must-not-exist.png")
        let handheldPhoto = try writeFixture(root.appendingPathComponent("handheld.jpg"), matrix: matrix(x: 0.18))
        let handheldOriginal = try Data(contentsOf: handheldPhoto.imageURL)
        let handheldURL = root.appendingPathComponent("handheld.png")
        let handheld = try PanoramaRenderer.render(
            PanoramaRenderRequest(frames: [forward, handheldPhoto], origin: [0, 0, 0], geometryProfile: .handheldV2,
                                  maximumCameraDisplacementMetres: 0.20, width: 512), to: handheldURL)
        check(handheld.geometry_profile == .handheldV2 && handheld.camera_displacement_limit_metres == 0.20
              && handheld.camera_span_limit_metres == 0.20, "handheld report identifies exact declared profile and limits")
        check(abs(handheld.maximumDisplacementMetres - 0.18) < 1e-12
              && abs(handheld.maximumCameraSpanMetres - 0.18) < 1e-12, "handheld report measures one-sided 18 cm radius and span")
        check(decoded(handheldURL).2 == raster.2, "handheld translation keeps measured rotation-only projection and exact unknown alpha")
        check(single.geometry_profile == .legacyPivotV1 && single.camera_displacement_limit_metres == 0.10
              && single.maximumCameraSpanMetres == 0, "default renderer retains the legacy profile and measures actual span")
        let opposite = PanoramaFrameInput(imageURL: red.imageURL, cameraToWorld: matrix(x: -0.18), intrinsics: red.intrinsics, resolution: red.resolution)
        rejects("handheld 36 cm pairwise span inside 20 cm radius") {
            _ = try PanoramaRenderer.render(PanoramaRenderRequest(frames: [handheldPhoto, opposite], origin: [0, 0, 0],
                geometryProfile: .handheldV2, maximumCameraDisplacementMetres: 0.20, width: 128), to: invalidURL)
        }
        let diagonal = PanoramaFrameInput(imageURL: blue.imageURL, cameraToWorld: matrix(y: 0.18), intrinsics: blue.intrinsics, resolution: blue.resolution)
        rejects("handheld 3D diagonal span above 20 cm") {
            _ = try PanoramaRenderer.render(PanoramaRenderRequest(frames: [handheldPhoto, diagonal], origin: [0, 0, 0],
                geometryProfile: .handheldV2, maximumCameraDisplacementMetres: 0.20, width: 128), to: invalidURL)
        }
        let outOfBounds = PanoramaFrameInput(imageURL: forward.imageURL, cameraToWorld: matrix(x: 0.201), intrinsics: forward.intrinsics, resolution: forward.resolution)
        rejects("handheld radius above 20 cm") {
            _ = try PanoramaRenderer.render(PanoramaRenderRequest(frames: [outOfBounds], origin: [0, 0, 0],
                geometryProfile: .handheldV2, maximumCameraDisplacementMetres: 0.20, width: 128), to: invalidURL)
        }
        rejects("legacy profile with handheld radius") {
            _ = try PanoramaRenderer.render(PanoramaRenderRequest(frames: [handheldPhoto], origin: [0, 0, 0],
                maximumCameraDisplacementMetres: 0.20, width: 128), to: invalidURL)
        }
        rejects("handheld profile with legacy radius") {
            _ = try PanoramaRenderer.render(PanoramaRenderRequest(frames: [forward], origin: [0, 0, 0],
                geometryProfile: .handheldV2, width: 128), to: invalidURL)
        }
        rejects("handheld profile with undeclared span") {
            _ = try PanoramaRenderer.render(PanoramaRenderRequest(frames: [forward], origin: [0, 0, 0],
                geometryProfile: .handheldV2, maximumCameraDisplacementMetres: 0.20, maximumCameraSpanMetres: 0.30, width: 128), to: invalidURL)
        }
        rejects("unknown renderer geometry profile at typed boundary") {
            _ = try JSONDecoder().decode(StationCaptureGeometryProfile.self, from: Data("\"station-unknown-v3\"".utf8))
        }
        let strict = try PanoramaRenderer.render(PanoramaRenderRequest(frames: [forward], origin: [0, 0, 0],
            maximumCameraDisplacementMetres: 0.05, width: 128), to: root.appendingPathComponent("strict-legacy.png"))
        check(strict.geometry_profile == .legacyPivotV1 && strict.camera_displacement_limit_metres == 0.05, "legacy caller can retain its stricter radius")
        let legacyEdgeA = PanoramaFrameInput(imageURL: red.imageURL, cameraToWorld: matrix(x: 0.1000005), intrinsics: red.intrinsics, resolution: red.resolution)
        let legacyEdgeB = PanoramaFrameInput(imageURL: blue.imageURL, cameraToWorld: matrix(x: -0.1000005), intrinsics: blue.intrinsics, resolution: blue.resolution)
        let legacyEdge = try PanoramaRenderer.render(PanoramaRenderRequest(frames: [legacyEdgeA, legacyEdgeB], origin: [0, 0, 0], width: 128),
            to: root.appendingPathComponent("legacy-edge.png"))
        check(legacyEdge.maximumCameraSpanMetres > 0.20, "legacy arithmetic tolerance does not acquire a new pairwise rejection")
        let moved = PanoramaFrameInput(imageURL: forward.imageURL, cameraToWorld: matrix(x: 0.101), intrinsics: forward.intrinsics, resolution: forward.resolution)
        rejects("station translation") { _ = try PanoramaRenderer.render(PanoramaRenderRequest(frames: [moved], origin: [0, 0, 0], width: 128), to: invalidURL) }
        rejects("more than 48 frames") { _ = try PanoramaRenderer.render(PanoramaRenderRequest(frames: Array(repeating: forward, count: 49), origin: [0, 0, 0], width: 128), to: invalidURL) }
        rejects("duplicate image paths") { _ = try PanoramaRenderer.render(PanoramaRenderRequest(frames: [forward, forward], origin: [0, 0, 0], width: 128), to: invalidURL) }
        rejects("oversized panorama") { _ = try PanoramaRenderer.render(PanoramaRenderRequest(frames: [forward], origin: [0, 0, 0], width: 4098), to: invalidURL) }
        rejects("unbounded reference yaw") { _ = try PanoramaRenderer.render(PanoramaRenderRequest(frames: [forward], origin: [0, 0, 0], referenceYawRadians: 1e100, width: 128), to: invalidURL) }
        rejects("pre-start cancellation") { _ = try PanoramaRenderer.render(PanoramaRenderRequest(frames: [forward], origin: [0, 0, 0], width: 128), to: invalidURL, isCancelled: { true }) }
        var cancellationCalls = 0
        rejects("mid-render cancellation") {
            _ = try PanoramaRenderer.render(PanoramaRenderRequest(frames: fullFrames, origin: [0, 0, 0], width: 1024), to: invalidURL,
                isCancelled: { cancellationCalls += 1; return cancellationCalls >= 10 })
        }
        check(cancellationCalls == 10, "cancellation is checked within source rows")
        var skewed = forward.intrinsics
        skewed[0][1] = 1
        let unsupported = PanoramaFrameInput(imageURL: forward.imageURL, cameraToWorld: matrix(), intrinsics: skewed, resolution: forward.resolution)
        rejects("non-pinhole skew") { _ = try PanoramaRenderer.render(PanoramaRenderRequest(frames: [unsupported], origin: [0, 0, 0], width: 128), to: invalidURL) }
        skewed = forward.intrinsics
        skewed[0][0] = 1e-300
        let underflow = PanoramaFrameInput(imageURL: forward.imageURL, cameraToWorld: matrix(), intrinsics: skewed, resolution: forward.resolution)
        rejects("focal length underflow") { _ = try PanoramaRenderer.render(PanoramaRenderRequest(frames: [underflow], origin: [0, 0, 0], width: 128), to: invalidURL) }
        let symlink = root.appendingPathComponent("link.jpg")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: forward.imageURL)
        let linked = PanoramaFrameInput(imageURL: symlink, cameraToWorld: matrix(), intrinsics: forward.intrinsics, resolution: forward.resolution)
        rejects("source symlink") { _ = try PanoramaRenderer.render(PanoramaRenderRequest(frames: [linked], origin: [0, 0, 0], width: 128), to: invalidURL) }
        rejects("replacing saved preview") { _ = try PanoramaRenderer.render(PanoramaRenderRequest(frames: [forward], origin: [0, 0, 0], width: 128), to: singleURL) }
        check(!FileManager.default.fileExists(atPath: invalidURL.path), "rejected jobs leave no declared output")
        let afterBytes = try Data(contentsOf: forward.imageURL)
        check(afterBytes == untouched, "source JPEG unchanged after rendering and errors")
        let handheldAfterBytes = try Data(contentsOf: handheldPhoto.imageURL)
        check(handheldAfterBytes == handheldOriginal, "handheld source JPEG unchanged after profile renders and errors")
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        check(files.allSatisfy { !$0.contains("partial.png") }, "no failed partial derivative retained")
        let encodedReport = try JSONEncoder().encode(full)
        let decodedReport = try JSONDecoder().decode(PanoramaRenderReport.self, from: encodedReport)
        check(decodedReport.covered_pixels == full.covered_pixels, "render report codable round trip")
        print("PASS PanoramaChecks \(checks) assertions; spherical oracle RMSE \(rmse), max channel error \(maximumError).")

        if CommandLine.arguments.contains("--benchmark") {
            let native = try writeFixture(root.appendingPathComponent("native.jpg"), matrix: matrix(), width: 1920, height: 1440, noisy: true)
            let data = try Data(contentsOf: native.imageURL)
            let frames = try orientations().enumerated().map { index, rotation -> PanoramaFrameInput in
                try autoreleasepool {
                    let url = root.appendingPathComponent("benchmark-\(index).jpg")
                    try data.write(to: url)
                    return PanoramaFrameInput(imageURL: url, cameraToWorld: rotation, intrinsics: native.intrinsics, resolution: native.resolution)
                }
            }
            let report = try PanoramaRenderer.render(PanoramaRenderRequest(frames: frames, origin: [0, 0, 0]), to: root.appendingPathComponent("benchmark.png"))
            print("BENCHMARK 38 distinct high-entropy 1920x1440 JPEG paths (\(data.count) bytes each) -> \(report.width)x\(report.height) PNG in \(report.elapsed_seconds)s, coverage \(report.solidAngleCoverage). Generated image workload; not a phone/camera performance claim.")
        }
    }
}
