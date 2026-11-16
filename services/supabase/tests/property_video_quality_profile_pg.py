#!/usr/bin/env python3
"""Real disposable PG profile/funding/replay/role/concurrency proofs; no network."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from fresh_schema_migrations import partition_fresh_migrations
from threading import Barrier
import argparse,hashlib,json,os,shutil,subprocess,tempfile,time
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);args=p.parse_args()
OUT=args.evidence_dir or Path(tempfile.mkdtemp(prefix='quality-profile-proof-'));OUT.mkdir(parents=True,exist_ok=True)
assert shutil.disk_usage(ROOT).free>=3*1024**3,'Preserve internal3GiB reserve'
DATA=Path(tempfile.mkdtemp(prefix='quality-profile-owned-pg-'));SOCK=Path(tempfile.mkdtemp(prefix='quality-profile-sock-',dir='/tmp'));started=False
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
tool=lambda n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)
MIG=SQL/'migrations/20261015073835_property_video_immutable_quality_profile.sql';FIX=SQL/'tests/property_video_quality_profile.sql';BASE=SQL/'tests/property_video_jobs.sql'
MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'))
SOURCES=[*MIGRATIONS,SQL/'tests/ci-bootstrap.sql',BASE,FIX,Path(__file__).resolve()]
hashes=lambda:{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest()for f in SOURCES}
r={'passed':False,'scope':'actual local PostgreSQL schema/functions/roles; closed receipt fixtures, no supplier calls','networkCalls':0,'providerCalls':0,'sourceHashes':hashes(),'commands':[],'controls':[],'races':[]}
def run(name,cmd,body=None,refuses=None):
 c=subprocess.run([str(x)for x in cmd],input=body,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
 f=OUT/(name+'.log');f.write_text(c.stdout);r['commands'].append({'name':name,'exit':c.returncode,'logSHA256':hashlib.sha256(f.read_bytes()).hexdigest()})
 assert(c.returncode and refuses in c.stdout)if refuses else c.returncode==0,(name,c.stdout[-4000:]);return c.stdout
def race(name,commands):
 barrier=Barrier(len(commands))
 def call(pair):
  i,body=pair;barrier.wait(timeout=10);start=time.monotonic()
  c=subprocess.run([*PSQL,'-Atq'],input=body,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
  (OUT/f'{name}-{i}.log').write_text(c.stdout)
  return{'exit':c.returncode,'output':c.stdout,'elapsed':time.monotonic()-start}
 with ThreadPoolExecutor(max_workers=len(commands))as pool:return list(pool.map(call,enumerate(commands)))
base=BASE.read_text();seed=base[base.index('insert into auth.users'):base.index('select pg_temp.ok((select bool_and')]
fixture='begin;\n'+seed+'\n'+FIX.read_text()
try:
 run('initdb',[tool('initdb'),'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[tool('pg_ctl'),'-D',DATA,'-l',OUT/'postgres.log','-w','-o',f"-k {SOCK} -p 55576 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 conn=['-h',SOCK,'-p','55576','-U','postgres'];run('createdb',[tool('createdb'),*conn,'quality_profiles'])
 PSQL=[tool('psql'),'-X','--no-password',*conn,'-d','quality_profiles','-v','ON_ERROR_STOP=1']
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for m in partition_fresh_migrations(MIGRATIONS)[0]:run('apply-'+m.stem,[*PSQL,'-q','-1','-f',m])
 for stage in ['fresh','replay']:
  if stage=='replay':run('replay-own-migration',[*PSQL,'-q','-1','-f',MIG])
  out=run(stage+'-actual-profile',[*PSQL,'-Atq'],fixture)
  rows=[json.loads(line)for line in out.splitlines()if line.startswith('{')and'assertions'in line];assert len(rows)==1 and rows[0]['passed'];r[stage]=rows[0]
 for label,signature,anchor,replacement,oracle in [
  ('immutable-saved-profile','public.property_video_quality_freeze()',"if new.quality_profile is distinct from old.quality_profile",'if false','saved profile cannot be changed'),
  ('bounded-profile-deadline','public.property_video_quality_freeze()',"if quoted='fal-kling3-4k-v1'then new.deadline:=new.created_at+interval'24 hours';end if;",'null;','new profile bounded24h deadline'),
  ('complete-generation-price','public.property_video_job_admit(uuid,jsonb,numeric,text)',"if p_quality_profile='fal-kling3-4k-v1'and(p_quote is null or p_quote<210*jsonb_array_length(p_manifest->'sources'))then",'if false then','underpriced profile refuses before capacity'),
  ('context-leak','public.property_video_job_admit(uuid,jsonb,numeric,text)',"perform set_config('rendprop.property_video_quality_profile',coalesce(prior,''),true);",'null;','admission context restored cannot leak to later direct enqueue')]:
  original=run('read-'+label,[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%signature]);assert original.count(anchor)==1,(label,'source anchor')
  run('compile-'+label,[*PSQL,'-Atq'],original.replace(anchor,replacement,1))
  run('negative-'+label,[*PSQL,'-Atq'],fixture,refuses=oracle)
  run('restore-'+label,[*PSQL,'-Atq'],original);r['controls'].append({'name':label,'compiledActualSQL':True,'unsafeMutationDetected':True})
 # Same real ordinaryMax receipt fixture; no funding/grant on any host.
 paid="set role service_role;select apply_apple_entitlement_v2((select org from bf),(select actor from bf),'race-quality-original','race-quality-transaction','com.rendprop.app.starter.monthly','max','Production','active',now()+interval'29 days',true,'DID_RENEW',now()-interval'1 day',now()-interval'30 seconds',now()-interval'30 seconds',now()-interval'30 seconds');reset role;"
 setup='begin;'+seed+paid+"update app_config set value=jsonb_set(value,'{enabled}','true')where key='property_video_jobs';update app_config set value='{\"enabled\":true,\"profile\":\"fal-kling3-4k-v1\"}'where key='property_video_quality';create table public.quality_profile_race_fixture as select jsonb_set(jsonb_set(m,'{sources}',jsonb_build_array(m#>'{sources,0}',m#>'{sources,1}')),'{presentation,shot_labels}','[null,null]')m from bm;grant select on public.quality_profile_race_fixture to service_role;commit;"
 run('race-seed',[*PSQL,'-Atq'],setup)
 actor='f1100000-0000-4000-8000-000000000001'
 def recipe(i):return "jsonb_set((select m from quality_profile_race_fixture),'{operation_id}',to_jsonb('f4800000-0000-4000-8000-%012d'::text))"%i
 def admit(i):return"select property_video_job_admit('%s',%s,500,'fal-kling3-4k-v1');"%(actor,recipe(i))
 outcomes=race('same-operation-profile',["set role service_role;"+admit(1)for _ in range(6)]);assert all(x['exit']==0 for x in outcomes),outcomes
 replies=[json.loads(next(l for l in x['output'].splitlines()if l.startswith('{')))for x in outcomes]
 assert len({x['job']['id']for x in replies})==1 and all(x['job']['quality_profile']=='fal-kling3-4k-v1'for x in replies)
 r['races'].append({'name':'same-operation-profile','actualConcurrentRequests':6,'exactlyOneJob':True,'sameFrozenProfile':True})
 flip="update app_config set value=jsonb_set(value,'{enabled}','false')where key='property_video_quality';"
 outcomes=race('cutover-before-stale-admission',["begin;"+flip+"select pg_sleep(.5);commit;","select pg_sleep(.1);set role service_role;"+admit(2)])
 assert outcomes[0]['exit']==0 and outcomes[1]['exit']!=0 and'RP409:'in outcomes[1]['output'],outcomes
 assert run('no-stale-job',[*PSQL,'-Atq','-c',"select count(*)from property_video_jobs where operation_id='f4800000-0000-4000-8000-000000000002'"]).strip()=='0'
 r['races'].append({'name':'cutover-before-stale-admission','actualConcurrentTransactions':2,'staleQuoteRefused':True,'noJob':True})
 run('enable-fixture',[*PSQL,'-Atq'],"update app_config set value=jsonb_set(value,'{enabled}','true')where key='property_video_quality';")
 outcomes=race('admission-before-cutover',["begin;set role service_role;"+admit(3)+"select pg_sleep(.5);commit;","select pg_sleep(.1);begin;"+flip+"commit;"])
 assert all(x['exit']==0 for x in outcomes),outcomes
 assert outcomes[1]['elapsed']>=.4,outcomes
 assert run('saved-profile-after-cutover',[*PSQL,'-Atq','-c',"select quality_profile from property_video_jobs where operation_id='f4800000-0000-4000-8000-000000000003'"]).strip()=='fal-kling3-4k-v1'
 r['races'].append({'name':'admission-before-cutover','actualConcurrentTransactions':2,'configFlipWaitedForAdmission':True,'savedProfileRetained':True})
 assert hashes()==r['sourceHashes'],'A snapshotted SQL input changed during proof';r['passed']=True
 print(json.dumps({'passed':True,'freshAssertions':r['fresh']['assertions'],'replayAssertions':r['replay']['assertions'],'compiledControls':len(r['controls']),'races':len(r['races']),'receipt':str(OUT/'receipt.json')}))
finally:
 if started:run('stop',[tool('pg_ctl'),'-D',DATA,'-m','immediate','-w','stop'])
 (OUT/'receipt.json').write_text(json.dumps(r,indent=2)+'\n')
 if not started or r['passed']:shutil.rmtree(DATA)
 if SOCK.exists():shutil.rmtree(SOCK)
