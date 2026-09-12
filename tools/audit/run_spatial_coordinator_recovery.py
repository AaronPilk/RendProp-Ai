#!/usr/bin/env python3
"""Run actual spatial recovery method bodies with injected app/OS boundaries.

This is not a whole-coordinator or real background-daemon/device proof. The
selected methods are copied verbatim, source-hashed, compiled and executed;
only persistence, pump, auth and API/URLSession boundaries are fixture objects.
"""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[2]
    out = Path(tempfile.mkdtemp(prefix="rendprop-spatial-restart-", dir="/tmp"))
    upload = root / "apps/ios/Rendprop/Upload"
    network = root / "apps/ios/Rendprop/Networking"
    coordinator = upload / "SpatialUploadCoordinator.swift"
    production = coordinator.read_text()
    selected = ["func restartFailedFrame(", "func pause(jobID:", "func resume(jobID:", "func reconnect()",
                "private func owns(", "private func assertOwner(", "private func fail(", "private static func parse("]

    def declaration(source, needle):
        assert source.count(needle) == 1, needle
        start = source.index(needle)
        brace = source.index("{", start)
        level = 1
        end = brace + 1
        while level:
            if source[end] == "{": level += 1
            elif source[end] == "}": level -= 1
            end += 1
        return source[start:end]

    boundary = root / "tests/phase1/SpatialCoordinatorRecoveryBoundary.swift"
    actual = out / "ActualSpatialMethods.swift"
    methods = "\n\n".join(declaration(production, n) for n in selected)
    actual.write_text(boundary.read_text().replace("// ACTUAL_METHODS", methods))
    api = network / "APIClient.swift"
    source = api.read_text()
    models = out / "ActualUploadModels.swift"
    models.write_text("import Foundation\n" + source[source.index("struct UploadTicket:"):source.index("/// The org's plan")] +
        source[source.index("enum APIError:"):source.index("// MARK: - Admin console models")])
    files = [models, upload / "UploadRecovery.swift", upload / "DirectUploader.swift", upload / "DirectUploadJournal.swift",
             network / "SpatialModels.swift", upload / "SpatialUploadState.swift", actual,
             root / "tests/phase1/UploadRecoveryDependencies.swift", root / "tests/phase1/SpatialCoordinatorRecoveryTests.swift"]
    paths = [coordinator, boundary, api, *files]
    receipt = {"accepted": False, "commands": [], "selectedMethods": selected,
               "scope": "actual selected recovery methods; injected app/OS boundaries, no network or camera",
               "sourceHashes": {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}}
    print("EVIDENCE:", out, flush=True)

    def run(name, command, expected=0):
        result = subprocess.run(list(map(str, command)), cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, timeout=180)
        log = out / (name + ".log"); log.write_text(result.stdout)
        receipt["commands"].append({"name": name, "exit": result.returncode, "command": list(map(str, command)), "log": str(log)})
        assert (result.returncode == 0) == (expected == 0), str(log)
        print(f"{name}: exit={result.returncode}", flush=True)
        return result.stdout

    try:
        swift = ["/usr/bin/xcrun", "swiftc", "-swift-version", "5"]
        binary = out / "actual"
        run("compile-actual-methods", [*swift, *files, "-o", binary])
        output = run("actual-methods", [binary])
        match = re.fullmatch(r"PASS SpatialCoordinatorRecoveryTests (\d+) assertions\n", output)
        assert match and int(match[1]) >= 10
        receipt["assertions"] = int(match[1])
        mutations = [
            ("pause-cancels-write", "records[i].pausedByUser = true",
             "records[i].pausedByUser = true; session.getAllTasks { $0.forEach { $0.cancel() } }",
             "Spatial Pause does not interrupt an already dispatched JPEG"),
            ("forget-restart-intent", "if records[i].frames[index].restartIntent == nil {",
             "if true {", "Spatial lost reply uses one persisted restart UUID without fresh reserve"),
            ("completed-is-unsent", "replacement.uploaded == true ? .uploaded :",
             "false ? .uploaded :", "Spatial completion winner skips replacement and preserves receipt"),
        ]
        original = actual.read_text()
        for name, needle, replacement, failure in mutations:
            assert original.count(needle) == 1, name
            mutant = out / (name + ".swift"); mutant.write_text(original.replace(needle, replacement, 1))
            broken = out / name
            run("compile-" + name, [*swift, *[mutant if p == actual else p for p in files], "-o", broken])
            output = run("reject-" + name, [broken], expected=1)
            assert "FAIL " + failure in output
        run("restore-production", [binary])
        receipt["accepted"] = True
    finally:
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
