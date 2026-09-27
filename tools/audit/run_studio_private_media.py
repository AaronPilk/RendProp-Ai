#!/usr/bin/env python3
"""Private-project/media SQL and transport regression in an owned local fixture.

Never accepts a database URL, service token or storage credentials. PostgreSQL
listens only on a newly created Unix socket. Deno uses a warmed dependency cache,
fixture-only signing values, mocked storage and denied network/process/write I/O.
Logs/source hashes are retained; only this runner's cluster is stopped.
"""
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile


def main():
    root = Path(__file__).resolve().parents[2]
    helper = root / "tools/audit/studio_private_media"
    sqlroot = root / "services/supabase"
    environment = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LC_ALL": "C", "TZ": "UTC"}
    bins = {name: shutil.which(name) for name in ("initdb", "pg_ctl", "psql", "createdb", "deno")}
    if not all(bins.values()):
        raise RuntimeError("Use already installed PostgreSQL and Deno binaries; warm Deno dependencies first")
    if shutil.disk_usage(tempfile.gettempdir()).free < 512 * 1024**2:
        raise RuntimeError("Need at least 512 MiB for the disposable database fixture")
    out = Path(tempfile.mkdtemp(prefix="rendprop-private-media-audit-", dir="/tmp")).resolve()
    sockets, data = out / "socket", out / "cluster"
    sockets.mkdir(mode=0o700)
    migrations = sorted((sqlroot / "migrations").glob("*.sql"))
    fixtures = [sqlroot / "tests" / name for name in (
        "studio_private_project_media.sql", "studio_property_music.sql", "studio_private_music_withdrawal.sql")]
    tests = [helper / "recovery.test.ts", helper / "r2-dispatch.test.ts",
             sqlroot / "functions/studio/property-music.test.ts", sqlroot / "functions/studio/documents.test.ts"]
    sources = migrations + fixtures + tests + [Path(__file__).resolve(), helper / "concurrency.py",
        sqlroot / "tests/ci-bootstrap.sql"] + [sqlroot / "functions" / name for name in (
            "studio/project-media.ts", "studio/property-music.ts", "studio/projects.ts",
            "studio/documents.ts", "_shared/r2.ts")]
    hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    receipt = {"createdAt": datetime.now(timezone.utc).isoformat(), "evidence": str(out),
               "sourceCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
               "sourceHashes": hashes, "commands": [], "passed": False,
               "limits": ["Local synthetic auth/SQL, not deployed Supabase or real JWT authorization",
                          "Storage fetches mocked; no real upload/deletion/AI provider",
                          "Previously issued signed URLs remain bounded bearer capabilities until expiry"]}
    print("EVIDENCE:", out, flush=True)

    def run(name, command, stdin=None):
        result = subprocess.run(command, cwd=root, env=environment, input=stdin, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
        log = out / (name + ".log")
        log.write_text(result.stdout)
        receipt["commands"].append({"name": name, "exit": result.returncode,
                                    "log": str(log), "sha256": hashlib.sha256(log.read_bytes()).hexdigest()})
        print(name, result.returncode, flush=True)
        if result.returncode:
            raise RuntimeError(f"{name} failed: {log}\n{result.stdout[-1200:]}")
        return result.stdout

    connection = ["-h", str(sockets), "-p", "55447", "-U", "postgres"]
    psql = [bins["psql"], "-X", "--no-password", *connection, "-d", "rendprop_audit", "-v", "ON_ERROR_STOP=1"]
    started = False
    old_handlers = {}
    def interrupted(signum, _frame):
        raise RuntimeError(f"Private-media audit interrupted by signal {signum}")
    for sig in (signal.SIGTERM, signal.SIGHUP):
        old_handlers[sig] = signal.signal(sig, interrupted)
    try:
        run("init", [bins["initdb"], "-D", str(data), "-U", "postgres", "-A", "trust", "--no-locale", "--encoding=UTF8"])
        started = True  # A partially acknowledged start still needs owned cleanup.
        run("start", [bins["pg_ctl"], "-D", str(data), "-l", str(out / "postgres.log"), "-w", "-t", "30",
                      "-o", f"-k {sockets} -p 55447 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=20", "start"])
        run("create", [bins["createdb"], "--no-password", *connection, "rendprop_audit"])
        identity = run("identity", psql + ["-Atc", "select current_setting('data_directory'),current_setting('listen_addresses'),current_database();"])
        if identity.strip() != f"{data}||rendprop_audit":
            raise RuntimeError("Database identity/network mismatch")
        environment["PGOPTIONS"] = "-c statement_timeout=30000 -c lock_timeout=5000"
        run("bootstrap", psql + ["-q", "-f", str(sqlroot / "tests/ci-bootstrap.sql")])
        for migration in migrations:
            run("migration-" + migration.stem, psql + ["-q", "-f", str(migration)])
        for fixture in fixtures:
            output = run(fixture.stem, psql + ["-f", str(fixture)])
            if fixture.name == "studio_private_project_media.sql" and not re.search(r"passed\s*\n-+\s*\n\s*51\s*\n", output):
                raise RuntimeError("Expected all 51 independent project/media SQL checks")
        spec = importlib.util.spec_from_file_location("studio_private_media_concurrency", helper / "concurrency.py")
        concurrency = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(concurrency)
        receipt["concurrency"] = concurrency.concurrent_checks(psql, environment, out, run)
        environment["DENO_DIR"] = os.environ.get("DENO_DIR") or str(Path.home() / (
            "Library/Caches/deno" if sys.platform == "darwin" else ".cache/deno"))
        environment.update(CLOUDFLARE_ACCOUNT_ID="fixture-account", R2_ACCESS_KEY_ID="fixture-access",
                           R2_SECRET_ACCESS_KEY="fixture-secret", R2_BUCKET_UPLOADS="fixture-uploads", NO_COLOR="1")
        output = run("offline-transport", [bins["deno"], "test", "--cached-only", "--no-config", "--no-lock",
                    "--node-modules-dir=none", "--deny-net", "--deny-run", "--deny-write", "--allow-read", "--allow-env", *map(str, tests)])
        match = re.search(r"ok \| (\d+) passed \| 0 failed", output)
        if not match or int(match[1]) < 31:
            raise RuntimeError("Expected at least 31 transport/document/music assertions with no failures")
        receipt["checks"] = {"privateProjectSQL": 51, "musicSQLFixtures": 2, "twoConnectionRaces": 2,
                             "typecheckedDenoTests": int(match[1])}
        for name, digest in hashes.items():
            if hashlib.sha256((root / name).read_bytes()).hexdigest() != digest:
                raise RuntimeError("Source changed during verification: " + name)
        receipt["passed"] = True
    finally:
        try:
            if started and (data / "postmaster.pid").exists():
                run("stop", [bins["pg_ctl"], "-D", str(data), "-m", "immediate", "-w", "stop"])
        finally:
            for sig, handler in old_handlers.items():
                signal.signal(sig, handler)
            (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print("PASS:", receipt["checks"], flush=True)


if __name__ == "__main__":
    main()
