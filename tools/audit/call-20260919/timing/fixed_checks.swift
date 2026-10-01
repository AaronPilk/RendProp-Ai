import Foundation
import CoreMedia
import CoreVideo
import Combine

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
enum FileStore {
    static var free: Int64 = 1_000_000_000
    static func freeSpaceBytes() -> Int64 { free }
    static func newRecordingURL() -> URL { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".mov") }
}
enum Formatters { static func bytes(_ n: Int64) -> String { String(n) } }
final class Session {
    var isRunning = true
    var synchronizationClock: CMClock? = CMClockGetHostTimeClock()
}
final class SessionQueue { func async(execute: () -> Void) { execute() } }
final class MovieOutput {
    var recordedDuration = CMTime.zero
    var maxRecordedDuration = CMTime.zero
    var starts = 0
    func startRecording(to: URL, recordingDelegate: AnyObject) { starts += 1 }
}
final class CameraManager {
    enum CaptureState { case ready, recording, paused, finalizing }
    enum SegmentEnd { case finish }
    static let maxRecordingSeconds = 600.0
    var state: CaptureState = .ready
    var elapsed = 0.0
    var bankedSeconds = 0.0
    var activeFPS = 30.0
    var activeSegmentURL: URL?
    var activeSegmentStartUptime: Double?
    var segmentGeneration = UUID()
    var takeStarted = false
    var segments: [URL] = []
    var pendingEnd = SegmentEnd.finish
    var recordTimer: Timer?
    var onFinish: (([URL]) -> Void)?
    var onDiscarded: (() -> Void)?
    var storageMessage: String?
    var interruptionMessage: String?
    let session = Session()
    let sessionQueue = SessionQueue()
    let movieOutput = MovieOutput()
    var personHits = 0
    var personMisses = 0
    var personInShot = false
    var personRangeStart: Double?
    var personVisibleRanges: [TimeRange] = []
    var rawPersonRanges: [TimeRange] = []
    var lastPersonSampleTime: Double?
    var lastPersonSourceTime = -Double.infinity
    var detectionAvailable = true
    let detectionLock = NSLock()
    var detectionContext = DetectionContext(generation: UUID(), available: true, segmentStart: nil, joinedOffset: 0)
    var lastDetectionUptime = -Double.infinity
    @Published var personDetectionUnavailableMessage: String?
    var luminance = 0.5
    let personRequest = VNDetectHumanRectanglesRequest()
    let faceRequest = VNDetectFaceRectanglesRequest()
    deinit { recordTimer?.invalidate() }
    // CAMERA_METHODS
}
// NORMALIZER
// MOTION_SOURCE

func pairs(_ ranges: [TimeRange]) -> [[Double]] { ranges.map { [$0.startS, $0.endS] } }
func sample(_ c: CameraManager, _ time: Double, _ found: Bool) { c.ingestPersonSample(found, at: time) }
func drainMain() { RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
func buffer(_ time: Double, fps: Int32 = 30) -> (CVPixelBuffer, CMSampleBuffer) {
    var pixel: CVPixelBuffer?
    precondition(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16,
                                   kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pixel) == kCVReturnSuccess)
    var format: CMVideoFormatDescription?
    precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                        imageBuffer: pixel!, formatDescriptionOut: &format) == noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: fps),
                    presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 600), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
        imageBuffer: pixel!, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
    return (pixel!, sample!)
}
var result: [String: Any] = [:]

