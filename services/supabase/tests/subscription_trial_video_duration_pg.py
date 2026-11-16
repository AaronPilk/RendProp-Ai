#!/usr/bin/env python3
"""Fresh/replayed actual trial-video SQL with disposable Unix-socket Postgres.

No inherited credentials, production schema, R2 reads or provider calls. The
separately owned prospective purchase-reservation overlay is not needed to
exercise this fixture's explicitly synthetic funding/grant and is not replayed.
"""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
SQL = ROOT / "services/supabase"
MIGRATION = SQL / "migrations/20261006213000_subscription_trial_video_duration.sql"
MIGRATIONS = [m for m in sorted((SQL / "migrations").glob("*.sql")) if m.name <= MIGRATION.name]
FIXTURE = SQL / "tests/subscription_trial_video_duration.sql"
TOOLS = {name: shutil.which(name) or str(Path("/opt/homebrew/opt/postgresql@17/bin") / name)
         for name in ("initdb", "pg_ctl", "psql", "createdb")}
if not all(Path(p).is_file() and os.access(p, os.X_OK) for p in TOOLS.values()):
    raise RuntimeError("Use existing PostgreSQL binaries")
OUT = Path(tempfile.mkdtemp(prefix="rendprop-trial-video-pg-", dir="/tmp"))
DATA, SOCK = OUT / "data", OUT / "socket"
SOCK.mkdir()
ENV = {"PATH": "/opt/homebrew/bin:/usr/bin:/bin", "LC_ALL": "C",
       "PGOPTIONS": "-c statement_timeout=30000 -c lock_timeout=15000"}
PORT = "55488"
SOURCES = [*MIGRATIONS, FIXTURE, SQL / "tests/ci-bootstrap.sql", Path(__file__).resolve()]
receipt = {"kind": "owned disposable local PostgreSQL; zero live/R2/provider calls",
           "output": str(OUT), "commands": [], "migrationCount": len(MIGRATIONS),
           "sourceHashes": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}}


def run(name, args):
    result = subprocess.run([str(x) for x in args], env=ENV, cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    log = OUT / (name + ".log")
    log.write_text(result.stdout)
    receipt["commands"].append({"name": name, "exit": result.returncode,
                                "log_sha256": hashlib.sha256(log.read_bytes()).hexdigest()})
    if result.returncode:
        raise RuntimeError(f"{name} failed: {result.stdout[-2500:]} ({log})")
    print(name + ": pass", flush=True)
    return result.stdout


started = False
try:
    receipt["postgresVersion"] = run("version", [TOOLS["psql"], "--version"]).strip()
    run("initdb", [TOOLS["initdb"], "-D", DATA, "-U", "postgres", "-A", "trust", "--no-locale", "--encoding=UTF8"])
    run("start", [TOOLS["pg_ctl"], "-D", DATA, "-l", OUT / "server.log", "-w", "-t", "30", "-o",
                  f"-k {SOCK} -p {PORT} -c listen_addresses='' -c shared_buffers=16MB", "start"])
    started = True
    connection = ["-h", SOCK, "-p", PORT, "-U", "postgres"]
    run("createdb", [TOOLS["createdb"], *connection, "trial_video_audit"])
    psql = [TOOLS["psql"], "-X", "--no-password", *connection, "-d", "trial_video_audit", "-v", "ON_ERROR_STOP=1"]
    run("bootstrap", [*psql, "-q", "-f", SQL / "tests/ci-bootstrap.sql"])
    for migration in MIGRATIONS:
        run("apply-" + migration.stem, [*psql, "-q", "-1", "-f", migration])
    receipt["fresh"] = run("video-fresh", [*psql, "-Atq", "-f", FIXTURE]).strip()
    run("replay-video", [*psql, "-q", "-f", MIGRATION])
    receipt["replay"] = run("video-replay", [*psql, "-Atq", "-f", FIXTURE]).strip()
    if "TRIAL_VIDEO_CHECKS" not in receipt["fresh"] or "TRIAL_VIDEO_CHECKS" not in receipt["replay"]:
        raise RuntimeError("Actual SQL proof did not complete")
    receipt["passed"] = True
finally:
    if started:
        run("stop", [TOOLS["pg_ctl"], "-D", DATA, "-m", "fast", "-w", "stop"])
    receipt["sourceUnchanged"] = all(hashlib.sha256((ROOT / p).read_bytes()).hexdigest() == digest
                                      for p, digest in receipt["sourceHashes"].items())
    (OUT / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(str(OUT / "receipt.json"), flush=True)
