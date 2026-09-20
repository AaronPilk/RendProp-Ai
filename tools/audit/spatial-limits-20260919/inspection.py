#!/usr/bin/env python3
"""Actual SpatialTourView inspection/caller race tests with a gated native validator."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
from run import ROOT, HERE, SOURCE, block, run, sha

PRODUCT = Path("apps/ios/Rendprop/Screens/SpatialTourView.swift")
MODELS = Path("apps/ios/Rendprop/Networking/SpatialModels.swift")

def body(source, marker, header=None):
    selected = block(source, marker)
    if header is None:
        return selected[selected.index("{") + 1:-1]
    return selected[selected.index(header) + len(header):-1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture-receipt", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    output = args.output or Path(tempfile.mkdtemp(prefix="rendprop-spatial-inspection-"))
    output.mkdir(parents=True, exist_ok=True)
    fixture_receipt = next(x for x in json.loads(args.fixture_receipt.read_text())["scenarios"] if x["name"] == "frame-limit-pending-write")
    fixture = fixture_receipt["root"]
    source = (ROOT / PRODUCT).read_text()
    models = (ROOT / MODELS).read_text()
    archive = (ROOT / SOURCE / "CaptureArchive.swift").read_text()
    local = block(archive, "    static func local() throws -> CaptureArchive")
    archive = archive.replace(local, "    static func local() throws -> CaptureArchive { return CaptureArchive(root: HarnessFS.capturesRoot) }")
    archive = archive.replace("    func validateForExport(id: String) throws -> URL {", "    func validateForExport(id: String) throws -> URL {\n        ArchiveBarrier.beforeValidation()")
    scan = body(block(source, "    private var captureCard:"), "            Button {")
    accepted = body(source, "            SpatialProductCapture(roomLabel: trimmedLabel) { url in", "{ url in")
    auth = body(source, "        .onChange(of: auth.userID) { _ in", "{ _ in")
    dismissal = body(source, "        .sheet(item: $captureHandoff, onDismiss: {")
    # Keep the Task handle to await real method completion; its body is unchanged.
    dismissal = dismissal.replace("Task { await inspectCaptures", "inspectionTask = Task { await inspectCaptures")
    methods = "\n".join(block(source, marker) for marker in ["    @MainActor private func invalidateCaptureInspection()", "    @MainActor private func inspectCaptures("])
    types = block(source, "private struct SpatialLimitNotice").replace("private struct", "struct", 1) + "\n" + block(models, "struct SpatialCaptureHandoff")
    raw_hashes = {str(path): sha((ROOT / path).read_bytes()) for path in [PRODUCT, MODELS, SOURCE / "CaptureModel.swift", SOURCE / "CaptureArchive.swift", SOURCE / "RasterWriter.swift"]}
    (output / "source-hashes.json").write_text(json.dumps(raw_hashes, indent=2))
    (output / "SpatialTourView.original.swift").write_text(source)
    cases = ["fixed", "mutant-missing-scan-invalidation", "mutant-missing-handoff-invalidation", "mutant-missing-account-invalidation", "mutant-missing-publication-identity"]
    results = []
    for variant in cases:
        target = output / variant
        target.mkdir()
        selected_scan, selected_accepted, selected_auth, selected_methods = scan, accepted, auth, methods
        if variant == cases[1]: selected_scan = scan.replace("invalidateCaptureInspection()", "")
        if variant == cases[2]: selected_accepted = accepted.replace("invalidateCaptureInspection()", "")
        if variant == cases[3]: selected_auth = auth.replace("invalidateCaptureInspection()", "")
        if variant == cases[4]: selected_methods = methods.replace("captureInspectionID == inspectionID,", "")
        actions = selected_methods + f"\nfunc tapScan() {{{selected_scan}}}\nfunc verified(_ url: URL, handoff: SpatialCaptureHandoff) {{{selected_accepted}}}\nfunc accountChanged() {{{selected_auth}}}\nfunc dismissCapture() {{{dismissal}}}\n"
        generated = (HERE / "InspectionRuntime.swift.template").read_text().replace("/* ACTUAL_NOTICE_AND_HANDOFF */", types).replace("/* ACTUAL_METHODS_AND_ACTIONS */", actions)
        (target / "InspectionRuntime.swift").write_text(generated)
        (target / "CaptureArchive.swift").write_text(archive)
        for file in ["CaptureModel.swift", "RasterWriter.swift"]:
            (target / file).write_bytes((ROOT / SOURCE / file).read_bytes())
        run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", *[str(target / f) for f in ["InspectionRuntime.swift", "CaptureArchive.swift", "CaptureModel.swift", "RasterWriter.swift"]], "-o", str(target / "inspection")], target / "compile.log")
        with (target / "runtime.log").open("w") as stream:
            result = subprocess.run([str(target / "inspection"), str(target / "fixtures"), fixture], stdout=stream, stderr=subprocess.STDOUT, timeout=90)
        text = (target / "runtime.log").read_text()
        print(variant, result.returncode, text[-1600:], flush=True)
        assert (result.returncode == 0) == (variant == "fixed"), (variant, text)
        if variant != "fixed":
            failure = json.loads((target / "fixtures/inspection-failure.json").read_text())
            assert any(not x["passed"] for x in failure["checks"]), "Mutant must fail a behavioral assertion, not infrastructure"
        results.append({"variant": variant, "exit": result.returncode, "log": text.strip()})
    for path, digest in raw_hashes.items(): assert sha((ROOT / path).read_bytes()) == digest, path
    for relative, digest in fixture_receipt["fileHashes"].items(): assert sha((Path(fixture) / relative).read_bytes()) == digest, relative
    (output / "fixture-preservation.json").write_text(json.dumps({"unchanged_original_files": len(fixture_receipt["fileHashes"]), "source": fixture, "hashes": fixture_receipt["fileHashes"]}, indent=2))
    (output / "receipt.json").write_text(json.dumps(results, indent=2))
    print("PASS inspection and all four behavioral mutation controls; evidence:", output)

if __name__ == "__main__": main()
