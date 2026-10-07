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
import importlib.util
import uuid

ROOT = Path(__file__).resolve().parents[3]
SQL = ROOT / "services/supabase"
MIGRATION = SQL / "migrations/20261006202500_bounded_subscription_trial.sql"
TOOLS = {name: shutil.which(name) or str(Path("/opt/homebrew/opt/postgresql@17/bin") / name)
         for name in ("initdb", "pg_ctl", "psql", "createdb")}
assert all(Path(p).is_file() and os.access(p, os.X_OK) for p in TOOLS.values()), "Use existing PostgreSQL binaries"
OUT = Path(tempfile.mkdtemp(prefix="rendprop-bounded-trial-pg-", dir="/tmp"))
DATA, SOCK = OUT / "data", OUT / "socket"
SOCK.mkdir()
# Drop inherited PGHOST/PGDATABASE/PGPASSWORD, service credentials and startup
# files. Every command names this fresh cluster's private Unix socket.
ENV = {"PATH": "/opt/homebrew/bin:/usr/bin:/bin", "LC_ALL": "C",
       "PGOPTIONS": "-c statement_timeout=30000 -c lock_timeout=15000"}
PORT = "55486"
SOURCES = [*sorted((SQL / "migrations").glob("*.sql")), SQL / "tests/ci-bootstrap.sql",
           SQL / "tests/bounded_subscription_trial.sql", SQL / "tests/invariants.sql",
           ROOT / "tools/audit/run_database_regression.py", Path(__file__).resolve()]
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
    receipt["fresh"] = run("trial-fresh", [*psql, "-Atq", "-f", SQL / "tests/bounded_subscription_trial.sql"]).strip()
    run("replay-trial", [*psql, "-q", "-f", MIGRATION])
    run("restore-purchase-overlay", [*psql,"-q","-f",SQL / "migrations/20261006212900_subscription_trial_purchase_reservations.sql"])
    run("restore-duration-overlay", [*psql,"-q","-f",SQL / "migrations/20261006213000_subscription_trial_video_duration.sql"])
    receipt["replay"] = run("trial-replay", [*psql, "-Atq", "-f", SQL / "tests/bounded_subscription_trial.sql"]).strip()
    # Existing actual lifecycle/quota fixtures also run with the new trigger.
    # Preserve their exact 270 assertions and the single documented kept-red
    # answer-ceiling assertion; no clean-tree deployment readiness is inferred.
    spec = importlib.util.spec_from_file_location("database_contract", ROOT / "tools/audit/run_database_regression.py")
    contracts = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(contracts)
    invariant_output = run("existing-invariants", [*psql, "-f", SQL / "tests/invariants.sql"], refuses="INVARIANTS FAILED: 1 assertion")
    names, failed = contracts.invariant_rows(invariant_output, 3)
    kept, unexpected, stale = contracts.classify_failures(names, failed)
    assert not unexpected and not stale and set(kept) == contracts.KEPT_RED
    receipt["existingInvariants"] = {"assertions": len(names), "acceptedKeptRed": kept, "unexpected": unexpected}
    actor="d1000000-0000-4000-8000-000000000001"
    org="d2000000-0000-4000-8000-000000000001"
    run("race-fixture",[*psql,"-q"],f"""
      begin;
      insert into auth.users(id,email,is_anonymous,email_confirmed_at)values('{actor}','trial-race@example.invalid',false,now());
      insert into auth.users(id,email,is_anonymous,email_confirmed_at)values('d1000000-0000-4000-8000-000000000002','trial-race-member@example.invalid',false,now());
      insert into orgs(id,name,plan,plan_source)values('{org}','Synthetic trial race','starter','apple');
      insert into memberships(user_id,org_id,role)values('{actor}','{org}','owner');
      insert into memberships(user_id,org_id,role)values('d1000000-0000-4000-8000-000000000002','{org}','agent');
      insert into listings(id,org_id,agent_id,address)values('d3000000-0000-4000-8000-000000000001','{org}','{actor}','Synthetic concurrent upload');
      update subscription_trial_config set enabled=true;
      insert into serving_sponsor_pools(collection_ref,source,funded_cents,starts_at,ends_at,evidence_sha256)values('synthetic-race-pool','trial',5000,now()-interval '1 day',now()+interval '1 day',repeat('b',64));
      insert into apple_serving_schedules(product_id,storefront,currency,price_milliunits,net_proceeds_floor_cents,service_months,starts_at,ends_at,reserve_components,trial_sponsored_cents,trial_reserve_components,trial_days,trial_pool_id,evidence_sha256)
        select 'com.rendprop.app.starter.monthly','USA','USD',49000,4165,1,now()-interval '1 day',now()+interval '1 day',
        '{{"storage":0,"delivery":0,"compute":0,"email":0,"support":0,"retention":0,"uncertainty":0}}',500,
        '{{"storage":0,"delivery":0,"compute":0,"email":0,"support":0,"retention":0,"uncertainty":0}}',7,id,repeat('b',64)from serving_sponsor_pools where collection_ref='synthetic-race-pool';
      update serving_sponsor_pools set admissions_enabled=true where collection_ref='synthetic-race-pool';
      set role service_role;
      select prepare_subscription_trial_purchase('{actor}','{org}','com.rendprop.app.starter.monthly');
      select apply_apple_entitlement_v2('{org}','{actor}','synthetic-race-original','synthetic-race-tx','com.rendprop.app.starter.monthly','starter','Production','active',now()+interval '7 days',true,'SUBSCRIBED',now(),now(),now(),now());
      select fund_reserved_subscription_trial('{actor}','{org}','synthetic-race-original','synthetic-race-tx','com.rendprop.app.starter.monthly',0,'USD','USA',1,'FREE_TRIAL',now(),now()+interval '7 days',now(),repeat('a',64));
      select serving_cost_reserve('{actor}','{org}','race-photo-key-'||i,'photo.sky:0','gemini','synthetic',repeat('a',64),1,'synthetic')from generate_series(1,4)i;
      commit;
    """)
    statements=[f"select serving_cost_reserve('{actor}','{org}','last-photo-race-{i}','photo.sky:0','gemini','synthetic',repeat('a',64),1,'synthetic');"for i in range(2)]
    outcomes=race("last-credit-race",statements)
    assert sorted(code for code,_ in outcomes)==[0,3],outcomes
    assert sum("RP402"in output for _,output in outcomes)==1,outcomes
    receipt["photoCreditRace"]={"admitted":1,"refused":1,"lifetimeCap":5}
    used=run("after-credit-race",[*psql,"-Atq"],f"select count(*)from subscription_trial_actions where org_id='{org}'and kind='photo';").strip()
    assert used=="5",used
    # Executed negative control: remove the actual trigger, then the sixth real
    # financial reservation succeeds. The test proves quota admission behavior,
    # not an implementation text fingerprint.
    run("negative-remove-trigger",[*psql,"-q"],"alter table serving_cost_reservations disable trigger subscription_trial_cost_admission;")
    negative=run("negative-sixth-credit",[*psql,"-Atq"],f"set role service_role;select serving_cost_reserve('{actor}','{org}','sixth-photo-no-trigger','photo.sky:0','gemini','synthetic',repeat('a',64),1,'synthetic');")
    assert '"reserved": true'in negative
    run("restore-trigger",[*psql,"-q"],"alter table serving_cost_reservations enable trigger subscription_trial_cost_admission;")
    receipt["negativeControl"]={"removed":"actual trial admission trigger","sixthProviderReservationAccepted":True}
    listing="d3000000-0000-4000-8000-000000000001"
    def ticket(n, idem):
        asset=str(uuid.uuid4())
        item={"id":asset,"listing_id":listing,"kind":"video" if n>52428800 else "photo","bucket":"uploads",
              "storage_key":f"uploads/{org}/{listing}/{asset}.mp4" if n>52428800 else f"uploads/{org}/{listing}/{asset}.jpg",
              "bytes":n,"content_type":"video/mp4" if n>52428800 else "image/jpeg","content_type_declared":True,"idem_key":idem}
        if n>67108864:item.update(parts_total=(n+33554431)//33554432,part_size=33554432)
        return json.dumps([item])
    upload_statements=[f"select reserve_upload_assets('{actor}','{ticket(600*1024*1024,'trial-upload-race-'+str(i))}'::jsonb);"for i in range(2)]
    outcomes=race("lifetime-upload-race",upload_statements)
    assert sorted(code for code,_ in outcomes)==[0,3],outcomes
    assert sum("RP402"in output for _,output in outcomes)==1,outcomes
    receipt["lifetimeUploadRace"]={"admitted":1,"refused":1,"holdBytes":600*1024*1024,"lifetimeCapBytes":1073741824}
    member="d1000000-0000-4000-8000-000000000002"
    run("member-upload-refused",[*psql,"-Atq"],f"set role service_role;select reserve_upload_assets('{member}','{ticket(10,'trial-member-before-control')}'::jsonb);",refuses="RP403")
    run("negative-remove-upload-trigger",[*psql,"-q"],"alter table upload_reservations disable trigger subscription_trial_upload_admission;")
    negative=run("negative-member-upload",[*psql,"-Atq"],f"set role service_role;select reserve_upload_assets('{member}','{ticket(10,'trial-member-negative-control')}'::jsonb);")
    assert '"replayed": false'in negative
    run("restore-upload-trigger",[*psql,"-q"],"alter table upload_reservations enable trigger subscription_trial_upload_admission;")
    receipt["memberUploadNegativeControl"]={"removed":"actual trial upload guard trigger","nonGranteeReservationAccepted":True}
    receipt["passed"]=True

finally:
    if started:
        run("stop", [TOOLS["pg_ctl"], "-D", DATA, "-m", "fast", "-w", "stop"])
    (OUT / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(str(OUT / "receipt.json"), flush=True)
