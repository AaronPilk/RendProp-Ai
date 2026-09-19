import Foundation
import CoreMedia
import CoreVideo
import Combine

// Framework-only test doubles. Tests below supply capture timestamps and movie
// durations independently; these doubles contain no production timing logic.
enum AuditClock { static var now = 100.0 }
struct Vector { var x = 0.0; var y = -1.0; var z = 0.0 }
struct Quaternion { var w = 1.0; var x = 0.0; var y = 0.0; var z = 0.0 }
struct Attitude { var quaternion = Quaternion() }
struct CMDeviceMotion {
    let timestamp: Double
    var gravity = Vector()
    var userAcceleration = Vector(x: 0, y: 0, z: 0)
    var rotationRate = Vector(x: 0, y: 0, z: 0)
    var attitude = Attitude()
}
final class CMMotionManager {
    var isDeviceMotionAvailable = true
    var deviceMotionUpdateInterval = 0.0
    func startDeviceMotionUpdates(to: OperationQueue, withHandler: @escaping (CMDeviceMotion?, Error?) -> Void) {}
    func stopDeviceMotionUpdates() {}
}
enum Haptics { static var warnings = 0; static func warning() { warnings += 1 } }
struct TimeRange { var startS: Double; var endS: Double }
struct AVCaptureOutput {}
struct AVCaptureConnection {}
struct VisionObservation { let confidence: Double }
class FakeVisionRequest { var results: [VisionObservation]? = [] }
final class VNDetectHumanRectanglesRequest: FakeVisionRequest {}
final class VNDetectFaceRectanglesRequest: FakeVisionRequest {}
enum Orientation { case right }
final class VNImageRequestHandler {
    static var found = false
    static var count = 0
    init(cvPixelBuffer: CVPixelBuffer, orientation: Orientation, options: [String: String]) {}
    func perform(_ requests: [FakeVisionRequest]) throws {
        Self.count += 1
        for r in requests { r.results = Self.found ? [VisionObservation(confidence: 1)] : [] }
    }
}
final class MovieOutput { var recordedDuration = CMTime.zero }
final class CameraManager {
    enum CaptureState { case ready, recording, paused, finalizing }
    var state: CaptureState = .ready
    var elapsed = 0.0
    var bankedSeconds = 0.0
    let movieOutput = MovieOutput()
    var personHits = 0
    var personMisses = 0
    var personInShot = false
    var personRangeStart: Double?
    var personVisibleRanges: [TimeRange] = []
    @Published var thermalMessage: String? = nil
    var frameCounter = 0
    var luminance = 0.5
    let personRequest = VNDetectHumanRectanglesRequest()
    let faceRequest = VNDetectFaceRectanglesRequest()
    // INSERT_ACTUAL_CAMERA_METHODS
}

// INSERT_ACTUAL_MOTION_SOURCE

func setTime(_ camera: CameraManager, _ seconds: Double) {
    camera.movieOutput.recordedDuration = CMTime(seconds: seconds, preferredTimescale: 600)
}
func sample(_ camera: CameraManager, _ seconds: Double, _ found: Bool) {
    setTime(camera, seconds)
    camera.ingestPersonSample(found)
}
func ranges(_ camera: CameraManager) -> [[Double]] {
    camera.personVisibleRanges.map { [$0.startS, $0.endS] }
}
func drainMain() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
func makeBuffer() -> (CVPixelBuffer, CMSampleBuffer) {
    var pixel: CVPixelBuffer?
    precondition(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16,
                                   kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                   nil, &pixel) == kCVReturnSuccess)
    var format: CMVideoFormatDescription?
    precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                     imageBuffer: pixel!, formatDescriptionOut: &format) == noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                   presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                     imageBuffer: pixel!, formatDescription: format!, sampleTiming: &timing,
                     sampleBufferOut: &sample) == noErr)
    return (pixel!, sample!)
}

