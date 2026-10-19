#!/usr/bin/env python3
"""Real ordinary-video admission/settlement races in an owned local Postgres.

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
MIGRATION = SQL / "migrations/20261003020955_app_video_cost_reservations.sql"
RELEASE = SQL / "migrations/20261004215403_app_video_rejected_submission_release.sql"
TOOLS = {name: shutil.which(name) or str(Path("/opt/homebrew/opt/postgresql@17/bin") / name)
         for name in ("initdb", "pg_ctl", "psql", "createdb")}
assert all(Path(p).is_file() and os.access(p, os.X_OK) for p in TOOLS.values()), "Use existing PostgreSQL binaries"
OUT = Path(tempfile.mkdtemp(prefix="rendprop-app-video-pg-", dir="/tmp"))
DATA, SOCK = OUT / "data", OUT / "socket"
SOCK.mkdir()
# Drop inherited PGHOST/PGDATABASE/PGPASSWORD, service credentials and startup
# files. Every command names this fresh cluster's private Unix socket.
ENV = {"PATH": "/opt/homebrew/bin:/usr/bin:/bin", "LC_ALL": "C",
       "PGOPTIONS": "-c statement_timeout=30000 -c lock_timeout=15000"}
PORT = "55476"
SOURCES = [*sorted((SQL / "migrations").glob("*.sql")), SQL / "tests/ci-bootstrap.sql",
           SQL / "tests/video_erase.sql", SQL / "tests/video_erase_direct_bria.sql", SQL / "tests/app_video_rejections.sql", Path(__file__).resolve()]
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


FIXTURE = r"""
\set ON_ERROR_STOP on
begin;
create temporary table app_video_assertions(n int not null default 0);
insert into app_video_assertions default values;
create function pg_temp.check_video(ok boolean,label text) returns void language plpgsql as $$
begin
  if ok is distinct from true then raise exception 'FAIL: %',label; end if;
  update app_video_assertions set n=n+1;
end $$;
create function pg_temp.video_refuses(statement text,expected text) returns void language plpgsql as $$
begin
  begin execute statement; exception when others then
    if sqlerrm like '%'||expected||'%' then perform pg_temp.check_video(true,expected); return; end if;
    raise;
  end;
  raise exception 'FAIL: expected refusal %',expected;
end $$;
do $$
declare u uuid:=gen_random_uuid(); other uuid:=gen_random_uuid(); o uuid:=gen_random_uuid();
  missing uuid:=gen_random_uuid(); key text:=gen_random_uuid()::text; r jsonb; rr jsonb; rid uuid;
  old_id uuid:=gen_random_uuid(); v numeric; field text; bad numeric;
  gone uuid:=gen_random_uuid(); gone_org uuid:=gen_random_uuid();
  l uuid:=gen_random_uuid(); a uuid:=gen_random_uuid(); j uuid; b uuid;
  cfg jsonb:='{"mask_unit_cost_cents":2,"erase_unit_cost_cents":3,"price_version":"synthetic","output_hosts":["outputs.example.com"]}';
