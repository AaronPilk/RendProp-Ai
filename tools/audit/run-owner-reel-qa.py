#!/usr/bin/env python3
"""Closed actual-source owner QA admission/staging tests; never dispatch a vendor."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SOURCES = [
    "services/supabase/functions/ai-video/owner-reel-qa.ts",
    "services/supabase/functions/ai-video/index.ts",
    "services/supabase/functions/ai-video/cost-reservation.ts",
    "services/supabase/functions/_shared/providers/kie.ts",
    "services/supabase/functions/ai-video/owner-reel-qa.test.ts",
    "tools/audit/run-owner-reel-qa.py",
]


def hashes():
    return {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in SOURCES}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence-dir", "--out", required=True, type=Path)
    args = parser.parse_args()
    out = args.evidence_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    before = hashes()
    command = ["deno", "test", "--allow-read", "--allow-env", "--deny-net", "--deny-write", "--deny-run",
               "services/supabase/functions/ai-video/owner-reel-qa.test.ts"]
    result = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    log = out / "deno-test.log"
    log.write_text(result.stdout)
    clean = re.sub(r"\x1b\[[0-9;]*m", "", result.stdout)
    counts = re.search(r"(\d+) passed \| (\d+) failed", clean)
    helper = re.search(r"OWNER_QA_COMPILED_CONTROLS=(\d+)", clean)
    staging = re.search(r"OWNER_QA_STAGING_COMPILED_CONTROLS=(\d+)", clean)
    uuid = re.search(r"OWNER_QA_UUID_COMPILED_CONTROLS=(\d+)", clean)
    after = hashes()
    passed = result.returncode == 0 and bool(counts) and counts.group(2) == "0" and before == after
    controls = int(helper.group(1)) + int(staging.group(1)) + int(uuid.group(1)) if helper and staging and uuid else 0
    passed = passed and bool(helper and staging and uuid) and controls == 17
    receipt = {
        "recordedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "passed": passed,
        "actualSourceTestsPassed": int(counts.group(1)) if counts else 0,
        "testsFailed": int(counts.group(2)) if counts else None,
        "compiledNegativeControls": controls,
        "helperControls": int(helper.group(1)) if helper else 0,
        "stagingControls": int(staging.group(1)) if staging else 0,
        "uuidCanonicalizationControls": int(uuid.group(1)) if uuid else 0,
        "exitCode": result.returncode,
        "startSourceSHA256": before,
        "endSourceSHA256": after,
        "sourceBindingMatches": before == after,
        "log": str(log),
        "logSHA256": hashlib.sha256(log.read_bytes()).hexdigest(),
        "command": command,
        "boundary": "Actual helper, priced reserve path and actual route/provider callback fragments; closed DB/auth/provider/storage boundaries. Denied network/write/process permissions. No live model quality, phone completion or supplier invoice certification.",
    }
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({k: receipt[k] for k in ["passed", "actualSourceTestsPassed", "testsFailed", "compiledNegativeControls", "sourceBindingMatches"]}))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
