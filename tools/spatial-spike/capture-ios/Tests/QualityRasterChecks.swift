import Foundation
import CoreVideo

/// Executes the exact production CoreVideo sampling function extracted by the
/// harness. All pixel buffers are generated here; no camera or saved room is read.
@main enum QualityRasterChecks {
    struct Failure: Error { let reason: String }
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        count += 1
        if !condition() { throw Failure(reason: message) }
    }
    static func fixture(width: Int, height: Int, videoRange: Bool = false, flat: Bool = false) throws -> CVPixelBuffer {
        var pixel: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
            videoRange ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            nil, &pixel)
        guard result == kCVReturnSuccess, let pixel else { throw Failure(reason: "Could not allocate synthetic luma buffer") }
        guard CVPixelBufferLockBaseAddress(pixel, []) == kCVReturnSuccess else { throw Failure(reason: "Could not lock synthetic buffer") }
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixel, 0) else { throw Failure(reason: "Missing synthetic luma plane") }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0)
        for y in 0..<height {
            for x in 0..<rowBytes {
                var value = flat ? 120.0 : ((y / 48 + x / 48) % 2 == 0 ? 40.0 : 210.0)
                if videoRange { value = 16 + value * 219 / 255 }
                bytes[y * rowBytes + x] = x < width ? UInt8(value.rounded()) : 255
            }
        }
        return pixel
    }
    static func checksum(_ pixel: CVPixelBuffer) throws -> UInt64 {
        guard CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { throw Failure(reason: "Could not verify luma bytes") }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        let bytes = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)!.assumingMemoryBound(to: UInt8.self)
        let count = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) * CVPixelBufferGetHeightOfPlane(pixel, 0)
        var hash: UInt64 = 14695981039346656037
        for i in 0..<count { hash = (hash ^ UInt64(bytes[i])) &* 1099511628211 }
        return hash
    }
    static func main() throws {
        let full = try fixture(width: 1920, height: 1440)
        let original = try checksum(full)
        let fullScore = CapturedQualityBridge.measure(full)
        try check(fullScore != nil && fullScore!.laplacianVariance > 24, "Native 1920x1440 full-range sampling should see sharp texture")
        let after = try checksum(full)
        try check(after == original, "Quality sampling must not modify original raster bytes")
        let video = try fixture(width: 1920, height: 1440, videoRange: true)
        let videoScore = CapturedQualityBridge.measure(video)
        try check(videoScore != nil, "Video-range luma sampling failed")
        try check(abs(fullScore!.laplacianVariance - videoScore!.laplacianVariance) / fullScore!.laplacianVariance < 0.03,
                  "Video-range normalization must keep sharpness units comparable")
        let padded = try fixture(width: 1916, height: 1440)
        try check(CVPixelBufferGetBytesPerRowOfPlane(padded, 0) > 1916, "Padded-stride fixture must actually contain row padding")
        try check(CapturedQualityBridge.measure(padded)?.laplacianVariance ?? 0 > 24, "Sampler must respect padded CoreVideo row stride")
        let plain = try fixture(width: 1920, height: 1440, flat: true)
        let plainScore = CapturedQualityBridge.measure(plain)
        try check(plainScore?.lumaVariance == 0 && plainScore?.laplacianVariance == 0, "Native flat wall should remain low texture")
        var unsupported: CVPixelBuffer?
        try check(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &unsupported) == kCVReturnSuccess,
                  "Unsupported-format control buffer allocation failed")
        try check(CapturedQualityBridge.measure(unsupported!) == nil, "Unexpected packed format cannot be interpreted as a luma plane")
        let tooSmall = try fixture(width: 2, height: 2)
        try check(CapturedQualityBridge.measure(tooSmall) == nil, "Degenerate camera dimensions must reject sampling")
        print("PASS QualityRasterChecks \(count) assertions")
    }
}
