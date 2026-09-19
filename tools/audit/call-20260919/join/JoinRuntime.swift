import Foundation
import AVFoundation

// Dependencies only. The runner extracts the production join, caller and URL
// allocator byte-for-byte; AVFoundation itself is never mocked.
enum MediaImporter { static func excludeFromBackup(_ url: URL) {} }
enum MotionRecorder { static func deleteSidecar(for url: URL) {} }
enum Haptics { static func heavy() {} }
enum Analytics { static func track(_ event: String, _ values: [String:String]) {} }
enum SpaceType: String { case realEstate; static let current = Self.realEstate }
final class CameraProbe {
    enum State { case ready, recording, paused, configuring, idle, finalizing }
    var state: State = .ready // CameraManager.deliverTake sets ready before onFinish.
    var interruptionMessage: String?
    var startCalls = 0
    func startRecording() { startCalls += 1; state = .recording }
    func stopRecording() { state = .finalizing }
}

@MainActor final class JoinProbe {
    var isJoining = false
    var joinWarning: String?
    var presented: URL?
    var pauses = 0
    let camera = CameraProbe()
    var tags: [String] = []
    var presentedTags: [String] = []
    func present(take: URL, pauses: Int) {
        self.presented = take; self.pauses = pauses
        presentedTags = tags // Same deferred tags read as production present.
    }
    func begin(_ urls: [URL]) { handleFinished(urls) }
    // PRODUCTION_FLAGS
    // PRODUCTION_DISABLED
    // PRODUCTION_RECORD_ACTION
    // PRODUCTION_HANDLER
    // PRODUCTION_DELETE
}

func duration(_ url: URL?) async -> Double? {
    guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try? await AVURLAsset(url: url).load(.duration).seconds
}

@main struct JoinRuntime {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        FileStore.documents = root

