import Foundation
import CoreVideo
import CoreImage
import ImageIO

var checks = 0
func check(_ value: Bool, _ message: String) {
    guard value else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    checks += 1
}
func rejects(_ message: String, _ operation: () throws -> Void) {
    do { try operation(); check(false, message) } catch { check(true, message) }
}
if CommandLine.arguments.contains("--force-failure") { check(false, "intentional test harness failure") }

func pose(yaw: Double = 0, pitch: Double = 0, x: Double = 0) -> [[Double]] {
    let y = yaw * .pi / 180, p = pitch * .pi / 180
    return [[cos(y), -sin(y) * sin(p), -sin(y) * cos(p), x],
            [0, cos(p), -sin(p), 0],
            [sin(y), cos(y) * sin(p), cos(y) * cos(p), 0], [0, 0, 0, 1]]
}
func ready(_ policy: inout StationCapturePolicy, matrix: [[Double]], start: Double = 0) -> StationCapturePolicy.Guidance {
    var result = policy.evaluate(timestamp: start, cameraToWorld: matrix, normalTracking: true, motionBlurAcceptable: true, angularSpeedDegreesPerSecond: 0)
    for tick in 1...4 {
        result = policy.evaluate(timestamp: start + Double(tick) * 0.1, cameraToWorld: matrix, normalTracking: true, motionBlurAcceptable: true, angularSpeedDegreesPerSecond: 0)
    }
    return result
}

check(StationCaptureTarget.standard.count == 38, "the provisional plan has 38 distinct directions")
check(Set(StationCaptureTarget.standard.map(\.id)).count == 38, "target identifiers are unique")
check(StationCaptureTarget.standard.map(\.index) == Array(0..<38), "target order is contiguous")
check(StationCapturePolicy.canBeginFacingStraightAhead(forwardY: 0.49), "slight pitch can start the first target")
check(!StationCapturePolicy.canBeginFacingStraightAhead(forwardY: 0.5) && !StationCapturePolicy.canBeginFacingStraightAhead(forwardY: -0.5),
      "floor survey must hand off to the same straight-ahead gate used by the recorder")
check(!StationCapturePolicy.canBeginFacingStraightAhead(forwardY: .nan), "invalid pose cannot enable start")
for (index, phase, number, count) in [(0, "Walls", 1, 12), (11, "Walls", 12, 12),
                                    (12, "Upper walls", 1, 12), (23, "Upper walls", 12, 12),
                                    (24, "Lower walls", 1, 12), (35, "Lower walls", 12, 12),
                                    (36, "Ceiling", 1, 1), (37, "Floor", 1, 1)] {
    let target = StationCaptureTarget.standard[index]
    check(target.phaseTitle == phase && target.phasePhotoNumber == number && target.phasePhotoCount == count,
          "ring presentation resets its local count at each actual target boundary")
}
check(StationCaptureTarget.standard[0].instruction == "Turn slowly to the left", "legacy archive target text is preserved; presentation does not mutate v1 targets")
let aiming = StationCapturePolicy.aimDirection
check(aiming([-0.5, 0, -sqrt(0.75)], nil) == .left, "target to displayed left requests a left turn")
check(aiming([0.5, 0, -sqrt(0.75)], nil) == .right, "overshooting left reverses guidance to right")
check(aiming([0, 0.5, -sqrt(0.75)], nil) == .up, "target above requires tilt, not turning")
check(aiming([0, -0.5, -sqrt(0.75)], nil) == .down, "target below requires downward tilt")
check(aiming([0, 0, 1], nil) == .left, "directly behind has stable counterclockwise guidance")
check(aiming([0, 0, -1], nil) == .centered, "first centered target never incorrectly tells the operator to turn left")
check(aiming([0.02, 0, -1], 2) == .centered, "aim feedback uses the same angular acceptance tolerance")
check(aiming([Double.nan, 0, -1], nil) == nil && aiming([0, 0, 0], nil) == nil,
      "invalid vectors cannot produce a direction cue")
check(aiming([1e308, 0, -1], nil) == nil && aiming([0, 0, -1], Double.nan) == nil,
      "overflow or invalid admission error is not presented as valid guidance")
