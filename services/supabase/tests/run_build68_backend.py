#!/usr/bin/env python3
"""Fresh local schema + actual review suite + deliberately broken controls.

Only creates its own Unix-socket cluster; no database URL or inherited PG
credentials are accepted. Never touches a running database or production.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    out = args.evidence or Path(tempfile.mkdtemp(prefix="rendprop-build68-evidence-"))
    out.mkdir(parents=True, exist_ok=True)
    # macOS's default per-user TMPDIR can exceed the Unix-socket path limit.
    # This directory is still uniquely owned by this runner; never reuse it.
    cluster = Path(tempfile.mkdtemp(prefix="rp-build68-", dir="/tmp"))
    data, sock = cluster / "data", cluster / "socket"
    sock.mkdir(mode=0o700)
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LC_ALL": "C", "TZ": "UTC",
           "PGOPTIONS": "-c rendprop.build68_fixture=owned-local -c statement_timeout=30000 -c lock_timeout=10000"}
    bins = {n: shutil.which(n) for n in ("initdb", "pg_ctl", "psql", "createdb")}
    if not all(bins.values()):
        raise RuntimeError("Use an already installed PostgreSQL distribution")
    port = "55568"
    connection = ["--no-password", "-h", str(sock), "-p", port, "-U", "postgres"]
    psql = [bins["psql"], "-X", *connection, "-d", "rendprop_build68_audit", "-v", "ON_ERROR_STOP=1"]
    receipt = {"startedAt": datetime.now(timezone.utc).isoformat(), "network": "owned Unix socket; listen_addresses empty",
               "cluster": str(cluster), "commands": [], "passed": False, "controls": [], "races": []}
    def persist():
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2))
    def run(name, command, expected=0, sql=None, failure_contains=None):
        result = subprocess.run(command, cwd=root, env=env, input=sql, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
        log = out / (name + ".log")
        log.write_text(result.stdout)
        receipt["commands"].append({"name": name, "exit": result.returncode, "log": str(log),
                                    "sha256": hashlib.sha256(log.read_bytes()).hexdigest()})
        persist()
        if result.returncode != expected or (failure_contains and failure_contains not in result.stdout):
            raise RuntimeError(f"{name} failed; see {log}: {result.stdout[-1600:]}")
        return result.stdout
    def definition(name):
        return run("read-" + name, psql + ["-Atc", f"select pg_get_functiondef('{name}'::regprocedure)"])
    suite = root / "services/supabase/tests/build68_backend_review.sql"
    migration = root / "services/supabase/migrations/20261013162532_build68_video_and_notification_review.sql"
    started = False
    try:
        run("initdb", [bins["initdb"], "-D", str(data), "-U", "postgres", "-A", "trust", "--no-locale", "--encoding=UTF8"])
        run("start", [bins["pg_ctl"], "-D", str(data), "-l", str(cluster / "postgres.log"), "-w", "-t", "30", "-o",
                      f"-k {sock} -p {port} -c listen_addresses='' -c shared_buffers=32MB -c max_connections=20", "start"])
        started = True
        run("createdb", [bins["createdb"], *connection, "rendprop_build68_audit"])
        identity = run("identity", psql + ["-Atc", "select current_setting('data_directory'),current_setting('listen_addresses'),current_database()"])
        if identity.strip() != f"{data}||rendprop_build68_audit":
            raise RuntimeError("Owned cluster identity mismatch")
        run("bootstrap", psql + ["-q", "-f", str(root / "services/supabase/tests/ci-bootstrap.sql")])
        for path in sorted((root / "services/supabase/migrations").glob("*.sql")):
            run("apply-" + path.stem, psql + ["-q", "-1", "-f", str(path)])
        run("replay-review", psql + ["-q", "-1", "-f", str(migration)])
        positive = run("review-suite", psql + ["-f", str(suite)])
        if not re.search(r"build68_assertions\s*\n[-\s]*61\s*\n", positive):
            raise RuntimeError("Expected all 61 actual SQL assertions")
        receipt["sqlAssertions"] = 61
        # Changes are confined to this new cluster. The same positive suite must
        # expose each mutation, then the exact original function is restored.
        signatures = {
            "billing": "public.app_video_cost_reserve_v2(uuid,uuid,text,text,text,text,text,numeric,numeric,numeric,jsonb,timestamptz,timestamptz,uuid)",
            "drift": "public.app_video_drift_check_begin(uuid,uuid,text,text,text,uuid)",
            "marketing": "public.notification_enqueue(uuid,uuid,text,jsonb,text,timestamptz)",
            "enrollment": "public.handle_new_user()",
        }
        definitions = {name: definition(sig) for name, sig in signatures.items()}
        controls = [
            ("billing", "billing:=public.library_actor_billing_org(p_actor,p_org);", "billing:=p_org;", "Original video quota charge could not be confirmed"),
            ("drift", "if not coalesce(((op.state=", "if false and not coalesce(((op.state=", "concurrent running check cannot obtain a new key"),
            ("marketing", "if v_cat in ('first_tour_nudge','free_week_ending') then", "if v_channel = 'email' and v_cat in ('first_tour_nudge','free_week_ending') then", "default-enabled first-tour push is suppressed"),
            ("enrollment", "and new.email_confirmed_at is not null and not new.is_anonymous", "", "unverified allowlisted email cannot become admin"),
        ]
        for name, before, after, error in controls:
            original = definitions[name]
            if original.count(before) != 1:
                raise RuntimeError(name + " mutation anchor changed")
            run("install-control-" + name, psql, sql=original.replace(before, after))
            run("detect-control-" + name, psql + ["-f", str(suite)], expected=3, failure_contains=error)
            run("restore-" + name, psql, sql=original)
            receipt["controls"].append({"name": name, "detected": True})
        # Keep only synthetic fixtures in this disposable cluster for races.
        fixture = suite.read_text()
        if fixture.count("rollback;") != 1:
            raise RuntimeError("Fixture rollback anchor changed")
        run("race-fixture", psql, sql=fixture.replace("rollback;", "commit;"))
        actor = "c068be01-0000-4000-8000-000000000002"
        org = run("race-org", psql + ["-Atc", f"select org_id from app_video_cost_reservations where actor_id='{actor}' and provider_request_id='crash-paid68'"]).strip()
        call = f"select app_video_drift_check_begin('{actor}','{org}','crash-paid68','aerial','{'c'*32}',null);"
        original = definitions["drift"]
        hook = "  update public.app_video_drift_checks set check_id=gen_random_uuid()"
        if original.count(hook) != 1:
            raise RuntimeError("Concurrent recheck instrumentation anchor changed")
        instrumented = original.replace(hook, "  perform pg_sleep(1);\n" + hook)
        def race(name, body, expected):
            run("install-race-" + name, psql, sql=body)
            run("reset-race-" + name, psql, sql=f"begin;set local role service_role;select app_video_drift_check_finish('{actor}','{org}',(select check_id from app_video_drift_checks where actor_id='{actor}'and source_sha256='{'c'*32}'),'hold',null);commit;")
            command = [*psql, "-c", "begin;set local role service_role;" + call + "commit;"]
            first = subprocess.Popen(command, cwd=root, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            time.sleep(.15)
            second = subprocess.Popen(command, cwd=root, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            outputs = [first.communicate(timeout=40)[0], second.communicate(timeout=40)[0]]
            codes = [first.returncode, second.returncode]
            for index, text in enumerate(outputs):
                (out / f"race-{name}-{index}.log").write_text(text)
            admitted = sum(code == 0 for code in codes)
            receipt["races"].append({"name": name, "admitted": admitted, "expected": expected, "codes": codes,
                                    "instrumentation": "one-second pause before actual hold-to-running update"})
            persist()
            if admitted != expected or (expected == 1 and not any("already running" in s for s in outputs)):
                raise RuntimeError(name + " concurrent result differed from contract")
        race("actual-locks", instrumented, 1)
        # Removing all three actual serialization points lets both callers read
        # HOLD before either writes: two funded identities prove the control.
        mutant = re.sub(r" perform pg_advisory_xact_lock\(hashtextextended\('video_drift_check:'[^\n]+\n", "", instrumented)
        if instrumented.count("for update") != 2 or mutant == instrumented:
            raise RuntimeError("Concurrent serialization mutation anchors changed")
        mutant = mutant.replace(" for update", "")
        race("removed-locks", mutant, 2)
        run("restore-race", psql, sql=original)
        receipt["passed"] = True
    except Exception as error:
        receipt["failure"] = str(error)
        raise
    finally:
        if started:
            run("stop", [bins["pg_ctl"], "-D", str(data), "-m", "immediate", "-w", "stop"])
        paths = [migration, suite, Path(__file__).resolve()]
        receipt["sourceHashes"] = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
        receipt["completedAt"] = datetime.now(timezone.utc).isoformat()
        persist()
        print(json.dumps({"passed": receipt["passed"], "sqlAssertions": receipt.get("sqlAssertions"),
                          "controls": len(receipt["controls"]), "races": receipt["races"], "receipt": str(out / "receipt.json")}, indent=2))

if __name__ == "__main__":
    main()
