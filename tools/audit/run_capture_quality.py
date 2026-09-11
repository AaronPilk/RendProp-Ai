#!/usr/bin/env python3
"""Native pure capture selection checks with compiled failing source mutants.

Does not simulate AR, rent compute, upload images or touch an app container.
Phone calibration and real-room reconstruction quality remain device evidence.
"""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[2]
    out = Path(tempfile.mkdtemp(prefix="rendprop-capture-quality-"))
    source = root / "tools/spatial-spike/capture-ios/Sources/CaptureQuality.swift"
    test = root / "tools/spatial-spike/capture-ios/Tests/QualityChecks.swift"
    recorder = root / "tools/spatial-spike/capture-ios/Sources/CaptureRecorder.swift"
    raster_test = root / "tools/spatial-spike/capture-ios/Tests/QualityRasterChecks.swift"
    receipt = {"accepted": False, "commands": [], "sourceHashes": {
        str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in [source, test, recorder, raster_test]}}
    print(f"EVIDENCE: {out}", flush=True)

    def run(label, cmd, failure=None):
        result = subprocess.run(list(map(str, cmd)), cwd=root, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=180)
        log = out / f"{label}.log"; log.write_text(result.stdout)
        receipt["commands"].append({"name": label, "command": list(map(str, cmd)), "exit": result.returncode, "log": str(log)})
        if failure is None:
            assert result.returncode == 0, f"{label} failed: {log}"
        else:
            assert result.returncode != 0 and failure in result.stdout, f"{label} failed for wrong reason: {log}"
        print(f"{label}: exit={result.returncode}", flush=True)
        return result.stdout

    try:
        # Mandatory landing gate; this is supplemental to executing the actual
        # selector below, never a replacement for it or a claim about a camera.
        assert "quality.evaluate(Self.qualityMeasurement(buffer), pose: measuredPose)" in recorder.read_text()
        assert "camera_to_world: measuredPose" in recorder.read_text()
        assert "rasterWriter.write(buffer, resolution: size" in recorder.read_text()
        swift = ["/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-warnings-as-errors"]
        binary = out / "quality-tests"
        run("compile-real-selector", [*swift, source, test, "-o", binary])
        output = run("real-selector", [binary])
        match = re.fullmatch(r"PASS QualityChecks (\d+) assertions\n", output)
        assert match and int(match[1]) >= 28, "Expected checks did not run"
        receipt["assertions"] = int(match[1])
        # ARSession does not exist on macOS, but its sampling function uses only
        # CoreVideo. Extract those exact bytes and execute them on real native
        # pixel buffers, without copying/reimplementing the algorithm in a test.
        text = recorder.read_text()
        marker = "    private static func qualityMeasurement(_ buffer: CVPixelBuffer)"
        assert text.count(marker) == 1
        start = text.index(marker); opening = text.index("{", start)
        depth = 1; end = opening + 1
        while depth:
            depth += (text[end] == "{") - (text[end] == "}")
            end += 1
        function = text[start:end]
        bridge = out / "CapturedQualityBridge.swift"
        bridge.write_text("import Foundation\nimport CoreVideo\nenum CapturedQualityBridge {\n" + function +
            "\nstatic func measure(_ buffer: CVPixelBuffer) -> CaptureQualitySelector.Measurement? { qualityMeasurement(buffer) }\n}\n")
        raster_binary = out / "quality-raster-tests"
        run("compile-real-corevideo-sampler", [*swift, source, bridge, raster_test, "-o", raster_binary])
        output = run("real-corevideo-sampler", [raster_binary])
        match = re.fullmatch(r"PASS QualityRasterChecks (\d+) assertions\n", output)
        assert match and int(match[1]) >= 10, "Native raster checks did not run"
        receipt["nativeRasterAssertions"] = int(match[1])
        for label, needle, replacement, failure in [
            ("blur", "if !lowTexture && measurement.laplacianVariance < Self.minimumLaplacianVariance", "if false",
             "Blurred frame must be skipped before advancing baseline"),
            ("baseline", "if translation < Self.minimumTranslationMetres && angle < Self.minimumRotationDegrees", "if false",
             "Stationary duplicate must be skipped")]:
            text = source.read_text(); assert text.count(needle) == 1
            mutant = out / f"Quality-{label}.swift"; mutant.write_text(text.replace(needle, replacement))
            broken = out / f"quality-{label}-mutant"
            # The mutation leaves computed values intentionally unused. That
            # compile warning is irrelevant; runtime must reject the behavior.
            run(f"compile-{label}-mutant", ["/usr/bin/xcrun", "swiftc", "-swift-version", "5", mutant, test, "-o", broken])
            run(f"reject-{label}-mutant", [broken], failure=failure)
        run("restore-real-selector", [binary])
        receipt["accepted"] = True
    finally:
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
