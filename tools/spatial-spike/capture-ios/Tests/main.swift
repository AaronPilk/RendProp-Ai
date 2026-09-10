import Foundation
import simd
import CoreVideo
import CoreImage
import ImageIO

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    checks += 1
}

// Exercise the harness's own failure exit before trusting its positive run.
if CommandLine.arguments.contains("--force-failure") { check(false, "intentional gate self-test") }

// Pure control-policy regression checks. These exercise button interlocks only;
// no AR frame, capture directory, or successful room capture is manufactured.
var controls = CaptureControls()
check(controls.startEnabled && !controls.stopEnabled && !controls.exportEnabled, "idle controls prevent stop/export")
check(!controls.beginStop() && !controls.beginExport(), "idle actions cannot claim work")
check(controls.beginStart() && !controls.beginStart(), "only one permission/start request admitted")
check(!controls.stopEnabled && !controls.exportEnabled, "permission phase is not a recording")
controls.startFailed()
check(controls.startEnabled && !controls.captureStarted(), "denied permission restores start without a late recording")
check(controls.beginStart() && controls.captureStarted(), "recording follows a prepared start")
check(controls.stopEnabled && !controls.startEnabled && !controls.exportEnabled, "stop stays available during a capture")
check(controls.beginStop() && !controls.beginStop(), "stop is admitted once")
check(!controls.beginStart() && !controls.beginExport(), "saving cannot race a new start/export")
controls.captureFinished(exportable: false)
check(controls.startEnabled && !controls.exportEnabled, "interrupted/failed data cannot offer export")
check(controls.beginStart() && controls.captureStarted(), "a new capture can start after preserved failure")
// This bool models an existing validator's verdict in a policy unit test only.
// The application never exposes an API/launch flag to inject that verdict.
controls.captureFinished(exportable: true)
check(controls.beginExport(), "export can begin only after a validating verdict")
check(!controls.beginStart() && !controls.stopEnabled && !controls.exportEnabled, "file validation blocks a racing capture")
controls.exportChecked(valid: false)
check(controls.startEnabled && !controls.exportEnabled, "failed revalidation revokes export")

var transform = matrix_identity_float4x4
transform.columns.3 = SIMD4<Float>(1.25, -2.5, 3.75, 1)
let rows = CaptureGeometry.rows(transform)
check(rows[0][3] == 1.25 && rows[1][3] == -2.5 && rows[2][3] == 3.75, "c2w translation must be last column, never transposed")
let k = simd_float3x3(columns: (SIMD3(1000, 0, 0), SIMD3(0, 1100, 0), SIMD3(950, 700, 1)))
check(CaptureGeometry.rows(k) == [[1000, 0, 950], [0, 1100, 700], [0, 0, 1]], "K row serialization")
let sid = UUID().uuidString
let frame = FrameRecord(session_id: sid, image: "images/000001.jpg", camera_to_world: rows,
    intrinsics: CaptureGeometry.rows(k), image_resolution: ImageResolution(width: 1920, height: 1440),
    timestamp: 123.5, tracking_state: TrackingRecord(state: "normal", reason: nil),
    raw_feature_points: [FeaturePoint(id: String(UInt64.max), position: [1, 2, -3])],
    exposure_duration_seconds: 0.01, exposure_offset_ev: 0, world_mapping_status: "mapped")
