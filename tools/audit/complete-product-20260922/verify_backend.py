#!/usr/bin/env python3
"""Source-bound offline edge tests and owned socket-only migration integration.

This runner accepts a work in progress tree and records exact hashes. It never
uses inherited service/database credentials or connects to an existing database.
Dependency caching is the only network-capable step; executed tests deny network.
"""
from concurrent.futures import ThreadPoolExecutor
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]
FUNCTIONS = ROOT / "services/supabase/functions"
SQL = ROOT / "services/supabase"
OUT = Path(tempfile.mkdtemp(prefix="rendprop-complete-backend-", dir="/tmp"))
ENV = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LC_ALL": "C", "NO_COLOR": "1", "DENO_NO_PROMPT": "1"}
RECEIPT = {"output": str(OUT), "commands": [], "productionCalls": 0, "paidCalls": 0}


def manifest():
    files = [p for p in FUNCTIONS.rglob("*.ts") if "node_modules" not in p.parts]
    files += list(SQL.glob("*/*.sql"))
    files += list((ROOT / "tools/audit").glob("*.ts"))
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)}


def run(name, command, *, expected=(0,), timeout=120, env=ENV, cwd=ROOT):
    started = time.monotonic()
    try:
        result = subprocess.run([str(x) for x in command], cwd=cwd, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        code, output = result.returncode, result.stdout
    except subprocess.TimeoutExpired as error:
        code, output = 124, error.stdout or b""
        if isinstance(output, bytes): output = output.decode(errors="replace")
    log = OUT / (name + ".log")
    log.write_text(output)
    record = {"name": name, "exit": code, "seconds": round(time.monotonic() - started, 3),
              "log": str(log), "logSHA256": hashlib.sha256(log.read_bytes()).hexdigest()}
    RECEIPT["commands"].append(record)
    print(f"{name}: exit={code}", flush=True)
    if code not in expected: raise RuntimeError(f"{name} failed; retained log: {log}")
    return output


def edge():
    deno = shutil.which("deno")
    info = json.loads(subprocess.check_output([deno, "info", "--no-config", "--json"], env=ENV, text=True))
    ENV["DENO_DIR"] = info["denoDir"]
    files = sorted(p for p in FUNCTIONS.rglob("*.ts") if "node_modules" not in p.parts and p.name.endswith((".test.ts", "_test.ts")))
    routes = sorted(p for p in FUNCTIONS.glob("*/index.ts") if p.parent.name != "_shared")
    run("dependencies", [deno, "install", "--no-config", "--no-lock", "--node-modules-dir=auto", "--entrypoint", *files, *routes], cwd=FUNCTIONS)
    output = run("edge-unit", [deno, "test", "--no-config", "--no-lock", "--cached-only", "--node-modules-dir=auto",
              "--deny-net", "--deny-run", "--deny-write", "--allow-read=" + str(ROOT), "--allow-env", *files], cwd=FUNCTIONS)
    counts = re.findall(r"^ok \| (\d+) passed \| (\d+) failed(?: \| (\d+) ignored)?", output, re.MULTILINE)
    if len(counts) != 1 or counts[0][1] != "0" or counts[0][2] not in ("", "0"):
        raise RuntimeError("Missing or failed edge summary")
    RECEIPT["edge"] = {"passed": int(counts[0][0]), "failed": 0, "ignored": 0, "testFiles": len(files), "runtimeNetwork": False}
    def check(path):
        run("check-" + path.parent.name, [deno, "check", "--no-config", "--no-lock", "--node-modules-dir=auto", "--deny-import", path], cwd=FUNCTIONS)
    with ThreadPoolExecutor(max_workers=2) as pool: list(pool.map(check, routes))
    RECEIPT["edge"]["typecheckedEntrypoints"] = len(routes)


def postgres():
    binary = Path("/opt/homebrew/opt/postgresql@17/bin")
    if not (binary / "initdb").is_file(): raise RuntimeError("Explicit PostgreSQL17 binaries missing")
    data, socket = OUT / "data", OUT / "socket"
    socket.mkdir()
    pg_env = {**ENV, "PGOPTIONS": "-c statement_timeout=30000 -c lock_timeout=5000"}
    connection = ["-h", socket, "-p", "55462", "-U", "postgres"]
    started = False
    migrations = sorted((SQL / "migrations").glob("*.sql"))
    historical = [p for p in migrations if p.name < "0055"]
    studio = [p for p in migrations if p.name.startswith("20260914")]
    later = [SQL / "migrations/0055_video_reflection_jobs.sql", SQL / "migrations/0056_active_photo_fallback.sql"]
    if set(historical + studio + later) != set(migrations): raise RuntimeError("Migration inventory changed; review new files")
    RECEIPT["postgres"] = {"migrationFiles": len(migrations), "studioMigrations": len(studio), "orders": {}, "listener": "Unix socket only"}
    try:
        run("initdb", [binary / "initdb", "-D", data, "-U", "postgres", "-A", "trust", "--no-locale", "--encoding=UTF8"], env=pg_env)
        run("start", [binary / "pg_ctl", "-D", data, "-l", OUT / "server.log", "-w", "-t", "30", "-o",
                       f"-k {socket} -p 55462 -c listen_addresses='' -c shared_buffers=16MB", "start"], env=pg_env)
        started = True
        for name, sequence in [("erase_fresh", migrations), ("erase_audit", historical + studio + later)]:
            run(name + "-create", [binary / "createdb", *connection, name], env=pg_env)
            psql = [binary / "psql", "-X", "--no-password", *connection, "-d", name, "-v", "ON_ERROR_STOP=1"]
            run(name + "-bootstrap", [*psql, "-q", "-f", SQL / "tests/ci-bootstrap.sql"], env=pg_env)
            for m in sequence: run(name + "-apply-" + m.stem, [*psql, "-q", "-1", "-f", m], env=pg_env)
            for suffix in ("before-replay", "after-replay"):
                if suffix == "after-replay":
                    for m in later: run(name + "-replay-" + m.stem, [*psql, "-q", "-1", "-f", m], env=pg_env)
                for fixture in ("video_erase", "legacy_photo_fallback", "voice_storage_reservations"):
                    run(name + "-" + fixture + "-" + suffix, [*psql, "-f", SQL / "tests" / (fixture + ".sql")], env=pg_env)
            inv = run(name + "-invariants", [*psql, "-f", SQL / "tests/invariants.sql"], expected=(0, 3), env=pg_env)
            red = [line for line in inv.splitlines() if re.search(r"\|\s*f\s*\|", line)]
            RECEIPT["postgres"]["orders"][name] = {"sequence": [p.name for p in sequence], "redInvariants": red}
            if len(red) != 1 or "each astra ceiling clears its route" not in red[0]:
                raise RuntimeError(f"{name}: unexpected invariant failures")
            if name == "erase_audit":
                result = run("erase-concurrency", ["/usr/bin/python3", ROOT / "tools/audit/call-20260919/web/erase-concurrency.py", *psql], env=pg_env)
                RECEIPT["postgres"]["concurrency"] = json.loads(result)
    finally:
        if started:
            run("stop", [binary / "pg_ctl", "-D", data, "-m", "fast", "-w", "stop"], env=pg_env)
            RECEIPT["postgres"]["clusterStopped"] = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("edge", "postgres"))
    mode = parser.parse_args().mode
    RECEIPT["mode"] = mode
    RECEIPT["sourceFiles"] = manifest()
    try:
        globals()[mode]()
        RECEIPT["sourceUnchanged"] = RECEIPT["sourceFiles"] == manifest()
        if not RECEIPT["sourceUnchanged"]: raise RuntimeError("Source changed during verification; see bound hashes")
        RECEIPT["passed"] = True
    except Exception as error:
        RECEIPT["passed"] = False
        RECEIPT["error"] = str(error)
    finally:
        (OUT / "receipt.json").write_text(json.dumps(RECEIPT, indent=2) + "\n")
        print("Receipt:", OUT / "receipt.json", flush=True)
    return 0 if RECEIPT["passed"] else 1


if __name__ == "__main__": raise SystemExit(main())
