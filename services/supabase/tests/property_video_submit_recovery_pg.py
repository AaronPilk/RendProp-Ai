#!/usr/bin/env python3
"""Actual isolated PG gallery authority, CAS, immutable replay and races.
No production connection, media download, provider call or copied credentials.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier
import argparse,hashlib,json,os,shutil,subprocess,tempfile,uuid
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);args=p.parse_args()
OUT=args.evidence_dir or Path(tempfile.mkdtemp(prefix='submit-recovery-proof-'));OUT.mkdir(parents=True,exist_ok=True)
assert shutil.disk_usage(ROOT).free>=3*1024**3,'Preserve internal3GiB reserve'
DATA=Path(tempfile.mkdtemp(prefix='submit-recovery-owned-pg-'));SOCK=Path(tempfile.mkdtemp(prefix='submit-recovery-socket-',dir='/tmp'))
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
tool=lambda n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)
MIG=SQL/'migrations/20261015165932_property_video_unaccepted_submit_recovery.sql';FIX=SQL/'tests/property_video_submit_recovery.sql'
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
 run('start',[tool('pg_ctl'),'-D',DATA,'-l',OUT/'postgres.log','-w','-o',f"-k {SOCK} -p 55584 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 conn=['-h',SOCK,'-p','55584','-U','postgres'];run('createdb',[tool('createdb'),*conn,'submit_recovery_proof'])
 PSQL=[tool('psql'),'-X','--no-password',*conn,'-d','submit_recovery_proof','-v','ON_ERROR_STOP=1']
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for m in MIGRATIONS:
  run('apply-'+m.stem,[*PSQL,'-q','-1','-f',m])
  if m==MIG:
   run('replay-at-own-boundary',[*PSQL,'-q','-1','-f',MIG]);receipt['ownBoundaryReplay']=True
 catalog="select jsonb_agg(jsonb_build_object('identity',oid::regprocedure::text,'body',prosrc,'owner',proowner,'acl',proacl::text,'config',proconfig,'security',prosecdef,'volatility',provolatile)order by oid)from pg_proc where pronamespace='public'::regnamespace;"
 for stage in ['fresh','replay']:
  if stage=='replay':
   before=run('current-authority-before-ancestor-replay',[*PSQL,'-Atq','-c',catalog])
   run('ancestor-replay-refused',[*PSQL,'-q','-1','-f',MIG],refuses='Review changed unaccepted-submit resume authority')
   assert run('current-authority-after-ancestor-replay',[*PSQL,'-Atq','-c',catalog])==before,'Ancestor replay must not replace current recovery'
   receipt['supersededReplayRefusedWithCurrentAuthorityIntact']=True
  out=run(stage+'-actual-submit-recovery',[*PSQL,'-Atq','-f',FIX]);rows=[json.loads(x)for x in out.splitlines()if x.startswith('{')and'assertions'in x];assert len(rows)==1 and rows[0]['passed'];receipt[stage]=rows[0]
 baseline=run('existing-jobs',[*PSQL,'-Atq','-f',SQL/'tests/property_video_jobs.sql']);receipt['existingJobRegression']=next(json.loads(x)for x in baseline.splitlines()if x.startswith('{')and'assertions'in x)
 for label,signature,anchor,replacement,oracle in [
  ('app-refusal-authority','public.property_video_submit_refusal(uuid,uuid)',"and released_at is not null and rejection_status=403 and rejection_error_class='upstream'\n  and provider_request_id is null and cost_ledger_id is null and settled_at is null",'','unreleased ambiguous reservation cannot recover'),
  ('one-recovery','public.property_video_submit_refusal(uuid,uuid)',"or exists(select 1 from jsonb_array_elements(s.non_dispatch_history)entry where entry->>'reason'='provider_submit_refused')",'','second vendor refusal has no automatic or second explicit generation grant'),
  ('serving-liability','public.property_video_submit_refusal(uuid,uuid)',"and state='rejected'",'','uncertain serving hold cannot recover'),
  ('source-authority','public.property_video_submit_refusal(uuid,uuid)',"if public.property_photo_reference(j.actor_id,j.listing_id,s.asset_id,s.photo_provenance_id)is distinct from s.source then return null;end if;",'','withdrawn original source cannot recover')]:
  original=run('read-'+label,[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%signature]);assert original.count(anchor)==1,(label,'exact production anchor')
  run('compile-'+label,[*PSQL,'-Atq'],original.replace(anchor,replacement,1));run('negative-'+label,[*PSQL,'-Atq','-f',FIX],refuses=oracle);run('restore-'+label,[*PSQL,'-Atq'],original)
  receipt['controls'].append({'name':label,'compiledActualSQL':True,'unsafeMutationRejected':True})
 fixture=FIX.read_text();setup=fixture[:fixture.index('create temporary table snapshot')].replace('set local ','set ')
 setup+="reset role;create table public.submit_recovery_race as select (j).id job,(select actor from bf)actor from submit_job;grant select on public.submit_recovery_race to service_role;commit;"
 run('race-setup',[*PSQL,'-Atq'],setup)
 statement="select (property_video_job_resume(actor,job,.0001)).state from public.submit_recovery_race;"
 results=race('same-owner-resume',[statement,statement]);assert all(x['exit']==0 and'generating'in x['output']for x in results),results
 count=run('resume-race-count',[*PSQL,'-Atq','-c',"select admission_retries||':'||jsonb_array_length(non_dispatch_history)from property_video_job_sources where job_id=(select job from public.submit_recovery_race)and position=2;"]).strip();assert count=='1:1',count
 receipt['races'].append({'name':'same-owner-resume','requests':2,'oneTransition':True,'supplierPOSTs':0})
 assert hashes()==receipt['sourceHashes'],'Source changed during proof';receipt['passed']=True
 print(json.dumps({'passed':True,'freshAssertions':receipt['fresh']['assertions'],'replayAssertions':receipt['replay']['assertions'],'controls':len(receipt['controls']),'races':len(receipt['races']),'receipt':str(OUT/'receipt.json')}))
finally:
 if started:run('stop',[tool('pg_ctl'),'-D',DATA,'-m','immediate','-w','stop'])
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
 if not started or not (DATA/'postmaster.pid').exists():shutil.rmtree(DATA)
 if SOCK.exists():shutil.rmtree(SOCK)