func captureAim(yaw: Double = 0, pitch: Double = 0, targetYaw: Double = 0, targetPitch: Double = 0) -> StationCapturePolicy.AimDirection? {
    StationCapturePolicy.captureAimDirection(cameraToWorld: pose(yaw: yaw, pitch: pitch),
                                            targetDirection: StationCapturePolicy.pose(pose(yaw: targetYaw, pitch: targetPitch))!.forward,
                                            angularErrorDegrees: nil)
}
check(captureAim(targetYaw: -30) == .left, "actual capture cue follows the next counterclockwise target")
check(captureAim(yaw: -40, targetYaw: -30) == .right, "actual capture cue reverses after overshooting left")
check(captureAim(yaw: 359, targetYaw: 9) == .right && captureAim(yaw: 1, targetYaw: 351) == .left,
      "gravity heading wraps across zero in the shorter direction")
check(captureAim(yaw: 359, targetYaw: -1) == .centered, "capture cue agrees with admission across heading wrap")
check(captureAim(pitch: 90, targetPitch: -90) == .down, "ceiling to floor must tilt down, never spin left indefinitely")
check(captureAim(pitch: -90, targetPitch: 90) == .up, "floor to ceiling must tilt up")
check(captureAim(pitch: 50, targetPitch: -50) == .down, "upper to lower ring behind camera requires downward pitch")
check(captureAim(pitch: -50, targetPitch: 50) == .up, "lower to upper ring behind camera requires upward pitch")
check(captureAim(yaw: 170, pitch: 89, targetYaw: -170, targetPitch: -50) == .down,
      "near-pole heading noise does not replace the needed tilt")
check(captureAim(yaw: 90, pitch: 50, targetYaw: -90, targetPitch: 50) == .left,
      "opposite same-ring heading uses a stable counterclockwise turn")
check(captureAim(pitch: 84, targetPitch: 90) == .up && captureAim(pitch: -84, targetPitch: -90) == .down,
      "pole targets always give the appropriate tilt")
check(StationCapturePolicy.captureAimDirection(cameraToWorld: [], targetDirection: [0, 0, -1], angularErrorDegrees: nil) == nil,
      "capture cue refuses an invalid camera matrix")
check(StationCapturePolicy.captureAimDirection(cameraToWorld: pose(), targetDirection: [0, 0, 0], angularErrorDegrees: nil) == nil &&
      StationCapturePolicy.captureAimDirection(cameraToWorld: pose(), targetDirection: [1e308, 0, -1], angularErrorDegrees: nil) == nil,
      "capture cue refuses zero and overflowing target vectors")
check(StationCapturePolicy.captureAimDirection(cameraToWorld: pose(), targetDirection: [0, 0, -1], angularErrorDegrees: .nan) == nil,
      "capture cue refuses invalid admission error")
check(StationCapturePolicy.returnInstruction(viewOffset: [-0.12, 0, 0]) == "Move the phone about 12 cm left", "pivot correction asks for translation separately from turn")
check(StationCapturePolicy.returnInstruction(viewOffset: [0, 0.15, 0]) == "Move the phone about 15 cm up", "pivot height drift asks to raise the phone")
check(StationCapturePolicy.returnInstruction(viewOffset: [0, 0, -0.2]) == "Move the phone about 20 cm away from you", "negative view z means forward translation")
check(StationCapturePolicy.returnInstruction(viewOffset: [0, 0, 0.2]) == "Move the phone about 20 cm toward you", "positive view z means backward translation")
check(StationCapturePolicy.returnInstruction(viewOffset: [0, 0, 0]) == nil && StationCapturePolicy.returnInstruction(viewOffset: [1e308, 0, 0]) == nil,
      "zero and overflowing displacement never create misleading centimetre cues")
for target in StationCaptureTarget.standard {
    let d = target.direction(referenceYawDegrees: 123)
    check(abs(d.reduce(0) { $0 + $1 * $1 } - 1) < 1e-12, "target \(target.id) is unit length including poles")
}
var policy = StationCapturePolicy(origin: [0, 0, 0], referenceYawDegrees: 0)
check(!policy.beginWrite(), "a target cannot be admitted without measured steady dwell")
check(ready(&policy, matrix: pose()).readyToCapture, "steady target is admitted after dwell")
check(policy.completedCount == 0, "admission alone never claims a durable photo")
check(policy.beginWrite() && !policy.beginWrite(), "one target write at a time")
check(policy.evaluate(timestamp: 0.5, cameraToWorld: pose(), normalTracking: true, motionBlurAcceptable: true, angularSpeedDegreesPerSecond: 0).mode == .saving,
      "pending write presents saving rather than requesting another turn")
