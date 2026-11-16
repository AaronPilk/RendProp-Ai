import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd

struct PanoramaFrameInput {
    let imageURL: URL
    let cameraToWorld: [[Double]]
    let intrinsics: [[Double]]
    let resolution: ImageResolution
}

struct PanoramaRenderRequest {
    let frames: [PanoramaFrameInput]
    let origin: [Double]
    var referenceYawRadians: Double = 0
    var geometryProfile: StationCaptureGeometryProfile = .legacyPivotV1
    var maximumCameraDisplacementMetres: Double = 0.10
    var maximumCameraSpanMetres: Double = 0.20
    var width: Int = 4096
}

struct PanoramaRenderReport: Codable {
    var schema_version = 2
    var projection = "equirectangular-top-left-y-up-minus-z-centre"
    var method = "measured-rotation-most-central-source-v1"
    let width: Int
    let height: Int
    let source_frame_count: Int
    let covered_pixels: Int
    let pixel_coverage_fraction: Double
    let spherical_coverage_fraction: Double
    let maximum_camera_displacement_metres: Double
    let maximum_camera_span_metres: Double
    let geometry_profile: StationCaptureGeometryProfile
    let camera_displacement_limit_metres: Double
    let camera_span_limit_metres: Double
    let reference_yaw_radians: Double
    let elapsed_seconds: Double
    var unknown_pixels = "alpha-zero; no inpainting or invented content"
    var limitations = "Photographic station preview, not a measured 3D model. ARKit rotation error, parallax and exposure seams are not corrected."
    var solidAngleCoverage: Double { spherical_coverage_fraction }
    var pixelCoverage: Double { pixel_coverage_fraction }
    var maximumDisplacementMetres: Double { maximum_camera_displacement_metres }
    var maximumCameraSpanMetres: Double { maximum_camera_span_metres }
}

/// Called on a serial worker queue, never the main thread. Each source is
/// decoded once, within an autorelease pool. Output and score buffers are each
/// at most 32 MiB; ImageIO/CG add bounded input and codec working memory.
enum PanoramaRenderer {
    static let maximumFrames = 48
    static let maximumWidth = 4096
    static let maximumDurationSeconds = 90

