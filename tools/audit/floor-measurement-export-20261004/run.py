#!/usr/bin/env python3
"""Compile and exercise actual async Photos save bodies against offline boundaries."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "apps/ios/Rendprop/Screens/FlythroughDetailView.swift"


def block(source, marker, body_hint=None):
    assert source.count(marker) == 1, marker
    start = source.index(marker)
    opening = source.index(body_hint, start) + len(body_hint) - 1 if body_hint else source.index("{", start)
    assert source[opening] == "{"
    end, depth = opening + 1, 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--inject-fault", choices=["drop-context-check", "ignore-cancellation", "drop-completion-check"])
    args = parser.parse_args()
    raw = SOURCE.read_bytes()
    source = raw.decode()
    saver = block(source, "private enum PhotosLibrarySaver")
    caller = block(source, "struct PlanExportSheet: View")
    bodies = {
        "__DENIED__": block(saver, "    struct Denied: LocalizedError"),
        "__CONTEXT_CHANGED__": block(saver, "    struct ContextChanged: LocalizedError"),
        "__SAVE_IMAGE__": block(saver, "    @MainActor static func saveImage(", "async throws {"),
        "__ENSURE_ACCESS__": block(saver, "    private static func ensureAddAccess()"),
        "__CALLER_SAVE__": block(caller, "    private func save()"),
    }
    actual_hashes = {key: hashlib.sha256(value.encode()).hexdigest() for key, value in bodies.items()}
    guard = "guard !Task.isCancelled, canSave() else { throw ContextChanged() }"
    assert bodies["__SAVE_IMAGE__"].count(guard) == 1
    expected = None
    if args.inject_fault == "drop-context-check":
        bodies["__SAVE_IMAGE__"] = bodies["__SAVE_IMAGE__"].replace(guard, "guard !Task.isCancelled else { throw ContextChanged() }")
        expected = "context change during permission prevents write"
    elif args.inject_fault == "ignore-cancellation":
        bodies["__SAVE_IMAGE__"] = bodies["__SAVE_IMAGE__"].replace(guard, "guard canSave() else { throw ContextChanged() }")
        expected = "cancellation throws"
    elif args.inject_fault == "drop-completion-check":
        after = "guard canExport() else { return }"
        assert bodies["__CALLER_SAVE__"].count(after) == 1
        bodies["__CALLER_SAVE__"] = bodies["__CALLER_SAVE__"].replace(after, "// injected stale completion success")
        expected = "stale completion never marks saved"
    fixture = Path(__file__).with_name("Fixture.swift.template").read_text()
    for key, body in bodies.items():
        assert fixture.count(key) == 1, key
        fixture = fixture.replace(key, body)
    out = Path(tempfile.mkdtemp(prefix="rendprop-floor-measurement-export-", dir="/tmp"))
    compiled = out / "ActualPhotosSave.swift"
    compiled.write_text(fixture)
    receipt = {"source": str(SOURCE.relative_to(ROOT)), "sourceSha256": hashlib.sha256(raw).hexdigest(),
               "actualBodyHashes": actual_hashes,
               "compiledBodyHashes": {key: hashlib.sha256(value.encode()).hexdigest() for key, value in bodies.items()},
               "injectedFault": args.inject_fault, "networkCalls": 0, "realPhotosCalls": 0,
               "cameraCalls": 0, "customerFilesAccessed": 0, "runtimeMutations": 0, "commands": []}
    commands = [("compile", ["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", str(compiled), "-o", str(out / "checks")]),
                ("run", [str(out / "checks")])]
    for label, command in commands:
        result = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60)
        log = out / f"{label}.log"
        log.write_text(result.stdout)
        receipt["commands"].append({"name": label, "exit": result.returncode, "log": str(log), "sha256": hashlib.sha256(log.read_bytes()).hexdigest()})
        if label == "run":
            receipt["passed"] = result.returncode != 0 and expected in result.stdout if expected else result.returncode == 0
            if expected:
                receipt["expectedRejection"] = expected
            elif receipt["passed"]:
                match = re.search(r"PASS: (\d+) scenarios, (\d+) assertions", result.stdout)
                assert match
                receipt.update(scenarios=int(match[1]), assertions=int(match[2]))
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(label, result.returncode, result.stdout.strip(), flush=True)
        if (label == "compile" and result.returncode) or (label == "run" and not receipt["passed"]):
            print("Evidence:", out, flush=True)
            raise SystemExit(1)
    print("Evidence:", out, flush=True)


if __name__ == "__main__":
    main()
