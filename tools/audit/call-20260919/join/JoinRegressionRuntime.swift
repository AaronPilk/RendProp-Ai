import Foundation
import AVFoundation

enum MediaImporter { static let maxDurationSeconds = 600.0; static func excludeFromBackup(_ url: URL) {} }
enum Haptics { static func heavy() {} }
enum Analytics { static func track(_ event: String, _ values: [String:String]) {} }
enum SpaceType: String { case realEstate; static let current = Self.realEstate; var quickTags: [String] { [] } }
final class CameraProbe {
    enum State { case ready, recording, paused, configuring, idle, finalizing }
    var state: State = .ready
    var interruptionMessage: String?
    var startCalls = 0
    var activeFPS = 30.0
    var activeWidth = 320
    var activeHeight = 240
    var elapsed = 0.6
    var personVisibleRanges = [TimeRange(startS: 0.1, endS: 0.5)]
    func startRecording() { startCalls += 1; state = .recording }
    func stopRecording() { state = .finalizing }
}
final class MotionRecorder {
    var endCalls = 0
    func endLogging(besideVideoAt: URL, fps: Double, width: Int, height: Int) -> URL? { endCalls += 1; return nil }
    func checkpointLogging(besideVideoAt: URL, fps: Double, width: Int, height: Int) -> URL? { nil }
    static func copySidecar(from: URL, to: URL) async -> URL? { nil }
}

@MainActor final class JoinController {
    var isJoining = false
    var recordingRecovery: RecoverableTake?
    var recovery: RecoverableTake?
    var recoveryError: String?
    var savedTakes: [RecoverableTake] = []
    var otherRecordings: [TakeRecoveryStore.OtherRecording] = []
    var unreadableRecoveries = 0
    let camera = CameraProbe()
    let motion = MotionRecorder()
    var tags = [RoomTag(name: "Kitchen", tMs: 100)]
    var presented: URL?
    var presentedRecovery: RecoverableTake?
    func present(take: URL, recovery: RecoverableTake) { presented = take; presentedRecovery = recovery }
    func finish(_ urls: [URL]) { handleFinished(urls) }
    func retry(_ take: RecoverableTake) { joinSavedTake(take) }
    // PRODUCTION_METHODS
    // PRODUCTION_FLAGS
    // PRODUCTION_DISABLED
    // PRODUCTION_RECORD_ACTION
}