// Optional sanitizer probe: the application's luma queue reads this published
// optional while thermalChanged writes it on main. Both sites below retain the
// production operation; only the notifications and pixel source are synthetic.
if CommandLine.arguments.contains("--thermal-race") {
    let c = CameraManager()
    let (pixel, _) = makeBuffer()
    let gate = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    DispatchQueue(label: "audit.capture.luma").async {
        gate.wait()
        for _ in 0..<100_000 { c.detectPeople(in: pixel) }
        done.signal()
    }
    gate.signal()
    for i in 0..<100_000 { c.thermalMessage = i % 2 == 0 ? "Phone is getting hot" : nil }
    done.wait()
    exit(0)
}

var report: [String: Any] = [:]

// Control: a 30-second wall-clock pause is removed, not billed as footage.
do {
    let c = CameraManager(); c.state = .recording
    sample(c, 1.0, true); sample(c, 1.5, true); sample(c, 3.0, true)
    c.closePersonRange(at: 3.0)
    c.bankedSeconds = 3.0; c.state = .paused
    for _ in 0..<60 { c.ingestPersonSample(true) }
    c.state = .recording; setTime(c, 0)
    sample(c, 0.5, true); sample(c, 1.0, true)
    c.closePersonRange(at: 4.0)
    precondition(ranges(c) == [[1.0, 4.5]])
    report["pauseWallTimeExcludedControl"] = ranges(c)
}

// A real person remains visible at Stop. Metadata extends past the actual
// media endpoint because padding is not clamped, even with perfect detections.
do {
    let c = CameraManager(); c.state = .recording
    sample(c, 0.0, true); sample(c, 0.5, true)
    c.closePersonRange(at: 10)
    precondition(ranges(c) == [[0, 10.5]])
    report["rangePastTenSecondMedia"] = ranges(c)
}

// During Stop's finalization window currentRecordedSeconds returns only
// previously banked segments. Four negative samples can therefore erase the
// entire still-open range before deliverTake closes it at the real file end.
do {
    let c = CameraManager(); c.state = .recording
    sample(c, 1.0, true); sample(c, 1.5, true); sample(c, 9.0, true)
    c.state = .finalizing
    for _ in 0..<4 { c.ingestPersonSample(false) }
    c.bankedSeconds = 10.0
    c.closePersonRange(at: c.bankedSeconds)
    precondition(c.personVisibleRanges.isEmpty)
    report["finalizingDropsEightSecondRange"] = ranges(c)
}

// Two short visible stretches straddle Pause. Their joined presence exceeds
// 0.75 s, but each is thrown out before the merge is even attempted.
do {
    let c = CameraManager(); c.state = .recording
    sample(c, 0.5, true); sample(c, 1.0, true)
    c.closePersonRange(at: 1.5)
    c.bankedSeconds = 1.5; c.state = .paused; c.ingestPersonSample(true)
    c.state = .recording; sample(c, 0.5, true)
    c.closePersonRange(at: 2.0)
    precondition(c.personVisibleRanges.isEmpty)
    report["pauseDropsTwoAdjacentHalfSecondDetectedSpans"] = ranges(c)
}

// Vision's main-queue callback carries only a Bool; it has neither the frame's
// PTS nor take identity. Queue two positives from take A, then reset into take B
// before their main callbacks execute. Actual detectPeople records them in B.
do {
    let c = CameraManager(); c.state = .recording; setTime(c, 8)
    let (pixel, _) = makeBuffer(); VNImageRequestHandler.found = true
    c.detectPeople(in: pixel); c.detectPeople(in: pixel)
    c.state = .ready
    c.personVisibleRanges = []; c.personRangeStart = nil
    c.bankedSeconds = 0; c.state = .recording; setTime(c, 0.1)
    drainMain()
    precondition(c.personRangeStart == 0.1 && c.personInShot)
    report["queuedOldTakeDetectionAttributedToNewTakeS"] = c.personRangeStart!
}

// Thermal skip never supplies a negative/reset signal. A raised warning and
// open range survive indefinitely with no subsequent Vision evidence.
do {
    let c = CameraManager(); c.state = .recording
    sample(c, 0.0, true); sample(c, 0.5, true)
    c.thermalMessage = "Phone is getting hot"
    let (pixel, _) = makeBuffer(); VNImageRequestHandler.found = false
    let before = VNImageRequestHandler.count
    for i in 1...120 { setTime(c, Double(i) / 2 + 0.5); c.detectPeople(in: pixel) }
    c.closePersonRange(at: 60.5)
    precondition(VNImageRequestHandler.count == before && c.personInShot)
    report["thermalSkipWithoutNewEvidence"] = ["warningStillOn": c.personInShot,
                                                "ranges": ranges(c)]
}

