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
OUT = Path(tempfile.mkdtemp(prefix="rendprop-retail-guest-pg-", dir="/tmp"))
DATA, SOCK = OUT / "data", OUT / "socket"
SOCK.mkdir()
# Drop inherited PGHOST/PGDATABASE/PGPASSWORD, service credentials and startup
# files. Every command names this fresh cluster's private Unix socket.
ENV = {"PATH": "/opt/homebrew/bin:/usr/bin:/bin", "LC_ALL": "C",
       "PGOPTIONS": "-c statement_timeout=30000 -c lock_timeout=15000"}
PORT = "55491"
SOURCES = [*sorted((SQL / "migrations").glob("*.sql")), SQL / "tests/ci-bootstrap.sql",
           SQL / "tests/verified_retail_guest.sql", Path(__file__).resolve()]
SOURCES.append(SQL / "tests/funded_serving.sql")
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
    run("createdb", [TOOLS["createdb"], *conn, "retail_guest_audit"])
    psql = [TOOLS["psql"], "-X", "--no-password", *conn, "-d", "retail_guest_audit", "-v", "ON_ERROR_STOP=1"]
    run("bootstrap", [*psql, "-q", "-f", SQL / "tests/ci-bootstrap.sql"])
    for m in sorted((SQL / "migrations").glob("*.sql")):
        run("apply-" + m.stem, [*psql, "-q", "-1", "-f", m])
    receipt["fresh"] = run("guest-fresh", [*psql,"-Atq","-f",SQL / "tests/verified_retail_guest.sql"]).strip()
    run("replay-guest",[*psql,"-q","-f",SQL / "migrations/20261007135551_verified_retail_guest_admission.sql"])
    receipt["replay"] = run("guest-replay", [*psql,"-Atq","-f",SQL / "tests/verified_retail_guest.sql"]).strip()
    receipt["fundedRegression"] = run("funded-regression",[*psql,"-Atq","-f",SQL / "tests/funded_serving.sql"]).strip()
    # Removing genuine environment/token guards must be rejected by the same
    # full source-bound fixture, never a parse/compile failure or timeout.
    pristine=run("guest-reader-definition",[*psql,"-Atq"],"select pg_get_functiondef('public.org_has_verified_retail_guest(uuid,uuid)'::regprocedure);")
    controls=[]
    for label,anchor,oracle in [
      ("environment"," and a.environment='Production'","Sandbox is not retail guest authority"),
      ("token"," and a.app_account_token=p_actor","missing buyer token denied")
    ]:
        if pristine.count(anchor)!=1:raise RuntimeError("Unapplied guest control "+label)
        run("install-control-"+label,[*psql,"-q"],pristine.replace(anchor,""))
        raw=run("guard-control-"+label,[*psql,"-Atq","-f",SQL / "tests/verified_retail_guest.sql"],refuses="FAIL: "+oracle)
        controls.append({"removedGuard":label,"runtimeOracle":oracle})
        run("restore-reader-"+label,[*psql,"-q"],pristine)
    receipt["guardControls"]=controls
    fixture=(SQL / "tests/verified_retail_guest.sql").read_text()
    setup=fixture.split('set local role service_role;',1)[0]
    run("race-setup",[*psql,"-Atq"],setup.replace("temporary table","table")+"set local role service_role;"+"""
     select apply_apple_entitlement_v2(o,u,'synthetic-guest-original','synthetic-guest-tx','com.rendprop.app.pro.monthly','pro','Production','active',e,true,'SUBSCRIBED',t,s,s,s)from guest_fixture;
     reset role;commit;
    """)
    command="select fund_verified_retail_apple_transaction(u,o,'synthetic-guest-original','synthetic-guest-tx','com.rendprop.app.pro.monthly',49000,'USD','USA',null,null,t,e,s,repeat('a',64))from guest_fixture;"
    outcomes=race("duplicate-paid-receipt",[command,command])
    if any(code!=0 for code,_ in outcomes):raise RuntimeError("Duplicate funding failed")
    funded=[json.loads(next(x for x in output.splitlines()if x.startswith('{')))for _,output in outcomes]
    if sum(value.get("replay")is True for value in funded)!=1 or any(value.get("funded")is not True for value in funded):raise RuntimeError("Duplicate funding replenished cash")
    ledger=run("race-ledger-check",[*psql,"-Atq"],"select count(*)from serving_funding where collection_ref='apple:synthetic-guest-tx';").strip()
    if ledger!='1':raise RuntimeError("Duplicate financial grant")
    receipt["fundingRace"]={"successfulReceipts":2,"financialGrants":1,"replays":1}
    receipt["passed"] = True
finally:
    if started: run("stop",[TOOLS["pg_ctl"],"-D",DATA,"-m","fast","-w","stop"])
    receipt["sourceUnchanged"]=all(hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==h for p,h in receipt["sourceHashes"].items())
    receipt["passed"]=receipt.get("passed",False) and receipt["sourceUnchanged"]
    (OUT/"receipt.json").write_text(json.dumps(receipt,indent=2)+"\n")
    print(str(OUT/"receipt.json"),flush=True)