begin
  insert into auth.users(id,email) values(u,'video-owner@example.invalid'),(other,'video-other@example.invalid');
  insert into orgs(id,name,plan) values(o,'Synthetic app video','pro');
  insert into memberships(user_id,org_id,role) values(u,o,'owner');
  update plan_entitlements set reels_per_month=50,aerials_per_month=50,topaz_per_month=50,cogs_ceiling_cents=6000 where plan='pro';
  perform pg_temp.check_video((select relrowsecurity from pg_class where oid='public.app_video_cost_reservations'::regclass),'RLS enabled');
  foreach field in array array['anon','authenticated'] loop
    perform pg_temp.check_video(not has_table_privilege(field,'public.app_video_cost_reservations','SELECT,INSERT,UPDATE,DELETE'),'private journal grant');
    perform pg_temp.check_video(not has_function_privilege(field,'public.app_video_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,numeric,numeric,jsonb)','execute'),'reserve service only');
    perform pg_temp.check_video(not has_function_privilege(field,'public.app_video_cost_settle(uuid,uuid,text,text)','execute'),'settle service only');
  end loop;
  perform pg_temp.check_video(has_function_privilege('service_role','public.app_video_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,numeric,numeric,jsonb)','execute'),'service reserve grant');
  perform pg_temp.check_video(has_function_privilege('service_role','public.app_video_cost_settle(uuid,uuid,text,text)','execute'),'service settle grant');
  perform pg_temp.check_video(not has_table_privilege('service_role','public.app_video_cost_reservations','DELETE'),'no service deletion/release grant');
  perform pg_temp.check_video((select prosecdef and proconfig=array['search_path=""'] from pg_proc where oid='public.org_month_spend_cents(uuid)'::regprocedure) and not has_function_privilege('anon','public.org_month_spend_cents(uuid)','execute'),'pooled spend has pinned path and no anonymous access');
  perform pg_temp.check_video(not exists(select 1 from pg_proc where proname='app_video_cost_release'),'no automatic release RPC');

  -- Every live editor role can reserve. Marketing/non-members/deleted workspaces
  -- and a disabled entitlement fail before any hold or provider permission.
  foreach field in array array['owner','admin','agent'] loop
    update memberships set role=field where org_id=o and user_id=u;
    r:=public.app_video_cost_reserve(u,o,gen_random_uuid()::text,'reel','fal','synthetic/reel',repeat('a',64),24,5,4.8,'{}');
    perform pg_temp.check_video((r->>'reserved')::boolean and (r->>'total_cents')::numeric=24,'editor reserve');
  end loop;
  update memberships set role='marketing' where org_id=o and user_id=u;
  perform pg_temp.video_refuses(format('select public.app_video_cost_reserve(%L,%L,%L,''reel'',''fal'',''synthetic/reel'',%L,24,5,4.8,''{}'')',u,o,key,repeat('a',64)),'RP403');
  update memberships set role='owner' where org_id=o and user_id=u;
  perform pg_temp.video_refuses(format('select public.app_video_cost_reserve(%L,%L,%L,''reel'',''fal'',''synthetic/reel'',%L,24,5,4.8,''{}'')',other,o,key,repeat('a',64)),'RP403');
  perform pg_temp.video_refuses(format('select public.app_video_cost_reserve(%L,%L,%L,''reel'',''fal'',''synthetic/reel'',%L,24,5,4.8,''{}'')',u,missing,key,repeat('a',64)),'RP403');
  update orgs set deleted_at=now() where id=o;
  perform pg_temp.video_refuses(format('select public.app_video_cost_reserve(%L,%L,%L,''reel'',''fal'',''synthetic/reel'',%L,24,5,4.8,''{}'')',u,o,key,repeat('a',64)),'RP403');
  update orgs set deleted_at=null where id=o;
  update plan_entitlements set reels_per_month=0 where plan='pro';
  perform pg_temp.video_refuses(format('select public.app_video_cost_reserve(%L,%L,%L,''reel'',''fal'',''synthetic/reel'',%L,24,5,4.8,''{}'')',u,o,key,repeat('a',64)),'RP402');
  update plan_entitlements set reels_per_month=50 where plan='pro';
  update plan_entitlements set aerials_per_month=0 where plan='pro';
  perform pg_temp.video_refuses(format('select public.app_video_cost_reserve(%L,%L,%L,''aerial'',''fal'',''synthetic/aerial'',%L,80,1,80,''{}'')',u,o,key,repeat('a',64)),'RP402');
  update plan_entitlements set aerials_per_month=50,topaz_per_month=0 where plan='pro';
  perform pg_temp.video_refuses(format('select public.app_video_cost_reserve(%L,%L,%L,''drone_render'',''fal'',''synthetic/topaz'',%L,4800,300,16,''{}'')',u,o,key,repeat('a',64)),'RP402');
  update plan_entitlements set topaz_per_month=50 where plan='pro';
  foreach field in array array['pending','processing'] loop
    insert into public.deletion_requests(user_id,status) values(u,field);
    perform pg_temp.video_refuses(format('select public.app_video_cost_reserve(%L,%L,%L,''reel'',''fal'',''synthetic/reel'',%L,24,5,4.8,''{}'')',u,o,key,repeat('a',64)),'RP403');
    delete from public.deletion_requests where user_id=u;
  end loop;

  foreach bad in array array[0,-1,'NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric,1000000000] loop
    foreach field in array array['hold','units','unit_cost'] loop
      perform pg_temp.video_refuses(format('select public.app_video_cost_reserve(%L,%L,%L,''reel'',''fal'',''synthetic/reel'',%L,%s,%s,%s,''{}'')',
        u,o,key,repeat('a',64),case when field='hold' then quote_literal(bad) else '24' end,
        case when field='units' then quote_literal(bad) else '5' end,
        case when field='unit_cost' then quote_literal(bad) else '4.8' end),'RP400');
    end loop;
  end loop;
  perform pg_temp.video_refuses(format('select public.app_video_cost_reserve(%L,%L,%L,''reel'',''fal'',''synthetic/reel'',%L,23.9999,5,4.8,''{}'')',u,o,key,repeat('a',64)),'RP400');
  perform pg_temp.video_refuses(format('select public.app_video_cost_reserve(%L,%L,%L,''reel'',''fal'',''synthetic/reel'',%L,.00001,.00001,.00001,''{}'')',u,o,key,repeat('a',64)),'RP400');
  foreach field in array array['short',repeat('a',129),'key with spaces','key'||chr(10)||'line'] loop
    perform pg_temp.video_refuses(format('select public.app_video_cost_reserve(%L,%L,%L,''reel'',''fal'',''synthetic/reel'',%L,24,5,4.8,''{}'')',u,o,field,repeat('a',64)),'RP400');
  end loop;
  foreach field in array array['A'||repeat('a',63),repeat('a',63),repeat('g',64)] loop
    perform pg_temp.video_refuses(format('select public.app_video_cost_reserve(%L,%L,%L,''reel'',''fal'',''synthetic/reel'',%L,24,5,4.8,''{}'')',u,o,key,field),'RP400');
  end loop;
  perform pg_temp.video_refuses(format('select public.app_video_cost_reserve(%L,%L,%L,''photo_edit'',''fal'',''synthetic/reel'',%L,24,5,4.8,''{}'')',u,o,key,repeat('a',64)),'RP400');
  perform pg_temp.video_refuses(format('select public.app_video_cost_reserve(%L,%L,%L,''reel'',''unknown'',''synthetic/reel'',%L,24,5,4.8,''{}'')',u,o,key,repeat('a',64)),'RP400');
  perform pg_temp.video_refuses(format('select public.app_video_cost_reserve(%L,%L,%L,''reel'',''fal'',%L,%L,24,5,4.8,''{}'')',u,o,key,repeat('m',241),repeat('a',64)),'RP400');
  foreach field in array array['[]','null','{"prompt":"private input"}','{"room":"private label"}','{"seconds":{}}','{"motion":"https://private.invalid"}'] loop
    perform pg_temp.video_refuses(format('select public.app_video_cost_reserve(%L,%L,%L,''reel'',''fal'',''synthetic/reel'',%L,24,5,4.8,%L)',u,o,key,repeat('a',64),field),'RP400');
  end loop;
  perform pg_temp.check_video((select count(*) from public.app_video_cost_reservations where org_id=o)=3,'refused calls create no hold');

  r:=public.app_video_cost_reserve(u,o,key,'drone_render','fal','synthetic/topaz',repeat('b',64),48,2,24,'{"unit":"second","price_estimated":true,"target_fps":120}');
  rid:=(r->>'id')::uuid;
  perform pg_temp.check_video(r->>'org_id'=o::text and r->>'key'=key,'bound positive reservation receipt');
  perform pg_temp.check_video(public.app_video_held_cents(o)=120 and public.org_month_spend_cents(o)=120,'holds counted alongside earlier clip holds');
  -- Duplicates cannot redeem even for another actor/task/provider/input/price.
  perform pg_temp.video_refuses(format('select public.app_video_cost_reserve(%L,%L,%L,''drone_render'',''fal'',''synthetic/topaz'',%L,48,2,24,''{}'')',u,o,key,repeat('b',64)),'RP409');
  insert into memberships(user_id,org_id,role) values(other,o,'agent');
  perform pg_temp.video_refuses(format('select public.app_video_cost_reserve(%L,%L,%L,''aerial'',''kie'',''different/model'',%L,50,2,25,''{}'')',other,o,key,repeat('c',64)),'RP409');
  foreach field in array array['hold_cents=49','input_sha256='''||repeat('c',64)||'''','actor_id='''||other::text||'''','provider=''kie''','model=''changed''','feature=''aerial''','meta=''{}''::jsonb'] loop
    perform pg_temp.video_refuses(format('update public.app_video_cost_reservations set %s where id=%L',field,rid),'RP409');
  end loop;
  insert into public.app_video_cost_reservations(id,org_id,actor_id,idempotency_key,feature,provider,model,input_sha256,units,unit_cost_cents,total_cents,hold_cents,created_at)
    values(old_id,o,u,'old-month-key','aerial','kie','synthetic/old',repeat('d',64),1,80,80,90,date_trunc('month',now())-interval '1 day');
  insert into public.cost_ledger(org_id,feature,provider,units,unit_cost_cents,total_cents,created_at)
    values(o,'synthetic','fal',1,9000,9000,date_trunc('month',now())-interval '1 day');
  perform pg_temp.check_video(public.app_video_held_cents(o)=210 and public.org_month_spend_cents(o)=210,'old unresolved hold persists; old booked ledger excluded');
  perform pg_temp.video_refuses(format('select public.app_video_cost_reserve(%L,%L,''old-month-key'',''aerial'',''kie'',''synthetic/old'',%L,90,1,80,''{}'')',u,o,repeat('d',64)),'RP409');
  perform pg_temp.video_refuses(format('select public.app_video_cost_settle(%L,%L,%L,''receipt-one'')',other,o,key),'RP409');
  perform pg_temp.video_refuses(format('select public.app_video_cost_settle(%L,%L,%L,''receipt-one'')',u,missing,key),'RP409');
  perform pg_temp.video_refuses(format('select public.app_video_cost_settle(%L,%L,''wrong-key'',''receipt-one'')',u,o),'RP409');
  foreach field in array array['',repeat('x',257),'receipt with whitespace'] loop
    perform pg_temp.video_refuses(format('select public.app_video_cost_settle(%L,%L,%L,%L)',u,o,key,field),'RP400');
  end loop;

  -- A simulated database failure rolls back BOTH ledger and hold settlement.
  insert into public.cost_ledger(org_id,feature,provider,total_cents,idempotency_key)
    values(o,'synthetic','fal',0,'app-video:'||rid);
  perform pg_temp.video_refuses(format('select public.app_video_cost_settle(%L,%L,%L,''receipt-one'')',u,o,key),'uq_cost_ledger_idempotency');
  perform pg_temp.check_video((select cost_ledger_id is null and provider_request_id is null from public.app_video_cost_reservations where id=rid) and public.app_video_held_cents(o)=210,'failed settlement keeps full hold');
  delete from public.cost_ledger where idempotency_key='app-video:'||rid;
  -- Cancellation/role revocation and soft deletion must not hide paid expense.
  delete from memberships where org_id=o and user_id=u;
  update orgs set deleted_at=now() where id=o;
  r:=public.app_video_cost_settle(u,o,key,'receipt-one');
  rr:=public.app_video_cost_settle(u,o,key,'receipt-one');
  perform pg_temp.check_video(r=rr and (r->>'settled')::boolean and (r->>'total_cents')::numeric=48,'same receipt settles exactly once after revocation');
  perform pg_temp.check_video(public.app_video_held_cents(o)=162 and public.org_month_spend_cents(o)=210,'atomic hold-to-ledger swap');
  perform pg_temp.check_video((select count(*)=1 from public.cost_ledger where idempotency_key='app-video:'||rid),'one ledger row');
  perform pg_temp.video_refuses(format('select public.app_video_cost_settle(%L,%L,%L,''different-receipt'')',u,o,key),'RP409');
  perform pg_temp.video_refuses(format('update public.app_video_cost_reservations set cost_ledger_id=null,provider_request_id=null,settled_at=null where id=%L',rid),'RP409');
  -- Hard org deletion neither cascades the hold nor prevents a late receipt.
  delete from orgs where id=o;
  perform pg_temp.check_video((select count(*)=5 from public.app_video_cost_reservations where org_id=o),'hard deletion retains cost-only tombstones');
  r:=public.app_video_cost_settle(u,o,'old-month-key','late-hard-delete');
  perform pg_temp.check_video((r->>'settled')::boolean and (select org_id is null and meta->>'billing_org_id'=o::text and billing_org_id=o and total_cents=80 from public.cost_ledger where id=(r->>'ledger_id')::uuid),'hard-deleted org late cost books with nullable ledger FK and immutable financial owner');
  insert into auth.users(id,email) values(gone,'deleted-actor@example.invalid');
  insert into orgs(id,name,plan) values(gone_org,'Synthetic deleted actor','pro');
  insert into memberships(user_id,org_id,role) values(gone,gone_org,'owner');
  r:=public.app_video_cost_reserve(gone,gone_org,'deleted-actor-key','reel','fal','synthetic/reel',repeat('6',64),24,5,4.8,'{}');
  delete from auth.users where id=gone;
  r:=public.app_video_cost_settle(gone,gone_org,'deleted-actor-key','late-deleted-actor');
  perform pg_temp.check_video((r->>'settled')::boolean and (select org_id=gone_org from public.cost_ledger where id=(r->>'ledger_id')::uuid),'deleted actor receipt remains accountable without recreating identity');

  -- Ordinary and both legacy/direct reflection admissions see the same fence.
  o:=gen_random_uuid(); key:=gen_random_uuid()::text;
  insert into orgs(id,name,plan) values(o,'Synthetic cross-feature budget','pro');
  insert into memberships(user_id,org_id,role) values(u,o,'owner');
  insert into listings(id,org_id,agent_id,address) values(l,o,u,'Synthetic');
  insert into capture_assets(id,listing_id,kind,storage_key,bucket,uploaded,duration_s)
    values(a,l,'video','synthetic/clip.mp4','renders',true,2);
  update plan_entitlements set cogs_ceiling_cents=100 where plan='pro';
  r:=public.video_erase_reserve(o,u,l,gen_random_uuid(),a,gen_random_uuid(),repeat('e',64));
  perform pg_temp.check_video(public.video_erase_held_cents(o)=28,'legacy reflection hold');
  perform pg_temp.video_refuses(format('select public.app_video_cost_reserve(%L,%L,%L,''aerial'',''fal'',''synthetic/aerial'',%L,73,1,73,''{}'')',u,o,key,repeat('f',64)),'RP402');
  r:=public.app_video_cost_reserve(u,o,key,'reel','fal','synthetic/reel',repeat('f',64),65,1,65,'{}');
  perform pg_temp.check_video(public.org_month_spend_cents(o)=93,'sum ordinary and reflection held costs');
  perform pg_temp.video_refuses(format('select public.video_erase_reserve_direct(%L,%L,%L,%L,%L,%L,%L,2,%L,''bria-video-v1'')',o,u,l,gen_random_uuid(),a,gen_random_uuid(),repeat('1',64),cfg),'RP402');
  -- Settling costs cannot make room until the held estimate is replaced.
  perform public.app_video_cost_settle(u,o,key,'cross-feature-receipt');
  perform pg_temp.check_video(public.org_month_spend_cents(o)=93,'reflection sees booked+held after settlement');
  update plan_entitlements set cogs_ceiling_cents=200 where plan='pro';
  r:=public.video_erase_reserve_direct(o,u,l,gen_random_uuid(),a,gen_random_uuid(),repeat('2',64),2,cfg,'bria-video-v1');
  perform pg_temp.check_video(public.video_erase_held_cents(o)=38 and public.org_month_spend_cents(o)=103,'direct mask+erase holds included without parent double count');
  update plan_entitlements set cogs_ceiling_cents=110 where plan='pro';
  perform pg_temp.video_refuses(format('select public.app_video_cost_reserve(%L,%L,%L,''reel'',''fal'',''synthetic/reel'',%L,8,1,8,''{}'')',u,o,gen_random_uuid(),repeat('3',64)),'RP402');
end $$;
-- Exercise the ACTUAL account purge. Financial totals and exact receipt links
-- remain anonymous; deleting orgs alone would miss the real lifecycle.
create temporary table app_video_purge_fixture(actor uuid,org uuid,settled_key text,unresolved_key text,
  ledger uuid,unresolved uuid,receipt jsonb);
grant select,update on app_video_purge_fixture to service_role;
do $$
declare u uuid:=gen_random_uuid(); o uuid:=gen_random_uuid(); r jsonb; ledger uuid; unresolved uuid;
begin
  insert into auth.users(id,email) values(u,'purge-video@example.invalid');
  insert into orgs(id,name,plan) values(o,'Synthetic account purge','pro');
  insert into memberships(user_id,org_id,role) values(u,o,'owner');
  update plan_entitlements set cogs_ceiling_cents=6000 where plan='pro';
  r:=public.app_video_cost_reserve(u,o,'purge-settled-key','reel','fal','synthetic/reel',repeat('8',64),24,5,4.8,'{}');
  r:=public.app_video_cost_settle(u,o,'purge-settled-key','purge-paid-receipt'); ledger:=(r->>'ledger_id')::uuid;
  r:=public.app_video_cost_reserve(u,o,'purge-unresolved-key','aerial','kie','synthetic/aerial',repeat('9',64),80,1,80,'{}');
  unresolved:=(r->>'id')::uuid;
  insert into app_video_purge_fixture values(u,o,'purge-settled-key','purge-unresolved-key',ledger,unresolved,null);
end $$;
set local role service_role;
update app_video_purge_fixture set receipt=public.prepare_account_deletion(actor,'fixture-uploads','fixture-renders');
reset role;
do $$
declare f app_video_purge_fixture; r jsonb;
begin
  select * into f from app_video_purge_fixture;
  perform pg_temp.check_video((f.receipt->>'ok')::boolean and not exists(select 1 from orgs where id=f.org),'actual account purge succeeds');
  perform pg_temp.check_video((select org_id is null and job_id is null and meta='{}'::jsonb
      and idempotency_key is null and total_cents=24 and billing_org_id=f.org from cost_ledger where id=f.ledger)
    and (select count(*)=2 from app_video_cost_reservations where org_id=f.org),
    'ledger anonymized; exact amount, billing identity and immutable cost-only receipts retained');
  perform pg_temp.check_video((select cost_ledger_id=f.ledger and hold_cents=24 from app_video_cost_reservations
      where org_id=f.org and idempotency_key=f.settled_key) and public.serving_ceiling_spent_cents(f.org,null,null)=104,
    'retained booked amount plus unresolved hold counted once after account removal');
  r:=public.app_video_cost_settle(f.actor,f.org,f.settled_key,'purge-paid-receipt');
  perform pg_temp.check_video((r->>'ledger_id')::uuid=f.ledger and
    (select count(*)=1 from cost_ledger where id=f.ledger) and public.serving_ceiling_spent_cents(f.org,null,null)=104,
    'settled tombstone replay preserves original anonymous ledger without a duplicate charge');
  delete from auth.users where id=f.actor;
  r:=public.app_video_cost_settle(f.actor,f.org,f.unresolved_key,'late-after-actual-purge');
  perform pg_temp.check_video((r->>'settled')::boolean and
    (select org_id is null and meta->>'billing_org_id'=f.org::text and total_cents=80 and billing_org_id=f.org
      from cost_ledger where id=(r->>'ledger_id')::uuid),'late paid receipt survives actual purge and auth deletion');
  perform pg_temp.check_video(public.serving_ceiling_spent_cents(f.org,null,null)=104
    and (select count(*)=2 from cost_ledger where billing_org_id=f.org),
    'late settlement swaps retained hold for exact booked amount without losing or doubling liability');
end $$;
select 'PASS ordinary video SQL: '||n||' assertions' from app_video_assertions;
rollback;
"""


def reserve(actor, org, key, cents=4800, feature="drone_render"):
    return (f"select public.app_video_cost_reserve('{actor}','{org}','{key}','{feature}',"
            f"'fal','synthetic/topaz','{'a'*64}',{cents},1,{cents},'{{}}');")


started = False
try:
    receipt["postgresVersion"] = run("version", [TOOLS["psql"], "--version"]).strip()
    run("initdb", [TOOLS["initdb"], "-D", DATA, "-U", "postgres", "-A", "trust", "--no-locale", "--encoding=UTF8"])
    run("start", [TOOLS["pg_ctl"], "-D", DATA, "-l", OUT / "server.log", "-w", "-t", "30", "-o",
                  f"-k {SOCK} -p {PORT} -c listen_addresses='' -c shared_buffers=16MB", "start"])
    started = True
    conn = ["-h", SOCK, "-p", PORT, "-U", "postgres"]
    run("createdb", [TOOLS["createdb"], *conn, "video_cost_audit"])
    psql = [TOOLS["psql"], "-X", "--no-password", *conn, "-d", "video_cost_audit", "-v", "ON_ERROR_STOP=1"]
    run("bootstrap", [*psql, "-q", "-f", SQL / "tests/ci-bootstrap.sql"])
    for m in sorted((SQL / "migrations").glob("*.sql")):
        run("apply-" + m.stem, [*psql, "-q", "-1", "-f", m])
    for name in ("video_erase", "video_erase_direct_bria"):
        receipt[name + "-preserved"] = run(name + "-preserved", [*psql, "-f", SQL / f"tests/{name}.sql"]).strip()
    # This legacy monthly-cap suite intentionally uses synthetic plan caps,
    # independently from signed retail serving envelopes tested elsewhere.
    receipt["syntheticFundedMode"] = run("synthetic-monthly-mode", [*psql, "-Atq"], "update public.app_config set value=jsonb_set(value,'{mode}','\"funded\"'::jsonb) where key='serving_mode'; select public.serving_mode();").strip()
    assert receipt["syntheticFundedMode"] == "funded"
    receipt["rejections-fresh"] = run("rejections-fresh", [*psql, "-Atq", "-f", SQL / "tests/app_video_rejections.sql"]).strip()
    receipt["ordinary-fresh"] = run("ordinary-fresh", [*psql, "-Atq"], FIXTURE).strip()
    # Replay the ACTUAL final definitions, not predecessor Team DDL which
    # would undo subsequent account-safety and financial-authority fixes.
    current_definitions = run("capture-final-video-authority", [*psql, "-Atq"], """
select pg_get_functiondef(p.oid)||';' from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in ('app_video_cost_reserve','app_video_cost_settle',
 'app_video_cost_release_rejected','app_video_cost_pin_receipt','app_video_held_cents',
 'prepare_account_deletion') order by p.proname;
""")
    assert current_definitions.count("CREATE OR REPLACE FUNCTION") == 6, "Exact final authority inventory changed"
    receipt["replayedAuthoritySHA256"] = hashlib.sha256(current_definitions.encode()).hexdigest()
    run("replay-final-video-authority", [*psql, "-q", "-1"], current_definitions)
    receipt["rejections-replay"] = run("rejections-replay", [*psql, "-Atq", "-f", SQL / "tests/app_video_rejections.sql"]).strip()
    receipt["ordinary-replay"] = run("ordinary-replay", [*psql, "-Atq"], FIXTURE).strip()
    deletion_definition = run("capture-final-deletion-authority", [*psql, "-Atq"],
                              "select pg_get_functiondef('public.prepare_account_deletion(uuid,text,text)'::regprocedure);")
    retention = "update public.cost_ledger set org_id=null,job_id=null,meta='{}'::jsonb,idempotency_key=null"
    assert deletion_definition.count(retention) == 1, "Exact anonymization guard changed"
    deletion_mutant = deletion_definition.replace(retention, "delete from public.cost_ledger", 1)
    run("install-deleted-ledger-negative-control", [*psql, "-q", "-1"], deletion_mutant)
    run("deleted-ledger-negative-control-refused", [*psql, "-Atq"], FIXTURE,
        refuses="FAIL: ledger anonymized; exact amount, billing identity and immutable cost-only receipts retained")
    run("restore-final-deletion-authority", [*psql, "-q", "-1"], deletion_definition)
    receipt["ordinary-restored"] = run("ordinary-restored", [*psql, "-Atq"], FIXTURE).strip()

    u, outsider, o, foreign, k1, k2 = [str(uuid.uuid4()) for _ in range(6)]
    run("race-setup", [*psql, "-q"], f"""
insert into auth.users(id,email) values('{u}','race-owner@example.invalid'),('{outsider}','race-other@example.invalid');
insert into orgs(id,name,plan) values('{o}','Synthetic video race','pro'),('{foreign}','Synthetic private foreign','pro');
insert into memberships(user_id,org_id,role) values('{u}','{o}','owner');
update plan_entitlements set topaz_per_month=50,reels_per_month=50,aerials_per_month=50,cogs_ceiling_cents=6000 where plan='pro';
insert into cost_ledger(org_id,feature,provider,total_cents) values('{foreign}','synthetic','fal',90);
""")
    barrier = Barrier(2)
    race_label = "race-reserve"

    def racing_reserve(item):
        i, key = item
        barrier.wait(timeout=10)
        p = subprocess.run([str(x) for x in [*psql, "-Atq"]], input=reserve(u, o, key), env=ENV,
                           cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=40)
        log = OUT / f"{race_label}-{i}.log"
        log.write_text(p.stdout)
        receipt["commands"].append({"name": f"{race_label}-{i}", "exit": p.returncode,
                                    "log_sha256": hashlib.sha256(log.read_bytes()).hexdigest()})
        return {"key": key, "exit": p.returncode, "data": json.loads(p.stdout.strip()) if not p.returncode else None,
                "budgetDenied": p.returncode != 0 and "RP402:" in p.stdout}

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(racing_reserve, enumerate((k1, k2))))
    assert sum(r["exit"] == 0 for r in results) == 1 and sum(r["budgetDenied"] for r in results) == 1, results
    winner = next(r for r in results if r["exit"] == 0)
    assert winner["data"]["reserved"] is True
    receipt["concurrent4800Against6000"] = results

    def snapshot(name):
        return json.loads(run(name, [*psql, "-Atq"], f"""
select jsonb_build_object('reservations',(select count(*) from app_video_cost_reservations where org_id='{o}'),
 'ledgers',(select count(*) from cost_ledger where org_id='{o}'), 'held',app_video_held_cents('{o}'),
 'booked',(select coalesce(sum(total_cents),0) from cost_ledger where org_id='{o}'), 'spend',org_month_spend_cents('{o}'));
""").strip())

    before = snapshot("race-before-settlement")
    assert before == {"reservations": 1, "ledgers": 0, "held": 4800, "booked": 0, "spend": 4800}, before
    run("cross-key-budget-fence", [*psql, "-Atq"], reserve(u, o, str(uuid.uuid4()), 1201, "reel"), refuses="RP402:")
    # Actual authenticated callers: own aggregate works, foreign ledger/holds
    # remain invisible through fresh scoped authority, and private RPC/table access fails.
    auth = f"set role authenticated; set request.jwt.claim.sub='{u}'; set request.jwt.claim.role='authenticated';\n"
    visible = json.loads(run("authenticated-aggregates", [*psql, "-Atq"], auth +
        f"select jsonb_build_object('own',org_month_spend_cents('{o}'),'foreign',org_month_spend_cents('{foreign}'),'held',app_video_held_cents('{o}'));").strip())
    assert visible == {"own": 4800, "foreign": 0, "held": 4800}, visible
    nonmember = json.loads(run("nonmember-aggregates", [*psql, "-Atq"],
        f"set role authenticated; set request.jwt.claim.sub='{outsider}'; set request.jwt.claim.role='authenticated';"
        f"select jsonb_build_object('held',app_video_held_cents('{o}'),'spend',org_month_spend_cents('{o}'));").strip())
    assert nonmember == {"held": 0, "spend": 0}, nonmember
    run("authenticated-table-denied", [*psql, "-Atq"], auth + "select * from app_video_cost_reservations;", refuses="permission denied")
    run("authenticated-reserve-denied", [*psql, "-Atq"], auth + reserve(u, o, str(uuid.uuid4()), 1), refuses="permission denied")
    settlement = f"select app_video_cost_settle('{u}','{o}','{winner['key']}','synthetic-paid-receipt');"
    run("authenticated-settle-denied", [*psql, "-Atq"], auth + settlement, refuses="permission denied")
    run("anon-aggregate-denied", [*psql, "-Atq"], "set role anon;" + f"select app_video_held_cents('{o}');", refuses="permission denied")
    with ThreadPoolExecutor(max_workers=8) as pool:
        settled = list(pool.map(lambda i: json.loads(run(f"concurrent-settle-{i}", [*psql, "-Atq"],
                    "set role service_role;" + settlement).strip()), range(8)))
    assert all(r["settled"] is True and r["total_cents"] == 4800 for r in settled)
    assert len({r["ledger_id"] for r in settled}) == 1
    after = snapshot("race-after-settlement")
    assert after == {"reservations": 1, "ledgers": 1, "held": 0, "booked": 4800, "spend": 4800}, after
    receipt["concurrentSettlement"] = {"callers": 8, "ledgerIds": sorted({r["ledger_id"] for r in settled}),
                                        "before": before, "after": after}
    # Two *different* feature journals must serialize on exactly the same org
    # lock. Their combined 4800+10 exceeds4805, so only one may admit.
    cross, listing, asset = [str(uuid.uuid4()) for _ in range(3)]
    run("reflection-race-setup", [*psql, "-q"], f"""
insert into orgs(id,name,plan) values('{cross}','Synthetic reflection overlap','pro');
insert into memberships(user_id,org_id,role) values('{u}','{cross}','owner');
insert into listings(id,org_id,agent_id,address) values('{listing}','{cross}','{u}','Synthetic');
insert into capture_assets(id,listing_id,kind,storage_key,bucket,uploaded,duration_s)
 values('{asset}','{listing}','video','synthetic/race.mp4','renders',true,2);
update plan_entitlements set cogs_ceiling_cents=4805 where plan='pro';
""")
    cfg = json.dumps({"mask_unit_cost_cents": 2, "erase_unit_cost_cents": 3,
                      "price_version": "synthetic-race", "output_hosts": ["outputs.example.com"]})
    overlap_queries = [reserve(u, cross, str(uuid.uuid4())),
        f"select public.video_erase_reserve_direct('{cross}','{u}','{listing}','{uuid.uuid4()}',"
        f"'{asset}','{uuid.uuid4()}','{'b'*64}',2,'{cfg}','bria-video-v1');"]
    overlap_barrier = Barrier(2)

    def overlap_worker(item):
        i, query = item
        overlap_barrier.wait(timeout=10)
        p = subprocess.run([str(x) for x in [*psql, "-Atq"]], input=query, env=ENV, cwd=ROOT,
                           text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=40)
        (OUT / f"reflection-race-{i}.log").write_text(p.stdout)
        return {"feature": "ordinary" if i == 0 else "reflection", "exit": p.returncode,
                "budgetDenied": p.returncode != 0 and "RP402:" in p.stdout,
                "data": json.loads(p.stdout.strip()) if not p.returncode else None}

    with ThreadPoolExecutor(max_workers=2) as pool:
        overlap = list(pool.map(overlap_worker, enumerate(overlap_queries)))
    assert sum(r["exit"] == 0 for r in overlap) == 1 and sum(r["budgetDenied"] for r in overlap) == 1, overlap
    total = json.loads(run("reflection-race-counts", [*psql, "-Atq"], f"""
select jsonb_build_object('ordinaryHeld',app_video_held_cents('{cross}'),
 'reflectionHeld',video_erase_held_cents('{cross}'),'spend',org_month_spend_cents('{cross}'));
""").strip())
    assert total["spend"] in (4800, 10) and total["spend"] == total["ordinaryHeld"] + total["reflectionHeld"]
    receipt["concurrentReflectionOverlap"] = {"ceiling": 4805, "results": overlap, "totals": total}

    # Mutate the actual final function, preserving every latest authority and
    # price guard. Remove exactly its three financial/physical admission locks;
    # a controlled pause after the shared spend read must expose over-admission.
    final_reserve = run("read-final-reserve-body", [*psql, "-Atq"],
        "select pg_get_functiondef('public.app_video_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,numeric,numeric,jsonb)'::regprocedure);")
    unguarded = final_reserve
    for before, after in (
        ("perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||public.library_actor_billing_org(p_actor,p_org)::text,42));", "perform 1; -- negative control removes pooled serialization"),
        ("where id=public.library_actor_billing_org(p_actor,p_org)and deleted_at is null for update;", "where id=public.library_actor_billing_org(p_actor,p_org)and deleted_at is null;"),
        ("where id=p_org and deleted_at is null for update;", "where id=p_org and deleted_at is null;"),
        ("spent:=public.org_month_spend_cents(public.library_actor_billing_org(p_actor,p_org));", "spent:=public.org_month_spend_cents(public.library_actor_billing_org(p_actor,p_org)); perform pg_sleep(0.5);"),
    ):
        assert unguarded.count(before) == 1, before
        unguarded = unguarded.replace(before, after)
    assert unguarded != final_reserve and "perform pg_sleep(0.5)" in unguarded
    (OUT / "removed-locks-mutation.sql").write_text(unguarded)
    run("install-negative-control", [*psql, "-q", "-1"], unguarded)
    o, k1, k2 = [str(uuid.uuid4()) for _ in range(3)]
    race_label = "removed-locks-reserve"
    run("negative-race-setup", [*psql, "-q"], f"""
insert into orgs(id,name,plan) values('{o}','Synthetic removed-lock mutation','pro');
insert into memberships(user_id,org_id,role) values('{u}','{o}','owner');
update plan_entitlements set cogs_ceiling_cents=6000 where plan='pro';
""")
    with ThreadPoolExecutor(max_workers=2) as pool:
        negative = list(pool.map(racing_reserve, enumerate((k1, k2))))
    try:
        assert sum(r["exit"] == 0 for r in negative) == 1 and sum(r["budgetDenied"] for r in negative) == 1
    except AssertionError:
        assert all(r["exit"] == 0 and r["data"]["reserved"] is True for r in negative), negative
        violated = snapshot("removed-locks-violated-invariant")
        assert violated == {"reservations": 2, "ledgers": 0, "held": 9600, "booked": 0, "spend": 9600}
        receipt["negativeControl"] = {"removed": "org advisory and row admission locks", "caught": True,
                                       "ceiling": 6000, "totals": violated}
    else:
        raise AssertionError("Admission race failed to catch removed serialization")
    run("restore-after-negative-control", [*psql, "-q", "-1"], final_reserve)
    assert run("verify-restored-final-reserve", [*psql, "-Atq"], "select pg_get_functiondef('public.app_video_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,numeric,numeric,jsonb)'::regprocedure);") == final_reserve
    receipt["sourceHashesAfter"] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
    receipt["sourceUnchanged"] = receipt["sourceHashesAfter"] == receipt["sourceHashes"]
    assert receipt["sourceUnchanged"], "Ordinary-video SQL source changed during verification"
    receipt["passed"] = True
finally:
    if started:
        run("stop", [TOOLS["pg_ctl"], "-D", DATA, "-m", "fast", "-w", "stop"])
    (OUT / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(str(OUT / "receipt.json"), flush=True)
