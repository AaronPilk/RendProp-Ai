import Foundation
import CoreVideo
import ImageIO

// These tests exercise the production metadata preflight, NEVER decode an
// excessive-dimension JPEG. Header edits and sparse padding stay small on disk.
@main
enum JPEGResourceChecks {
    static let cases = ["valid", "encoded-limit-boundary", "oversized-encoded", "excessive-axis", "excessive-pixels",
        "metadata-excessive-axis", "metadata-excessive-pixels", "metadata-dimension-mismatch"]
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let selected = arguments.isEmpty ? cases : arguments
        guard selected.allSatisfy(cases.contains) else { fputs("FAIL: unknown JPEG resource case\n", stderr); exit(1) }
        var failures = 0
        for name in selected {
            do {
                let url = try fixture()
                var resolution = ImageResolution(width: 80, height: 48)
                switch name {
                case "oversized-encoded", "encoded-limit-boundary":
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.truncate(atOffset: 64 * 1024 * 1024 + (name == "oversized-encoded" ? 1 : 0))
                case "excessive-axis", "excessive-pixels", "metadata-excessive-axis", "metadata-excessive-pixels", "metadata-dimension-mismatch":
                    let headerSize = name.hasSuffix("axis") ? ImageResolution(width: 8193, height: 1)
                        : name == "metadata-dimension-mismatch" ? ImageResolution(width: 81, height: 48) : ImageResolution(width: 8192, height: 8192)
                    try rewriteDimensions(at: url, resolution: headerSize)
                    if !name.hasPrefix("metadata-") { resolution = headerSize }
                default: break
                }
                let result = Result { try NativeRasterWriter.validatedJPEGSource(at: url, resolution: resolution) }
                let shouldAccept = name == "valid" || name == "encoded-limit-boundary"
                let passed: Bool
                switch result {
                case .success: passed = shouldAccept
                case .failure(let error):
                    // A setup/type/mismatch rejection cannot masquerade as a
                    // passing resource cap test: assert the actual policy reason.
                    let expected = name == "metadata-dimension-mismatch" ? "disagree with ARCamera" : "safety limit"
                    passed = !shouldAccept && error.localizedDescription.contains(expected)
                }
                guard passed else {
                    failures += 1
                    fputs("FAIL: \(name) preflight returned \(result)\n", stderr)
                    continue
                }
                print("PASS: JPEG \(name)")
            } catch {
                failures += 1
                fputs("FAIL: JPEG fixture/setup for \(name): \(error)\n", stderr)
            }
        }
        print("JPEG resource checks: \(selected.count - failures) passed, \(failures) failed, 0 skipped")
        exit(failures == 0 ? 0 : 1)
    }

    static func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spatial-jpeg-resource-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("native.jpg")
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 80, 48, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { throw CaptureError.invalid("Could not allocate small JPEG fixture.") }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        memset(CVPixelBufferGetBaseAddress(pixelBuffer)!, 128, CVPixelBufferGetBytesPerRow(pixelBuffer) * 48)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        try NativeRasterWriter().write(pixelBuffer, resolution: ImageResolution(width: 80, height: 48), to: url)
        return url
    }

    static func rewriteDimensions(at url: URL, resolution: ImageResolution) throws {
        var bytes = try Data(contentsOf: url)
        guard bytes.starts(with: [0xff, 0xd8]) else { throw CaptureError.invalid("Fixture is not JPEG.") }
        var cursor = 2
        while cursor + 4 < bytes.count {
            guard bytes[cursor] == 0xff else { break }
            let marker = bytes[cursor + 1]
            let length = Int(bytes[cursor + 2]) * 256 + Int(bytes[cursor + 3])
            guard length >= 2, cursor + 2 + length <= bytes.count else { break }
            if marker == 0xc0 || marker == 0xc2 {
                guard length >= 8 else { break }
                bytes[cursor + 5] = UInt8(resolution.height >> 8)
                bytes[cursor + 6] = UInt8(resolution.height & 255)
                bytes[cursor + 7] = UInt8(resolution.width >> 8)
                bytes[cursor + 8] = UInt8(resolution.width & 255)
                try bytes.write(to: url)
                // Check metadata only, with decoded caching explicitly disabled.
                let options = [kCGImageSourceShouldCache: false] as CFDictionary
                guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
                      properties[kCGImagePropertyPixelWidth] as? Int == resolution.width,
                      properties[kCGImagePropertyPixelHeight] as? Int == resolution.height else {
                    throw CaptureError.invalid("ImageIO did not recognize edited synthetic dimensions.")
                }
                return
            }
            if marker == 0xda { break }
            cursor += 2 + length
        }
        throw CaptureError.invalid("Fixture has no supported start-of-frame marker.")
    }
}
