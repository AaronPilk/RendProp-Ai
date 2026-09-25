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
var recoveryControls = CaptureControls()
check(recoveryControls.beginSavedExport() && !recoveryControls.startEnabled && !recoveryControls.exportEnabled, "saved selection enters validation without claiming completion")
recoveryControls.endPresentation()
check(!recoveryControls.beginSavedExport(), "closed presentation cannot recover/export")
var activeRecoveryControls = CaptureControls()
activeRecoveryControls.beginStart()
check(!activeRecoveryControls.beginSavedExport(), "saved export cannot race preparation")
activeRecoveryControls.captureStarted()
check(!activeRecoveryControls.beginSavedExport(), "saved export cannot race recording")

// A dismissed UI instance must never restart after delayed permission, disk, or
// export callbacks. Test every lifecycle phase, including dismissal while saving.
for phase in 0...6 {
    var closing = CaptureControls()
    if phase >= 1 { closing.beginStart() }
    if phase >= 2 { closing.captureStarted() }
    if phase == 3 { closing.beginStop() }
    if phase >= 4 { closing.captureFinished(exportable: phase != 5) }
    if phase == 6 { closing.beginExport() }
    check(closing.endPresentation() == (phase == 1 || phase == 2), "dismissal interrupts exactly preparing/recording phase \(phase)")
    check(closing.isClosed && !closing.startEnabled && !closing.stopEnabled && !closing.exportEnabled, "dismissal disables every action in phase \(phase)")
    closing.startFailed()
    closing.captureFinished(exportable: true)
    closing.exportChecked(valid: true)
    check(!closing.captureStarted() && !closing.beginStart() && !closing.beginStop() && !closing.beginExport() && closing.isClosed, "late callbacks cannot revive phase \(phase)")
    check(!closing.endPresentation(), "repeated dismissal does not request another interruption in phase \(phase)")
}

