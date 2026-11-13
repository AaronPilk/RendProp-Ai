#!/usr/bin/env python3
"""Actual isolated PG strict-axis paid retry, stopped-job recovery and races.
No production connection, media download, provider call or copied credentials.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from fresh_schema_migrations import partition_fresh_migrations
from threading import Barrier
import argparse,hashlib,json,os,shutil,subprocess,tempfile,uuid
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);args=p.parse_args()
OUT=args.evidence_dir or Path(tempfile.mkdtemp(prefix='derived-retry-proof-'));OUT.mkdir(parents=True,exist_ok=True)
assert shutil.disk_usage(ROOT).free>=3*1024**3,'Preserve internal3GiB reserve'
DATA=Path(tempfile.mkdtemp(prefix='derived-retry-owned-pg-'));SOCK=Path(tempfile.mkdtemp(prefix='derived-retry-socket-',dir='/tmp'))
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
tool=lambda n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)
MIG=SQL/'migrations/20261015151716_property_video_derived_quality_retry.sql';FIX=SQL/'tests/property_video_derived_retry.sql'
MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'));SOURCES=[*MIGRATIONS,SQL/'tests/ci-bootstrap.sql',SQL/'tests/property_video_jobs.sql',FIX,Path(__file__).resolve()]
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
 conn=['-h',SOCK,'-p','55583','-U','postgres'];run('createdb',[tool('createdb'),*conn,'derived_retry_proof'])
 PSQL=[tool('psql'),'-X','--no-password',*conn,'-d','derived_retry_proof','-v','ON_ERROR_STOP=1']
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for m in partition_fresh_migrations(MIGRATIONS)[0]:
  run('apply-'+m.stem,[*PSQL,'-q','-1','-f',m])
  # Prove this migration's idempotency at its own schema boundary. Later
  # guarded Resume wrappers must never be replaced by replaying this ancestor.
  if m==MIG:
   run('replay-at-own-boundary',[*PSQL,'-q','-1','-f',MIG]);receipt['ownBoundaryReplay']=True
 catalog="select jsonb_agg(jsonb_build_object('identity',oid::regprocedure::text,'body',prosrc,'owner',proowner,'acl',proacl::text,'config',proconfig,'security',prosecdef,'volatility',provolatile)order by oid)from pg_proc where pronamespace='public'::regnamespace;"
 for stage in ['fresh','replay']:
  if stage=='replay':
   before=run('current-authority-before-ancestor-replay',[*PSQL,'-Atq','-c',catalog])
   run('ancestor-replay-refused',[*PSQL,'-q','-1','-f',MIG],refuses='Review changed retained paid retry recovery authority')
   assert run('current-authority-after-ancestor-replay',[*PSQL,'-Atq','-c',catalog])==before,'Ancestor replay must roll back every public function change'
   receipt['supersededReplayRefusedWithCurrentAuthorityIntact']=True
  out=run(stage+'-actual-derived-retry',[*PSQL,'-Atq','-f',FIX]);rows=[json.loads(x)for x in out.splitlines()if x.startswith('{')and'assertions'in x];assert len(rows)==1 and rows[0]['passed'];receipt[stage]=rows[0]
 baseline=run('existing-job-rpc-regression',[*PSQL,'-Atq','-f',SQL/'tests/property_video_jobs.sql']);receipt['existingJobRegression']=next(json.loads(x)for x in baseline.splitlines()if x.startswith('{')and'assertions'in x)
 for label,signature,anchor,replacement,oracle in [
  ('raw-pass-deadlock','public.property_video_quality_retry_evidence(uuid,uuid)',"not in('pass','fail','regen')","not in('fail','regen')",'strict failed axes authorize raw-pass terminal retry'),
  ('terminal-journal','public.property_video_quality_retry_evidence(uuid,uuid)','if c.reservation_id is null then return null;end if;','', 'nonterminal journal cannot authorize retry'),
  ('canonical-status','public.property_video_quality_retry_evidence(uuid,uuid)',"result#>>'{drift,status}'='fail'and ",'','journal status pass cannot authorize retry'),
  ('paid-generation','public.property_video_quality_retry_evidence(uuid,uuid)','if r.id is null or paid.id is null then return null;end if;','', 'missing paid generation charge cannot authorize retry'),
  ('paid-qc-scores','public.property_video_quality_retry_evidence(uuid,uuid)',"and(p.qc->>'verdict'<>'pass'or meta->'scores'=p.qc->'scores')",'', 'paid QC score mismatch cannot authorize retry')]:
  original=run('read-'+label,[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%signature]);assert original.count(anchor)==1,(label,'exact production anchor')
  run('compile-'+label,[*PSQL,'-Atq'],original.replace(anchor,replacement,1));run('negative-'+label,[*PSQL,'-Atq','-f',FIX],refuses=oracle);run('restore-'+label,[*PSQL,'-Atq'],original)
  receipt['controls'].append({'name':label,'compiledActualSQL':True,'unsafeMutationRejected':True})
 run('owner-race-template',[tool('createdb'),*conn,'-T','derived_retry_proof','derived_retry_owner_proof'])
 # Commit only synthetic setup for separate concurrent service-role sessions.
 fixture=FIX.read_text();setup=fixture[:fixture.index('reset role;\ncreate function pg_temp.evidence')];setup=setup.replace('set local ','set ')
 setup+="reset role;create table public.derived_retry_race as select c from retry_case;grant select on public.derived_retry_race to service_role;commit;"
 run('race-setup', [*PSQL,'-Atq'],setup)
 statement="select property_video_job_quality_retry((c#>>'{job,id}')::uuid,(c#>>'{source,lease_token}')::uuid,(c#>>'{source,attempt_id}')::uuid)from public.derived_retry_race;"
 results=race('one-paid-grant-two-workers',[statement,statement]);assert all(x['exit']==0 for x in results),results
 replies=[json.loads(next(x for x in r['output'].splitlines()if x.startswith('{')))for r in results];assert sorted(r['replay']for r in replies)==[False,True]and all(r['retry_scheduled']for r in replies),replies
 out=run('race-retention',[*PSQL,'-Atq','-c',"select jsonb_build_object('count',quality_retries,'history',jsonb_array_length(quality_retry_history),'state',state,'raw_summary',quality_retry_history#>>'{0,quality_grant,verdict,verdict}','attempt',attempt_id,'receipt',receipt)from public.property_video_job_sources where job_id=(select(c#>>'{job,id}')::uuid from public.derived_retry_race)and position=0;"]);v=json.loads(out.strip());assert v=={'count':1,'history':1,'state':'pending','raw_summary':'pass','attempt':None,'receipt':None},v
 receipt['races'].append({'name':'one-paid-grant-two-workers','requests':2,'oneTransition':True,'oneReplay':True,'exactOldPaidReceiptRetained':True,'providerCalls':0})
 # Race two ordinary owner actions over the exact stopped two-source set.
 fixture=FIX.read_text();setup=fixture[:fixture.index('-- MULTI RECOVERY READY')].replace('set local ','set ')
 setup+="reset role;create table public.derived_retry_owner_race as select (c#>>'{job,id}')::uuid job,(select actor from bf)actor from multi0;grant select on public.derived_retry_owner_race to service_role;commit;"
 # The first committed fixture used the same deterministic IDs; isolate this
 # second race in its own database, without altering its production authority.
 PSQL=[tool('psql'),'-X','--no-password',*conn,'-d','derived_retry_owner_proof','-v','ON_ERROR_STOP=1']
 run('owner-race-setup',[*PSQL,'-Atq'],setup)
 statement="select (public.property_video_job_resume(actor,job,0)).state from public.derived_retry_owner_race;"
 results=race('two-owner-resumes',[statement,statement]);assert all(x['exit']==0 and'generating'in x['output']for x in results),results
 out=run('owner-race-retention',[*PSQL,'-Atq','-c',"select jsonb_build_object('sources',count(*),'single',bool_and(quality_retries=1 and jsonb_array_length(quality_retry_history)=1),'pending',bool_and(state='pending'))from property_video_job_sources where job_id=(select job from public.derived_retry_owner_race);"]);v=json.loads(out.strip());assert v=={'sources':2,'single':True,'pending':True},v
 receipt['races'].append({'name':'two-owner-resumes','requests':2,'bothAcknowledged':True,'oneTransitionPerSource':True,'sources':2,'providerCalls':0})
 assert hashes()==receipt['sourceHashes'],'Source changed during proof';receipt['passed']=True
 print(json.dumps({'passed':True,'freshAssertions':receipt['fresh']['assertions'],'replayAssertions':receipt['replay']['assertions'],'controls':len(receipt['controls']),'races':len(receipt['races']),'receipt':str(OUT/'receipt.json')}))
finally:
 if started:run('stop',[tool('pg_ctl'),'-D',DATA,'-m','immediate','-w','stop'])
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
 if not started or receipt['passed']:shutil.rmtree(DATA)
 if SOCK.exists():shutil.rmtree(SOCK)
