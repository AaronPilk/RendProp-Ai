import Foundation
import ARKit
import CoreVideo
import simd
import CryptoKit

enum HarnessFS {
    static let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    static var capturesRoot = root.appendingPathComponent("Captures", isDirectory: true)
}

@MainActor enum Checks {
    static var rows: [[String: Any]] = []
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        let passed = try value()
        rows.append(["check": message, "passed": passed])
        guard passed else { throw CaptureError.invalid(message) }
    }
    static func wait(_ message: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        try check(predicate(), message)
    }
}

@MainActor final class Scenario {
    let recorder = CaptureRecorder()
    let name: String
    var root: URL!
    var completions: [(url: URL?, message: String, ready: Bool, reason: String?)] = []
    init(_ name: String) { self.name = name }
    func start() async throws {
        #if FIXED
        recorder.onFinished = { [weak self] url, message, ready, reason in
            self?.completions.append((url, message, ready, reason?.rawValue))
        }
        #else
        recorder.onFinished = { [weak self] url, message, ready in
            self?.completions.append((url, message, ready, nil))
        }
        #endif
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            recorder.start(deviceModel: "Synthetic hardware boundary", operatingSystem: "native macOS regression") {
                continuation.resume(with: $0)
            }
        }
        root = recorder.auditState().root!
    }
    func fill(_ count: Int, pixel: CVPixelBuffer) throws {
        for i in 1...count {
            recorder.auditSend(try Fixture.frame(i, pixel: pixel))
            recorder.auditDrain()
        }
        let manifest = try manifest()
        try Checks.check(manifest.frames.count == count, "\(name): actual writer committed \(count) frames")
    }
    func finished() async throws {
        recorder.auditDrain()
        try await Checks.wait("\(name): exactly one completion arrives after drain") { self.completions.count == 1 }
    }
    func manifest() throws -> CaptureManifest {
        try JSONDecoder().decode(CaptureManifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
    }
    func manifestJSON() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as! [String: Any]
    }
    func hashes() throws -> [String: String] {
        var result: [String: String] = [:]
        for directory in ["images", "frames"] {
            for item in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil) {
                let props = try item.resourceValues(forKeys: [.isRegularFileKey])
                if props.isRegularFile == true {
                    result[directory + "/" + item.lastPathComponent] = SHA256.hash(data: try Data(contentsOf: item)).map { String(format: "%02x", $0) }.joined()
                }
            }
        }
        return result
    }
    func retains(_ before: [String: String]) throws {
        let after = try hashes()
        try Checks.check(before.allSatisfy { after[$0.key] == $0.value }, "\(name): every previously durable original remains unchanged")
    }
    func result() throws -> [String: Any] {
        let m = try manifestJSON()
        return ["name": name, "root": root.path, "manifest": m,
                "completionReady": completions.first?.ready ?? false,
                "completionReason": completions.first?.reason as Any? ?? NSNull(),
                "fileHashes": try hashes()]
    }
}

enum Fixture {
    static func pixel() throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 80, 60, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                 [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result) == kCVReturnSuccess,
              let pixel = result else { throw CaptureError.invalid("Synthetic NV12 allocation failed") }
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(pixel) {
            let base = CVPixelBufferGetBaseAddressOfPlane(pixel, plane)!.assumingMemoryBound(to: UInt8.self)
            let height = CVPixelBufferGetHeightOfPlane(pixel, plane)
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixel, plane)
            for y in 0..<height { for x in 0..<rowBytes {
                base[y * rowBytes + x] = plane == 0 ? ((x / 8 + y / 8) % 2 == 0 ? 40 : 210) : 128
            } }
        }
        return pixel
    }
    static func frame(_ index: Int, timestamp: Double? = nil, pixel: CVPixelBuffer) throws -> ARFrame {
        var pose = matrix_identity_float4x4
        let angle = Double(index - 1) * 0.15
        pose.columns.3 = SIMD4(Float(0.5 * cos(angle)), Float(0.5 * sin(angle)), 0, 1)
        let k = simd_float3x3(columns: (SIMD3(60, 0, 0), SIMD3(0, 60, 0), SIMD3(40, 30, 1)))
        var points: [SIMD3<Float>] = []
        for i in 0..<100 {
            let x: Float = Float((i % 10) - 5) * 0.06
            let y: Float = Float((i / 10) - 5) * 0.06
            points.append(SIMD3<Float>(x, y, -2))
        }
        let cloud = ARPointCloud(points: points, identifiers: (0..<100).map { UInt64.max - UInt64($0) })
        return ARFrame(timestamp: timestamp ?? Double(index - 1) * 0.5,
                       camera: ARCamera(transform: pose, intrinsics: k, imageResolution: CGSize(width: 80, height: 60)),
                       capturedImage: pixel, cloud: cloud)
    }
}

