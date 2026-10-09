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
           SQL / "tests/invariant_astra_paid_gates.sql",
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


def require_all_invariants(output, exit_code):
    names, failed = contracts.invariant_rows(output, exit_code)
    if exit_code != 0 or failed:
        raise RuntimeError("Every invariant must pass; no failures are accepted")
    return names


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
    # Replay the overlay at its historical schema point in a separate database.
    # Later Team wrappers remain installed in the original current-schema DB.
    catalog_sql = "select md5(string_agg(oid::regprocedure::text||prosrc||coalesce(proacl::text,'')||proowner::text||prosecdef::text||coalesce(proconfig::text,''),'|' order by oid::regprocedure::text)) from pg_proc where pronamespace='public'::regnamespace;"
    final_catalog = run("final-function-catalog", [*psql, "-Atq"], catalog_sql)
    run("createdb-historical-replay", [TOOLS["createdb"], *conn, "historical_replay"])
    replay_psql = [TOOLS["psql"], "-X", "--no-password", *conn, "-d", "historical_replay", "-v", "ON_ERROR_STOP=1"]
    run("bootstrap-historical-replay", [*replay_psql, "-q", "-f", SQL / "tests/ci-bootstrap.sql"])
    for m in sorted((SQL / "migrations").glob("*.sql")):
        run("replay-apply-" + m.stem, [*replay_psql, "-q", "-1", "-f", m])
        if m.name == "20261006202500_bounded_subscription_trial.sql":
            run("historical-exact-overlay-replay", [*replay_psql, "-q", "-1", "-f", m])
    assert run("replayed-final-function-catalog", [*replay_psql, "-Atq"], catalog_sql) == final_catalog, "Historical replay changed final function authority"
    receipt["replayMode"] = "Separate database; overlay twice at historical point, all later migrations then applied"
    receipt["replay"] = run("final-replayed-fixture", [*replay_psql, "-Atq", "-f", SQL / "tests/bounded_subscription_trial.sql"]).strip()
    # Restore the exact pre-fence function ONLY inside an owned rollback
    # fixture. Its formerly permitted helper must fail the unchanged early
    # refusal oracle, proving the new fence changes actual cost admission.
    import re
    canonical = MIGRATION.read_text()
    old_guard = re.search(r"create or replace function public.subscription_trial_cost_guard\(\)returns trigger.*?end\$\$;",canonical,re.S)
    assert old_guard
    fixture = (SQL / "tests/bounded_subscription_trial.sql").read_text()
    assert fixture.count("\nbegin;\n") == 1
    mutant = OUT / "trial-helper-stage-fence-removed.sql"
    mutant.write_text(fixture.replace("\nbegin;\n","\nbegin;\n" + old_guard.group(0) + "\n",1))
    run("trial-helper-stage-fence-removed",[*psql,"-Atq","-f",mutant],refuses="TRIAL FAIL expected RP402: trial suggestion refused before any photo credit or cash is spent")
    receipt["helperFenceNegativeControl"] = {"positiveOracleRejected":True,"sourceCopy":str(mutant),"sha256":hashlib.sha256(mutant.read_bytes()).hexdigest(),"exit":receipt["commands"][-1]["exit"]}
    # Existing actual lifecycle/quota fixtures also run with the new trigger.
    # Require the exact complete inventory, successful SQL exit and all-green footer.
    spec = importlib.util.spec_from_file_location("database_contract", ROOT / "tools/audit/run_database_regression.py")
    contracts = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(contracts)
    invariant_output = run("existing-invariants", [*psql, "-f", SQL / "tests/invariants.sql"])
    names = require_all_invariants(invariant_output, receipt["commands"][-1]["exit"])
    receipt["existingInvariants"] = {"assertions": len(names), "passed": len(names), "failures": []}
    # Restore only the former headroom failure in an owned SQL copy and prove
    # that the same positive acceptance gate refuses its complete red inventory.
    original = (SQL / "tests/invariants.sql").read_text()
    anchor = "when 'copy.agent_reel' then 500"
    assert original.count(anchor) == 1
    shutil.copyfile(SQL / "tests/invariant_astra_paid_gates.sql", OUT / "invariant_astra_paid_gates.sql")
    mutant = OUT / "invariants-former-headroom-red.sql"
    mutant.write_text(original.replace(anchor, "when 'copy.agent_reel' then 700", 1))
    red = run("invariants-former-headroom-red", [*psql, "-f", mutant], refuses="INVARIANTS FAILED: 1 assertion")
    red_exit = receipt["commands"][-1]["exit"]
    red_names, red_failures = contracts.invariant_rows(red, red_exit)
    assert red_names == names
    assert red_failures == ["each astra ceiling clears its route's visible answer and stays under the code clamp"]
    try:
        require_all_invariants(red, red_exit)
    except RuntimeError:
        pass
    else:
        raise RuntimeError("Strict positive invariant gate accepted the former red assertion")
    receipt["invariantNegativeControl"] = {"kind": "actual-owned-SQL-former-headroom-red", "exit": red_exit,
        "count": len(red_names), "failed": red_failures, "positiveGateRejected": True,
        "sourceCopy": str(mutant), "sha256": hashlib.sha256(mutant.read_bytes()).hexdigest()}
    actor="d1000000-0000-4000-8000-000000000001"
    org="d2000000-0000-4000-8000-000000000001"
    run("race-fixture",[*psql,"-q"],f"""
      begin;
      -- These races exercise the funded trial's five-photo lifetime quota.
      -- The transaction-scoped SQL fixtures above rolled their mode back;
      -- pin the same authority in this owned cluster before committing users.
      update public.app_config set value=value||'{{"mode":"funded"}}'::jsonb where key='serving_mode';
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
    race_mode=run("race-serving-mode",[*psql,"-Atq"],"select public.serving_mode();").strip()
    assert race_mode=="funded",race_mode
    receipt["raceServingMode"]=race_mode
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
    receipt["sourceUnchanged"] = all(hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==h for p,h in receipt["sourceHashes"].items())
    receipt["passed"] = receipt.get("passed", False) and receipt["sourceUnchanged"]
    (OUT / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(str(OUT / "receipt.json"), flush=True)