// Real captureOutput/CoreVideo sampler, fake Vision inference only. Modulo 15
// is two invocations a second at 30 FPS and FOUR at max-quality 60 FPS.
do {
    let (_, buffer) = makeBuffer()
    var counts: [String: Int] = [:]
    VNImageRequestHandler.found = false
    for fps in [30, 60] {
        let c = CameraManager(); VNImageRequestHandler.count = 0
        for _ in 0..<(fps * 10) {
            c.captureOutput(AVCaptureOutput(), didOutput: buffer, from: AVCaptureConnection())
        }
        counts["\(fps)fpsCallsIn10s"] = VNImageRequestHandler.count
    }
    precondition(counts["30fpsCallsIn10s"] == 20 && counts["60fpsCallsIn10s"] == 40)
    report["actualSamplerCadence"] = counts
    drainMain()
}

// Whole actual MotionRecorder, a deterministic uptime clock and generated
// motion values. Pause is invoked at tap=110; movie actually stops at110.4.
// Resumed movie starts at140. Every later sample is 0.4s ahead of its frame.
do {
    let m = MotionRecorder()
    AuditClock.now = 100; m.beginLogging()
    m.ingest(CMDeviceMotion(timestamp: 109.9))
    AuditClock.now = 110; m.pauseLogging()
    m.ingest(CMDeviceMotion(timestamp: 110.3)) // a frame still in first segment
    AuditClock.now = 140; m.resumeLogging()
    m.ingest(CMDeviceMotion(timestamp: 140.1))
    let actual = m.samples.map(\.t)
    precondition(abs(actual.last! - 10.1) < 0.0001)
    report["motionPauseTapVsActualSegmentEnd"] = ["sampleTimes": actual,
        "expectedLastJoinedTime": 10.5, "offsetS": actual.last! - 10.5,
        "lostWrittenTailSample": !actual.contains(where: { abs($0 - 10.3) < 0.0001 })]
}

// Even with zero AVFoundation latency, a delayed pre-pause motion callback can
// arrive after resume, use the *new* pausedAccum and create a backwards sample.
do {
    let m = MotionRecorder()
    AuditClock.now = 100; m.beginLogging(); m.ingest(CMDeviceMotion(timestamp: 199.9))
    AuditClock.now = 200; m.pauseLogging()
    AuditClock.now = 230; m.resumeLogging()
    m.ingest(CMDeviceMotion(timestamp: 199.99))
    m.ingest(CMDeviceMotion(timestamp: 230.01))
    let times = m.samples.map(\.t)
    precondition(times[1] < times[0])
    report["delayedMotionCallbackAfterResume"] = times
}

// CaptureView calls endLogging only after TakeJoiner returns. Motion is still
// enabled while joining, even though no movie frames exist after t=10 here.
do {
    let m = MotionRecorder()
    AuditClock.now = 100; m.beginLogging(); m.ingest(CMDeviceMotion(timestamp: 110))
    // Stop at110; export completion at115. No MotionRecorder call occurs in
    // handleFinished before its await TakeJoiner.join in the actual source.
    m.ingest(CMDeviceMotion(timestamp: 114))
    precondition(m.samples.last!.t == 14)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("audit-motion-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sidecarURL = m.endLogging(besideVideoAt: directory.appendingPathComponent("synthetic.mov"),
                                 fps: 30, width: 320, height: 240)!
    MotionRecorder.fileQueue.sync {}
    let persisted = try JSONDecoder().decode(MotionRecorder.Sidecar.self, from: Data(contentsOf: sidecarURL))
    precondition(persisted.samples.last!.t == 14)
    report["motionLoggingThroughJoin"] = ["mediaDurationS": 10,
                                           "lastPersistedSidecarSampleS": persisted.samples.last!.t]
    try FileManager.default.removeItem(at: directory)
}

let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