        let fm = FileManager.default
        try fm.createDirectory(at: FileStore.recordingsDir, withIntermediateDirectories: true)
        let fixture = root.appendingPathComponent("fixture.mov")
        var results: [[String: Any]] = []
        func copied(_ name: String) throws -> URL {
            let out = FileStore.recordingsDir.appendingPathComponent(name)
            try fm.copyItem(at: fixture, to: out)
            return out
        }
        func finish(_ p: JoinProbe) async throws {
            for _ in 0..<3000 {
                if p.presented != nil { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw NSError(domain: "join-timeout", code: 1)
        }
        let normal = JoinProbe()
        let n1 = try copied("normal-first.mov"), n2 = try copied("normal-second.mov")
        normal.begin([n1, n2]); try await finish(normal)
        results.append(["case": "normal", "warning": normal.joinWarning as Any? ?? NSNull(),
            "duration": await duration(normal.presented) as Any? ?? NSNull(),
            "presented_exists": fm.fileExists(atPath: normal.presented!.path),
            "sources_exist": [n1,n2].map { fm.fileExists(atPath: $0.path) }])

        // Genuine local AVURLAsset failure in one segment: the caller must not
        // turn a subset into success and delete the original damaged bytes.
        let partial = JoinProbe()
        let p1 = try copied("partial-first.mov"), p3 = try copied("partial-third.mov")
        let p2 = FileStore.recordingsDir.appendingPathComponent("partial-damaged.mov")
        try Data("synthetic truncated MOV retained for recovery".utf8).write(to: p2)
        partial.begin([p1,p2,p3]); try await finish(partial)
        results.append(["case": "damaged_middle", "warning": partial.joinWarning as Any? ?? NSNull(),
            "duration": await duration(partial.presented) as Any? ?? NSNull(),
            "sources_exist": [p1,p2,p3].map { fm.fileExists(atPath: $0.path) }])

        // Last resume starts and stops during one wall-clock second. Real
        // newRecordingURL(), Date(), filesystem and exporter; no clock mock.
        while Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1) > 0.03 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let collision = JoinProbe()
        let c1 = try copied("collision-first.mov")
        let c2 = FileStore.newRecordingURL()
        let collisionAllocatedAt = Date().timeIntervalSince1970
        try? fm.removeItem(at: c2)
        try fm.copyItem(at: fixture, to: c2)
        collision.begin([c1,c2]); try await finish(collision)
        results.append(["case": "same_second_output", "warning": collision.joinWarning as Any? ?? NSNull(),
            "allocated_at": collisionAllocatedAt, "finished_at": Date().timeIntervalSince1970,
            "presented_is_input": collision.presented == c1 || collision.presented == c2,
            "presented_path": collision.presented!.lastPathComponent,
            "presented_exists": fm.fileExists(atPath: collision.presented!.path),
            "source_paths": [c1,c2].map(\.lastPathComponent),
            "sources_exist": [c1,c2].map { fm.fileExists(atPath: $0.path) }])

        // A valid video at a different size is deliberately tested rather than
        // assuming passthrough cannot represent multiple descriptions.
        let mismatch = JoinProbe()
        let m1 = try copied("mismatch-first.mov")
        let m2 = FileStore.recordingsDir.appendingPathComponent("mismatch-second.mov")
        try fm.copyItem(at: root.appendingPathComponent("different-size.mov"), to: m2)
        mismatch.begin([m1,m2]); try await finish(mismatch)
        results.append(["case": "different_dimensions", "warning": mismatch.joinWarning as Any? ?? NSNull(),
            "duration": await duration(mismatch.presented) as Any? ?? NSNull(),
            "presented_exists": fm.fileExists(atPath: mismatch.presented!.path)])

        let overCap = JoinProbe()
        let l1 = root.appendingPathComponent("long.mov"), l2 = root.appendingPathComponent("one-second.mov")
        overCap.begin([l1,l2]); try await finish(overCap)
        results.append(["case": "599.75_plus_1_second", "warning": overCap.joinWarning as Any? ?? NSNull(),
            "duration": await duration(overCap.presented) as Any? ?? NSNull(),
            "presented_exists": fm.fileExists(atPath: overCap.presented!.path)])

        // Force a real output-open failure through a local ENOTDIR path. The
        // production fallback returns only the first URL; no segment manifest
        // is created for either the view or a subsequent app launch.
        let fallback = JoinProbe()
        let f1 = try copied("fallback-first.mov"), f2 = try copied("fallback-second.mov")
        let impossible = root.appendingPathComponent("not-a-directory")
        try Data([0]).write(to: impossible)
        FileStore.documents = impossible
        fallback.begin([f1,f2]); try await finish(fallback)
        results.append(["case": "export_failure", "warning": fallback.joinWarning as Any? ?? NSNull(),
            "presented_is_first_only": fallback.presented == f1,
            "sources_exist": [f1,f2].map { fm.fileExists(atPath: $0.path) }])
        FileStore.documents = root

        let interleave = JoinProbe()
        let i1 = try copied("interleave-first.mov"), i2 = try copied("interleave-second.mov")
        interleave.tags = ["Kitchen"]
        interleave.begin([i1,i2])
        // handleFinished has set isJoining, but its unstructured Task has not
        // run yet. This deterministic actor ordering needs no sleep or mocked
        // exporter, and exercises the actual button predicate/action.
        let joiningAtPress = interleave.isJoining
        let disabledAtPress = interleave.recordDisabled
        if !disabledAtPress { interleave.pressRecord() }
        try await finish(interleave)
        results.append(["case":"record_while_joining", "joining_at_press":joiningAtPress,
            "record_disabled_at_press":disabledAtPress,"start_calls":interleave.camera.startCalls,
            "original_tags":1,"presented_tags":interleave.presentedTags.count])

        let bytes = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try bytes.write(to: root.appendingPathComponent("join-results.json"))
        print(String(decoding: bytes, as: UTF8.self))
    }
}
