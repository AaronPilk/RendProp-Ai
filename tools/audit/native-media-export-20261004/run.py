#!/usr/bin/env python3
"""Execute actual native download/export/Photos admission with offline doubles."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "apps/ios/Rendprop/Screens/FlythroughDetailView.swift"


def block(source, marker):
    assert source.count(marker) == 1, marker
    start = source.index(marker)
    # Function default closures precede the function body.
    body = source.index("async throws {", start) + len("async throws ") if "while canSave:" in marker else source.index("{", start)
    end, depth = body + 1, 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--inject-fault", choices=["drop-permission-context", "drop-listing-binding", "drop-csv-context", "drop-completion-context"])
    args = parser.parse_args()
    raw = SOURCE.read_bytes()
    source = raw.decode()
    bodies = {
        "__CONTEXT__": block(source, "@MainActor private struct NativeMediaExportContext"),
        "__SAVER__": block(source, "private enum PhotosLibrarySaver"),
        "__ADMISSION__": block(source, "    @MainActor private func mediaExportAdmission("),
        "__LOAD__": block(source, "    @MainActor private func loadCompliance()"),
        "__ORIGINALS__": block(source, "    @MainActor private func saveOriginalsToPhotos()"),
        "__LOCAL__": block(source, "    @MainActor private func saveFileToPhotos("),
        "__CSV__": block(source, "    @MainActor private func exportAudit()"),
        "__FILENAME__": block(source, "    static func auditFilename("),
    }
    hashes = {key: hashlib.sha256(value.encode()).hexdigest() for key, value in bodies.items()}
    expected = None
    if args.inject_fault == "drop-permission-context":
        needle = "        guard context.isCurrent, canSave() else { throw ContextChanged() }"
        assert bodies["__SAVER__"].count(needle) == 4
        bodies["__SAVER__"] = bodies["__SAVER__"].replace(needle, "        // injected missing permission admission")
        expected = "permission change prevents Photos transaction"
    elif args.inject_fault == "drop-listing-binding":
        needle = "            return current.serverID == snapshot.serverID && current.serverOrgID == snapshot.serverOrgID"
        assert bodies["__ADMISSION__"].count(needle) == 1
        bodies["__ADMISSION__"] = bodies["__ADMISSION__"].replace(needle, "            return true")
        expected = "changed download never writes Photos"
    elif args.inject_fault == "drop-csv-context":
        needle = "                guard canExport() else { return }"
        assert bodies["__CSV__"].count(needle) == 3
        bodies["__CSV__"] = bodies["__CSV__"].replace(needle, "                // injected stale CSV handoff")
        expected = "stale CSV response never reaches Files handoff"
    elif args.inject_fault == "drop-completion-context":
        needle = "                guard canExport() else { return }"
        assert bodies["__LOCAL__"].count(needle) == 2
        bodies["__LOCAL__"] = bodies["__LOCAL__"].replace(needle, "                // injected stale Photos success", 1)
        expected = "already begun Photos completion cannot mark replacement session saved"
    fixture = Path(__file__).with_name("Fixture.swift.template").read_text()
    for key, body in bodies.items():
        assert fixture.count(key) == 1, key
        fixture = fixture.replace(key, body)
    out = args.output_dir or Path(tempfile.mkdtemp(prefix="rendprop-native-media-export-"))
    out.mkdir(parents=True, exist_ok=True)
    swift = out / "ActualNativeMediaExport.swift"
    swift.write_text(fixture)
    binary = out / "checks"
    files = out / "isolated-files"
    files.mkdir(exist_ok=True)
    receipt = {"source": str(SOURCE.relative_to(ROOT)), "sourceSHA256": hashlib.sha256(raw).hexdigest(),
               "actualBodyHashes": hashes, "compiledBodyHashes": {key: hashlib.sha256(body.encode()).hexdigest() for key, body in bodies.items()},
               "injectedFault": args.inject_fault, "networkCalls": 0, "realPhotosCalls": 0, "cameraCalls": 0,
               "customerFilesAccessed": 0, "commands": []}
    for label, command in [("compile", ["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", str(swift), "-o", str(binary)]),
                           ("run", [str(binary), str(files)])]:
        result = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60)
        log = out / f"{label}.log"
        log.write_text(result.stdout)
        receipt["commands"].append({"name": label, "exit": result.returncode, "log": str(log), "sha256": hashlib.sha256(log.read_bytes()).hexdigest()})
        if label == "run":
            receipt["passed"] = result.returncode == 1 and expected in result.stdout if expected else result.returncode == 0
            if expected:
                receipt["expectedRejection"] = expected
            elif receipt["passed"]:
                match = re.search(r"PASS: (\d+) native media export assertions", result.stdout)
                assert match
                receipt["assertions"] = int(match[1])
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(label, result.returncode, result.stdout.strip(), flush=True)
        if (label == "compile" and result.returncode) or (label == "run" and not receipt["passed"]):
            print("Evidence:", out, flush=True)
            raise SystemExit(1)
    print("Evidence:", out, flush=True)


if __name__ == "__main__":
    main()
