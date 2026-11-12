#!/usr/bin/env python3
"""Actual isolated PG gallery authority, CAS, immutable replay and races.
No production connection, media download, provider call or copied credentials.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from fresh_schema_migrations import partition_fresh_migrations
from threading import Barrier
import argparse,hashlib,json,os,shutil,subprocess,tempfile,uuid
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);args=p.parse_args()
OUT=args.evidence_dir or Path(tempfile.mkdtemp(prefix='result-delivery-proof-'));OUT.mkdir(parents=True,exist_ok=True)
assert shutil.disk_usage(ROOT).free>=3*1024**3,'Preserve internal3GiB reserve'
DATA=Path(tempfile.mkdtemp(prefix='result-delivery-owned-pg-'));SOCK=Path(tempfile.mkdtemp(prefix='result-delivery-socket-',dir='/tmp'))
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
tool=lambda n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)
MIG=SQL/'migrations/20261015160252_property_video_retained_result_delivery_recovery.sql';FIX=SQL/'tests/property_video_result_delivery.sql'
MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'));SOURCES=[*MIGRATIONS,SQL/'tests/ci-bootstrap.sql',FIX,Path(__file__).resolve()]
hashes=lambda:{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest()for f in SOURCES}
receipt={'passed':False,'scope':'disposable actual PostgreSQL/schema/roles/concurrency, synthetic metadata only','networkCalls':0,'providerCalls':0,'sourceHashes':hashes(),'commands':[],'controls':[],'races':[]}
started=False
def run(name,cmd,body=None,refuses=None):
 r=subprocess.run([str(x)for x in cmd],input=body,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
 (OUT/(name+'.log')).write_text(r.stdout);receipt['commands'].append({'name':name,'exit':r.returncode,'logSHA256':hashlib.sha256(r.stdout.encode()).hexdigest()})
 assert(r.returncode and refuses in r.stdout)if refuses else r.returncode==0,(name,r.stdout[-6000:]);return r.stdout
def race(name,bodies):
 barrier=Barrier(len(bodies))
 def call(pair):
  i,body=pair;barrier.wait(timeout=10)
  r=subprocess.run([*PSQL,'-Atq'],input='set role service_role;'+body,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
  (OUT/f'{name}-{i}.log').write_text(r.stdout);return{'exit':r.returncode,'output':r.stdout}
 with ThreadPoolExecutor(max_workers=len(bodies))as pool:return list(pool.map(call,enumerate(bodies)))
try:
 run('initdb',[tool('initdb'),'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[tool('pg_ctl'),'-D',DATA,'-l',OUT/'postgres.log','-w','-o',f"-k {SOCK} -p 55583 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 conn=['-h',SOCK,'-p','55583','-U','postgres'];run('createdb',[tool('createdb'),*conn,'result_delivery_proof'])
 PSQL=[tool('psql'),'-X','--no-password',*conn,'-d','result_delivery_proof','-v','ON_ERROR_STOP=1']
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for m in partition_fresh_migrations(MIGRATIONS)[0]:
  run('apply-'+m.stem,[*PSQL,'-q','-1','-f',m])
  if m==MIG:
   run('replay-at-own-boundary',[*PSQL,'-q','-1','-f',MIG]);receipt['ownBoundaryReplay']=True
 catalog="select jsonb_agg(jsonb_build_object('identity',oid::regprocedure::text,'body',prosrc,'owner',proowner,'acl',proacl::text,'config',proconfig,'security',prosecdef,'volatility',provolatile)order by oid)from pg_proc where pronamespace='public'::regnamespace;"
 for stage in ['fresh','replay']:
  if stage=='replay':
   before=run('current-authority-before-ancestor-replay',[*PSQL,'-Atq','-c',catalog])
   run('ancestor-replay-refused',[*PSQL,'-q','-1','-f',MIG],refuses='Review changed delivery-aware resume authority')
   assert run('current-authority-after-ancestor-replay',[*PSQL,'-Atq','-c',catalog])==before,'Ancestor replay must not replace current recovery'
   receipt['supersededReplayRefusedWithCurrentAuthorityIntact']=True
  out=run(stage+'-actual-result-delivery',[*PSQL,'-Atq','-f',FIX]);rows=[json.loads(x)for x in out.splitlines()if x.startswith('{')and'assertions'in x];assert len(rows)==1 and rows[0]['passed'];receipt[stage]=rows[0]
 baseline=run('existing-jobs',[*PSQL,'-Atq','-f',SQL/'tests/property_video_jobs.sql']);receipt['existingJobRegression']=next(json.loads(x)for x in baseline.splitlines()if x.startswith('{')and'assertions'in x)
 for label,signature,anchor,replacement,oracle in [
  ('paid-receipt','public.property_video_delivery_receipt(uuid,uuid)','if r.id is null or paid.id is null or p.id is null then return null;end if;','','wrong provider request cannot recover'),
  ('source-authority','public.property_video_delivery_receipt(uuid,uuid)','if public.property_photo_reference(j.actor_id,j.listing_id,s.asset_id,s.photo_provenance_id)is distinct from s.source then return null;end if;','','deleted source cannot recover'),
  ('safe-error','public.property_video_delivery_resume_available(uuid)',"s.last_error in('provider_generation_failed','provider_result_unavailable')"," true ",'content safety refusal cannot recover'),
  ('lease','public.property_video_delivery_resume_available(uuid)','and(s.lease_until is null or s.lease_until<=now())','','active lease cannot be recovered')]:
  original=run('read-'+label,[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%signature]);assert original.count(anchor)==1,(label,'exact production anchor')
  run('compile-'+label,[*PSQL,'-Atq'],original.replace(anchor,replacement,1).replace("s.last_error not in('provider_generation_failed','provider_result_unavailable')",' false ') if label=='safe-error' else original.replace(anchor,replacement,1).replace('or s.lease_until>now()','') if label=='lease' else original.replace(anchor,replacement,1));run('negative-'+label,[*PSQL,'-Atq','-f',FIX],refuses=oracle);run('restore-'+label,[*PSQL,'-Atq'],original)
  receipt['controls'].append({'name':label,'compiledActualSQL':True,'unsafeMutationRejected':True})
 fixture=FIX.read_text();setup=fixture[:fixture.index('reset role;\ncreate temporary table snapshot')].replace('set local ','set ')
 setup+="reset role;create table public.result_delivery_race as select (j).id job,(select actor from bf)actor from delivery_job;grant select on public.result_delivery_race to service_role;commit;"
 run('race-setup',[*PSQL,'-Atq'],setup)
 statement="select (property_video_job_resume(actor,job,0)).state from public.result_delivery_race;"
 results=race('same-owner-resume',[statement,statement]);assert all(x['exit']==0 and'generating'in x['output']for x in results),results
 count=run('resume-race-count',[*PSQL,'-Atq','-c',"select delivery_recoveries||':'||jsonb_array_length(delivery_recovery_history)from property_video_job_sources where job_id=(select job from public.result_delivery_race)and position=2;"]).strip();assert count=='1:1',count
 receipt['races'].append({'name':'same-owner-resume','requests':2,'oneTransition':True,'samePaidReceipt':True,'supplierPOSTs':0})
 # Obtain the actual current poll lease once, then contend the identical callback.
 poll_setup="set role service_role;create table public.result_delivery_poll as select pg_temp.target_poll(job,2)c from public.result_delivery_race;grant select on public.result_delivery_poll to service_role;"
 # pg_temp helper belongs to the fixture session, recreate its exact definition.
 helper=fixture[fixture.index('create function pg_temp.target_poll'):fixture.index('-- BEGIN DELIVERY FIXTURE')]
 run('poll-race-setup',[*PSQL,'-Atq'],helper+poll_setup)
 statement="select property_video_job_result_read_failure((c#>>'{job,id}')::uuid,(c#>>'{source,lease_token}')::uuid,(c#>>'{source,attempt_id}')::uuid,'unknown')from public.result_delivery_poll;"
 results=race('same-read-callback',[statement,statement]);assert all(x['exit']==0 for x in results),results
 count=run('read-race-count',[*PSQL,'-Atq','-c',"select result_read_failures from property_video_job_sources where job_id=(select job from public.result_delivery_race)and position=2;"]).strip();assert count=='1',count
 receipt['races'].append({'name':'same-read-callback','requests':2,'oneCounter':True,'supplierPOSTs':0})
 assert hashes()==receipt['sourceHashes'],'Source changed during proof';receipt['passed']=True
 print(json.dumps({'passed':True,'freshAssertions':receipt['fresh']['assertions'],'replayAssertions':receipt['replay']['assertions'],'controls':len(receipt['controls']),'races':len(receipt['races']),'receipt':str(OUT/'receipt.json')}))
finally:
 if started:run('stop',[tool('pg_ctl'),'-D',DATA,'-m','immediate','-w','stop'])
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
 if not started or not (DATA/'postmaster.pid').exists():shutil.rmtree(DATA)
 if SOCK.exists():shutil.rmtree(SOCK)
