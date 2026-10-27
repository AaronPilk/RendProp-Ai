#!/usr/bin/env python3
"""Disposable actual PG funding/period/quota/hold proofs; no hosted mutation."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from fresh_schema_migrations import partition_fresh_migrations
from threading import Barrier
import argparse,hashlib,json,os,shutil,subprocess,tempfile,time
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);args=p.parse_args()
OUT=args.evidence_dir or Path(tempfile.mkdtemp(prefix='paid-quality-proof-'));OUT.mkdir(parents=True,exist_ok=True)
assert shutil.disk_usage(ROOT).free>=3*1024**3,'Preserve internal3GiB reserve'
DATA=Path(tempfile.mkdtemp(prefix='paid-quality-owned-pg-'));SOCK=Path(tempfile.mkdtemp(prefix='paid-quality-sock-',dir='/tmp'));started=False
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
tool=lambda n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)
MIG=SQL/'migrations/20261015080552_paid_quality_monthly_processing_allowance.sql';FIX=SQL/'tests/paid_quality_processing.sql';BASE=SQL/'tests/property_video_jobs.sql'
MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'));SOURCES=[*MIGRATIONS,SQL/'tests/ci-bootstrap.sql',BASE,FIX,Path(__file__).resolve()]
hashes=lambda:{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest()for f in SOURCES}
r={'passed':False,'scope':'actual local PostgreSQL authority; synthetic verified-purchase and cost receipts only','networkCalls':0,'providerCalls':0,'sourceHashes':hashes(),'commands':[],'controls':[],'races':[]}
def run(name,cmd,body=None,refuses=None):
 c=subprocess.run([str(x)for x in cmd],input=body,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
 f=OUT/(name+'.log');f.write_text(c.stdout);r['commands'].append({'name':name,'exit':c.returncode,'logSHA256':hashlib.sha256(f.read_bytes()).hexdigest()})
 assert(c.returncode and refuses in c.stdout)if refuses else c.returncode==0,(name,c.stdout[-5000:]);return c.stdout
def race(name,commands):
 barrier=Barrier(len(commands))
 def call(pair):
  i,body=pair;barrier.wait(timeout=10);start=time.monotonic()
  c=subprocess.run([*PSQL,'-Atq'],input=body,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
  (OUT/f'{name}-{i}.log').write_text(c.stdout);return{'exit':c.returncode,'output':c.stdout,'elapsed':time.monotonic()-start}
 with ThreadPoolExecutor(max_workers=len(commands))as pool:return list(pool.map(call,enumerate(commands)))
base=BASE.read_text();seed=base[base.index('insert into auth.users'):base.index('select pg_temp.ok((select bool_and')]
# The shared video seed uses manual Starter authority to create its listing.
# This proof then starts from Free so only its signed Apple receipt can grant
# paid processing, preserving the manual-plan negative control below.
fixture='begin;\n'+seed+"\nupdate orgs set plan='free',plan_source=null where id=(select org from bf);\n"+FIX.read_text()
try:
 run('initdb',[tool('initdb'),'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[tool('pg_ctl'),'-D',DATA,'-l',OUT/'postgres.log','-w','-o',f"-k {SOCK} -p 55577 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 conn=['-h',SOCK,'-p','55577','-U','postgres'];run('createdb',[tool('createdb'),*conn,'paid_quality'])
 PSQL=[tool('psql'),'-X','--no-password',*conn,'-d','paid_quality','-v','ON_ERROR_STOP=1']
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for m in partition_fresh_migrations(MIGRATIONS)[0]:
  run('apply-'+m.stem,[*PSQL,'-q','-1','-f',m])
  if m==MIG:
   # The October 26 intro policy later replaces org_entitlement. Prove this
   # migration's exact replay and changed-wrapper refusal at its own boundary.
   run('replay-own-historical',[*PSQL,'-q','-1','-f',MIG])
   run('clone-own-historical',[tool('createdb'),*conn,'-T','paid_quality','paid_quality_guard'])
 HISTORICAL_PSQL=[tool('psql'),'-X','--no-password',*conn,'-d','paid_quality_guard','-v','ON_ERROR_STOP=1']
 for stage in ['fresh','replay']:
  out=run(stage+'-actual-funding',[*PSQL,'-Atq'],fixture)
  rows=[json.loads(line)for line in out.splitlines()if line.startswith('{')and'assertions'in line];assert len(rows)==1 and rows[0]['passed'];r[stage]=rows[0]
 for label,signature,anchor,replacement,oracle in [
  ('paid-receipt-authority','public.paid_quality_processing_budget(uuid)',"transaction_signed_at is not null","true",'missing signed transaction cannot grant paid processing'),
  ('current-paid-deadline','public.paid_quality_processing_budget(uuid)','expires_at=o.plan_expires_at','true','historical receipt cannot fund a different current paid deadline'),
  ('COGS-floor','public.org_entitlement(uuid)','e.cogs_ceiling_cents:=greatest(e.cogs_ceiling_cents,budget);','null;','COGS and atomic serving agree'),
  ('atomic-envelope-floor','public.plan_serving_ceiling_before_credit(uuid)',"if budget>0 and env->>'kind'='retail'","if false and env->>'kind'='retail'",'COGS and atomic serving agree'),
  ('paid-service-period','public.org_month_spend_cents(uuid)','if public.paid_quality_processing_budget(b)>0 then','if false then','previous paid term booked cost never blocks a renewed service window'),
  ('all-AI-liability','public.library_serving_envelope_admit(uuid,uuid,numeric,text)','spent:=greatest(0,spent-pre);','spent:=0;','real atomic gate refuses above remaining balance')]:
  original=run('read-'+label,[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%signature]);assert original.count(anchor)==1,(label,'source anchor')
  run('compile-'+label,[*PSQL,'-Atq'],original.replace(anchor,replacement,1));run('negative-'+label,[*PSQL,'-Atq'],fixture,refuses=oracle);run('restore-'+label,[*PSQL,'-Atq'],original)
  r['controls'].append({'name':label,'compiledActualSQL':True,'unsafeMutationDetected':True})
 # An unseen production wrapper cannot be overwritten even if its comment
 # happens to mention the helper name; the guard accepts exact source MD5s only.
 original=run('read-unseen-wrapper',[*HISTORICAL_PSQL,'-Atq','-c',"select pg_get_functiondef('public.plan_serving_ceiling(uuid)'::regprocedure)"])
 assert original.count('declare b uuid;')==1
 run('compile-unseen-wrapper',[*HISTORICAL_PSQL,'-Atq'],original.replace('declare b uuid;','-- unforeseen edit mentioning paid_quality_processing_budget\ndeclare b uuid;',1))
 run('negative-unseen-wrapper',[*HISTORICAL_PSQL,'-q','-1','-f',MIG],refuses='Review changed plan_serving_ceiling')
 run('restore-unseen-wrapper',[*HISTORICAL_PSQL,'-Atq'],original);r['controls'].append({'name':'unseen-wrapper-overwrite','compiledActualSQL':True,'unsafeMutationDetected':True})
 # Mixed actual video/serving writers share the last300c after a renewal.
 paid="set role service_role;select apply_apple_entitlement_v2((select org from bf),(select actor from bf),'race-paid-quality-original','race-paid-quality-transaction','com.rendprop.app.starter.monthly','max','Production','active',now()+interval'29 days',true,'DID_RENEW',now()-interval'1 day',now()-interval'30 seconds',now()-interval'30 seconds',now()-interval'30 seconds');reset role;"
 setup='begin;'+seed+"update orgs set plan='free',plan_source=null where id=(select org from bf);"+paid+"update app_config set value=jsonb_set(value,'{enabled}','true')where key='paid_quality_processing';update app_config set value='{\"enabled\":true,\"profile\":\"fal-kling3-4k-v1\"}'where key='property_video_quality';update app_config set value='{\"mode\":\"ceiling\",\"free_published_listings\":1}'where key='serving_mode';set role service_role;select serving_cost_reserve((select actor from bf),(select org from bf),'paid-quality-race-existing','held','gemini','fixture',repeat('a',64),6200,'fixture');reset role;update serving_cost_reservations set created_at=now()-interval'2 days'where request_key='paid-quality-race-existing';insert into cost_ledger(org_id,feature,provider,model,total_cents,meta,created_at)values((select org from bf),'copy','openai','prior-term-race',6500,'{}',now()-interval'2 days');create table public.paid_quality_race_fixture as select *from bf;grant select on public.paid_quality_race_fixture to service_role;commit;"
 run('race-seed',[*PSQL,'-Atq'],setup)
 def reserve(i):
  actor="(select actor from paid_quality_race_fixture)";org="(select org from paid_quality_race_fixture)"
  return("set role service_role;select app_video_cost_reserve(%s,%s,'paid-quality-race-1','reel','fal','fal-ai/kling-video/v3/4k/image-to-video',repeat('b',64),210,5,42,'{\"task\":\"video.reel_clip\"}');"%(actor,org))if i==1 else("set role service_role;select serving_cost_reserve(%s,%s,'paid-quality-race-2','held','fal','fixture',repeat('b',64),210,'fixture');"%(actor,org))
 outcomes=race('shared-remaining-balance',[reserve(1),reserve(2)]);assert sum(x['exit']==0 for x in outcomes)==1 and sum('RP402:'in x['output']for x in outcomes)==1,outcomes
 actual=run('race-balance',[*PSQL,'-Atq','-c',"select (serving_envelope_state(org)->>'held_cents')::numeric from paid_quality_race_fixture"]).strip();assert actual=='6410.00',actual
 r['races'].append({'name':'shared-remaining-balance','actualConcurrentRequests':2,'exactlyOneAdmitted':True,'heldCents':6410,'otherRefused402':True})
 assert hashes()==r['sourceHashes'],'A snapshotted SQL input changed during proof';r['passed']=True
 print(json.dumps({'passed':True,'freshAssertions':r['fresh']['assertions'],'replayAssertions':r['replay']['assertions'],'compiledControls':len(r['controls']),'races':len(r['races']),'receipt':str(OUT/'receipt.json')}))
finally:
 if started:run('stop',[tool('pg_ctl'),'-D',DATA,'-m','immediate','-w','stop'])
 (OUT/'receipt.json').write_text(json.dumps(r,indent=2)+'\n')
 if not started or r['passed']:shutil.rmtree(DATA)
 if SOCK.exists():shutil.rmtree(SOCK)
