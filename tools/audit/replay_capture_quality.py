#!/usr/bin/env python3
"""Read-only saved-capture replay of the actual native quality selector/sampler.

Customer pixels/poses are never copied into the repository or printed. Receipt
contains aggregate metrics and source hashes only. The JPEG->gray conversion is
not ARKit's original luma plane, so this cannot prove phone camera calibration.
"""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("capture", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    source = root / "tools/spatial-spike/capture-ios/Sources/CaptureQuality.swift"
    recorder = root / "tools/spatial-spike/capture-ios/Sources/CaptureRecorder.swift"
    replay = root / "tools/spatial-spike/capture-ios/Tests/QualityReplay.swift"
    out = Path(tempfile.mkdtemp(prefix="rendprop-quality-replay-"))
    receipt = {"accepted": False, "camera_acceptance": False, "commands": [], "sourceHashes": {
        str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in [source, recorder, replay]}}
    print(f"EVIDENCE: {out}", flush=True)
    try:
        text = recorder.read_text()
        marker = "    private static func qualityMeasurement(_ buffer: CVPixelBuffer)"
        assert text.count(marker) == 1
        start = text.index(marker); opening = text.index("{", start)
        depth = 1; end = opening + 1
        while depth:
            depth += (text[end] == "{") - (text[end] == "}")
            end += 1
        bridge = out / "CapturedQualityBridge.swift"
        bridge.write_text("import Foundation\nimport CoreVideo\nenum CapturedQualityBridge {\n" + text[start:end] +
            "\nstatic func measure(_ buffer: CVPixelBuffer) -> CaptureQualitySelector.Measurement? { qualityMeasurement(buffer) }\n}\n")
        binary = out / "replay"
        commands = [("compile", ["/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-warnings-as-errors", source, bridge, replay, "-o", binary]),
                    ("replay", [binary, args.capture.resolve()])]
        for name, cmd in commands:
            result = subprocess.run(list(map(str, cmd)), text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=240)
            log = out / f"{name}.log"; log.write_text(result.stdout)
            receipt["commands"].append({"name": name, "exit": result.returncode, "log": str(log)})
            assert result.returncode == 0, f"{name} failed: {log}"
            if name == "replay":
                receipt["aggregate"] = json.loads(result.stdout)
                assert receipt["aggregate"]["frames"] >= 20
                print(result.stdout, end="")
        receipt["accepted"] = True
    finally:
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
