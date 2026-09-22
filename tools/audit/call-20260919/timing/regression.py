#!/usr/bin/env python3
"""Compile actual repaired timing functions; generated media/clock inputs only."""
from pathlib import Path
import hashlib
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[4]
HERE = Path(__file__).resolve().parent


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
    out = Path(tempfile.mkdtemp(prefix="rendprop-call-timing-fixed-"))
    paths = [ROOT / f"apps/ios/Rendprop/Capture/{name}.swift" for name in ["CameraManager", "MotionRecorder"]]
    camera, motion = [p.read_text() for p in paths]
    methods = [block(camera, marker) for marker in [
        "private struct DetectionContext", "var currentRecordedSeconds: TimeInterval",
        "var hasTakeInProgress: Bool", "private var remainingSeconds: TimeInterval",
        "func resumeRecording()", "private func beginSegment()", "private func deliverTake()",
        "private func publishDetectionContext()", "private func setPersonDetectionAvailable(_ available: Bool)",
        "fileprivate func ingestPersonSample(_ found: Bool,", "fileprivate func closePersonRange(at end: Double)",
        "private func detectPeople(in pixelBuffer: CVPixelBuffer,", "func captureOutput(_ output: AVCaptureOutput,",
    ]]
    functions = "\n".join(methods).replace("fileprivate ", "").replace("private ", "")
    motion = motion.replace("import CoreMotion", "import Combine").replace("private ", "fileprivate ")
    program = (HERE / "fixed_checks.swift").read_text().replace("// CAMERA_METHODS", functions)
    program = program.replace("// NORMALIZER", block(camera, "enum PersonRangeTimeline"))
    program = program.replace("// MOTION_SOURCE", motion)
    generated = out / "FixedChecks.swift"
    generated.write_text(program)
    binary = out / "fixed-checks"
    receipt = {"sourceSHA256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in [*paths, HERE / "fixed_checks.swift"]}, "commands": []}
    for label, command in [
        ("compile", ["xcrun", "swiftc", "-swift-version", "5", generated, "-o", binary]),
        ("execute", [binary]),
    ]:
        result = subprocess.run(list(map(str, command)), cwd=ROOT, capture_output=True, text=True, timeout=120)
        (out / f"{label}.log").write_text(result.stdout + result.stderr)
        receipt["commands"].append({"label": label, "exit": result.returncode})
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        if result.returncode:
            print(result.stdout + result.stderr)
            raise RuntimeError(f"{label} failed: {out}")
        if label == "execute": receipt["result"] = json.loads(result.stdout)
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({"evidence": str(out), **receipt["result"]}, indent=2))


if __name__ == "__main__": main()
