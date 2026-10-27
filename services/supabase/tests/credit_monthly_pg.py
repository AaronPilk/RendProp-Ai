#!/usr/bin/env python3
"""Run monthly Apple-credit settlement proof against disposable PostgreSQL."""
from pathlib import Path
import json
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from tools.audit.run_database_regression import partition_fresh_migrations

SQL = ROOT / "services/supabase"
FIXTURE = SQL / "tests" / (sys.argv[1] if len(sys.argv) > 1 else "credit_monthly_period.sql")
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


with tempfile.TemporaryDirectory(prefix="rendprop-monthly-pg-", dir=str(ROOT.parent)) as data, \
     tempfile.TemporaryDirectory(prefix="rm-", dir="/tmp") as socket:
    run("initdb", [TOOLS["initdb"], "-D", data, "-U", "postgres", "-A", "trust",
                   "--no-locale", "--encoding=UTF8"])
    started = False
    try:
        run("start", [TOOLS["pg_ctl"], "-D", data, "-l", Path(data) / "postgres.log",
                      "-w", "-o", f"-k {socket} -p 55987 -c listen_addresses='' -c shared_buffers=16MB",
                      "start"])
        started = True
        connection = ["-h", socket, "-p", "55987", "-U", "postgres"]
        run("createdb", [TOOLS["createdb"], *connection, "credit_monthly_test"])
        psql = [TOOLS["psql"], "-X", "--no-password", *connection,
                "-d", "credit_monthly_test", "-v", "ON_ERROR_STOP=1"]
        run("bootstrap", [*psql, "-q", "-f", SQL / "tests/ci-bootstrap.sql"])
        migrations, _ = partition_fresh_migrations(sorted((SQL / "migrations").glob("*.sql")))
        for migration in migrations:
            run("migration " + migration.name, [*psql, "-q", "-1", "-f", migration])
        output = run("monthly fixture", [*psql, "-Atq", "-f", FIXTURE])
        results = [json.loads(line) for line in output.splitlines()
                   if line.startswith("{") and '"assertions"' in line]
        assert len(results) == 1 and results[0]["passed"] is True, output
        print(json.dumps({"passed": True, "assertions": results[0]["assertions"],
                          "migrations": len(migrations), "scope": "disposable PostgreSQL"}))
    finally:
        if started:
            run("stop", [TOOLS["pg_ctl"], "-D", data, "-m", "immediate", "-w", "stop"])
