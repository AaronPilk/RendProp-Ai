#!/usr/bin/env python3
"""Prove the seven-day creative limits on disposable PostgreSQL only.

Pass an evidence directory on the external volume. No hosted database or
provider credentials are used, and every synthetic account is disposable.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
SQL = ROOT / "services/supabase"
parser = argparse.ArgumentParser()
parser.add_argument("--evidence-dir", type=Path, required=True)
args = parser.parse_args()
out = args.evidence_dir.resolve()
out.mkdir(parents=True, exist_ok=True)
assert shutil.disk_usage(out).free >= 10 * 1024**3, "External evidence volume needs 10 GiB free"
data = Path(tempfile.mkdtemp(prefix="limited-trial-pg-", dir=out))
socket = Path(tempfile.mkdtemp(prefix="lt-", dir="/tmp"))
port = "55977"
env = {
    "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
    "LC_ALL": "C",
    "TMPDIR": str(out),
    "PGOPTIONS": "-c statement_timeout=60000 -c lock_timeout=15000",
}
tool = lambda name: shutil.which(name) or str(Path("/opt/homebrew/opt/postgresql@17/bin") / name)
migrations = sorted((SQL / "migrations").glob("*.sql"))
inputs = [SQL / "tests/ci-bootstrap.sql", *migrations,
          SQL / "tests/limited_trial_creative_spend.sql",
          SQL / "tests/subscription_confirmed_trial.sql",
          SQL / "tests/invariants.sql", SQL / "tests/property_video_jobs.sql",
          SQL / "tests/paid_quality_processing.sql", Path(__file__).resolve()]
hashes = {
    str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
    for path in inputs
}
receipt = {"passed": False, "scope": "disposable local PostgreSQL; no network/provider calls",
           "sourceHashes": hashes, "commands": []}
started = False


def run(name, command, refuses=None, body=None):
    result = subprocess.run(
        [str(part) for part in command], cwd=ROOT, env=env,
        input=body, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, timeout=240,
    )
    log = out / (name + ".log")
    log.write_text(result.stdout)
    receipt["commands"].append({
        "name": name, "exit": result.returncode,
        "logSHA256": hashlib.sha256(log.read_bytes()).hexdigest(),
    })
    if refuses is not None:
        assert result.returncode and refuses in result.stdout, (
            f"{name} did not fail closed as expected:\n{result.stdout[-8000:]}")
        return result.stdout
    if result.returncode:
        raise AssertionError(f"{name} failed:\n{result.stdout[-8000:]}")
    return result.stdout


try:
    run("initdb", [tool("initdb"), "-D", data, "-U", "postgres", "-A", "trust",
                   "--no-locale", "--encoding=UTF8"])
    run("start", [tool("pg_ctl"), "-D", data, "-l", out / "postgres.log", "-w",
                  "-o", f"-k {socket} -p {port} -c listen_addresses='' -c shared_buffers=16MB",
                  "start"])
    started = True
    connection = ["-h", socket, "-p", port, "-U", "postgres"]
    run("createdb", [tool("createdb"), *connection, "rendprop_audit"])
    psql = [tool("psql"), "-X", "--no-password", *connection,
            "-d", "rendprop_audit", "-v", "ON_ERROR_STOP=1"]
    run("bootstrap", [*psql, "-q", "-f", SQL / "tests/ci-bootstrap.sql"])
    for migration in migrations:
        run("apply-" + migration.stem, [*psql, "-q", "-1", "-f", migration])
    output = run("fresh-limited-trial", [
        *psql, "-Atq", "-f", SQL / "tests/limited_trial_creative_spend.sql"])
    rows = [json.loads(line) for line in output.splitlines()
            if line.startswith("{") and '"assertions"' in line]
    assert len(rows) == 1 and rows[0]["passed"], rows
    receipt["fresh"] = rows[0]
    run("replay-refused-by-cas", [*psql, "-q", "-1", "-f", migrations[-1]],
        refuses="Review changed org_entitlement before limited-trial migration")
    output = run("post-refusal-limited-trial", [
        *psql, "-Atq", "-f", SQL / "tests/limited_trial_creative_spend.sql"])
    rows = [json.loads(line) for line in output.splitlines()
            if line.startswith("{") and '"assertions"' in line]
    assert len(rows) == 1 and rows[0]["passed"], rows
    receipt["postRefusal"] = rows[0]
    confirmed = run("confirmed-Apple-intro-and-paid-renewal", [
        *psql, "-Atq", "-f", SQL / "tests/subscription_confirmed_trial.sql"])
    assert "\n27\n" in confirmed and confirmed.count("|t") == 27, confirmed[-1000:]
    receipt["confirmedTrialAssertions"] = 27
    invariants = run("all-database-invariants", [
        *psql, "-f", SQL / "tests/invariants.sql"])
    assert "All " in invariants and " invariants passed." in invariants
    base = (SQL / "tests/property_video_jobs.sql").read_text()
    seed = base[base.index("insert into auth.users"):
                base.index("select pg_temp.ok((select bool_and")]
    paid = "begin;\n" + seed + "\n" + (
        SQL / "tests/paid_quality_processing.sql").read_text()
    output = run("paid-quality-regression", [*psql, "-Atq"], body=paid)
    rows = [json.loads(line) for line in output.splitlines()
            if line.startswith("{") and '"assertions"' in line]
    assert len(rows) == 1 and rows[0]["passed"], rows
    receipt["paidQuality"] = rows[0]
    assert all(hashlib.sha256(path.read_bytes()).hexdigest() == digest
               for path, digest in ((ROOT / name, value) for name, value in hashes.items()))
    receipt["passed"] = True
    print(json.dumps({"passed": True, "freshAssertions": receipt["fresh"]["assertions"],
                      "postRefusalAssertions": receipt["postRefusal"]["assertions"],
                      "invariants": "passed", "paidQualityAssertions": rows[0]["assertions"],
                      "receipt": str(out / "receipt.json")}))
finally:
    if started:
        run("stop", [tool("pg_ctl"), "-D", data, "-m", "immediate", "-w", "stop"])
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    shutil.rmtree(data)
    shutil.rmtree(socket)