@main struct JoinRegressionRuntime {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        FileStore.documents = root
        let fm = FileManager.default
        try fm.createDirectory(at: FileStore.recordingsDir, withIntermediateDirectories: true)
        let fixture = root.appendingPathComponent("fixture.mov")
        let original = try Data(contentsOf: fixture)
        var assertions = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: message, code: 1) }
            assertions += 1
        }
        func copy(_ name: String) throws -> URL {
            let url = FileStore.recordingsDir.appendingPathComponent(name)
            try original.write(to: url)
            return url
        }
        func wait(_ controller: JoinController) async throws {
            for _ in 0..<3000 {
                if !controller.isJoining { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw NSError(domain: "join-timeout", code: 1)
        }

        let paths = (0..<1000).map { _ in FileStore.newRecordingURL().path }
        try check(Set(paths).count == 1000, "Every recording and joined output needs a unique name")
        let a = try copy("a.mov"), b = try copy("b.mov")
        let legacy = try copy("walkthrough-legacy.mov")
        try check(TakeRecoveryStore.load().otherRecordings.contains { $0.url.resolvingSymlinksInPath() == legacy.resolvingSymlinksInPath() },
                  "Pre-fix unindexed recordings must be manually exportable without a journal")
        let controller = JoinController()
        controller.finish([a,b])
        try check(controller.isJoining && controller.recordDisabled, "Record must be disabled immediately while joining")
        try check(controller.motion.endCalls == 1, "Gyro snapshot must freeze before await")
        let checkpoint = TakeRecoveryStore.load()
        try check(checkpoint.takes.count == 1 && checkpoint.takes[0].piecePaths.count == 2,
                  "Ordered originals must be durable before join begins")
        // Even an unrelated state mutation while the exporter is running cannot
        // contaminate the frozen review metadata.
        controller.tags.removeAll()
        controller.camera.personVisibleRanges = []
        controller.camera.activeFPS = 60
        controller.camera.elapsed = 99
        if !controller.recordDisabled { controller.pressRecord() }
        try await wait(controller)
        try check(controller.presented != nil && controller.recoveryError == nil, "Normal complete join should succeed")
        try check(controller.camera.startCalls == 0, "No second capture during join")
        try check(controller.presented != a && controller.presented != b, "Output must never alias an input")
        try check(try Data(contentsOf:a) == original && Data(contentsOf:b) == original, "Success must retain originals")
        try check(controller.presentedRecovery?.tags.count == 1 && controller.presentedRecovery?.people.count == 1,
                  "Review tags and detections must be frozen")
        try check(controller.presentedRecovery?.fps == 30 && controller.presentedRecovery?.seconds == 0.6,
                  "Review format and duration must be frozen")
        let output = controller.presented!
        let duration = try await AVURLAsset(url:output).load(.duration).seconds
        try check(abs(duration-0.6)<0.01, "Complete output has both segment durations")
        let saved = TakeRecoveryStore.load().takes.first!
        try check(saved.joined == output && saved.pieces == [a,b] && saved.tags.count == 1,
                  "Relaunch must recover joined output and ordered originals")
        try check(!TakeRecoveryStore.load().otherRecordings.contains { $0.url.resolvingSymlinksInPath() == output.resolvingSymlinksInPath() },
                  "An indexed joined output is not listed as an ungrouped legacy file")

        let damaged = try copy("damaged.mov")
        let damage = Data("synthetic corrupt MOV retained".utf8)
        try damage.write(to: damaged)
        let failed = await TakeJoiner.join([a, damaged, b])
        try check(failed == nil, "One damaged segment must fail the whole join")
        try check(try Data(contentsOf:damaged) == damage && Data(contentsOf:a) == original && Data(contentsOf:b) == original,
                  "Failure must not delete damaged bytes or good originals")
        try check(await TakeJoiner.join([a,a]) == nil, "Duplicate source paths must be rejected")

        let different = FileStore.recordingsDir.appendingPathComponent("different.mov")
        try fm.copyItem(at:root.appendingPathComponent("different-size.mov"),to:different)
        try check(await TakeJoiner.join([a,different]) == nil, "Unsupported format changes must preserve separate parts")
        try check(fm.fileExists(atPath:different.path), "Format rejection preserves original")

        let long = root.appendingPathComponent("long.mov"), extra = root.appendingPathComponent("one-second.mov")
        try check(await TakeJoiner.join([long,extra]) == nil, "An over-cap aggregate is refused without trimming")
        try check(fm.fileExists(atPath:long.path) && fm.fileExists(atPath:extra.path), "Cap rejection retains complete source footage")

        let failureController = JoinController()
        failureController.finish([a,damaged,b])
        try await wait(failureController)
        try check(failureController.presented == nil && failureController.recovery?.pieces == [a,damaged,b],
                  "Failed join must expose every part instead of presenting first-only")
        try check(failureController.recoveryError != nil, "Failure must explain recovery")
        let failedID = failureController.recovery!.id
        let relaunched = TakeRecoveryStore.load().takes.first { $0.id == failedID }!
        try check(relaunched.pieces == [a,damaged,b] && relaunched.tags.count == 1,
                  "Failed take metadata survives relaunch")
        try original.write(to:damaged) // Repairs ONLY synthetic fixture for retry.
        let retry = JoinController()
        retry.retry(relaunched)
        try await wait(retry)
        try check(retry.presented != nil && retry.recoveryError == nil, "Recovered take can retry successfully")
        try check([a,damaged,b].allSatisfy { fm.fileExists(atPath:$0.path) }, "Retry retains every original")

        // Invalid metadata must not overwrite the earlier recoverable record.
        var traversal = saved
        traversal.piecePaths = ["Recordings/../../outside.mov"]
        do { try TakeRecoveryStore.save(traversal); throw NSError(domain:"accepted-traversal",code:1) }
        catch TakeRecoveryStore.RecoveryError.invalidRecord { assertions += 1 }
        try check(TakeRecoveryStore.load().takes.contains { $0.id == saved.id && $0.pieces == [a,b] },
                  "Invalid checkpoint leaves prior journal intact")
        let corruptJournal = root.appendingPathComponent("TakeRecovery/\(UUID().uuidString).json")
        let badJSON = Data("{broken journal".utf8)
        try badJSON.write(to:corruptJournal)
        try check(TakeRecoveryStore.load().unreadableCount == 1, "Unreadable journals must remain visible")
        try check(try Data(contentsOf:corruptJournal) == badJSON, "Unreadable journal bytes must be retained")

        // A journal write failure stops before export and keeps an in-memory
        // recovery card with both real source URLs for manual export.
        let full = root.appendingPathComponent("journal-write-failure",isDirectory:true)
        try fm.createDirectory(at:full.appendingPathComponent("Recordings"),withIntermediateDirectories:true)
        try Data([0]).write(to:full.appendingPathComponent("TakeRecovery"))
        FileStore.documents = full
        let f1 = try copy("first.mov"), f2 = try copy("second.mov")
        let noJournal = JoinController()
        noJournal.finish([f1,f2])
        try check(!noJournal.isJoining && noJournal.presented == nil && noJournal.recoveryError != nil,
                  "No join starts if recovery cannot be made durable")
        try check(noJournal.recovery?.pieces == [f1,f2] && noJournal.savedTakes.isEmpty,
                  "Unsaved recovery exposes all parts without claiming a saved journal")
        try check(try Data(contentsOf:f1) == original && Data(contentsOf:f2) == original,"Journal failure retains original bytes")
        FileStore.documents = root

        let result: [String:Any] = ["assertions":assertions,"accepted":true,"complete_duration":duration,
                                    "preserved_originals":true,"relaunch_retry":true]
        let bytes = try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])
        try bytes.write(to:root.appendingPathComponent("regression-results.json"))
        print(String(decoding:bytes,as:UTF8.self))
    }
}
