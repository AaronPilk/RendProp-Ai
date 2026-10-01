#!/usr/bin/env python3
"""Execute shipped capture lifecycle functions against offline hardware doubles.

Function bodies are extracted byte-for-byte from the checkout, not reimplemented.
The doubles control storage, session availability and the recording-output clock.
This does not prove physical camera notification timing or thermal performance.
"""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[4]
CAMERA = ROOT / "apps/ios/Rendprop/Capture/CameraManager.swift"
IMPORTER = ROOT / "apps/ios/Rendprop/Import/MediaImporter.swift"


def block(text, marker):
    assert text.count(marker) == 1, marker
    start = text.index(marker)
    opening = text.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


def main():
    out = Path(tempfile.mkdtemp(prefix="rendprop-call-lifecycle-"))
    parser = argparse.ArgumentParser()
    parser.add_argument('--revision', default='7bcc624', help='Git revision whose defects to reproduce')
    args = parser.parse_args()
    def read(path):
        return subprocess.check_output(['git', 'show', f'{args.revision}:{path.relative_to(ROOT)}'], cwd=ROOT, text=True)
    camera, importer = read(CAMERA), read(IMPORTER)
    functions = [block(camera, m) for m in [
        "    private var remainingSeconds:",
        "    func resumeRecording()",
        "    private func beginSegment()",
    ]]
    imported = [block(importer, m) for m in [
        "    struct ProbeResult", "    enum ImportError", "    private static func validate(",
    ]]
    swift = r'''
import Foundation
import AVFoundation

enum Haptics { static var warnings = 0; static func warning() { warnings += 1 } }
enum Formatters { static func bytes(_ value: Int64) -> String { String(value) } }
enum FileStore {
    static var free: Int64 = 1_000_000_000
    static func freeSpaceBytes() -> Int64 { free }
    static func newRecordingURL() -> URL { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".mov") }
    static func fileSize(_ url: URL) -> Int64 { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0 }
}
final class SessionDouble { var isRunning = true }
final class QueueDouble { func async(execute: () -> Void) { execute() } }
final class OutputDouble {
    var maxRecordedDuration = CMTime.zero
    var recordedDuration = CMTime.zero
    var starts = 0
    func startRecording(to: URL, recordingDelegate: AnyObject) { starts += 1 }
}
final class Lifecycle {
    enum CaptureState { case ready, recording, paused, finalizing }
    enum SegmentEnd { case finish }
    static let maxRecordingSeconds: Double = 600
    var state = CaptureState.paused
    let session = SessionDouble()
    let sessionQueue = QueueDouble()
    let movieOutput = OutputDouble()
    var pendingEnd = SegmentEnd.finish
    var bankedSeconds: Double = 0
    var elapsed: Double = 0
    var storageMessage: String?
    var interruptionMessage: String?
    var recordTimer: Timer?
    deinit { recordTimer?.invalidate() }
__LIFECYCLE__
}
enum MediaImporter {
    static let maxDurationSeconds: Double = 600
    static let minDurationSeconds: Double = 0.2
__IMPORTER__
    static func check(duration: Double, at url: URL) throws {
        var probe = ProbeResult()
        probe.duration = duration; probe.hasVideoTrack = true
        probe.width = 320; probe.height = 240
        try validate(probe, at: url)
    }
}

@main struct Checks {
    static func main() throws {
        var results: [[String: Any]] = []
        let stopped = Lifecycle()
        stopped.session.isRunning = false
        stopped.resumeRecording()
        precondition(stopped.state == .paused && stopped.movieOutput.starts == 0)
        let silent = stopped.storageMessage == nil && stopped.interruptionMessage == nil && Haptics.warnings == 0
        precondition(silent, "Expected shipped silent-resume defect was not reproduced")
        results.append(["case":"resume_session_stopped", "reproduced":silent, "starts":stopped.movieOutput.starts, "visible_feedback":false])

        let lowStorage = Lifecycle()
        FileStore.free = 10
        lowStorage.resumeRecording()
        precondition(lowStorage.storageMessage != nil && lowStorage.movieOutput.starts == 0)
        results.append(["case":"low_storage_control", "visible_feedback":true])
        FileStore.free = 1_000_000_000

        let marker = URL(fileURLWithPath: CommandLine.arguments[1])
        try Data([1]).write(to: marker)
        defer { try? FileManager.default.removeItem(at: marker) }
        for banked in [599.25, 599.75, 600.0] {
            let take = Lifecycle()
            take.bankedSeconds = banked
            take.resumeRecording()
            let cap = take.movieOutput.maxRecordedDuration.seconds
            let total = banked + cap
            precondition(take.movieOutput.starts == 1 && cap == 1 && total > 600)
            var rejected = false
            do { try MediaImporter.check(duration: total, at: marker) }
            catch MediaImporter.ImportError.tooLong(let seconds) { rejected = seconds == total }
            precondition(rejected, "Actual import validation must reject the permitted take length")
            take.recordTimer?.invalidate()
            results.append(["case":"resume_near_take_cap", "banked_s":banked, "permitted_next_s":cap, "permitted_total_s":total, "import_rejects":rejected])
        }
        print(String(data: try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted,.sortedKeys]), encoding: .utf8)!)
    }
}
'''.replace("__LIFECYCLE__", "\n".join(functions)).replace("__IMPORTER__", "\n".join(imported))
    source, binary = out / "ExtractedLifecycle.swift", out / "lifecycle"
    source.write_text(swift)
    receipt = {"source_sha256": {str(p.relative_to(ROOT)): hashlib.sha256(read(p).encode()).hexdigest()
               for p in [CAMERA, IMPORTER]}, "scope": "real extracted Swift functions; deterministic offline session/storage/output doubles", "commands": []}
    print(f"EVIDENCE: {out}", flush=True)
    for name, command in [
        ("compile", ["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", str(source), "-o", str(binary)]),
        ("execute", [str(binary), str(out / "synthetic-probe-marker")]),
    ]:
        r = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
        (out / f"{name}.log").write_text(r.stdout)
        receipt["commands"].append({"name": name, "exit": r.returncode, "command": command})
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(f"{name}: {r.returncode}", flush=True)
        if r.returncode:
            print(r.stdout[-5000:])
            raise SystemExit(r.returncode)
        if name == "execute":
            receipt["results"] = json.loads(r.stdout)
            print(r.stdout)
    receipt["completed"] = True
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
