#!/usr/bin/env python3
"""Launch blockers (2026-10-08) under two concurrent connections in a disposable
local PostgreSQL: ceiling-mode money admission at the envelope boundary, the
durable free publication slot and Sandbox trial grants serialize to exactly one
winner; removing the locks is proven to overspend/over-admit (negative control).

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

ROOT = Path(__file__).resolve().parents[3]
SQL = ROOT / "services/supabase"
TOOLS = {name: shutil.which(name) or str(Path("/opt/homebrew/opt/postgresql@17/bin") / name)
         for name in ("initdb", "pg_ctl", "psql", "createdb")}
assert all(Path(p).is_file() and os.access(p, os.X_OK) for p in TOOLS.values()), "Use existing PostgreSQL binaries"
OUT = Path(tempfile.mkdtemp(prefix="rendprop-launch-blockers-pg-", dir="/tmp"))
DATA, SOCK = OUT / "data", OUT / "socket"
SOCK.mkdir()
ENV = {"PATH": "/opt/homebrew/bin:/usr/bin:/bin", "LC_ALL": "C",
       "PGOPTIONS": "-c statement_timeout=30000 -c lock_timeout=15000"}
PORT = "55481"
SOURCES = [*sorted((SQL / "migrations").glob("*.sql")), SQL / "tests/ci-bootstrap.sql",
           SQL / "tests/launch_blockers.sql", SQL / "tests/serving_settlement_identity.sql", SQL / "tests/serving_grace.sql", Path(__file__).resolve()]
receipt = {"kind": "owned disposable local PostgreSQL; no providers or hosted calls", "output": str(OUT),
           "commands": [], "sourceHashes": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}}


def run(name, args, sql=None, refuses=None):
    p = subprocess.run([str(x) for x in args], input=sql, env=ENV, cwd=ROOT, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
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


def definition(signature):
    return run("read-" + signature.split("(")[0].split(".")[-1], [*psql, "-Atq", "-c",
               f"select pg_get_functiondef('{signature}'::regprocedure)"]).rstrip("\n")


started = False
try:
    receipt["postgresVersion"] = run("version", [TOOLS["psql"], "--version"]).strip()
    run("initdb", [TOOLS["initdb"], "-D", DATA, "-U", "postgres", "-A", "trust", "--no-locale", "--encoding=UTF8"])
    run("start", [TOOLS["pg_ctl"], "-D", DATA, "-l", OUT / "server.log", "-w", "-t", "30", "-o",
                  f"-k {SOCK} -p {PORT} -c listen_addresses='' -c shared_buffers=16MB", "start"])
    started = True
    conn = ["-h", SOCK, "-p", PORT, "-U", "postgres"]
    run("createdb", [TOOLS["createdb"], *conn, "launch_blockers_audit"])
    psql = [TOOLS["psql"], "-X", "--no-password", *conn, "-d", "launch_blockers_audit", "-v", "ON_ERROR_STOP=1"]
    run("bootstrap", [*psql, "-q", "-f", SQL / "tests/ci-bootstrap.sql"])
    for m in sorted((SQL / "migrations").glob("*.sql")):
        run("apply-" + m.stem, [*psql, "-q", "-1", "-f", m])
    receipt["fresh"] = run("launch-blockers-fresh", [*psql, "-Atq", "-f", SQL / "tests/launch_blockers.sql"]).strip()
    receipt["settlementIdentity"] = json.loads(run("settlement-identity", [*psql, "-Atq", "-f", SQL / "tests/serving_settlement_identity.sql"]).strip())
    receipt["servingGrace"] = run("serving-grace", [*psql, "-Atq", "-f", SQL / "tests/serving_grace.sql"]).strip()

    actor = "e1000000-0000-4000-8000-000000000001"
    starter = "e2000000-0000-4000-8000-000000000001"
    negative = "e2000000-0000-4000-8000-000000000002"
    free_org = "e2000000-0000-4000-8000-000000000003"
    free_negative = "e2000000-0000-4000-8000-000000000004"
    sandbox = "e2000000-0000-4000-8000-000000000005"
    listings = ["e3000000-0000-4000-8000-00000000000" + str(i) for i in range(1, 5)]
    run("race-fixtures", [*psql, "-Atq"], f"""
      update public.app_config set value=jsonb_build_object('mode','ceiling','free_published_listings',1) where key='serving_mode';
      update public.app_config set value=value||'{{"apple_commission_bps":1500}}'::jsonb where key='serving_envelope';
      update public.app_config set value=jsonb_build_object('cap_cents',29000,'starts_at',to_char(now()-interval '1 day','YYYY-MM-DD"T"HH24:MI:SS"Z"'),'ends_at',to_char(now()+interval '30 days','YYYY-MM-DD"T"HH24:MI:SS"Z"')) where key='trial_sponsor_pool';
      insert into auth.users(id,email,is_anonymous,email_confirmed_at)values('{actor}','launch-race@example.invalid',false,now());
      insert into orgs(id,name,plan,plan_source,apple_product_id,plan_expires_at)values
       ('{starter}','Synthetic ceiling race','starter','apple','com.rendprop.app.starter.monthly',now()+interval '20 days'),
       ('{negative}','Synthetic ceiling negative race','starter','apple','com.rendprop.app.starter.monthly',now()+interval '20 days'),
       ('{free_org}','Synthetic slot race','free',null,null,null),('{free_negative}','Synthetic slot negative race','free',null,null,null),
       ('{sandbox}','Synthetic sandbox race','free',null,null,null);
      insert into memberships(user_id,org_id,role)select '{actor}',id,'owner' from orgs where id::text like 'e2000000-%';
      insert into apple_subscriptions(original_transaction_id,org_id,user_id,product_id,plan,environment,status,expires_at,auto_renew,last_transaction_id,transaction_purchased_at,created_at)values
       ('race-starter-original','{starter}','{actor}','com.rendprop.app.starter.monthly','starter','Production','active',now()+interval '20 days',true,'race-starter-tx',now()-interval '10 days',now()-interval '1 day'),
       ('race-negative-original','{negative}','{actor}','com.rendprop.app.starter.monthly','starter','Production','active',now()+interval '20 days',true,'race-negative-tx',now()-interval '10 days',now()-interval '1 day');
      insert into cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,created_at)values
       ('{starter}','photo_edit','gemini','gemini-3.1-flash-image',1,980,980,now()-interval '1 day'),('{negative}','photo_edit','gemini','gemini-3.1-flash-image',1,980,980,now()-interval '1 day');
      insert into listings(id,org_id,agent_id,address)values
       ('{listings[0]}','{free_org}','{actor}','Synthetic race listing 1'),('{listings[1]}','{free_org}','{actor}','Synthetic race listing 2'),
       ('{listings[2]}','{free_negative}','{actor}','Synthetic race listing 3'),('{listings[3]}','{free_negative}','{actor}','Synthetic race listing 4');
    """)

    # ── Money admission at the envelope boundary (991c; 980 spent). Two writers,
    # one authority: a photo serving reservation and a legacy video hold race
    # through serving_envelope_admit under the org_month_spend lock. ──
    admit = definition("public.serving_envelope_admit(uuid,numeric,text)")
    spent_anchor = " spent:=public.serving_ceiling_spent_cents(p_org,ps,pe);"
    assert admit.count(spent_anchor) == 1
    instrumented = admit.replace(spent_anchor, " perform pg_sleep(0.25);\n" + spent_anchor)
    run("instrument-ceiling-race", [*psql, "-q"], instrumented)
    def requests(org, suffix):
        return [f"select serving_cost_reserve('{actor}','{org}','race-photo-{suffix}','photo.stage:0','gemini','gemini-3.1-flash-image',repeat('a',64),6,'verified');",
                f"select app_video_cost_reserve('{actor}','{org}','race-video-{suffix}','reel','fal','bytedance/seedance/v1/pro/fast/image-to-video',repeat('b',64),6,2,3,'{{}}'::jsonb);"]
    outcomes = race("mixed-writer-envelope-race", requests(starter, "a"))
    assert sorted(code for code, _ in outcomes) == [0, 3], outcomes
    assert sum("RP402: AI usage limit reached" in output for _, output in outcomes) == 1, outcomes
    receipt["mixedWriterEnvelopeRace"] = {"accepted": 1, "refused": 1, "ceilingCents": 991, "spentCents": 980, "attemptCents": 6, "writers": ["serving_cost_reserve", "app_video_cost_reserve"]}
    # Same-writer race (two photo attempts) through the same authority.
    photo_pair = [f"select serving_cost_reserve('{actor}','{negative}','race-photo-{i}','{stage}','gemini','gemini-3.1-flash-image',repeat('a',64),6,'verified');" for i, stage in enumerate(("photo.stage:0", "photo.sky:0"))]
    outcomes = race("ceiling-budget-race", photo_pair)
    assert sorted(code for code, _ in outcomes) == [0, 3], outcomes
    assert sum("RP402: AI usage limit reached" in output for _, output in outcomes) == 1, outcomes
    receipt["ceilingBudgetRace"] = {"accepted": 1, "refused": 1, "ceilingCents": 991, "spentCents": 980, "attemptCents": 6}
    run("release-negative-fixture", [*psql, "-Atq"], f"delete from serving_cost_reservations where org_id='{negative}';")
    lock_anchor = " perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||p_org::text,42));"
    assert instrumented.count(lock_anchor) == 1
    reserve = definition("public.serving_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,text)")
    early_lock = " if public.serving_mode()='ceiling' then perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||p_org::text,42));end if;"
    assert reserve.count(early_lock) == 1
    video = definition("public.app_video_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,numeric,numeric,jsonb)")
    video_lock = "  perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||p_org::text,42));"
    video_row = "  perform 1 from public.orgs where id=p_org and deleted_at is null for update;"
    serving_row = " perform 1 from public.orgs where id=p_org and deleted_at is null for update;"
    assert video.count(video_lock) == 1 and video.count(video_row) == 1 and reserve.count(serving_row) == 1
    # The control removes every lock the two writers share: the money advisory
    # lock in the authority and in both writers, and the workspace row lock.
    broken = instrumented.replace(lock_anchor, " -- Deliberately removed the shared money lock.")
    broken_reserve = reserve.replace(early_lock, " -- Deliberately removed the shared money lock.").replace(serving_row, " perform 1 from public.orgs where id=p_org and deleted_at is null;")
    broken_video = video.replace(video_lock, "  -- Deliberately removed the shared money lock.").replace(video_row, "  perform 1 from public.orgs where id=p_org and deleted_at is null;")
    mutation = OUT / "negative-ceiling-no-locks.sql"
    mutation.write_text(broken + ";\n" + broken_reserve + ";\n" + broken_video + ";\n")
    run("install-ceiling-negative-control", [*psql, "-q", "-f", mutation])
    # Without the shared lock the two writers serialize on different locks
    # (serving:<org> vs org_month_spend:<org>) and both read the stale balance.
    outcomes = race("broken-mixed-writer-race", requests(negative, "n"))
    assert [code for code, _ in outcomes] == [0, 0], outcomes
    receipt["ceilingNegativeControl"] = {"removed": "org_month_spend money lock (authority + both writers) and the workspace row lock", "accepted": 2, "overspendCents": 1,
                                         "writers": ["serving_cost_reserve", "app_video_cost_reserve"],
                                         "mutation_sha256": hashlib.sha256(mutation.read_bytes()).hexdigest()}
    run("restore-ceiling-authority", [*psql, "-q"], admit + ";\n" + reserve + ";\n" + video + ";\n")

    # ── Durable free publication slot (one per workspace; two listings race) ──
    admit = definition("public.free_publication_admit(uuid,uuid)")
    count_anchor = " select count(*)into used from public.workspace_publication_slots where org_id=p_org;"
    assert admit.count(count_anchor) == 1
    instrumented = admit.replace(count_anchor, count_anchor + "\n perform pg_sleep(0.25);")
    run("instrument-slot-race", [*psql, "-q"], instrumented)
    def admissions(org, pair):
        return [f"select free_publication_admit('{org}','{listing}');" for listing in pair]
    outcomes = race("free-slot-race", admissions(free_org, listings[:2]))
    assert [code for code, _ in outcomes] == [0, 0], outcomes
    assert sorted(output.strip() for _, output in outcomes) == ["f", "t"], outcomes
    slots = run("slot-count", [*psql, "-Atq", "-c", f"select count(*) from workspace_publication_slots where org_id='{free_org}'"]).strip()
    assert slots == "1", slots
    receipt["freeSlotRace"] = {"admitted": 1, "refused": 1, "slots": 1}
    slot_lock = " perform pg_advisory_xact_lock(hashtextextended('free_publication:'||p_org,72454));"
    assert instrumented.count(slot_lock) == 1
    broken = instrumented.replace(slot_lock, " -- Deliberately removed slot lock.")
    mutation = OUT / "negative-slot-no-lock.sql"
    mutation.write_text(broken)
    run("install-slot-negative-control", [*psql, "-q", "-f", mutation])
    outcomes = race("broken-free-slot-race", admissions(free_negative, listings[2:]))
    assert [code for code, _ in outcomes] == [0, 0] and [output.strip() for _, output in outcomes] == ["t", "t"], outcomes
    receipt["freeSlotNegativeControl"] = {"removed": "workspace slot lock", "admitted": 2,
                                          "mutation_sha256": hashlib.sha256(mutation.read_bytes()).hexdigest()}
    run("restore-slot-authority", [*psql, "-q"], admit)

    # ── Sandbox trial: two receipts for one workspace open exactly one window ──
    grants = [f"select grant_sandbox_trial('{sandbox}','{actor}','race-receipt-{i}','race-tx-{i}','com.rendprop.app.pro.monthly','active',now()+interval '3 minutes',now())->>'granted';"
              for i in range(2)]
    outcomes = race("sandbox-grant-race", grants)
    assert [code for code, _ in outcomes] == [0, 0], outcomes
    assert sorted(output.strip() for _, output in outcomes) == ["false", "true"], outcomes
    granted = run("sandbox-grant-count", [*psql, "-Atq", "-c",
                  f"select count(*) from apple_sandbox_receipts where org_id='{sandbox}' and trial_granted_at is not null"]).strip()
    assert granted == "1", granted
    receipt["sandboxGrantRace"] = {"granted": 1, "recordedOnly": 1}
    receipt["passed"] = True
finally:
    if started:
        run("stop", [TOOLS["pg_ctl"], "-D", DATA, "-m", "fast", "-w", "stop"])
    (OUT / "receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True))
    print(OUT / "receipt.json")