var transform = matrix_identity_float4x4
transform.columns.3 = SIMD4<Float>(1.25, -2.5, 3.75, 1)
let rows = CaptureGeometry.rows(transform)
check(rows[0][3] == 1.25 && rows[1][3] == -2.5 && rows[2][3] == 3.75, "c2w translation must be last column, never transposed")
let k = simd_float3x3(columns: (SIMD3(1000, 0, 0), SIMD3(0, 1100, 0), SIMD3(950, 700, 1)))
check(CaptureGeometry.rows(k) == [[1000, 0, 950], [0, 1100, 700], [0, 0, 1]], "K row serialization")
// Pose-based motion-blur estimator: formula values and verdict boundaries.
// fx 1332 px at 18.8 deg/s and 1/60 s is 1332 * radians(18.8 / 60) = 7.284 px,
// a synthetic formula example, not a validated quality threshold.
func yawTransform(_ degrees: Double, x: Float = 0) -> simd_float4x4 {
    let r = Float(degrees * .pi / 180)
    var m = matrix_identity_float4x4
    m.columns.0 = SIMD4<Float>(cos(r), 0, -sin(r), 0)
    m.columns.2 = SIMD4<Float>(sin(r), 0, cos(r), 0)
    m.columns.3 = SIMD4<Float>(x, 0, 0, 1)
    return m
}
let exampleSmear = CaptureBlurEstimator.predictedSmearPixels(angularSpeedDegreesPerSecond: 18.8, exposureDuration: 1.0 / 60, fx: 1332)!
check(abs(exampleSmear - 1332 * (18.8 / 60) * .pi / 180) < 1e-9 && abs(exampleSmear - 7.284) < 0.001, "smear formula fx*radians(omega*t) gives 7.284 px")
check(abs(CaptureBlurEstimator.predictedSmearPixels(angularSpeedDegreesPerSecond: 42.5, exposureDuration: 1.0 / 60, fx: 1332)! - 16.467) < 0.001, "p90 pan of 42.5 deg/s smears 16.5 px at 1/60 s")
check(abs(CaptureBlurEstimator.predictedSmearPixels(angularSpeedDegreesPerSecond: 18.8, exposureDuration: 1.0 / 120, fx: 1332)! - 3.642) < 0.001, "halving exposure halves the smear")
check(CaptureBlurEstimator.predictedSmearPixels(angularSpeedDegreesPerSecond: 0, exposureDuration: 1.0 / 60, fx: 1332) == 0, "a still camera has zero smear")
check(CaptureBlurEstimator.predictedSmearPixels(angularSpeedDegreesPerSecond: -1, exposureDuration: 0.01, fx: 1332) == nil, "negative angular speed rejected")
check(CaptureBlurEstimator.predictedSmearPixels(angularSpeedDegreesPerSecond: 1, exposureDuration: 0.01, fx: 0) == nil, "zero focal length rejected")
check(CaptureBlurEstimator.predictedSmearPixels(angularSpeedDegreesPerSecond: .nan, exposureDuration: 0.01, fx: 1332) == nil, "non-finite angular speed rejected")
check(CaptureBlurEstimator.predictedSmearPixels(angularSpeedDegreesPerSecond: 1, exposureDuration: .infinity, fx: 1332) == nil, "non-finite exposure rejected")
check(abs(CaptureBlurEstimator.rotationAngleDegrees(yawTransform(0), yawTransform(0))!) < 1e-6, "identical poses have zero angle")
check(abs(CaptureBlurEstimator.rotationAngleDegrees(yawTransform(0), yawTransform(180))! - 180) < 1e-3, "half turn measures 180 degrees")
check(abs(CaptureBlurEstimator.angularSpeedDegreesPerSecond(previous: yawTransform(0), current: yawTransform(4.5), previousTimestamp: 10, currentTimestamp: 10.05)! - 90) < 1e-3, "4.5 degree yaw over 50 ms is 90 deg/s")
let framePan = CaptureBlurEstimator.angularSpeedDegreesPerSecond(previous: yawTransform(0, x: 1), current: yawTransform(18.8 / 60, x: 1.5), previousTimestamp: 100, currentTimestamp: 100 + 1.0 / 60)!
check(abs(framePan - 18.8) < 0.05, "18.8 deg/s pan measured across one 1/60 s frame gap; translation ignored")
let liveEstimate = CaptureBlurEstimator.estimate(previous: yawTransform(0), current: yawTransform(18.8 / 60), previousTimestamp: 0, currentTimestamp: 1.0 / 60, exposureDuration: 1.0 / 60, fx: 1332)!
check(abs(liveEstimate.predictedSmearPixels - 7.284) < 0.02 && abs(liveEstimate.angularSpeedDegreesPerSecond - 18.8) < 0.05, "end-to-end estimate reproduces the room's median smear")
check(CaptureBlurEstimator.estimate(previous: yawTransform(0), current: yawTransform(1), previousTimestamp: 1, currentTimestamp: 1, exposureDuration: 0.01, fx: 1332) == nil, "zero frame gap rejected")
check(CaptureBlurEstimator.estimate(previous: yawTransform(0), current: yawTransform(1), previousTimestamp: 2, currentTimestamp: 1, exposureDuration: 0.01, fx: 1332) == nil, "backwards timestamps rejected")
var scaledTransform = yawTransform(0)
scaledTransform.columns.0 *= 2
check(CaptureBlurEstimator.rotationAngleDegrees(scaledTransform, yawTransform(0)) == nil, "non-rigid transform rejected")
var nonfiniteTransform = yawTransform(0)
nonfiniteTransform.columns.1.y = .nan
check(CaptureBlurEstimator.estimate(previous: nonfiniteTransform, current: yawTransform(1), previousTimestamp: 0, currentTimestamp: 1, exposureDuration: 0.01, fx: 1332) == nil, "non-finite transform rejected")
var reflectedMotion = matrix_identity_float4x4
reflectedMotion.columns.0.x = -1
check(CaptureBlurEstimator.rotationAngleDegrees(reflectedMotion, reflectedMotion) == nil,
      "a reflected previous pose cannot certify zero motion")
func blurVerdict(_ pixels: Double, exposure: Double) -> CaptureBlurVerdict {
    CaptureBlurEstimator.verdict(for: CaptureBlurEstimate(angularSpeedDegreesPerSecond: 0, predictedSmearPixels: pixels), exposureDuration: exposure)
}
check(blurVerdict(2.999, exposure: 1.0 / 60) == .ok && !blurVerdict(2.999, exposure: 1.0 / 60).skipsFrame, "under 3 px is fine even at 1/60 s")
check(blurVerdict(3, exposure: 1.0 / 120) == .tooFast(skip: false), "3 px at a short exposure warns: slow down")
check(blurVerdict(3, exposure: 1.0 / 60) == .tooDark(skip: false), "3 px at 1/60 s warns: more light")
check(blurVerdict(3.999, exposure: 1.0 / 30) == .tooDark(skip: false) && !blurVerdict(3.999, exposure: 1.0 / 30).skipsFrame, "just under 4 px still records")
check(blurVerdict(4, exposure: 1.0 / 120) == .tooFast(skip: true) && blurVerdict(4, exposure: 1.0 / 120).skipsFrame, "4 px at a short exposure skips the frame")
check(blurVerdict(4, exposure: 1.0 / 60) == .tooDark(skip: true) && blurVerdict(4, exposure: 1.0 / 60).skipsFrame, "4 px at 1/60 s skips and asks for light")
check(blurVerdict(7.284, exposure: Double(Float(1.0 / 60))) == .tooDark(skip: true), "a 7.284 px prediction at a Float32 1/60 s exposure is skipped for light")
check(CaptureBlurVerdict.ok.hint == nil && CaptureBlurVerdict.tooFast(skip: false).hint!.hasPrefix("Slow down")
      && CaptureBlurVerdict.tooDark(skip: true).hint!.hasPrefix("More light"), "hints name the corrective action")
