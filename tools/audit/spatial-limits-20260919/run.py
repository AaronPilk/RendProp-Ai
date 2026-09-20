#!/usr/bin/env python3
"""Offline native regression. Never reads app Documents or calls a provider.

Full production sources are snapshotted and hashed. The only substitutions are
AR hardware values, the capture-root filesystem boundary, and UIKit widgets.
Queue hooks are appended to the copied recorder without rewriting its methods.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
SOURCE = Path("tools/spatial-spike/capture-ios/Sources")
FILES = ["CaptureModel.swift", "CaptureQuality.swift", "CaptureControls.swift", "RasterWriter.swift", "CaptureArchive.swift", "CaptureRecorder.swift", "SpatialCaptureViewController.swift"]

def block(text, marker):
    start = text.index(marker)
    brace = text.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        if text[end] == "{": depth += 1
        elif text[end] == "}": depth -= 1
        end += 1
    return text[start:end]

def sha(data):
    return hashlib.sha256(data).hexdigest()

def run(command, log, timeout=240):
    with log.open("w") as stream:
        result = subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
    if result.returncode:
        print(log.read_text()[-14000:], flush=True)
        raise RuntimeError(f"Command failed ({result.returncode}); evidence: {log}")
    print(log.read_text()[-1500:], flush=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", default="1ed500931ef16b26c644c25be828a7227a8a5208")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--python", default="python3", help="Interpreter with Pillow for actual importer")
    parser.add_argument("--only", choices=["baseline", "fixed"])
    args = parser.parse_args()
    output = args.output or Path(tempfile.mkdtemp(prefix="rendprop-spatial-limits-"))
    output.mkdir(parents=True, exist_ok=True)
    print(f"Evidence: {output}", flush=True)
    module = output / "ARKitBoundary"
    module.mkdir(exist_ok=True)
    (output / "harness-hashes.json").write_text(json.dumps({str(path.relative_to(ROOT)): sha(path.read_bytes()) for path in sorted(HERE.iterdir()) if path.is_file()}, indent=2))
    run(["xcrun", "swiftc", "-swift-version", "5", "-emit-module", "-emit-library", "-module-name", "ARKit", str(HERE / "ARKitScaffold.swift"), "-o", str(module / "libARKit.dylib"), "-emit-module-path", str(module / "ARKit.swiftmodule")], output / "arkit-compile.log")
    receipts = {}
    for variant in [args.only] if args.only else ["baseline", "fixed"]:
        target = output / variant
        source_dir = target / "sources"
        source_dir.mkdir(parents=True, exist_ok=True)
        hashes = {}
        originals = {}
        for filename in FILES:
            relative = SOURCE / filename
            content = subprocess.check_output(["git", "show", f"{args.baseline}:{relative}"], cwd=ROOT) if variant == "baseline" else (ROOT / relative).read_bytes()
            originals[filename] = content.decode()
            hashes[str(relative)] = {"original_sha256": sha(content)}
            altered = content.decode()
            if filename == "CaptureArchive.swift":
                local = block(altered, "    static func local() throws -> CaptureArchive")
                altered = altered.replace(local, "    static func local() throws -> CaptureArchive { return CaptureArchive(root: HarnessFS.capturesRoot) }")
            if filename == "CaptureRecorder.swift":
                altered += "\n" + (HERE / "RecorderHooks.swift").read_text()
            (source_dir / filename).write_text(altered)
            hashes[str(relative)]["compiled_sha256"] = sha(altered.encode())
        (target / "source-hashes.json").write_text(json.dumps(hashes, indent=2))
        runtime = (HERE / "RecorderRuntime.swift").read_text()
        controller_template = HERE / "ControllerHarness.swift.template"
        if controller_template.exists():
            controller_source = originals["SpatialCaptureViewController.swift"]
            if variant == "fixed":
                completion = block(controller_source, "    private func captureFinished(")
                completion += "\n    func deliver(url: URL?, ready: Bool, reason: CaptureStopReason?) { captureFinished(url: url, message: \"Synthetic completion\", exportable: ready, stopReason: reason) }\n"
            else:
                closure = block(controller_source, "        recorder.onFinished =")
                closure = closure.replace("recorder.onFinished", "handler", 1)
                completion = "    var handler: ((URL?, String, Bool) -> Void)?\n    init() {\n" + closure + "\n    }\n    func deliver(url: URL?, ready: Bool) { handler?(url, \"Synthetic completion\", ready) }\n"
            methods = [block(controller_source, marker).replace("@objc ", "") for marker in ["    @objc private func exportTapped()", "    private func verifyAndExport(", "    private func refreshControls()"]]
            generated = controller_template.read_text().replace("/* ACTUAL_COMPLETION */", completion).replace("/* ACTUAL_EXPORT_METHODS */", "\n".join(methods))
            (source_dir / "ControllerHarness.swift").write_text(generated)
        (source_dir / "RecorderRuntime.swift").write_text(runtime)
        compiled = [str(source_dir / f) for f in FILES if f != "SpatialCaptureViewController.swift"] + [str(source_dir / "RecorderRuntime.swift")]
        if controller_template.exists(): compiled += [str(source_dir / "ControllerHarness.swift")]
        command = ["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", "-I", str(module), "-L", str(module), "-lARKit", "-Xlinker", "-rpath", "-Xlinker", str(module)]
        if variant == "fixed": command += ["-D", "FIXED"]
        if controller_template.exists(): command += ["-D", "CONTROLLER"]
        command += compiled + ["-o", str(target / "recorder")]
        run(command, target / "compile.log")
        run([str(target / "recorder"), str(target / "fixtures")], target / "runtime.log", timeout=180)
        receipt = json.loads((target / "fixtures/recorder.json").read_text())
        receipts[variant] = {"checks": len(receipt["checks"]), "scenarios": len(receipt["scenarios"]), "source_hashes": str(target / "source-hashes.json")}
        run([args.python, str(HERE / "importer.py"), str(ROOT / "tools/spatial-spike/training"), str(target / "fixtures/recorder.json"), variant, str(target / "importer.json")], target / "importer.log")
    if len(receipts) == 2:
        a = json.loads((output / "baseline/source-hashes.json").read_text())
        b = json.loads((output / "fixed/source-hashes.json").read_text())
        assert a[str(SOURCE / "RasterWriter.swift")]["original_sha256"] == b[str(SOURCE / "RasterWriter.swift")]["original_sha256"], "Full validator must remain unchanged"
    if "fixed" in receipts:
        hashes = json.loads((output / "fixed/source-hashes.json").read_text())
        for relative, digest in hashes.items():
            assert sha((ROOT / relative).read_bytes()) == digest["original_sha256"], f"Production changed during regression: {relative}"
    (output / "receipt.json").write_text(json.dumps(receipts, indent=2))
    print("PASS " + json.dumps(receipts), flush=True)

if __name__ == "__main__":
    main()