do {
    try frame.validate(expectedSession: sid)
    let encoded = try JSONEncoder().encode(frame)
    let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    let points = json["raw_feature_points"] as! [[String: Any]]
    check(points[0]["id"] as? String == "18446744073709551615", "UInt64 IDs retain all digits as strings")
    check(json["camera_to_world"] != nil && json["cameraToWorld"] == nil, "exact snake_case schema")
    let decoded = try JSONDecoder().decode(FrameRecord.self, from: encoded)
    check(decoded.camera_to_world == rows, "pose JSON round trip")
    var malformed = decoded
    malformed.camera_to_world[3][0] = 1
    check((try? malformed.validate(expectedSession: sid)) == nil, "reject non-homogeneous transform")
    malformed = decoded
    malformed.camera_to_world[0][0] = -1
    check((try? malformed.validate(expectedSession: sid)) == nil, "reject reflected rotation")
    malformed = decoded
    malformed.intrinsics[0][0] = .nan
    check((try? malformed.validate(expectedSession: sid)) == nil, "reject non-finite intrinsics")
    check((try? decoded.validate(expectedSession: "other-epoch")) == nil, "reject mixed capture epochs")
    malformed = decoded
    malformed.tracking_state = TrackingRecord(state: "limited", reason: "relocalizing")
    check((try? malformed.validate(expectedSession: sid)) == nil, "reject limited tracking")
    malformed = decoded
    malformed.image = "../outside.jpg"
    check((try? malformed.validate(expectedSession: sid)) == nil, "reject path traversal")
    var policy = FrameCadence()
    check(policy.accept(timestamp: 1, normalTracking: true), "first normal frame selected")
    check(!policy.accept(timestamp: 1.1, normalTracking: true), "cadence refuses duplicate near frame")
    check(!policy.accept(timestamp: 1.6, normalTracking: false), "limited frame skipped")
    check(policy.accept(timestamp: 1.6, normalTracking: true), "limited frame does not consume cadence")
    var manifest = CaptureManifest(sessionID: sid, deviceModel: "test", operatingSystem: "test")
    check(!manifest.isExportable, "recording session cannot export")
    manifest.status = "complete"
    check(!manifest.isExportable, "empty session cannot export")
    manifest.frames = (1...20).map { String(format: "frames/%06d.json", $0) }
    manifest.feature_point_observations = 1
    check(manifest.isExportable, "complete data can enter file validation")
    manifest.status = "interrupted"
    check(!manifest.isExportable, "interrupted capture preserved but not exportable")
    manifest.status = "failed"
    check(!manifest.isExportable, "failed capture not exportable")
    manifest.status = "limit_reached"
    check(!manifest.isExportable, "automatic truncation not a successful capture")
    // Synthetic colored quadrants exercise raster orientation, not a room reconstruction.
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("spatial-raster-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    var pixelBuffer: CVPixelBuffer?
    let width = 80, height = 48
    check(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pixelBuffer) == kCVReturnSuccess, "create native test buffer")
    let buffer = pixelBuffer!
    CVPixelBufferLockBaseAddress(buffer, [])
    let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height { for x in 0..<width {
        let offset = y * stride + x * 4
        bytes[offset] = y >= height / 2 ? 255 : 0
        bytes[offset + 1] = x >= width / 2 ? 255 : 0
        bytes[offset + 2] = y < height / 2 && x < width / 2 ? 255 : 0
        bytes[offset + 3] = 255
    } }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let jpegURL = temporaryRoot.appendingPathComponent("native.jpg")
    let nativeSize = ImageResolution(width: width, height: height)
    try NativeRasterWriter().write(buffer, resolution: nativeSize, to: jpegURL)
    try NativeRasterWriter.validateJPEG(at: jpegURL, resolution: nativeSize)
    check((try? NativeRasterWriter.validateJPEG(at: jpegURL, resolution: ImageResolution(width: height, height: width))) == nil, "reject dimensions swapped by portrait rotation")
    let source = CGImageSourceCreateWithURL(jpegURL as CFURL, nil)!
    let raster = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
    context.draw(raster, in: CGRect(x: 0, y: 0, width: width, height: height))
    func pixel(_ x: Int, _ y: Int, _ channel: Int) -> Int { Int(rgba[(y * width + x) * 4 + channel]) }
    check(pixel(10, 10, 0) > 200 && pixel(10, 10, 2) < 50, "JPEG top-left remains red")
    check(pixel(70, 10, 1) > 200 && pixel(70, 10, 2) < 50, "JPEG top-right remains green")
    check(pixel(10, 38, 2) > 200 && pixel(10, 38, 0) < 50, "JPEG bottom-left remains blue")
    check(pixel(70, 38, 1) > 200 && pixel(70, 38, 2) > 200, "JPEG bottom-right remains cyan")
    // ARKit commonly supplies bi-planar YCbCr, so verify that conversion path too.
    var yuvBuffer: CVPixelBuffer?
    check(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &yuvBuffer) == kCVReturnSuccess, "create native YCbCr test buffer")
    let yuv = yuvBuffer!
    CVPixelBufferLockBaseAddress(yuv, [])
    let luma = CVPixelBufferGetBaseAddressOfPlane(yuv, 0)!.assumingMemoryBound(to: UInt8.self)
    let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(yuv, 0)
    for y in 0..<height { for x in 0..<width {
        luma[y * lumaStride + x] = UInt8(40 + (x >= width / 2 ? 50 : 0) + (y >= height / 2 ? 100 : 0))
    } }
    memset(CVPixelBufferGetBaseAddressOfPlane(yuv, 1)!, 128, CVPixelBufferGetBytesPerRowOfPlane(yuv, 1) * CVPixelBufferGetHeightOfPlane(yuv, 1))
    CVPixelBufferUnlockBaseAddress(yuv, [])
    let yuvURL = temporaryRoot.appendingPathComponent("native-ycbcr.jpg")
    try NativeRasterWriter().write(yuv, resolution: nativeSize, to: yuvURL)
    let yuvSource = CGImageSourceCreateWithURL(yuvURL as CFURL, nil)!
    let yuvRaster = CGImageSourceCreateImageAtIndex(yuvSource, 0, nil)!
    context.draw(yuvRaster, in: CGRect(x: 0, y: 0, width: width, height: height))
    check(pixel(10, 10, 0) + 20 < pixel(70, 10, 0), "YCbCr raster preserves left-right order")
    check(pixel(70, 10, 0) + 20 < pixel(10, 38, 0), "YCbCr raster preserves top-bottom order")
    check(pixel(10, 38, 0) + 20 < pixel(70, 38, 0), "YCbCr bottom-right remains brightest")
    let corruptURL = temporaryRoot.appendingPathComponent("corrupt.jpg")
    try Data("not a JPEG".utf8).write(to: corruptURL)
    check((try? NativeRasterWriter.validateJPEG(at: corruptURL, resolution: nativeSize)) == nil, "reject corrupt JPEG")
    // End-to-end local file validator; this is explicitly a synthetic fixture,
    // not captured data or evidence for the one-room acceptance gate.
    let captureRoot = temporaryRoot.appendingPathComponent("synthetic-validation-fixture")
    try FileManager.default.createDirectory(at: captureRoot.appendingPathComponent("images"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: captureRoot.appendingPathComponent("frames"), withIntermediateDirectories: true)
    var fixtureManifest = CaptureManifest(sessionID: sid, deviceModel: "synthetic-test", operatingSystem: "synthetic-test")
    fixtureManifest.status = "complete"
    let encoder = JSONEncoder()
    for i in 1...20 {
        let imagePath = String(format: "images/%06d.jpg", i)
        let sidecarPath = String(format: "frames/%06d.json", i)
        let fixtureFrame = FrameRecord(session_id: sid, image: imagePath, camera_to_world: rows,
            intrinsics: [[100, 0, 40], [0, 100, 24], [0, 0, 1]], image_resolution: nativeSize,
            timestamp: Double(i), tracking_state: TrackingRecord(state: "normal", reason: nil),
            raw_feature_points: [FeaturePoint(id: String(i), position: [0, 0, -2])],
            exposure_duration_seconds: 0.01, exposure_offset_ev: 0, world_mapping_status: "mapped")
        try FileManager.default.copyItem(at: jpegURL, to: captureRoot.appendingPathComponent(imagePath))
        try encoder.encode(fixtureFrame).write(to: captureRoot.appendingPathComponent(sidecarPath))
        fixtureManifest.frames.append(sidecarPath)
        fixtureManifest.feature_point_observations += 1
    }
    let manifestURL = captureRoot.appendingPathComponent("manifest.json")
    try encoder.encode(fixtureManifest).write(to: manifestURL)
    let validatedFixture = try NativeRasterWriter.validateCapture(at: captureRoot)
    check(validatedFixture.frames.count == 20, "validate all paired fixture files")
    fixtureManifest.status = "interrupted"
    try encoder.encode(fixtureManifest).write(to: manifestURL)
    check((try? NativeRasterWriter.validateCapture(at: captureRoot)) == nil, "refuse interrupted on-disk capture")
    fixtureManifest.status = "complete"
    fixtureManifest.matrix_layout = "column-major"
    try encoder.encode(fixtureManifest).write(to: manifestURL)
    check((try? NativeRasterWriter.validateCapture(at: captureRoot)) == nil, "refuse altered convention manifest")
    fixtureManifest.matrix_layout = "row-major"
    try encoder.encode(fixtureManifest).write(to: manifestURL)
    try Data("corrupt image after initial capture".utf8).write(to: captureRoot.appendingPathComponent("images/000020.jpg"))
    check((try? NativeRasterWriter.validateCapture(at: captureRoot)) == nil, "export revalidates even the final JPEG")
    print("PASS: \(checks) capture geometry, schema, cadence, completion, and native JPEG assertions")
} catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