@main enum RecorderRuntime {
    @MainActor static func main() async {
        do {
            try FileManager.default.createDirectory(at: HarnessFS.root, withIntermediateDirectories: true)
            let pixel = try Fixture.pixel()
            var results: [[String: Any]] = []

            // Real 400th admission while its JPEG/sidecar write remains queued.
            let frameCap = Scenario("frame-limit-pending-write")
            try await frameCap.start(); try frameCap.fill(399, pixel: pixel)
            let frameOriginals = try frameCap.hashes()
            let release400 = frameCap.recorder.auditBlockWriter()
            frameCap.recorder.auditSend(try Fixture.frame(400, pixel: pixel))
            try Checks.check(frameCap.recorder.auditState().admitted == 400, "frame cap admits the 400th frame")
            frameCap.recorder.auditSend(try Fixture.frame(401, pixel: pixel))
            try Checks.check(!frameCap.recorder.auditState().active, "frame cap closes admission immediately")
            try Checks.check(frameCap.completions.isEmpty && (try frameCap.manifest()).frames.count == 399,
                             "frame cap cannot complete while final JPEG/sidecar is pending")
            frameCap.recorder.auditInterrupt()
            frameCap.recorder.auditSend(try Fixture.frame(402, pixel: pixel))
            release400.signal(); try await frameCap.finished()
            let frameManifest = try frameCap.manifest()
            try Checks.check(frameManifest.frames.count == 400, "frame cap drains and keeps all 400 frame pairs")
            try Checks.check(!FileManager.default.fileExists(atPath: frameCap.root.appendingPathComponent("images/000401.jpg").path), "frame cap never writes a 401st image")
            #if FIXED
            try Checks.check(frameManifest.status == "complete" && frameCap.completions[0].ready && frameCap.completions[0].reason == "frame_limit", "fixed frame limit is complete, validated and explicitly labelled")
            _ = try CaptureArchive.local().validateForExport(id: frameCap.root.lastPathComponent)
            #else
            try Checks.check(frameManifest.status == "limit_reached" && !frameCap.completions[0].ready, "baseline reproduces 400 valid pairs made unexportable by limit_reached")
            try Checks.check((try? CaptureArchive.local().validateForExport(id: frameCap.root.lastPathComponent)) == nil, "baseline archive also refuses automatic cap")
            #endif
            try frameCap.retains(frameOriginals); results.append(try frameCap.result())

            // Just-below duration boundary is admitted; 600.0 is not.
            let duration = Scenario("duration-limit-pending-write")
            try await duration.start(); try duration.fill(20, pixel: pixel)
            let durationOriginals = try duration.hashes()
            let releaseDuration = duration.recorder.auditBlockWriter()
            duration.recorder.auditSend(try Fixture.frame(21, timestamp: 599.999, pixel: pixel))
            duration.recorder.auditSend(try Fixture.frame(22, timestamp: 600, pixel: pixel))
            try Checks.check(!duration.recorder.auditState().active && duration.recorder.auditState().admitted == 21, "duration boundary excludes the frame at exactly 600 seconds")
            try Checks.check(duration.completions.isEmpty, "duration cap waits for the admitted last write")
            releaseDuration.signal(); try await duration.finished()
            #if FIXED
            try Checks.check(duration.completions[0].ready && duration.completions[0].reason == "duration_limit", "valid duration cap is exportable with explicit stop reason")
            #else
            try Checks.check(!duration.completions[0].ready && (try duration.manifest()).status == "limit_reached", "baseline reproduces duration cap made unexportable")
            #endif
            try duration.retains(durationOriginals); results.append(try duration.result())

            for mode in ["write-failure", "corrupt-last-image", "short", "interrupted", "failed", "manual"] {
                let sample = Scenario(mode)
                try await sample.start()
                let initial = (mode == "short" || mode == "write-failure" || mode == "corrupt-last-image") ? 19 : 20
                try sample.fill(initial, pixel: pixel)
                let originals = try sample.hashes()
                if mode == "write-failure" || mode == "corrupt-last-image" {
                    let release = sample.recorder.auditBlockWriter()
                    if mode == "write-failure" {
                        try FileManager.default.createDirectory(at: sample.root.appendingPathComponent("images/000020.jpg"), withIntermediateDirectories: false)
                    }
                    sample.recorder.auditSend(try Fixture.frame(20, pixel: pixel))
                    if mode == "corrupt-last-image" {
                        let corruptURL = sample.root.appendingPathComponent("images/000020.jpg")
                        sample.recorder.auditWriterAction {
                            try! Data("synthetic corrupt JPEG".utf8).write(to: corruptURL)
                        }
                    }
                    sample.recorder.auditSend(try Fixture.frame(21, timestamp: 600, pixel: pixel))
                    release.signal()
                } else if mode == "short" {
                    sample.recorder.auditSend(try Fixture.frame(20, timestamp: 600, pixel: pixel))
                } else if mode == "interrupted" { sample.recorder.auditInterrupt() }
                else if mode == "failed" { sample.recorder.auditFail() }
                else { sample.recorder.finish() }
                try await sample.finished()
                let manifest = try sample.manifest()
                if mode == "manual" {
                    try Checks.check(sample.completions[0].ready && manifest.status == "complete" && sample.completions[0].reason == nil, "manual stop remains valid without a cap reason")
                } else {
                    try Checks.check(!sample.completions[0].ready, "\(mode): not exportable")
                    try Checks.check((try? CaptureArchive.local().validateForExport(id: sample.root.lastPathComponent)) == nil, "\(mode): full archive revalidation also refuses export")
                }
                if mode == "write-failure" || mode == "failed" { try Checks.check(manifest.status == "failed", "\(mode): genuine failure is never promoted to complete") }
                if mode == "interrupted" { try Checks.check(manifest.status == "interrupted", "interruption remains explicitly interrupted") }
                try sample.retains(originals); results.append(try sample.result())
            }
            #if FIXED
            for (name, timestamp) in [("nan-clock", Double.nan), ("infinite-clock", Double.infinity), ("backward-clock", -1.0)] {
                let sample = Scenario(name)
                try await sample.start(); try sample.fill(20, pixel: pixel)
                let originals = try sample.hashes()
                sample.recorder.auditSend(try Fixture.frame(21, timestamp: timestamp, pixel: pixel))
                try await sample.finished()
                try Checks.check(!sample.completions[0].ready && sample.completions[0].reason == nil && (try sample.manifest()).status == "failed", "\(name): invalid clock fails closed without a normal cap reason")
                try sample.retains(originals); results.append(try sample.result())
            }
            #endif
            // Source-created archives also round-trip through the real archive index.
            let archive = try CaptureArchive.local()
            let page = try archive.page(offset: 0)
            try Checks.check(page.entries.count == results.count, "every successful, failed and short attempt remains in the archive")
            #if CONTROLLER
            try await ControllerRegression.run(frameCap: frameCap, duration: duration, results: results)
            #endif
            let receipt: [String: Any] = ["checks": Checks.rows, "scenarios": results]
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: HarnessFS.root.appendingPathComponent("recorder.json"))
            print("PASS actual CaptureRecorder: \(Checks.rows.count) checks, \(results.count) preserved synthetic attempts")
        } catch {
            let receipt: [String: Any] = ["checks": Checks.rows, "error": error.localizedDescription]
            try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: HarnessFS.root.appendingPathComponent("recorder-failure.json"))
            fputs("FAIL \(error)\n", stderr); exit(1)
        }
    }
}
