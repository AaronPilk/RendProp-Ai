#!/usr/bin/env python3
"""Closed address resolver regression on disposable socket-only PostgreSQL."""
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
parser.add_argument("--evidence-dir", type=Path)
args = parser.parse_args()
out = args.evidence_dir or Path(tempfile.mkdtemp(prefix="rendprop-address-pg-"))
out.mkdir(parents=True, exist_ok=True)
data = Path(tempfile.mkdtemp(prefix="rendprop-address-data-"))
socket = Path(tempfile.mkdtemp(prefix="rendprop-address-socket-"))
tools = {name: shutil.which(name) or str(Path("/opt/homebrew/opt/postgresql@17/bin") / name)
         for name in ("initdb", "pg_ctl", "psql", "createdb")}
assert all(Path(path).is_file() and os.access(path, os.X_OK) for path in tools.values())
environment = {"PATH": "/opt/homebrew/bin:/usr/bin:/bin", "LC_ALL": "C",
               "PGOPTIONS": "-c statement_timeout=30000 -c lock_timeout=15000"}
sources = [*sorted((SQL / "migrations").glob("*.sql")), SQL / "tests/ci-bootstrap.sql",
           SQL / "tests/property_address_lookup.sql", Path(__file__).resolve()]
hashes = lambda: {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}
receipt = {"passed": False, "scope": "disposable socket-only PostgreSQL; synthetic identities",
           "networkCalls": 0, "providerCalls": 0, "productionMutations": 0,
           "sourceHashes": hashes(), "commands": []}

def run(name, argv, stdin=None):
    result = subprocess.run([str(arg) for arg in argv], input=stdin, text=True,
                            env=environment, cwd=ROOT, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=120)
    (out / f"{name}.log").write_text(result.stdout)
    receipt["commands"].append({"name": name, "exit": result.returncode,
                                "logSHA256": hashlib.sha256(result.stdout.encode()).hexdigest()})
    assert result.returncode == 0, (name, result.stdout[-3500:])
    return result.stdout

started = False
try:
    run("initdb", [tools["initdb"], "-D", data, "-U", "postgres", "-A", "trust",
                   "--no-locale", "--encoding=UTF8"])
    run("start", [tools["pg_ctl"], "-D", data, "-l", out / "postgres.log", "-w", "-t", "30",
                  "-o", f"-k {socket} -p 55544 -c listen_addresses='' -c shared_buffers=16MB", "start"])
    started = True
    connection = ["-h", socket, "-p", "55544", "-U", "postgres"]
    run("createdb", [tools["createdb"], *connection, "address_lookup"])
    psql = [tools["psql"], "-X", "--no-password", *connection, "-d", "address_lookup",
            "-v", "ON_ERROR_STOP=1"]
    run("bootstrap", [*psql, "-q", "-f", SQL / "tests/ci-bootstrap.sql"])
    for migration in sorted((SQL / "migrations").glob("*.sql")):
        run("apply-" + migration.stem, [*psql, "-q", "-1", "-f", migration])
    output = run("address-contract", [*psql, "-Atq", "-f", SQL / "tests/property_address_lookup.sql"])
    proofs = [json.loads(line) for line in output.splitlines() if line.startswith("{") and '"assertions"' in line]
    assert len(proofs) == 1 and proofs[0]["passed"] and proofs[0]["assertions"] >= 22, proofs
    receipt["unit"] = proofs[0]
    assert hashes() == receipt["sourceHashes"], "source changed during verification"
    receipt["passed"] = True
finally:
    if started:
        run("stop", [tools["pg_ctl"], "-D", data, "-m", "immediate", "-w", "-t", "30", "stop"])
    receipt["clusterStopped"] = not (data / "postmaster.pid").exists()
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    if receipt["clusterStopped"]:
        shutil.rmtree(data, ignore_errors=True)
        shutil.rmtree(socket, ignore_errors=True)
    print(json.dumps({"passed": receipt["passed"], "receipt": str(out / "receipt.json")}))