check(!policy.finishWrite(targetID: "wrong", succeeded: true), "a stale or wrong target completion cannot advance progress")
check(policy.completedCount == 0 && policy.writeInFlight, "mismatched completion preserves pending write")
check(policy.finishWrite(targetID: "middle-0", succeeded: false), "failed write can clear pending target")
check(policy.completedCount == 0, "disk failure never increases completed count")
check(ready(&policy, matrix: pose(), start: 1).readyToCapture && policy.beginWrite(), "same target can be reconsidered only after a fresh dwell")
check(policy.finishWrite(targetID: "middle-0", succeeded: true) && policy.completedCount == 1, "durable matching completion advances exactly once")
check(!policy.finishWrite(targetID: "middle-0", succeeded: true) && policy.completedCount == 1, "duplicate callback cannot double count")

var wrapped = StationCapturePolicy(origin: [0, 0, 0], referenceYawDegrees: 359)
let wrapResult = ready(&wrapped, matrix: pose(yaw: -1))
check(wrapResult.readyToCapture && (wrapResult.angularErrorDegrees ?? 99) < 0.001, "359 and −1 degrees are the same target")
var drifted = StationCapturePolicy(origin: [0, 0, 0], referenceYawDegrees: 0)
check(!ready(&drifted, matrix: pose(x: 0.101)).readyToCapture, "more than 10 cm pivot drift rejects a target")
check(ready(&drifted, matrix: pose(x: 0.2), start: 1).mode == .returnToPivot,
      "displaced but perfectly aimed phone must get pivot correction instead of centered-target encouragement")
check(ready(&drifted, matrix: pose(x: 0.10), start: 2).readyToCapture, "the documented pivot boundary is accepted")
var dwelling = StationCapturePolicy(origin: [0, 0, 0], referenceYawDegrees: 0)
_ = dwelling.evaluate(timestamp: 0, cameraToWorld: pose(), normalTracking: true, motionBlurAcceptable: true, angularSpeedDegreesPerSecond: 0)
let halfway = dwelling.evaluate(timestamp: 0.1, cameraToWorld: pose(), normalTracking: true, motionBlurAcceptable: true, angularSpeedDegreesPerSecond: 0)
check(halfway.mode == .steady && halfway.steadyProgress > 0 && halfway.steadyProgress < 1 && !halfway.readyToCapture,
      "dwell indicator reports actual partial steady time without claiming a saved photo")
let moved = dwelling.evaluate(timestamp: 0.2, cameraToWorld: pose(yaw: 30), normalTracking: true, motionBlurAcceptable: true, angularSpeedDegreesPerSecond: 0)
check(moved.mode == .aim && moved.steadyProgress == 0, "moving away from target clears dwell progress")
var invalid = pose(); invalid[0][0] = .nan
check(!StationCapturePolicy(origin: [0, 0, 0], referenceYawDegrees: 0).isComplete, "empty progress is incomplete")
check(StationCapturePolicy.pose(invalid) == nil, "nonfinite pose is rejected")
invalid = pose(); invalid[0][0] = -1
check(StationCapturePolicy.pose(invalid) == nil, "reflected camera basis is rejected")

var reset = StationCapturePolicy(origin: [0, 0, 0], referenceYawDegrees: 0)
_ = reset.evaluate(timestamp: 0, cameraToWorld: pose(), normalTracking: true, motionBlurAcceptable: true, angularSpeedDegreesPerSecond: 0)
_ = reset.evaluate(timestamp: 0.1, cameraToWorld: pose(), normalTracking: true, motionBlurAcceptable: true, angularSpeedDegreesPerSecond: 0)
_ = reset.evaluate(timestamp: 0.2, cameraToWorld: pose(), normalTracking: false, motionBlurAcceptable: true, angularSpeedDegreesPerSecond: 0)
check(!reset.evaluate(timestamp: 0.3, cameraToWorld: pose(), normalTracking: true, motionBlurAcceptable: true, angularSpeedDegreesPerSecond: 0).readyToCapture, "tracking loss resets dwell")
check(!reset.evaluate(timestamp: 9, cameraToWorld: pose(), normalTracking: true, motionBlurAcceptable: true, angularSpeedDegreesPerSecond: 0).readyToCapture, "missing frame interval resets dwell")
check(!reset.evaluate(timestamp: 9.1, cameraToWorld: pose(), normalTracking: true, motionBlurAcceptable: false, angularSpeedDegreesPerSecond: 0).readyToCapture, "blur rejection cannot advance a target")
check(!reset.evaluate(timestamp: 9.2, cameraToWorld: pose(), normalTracking: true, motionBlurAcceptable: true, angularSpeedDegreesPerSecond: 3.1).readyToCapture, "angular motion above steady limit cannot advance")

