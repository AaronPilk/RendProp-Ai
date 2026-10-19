#!/usr/bin/env python3
"""Compile targeted defects; require the intended runtime assertion, not setup failure."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
runner = ROOT / "apps/ios/tests/run-floor-measurements.sh"
evidence = Path(tempfile.mkdtemp(prefix="rendprop-floor-outline-controls-", dir="/tmp"))
controls = {
    "--inject-conversion-error": "12 ft 6 in",
    "--inject-overlap-loss": "overlap detected at plan level",
    "--inject-wire-resurrection": "present invalid/future/null typed field does not resurrect raw stale data",
    "--inject-outline-area-error": "concave L analytical area",
    "--inject-outline-overlap-loss": "Accepted invalid input: solid interior overlap including boundary-only corners",
    "--inject-outline-deduction-loss": "worksheet sums explicit holes",
}
results = []
for flag, assertion in controls.items():
    result = subprocess.run(["bash", str(runner), flag], cwd=ROOT,
                            capture_output=True, text=True, timeout=120)
    log = result.stdout + result.stderr
    (evidence / (flag.removeprefix("--") + ".log")).write_text(log)
    accepted = result.returncode in (132, 133) and "Precondition failed: " + assertion in log
    results.append({"control": flag, "exitCode": result.returncode,
                    "expectedAssertion": assertion, "intendedFailure": accepted})
    if not accepted:
        print(log[-6000:])
        raise SystemExit("Control did not reach its intended runtime assertion: " + flag)
    print("Rejected compiled measurement regression:", flag)
receipt = {"passed": True, "controls": results,
           "sourceHashes": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                            for path in [runner, ROOT / "apps/ios/Rendprop/Models/Listing.swift",
                                         ROOT / "apps/ios/tests/FloorMeasurementsTests.swift"]}}
(evidence / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
print("Six measurement runtime controls passed; receipt:", evidence / "receipt.json")
