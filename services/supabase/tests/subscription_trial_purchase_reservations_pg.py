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
MIGRATION = SQL / "migrations/20261006212900_subscription_trial_purchase_reservations.sql"
TOOLS = {name: shutil.which(name) or str(Path("/opt/homebrew/opt/postgresql@17/bin") / name)
         for name in ("initdb", "pg_ctl", "psql", "createdb")}
assert all(Path(p).is_file() and os.access(p, os.X_OK) for p in TOOLS.values()), "Use existing PostgreSQL binaries"
OUT = Path(tempfile.mkdtemp(prefix="rendprop-trial-purchase-pg-", dir="/tmp"))
DATA, SOCK = OUT / "data", OUT / "socket"
SOCK.mkdir()
# Drop inherited PGHOST/PGDATABASE/PGPASSWORD, service credentials and startup
# files. Every command names this fresh cluster's private Unix socket.
ENV = {"PATH": "/opt/homebrew/bin:/usr/bin:/bin", "LC_ALL": "C",
       "PGOPTIONS": "-c statement_timeout=30000 -c lock_timeout=15000"}
PORT = "55489"
SOURCES = [*sorted((SQL / "migrations").glob("*.sql")), SQL / "tests/ci-bootstrap.sql",
           SQL / "tests/subscription_trial_purchase_reservations.sql", SQL / "tests/invariants.sql",
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
    receipt["fresh"] = run("trial-fresh", [*psql, "-Atq", "-f", SQL / "tests/subscription_trial_purchase_reservations.sql"]).strip()
    run("replay-trial", [*psql, "-q", "-f", MIGRATION])
    receipt["replay"] = run("trial-replay", [*psql, "-Atq", "-f", SQL / "tests/subscription_trial_purchase_reservations.sql"]).strip()
    actor1="f1000000-0000-4000-8000-000000000001"
    actor2="f1000000-0000-4000-8000-000000000002"
    org1="f2000000-0000-4000-8000-000000000001"
    org2="f2000000-0000-4000-8000-000000000002"
    product="com.rendprop.app.starter.monthly"
    run("cash-race-fixture",[*psql,"-q"],f"""
      insert into auth.users(id,email,is_anonymous,email_confirmed_at)values('{actor1}','cash-race1@example.invalid',false,now()),('{actor2}','cash-race2@example.invalid',false,now());
      insert into orgs(id,name,plan,plan_source)values('{org1}','Synthetic cash race1','free','apple'),('{org2}','Synthetic cash race2','free','apple');
      insert into memberships(user_id,org_id,role)values('{actor1}','{org1}','owner'),('{actor2}','{org2}','owner');
      update subscription_trial_config set enabled=true;
      insert into serving_sponsor_pools(collection_ref,source,funded_cents,starts_at,ends_at,evidence_sha256,admissions_enabled)values('synthetic-cash-race','trial',500,now()-interval '1 day',now()+interval '1 day',repeat('e',64),true);
      insert into apple_serving_schedules(product_id,storefront,currency,price_milliunits,net_proceeds_floor_cents,service_months,starts_at,ends_at,reserve_components,trial_sponsored_cents,trial_reserve_components,trial_days,trial_pool_id,evidence_sha256)
        select '{product}','USA','USD',49000,4165,1,now()-interval '1 day',now()+interval '1 day',
        '{{"storage":1,"delivery":1,"compute":1,"email":1,"support":1,"retention":1,"uncertainty":1}}',500,
        '{{"storage":1,"delivery":1,"compute":1,"email":1,"support":1,"retention":1,"uncertainty":1}}',7,id,repeat('e',64)from serving_sponsor_pools where collection_ref='synthetic-cash-race';
    """)
    parties=[(actor1,org1),(actor2,org2)]
    outcomes=race("last-cash-hold",[f"select prepare_subscription_trial_purchase('{a}','{o}','{product}');"for a,o in parties])
    assert sorted(code for code,_ in outcomes)==[0,3],outcomes
    assert sum("RP402"in output for _,output in outcomes)==1,outcomes
    winner=next(index for index,(code,_)in enumerate(outcomes)if code==0)
    actor,org=parties[winner];loser_actor,loser_org=parties[1-winner]
    receipt["lastCashRace"]={"admitted":1,"refused":1,"cashCents":500}
    outcomes=race("same-hold-replay",[f"select prepare_subscription_trial_purchase('{actor}','{org}','{product}');"]*2)
    assert all(code==0 for code,_ in outcomes),outcomes
    bodies=[json.loads(output.strip())for _,output in outcomes]
    assert bodies[0]==bodies[1] and bodies[0]["app_account_token"]==actor
    receipt["sameHoldRace"]={"replayed":2,"oneImmutableCommitment":True}
    run("accepted-race-chronology",[*psql,"-q"],f"""set role service_role;select apply_apple_entitlement_v2('{org}','{actor}','cash-race-original','cash-race-tx','{product}','starter','Production','active',now()+interval '7 days',true,'SUBSCRIBED',now(),now(),now(),now());""")
    convert=f"select fund_reserved_subscription_trial('{actor}',org_id,original_transaction_id,last_transaction_id,product_id,0,'USD','USA',1,'FREE_TRIAL',transaction_purchased_at,expires_at,transaction_signed_at,repeat('e',64))from apple_subscriptions where original_transaction_id='cash-race-original';"
    outcomes=race("convert-versus-new-hold",[convert,f"select prepare_subscription_trial_purchase('{loser_actor}','{loser_org}','{product}');"])
    assert outcomes[0][0]==0 and outcomes[1][0]==3 and 'RP402'in outcomes[1][1],outcomes
    totals=run("cash-conservation",[*psql,"-Atq"],"select (select coalesce(sum(sponsored_cents),0)from serving_funding where sponsor_pool_id=p.id)+(select coalesce(sum(sponsored_cents),0)from subscription_trial_purchase_reservations where pool_id=p.id and funding_id is null)from serving_sponsor_pools p where collection_ref='synthetic-cash-race';").strip()
    assert totals=="500",totals
    receipt["conversionRace"]={"converted":1,"newHoldRefused":1,"committedCents":500}
    # Executed source mutation: omit prior converted funding from pool sums.
    # A separate eligible buyer then overcommits the actual pool. Restore the
    # exact original body immediately after proving this detector can fail.
    definition=run("read-prepare-definition",[*psql,"-Atq"],"select pg_get_functiondef('prepare_subscription_trial_purchase(uuid,uuid,text)'::regprocedure);")
    marker="select coalesce(sum(sponsored_cents),0)into committed from public.serving_funding where sponsor_pool_id=p.id;"
    assert definition.count(marker)==1
    run("negative-omit-funding",[*psql,"-q"],definition.replace(marker,"committed:=0;"))
    negative=run("negative-overcommit",[*psql,"-Atq"],f"set role service_role;select prepare_subscription_trial_purchase('{loser_actor}','{loser_org}','{product}');")
    assert '"reservation_id"'in negative
    over=run("negative-cash-total",[*psql,"-Atq"],"select (select coalesce(sum(sponsored_cents),0)from serving_funding where sponsor_pool_id=p.id)+(select coalesce(sum(sponsored_cents),0)from subscription_trial_purchase_reservations where pool_id=p.id and funding_id is null)from serving_sponsor_pools p where collection_ref='synthetic-cash-race';").strip()
    assert over=="1000",over
    run("restore-prepare-definition",[*psql,"-q"],definition)
    receipt["cashNegativeControl"]={"removed":"converted funding from pool commitment sum","actualOvercommitDetectedCents":1000}
    # Simulate owner loss after the initial check inside the actual function.
    # The final authority guard must abort the cash insert; deleting only that
    # guard must make the same real database operation commit a bad hold.
    actor3="f1000000-0000-4000-8000-000000000003";org3="f2000000-0000-4000-8000-000000000003"
    run("owner-loss-fixture",[*psql,"-q"],f"""
      insert into auth.users(id,email,is_anonymous,email_confirmed_at)values('{actor3}','cash-owner-loss@example.invalid',false,now());
      insert into orgs(id,name,plan,plan_source)values('{org3}','Synthetic final owner loss','free','apple');
      insert into memberships(user_id,org_id,role)values('{actor3}','{org3}','owner');
      insert into serving_sponsor_pools(collection_ref,source,funded_cents,starts_at,ends_at,evidence_sha256,admissions_enabled)values('synthetic-owner-loss','trial',500,now()-interval '1 day',now()+interval '1 day',repeat('e',64),true);
      insert into apple_serving_schedules(product_id,storefront,currency,price_milliunits,net_proceeds_floor_cents,service_months,starts_at,ends_at,reserve_components,trial_sponsored_cents,trial_reserve_components,trial_days,trial_pool_id,evidence_sha256)
       select 'com.rendprop.app.pro.monthly','USA','USD',99000,8415,1,now()-interval '1 day',now()+interval '1 day','{{"storage":1,"delivery":1,"compute":1,"email":1,"support":1,"retention":1,"uncertainty":1}}',500,'{{"storage":1,"delivery":1,"compute":1,"email":1,"support":1,"retention":1,"uncertainty":1}}',7,id,repeat('e',64)from serving_sponsor_pools where collection_ref='synthetic-owner-loss';
    """)
    before=" perform 1 from public.orgs where id=p_org and deleted_at is null for update;"
    assert definition.count(before)==1
    instrumented=definition.replace(before,before+"\n update public.memberships set role='agent'where user_id=p_actor and org_id=p_org;")
    run("instrument-final-owner-loss",[*psql,"-q"],instrumented)
    run("owner-loss-refused",[*psql,"-Atq"],f"set role service_role;select prepare_subscription_trial_purchase('{actor3}','{org3}','com.rendprop.app.pro.monthly');",refuses="RP403")
    guard_start=instrumented.index(" if not exists(select 1 from public.orgs where id=p_org and deleted_at is null)")
    guard_end=instrumented.index("end if;",guard_start)+len("end if;")
    run("negative-remove-final-owner-guard",[*psql,"-q"],instrumented[:guard_start]+instrumented[guard_end:])
    run("negative-owner-loss-accepted",[*psql,"-Atq"],f"set role service_role;select prepare_subscription_trial_purchase('{actor3}','{org3}','com.rendprop.app.pro.monthly');")
    bad=run("negative-owner-loss-readback",[*psql,"-Atq"],f"select count(*)from subscription_trial_purchase_reservations h join memberships m on m.org_id=h.org_id and m.user_id=h.actor_id where h.actor_id='{actor3}'and m.role='agent';").strip()
    assert bad=="1",bad
    run("restore-final-owner-guard",[*psql,"-q"],definition)
    receipt["finalOwnerNegativeControl"]={"actualLossAfterInitialCheckRefused":True,"removedFinalGuardCommitsBadHold":True}
    receipt["passed"]=True

finally:
    if started:
        run("stop", [TOOLS["pg_ctl"], "-D", DATA, "-m", "fast", "-w", "stop"])
    (OUT / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(str(OUT / "receipt.json"), flush=True)