var full = StationCapturePolicy(origin: [0, 0, 0], referenceYawDegrees: 20)
for target in StationCaptureTarget.standard {
    let result = ready(&full, matrix: pose(yaw: target.yaw_degrees + 20, pitch: target.pitch_degrees), start: Double(target.index))
    check(result.readyToCapture, "each target including poles can be admitted with a valid corresponding pose")
    check(full.beginWrite() && full.finishWrite(targetID: target.id, succeeded: true), "each target commits once")
}
check(full.isComplete && full.currentTarget == nil && full.completedCount == 38, "complete requires every original target")
check(!full.beginWrite(), "finished station cannot admit a 39th image")

var epoch = StationCaptureEpochPolicy()
check(epoch.observe(timestamp: 10, relocalizing: false) == nil, "new epoch starts with camera time")
check(epoch.observe(timestamp: 10, relocalizing: false) == nil, "begin and process may inspect the same ARFrame")
check(epoch.observe(timestamp: 11, relocalizing: true) != nil && epoch.isClosed, "relocalization during any phase closes the epoch")
check(epoch.observe(timestamp: 12, relocalizing: false) != nil, "normal tracking cannot revive a closed coordinate epoch")
var backwards = StationCaptureEpochPolicy()
_ = backwards.observe(timestamp: 10, relocalizing: false)
check(backwards.observe(timestamp: 9, relocalizing: false) != nil, "camera time reset closes the epoch")
var limit = StationCaptureEpochPolicy()
_ = limit.observe(timestamp: 10, relocalizing: false)
check(limit.observe(timestamp: 1810, relocalizing: false) != nil, "30-minute total epoch limit includes between-position time")

