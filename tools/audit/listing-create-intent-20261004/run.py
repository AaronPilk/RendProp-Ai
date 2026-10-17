#!/usr/bin/env python3
"""Replay and in-flight facts intent proof from captured production Swift."""
from pathlib import Path
import argparse, hashlib, json, re, subprocess, tempfile

ROOT = Path(__file__).resolve().parents[3]
SYNC = ROOT / "apps/ios/Rendprop/Networking/WorkspaceSync.swift"
APP = ROOT / "apps/ios/Rendprop/RendpropApp.swift"


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
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--expect-regression", action="store_true")
    parser.add_argument("--inject-fault", choices=["revive-replay-intent", "drop-replay-base", "retain-consumed-address", "drop-archive-restore"])
    args = parser.parse_args()
    out = args.output_dir or Path(tempfile.mkdtemp(prefix="rendprop-listing-create-intent-", dir="/tmp"))
    out.mkdir(parents=True, exist_ok=True)
    models = [ROOT / "apps/ios/Rendprop/Models" / n for n in ["Listing.swift", "ListingClientContact.swift", "Money.swift"]]
    captured = {p: p.read_bytes() for p in [SYNC, APP, *models]}
    template = Path(__file__).with_name("Fixture.swift.template")
    captured_harness = {p: p.read_bytes() for p in [Path(__file__).resolve(), template]}
    source = captured[SYNC].decode()
    bodies = {"__WIRE__": block(source, "enum ListingWireDetails"),
              "__CREATE__": block(source, "@MainActor enum CloudDraftCreation"),
              "__ERROR__": block(source, "enum CloudSyncError:"),
              "__IS_IN_WORKSPACE__": block(captured[APP].decode(), "    func isInSelectedWorkspace(_ listing: Listing)"),
              "__MODIFY__": block(captured[APP].decode(), "    func modify(_ id: UUID,"),
              "__SET_SOLD__": block(captured[APP].decode(), "    func setSold(_ sold: Bool,")}
    actual_bodies = bodies.copy()
    if args.inject_fault == "revive-replay-intent":
        branch = block(bodies["__CREATE__"], "        if created.cloudCreateReplayed == true, unchanged {")
        needle = "            latest.factsSync = created.factsSync"
        assert branch.count(needle) == 1
        bodies["__CREATE__"] = bodies["__CREATE__"].replace(branch, branch.replace(needle, "            // injected missing replay intent retirement"))
    elif args.inject_fault == "drop-replay-base":
        branch = block(bodies["__CREATE__"], "        if created.cloudCreateReplayed == true, !factsUnchanged, var intent = latest.factsSync,")
        bodies["__CREATE__"] = bodies["__CREATE__"].replace(branch, "        // injected missing original-payload replay CAS base proof")
    elif args.inject_fault == "retain-consumed-address":
        needle = 'if sent.value == (first[key] ?? .null), !(newerLocation && locationKeys.contains(key)) {'
        assert bodies["__CREATE__"].count(needle) == 1
        bodies["__CREATE__"] = bodies["__CREATE__"].replace(needle, 'if key != "address", sent.value == (first[key] ?? .null), !(newerLocation && locationKeys.contains(key)) {')
    elif args.inject_fault == "drop-archive-restore":
        needle = "; if !sold { $0.cloudArchived = false }"
        assert bodies["__SET_SOLD__"].count(needle) == 1
        bodies["__SET_SOLD__"] = bodies["__SET_SOLD__"].replace(needle, "")
    fixture = captured_harness[template].decode()
    for key, body in bodies.items():
        assert fixture.count(key) == 1
        fixture = fixture.replace(key, body)
    swift = out / "ActualListingCreateIntent.swift"
    swift.write_text(fixture)
    copied = []
    for model in models:
        p = out / model.name
        p.write_bytes(captured[model])
        copied.append(p)
    receipt = {"sourceHashes": {str(p.relative_to(ROOT)): hashlib.sha256(b).hexdigest() for p, b in captured.items()},
               "actualBodyHashes": {k: hashlib.sha256(b.encode()).hexdigest() for k, b in actual_bodies.items()},
               "compiledBodyHashes": {k: hashlib.sha256(b.encode()).hexdigest() for k, b in bodies.items()},
               "harnessHashes": {str(p.relative_to(ROOT)): hashlib.sha256(b).hexdigest() for p, b in captured_harness.items()},
               "fault": args.inject_fault, "networkCalls": 0, "cameraCalls": 0, "customerFilesAccessed": 0, "productionMutations": 0, "commands": []}
    expected = {"drop-replay-base": "in-flight edits use the originally created values as CAS base",
                "retain-consumed-address": "create-time untouched intent retires and adopts office facts during a newer edit",
                "drop-archive-restore": "a pending unarchive restores phone status and sold marker against the first POST state"}.get(args.inject_fault, "unchanged replay must clear create-time intent instead of reviving it")
    for label, command in [("compile", ["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", *map(str, copied), str(swift), "-o", str(out / "checks")]),
                           ("run", [str(out / "checks")])]:
        r = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
        log = out / (label + ".log")
        log.write_text(r.stdout)
        receipt["commands"].append({"name": label, "exit": r.returncode, "log": str(log), "sha256": hashlib.sha256(log.read_bytes()).hexdigest()})
        receipt["sourceHashesAtEnd"] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in captured}
        receipt["harnessHashesAtEnd"] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in captured_harness}
        receipt["sourceBoundAtEnd"] = receipt["sourceHashes"] == receipt["sourceHashesAtEnd"]
        receipt["harnessBoundAtEnd"] = receipt["harnessHashes"] == receipt["harnessHashesAtEnd"]
        bound = receipt["sourceBoundAtEnd"] and receipt["harnessBoundAtEnd"]
        if label == "run":
            receipt["scenarios"] = [json.loads(line.removeprefix("SCENARIO ")) for line in r.stdout.splitlines() if line.startswith("SCENARIO ")]
            assertions = re.search(r"^(\d+) assertions across", r.stdout, re.MULTILINE)
            receipt["assertions"] = int(assertions.group(1)) if assertions else None
            receipt["confirmedReplayRegression"] = r.returncode == 1 and any(s["replay"] and s["violations"] for s in receipt["scenarios"])
            gate = receipt["confirmedReplayRegression"] and (args.inject_fault is None or expected in r.stdout)
            receipt["passed"] = bound and (gate if args.expect_regression else r.returncode == 0)
            if args.inject_fault:
                receipt["expectedRejection"] = expected
        elif r.returncode or not bound:
            receipt["passed"] = False
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(label, r.returncode, r.stdout.strip(), flush=True)
        if not bound or (label == "compile" and r.returncode) or (label == "run" and not receipt["passed"]):
            print("Evidence:", out)
            raise SystemExit(1)
    print("Evidence:", out)


if __name__ == "__main__":
    main()