check(CaptureBlurEstimator.manifestThresholds == ["warn_smear_px": 3, "skip_smear_px": 4, "long_exposure_seconds": 1.0 / 60, "maximum_sample_interval_seconds": 0.1], "manifest records the live thresholds")

// Review regression: a rejected boundary frame must leave the next sharp
// candidate eligible, using the same cadence and verdict types as the recorder.
var replayCadence = FrameCadence()
var replayAccepted = 0
for tick in 0..<600 {
    let timestamp = Double(tick) / 60
    guard replayCadence.isEligible(timestamp: timestamp, normalTracking: true) else { continue }
    let verdict = blurVerdict(tick % 30 == 0 ? 9 : 1, exposure: 1.0 / 120)
    if !verdict.skipsFrame && replayCadence.accept(timestamp: timestamp, normalTracking: true) { replayAccepted += 1 }
}
check(replayAccepted >= 19, "blurred cadence boundaries do not discard sharp alternatives")
check(CaptureBlurEstimator.verdict(for: nil, exposureDuration: 0.01) == .unavailable,
      "missing motion is unavailable, not accepted as sharp")
for invalidExposure in [0.0, -0.01, 1.0, Double.nan] {
    check(CaptureBlurEstimator.predictedSmearPixels(angularSpeedDegreesPerSecond: 0, exposureDuration: invalidExposure, fx: 1332) == nil,
          "invalid exposure cannot produce a zero-smear pass")
    check(blurVerdict(0, exposure: invalidExposure).skipsFrame, "unknown exposure never commits admission")
}
check(CaptureBlurEstimator.estimate(previous: yawTransform(0), current: yawTransform(0), previousTimestamp: 0,
      currentTimestamp: 0.5, exposureDuration: 0.01, fx: 1332) == nil, "long sample gaps cannot certify low motion")

let sid = UUID().uuidString
let frame = FrameRecord(session_id: sid, image: "images/000001.jpg", camera_to_world: rows,
    intrinsics: CaptureGeometry.rows(k), image_resolution: ImageResolution(width: 1920, height: 1440),
    timestamp: 123.5, tracking_state: TrackingRecord(state: "normal", reason: nil),
    raw_feature_points: [FeaturePoint(id: String(UInt64.max), position: [1, 2, -3])],
    exposure_duration_seconds: 0.01, exposure_offset_ev: 0, world_mapping_status: "mapped")
