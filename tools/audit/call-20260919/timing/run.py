#!/usr/bin/env python3
"""Execute repository timing functions on generated inputs, without a camera.

Only framework boundaries are faked: monotonic time, CoreMotion delivery,
AVCapture output duration, and Vision's detections. CoreVideo sampling and all
range/motion arithmetic are the repository's actual Swift source. No media,
provider calls, app containers, or application source edits are involved.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[4]
HERE = Path(__file__).resolve().parent
OUT = Path(tempfile.mkdtemp(prefix="rendprop-call-timing-20260919-"))


def member(source, marker):
    assert source.count(marker) == 1, marker
    start = source.index(marker)
    opening = source.index("{", start)
    end, depth = opening + 1, 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--revision", default="7bcc624", help="Git revision whose defects to reproduce")
    args = parser.parse_args()
    def read_source(path):
        return subprocess.check_output(["git", "show", f"{args.revision}:{path.relative_to(ROOT)}"],
                                       cwd=ROOT, text=True)
    camera_path = ROOT / "apps/ios/Rendprop/Capture/CameraManager.swift"
    motion_path = ROOT / "apps/ios/Rendprop/Capture/MotionRecorder.swift"
    view_path = ROOT / "apps/ios/Rendprop/Capture/CaptureView.swift"
    camera = read_source(camera_path)
    motion = read_source(motion_path)
    view = read_source(view_path)
    assert "motion.pauseLogging()\n                camera.pauseRecording()" in view
    assert view.index("let joined = await TakeJoiner.join(urls)") < view.index("let sidecar = motion.endLogging")
    methods = [member(camera, marker) for marker in [
        "var currentRecordedSeconds: TimeInterval",
        "var hasTakeInProgress: Bool",
        "fileprivate func ingestPersonSample(_ found: Bool)",
        "fileprivate func closePersonRange(at end: Double)",
        "private func detectPeople(in pixelBuffer: CVPixelBuffer)",
        "func captureOutput(_ output: AVCaptureOutput,",
    ]]
    # Access modifiers only; function bodies stay byte-identical.
    extracted = "\n".join(methods).replace("fileprivate ", "").replace("private ", "")
    motion_adapted = motion.replace("import CoreMotion", "import Combine")
    assert motion_adapted.count("ProcessInfo.processInfo.systemUptime") == 3
    motion_adapted = motion_adapted.replace("ProcessInfo.processInfo.systemUptime", "AuditClock.now")
    motion_adapted = motion_adapted.replace("private ", "fileprivate ")
    swift = HERE / "checks.swift"
    program = swift.read_text().replace("// INSERT_ACTUAL_CAMERA_METHODS", extracted)
    program = program.replace("// INSERT_ACTUAL_MOTION_SOURCE", motion_adapted)
    generated = OUT / "TimingChecks.swift"
    generated.write_text(program)
    binary = OUT / "timing-checks"
    commands = []
    for label, command in [
        ("compile", ["xcrun", "swiftc", "-swift-version", "5", generated, "-o", binary]),
        ("execute", [binary]),
    ]:
        result = subprocess.run(list(map(str, command)), cwd=ROOT, capture_output=True, text=True, timeout=120)
        (OUT / f"{label}.log").write_text(result.stdout + result.stderr)
        commands.append({"label": label, "command": list(map(str, command)), "exit": result.returncode})
        if result.returncode:
            print(result.stdout + result.stderr)
            raise RuntimeError(f"{label} failed: {OUT}")
    result = json.loads((OUT / "execute.log").read_text())
    sanitized = OUT / "timing-checks-tsan"
    compile_tsan = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-g", "-sanitize=thread",
                                   str(generated), "-o", str(sanitized)],
                                  cwd=ROOT, capture_output=True, text=True, timeout=120)
    (OUT / "compile-tsan.log").write_text(compile_tsan.stdout + compile_tsan.stderr)
    assert compile_tsan.returncode == 0, f"TSAN compile failed: {OUT}"
    race = subprocess.run([str(sanitized), "--thermal-race"], cwd=ROOT,
                          env={**os.environ, "TSAN_OPTIONS": "halt_on_error=1"},
                          capture_output=True, text=True, timeout=120)
    (OUT / "thermal-race.log").write_text(race.stdout + race.stderr)
    result["thermalMessageThreadSanitizer"] = {
        "exit": race.returncode, "raceDetected": "ThreadSanitizer: data race" in race.stderr,
        "log": str(OUT / "thermal-race.log")}
    receipt = {"scope": "offline-extracted-real-functions; framework outputs are controlled fixtures",
               "revision": args.revision,
               "sourceSHA256": {str(p.relative_to(ROOT)): hashlib.sha256(read_source(p).encode()).hexdigest()
                                for p in [camera_path, motion_path, view_path]},
               "commands": commands, "result": result}
    receipt["sourceSHA256"][str(swift.relative_to(ROOT))] = hashlib.sha256(swift.read_bytes()).hexdigest()
    (OUT / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({"evidence": str(OUT), **result}, indent=2))


if __name__ == "__main__":
    main()