do {
    // Native CVPixelBuffer fixtures exercise exact row packing, including padding.
    // They are not camera captures or physical LiDAR verification.
    var pixelBuffer: CVPixelBuffer?
    check(CVPixelBufferCreate(kCFAllocatorDefault, 7, 3, kCVPixelFormatType_DepthFloat32,
                             [kCVPixelBufferBytesPerRowAlignmentKey: 64] as CFDictionary, &pixelBuffer) == kCVReturnSuccess, "allocate synthetic padded depth")
    let depth = pixelBuffer!
    CVPixelBufferLockBaseAddress(depth, [])
    let base = CVPixelBufferGetBaseAddress(depth)!
    let stride = CVPixelBufferGetBytesPerRow(depth)
    memset(base, 0xAB, stride * 3)
    var expected = Data()
    for y in 0..<3 { for x in 0..<7 {
        let value: Float = x == 0 && y == 0 ? .nan : Float(y * 10 + x) / 10
        base.advanced(by: y * stride + x * 4).storeBytes(of: value, as: Float.self)
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { expected.append(contentsOf: $0) }
    } }
    CVPixelBufferUnlockBaseAddress(depth, [])
    let packed = try StationDepthPacking.copyDepth(depth)
    check(packed.width == 7 && packed.height == 3 && packed.data == expected, "packed depth preserves Float32 bits and invalid holes while removing row padding")
    var confidenceBuffer: CVPixelBuffer?
    check(CVPixelBufferCreate(kCFAllocatorDefault, 7, 3, kCVPixelFormatType_OneComponent8,
                             [kCVPixelBufferBytesPerRowAlignmentKey: 64] as CFDictionary, &confidenceBuffer) == kCVReturnSuccess, "allocate synthetic padded confidence")
    let confidence = confidenceBuffer!
    CVPixelBufferLockBaseAddress(confidence, [])
    let cb = CVPixelBufferGetBaseAddress(confidence)!.assumingMemoryBound(to: UInt8.self)
    let cs = CVPixelBufferGetBytesPerRow(confidence)
    memset(cb, 0xAB, cs * 3)
    for y in 0..<3 { for x in 0..<7 { cb[y * cs + x] = UInt8(x % 3) } }
    CVPixelBufferUnlockBaseAddress(confidence, [])
    let confidenceData = try StationDepthPacking.copyConfidence(confidence, width: 7, height: 3)
    check(confidenceData == Data((0..<21).map { UInt8(($0 % 7) % 3) }), "confidence packing strips padding and preserves values")
    rejects("confidence dimensions must match depth") { _ = try StationDepthPacking.copyConfidence(confidence, width: 8, height: 3) }
    rejects("wrong depth format is rejected") { _ = try StationDepthPacking.copyDepth(confidence) }
    CVPixelBufferLockBaseAddress(confidence, []); cb[0] = 255; CVPixelBufferUnlockBaseAddress(confidence, [])
    rejects("invalid confidence values remain an explicit error") { _ = try StationDepthPacking.copyConfidence(confidence, width: 7, height: 3) }

    // The /var alias is intentional: Foundation may enumerate /private/var.
    let parent = URL(fileURLWithPath: "/var/tmp").appendingPathComponent("station-tests-\(UUID().uuidString)")
    try StationCaptureArchive.prepareRoot(parent)
    defer { try? FileManager.default.removeItem(at: parent) }
    let id = UUID().uuidString
    let root = parent.appendingPathComponent(id)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    for name in ["images", "frames", "depth"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false) }
    var manifest = StationCaptureManifest(sessionID: id, deviceModel: "synthetic-test", operatingSystem: "synthetic-test", depthSupported: false)
    var station = StationCaptureStation(id: UUID().uuidString, index: 0, origin: [0, 0, 0], reference_yaw_degrees: 0, started_timestamp: 1)
    station.frames = ["frames/000001.json"]; station.status = .partial
    manifest.stations = [station]; manifest.status = .partial
    let encoder = JSONEncoder()
    func saveManifest() throws { try encoder.encode(manifest).write(to: root.appendingPathComponent("manifest.json"), options: .atomic) }
    try saveManifest()
    var rasterBuffer: CVPixelBuffer?
    check(CVPixelBufferCreate(kCFAllocatorDefault, 80, 48, kCVPixelFormatType_32BGRA,
                             [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &rasterBuffer) == kCVReturnSuccess, "allocate synthetic test raster")
    let raster = rasterBuffer!
    CVPixelBufferLockBaseAddress(raster, [])
    memset(CVPixelBufferGetBaseAddress(raster)!, 128, CVPixelBufferGetBytesPerRow(raster) * 48)
    CVPixelBufferUnlockBaseAddress(raster, [])
    let size = ImageResolution(width: 80, height: 48)
    try NativeRasterWriter().write(raster, resolution: size, to: root.appendingPathComponent("images/000001.jpg"))
    let frame = FrameRecord(session_id: id, image: "images/000001.jpg", camera_to_world: pose(), intrinsics: [[60, 0, 40], [0, 60, 24], [0, 0, 1]],
                            image_resolution: size, timestamp: 1, tracking_state: TrackingRecord(state: "normal", reason: nil), raw_feature_points: [FeaturePoint(id: "1", position: [0, 0, -2])],
                            exposure_duration_seconds: 0.005, exposure_offset_ev: 0, world_mapping_status: "mapped")
    let record = StationCaptureFrame(station_id: station.id, target_id: "middle-0", frame: frame, depth: nil, depth_availability: "unsupported", pivot_drift_metres: 0, angular_error_degrees: 0)
    let sidecar = root.appendingPathComponent("frames/000001.json")
    try encoder.encode(record).write(to: sidecar)
    let originalSidecar = try Data(contentsOf: sidecar)
    let lightweight = try StationCaptureArchive.loadFrames(at: root, stationID: station.id)
    check(lightweight.count == 1, "partial station originals can be reopened for preview")
    check(lightweight[0].frame.raw_feature_points.isEmpty, "preview validation releases raw point arrays rather than retaining a station of clouds")
    check(try Data(contentsOf: sidecar) == originalSidecar, "compacted preview metadata never changes original sidecars")
    check(try JSONDecoder().decode(StationCaptureFrame.self, from: originalSidecar).frame.raw_feature_points.count == 1, "raw point cloud remains stored in original sidecar")
    var malformedSidecar = try JSONSerialization.jsonObject(with: originalSidecar) as! [String: Any]
    var malformedFrame = malformedSidecar["frame"] as! [String: Any]
    malformedFrame["raw_feature_points"] = [["id": "invalid-point-id", "position": [0, 0, -2]]]
    malformedSidecar["frame"] = malformedFrame
    try JSONSerialization.data(withJSONObject: malformedSidecar).write(to: sidecar)
    rejects("unused raw points still undergo full validation before release") { _ = try StationCaptureArchive.loadFrames(at: root, stationID: station.id) }
    try originalSidecar.write(to: sidecar)
    check(try StationCaptureArchive.validateForExport(at: root).frameCount == 1, "partial export truthfully preserves incomplete coverage")
    check(try StationCaptureArchive.listTours(at: parent).count == 1, "archive recovery lists saved attempts")
    manifest.status = .complete
    rejects("tour cannot claim complete with a partial station") { try StationCaptureArchive.validateManifest(manifest, directoryID: id) }
    manifest.stations[0].status = .complete
    rejects("station cannot claim complete after one target") { try StationCaptureArchive.validateManifest(manifest, directoryID: id) }
    manifest.status = .partial; manifest.stations[0].status = .partial
    manifest.stations[0].frames = ["../escape.json"]
    rejects("manifest cannot escape through a sidecar path") { try StationCaptureArchive.validateManifest(manifest, directoryID: id) }
    manifest.stations[0].frames = ["frames/000001.json"]
    manifest.status = .capturing; try saveManifest()
    rejects("active tour cannot be exported") { _ = try StationCaptureArchive.validateForExport(at: root) }
    manifest.stations[0].status = .capturing; try saveManifest()
    let originalJPEG = try Data(contentsOf: root.appendingPathComponent("images/000001.jpg"))
    let recovered = try StationCaptureArchive.recoverAbandonedTour(at: root)
    check(recovered.status == .interrupted && recovered.stations[0].status == .interrupted && recovered.frameCount == 1,
          "abandoned epoch recovery finalizes only durable frames as interrupted")
    check(try Data(contentsOf: root.appendingPathComponent("images/000001.jpg")) == originalJPEG, "abandoned recovery never rewrites original photos")
    check(try StationCaptureArchive.validateForExport(at: root).frameCount == 1, "recovered interrupted capture can export verified files")
    check(try StationCaptureArchive.recoverAbandonedTour(at: root).finished_at == recovered.finished_at, "recovery is idempotent after finalization")
    manifest.status = .interrupted; try saveManifest()
    check(try StationCaptureArchive.validateForExport(at: root).frameCount == 1, "interrupted tour remains inspectable and exportable without claiming completion")
    let originalFrames = root.appendingPathComponent("frames")
    let moved = parent.appendingPathComponent("frame-fixture")
    try FileManager.default.moveItem(at: originalFrames, to: moved)
    try FileManager.default.createSymbolicLink(at: originalFrames, withDestinationURL: moved)
    rejects("preview refuses a sidecar-parent symlink before reading it") { _ = try StationCaptureArchive.loadFrames(at: root, stationID: station.id) }
    rejects("export refuses a sidecar-parent symlink") { _ = try StationCaptureArchive.validateForExport(at: root) }
    try FileManager.default.removeItem(at: originalFrames); try FileManager.default.moveItem(at: moved, to: originalFrames)
    let orphan = root.appendingPathComponent("images/000002.partial.jpg")
    try Data([1, 2]).write(to: orphan)
    rejects("unexpected partial originals block verified export and are preserved") { _ = try StationCaptureArchive.validateForExport(at: root) }
    check(FileManager.default.fileExists(atPath: orphan.path), "failed export never deletes an orphan")
    manifest.status = .capturing; manifest.stations[0].status = .capturing; try saveManifest()
    let beforeRefusedRecovery = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
    rejects("unfinished orphan files block abandoned-tour recovery") { _ = try StationCaptureArchive.recoverAbandonedTour(at: root) }
    check(try Data(contentsOf: root.appendingPathComponent("manifest.json")) == beforeRefusedRecovery, "refused recovery keeps the manifest untouched")
    check(FileManager.default.fileExists(atPath: orphan.path), "refused recovery preserves the unfinished original")
    try FileManager.default.removeItem(at: orphan)
    _ = try StationCaptureArchive.recoverAbandonedTour(at: root)
    try Data([1, 2, 3]).write(to: root.appendingPathComponent("images/000001.jpg"))
    rejects("every export revalidates original JPEG bytes") { _ = try StationCaptureArchive.validateForExport(at: root) }
    print("PASS: \(checks) station policy, epoch, native depth and archive assertions. Synthetic software checks only; physical camera validation remains owner-only.")
} catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
