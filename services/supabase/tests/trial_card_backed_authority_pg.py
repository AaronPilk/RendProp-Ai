#!/usr/bin/env python3
"""Fresh, disposable PostgreSQL proof for card-backed trial authorization.

No hosted connection, inherited PG credentials, provider calls or actual funding.
The local cluster is stopped and removed after the test; logs remain as evidence.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from tools.audit.run_database_regression import partition_fresh_migrations

parser = argparse.ArgumentParser()
parser.add_argument("--evidence-dir", type=Path, required=True)
args = parser.parse_args()
out = args.evidence_dir.resolve()
out.mkdir(parents=True, exist_ok=True)
cluster = Path(tempfile.mkdtemp(prefix="card-trial-pg-", dir="/private/tmp"))
socket = Path(tempfile.mkdtemp(prefix="ct-", dir="/private/tmp"))
port = "55984"
env = {
    "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
    "LC_ALL": "C",
    "PGOPTIONS": "-c statement_timeout=60000 -c lock_timeout=15000 -c timezone=UTC",
}
tool = lambda name: shutil.which(name) or str(Path("/opt/homebrew/opt/postgresql@17/bin") / name)
sql = ROOT / "services/supabase"
migrations, skipped = partition_fresh_migrations(sorted((sql / "migrations").glob("*.sql")))
inputs = [sql / "tests/ci-bootstrap.sql", sql / "tests/trial_card_backed_authority.sql",
          sql / "tests/trial_hybrid_funded_serving.sql", sql / "tests/trial_media_fixture.sql",
          Path(__file__).resolve(), *migrations]
receipt = {
    "passed": False, "scope": "fresh disposable local PostgreSQL only",
    "sourceHashes": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},
    "liveStateOnlySkipped": [p.name for p in skipped], "steps": [],
}
started = False


def run(name, command):
    result = subprocess.run([str(x) for x in command], cwd=ROOT, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=240)
    log = out / (name + ".log")
    log.write_text(result.stdout)
    receipt["steps"].append({"name": name, "exit": result.returncode,
                             "logSHA256": hashlib.sha256(log.read_bytes()).hexdigest()})
    if result.returncode:
        raise RuntimeError(f"{name} failed: {result.stdout[-5000:]}")
    return result.stdout


try:
    run("initdb", [tool("initdb"), "-D", cluster, "-U", "postgres", "-A", "trust",
                   "--no-locale", "--encoding=UTF8"])
    run("start", [tool("pg_ctl"), "-D", cluster, "-l", out / "postgres.log", "-w",
                  "-o", f"-k {socket} -p {port} -c listen_addresses='' -c shared_buffers=16MB", "start"])
    started = True
    conn = ["-h", socket, "-p", port, "-U", "postgres"]
    run("createdb", [tool("createdb"), *conn, "card_trial_test"])
    psql = [tool("psql"), "-X", "--no-password", *conn, "-d", "card_trial_test",
            "-v", "ON_ERROR_STOP=1"]
    run("bootstrap", [*psql, "-q", "-f", sql / "tests/ci-bootstrap.sql"])
    for migration in migrations:
        run("apply-" + migration.stem, [*psql, "-q", "-1", "-f", migration])
    output = run("card-backed-authority", [*psql, "-Atq", "-f",
                                           sql / "tests/trial_card_backed_authority.sql"])
    marker = [json.loads(x) for x in output.splitlines() if x.startswith("{") and '"assertions"' in x]
    if len(marker) != 1 or not marker[0].get("passed") or marker[0].get("assertions", 0) < 15:
        raise RuntimeError(f"Missing local card-backed assertion receipt: {marker}")
    receipt["test"] = marker[0]
    cash_output = run("existing-paid-cash-trial-regression", [*psql, "-Atq", "-f",
                       sql / "tests/trial_hybrid_funded_serving.sql"])
    cash_marker = [json.loads(x) for x in cash_output.splitlines()
                   if x.startswith("{") and '"assertions"' in x]
    if len(cash_marker) != 1 or not cash_marker[0].get("passed") or cash_marker[0].get("assertions") != 43:
        raise RuntimeError(f"Existing paid-cash path changed: {cash_marker}")
    receipt["existingCashRegression"] = cash_marker[0]
    receipt["passed"] = True
finally:
    if started:
        subprocess.run([tool("pg_ctl"), "-D", str(cluster), "-m", "immediate", "-w", "stop"],
                       env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    shutil.rmtree(cluster, ignore_errors=True)
    shutil.rmtree(socket, ignore_errors=True)
    (out / "card-trial-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")

print(json.dumps({"passed": receipt["passed"], "assertions": receipt.get("test", {}).get("assertions"),
                  "evidence": str(out / "card-trial-receipt.json")}))
