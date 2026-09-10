#!/usr/bin/env python3
"""Build clean source; verify consent first, then two synthetic UI walks.

No archive, Apple upload, simulator erase, uninstall or camera test. The caller
must explicitly select an already-created dedicated test simulator and scratch
DerivedData. Keep an artifact/source receipt so an old green test bundle cannot
be mistaken for the source we just changed.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

if not __debug__:
    raise SystemExit("FAIL: evidence helpers require unoptimized Python")

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/spatial-spike"))
import verify_ui_evidence as evidence
import verify_app_bundle as bundle


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def source():
    require(not git("status", "--porcelain"), "Source is dirty; checkpoint before testing")
    return {"commit": git("rev-parse", "HEAD"), "tree": git("rev-parse", "HEAD^{tree}")}


def digest(path):
    require(not path.is_symlink(), "Symlink at artifact/evidence root")
    if path.is_file():
        value = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                value.update(chunk)
        return value.hexdigest()
    values = {}
    for item in sorted(path.rglob("*")):
        require(not item.is_symlink(), "Symlink inside artifact/evidence")
        if item.is_file():
            values[str(item.relative_to(path))] = digest(item)
    require(bool(values), "Empty artifact/evidence")
    return hashlib.sha256(json.dumps(values, sort_keys=True).encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True)
    parser.add_argument("--simulator-name", required=True)
    parser.add_argument("--derived-data", required=True, type=Path)
    args = parser.parse_args()
    require(args.derived_data.is_absolute(), "Use an explicit absolute DerivedData path")
    initial = source()
    require(shutil.disk_usage(ROOT).free >= 2 * 1024**3, "Less than 2 GiB scratch space")
    inventory = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))
    matches = [d for group in inventory["devices"].values() for d in group if d["udid"] == args.simulator]
    require(len(matches) == 1 and matches[0]["name"] == args.simulator_name,
            "Dedicated simulator name/UUID mismatch")
    require(matches[0]["state"] == "Booted", "Explicitly boot the dedicated simulator first")
    out = Path(tempfile.mkdtemp(prefix="rendprop-noncamera-ui-", dir="/tmp"))
    print("EVIDENCE:", out, flush=True)
    commands = {}

    def invoke(name, command, cwd=ROOT):
        commands[name] = command
        print("RUN:", name, flush=True)
        with (out / (name + ".log")).open("x") as log:
            result = subprocess.run(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, timeout=1800)
        require(result.returncode == 0, f"{name} exited {result.returncode}; see {out / (name + '.log')}")
        print("PASS:", name, flush=True)

    # Verify the symbols in the actual input tree before any compiler runs.
    invoke("symbols", ["rg", "-n", "aiConsent.agree|aiConsent.decline|consentAction|consent.isAsking.*hidden",
                       "apps/ios/Rendprop/RendpropApp.swift", "apps/ios/RendpropUITests/ReviewerWalk.swift"])
    invoke("generate", ["xcodegen", "generate", "--spec", "project-spatial-testflight.yml"], ROOT / "apps/ios")
    project = ROOT / "apps/ios/RendpropSpatialTestFlight.xcodeproj"
    project_hash = digest(project / "project.pbxproj")
    require(source() == initial, "Source changed during generation")
    common = ["xcodebuild", "-quiet", "-project", str(project), "-scheme", "RendpropSpatialTestFlight",
              "-configuration", "Release", "-destination", "platform=iOS Simulator,id=" + args.simulator,
              "-derivedDataPath", str(args.derived_data), "-parallel-testing-enabled", "NO",
              "-disableAutomaticPackageResolution", "-skipPackageUpdates"]
    invoke("build", common + ["build-for-testing"])
    require(source() == initial, "Source changed during build")
    products = args.derived_data / "Build/Products"
    app = products / "Release-iphonesimulator/Rendprop.app"
    runner = products / "Release-iphonesimulator/RendpropUITests-Runner.app"
    bundle.verify(app, "18", True)
    artifact_hashes = {"app": digest(app), "runner": digest(runner)}
    specs = list(products.glob("RendpropSpatialTestFlight_*.xctestrun"))
    require(len(specs) == 1, "Ambiguous test specification")
    spec_hash = digest(specs[0])
    # Exercise the repaired decision flow first against the same built binary.
    # A regression should fail in minutes, not after unrelated onboarding steps.
    checks = [
        ("Consent", "ReviewerWalk/testAIConsentDecisions", {"ReviewerWalk/testAIConsentDecisions()"},
         {"r11-ai-consent", "r11b-consent-actions", "r11c-consent-granted"}),
        ("Reviewer", "ReviewerWalk/testReviewerWalk", evidence.REVIEWER,
         evidence.REVIEWER_SHOTS | {"r11b-consent-actions", "r11c-consent-granted"}),
        ("Main", "RendpropUITests/testWalk", evidence.MAIN, evidence.MAIN_SHOTS),
    ]
    for name, test, expected, shots in checks:
        invoke(name, common + ["test-without-building", "-only-testing:RendpropUITests/" + test,
                              "-resultBundlePath", str(out / (name + ".xcresult"))])
        require(source() == initial, "Source changed during UI walk")
        require(artifact_hashes == {"app": digest(app), "runner": digest(runner)}, "Tested artifacts changed")
        evidence.verify(out / (name + ".xcresult"), expected, shots)
    require(digest(specs[0]) == spec_hash and digest(project / "project.pbxproj") == project_hash,
            "Project/test specification changed")
    receipt = {"source": initial, "configuration": "Release", "simulator": args.simulator,
               "commands": commands, "artifacts": artifact_hashes, "projectSHA256": project_hash,
               "xctestrunSHA256": spec_hash, "completedAt": datetime.now(timezone.utc).isoformat(),
               "results": {name: digest(out / (name + ".xcresult")) for name, *_ in checks},
               "logs": {name: digest(out / (name + ".log")) for name in commands},
               "tests": 3, "skips": 0, "requiredScreenAttachments": 24, "distinctRequiredScreens": 21,
               "limits": ["Synthetic offline data", "No camera/AR tests", "Visual inspection still required",
                          "No TestFlight upload or App Store changes"]}
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print("PASS: three exact tests, zero skips, 24 required screen attachments; receipt:", out / "receipt.json", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("FAIL:", type(error).__name__, str(error), flush=True)
        sys.exit(1)
