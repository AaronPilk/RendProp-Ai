#!/usr/bin/env python3
"""Real shared serving budgets, Apple funding and replay in local Postgres.

No inherited credentials, network listener, hosted database or provider calls.
The receipt binds all migrations, fixtures and this runner to their SHA256.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[3]
SQL = ROOT / "services/supabase"
MIGRATION = SQL / "migrations/20261006164721_funded_serving_and_app_review_authority.sql"
TOOLS = {name: shutil.which(name) or str(Path("/opt/homebrew/opt/postgresql@17/bin") / name)
         for name in ("initdb", "pg_ctl", "psql", "createdb")}
assert all(Path(p).is_file() and os.access(p, os.X_OK) for p in TOOLS.values()), "Use existing PostgreSQL binaries"
OUT = Path(tempfile.mkdtemp(prefix="rendprop-funded-serving-pg-", dir="/tmp"))
DATA, SOCK = OUT / "data", OUT / "socket"
SOCK.mkdir()
# Drop inherited PGHOST/PGDATABASE/PGPASSWORD, service credentials and startup
# files. Every command names this fresh cluster's private Unix socket.
ENV = {"PATH": "/opt/homebrew/bin:/usr/bin:/bin", "LC_ALL": "C",
       "PGOPTIONS": "-c statement_timeout=30000 -c lock_timeout=15000"}
PORT = "55478"
SOURCES = [*sorted((SQL / "migrations").glob("*.sql")), SQL / "tests/ci-bootstrap.sql",
           SQL / "tests/funded_serving.sql", Path(__file__).resolve()]
receipt = {"kind": "owned disposable local PostgreSQL; no providers or hosted calls", "output": str(OUT),
           "commands": [], "sourceHashes": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}}


def run(name, args, sql=None, refuses=None):
    p = subprocess.run([str(x) for x in args], input=sql, env=ENV, cwd=ROOT, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    log = OUT / (name + ".log")
    log.write_text(p.stdout)
    receipt["commands"].append({"name": name, "exit": p.returncode,
                                "log_sha256": hashlib.sha256(log.read_bytes()).hexdigest()})
    if refuses:
        assert p.returncode != 0 and refuses in p.stdout, f"{name}: expected {refuses}, got {p.stdout}"
    elif p.returncode:
        raise RuntimeError(f"{name} failed: {p.stdout[-2000:]} ({log})")
    print(name + ": pass", flush=True)
    return p.stdout


def race(name, statements):
    barrier = Barrier(len(statements))
    def invoke(pair):
        index, statement = pair
        barrier.wait(timeout=10)
        p = subprocess.run([*psql, "-Atq"], input="set role service_role;" + statement,
                           env=ENV, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, timeout=30)
        log = OUT / f"{name}-{index}.log"
        log.write_text(p.stdout)
        receipt["commands"].append({"name": f"{name}-{index}", "exit": p.returncode,
                                    "log_sha256": hashlib.sha256(log.read_bytes()).hexdigest()})
        return p.returncode, p.stdout
    with ThreadPoolExecutor(max_workers=len(statements)) as executor:
        return list(executor.map(invoke, enumerate(statements)))


started = False
try:
    receipt["postgresVersion"] = run("version", [TOOLS["psql"], "--version"]).strip()
    run("initdb", [TOOLS["initdb"], "-D", DATA, "-U", "postgres", "-A", "trust", "--no-locale", "--encoding=UTF8"])
    run("start", [TOOLS["pg_ctl"], "-D", DATA, "-l", OUT / "server.log", "-w", "-t", "30", "-o",
                  f"-k {SOCK} -p {PORT} -c listen_addresses='' -c shared_buffers=16MB", "start"])
    started = True
    conn = ["-h", SOCK, "-p", PORT, "-U", "postgres"]
    run("createdb", [TOOLS["createdb"], *conn, "funded_serving_audit"])
    psql = [TOOLS["psql"], "-X", "--no-password", *conn, "-d", "funded_serving_audit", "-v", "ON_ERROR_STOP=1"]
    run("bootstrap", [*psql, "-q", "-f", SQL / "tests/ci-bootstrap.sql"])
    for m in sorted((SQL / "migrations").glob("*.sql")):
        run("apply-" + m.stem, [*psql, "-q", "-1", "-f", m])
    receipt["fresh"] = run("funded-fresh", [*psql, "-Atq", "-f", SQL / "tests/funded_serving.sql"]).strip()
    run("replay-funded", [*psql, "-q", "-f", MIGRATION])
    # Replaying an earlier overlay restores its earlier function body. Restore
    # the latest additive trial overlay before checking current-source behavior.
    run("restore-current-trial-overlay", [*psql, "-q", "-f", SQL / "migrations/20261006202500_bounded_subscription_trial.sql"])
    run("restore-purchase-overlay", [*psql,"-q","-f",SQL / "migrations/20261006212900_subscription_trial_purchase_reservations.sql"])
    run("restore-duration-overlay", [*psql,"-q","-f",SQL / "migrations/20261006213000_subscription_trial_video_duration.sql"])
    receipt["replay"] = run("funded-replay", [*psql, "-Atq", "-f", SQL / "tests/funded_serving.sql"]).strip()

    actor = "b1000000-0000-4000-8000-000000000001"
    positive = "b2000000-0000-4000-8000-000000000001"
    negative = "b2000000-0000-4000-8000-000000000002"
    run("race-fixtures", [*psql, "-Atq"], f"""
      insert into auth.users(id,email,is_anonymous)values('{actor}','funding-race@example.invalid',false);
      insert into orgs(id,name,plan,plan_source)values('{positive}','Synthetic funded race','pro','manual'),('{negative}','Synthetic negative race','pro','manual');
      insert into memberships(user_id,org_id,role)values('{actor}','{positive}','owner'),('{actor}','{negative}','owner');
      set role service_role;
      select provision_serving_funding(id,'retail','race-receipt:'||id,null,400,0,now()-interval '1 minute',now()-interval '1 minute'+interval '1 month',1,
       '{{"storage":0,"delivery":0,"compute":0,"email":0,"support":0,"retention":0,"uncertainty":0}}',repeat('a',64))from orgs where id in('{positive}','{negative}');
    """)
    source = MIGRATION.read_text()
    start = source.index("create or replace function public.serving_cost_reserve(")
    end = source.index("end$$;", start) + len("end$$;")
    authority = source[start:end]
    spend_anchor = "  if spent+p_hold_cents>"
    assert authority.count(spend_anchor) == 1
    # The same delay at the balance-read boundary makes the race deterministic.
    # It leaves every permission, arithmetic, journal and locking check intact.
    instrumented = authority.replace(spend_anchor, "  perform pg_sleep(0.25);\n" + spend_anchor)
    run("instrument-cost-race", [*psql, "-q"], instrumented)
    def requests(org):
        return [f"select serving_cost_reserve('{actor}','{org}','race-provider-{i}','{feature}','synthetic','synthetic',repeat('a',64),60,'synthetic');"
                for i, feature in enumerate(("photo", "voice"))]
    outcomes = race("shared-budget-race", requests(positive))
    assert sorted(code for code, _ in outcomes) == [0, 3], outcomes
    assert sum("RP402" in output for _, output in outcomes) == 1, outcomes
    receipt["sharedBudgetRace"] = {"accepted": 1, "refused": 1, "limitCents": 100, "attemptCents": 60}
    same = f"select serving_operation_begin('{actor}','{positive}','race-operation-key','coach.chat',repeat('a',64));"
    outcomes = race("operation-replay-race", [same, same])
    assert sorted(code for code, _ in outcomes) == [0, 3], outcomes
    assert sum("RP409" in output for _, output in outcomes) == 1, outcomes
    receipt["operationReplayRace"] = {"begun": 1, "refused": 1}
    lock_anchor = " perform pg_advisory_xact_lock(hashtextextended('serving:'||p_org,72452));"
    row_anchor = " perform 1 from public.orgs where id=p_org and deleted_at is null for update;"
    assert instrumented.count(lock_anchor) == 1 and instrumented.count(row_anchor) == 1
    broken = instrumented.replace(lock_anchor, " -- Deliberately removed budget lock.").replace(row_anchor, " perform 1 from public.orgs where id=p_org and deleted_at is null;")
    mutation = OUT / "negative-cost-no-locks.sql"
    mutation.write_text(broken)
    run("install-cost-negative-control", [*psql, "-q", "-f", mutation])
    outcomes = race("broken-shared-budget-race", requests(negative))
    assert [code for code, _ in outcomes] == [0, 0], outcomes
    receipt["negativeControl"] = {"removed": "advisory + workspace row budget locks", "accepted": 2,
                                   "overspendCents": 20, "mutation_sha256": hashlib.sha256(mutation.read_bytes()).hexdigest()}
    run("restore-cost-authority", [*psql, "-q"], authority)
    receipt["passed"] = True
finally:
    if started:
        run("stop", [TOOLS["pg_ctl"], "-D", DATA, "-m", "fast", "-w", "stop"])
    (OUT / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(str(OUT / "receipt.json"), flush=True)