do {
    let c = CameraManager(); c.state = .recording
    sample(c, 1, true); sample(c, 1.5, true); sample(c, 9, true)
    c.state = .finalizing
    for _ in 0..<4 { sample(c, 0, false) }
    c.bankedSeconds = 10; c.closePersonRange(at: 10)
    let normalized = PersonRangeTimeline.normalized(c.rawPersonRanges, duration: 10)
    precondition(pairs(normalized) == [[1, 10]])
    result["finalizingPreservesRange"] = pairs(normalized)
}
do {
    let c = CameraManager(); c.state = .recording
    sample(c, 0.5, true); sample(c, 1, true); c.closePersonRange(at: 1.5)
    c.state = .paused; sample(c, 1.5, true)
    c.state = .recording; sample(c, 1.5, true); c.closePersonRange(at: 2)
    let normalized = PersonRangeTimeline.normalized(c.rawPersonRanges, duration: 2)
    precondition(pairs(normalized) == [[0.5, 2]])
    result["pauseMergedBeforeFiltering"] = pairs(normalized)
    let invalid = [TimeRange(startS: .nan, endS: 4), TimeRange(startS: -10, endS: 2),
                   TimeRange(startS: 9, endS: 999), TimeRange(startS: 8, endS: 7)]
    let bounded = PersonRangeTimeline.normalized(invalid, duration: 10)
    precondition(pairs(bounded) == [[0, 2.5], [8.5, 10]])
    result["finiteClampedOrderedRanges"] = pairs(bounded)
}
do {
    let c = CameraManager(); c.state = .recording
    sample(c, 0, true); sample(c, 0.5, true); sample(c, 3, true)
    c.setPersonDetectionAvailable(false)
    let (pixel, _) = buffer(20)
    VNImageRequestHandler.count = 0
    c.detectPeople(in: pixel, sourceTime: 20, context: c.detectionContext)
    drainMain()
    precondition(!c.personInShot && c.personDetectionUnavailableMessage != nil && VNImageRequestHandler.count == 0)
    let normalized = PersonRangeTimeline.normalized(c.rawPersonRanges, duration: 60)
    precondition(pairs(normalized) == [[0, 3.5]])
    result["heatStopsEvidenceAndShowsUnavailable"] = pairs(normalized)
    c.setPersonDetectionAvailable(true)
    precondition(c.personDetectionUnavailableMessage == nil)
}
do {
    let c = CameraManager(); c.state = .recording
    c.activeSegmentStartUptime = 100; c.publishDetectionContext()
    let old = c.detectionContext
    VNImageRequestHandler.found = true
    let (pixel, _) = buffer(108)
    c.detectPeople(in: pixel, sourceTime: 108, context: old)
    c.detectPeople(in: pixel, sourceTime: 108.5, context: old)
    c.segmentGeneration = UUID(); c.activeSegmentStartUptime = 120; c.publishDetectionContext()
    drainMain()
    precondition(!c.personInShot && c.personRangeStart == nil)
    c.movieOutput.recordedDuration = CMTime(seconds: 9, preferredTimescale: 600)
    c.detectPeople(in: pixel, sourceTime: 121, context: c.detectionContext)
    c.detectPeople(in: pixel, sourceTime: 121.5, context: c.detectionContext)
    drainMain()
    precondition(c.personRangeStart == 1.5)
    result["oldGenerationRejectedAndSourceClockUsed"] = c.personRangeStart!
}
do {
    var counts: [String: Int] = [:]
    VNImageRequestHandler.found = false
    for fps in [30, 60] {
        let c = CameraManager(); c.publishDetectionContext(); VNImageRequestHandler.count = 0
        for i in 0..<(fps * 10) {
            let (_, frame) = buffer(Double(i) / Double(fps), fps: Int32(fps))
            c.captureOutput(AVCaptureOutput(), didOutput: frame, from: AVCaptureConnection())
        }
        counts[String(fps)] = VNImageRequestHandler.count
    }
    precondition(counts["30"] == 20 && counts["60"] == 20)
    result["wallTimeCadenceCallsInTenSeconds"] = counts
    drainMain()
}
do {
    let stopped = CameraManager(); stopped.state = .paused; stopped.session.isRunning = false
    stopped.resumeRecording()
    precondition(stopped.interruptionMessage != nil && stopped.movieOutput.starts == 0 && stopped.state == .paused)
    result["resumeUnavailableHasFeedback"] = true
    var totals: [Double] = []
    for fps in [30.0, 60.0] {
        for banked in [599.25, 599.75, 599.99, 600.0] {
            let c = CameraManager(); c.state = .paused; c.activeFPS = fps; c.bankedSeconds = banked
            c.segments = [URL(fileURLWithPath: "/synthetic-existing-piece.mov")]
            var delivered = false; c.onFinish = { delivered = !$0.isEmpty }
            c.resumeRecording()
            if banked == 599.99 || banked == 600 {
                precondition(delivered && c.movieOutput.starts == 0)
            } else {
                let total = banked + c.movieOutput.maxRecordedDuration.seconds
                precondition(total <= 600 && c.movieOutput.starts == 1)
                totals.append(total)
            }
        }
    }
    result["flooredCapTotals"] = totals
}
do {
    let m = MotionRecorder(); m.beginLogging(); m.beginSegment(atUptime: 100, joinedOffset: 0)
    m.ingest(CMDeviceMotion(timestamp: 109.9)); m.ingest(CMDeviceMotion(timestamp: 110.3))
    m.ingest(CMDeviceMotion(timestamp: 111))
    m.finishSegment(duration: 10.4)
    precondition(m.samples.count == 2 && abs(m.samples.last!.t - 10.3) < 0.00001)
    m.ingest(CMDeviceMotion(timestamp: 120))
    m.beginSegment(atUptime: 140, joinedOffset: 10.4)
    m.ingest(CMDeviceMotion(timestamp: 109.99))
    m.ingest(CMDeviceMotion(timestamp: 140.1)); m.finishSegment(duration: 5)
    m.ingest(CMDeviceMotion(timestamp: 160))
    precondition(m.samples.count == 3 && abs(m.samples.last!.t - 10.5) < 0.00001)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fixed-motion-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let video = dir.appendingPathComponent("first.mov")
    let checkpoint = m.checkpointLogging(besideVideoAt: video, fps: 30, width: 320, height: 240)!
    precondition(m.samples.count == 3)
    let final = m.endLogging(besideVideoAt: video, fps: 30, width: 320, height: 240)!
    MotionRecorder.fileQueue.sync {}
    precondition(final == checkpoint)
    let decoded = try JSONDecoder().decode(MotionRecorder.Sidecar.self, from: Data(contentsOf: final))
    precondition(decoded.samples.count == 3 && decoded.samples.allSatisfy { $0.t < 15.4 })
    result["persistedMediaAlignedMotionTimes"] = decoded.samples.map(\.t)
    var copied: URL?
    Task {
        copied = await MotionRecorder.copySidecar(from: video, to: dir.appendingPathComponent("joined.mov"))
    }
    let deadline = Date().addingTimeInterval(5)
    while copied == nil && Date() < deadline { drainMain() }
    let rebound = try JSONDecoder().decode(MotionRecorder.Sidecar.self, from: Data(contentsOf: copied!))
    precondition(rebound.videoFile == "joined.mov" && rebound.samples.count == 3 && FileManager.default.fileExists(atPath: final.path))
    result["sidecarRebindRetainsSource"] = true
    try FileManager.default.removeItem(at: dir)
}
print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
