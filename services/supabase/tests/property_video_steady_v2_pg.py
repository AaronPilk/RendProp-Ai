#!/usr/bin/env python3
"""Real disposable PG profile/funding/replay/role/concurrency proofs; no network."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier
import argparse,hashlib,json,os,shutil,subprocess,tempfile,time
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path,required=True);args=p.parse_args()
OUT=args.evidence_dir or Path(tempfile.mkdtemp(prefix='steady-v2-proof-'));OUT.mkdir(parents=True,exist_ok=True);OUT.chmod(0o700)
assert shutil.disk_usage(ROOT).free>=3*1024**3,'Preserve internal3GiB reserve'
DATA=Path(tempfile.mkdtemp(prefix='steady-v2-owned-pg-',dir='/Volumes/Rendprop Files/Builds/Active'if Path('/Volumes/Rendprop Files/Builds/Active').is_dir()else None));SOCK=Path(tempfile.mkdtemp(prefix='steady-v2-sock-',dir='/tmp'));started=False
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
tool=lambda n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)
MIG=SQL/'migrations/20261016002000_property_video_steady_v2.sql';FIX=SQL/'tests/property_video_steady_v2.sql';BASE=SQL/'tests/property_video_jobs.sql'
MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'))
SOURCES=[*MIGRATIONS,SQL/'tests/ci-bootstrap.sql',BASE,FIX,SQL/'tests/property_video_quality_profile.sql',Path(__file__).resolve()]
hashes=lambda:{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest()for f in SOURCES}
r={'passed':False,'scope':'actual local PostgreSQL schema/functions/roles; closed receipt fixtures, no supplier calls','networkCalls':0,'providerCalls':0,'sourceHashes':hashes(),'commands':[],'controls':[],'races':[]}
def run(name,cmd,body=None,refuses=None):
 if name!='stop':assert shutil.disk_usage(ROOT).free>=3*1024**3,'Preserve internal3GiB reserve'
 c=subprocess.run([str(x)for x in cmd],input=body,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
 f=OUT/(name+'.log');f.write_text(c.stdout);f.chmod(0o600);r['commands'].append({'name':name,'exit':c.returncode,'logSHA256':hashlib.sha256(f.read_bytes()).hexdigest()})
 assert(c.returncode and refuses in c.stdout)if refuses else c.returncode==0,(name,c.stdout[-4000:]);return c.stdout
def race(name,commands):
 assert shutil.disk_usage(ROOT).free>=3*1024**3,'Preserve internal3GiB reserve'
 barrier=Barrier(len(commands))
 def call(pair):
  i,body=pair;barrier.wait(timeout=10);start=time.monotonic()
  c=subprocess.run([*PSQL,'-Atq'],input=body,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
  (OUT/f'{name}-{i}.log').write_text(c.stdout);(OUT/f'{name}-{i}.log').chmod(0o600)
  return{'exit':c.returncode,'output':c.stdout,'elapsed':time.monotonic()-start}
 with ThreadPoolExecutor(max_workers=len(commands))as pool:return list(pool.map(call,enumerate(commands)))
base=BASE.read_text();seed=base[base.index('insert into auth.users'):base.index('select pg_temp.ok((select bool_and')];helpers=base[base.index('create function pg_temp.paid_clip'):base.index('insert into auth.users')]
fixture='begin;\n'+seed+'\n'+helpers+'\n'+FIX.read_text()
try:
 run('initdb',[tool('initdb'),'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[tool('pg_ctl'),'-D',DATA,'-l',OUT/'postgres.log','-w','-o',f"-k {SOCK} -p 55627 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 conn=['-h',SOCK,'-p','55627','-U','postgres'];run('createdb',[tool('createdb'),*conn,'steady_profiles'])
 PSQL=[tool('psql'),'-X','--no-password',*conn,'-d','steady_profiles','-v','ON_ERROR_STOP=1']
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 signatures=['public.property_video_quality_profile()','public.property_video_quality_freeze()','public.property_video_job_admit(uuid,jsonb,numeric,text)','public.paid_quality_processing_budget(uuid)','public.property_video_job_audio_preflight(uuid,uuid,text,text,numeric,integer)','public.background_video_delivery(uuid,uuid,uuid,text,bigint)']
 targets=','.join("'%s'::regprocedure"%s for s in signatures)
 catalog_query="""with f as(select p.oid,p.oid::regprocedure::text signature,md5(p.prosrc)body,pg_get_userbyid(p.proowner)owner,p.prosecdef,p.provolatile,p.proconfig,p.proacl::text acl from pg_proc p where p.pronamespace='public'::regnamespace and p.prokind in('f','p'))select jsonb_build_object('target_metadata',(select jsonb_object_agg(signature,to_jsonb(f)-'oid'-'body')from f where oid in(TARGETS)),'other_functions',(select md5(string_agg((to_jsonb(f)-'oid')::text,E'\n'order by signature))from f where oid not in(TARGETS)),'other_constraints',(select md5(string_agg(conrelid::regclass||':'||conname||':'||pg_get_constraintdef(oid),E'\n'order by conrelid::regclass::text,conname))from pg_constraint where connamespace='public'::regnamespace and conname<>'property_video_quality_profile_check'),'profile_default',(select column_default from information_schema.columns where table_schema='public'and table_name='property_video_jobs'and column_name='quality_profile'),'config',(select md5(string_agg(to_jsonb(t)::text,E'\n'order by key))from app_config t),'routes',(select md5(string_agg(to_jsonb(t)::text,E'\n'order by id))from ai_routes t));""".replace('TARGETS',targets)
 # Full catalog equality includes the owned function bodies and constraint.
 # Repeating this migration is valid only at its immediate historical boundary;
 # later migrations intentionally replace those strict dependencies.
 other_functions="where oid not in("+targets+")";other_constraints="and conname<>'property_video_quality_profile_check'"
 assert catalog_query.count(other_functions)==1 and catalog_query.count(other_constraints)==1
 final_catalog_query=catalog_query.replace(other_functions,'').replace(other_constraints,'').replace("'other_functions'","'all_functions'").replace("'other_constraints'","'all_constraints'")
 # Own migration must preserve its immediate predecessor's unrelated catalog.
 # Later additive migrations legitimately add other functions/constraints.
 for m in MIGRATIONS:
  if m==MIG:boundary=json.loads(run('before-own-boundary',[*PSQL,'-Atq','-c',catalog_query]).strip())
  run('apply-'+m.stem,[*PSQL,'-q','-1','-f',m])
  if m==MIG:
   actual=json.loads(run('after-own-boundary',[*PSQL,'-Atq','-c',catalog_query]).strip());assert actual==boundary,('unrelated/default/config/route/security drift',boundary,actual)
   own_full_boundary=json.loads(run('whole-own-boundary',[*PSQL,'-Atq','-c',final_catalog_query]).strip())
   run('immediate-replay-own-migration',[*PSQL,'-q','-1','-f',MIG])
   assert json.loads(run('immediate-own-replay-boundary',[*PSQL,'-Atq','-c',final_catalog_query]).strip())==own_full_boundary,'Immediate repeat changed owned/unrelated catalog'
   r['immediateReplayCatalog']=own_full_boundary
 # Refusal/control restoration must preserve the complete final schema.
 final_boundary=json.loads(run('whole-final-boundary',[*PSQL,'-Atq','-c',final_catalog_query]).strip())
 r['boundaryPreservation']=actual;r['wholeFinalCatalog']=final_boundary;r['migrationCount']=len(MIGRATIONS)
 # A historic migration must refuse to overwrite a later Kie-aware profile.
 # Preserve its exact production signature/body guard and prove atomic refusal.
 late_refusal='Review changed steady-v2 dependency: public.property_video_quality_profile()'
 run('late-own-replay-refused',[*PSQL,'-q','-1','-f',MIG],refuses=late_refusal)
 assert json.loads(run('late-own-replay-refusal-boundary',[*PSQL,'-Atq','-c',final_catalog_query]).strip())==final_boundary,'Refused old repeat changed final catalog'
 r['lateReplayRefusal']={'exactGuard':late_refusal,'wholeFinalCatalogPreserved':True}
 legacy='begin;\n'+seed+'\n'+(SQL/'tests/property_video_quality_profile.sql').read_text()
 run('unchanged-v1-regression',[*PSQL,'-Atq'],legacy)

 for stage in ['fresh','replay']:
  # Both fixture passes run on the complete final schema; own DDL repeat was
  # already checked at the immediate boundary and rejected after later DDL.
  out=run(stage+'-actual-profile',[*PSQL,'-Atq'],fixture)
  rows=[json.loads(line)for line in out.splitlines()if line.startswith('{')and'assertions'in line];assert len(rows)==1 and rows[0]['passed'];r[stage]=rows[0]
 for label,signature,anchor,replacement,oracle in [
  ('immutable-saved-profile','public.property_video_quality_freeze()',"if new.quality_profile is distinct from old.quality_profile",'if false','saved profile cannot be changed'),
  ('bounded-v2-deadline','public.property_video_quality_freeze()',"if quoted in('fal-kling3-4k-v1','fal-kling3-4k-steady-v2')then new.deadline", "if quoted='fal-kling3-4k-v1't hen new.deadline".replace('t hen','then'),'new profile bounded24h deadline'),
  ('complete-v2-price','public.property_video_job_admit(uuid,jsonb,numeric,text)',"if p_quality_profile in('fal-kling3-4k-v1','fal-kling3-4k-steady-v2')and(","if p_quality_profile='fal-kling3-4k-v1'and(",'underpriced profile refuses before capacity'),
  ('context-leak','public.property_video_job_admit(uuid,jsonb,numeric,text)',"perform set_config('rendprop.property_video_quality_profile',coalesce(prior,''),true);",'null;','admission context restored cannot leak to later direct enqueue'),
  ('narration-old-fps','public.property_video_job_audio_preflight(uuid,uuid,text,text,numeric,integer)',"output_fps:=case when j.quality_profile='fal-kling3-4k-steady-v2't hen 24 else 30 end;".replace('t hen','then'),"output_fps:=30;",'v2 dissolve exact6frames24fps admits'),
  ('narration-v1-overwrite','public.property_video_job_audio_preflight(uuid,uuid,text,text,numeric,integer)',"output_fps:=case when j.quality_profile='fal-kling3-4k-steady-v2't hen 24 else 30 end;".replace('t hen','then'),"output_fps:=24;",'v1 still uses8frames30fps'),
  ('missing-delivery-profile','public.background_video_delivery(uuid,uuid,uuid,text,bigint)',"case when j.quality_profile='fal-kling3-4k-steady-v2't hen jsonb_build_object".replace('t hen','then'),"case when false then jsonb_build_object",'only authoritative v2 registered master projects frozen profile'),
  ('missing-paid-v2-eligibility','public.paid_quality_processing_budget(uuid)',"v->>'profile'in('fal-kling3-4k-v1','fal-kling3-4k-steady-v2')","v->>'profile'='fal-kling3-4k-v1'",'v2 recognizes same ordinary paid policy')]:
  original=run('read-'+label,[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%signature]);assert original.count(anchor)==1,(label,'source anchor')
  run('compile-'+label,[*PSQL,'-Atq'],original.replace(anchor,replacement,1))
  run('negative-'+label,[*PSQL,'-Atq'],fixture,refuses=oracle)
  run('restore-'+label,[*PSQL,'-Atq'],original)
  assert json.loads(run('restored-catalog-'+label,[*PSQL,'-Atq','-c',final_catalog_query]).strip())==final_boundary,'Restored control changed final catalog'
  r['controls'].append({'name':label,'compiledActualSQL':True,'unsafeMutationDetected':True})
 # Same real ordinaryStarter receipt fixture; no funding/grant on any host.
 paid="set role service_role;select apply_apple_entitlement_v2((select org from bf),(select actor from bf),'race-quality-original','race-quality-transaction','com.rendprop.app.starter.monthly','starter','Production','active',now()+interval'29 days',true,'DID_RENEW',now()-interval'1 day',now()-interval'30 seconds',now()-interval'30 seconds',now()-interval'30 seconds');reset role;"
 setup='begin;'+seed+paid+"update app_config set value=jsonb_set(value,'{enabled}','true')where key='property_video_jobs';update app_config set value='{\"enabled\":true,\"profile\":\"fal-kling3-4k-steady-v2\"}'where key='property_video_quality';create table public.steady_v2_race_fixture as select jsonb_set(jsonb_set(m,'{sources}',jsonb_build_array(m#>'{sources,0}',m#>'{sources,1}')),'{presentation,shot_labels}','[null,null]')m from bm;grant select on public.steady_v2_race_fixture to service_role;commit;"
 run('race-seed',[*PSQL,'-Atq'],setup)
 actor='f1100000-0000-4000-8000-000000000001'
 def recipe(i):return "jsonb_set((select m from steady_v2_race_fixture),'{operation_id}',to_jsonb('f4800000-0000-4000-8000-%012d'::text))"%i
 def admit(i):return"select property_video_job_admit('%s',%s,500,'fal-kling3-4k-steady-v2');"%(actor,recipe(i))
 outcomes=race('same-operation-profile',["set role service_role;"+admit(1)for _ in range(6)]);assert all(x['exit']==0 for x in outcomes),outcomes
 replies=[json.loads(next(l for l in x['output'].splitlines()if l.startswith('{')))for x in outcomes]
 assert len({x['job']['id']for x in replies})==1 and all(x['job']['quality_profile']=='fal-kling3-4k-steady-v2'for x in replies)
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
 assert run('saved-profile-after-cutover',[*PSQL,'-Atq','-c',"select quality_profile from property_video_jobs where operation_id='f4800000-0000-4000-8000-000000000003'"]).strip()=='fal-kling3-4k-steady-v2'
 r['races'].append({'name':'admission-before-cutover','actualConcurrentTransactions':2,'configFlipWaitedForAdmission':True,'savedProfileRetained':True})
 assert hashes()==r['sourceHashes'],'A snapshotted SQL input changed during proof';r['passed']=True
 print(json.dumps({'passed':True,'freshAssertions':r['fresh']['assertions'],'replayAssertions':r['replay']['assertions'],'compiledControls':len(r['controls']),'races':len(r['races']),'receipt':str(OUT/'receipt.json')}))
finally:
 if started:run('stop',[tool('pg_ctl'),'-D',DATA,'-m','immediate','-w','stop'])
 (OUT/'receipt.json').write_text(json.dumps(r,indent=2)+'\n');(OUT/'receipt.json').chmod(0o600)
 shutil.rmtree(DATA,ignore_errors=True)
 if SOCK.exists():shutil.rmtree(SOCK)
