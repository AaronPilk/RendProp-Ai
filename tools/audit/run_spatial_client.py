#!/usr/bin/env python3
"""Execute actual client model/journal tests and targeted failing source mutants.

No network, camera, app container, Apple or provider calls. The iOS full-app
build and background delivery on device remain separate acceptance evidence.
"""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[2]
    out = Path(tempfile.mkdtemp(prefix="rendprop-spatial-client-"))
    models = root / "apps/ios/Rendprop/Networking/SpatialModels.swift"
    state = root / "apps/ios/Rendprop/Upload/SpatialUploadState.swift"
    recovery = root / "apps/ios/Rendprop/Upload/SpatialUploadRecovery.swift"
    tests = root / "tests/phase1/SpatialClientTests.swift"
    paths = [models, state, recovery, tests]
    receipt = {"accepted": False, "commands": [], "sourceHashes": {
        str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}}
    print(f"EVIDENCE: {out}", flush=True)

    def run(name, command, expected=0):
        result = subprocess.run([str(x) for x in command], cwd=root, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
        log = out / f"{name}.log"
        log.write_text(result.stdout)
        receipt["commands"].append({"name": name, "exit": result.returncode,
            "command": list(map(str, command)), "log": str(log)})
        assert (result.returncode == 0) == (expected == 0), f"{name}: unexpected exit {result.returncode}; {log}"
        print(f"{name}: exit={result.returncode}", flush=True)
        return result.stdout

    try:
        assert "enum SpatialJSON" in models.read_text()
        assert "struct SpatialUploadRecord" in state.read_text()
        swift = ["/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-warnings-as-errors"]
        binary = out / "spatial-tests"
        run("compile", [*swift, models, state, recovery, tests, "-o", binary])
        output = run("actual-production-models", [binary])
        match = re.fullmatch(r"PASS SpatialClientTests (\d+) assertions\n", output)
        assert match and int(match[1]) >= 30, "Tests did not execute expected assertions"
        receipt["assertions"] = int(match[1])

        # Real-source mutation controls. Both compile successfully; a runtime
        # test failure, not a compiler typo, must catch each broken invariant.
        mutant = out / "SpatialModels-no-privacy-gate.swift"
        text = models.read_text()
        needle = "if shareURL != nil, status != .ready || privacyState != .approved"
        assert text.count(needle) == 1
        mutant.write_text(text.replace(needle, "if false"))
        broken = out / "broken-privacy"
        run("compile-privacy-mutant", [*swift, mutant, state, recovery, tests, "-o", broken])
        failure = run("reject-privacy-mutant", [broken], expected=1)
        assert "Nonapproved artifacts cannot expose share links" in failure, "Wrong failure in privacy control"
        mutant = out / "SpatialUploadState-premature-progress.swift"
        text = state.read_text()
        assert text.count("$0.phase == .attached") == 2
        mutant.write_text(text.replace("$0.phase == .attached", "$0.phase == .sending"))
        broken = out / "broken-progress"
        run("compile-progress-mutant", [*swift, models, mutant, recovery, tests, "-o", broken])
        failure = run("reject-progress-mutant", [broken], expected=1)
        assert "An OS dispatched PUT is not server completion" in failure, "Wrong failure in progress control"
        mutant = out / "SpatialUploadState-stale-task.swift"
        text = state.read_text()
        needle = "frames.indices.contains(index), frames[index].taskID == taskID,"
        assert text.count(needle) == 1
        mutant.write_text(text.replace(needle, "frames.indices.contains(index),"))
        broken = out / "broken-task-fence"
        run("compile-task-fence-mutant", [*swift, models, mutant, recovery, tests, "-o", broken])
        failure = run("reject-task-fence-mutant", [broken], expected=1)
        assert "Stale task callback cannot finish a replacement" in failure, "Wrong failure in task control"
        mutant = out / "SpatialModels-no-render-revision.swift"
        text = models.read_text()
        needle = 'let artifact = body["artifact_revision"] as? String, UUID(uuidString: artifact) == revision'
        assert text.count(needle) == 1
        mutant.write_text(text.replace(needle, 'body["artifact_revision"] is String'))
        broken = out / "broken-render-revision"
        run("compile-render-revision-mutant", [*swift, mutant, state, recovery, tests, "-o", broken])
        failure = run("reject-render-revision-mutant", [broken], expected=1)
        assert "Wrong artifact revision cannot approve room review" in failure, "Wrong failure in renderer control"
        mutant = out / "SpatialModels-no-capture-owner.swift"
        text = models.read_text()
        needle = "presentationID == id && currentOwner == ownerID"
        assert text.count(needle) == 1
        mutant.write_text(text.replace(needle, "presentationID == id"))
        broken = out / "broken-capture-owner"
        run("compile-capture-owner-mutant", [*swift, mutant, state, recovery, tests, "-o", broken])
        failure = run("reject-capture-owner-mutant", [broken], expected=1)
        assert "Account switch cannot adopt a late capture callback" in failure, "Wrong failure in capture handoff control"
        run("restore-production", [binary])
        receipt["accepted"] = True
    finally:
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
