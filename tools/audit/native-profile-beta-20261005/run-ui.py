#!/usr/bin/env python3
"""Six real Release simulator UI cases; no purchase, camera or Photos access.
Use --storekit only with an operational local StoreKitTest daemon. It fails
closed when unavailable and never falls back to the real App Store.
"""
import argparse, hashlib, json, pathlib, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
CASES = ["testProfileBusinessCardAndExplicitPortfolioSelection", "testProfileLogoIsSeparateAndPhoneKeepsInternationalNumber", "testClientSaveExplainsChangedWorkspaceAndRemainsInvalidAfterABA", "testProfileGuideIsReachableAtLargeText", "testProfileExplicitSaveAboveKeyboardAndTeamKeepsPersonalCard", "testProfileGuestArchiveRequiresReviewAndExplicitSave"]

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--simulator", required=True)
    parser.add_argument("--derived-data", required=True)
    parser.add_argument("--storekit", action="store_true")
    args = parser.parse_args()
    out = pathlib.Path(args.out).resolve(); out.mkdir(parents=True, exist_ok=True)
    bundle = out / "actual.xcresult"
    if bundle.exists(): raise SystemExit("Use a fresh --out directory; retained UI evidence is never overwritten.")
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))
    if not any(device["udid"] == args.simulator for group in devices["devices"].values() for device in group): raise SystemExit("Destination must be an available simulator.")
    inputs = sorted((ROOT / "apps/ios/Rendprop").rglob("*.swift")) + sorted((ROOT / "apps/ios/RendpropUITests").rglob("*.swift"))
    inputs += [ROOT / "apps/ios/RendpropSpatialTestFlight.xcodeproj/project.pbxproj", ROOT / "apps/ios/Rendprop.storekit", pathlib.Path(__file__).resolve()]
    hashes = {str(path.relative_to(ROOT)): digest(path) for path in inputs}
    cases = CASES + (["testCompactPaywallUsesLocalStoreKitAndGuideIsReachableAtLargeText"] if args.storekit else [])
    command = ["xcodebuild", "test", "-project", "apps/ios/RendpropSpatialTestFlight.xcodeproj", "-scheme", "RendpropSpatialTestFlight", "-configuration", "Release", "-destination", "platform=iOS Simulator,id=" + args.simulator, "-derivedDataPath", args.derived_data, "-resultBundlePath", str(bundle), "-parallel-testing-enabled", "NO"]
    command += ["-only-testing:RendpropUITests/BetaPolishUITests/" + case for case in cases]
    command += ["CODE_SIGNING_ALLOWED=NO"]
    (out / "command.json").write_text(json.dumps(command, indent=2) + "\n")
    with (out / "actual.log").open("w") as log:
        result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    summary = {}
    if bundle.exists():
        read = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)], capture_output=True, text=True)
        if read.returncode == 0:
            summary = json.loads(read.stdout)
            (out / "xcresult-summary.json").write_text(read.stdout)
    mismatches = [name for name, value in hashes.items() if digest(ROOT / name) != value]
    passed = result.returncode == 0 and summary.get("passedTests") == len(cases) and summary.get("failedTests") == 0 and summary.get("skippedTests") == 0 and not mismatches
    receipt = {"passed": passed, "cases": cases, "xcodebuildExit": result.returncode, "passedTests": summary.get("passedTests"), "failedTests": summary.get("failedTests"), "skippedTests": summary.get("skippedTests"), "sourceSHA256": hashes, "sourceBoundAtEnd": not mismatches, "sourceMismatches": mismatches, "simulator": args.simulator, "storekitProductUIIncluded": args.storekit, "limits": "Synthetic selected workspace, real SwiftUI and OS share-sheet handoff. No share destination, contact store, Photos picker, camera, paid provider or purchase is invoked. This does not certify physical capture, App Store storefront eligibility or hosted production logo delivery."}
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({key:receipt[key] for key in ["passed", "passedTests", "failedTests", "skippedTests", "sourceBoundAtEnd"]}))
    sys.exit(0 if passed else 1)

if __name__ == "__main__": main()
