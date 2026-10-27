#!/usr/bin/env python3
"""Prove credit purchase, refund, downgrade and hold invariants in local PostgreSQL."""
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from tools.audit.run_database_regression import partition_fresh_migrations

SQL = ROOT / "services/supabase"
TOOLS = {name: shutil.which(name) or str(Path("/opt/homebrew/opt/postgresql@17/bin") / name)
         for name in ("initdb", "pg_ctl", "createdb", "psql")}
ENV = {"PATH": "/opt/homebrew/bin:/usr/bin:/bin", "LC_ALL": "C",
       "PGOPTIONS": "-c statement_timeout=60000 -c lock_timeout=15000"}


def run(label, args):
    result = subprocess.run([str(x) for x in args], cwd=ROOT, env=ENV,
                            text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=240)
    if result.returncode:
        raise AssertionError(f"{label} failed:\n{result.stdout[-6000:]}")
    return result.stdout


with tempfile.TemporaryDirectory(prefix="rendprop-credit-pg-", dir=str(ROOT.parent)) as data, \
     tempfile.TemporaryDirectory(prefix="rc-", dir="/tmp") as socket:
    # The database cluster is disposable and never uses the hosted Supabase DB.
    run("initdb", [TOOLS["initdb"], "-D", data, "-U", "postgres", "-A", "trust",
                   "--no-locale", "--encoding=UTF8"])
    started = False
    try:
        run("start", [TOOLS["pg_ctl"], "-D", data, "-l", Path(data) / "postgres.log",
                      "-w", "-o", f"-k {socket} -p 55986 -c listen_addresses='' -c shared_buffers=16MB",
                      "start"])
        started = True
        connection = ["-h", socket, "-p", "55986", "-U", "postgres"]
        run("createdb", [TOOLS["createdb"], *connection, "credit_wallet_test"])
        psql = [TOOLS["psql"], "-X", "--no-password", *connection,
                "-d", "credit_wallet_test", "-v", "ON_ERROR_STOP=1"]
        run("bootstrap", [*psql, "-q", "-f", SQL / "tests/ci-bootstrap.sql"])
        migrations, _ = partition_fresh_migrations(sorted((SQL / "migrations").glob("*.sql")))
        for migration in migrations:
            run("migration " + migration.name, [*psql, "-q", "-1", "-f", migration])
        output = run("wallet fixture", [*psql, "-Atq", "-f", SQL / "tests/credit_wallet.sql"])
        results = [json.loads(line) for line in output.splitlines()
                   if line.startswith("{") and '"assertions"' in line]
        assert len(results) == 1 and results[0]["passed"] is True, output
        photo_output = run("photo credit fixture", [*psql, "-Atq", "-f", SQL / "tests/credit_photo_spend.sql"])
        photo_results = [json.loads(line) for line in photo_output.splitlines()
                         if line.startswith("{") and '"assertions"' in line]
        assert len(photo_results) == 1 and photo_results[0]["passed"] is True, photo_output
        trial_output = run("trial activation readiness fixture", [*psql, "-Atq", "-f", SQL / "tests/trial_activation_readiness.sql"])
        trial_results = [json.loads(line) for line in trial_output.splitlines()
                         if line.startswith("{") and '"assertions"' in line]
        assert len(trial_results) == 1 and trial_results[0]["passed"] is True, trial_output
        print(json.dumps({"passed": True,
                          "assertions": results[0]["assertions"] + photo_results[0]["assertions"] + trial_results[0]["assertions"],
                          "migrations": len(migrations), "scope": "disposable PostgreSQL"}))
    finally:
        if started:
            run("stop", [TOOLS["pg_ctl"], "-D", data, "-m", "immediate", "-w", "stop"])
