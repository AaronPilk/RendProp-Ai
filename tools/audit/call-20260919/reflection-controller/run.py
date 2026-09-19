#!/usr/bin/env python3
"""Run complete real reflection controller against controlled async boundaries.

No network, upload, provider, customer media, or application containers are used.
Video/API/upload implementations are doubles; controller and journal are real.
"""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[4]
HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", action="store_true")
    args = parser.parse_args()
    out = Path(tempfile.mkdtemp(prefix="rendprop-reflection-controller-"))
    source_path = HERE / "BaselineReflectionRemoval.swift" if args.baseline else ROOT / "apps/ios/Rendprop/Render/ReflectionRemoval.swift"
    api_path = ROOT / "apps/ios/Rendprop/Networking/ReflectionAPI.swift"
    controller = source_path.read_text().replace("private(set) ", "").replace("private ", "fileprivate ")
    if args.baseline:
        # Baseline had an unrelated Swift isolation compile error. This changes
        # only that annotation so its actual async behavior can be executed.
        controller = controller.replace("    static var directory: URL", "    nonisolated static var directory: URL")
    fixture = (HERE / "checks.swift").read_text()
    if args.baseline:
        before, rest = fixture.split("// FIXED_ONLY_START")
        _, after = rest.split("// FIXED_ONLY_END")
        fixture = before + after
    generated = out / "ControllerChecks.swift"
    generated.write_text(fixture.replace("// REAL_CONTROLLER", controller).replace("// REAL_API", api_path.read_text()))
    binary = out / "controller-checks"
    receipt = {"baseline": args.baseline, "sourceSHA256": {
        str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in [source_path, api_path, HERE / "checks.swift"]}, "commands": []}
    for label, command in [
        ("compile", ["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", generated, "-o", binary]),
        ("execute", [binary, out / "documents", "baseline" if args.baseline else "fixed"]),
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
