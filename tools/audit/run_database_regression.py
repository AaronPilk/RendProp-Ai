#!/usr/bin/env python3
"""Replay repo migrations and invariants in a new local, socket-only cluster.

Never connects to an existing database or accepts a database URL. Child processes
get no inherited PG/service credentials. Data/logs are retained for diagnosis;
only the exact cluster created by this run is stopped in finally.
"""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def main():
    root = Path(__file__).resolve().parents[2]
    environment = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LC_ALL": "C", "TZ": "UTC"}
    bins = {name: shutil.which(name) for name in ("initdb", "pg_ctl", "psql", "createdb")}
    require(all(bins.values()), "Use an already installed PostgreSQL distribution")
    require(shutil.disk_usage(root).free >= 1024**3, "Less than 1 GiB available")
    out = Path(tempfile.mkdtemp(prefix="rendprop-db-audit-", dir="/tmp"))
    data, sockets = out / "cluster", out / "socket"
    sockets.mkdir(mode=0o700)
    receipt = {"sourceCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
               "startedAt": datetime.now(timezone.utc).isoformat(), "evidence": str(out), "commands": [],
               "network": "Unix socket only; listen_addresses empty", "accepted": False,
               "limits": ["Plain local Postgres, not hosted Supabase", "Minimal synthetic auth schema",
                          "No actual JWT verification or HTTP Data API", "No deployed cron verification"]}
    sqlroot = root / "services/supabase"
    migrations = sorted((sqlroot / "migrations").glob("*.sql"))
    sources = migrations + [sqlroot / "tests/ci-bootstrap.sql", sqlroot / "tests/invariants.sql"]
    receipt["sourceHashes"] = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    print("EVIDENCE:", out, flush=True)

    def run(name, command, expected=0, input_text=None):
        result = subprocess.run(command, env=environment, cwd=root, input=input_text, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
        log = out / (name + ".log")
        log.write_text(result.stdout)
        receipt["commands"].append({"name": name, "command": command, "exit": result.returncode,
                                    "log": str(log), "logSHA256": hashlib.sha256(log.read_bytes()).hexdigest()})
        require(result.returncode == expected, f"{name} exited {result.returncode}, expected {expected}; see {log}")
        print(name + ": exit=" + str(result.returncode), flush=True)
        return result.stdout

    connection = ["-h", str(sockets), "-p", "55439", "-U", "postgres"]
    psql = [bins["psql"], "-X", "--no-password", *connection, "-d", "rendprop_audit",
            "-v", "ON_ERROR_STOP=1"]
    started = False
    try:
        run("version", [bins["psql"], "--version"])
        run("initdb", [bins["initdb"], "-D", str(data), "-U", "postgres", "-A", "trust",
                       "--no-locale", "--encoding=UTF8"])
        run("start", [bins["pg_ctl"], "-D", str(data), "-l", str(out / "postgres.log"), "-w", "-t", "30",
                      "-o", f"-k {sockets} -p 55439 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=20", "start"])
        started = True
        run("createdb", [bins["createdb"], "--no-password", *connection, "rendprop_audit"])
        identity = run("identity", psql + ["-Atc", "select current_setting('data_directory'),current_setting('listen_addresses'),current_database();"])
        require(identity.strip() == f"{data}||rendprop_audit", "Cluster identity/network mismatch")
        environment["PGOPTIONS"] = "-c statement_timeout=30000 -c lock_timeout=5000"
        run("bootstrap", psql + ["-q", "-f", str(sqlroot / "tests/ci-bootstrap.sql")])
        for migration in migrations:
            run("apply-" + migration.stem, psql + ["-q", "-1", "-f", str(migration)])
        counts = []
        for phase in ("initial", "replayed"):
            if phase == "replayed":
                replay = [p for p in migrations if p.name.startswith(("0005b_", "0008b_")) or p.name >= "0009"]
                for migration in replay:
                    run("replay-" + migration.stem, psql + ["-q", "-1", "-f", str(migration)])
                receipt["replayedMigrations"] = len(replay)
            output = run("invariants-" + phase, psql + ["-f", str(sqlroot / "tests/invariants.sql")])
            count = re.findall(r"All (\d+) invariants passed\.", output)
            require(len(count) == 1 and int(count[0]) > 0, "Missing/ambiguous actual invariant count")
            counts.append(int(count[0]))
        require(counts[0] == counts[1], "Invariant count changed on replay")
        # Break actual entitlement data in this synthetic database. A gate that
        # only prints results must not pass when the published contract is false.
        run("mutate-negative", psql + ["-c", "update public.plan_entitlements set seats=999 where plan='team';"])
        failed = run("negative-invariants", psql + ["-f", str(sqlroot / "tests/invariants.sql")], expected=3)
        require("INVARIANTS FAILED:" in failed, "Negative control failed for the wrong reason")
        require(all(hashlib.sha256(p.read_bytes()).hexdigest() == receipt["sourceHashes"][str(p.relative_to(root))]
                    for p in sources), "SQL sources changed during run")
        receipt.update({"accepted": True, "appliedMigrations": len(migrations), "invariantsEachPass": counts[0],
                        "negativeControl": "Actual team entitlement corrupted; real invariant gate exited 3"})
    finally:
        if started or (data / "postmaster.pid").exists():
            run("stop", [bins["pg_ctl"], "-D", str(data), "-w", "-t", "30", "-m", "fast", "stop"])
        receipt["finishedAt"] = datetime.now(timezone.utc).isoformat()
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print("PASS: migrations, replay, actual invariants and negative control;", out / "receipt.json", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("FAIL:", type(error).__name__, str(error), flush=True)
        sys.exit(1)
