#!/usr/bin/env python3
"""Actual native JPEG admission, unchanged frame ceilings and funded QC input bound."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SOURCES = [
    "services/supabase/functions/ai-video/index.ts",
    "services/supabase/functions/ai-video/drift-input.ts",
    "services/supabase/functions/ai-video/drift-source-bound.test.ts",
    "services/supabase/functions/ai-video/fixtures/reel-source-2048-q95.jpg",
    "services/supabase/functions/ai-photo/input-policy.ts",
    "services/supabase/functions/_shared/http.ts",
    "services/supabase/functions/_shared/funded-serving.ts",
    "tools/audit/run-drift-source-bound.py",
]


def hashes():
    return {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in SOURCES}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence-dir", "--out", required=True, type=Path)
    args = parser.parse_args()
    out = args.evidence_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    before = hashes()
    cmd = ["deno", "test", "--allow-read", "--allow-env", "--deny-net", "--deny-write", "--deny-run", "services/supabase/functions/ai-video/drift-source-bound.test.ts"]
    env = os.environ.copy()
    for key in ["SUPABASE_SECRET_KEYS", "RENDPROP_SECRET_KEY_NAME", "SUPABASE_PUBLISHABLE_KEYS", "RENDPROP_PUBLISHABLE_KEY_NAME"]:
        env.pop(key, None)
    env.update({"SUPABASE_URL": "https://closed-fixture.invalid", "SUPABASE_SERVICE_ROLE_KEY": "closed-fixture-not-valid", "SUPABASE_ANON_KEY": "closed-fixture-not-valid"})
    result = subprocess.run(cmd, cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log = out / "deno-source-bound.log"
    log.write_text(result.stdout)
    clean = re.sub(r"\x1b\[[0-9;]*m", "", result.stdout)
    counts = re.search(r"(\d+) passed \| (\d+) failed", clean)
    controls = re.search(r"DRIFT_SOURCE_BOUND_COMPILED_CONTROLS=(\d+)", clean)
    after = hashes()
    receipt = {
        "recordedUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "passed": result.returncode == 0 and counts is not None and counts.group(1) == "5" and counts.group(2) == "0" and controls is not None and controls.group(1) == "8" and before == after,
        "actualSourceTestsPassed": int(counts.group(1)) if counts else 0,
        "testsFailed": int(counts.group(2)) if counts else None,
        "compiledNegativeControls": int(controls.group(1)) if controls else 0,
        "exitCode": result.returncode,
        "sourceBindingMatches": before == after,
        "startSourceSHA256": before,
        "endSourceSHA256": after,
        "fixtureBytes": 2976887,
        "fixtureGeometry": [1152, 2048],
        "fixtureBase64Chars": 3969184,
        "sourceMaxBase64Chars": 12000000,
        "frameMaxBase64Chars": 2000000,
        "bodyMaxBytes": 19000000,
        "prospectiveSourceVisionTokens": 4096,
        "log": str(log),
        "logSHA256": hashlib.sha256(log.read_bytes()).hexdigest(),
        "command": cmd,
        "boundary": "Actual procedural UIKit JPEG and production source-validator, QC image/body reader, reel pre-admission prefix and judge input/tariff arithmetic execute. Paid admission and asset transport are closed doubles; no live API/model, authorization end-to-end, visual quality or invoice certification is claimed. All network, process and write access denied inside tests.",
    }
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({key: receipt[key] for key in ["passed", "actualSourceTestsPassed", "testsFailed", "compiledNegativeControls", "sourceBindingMatches"]}))
    return 0 if receipt["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