// Resolution-policy tests allocate no rasters. Include preferred video sizes,
// 4K/12 MP fallbacks, the exact cap, and malformed Ints that could overflow a
// naive width*height calculation. No ARKit device-format availability is implied.
for size in [ImageResolution(width: 1920, height: 1440), ImageResolution(width: 1920, height: 1080),
             ImageResolution(width: 3840, height: 2160), ImageResolution(width: 4032, height: 3024),
             ImageResolution(width: 4096, height: 4096), ImageResolution(width: 8192, height: 2048)] {
    check((try? CaptureRasterLimits.validate(size)) != nil, "raster policy accepts native format/boundary \(size)")
}
for size in [ImageResolution(width: 0, height: 48), ImageResolution(width: -1, height: 48),
             ImageResolution(width: 8193, height: 1), ImageResolution(width: 8192, height: 2049),
             ImageResolution(width: Int.max, height: Int.max), ImageResolution(width: Int.min, height: -1)] {
    check((try? CaptureRasterLimits.validate(size)) == nil, "raster policy rejects malformed/excessive size \(size) without overflow")
}
do {
    try frame.validate(expectedSession: sid)
    let encoded = try JSONEncoder().encode(frame)
    let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    let points = json["raw_feature_points"] as! [[String: Any]]
    check(points[0]["id"] as? String == "18446744073709551615", "UInt64 IDs retain all digits as strings")
    check(json["camera_to_world"] != nil && json["cameraToWorld"] == nil, "exact snake_case schema")
    let decoded = try JSONDecoder().decode(FrameRecord.self, from: encoded)
    check(decoded.camera_to_world == rows, "pose JSON round trip")
    check(json["predicted_smear_px"] == nil && json["angular_speed_deg_s"] == nil, "frames without motion telemetry omit the additive keys")
    for exposure in [0.0, -0.01, 1.0] {
        var invalidJSON = json
        invalidJSON["exposure_duration_seconds"] = exposure
        let invalid = try JSONDecoder().decode(FrameRecord.self, from: JSONSerialization.data(withJSONObject: invalidJSON))
        check((try? invalid.validate(expectedSession: sid)) == nil, "invalid exposure cannot be persisted as a usable frame")
    }
    var telemetry = decoded
    telemetry.angular_speed_deg_s = 18.8
    telemetry.predicted_smear_px = 7.284
    try telemetry.validate(expectedSession: sid)
    let telemetryJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(telemetry)) as! [String: Any]
    check(telemetryJSON["predicted_smear_px"] as? Double == 7.284 && telemetryJSON["angular_speed_deg_s"] as? Double == 18.8, "additive motion-blur telemetry keys are written beside exposure")
    let telemetryRoundTrip = try JSONDecoder().decode(FrameRecord.self, from: JSONEncoder().encode(telemetry))
    check(telemetryRoundTrip.predicted_smear_px == 7.284 && telemetryRoundTrip.angular_speed_deg_s == 18.8, "telemetry round trip")
    telemetry.predicted_smear_px = -1
    check((try? telemetry.validate(expectedSession: sid)) == nil, "negative smear telemetry rejected")
    telemetry.predicted_smear_px = .nan
    check((try? telemetry.validate(expectedSession: sid)) == nil, "non-finite smear telemetry rejected")
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
    // Positive bound check for the real recorder's maximum point count, using
    // UInt64-width IDs and extreme finite Float coordinates (not room evidence).
    let extreme = Double(Float.greatestFiniteMagnitude)
    let maximumCloud = (0..<50_000).map {
        FeaturePoint(id: String(UInt64.max - UInt64($0)), position: [extreme, -extreme, extreme])
    }
    let maximumRecord = FrameRecord(session_id: sid, image: frame.image,
        camera_to_world: frame.camera_to_world, intrinsics: frame.intrinsics, image_resolution: frame.image_resolution,
        timestamp: frame.timestamp, tracking_state: frame.tracking_state, raw_feature_points: maximumCloud,
        exposure_duration_seconds: frame.exposure_duration_seconds, exposure_offset_ev: frame.exposure_offset_ev,
        world_mapping_status: frame.world_mapping_status)
    let maximumEncoded = try JSONEncoder().encode(maximumRecord)
    check(maximumEncoded.count < NativeRasterWriter.maximumSidecarBytes, "bounded read admits maximum 50,000-point recorder output")
    let maximumDecoded = try JSONDecoder().decode(FrameRecord.self, from: maximumEncoded)
    try maximumDecoded.validate(expectedSession: sid)
    check(maximumDecoded.raw_feature_points.count == 50_000, "maximum point cloud survives exact JSON round trip")
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
    check((try? NativeRasterWriter.boundedJSONData(at: corruptURL, maximumBytes: Int.max)) == nil, "reject overflowing read limit without a trap")
    check((try? NativeRasterWriter.boundedJSONData(at: corruptURL, maximumBytes: -1)) == nil, "reject negative read limit without a trap")
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
    // Persistent recovery tests use only explicitly synthetic temporary data.
    let archive = CaptureArchive(root: temporaryRoot.appendingPathComponent("Captures"))
    let absent = try archive.page(offset: 0)
    check(absent.entries.isEmpty && !absent.hasMore, "missing capture storage is genuinely empty")
    let preparedArchive = try archive.prepareRoot(createIfMissing: true)
    check(preparedArchive, "prepare archive storage")
    let excluded = try URL(fileURLWithPath: archive.root.path).resourceValues(forKeys: [.isExcludedFromBackupKey])
    check(excluded.isExcludedFromBackup == true, "capture storage is persistently excluded from backups")
    check((try? archive.captureURL(id: "../outside")) == nil, "recovery rejects path traversal")
    let recoveredRoot = archive.root.appendingPathComponent(sid)
    try FileManager.default.copyItem(at: captureRoot, to: recoveredRoot)
    var attemptIDs: Set<String> = [sid]
    for i in 1...51 {
        let id = UUID().uuidString
        attemptIDs.insert(id)
        let attempt = archive.root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: attempt, withIntermediateDirectories: true)
        var incomplete = CaptureManifest(sessionID: id, deviceModel: "synthetic-recovery-test", operatingSystem: "test")
        incomplete.status = i == 1 ? "recording" : "interrupted"
        try encoder.encode(incomplete).write(to: attempt.appendingPathComponent("manifest.json"))
    }
    let firstPage = try archive.page(offset: 0)
    let secondPage = try archive.page(offset: CaptureArchive.pageSize)
    check(firstPage.entries.count == 50 && firstPage.hasMore, "recovery page memory is bounded and reveals more attempts")
    check(secondPage.entries.count == 2 && !secondPage.hasMore, "older attempts remain reachable on another page")
    check(Set((firstPage.entries + secondPage.entries).map(\.id)) == attemptIDs, "pagination does not silently hide or duplicate attempts")
    check(firstPage.entries.allSatisfy { $0.createdAt != nil && $0.frameCount != nil }, "saved summaries contain creation time and frame counts")
    let reopened = CaptureArchive(root: archive.root)
    let recoveredExport = try reopened.validateForExport(id: sid)
    check(recoveredExport.standardizedFileURL.path == recoveredRoot.standardizedFileURL.path, "fresh archive instance recovers completed synthetic data after reopening")
    var interruptedRecovery = fixtureManifest
    interruptedRecovery.status = "interrupted"
    let recoveryManifestURL = recoveredRoot.appendingPathComponent("manifest.json")
    try encoder.encode(interruptedRecovery).write(to: recoveryManifestURL)
    check((try? reopened.validateForExport(id: sid)) == nil, "recovered export re-reads status and refuses interrupted attempts")
    try encoder.encode(fixtureManifest).write(to: recoveryManifestURL)
    let invalidID = UUID().uuidString
    let invalidAttempt = archive.root.appendingPathComponent(invalidID)
    try FileManager.default.createDirectory(at: invalidAttempt, withIntermediateDirectories: true)
    try Data("not JSON".utf8).write(to: invalidAttempt.appendingPathComponent("manifest.json"))
    let visibleAttempts = try archive.page(offset: 0).entries + archive.page(offset: CaptureArchive.pageSize).entries
    check(visibleAttempts.contains { $0.id == invalidID && $0.status == "unreadable" && $0.issue != nil }, "unreadable attempts remain visible instead of becoming empty/successful")
    try Data(repeating: 32, count: CaptureArchive.maximumManifestBytes + 1).write(to: invalidAttempt.appendingPathComponent("manifest.json"))
    check((try? archive.manifest(id: invalidID)) == nil, "oversized manifest fails within the bounded read policy")
    let wrongIdentity = CaptureManifest(sessionID: UUID().uuidString, deviceModel: "test", operatingSystem: "test")
    try encoder.encode(wrongIdentity).write(to: invalidAttempt.appendingPathComponent("manifest.json"))
    check((try? archive.manifest(id: invalidID)) == nil, "recovery refuses directory/manifest identity mismatch")
    let badArchiveURL = temporaryRoot.appendingPathComponent("archive-is-a-file")
    try Data("not a directory".utf8).write(to: badArchiveURL)
    check((try? CaptureArchive(root: badArchiveURL).page(offset: 0)) == nil, "storage/enumeration failures are not reported as no saved captures")
    let linkedArchiveURL = temporaryRoot.appendingPathComponent("linked-archive")
    try FileManager.default.createSymbolicLink(at: linkedArchiveURL, withDestinationURL: archive.root)
    check((try? CaptureArchive(root: linkedArchiveURL).page(offset: 0)) == nil, "archive root cannot redirect outside owned storage")
    let linkedID = UUID().uuidString
    try FileManager.default.createSymbolicLink(at: archive.root.appendingPathComponent(linkedID), withDestinationURL: captureRoot)
    check((try? archive.captureURL(id: linkedID)) == nil, "capture selection rejects a symlink to another directory")
    try Data("corrupted after initial export validation".utf8).write(to: recoveredRoot.appendingPathComponent("images/000020.jpg"))
    check((try? reopened.validateForExport(id: sid)) == nil, "recovered exports revalidate the final JPEG on every attempt")
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
