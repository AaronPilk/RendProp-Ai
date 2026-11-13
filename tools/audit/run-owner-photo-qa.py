#!/usr/bin/env python3
"""Actual owner photo2K helpers, HTTP body and priced hold; denied live network."""
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
    "services/supabase/functions/ai-photo/owner-photo-qa.ts",
    "services/supabase/functions/ai-photo/owner-photo-qa.test.ts",
    "services/supabase/functions/ai-photo/input-policy.ts",
    "services/supabase/functions/ai-photo/index.ts",
    "services/supabase/functions/_shared/providers/gemini.ts",
    "services/supabase/functions/_shared/funded-serving.ts",
    "tools/audit/run-owner-photo-qa.py",
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
               "services/supabase/functions/ai-photo/owner-photo-qa.test.ts"]
    env = os.environ.copy()
    for name in ["SUPABASE_SECRET_KEYS", "RENDPROP_SECRET_KEY_NAME", "SUPABASE_PUBLISHABLE_KEYS", "RENDPROP_PUBLISHABLE_KEY_NAME"]:
        env.pop(name, None)
    env.update({"SUPABASE_URL": "https://closed-fixture.invalid", "SUPABASE_SERVICE_ROLE_KEY": "closed-fixture-not-valid", "SUPABASE_ANON_KEY": "closed-fixture-not-valid", "GEMINI_API_KEY": "closed-fixture-not-valid"})
    result = subprocess.run(command, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    log = out / "deno-test.log"
    log.write_text(result.stdout)
    clean = re.sub(r"\x1b\[[0-9;]*m", "", result.stdout)
    counts = re.search(r"(\d+) passed \| (\d+) failed", clean)
    guard = re.search(r"OWNER_PHOTO_QA_COMPILED_CONTROLS=(\d+)", clean)
    price = re.search(r"OWNER_PHOTO_QA_PRICE_COMPILED_CONTROLS=(\d+)", clean)
    after = hashes()
    controls = int(guard.group(1)) + int(price.group(1)) if guard and price else 0
    passed = result.returncode == 0 and bool(counts) and counts.group(2) == "0" and before == after and controls == 11
    receipt = {
        "recordedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "passed": passed, "actualSourceTestsPassed": int(counts.group(1)) if counts else 0,
        "testsFailed": int(counts.group(2)) if counts else None,
        "compiledNegativeControls": controls, "exitCode": result.returncode,
        "startSourceSHA256": before, "endSourceSHA256": after, "sourceBindingMatches": before == after,
        "log": str(log), "logSHA256": hashlib.sha256(log.read_bytes()).hexdigest(), "command": command,
        "bound2KCents": 11.7184,
        "primarySources": ["https://ai.google.dev/gemini-api/docs/pricing", "https://ai.google.dev/api/generate-content#ImageConfig", "https://ai.google.dev/gemini-api/docs/image-generation"],
        "boundary": "Actual helper, adapter HTTP body and fundedAttempt execute with closed DB, HTTP, token and supplier-result boundaries. Prospective same-source geometry, ordinary1K default and scoped2K quote checked. Denied network/write/process permissions; no real provider quality, phone export or invoice reconciliation guarantee.",
    }
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({k: receipt[k] for k in ["passed", "actualSourceTestsPassed", "testsFailed", "compiledNegativeControls", "sourceBindingMatches"]}))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
