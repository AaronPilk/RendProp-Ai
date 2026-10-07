#!/usr/bin/env python3
"""Exercise actual outline editor calculations with Foundation-only boundaries."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "apps/ios/Rendprop/Screens/FloorMeasurementsView.swift"


def block(source, marker):
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
    parser.add_argument("--inject-fault", choices=["drop-original-geometry", "drop-original-vector", "drop-save-fence"])
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    raw = SOURCE.read_bytes()
    source = raw.decode()
    form = block(source, "private struct MeasurementOutlineForm: View")
    state_lines = [line.strip().removeprefix("@State private ")
                   for line in form.splitlines() if line.strip().startswith("@State private var ")]
    assert len(state_lines) >= 20
    bodies = {
        "__UI_ERROR__": block(source, "private struct MeasurementUIError: LocalizedError"),
        "__WALL_DRAFT__": block(source, "private struct MeasurementWallDraft: Identifiable"),
        "__WALL_ORIGINAL__": block(source, "private struct MeasurementWallOriginal"),
        "__WALL_DIRECTION__": block(source, "private enum MeasurementWallDirection: String, CaseIterable"),
        "__INITIALIZE__": block(form, "    private func initialize()"),
        "__COORDINATE_FIELD__": block(form, "    private func coordinateField("),
        "__DIMENSION_FIELDS__": block(form, "    private func dimensionFields("),
        "__COORDINATE__": block(form, "    private func coordinate("),
        "__MAKE_POINTS__": block(form, "    private func makePoints()"),
        "__CANDIDATE__": block(form, "    private func candidate()"),
        "__SAVE__": block(form, "    private func save()"),
        "__HAS_PENDING__": block(form, "    private var hasPendingWall: Bool"),
    }
    original_hashes = {key: hashlib.sha256(body.encode()).hexdigest() for key, body in bodies.items()}
    expected = None
    if args.inject_fault == "drop-original-geometry":
        marker = "if unchangedGeometry {"
        assert bodies["__CANDIDATE__"].count(marker) == 1
        bodies["__CANDIDATE__"] = bodies["__CANDIDATE__"].replace(marker, "if false && unchangedGeometry {")
        expected = "metadata-only edit preserves exact vertex bits"
    elif args.inject_fault == "drop-original-vector":
        marker = "if let original, primary == original.primary, inches == original.inches,"
        assert bodies["__WALL_DRAFT__"].count(marker) == 1
        bodies["__WALL_DRAFT__"] = bodies["__WALL_DRAFT__"].replace(marker, "if false, let original, primary == original.primary, inches == original.inches,")
        expected = "unchanged wall vector preserves exact component bits"
    elif args.inject_fault == "drop-save-fence":
        marker = "guard closingReviewed, !hasPendingWall else {"
        assert bodies["__SAVE__"].count(marker) == 1
        bodies["__SAVE__"] = bodies["__SAVE__"].replace(marker, "guard closingReviewed else {")
        expected = "pending wall fields prevent save callback"

    fixture_path = Path(__file__).with_name("Fixture.swift.template")
    fixture = fixture_path.read_text()
    for key, body in bodies.items():
        assert fixture.count(key) == 1, key
        fixture = fixture.replace(key, body)
    assert fixture.count("__STATE_FIELDS__") == 1
    fixture = fixture.replace("__STATE_FIELDS__", "\n    ".join(state_lines))
    out = args.evidence or Path(tempfile.mkdtemp(prefix="rendprop-outline-editor-", dir="/tmp"))
    out.mkdir(parents=True, exist_ok=True)
    compiled = out / "ActualOutlineEditor.swift"
    compiled.write_text(fixture)
    model_paths = [ROOT / "apps/ios/Rendprop/Models" / name
                   for name in ["Listing.swift", "ListingClientContact.swift", "Money.swift"]]
    receipt = {
        "source": str(SOURCE.relative_to(ROOT)), "sourceSha256": hashlib.sha256(raw).hexdigest(),
        "modelHashes": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in model_paths},
        "actualBodyHashes": original_hashes,
        "compiledBodyHashes": {key: hashlib.sha256(body.encode()).hexdigest() for key, body in bodies.items()},
        "fixtureSha256": hashlib.sha256(fixture_path.read_bytes()).hexdigest(),
        "stateBoundary": "SwiftUI @State wrappers removed; class-owned fields retain actual defaults",
        "injectedFault": args.inject_fault, "networkCalls": 0, "cameraCalls": 0, "providerCalls": 0,
        "customerFilesAccessed": 0, "runtimeSourceMutations": 0, "commands": [],
    }
    commands = [
        ("compile", ["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                     *map(str, model_paths), str(compiled), "-o", str(out / "checks")]),
        ("run", [str(out / "checks")]),
    ]
    for label, command in commands:
        result = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, timeout=60)
        log = out / f"{label}.log"
        log.write_text(result.stdout)
        receipt["commands"].append({"name": label, "exit": result.returncode, "log": str(log),
                                    "sha256": hashlib.sha256(log.read_bytes()).hexdigest()})
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