    static func render(_ request: PanoramaRenderRequest, to destination: URL,
                       isCancelled: () -> Bool = { false },
                       progress: (Double) -> Void = { _ in }) throws -> PanoramaRenderReport {
        let clock = ContinuousClock()
        let started = clock.now
        let deadline = started.advanced(by: .seconds(maximumDurationSeconds))
        func checkActive() throws {
            if isCancelled() { throw CaptureError.invalid("Panorama preview cancelled. Original photos are preserved.") }
            if clock.now >= deadline { throw CaptureError.invalid("Panorama preview reached its 90-second limit. Original photos are preserved.") }
        }
        try checkActive()
        let profile = request.geometryProfile
        let supportedDisplacement = request.maximumCameraDisplacementMetres.isFinite
            && request.maximumCameraDisplacementMetres > 0
            && (profile == .legacyPivotV1
                ? request.maximumCameraDisplacementMetres <= profile.maximumPivotDriftMetres
                : request.maximumCameraDisplacementMetres == profile.maximumPivotDriftMetres)
        guard !request.frames.isEmpty, request.frames.count <= maximumFrames,
              request.width >= 64, request.width <= maximumWidth, request.width % 2 == 0,
              request.origin.count == 3, request.origin.allSatisfy(\.isFinite),
              request.referenceYawRadians.isFinite, abs(request.referenceYawRadians) <= 2 * .pi,
              supportedDisplacement,
              request.maximumCameraSpanMetres == profile.maximumCameraSpanMetres,
              destination.isFileURL, destination.pathExtension.lowercased() == "png" else {
            throw CaptureError.invalid("Panorama request exceeds the bounded station-preview format.")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CaptureError.invalid("A preview already exists at this location. The saved preview was preserved.")
        }
        let origin = SIMD3(request.origin[0], request.origin[1], request.origin[2])
        var maximumDisplacement = 0.0
        var uniqueImages = Set<String>()
        let cameras = try request.frames.map { frame in
            guard frame.imageURL.isFileURL, uniqueImages.insert(frame.imageURL.standardizedFileURL.path).inserted else {
                throw CaptureError.invalid("A panorama must contain distinct local photographs.")
            }
            let camera = try PanoramaProjection.Camera(cameraToWorld: frame.cameraToWorld,
                                                       intrinsics: frame.intrinsics, resolution: frame.resolution)
            let displacement = simd_distance(camera.position, origin)
            guard displacement <= request.maximumCameraDisplacementMetres + 1e-6 else {
                throw CaptureError.invalid("The camera moved too far from this scan position to make a rotation-only preview. Original photos are preserved.")
            }
            maximumDisplacement = max(maximumDisplacement, displacement)
            return camera
        }
        var maximumSpan = 0.0
        for index in cameras.indices {
            for previous in cameras[..<index] {
                maximumSpan = max(maximumSpan, simd_distance(cameras[index].position, previous.position))
            }
        }
        // The old format retains its established radius acceptance. Only the
        // explicitly versioned handheld format introduces a pairwise bound.
        if profile == .handheldV2, maximumSpan > request.maximumCameraSpanMetres + 1e-6 {
            throw CaptureError.invalid("These photos moved too far apart for this rotation-only preview. Original photos are preserved.")
        }
        let width = request.width, height = width / 2, count = width * height
        var output = [UInt8](repeating: 0, count: count * 4)
        var bestScore = [Float](repeating: 0, count: count)
        let longitudes: [Double] = (0..<width).map { x in
            let fraction = (Double(x) + 0.5) / Double(width)
            return (fraction * 2.0 - 1.0) * Double.pi + request.referenceYawRadians
        }
        let sinLongitude = longitudes.map { Float(sin($0)) }
        let cosLongitude = longitudes.map { Float(cos($0)) }
        let latitudes: [Double] = (0..<height).map { y in
            let fraction = (Double(y) + 0.5) / Double(height)
            return Double.pi / 2.0 - fraction * Double.pi
        }
        let sinLatitude = latitudes.map { Float(sin($0)) }
        let cosLatitude = latitudes.map { Float(cos($0)) }

        for (index, frame) in request.frames.enumerated() {
            try checkActive()
            try autoreleasepool {
                let camera = cameras[index]
                let pixels = try decode(frame)
                try output.withUnsafeMutableBufferPointer { target in
                    try bestScore.withUnsafeMutableBufferPointer { scores in
                        try pixels.withUnsafeBufferPointer { source in
                            for y in 0..<height {
                                if y % 16 == 0 { try checkActive() }
                                let ranges = camera.columnRanges(latitude: latitudes[y], referenceYawRadians: request.referenceYawRadians, outputWidth: width)
                                let horizontal = cosLatitude[y], vertical = sinLatitude[y]
                                let rowOffset = y * width
                                for range in ranges {
                                    for x in range {
                                        let ray = SIMD3(sinLongitude[x] * horizontal, vertical, -cosLongitude[x] * horizontal)
                                        let score = simd_dot(ray, camera.forward)
                                        let pixelIndex = rowOffset + x
                                        guard score > scores[pixelIndex] + 1e-7, let uv = camera.pixel(for: ray) else { continue }
                                        let left = Int(uv.x), top = Int(uv.y)
                                        let right = min(left + 1, camera.width - 1), bottom = min(top + 1, camera.height - 1)
                                        let dx = uv.x - Float(left), dy = uv.y - Float(top)
                                        let a = (top * camera.width + left) * 4, b = (top * camera.width + right) * 4
                                        let c = (bottom * camera.width + left) * 4, d = (bottom * camera.width + right) * 4
                                        let outputIndex = pixelIndex * 4
                                        for channel in 0..<3 {
                                            let upper = Float(source[a + channel]) * (1 - dx) + Float(source[b + channel]) * dx
                                            let lower = Float(source[c + channel]) * (1 - dx) + Float(source[d + channel]) * dx
                                            target[outputIndex + channel] = UInt8(max(0, min(255, (upper * (1 - dy) + lower * dy).rounded())))
                                        }
                                        target[outputIndex + 3] = 255
                                        scores[pixelIndex] = score
                                    }
                                }
                            }
                        }
                    }
                }
            }
            progress(Double(index + 1) / Double(request.frames.count + 1))
        }
        try checkActive()
        var covered = 0, coveredSolidAngle = 0.0, totalSolidAngle = 0.0
        for y in 0..<height {
            let weight = cos(latitudes[y])
            var rowCovered = 0
            for x in 0..<width where output[(y * width + x) * 4 + 3] != 0 { rowCovered += 1 }
            covered += rowCovered
            coveredSolidAngle += Double(rowCovered) * weight
            totalSolidAngle += Double(width) * weight
        }
        guard covered > 0 else { throw CaptureError.invalid("These photographs do not cover a usable panorama direction.") }
        try checkActive()
        // Write a new derived file only. Cancel/failure removes this temporary
        // derivative, never any original photograph or already saved preview.
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".panorama-\(UUID().uuidString).partial.png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try writePNG(output, width: width, height: height, to: temporary)
        try checkActive()
        try FileManager.default.moveItem(at: temporary, to: destination)
        progress(1)
        let duration = started.duration(to: clock.now).components
        return PanoramaRenderReport(width: width, height: height, source_frame_count: request.frames.count,
                                    covered_pixels: covered, pixel_coverage_fraction: Double(covered) / Double(count),
                                    spherical_coverage_fraction: coveredSolidAngle / totalSolidAngle,
                                    maximum_camera_displacement_metres: maximumDisplacement,
                                    maximum_camera_span_metres: maximumSpan,
                                    geometry_profile: profile,
                                    camera_displacement_limit_metres: request.maximumCameraDisplacementMetres,
                                    camera_span_limit_metres: request.maximumCameraSpanMetres,
                                    reference_yaw_radians: request.referenceYawRadians,
                                    elapsed_seconds: Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
    }

    private static func decode(_ frame: PanoramaFrameInput) throws -> [UInt8] {
        let source = try NativeRasterWriter.validatedJPEGSource(at: frame.imageURL, resolution: frame.resolution)
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == frame.resolution.width, image.height == frame.resolution.height, image.bitsPerComponent == 8 else {
            throw CaptureError.invalid("A saved panorama photograph could not be decoded at its measured resolution.")
        }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw CaptureError.invalid("Panorama raster memory could not be allocated.")
            }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    private static func writePNG(_ pixels: [UInt8], width: Int, height: Int, to url: URL) throws {
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.invalid("Panorama preview could not be encoded.")
        }
        CGImageDestinationAddImage(output, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw CaptureError.invalid("Panorama preview could not be saved. Original photos are preserved.") }
    }
}
