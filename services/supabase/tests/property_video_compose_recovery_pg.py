#!/usr/bin/env python3
"""Actual isolated PG assembly-only recovery, immutable paid inputs and races.
No production connection, media download, provider call or copied credentials.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier
import argparse,hashlib,json,os,shutil,subprocess,tempfile,uuid
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);args=p.parse_args()
OUT=args.evidence_dir or Path(tempfile.mkdtemp(prefix='compose-recovery-proof-'));OUT.mkdir(parents=True,exist_ok=True)
assert shutil.disk_usage(ROOT).free>=3*1024**3,'Preserve internal3GiB reserve'
DATA=Path(tempfile.mkdtemp(prefix='compose-recovery-owned-pg-',dir='/Volumes/Rendprop Files/Builds/Active' if Path('/Volumes/Rendprop Files/Builds/Active').is_dir()else None));SOCK=Path(tempfile.mkdtemp(prefix='compose-recovery-socket-',dir='/tmp'))
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
tool=lambda n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)
MIG=SQL/'migrations/20261015182509_property_video_preoutput_compose_recovery.sql';FIX=SQL/'tests/property_video_compose_recovery.sql'
MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'));SOURCES=[*MIGRATIONS,SQL/'tests/ci-bootstrap.sql',FIX,SQL/'tests/property_video_missing_result.sql',Path(__file__).resolve()]
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
 run('start',[tool('pg_ctl'),'-D',DATA,'-l',OUT/'postgres.log','-w','-o',f"-k {SOCK} -p 55587 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 conn=['-h',SOCK,'-p','55587','-U','postgres'];run('createdb',[tool('createdb'),*conn,'compose_recovery_proof'])
 PSQL=[tool('psql'),'-X','--no-password',*conn,'-d','compose_recovery_proof','-v','ON_ERROR_STOP=1']
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for m in MIGRATIONS:run('apply-'+m.stem,[*PSQL,'-q','-1','-f',m])
 for stage in ['fresh','replay']:
  if stage=='replay':run('replay-own-migration',[*PSQL,'-q','-1','-f',MIG])
  out=run(stage+'-actual-compose-recovery',[*PSQL,'-Atq','-f',FIX]);rows=[json.loads(x)for x in out.splitlines()if x.startswith('{')and'assertions'in x];assert len(rows)==1 and rows[0]['passed'];receipt[stage]=rows[0]
 baseline=run('existing-missing-result-recovery',[*PSQL,'-Atq','-f',SQL/'tests/property_video_missing_result.sql']);receipt['existingRecoveryRegression']=next(json.loads(x)for x in baseline.splitlines()if x.startswith('{')and'assertions'in x)
 for label,signature,anchor,replacement,oracle in [
  ('paid-identity','public.property_video_compose_snapshot(uuid)',"and meta->>'request_id'=r.provider_request_id",'', 'paid ledger request identity required'),
  ('no-uncertain-output','public.property_video_compose_snapshot(uuid)',"or exists(select 1 from public.capture_assets where id in(j.output_asset_id,j.poster_asset_id))",'', 'any reserved output asset blocks uncertain overwrite'),
  ('source-authority','public.property_video_compose_snapshot(uuid)',"or public.property_photo_reference(j.actor_id,j.listing_id,s.asset_id,s.photo_provenance_id)is distinct from s.source",'', 'withdrawn source cannot resume'),
  ('preserve-output-identity','public.property_video_job_claim(uuid,text)',"output_asset_id=case when j.compose_recoveries=1 then j.output_asset_id else gen_random_uuid()end,poster_asset_id=case when j.compose_recoveries=1 then j.poster_asset_id else gen_random_uuid()end",'output_asset_id=gen_random_uuid(),poster_asset_id=gen_random_uuid()', 'recovered claim reuses exact reserved identities and only composes')]:
  original=run('read-'+label,[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%signature]);assert original.count(anchor)==1,(label,'exact production anchor')
  run('compile-'+label,[*PSQL,'-Atq'],original.replace(anchor,replacement,1));run('negative-'+label,[*PSQL,'-Atq','-f',FIX],refuses=oracle);run('restore-'+label,[*PSQL,'-Atq'],original)
  receipt['controls'].append({'name':label,'compiledActualSQL':True,'unsafeMutationRejected':True})
 fixture=FIX.read_text();setup=fixture[:fixture.index('reset role;\ncreate temporary table snapshot')].replace('set local ','set ')
 setup+="reset role;create table public.compose_recovery_race as select id job,(select actor from bf)actor from cj;grant select on public.compose_recovery_race to service_role;commit;"
 run('race-setup',[*PSQL,'-Atq'],setup)
 statement="select (property_video_job_resume(actor,job,0)).state from public.compose_recovery_race;"
 results=race('same-owner-resume',[statement,statement]);assert all(x['exit']==0 and'generating'in x['output']for x in results),results
 count=run('resume-race-count',[*PSQL,'-Atq','-c',"select compose_recoveries||':'||jsonb_array_length(compose_recovery_history)from property_video_jobs where id=(select job from public.compose_recovery_race);"]).strip();assert count=='1:1',count
 receipt['races'].append({'name':'same-owner-resume','requests':2,'oneTransition':True,'supplierPOSTs':0})
 results=race('two-slot-claim',["select property_video_job_claim(job,'slot-0')->>'action'from public.compose_recovery_race;","select property_video_job_claim(job,'slot-1')->>'action'from public.compose_recovery_race;"]);assert all(x['exit']==0 for x in results)and sorted(x['output'].strip()for x in results)==['compose','wait'],results
 receipt['races'].append({'name':'two-slot-claim','oneComposeOneWait':True})
 out=run('late-uncertain-output',[*PSQL,'-Atq'],"begin;set local session_replication_role=replica;insert into capture_assets(id,listing_id,kind,bucket,storage_key,bytes,sha256,uploaded)select output_asset_id,listing_id,'video','renders','synthetic/late-uncertain.mp4',1,repeat('b',64),false from property_video_jobs where id=(select job from public.compose_recovery_race);set local session_replication_role=origin;update property_video_jobs set compose_until=now()where id=(select job from public.compose_recovery_race);set role service_role;select property_video_job_claim(job,'slot-0')#>>'{job,state}'from public.compose_recovery_race;commit;")
 assert 'needs_reconciliation'in out,out;receipt['lateOutputAdmission']={'stoppedBeforeCPU':True,'reportedCurrentState':True}

 # New fresh target: canonical listing erasure, without disabling any trigger.
 # A real source-row lock orders the final current-authority check after erasure.
 race_setup=setup.replace('9001','9002').replace('f1100000','f2100000').replace('f1300000','f2300000').replace('bg-photo:','bg-photo-2:').replace('@fixture.invalid','-2@fixture.invalid').replace('compose_recovery_race','compose_withdrawal_race')
 run('withdrawal-setup',[*PSQL,'-Atq'],race_setup)
 proc=subprocess.Popen([*PSQL,'-Atq'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,env=ENV,cwd=ROOT)
 proc.stdin.write("begin;select id from capture_assets where id=(select asset_id from property_video_job_sources where job_id=(select job from public.compose_withdrawal_race)and position=0)for update;update listings set deleted_at=now()where id=(select listing_id from property_video_jobs where id=(select job from public.compose_withdrawal_race));select 'LOCKED';select pg_sleep(1.5);commit;\n");proc.stdin.close();held=proc.stdout.readline().strip();assert held,held;first=proc.stdout.readline().strip();assert first=='LOCKED',first
 denied=run('withdrawal-resume',[*PSQL,'-Atq'],"set role service_role;select (property_video_job_resume(actor,job,0)).state from public.compose_withdrawal_race;",refuses='RP404');remaining=proc.stdout.read();assert proc.wait(timeout=10)==0,remaining
 state=run('withdrawal-count',[*PSQL,'-Atq','-c',"select state||':'||compose_recoveries from property_video_jobs where id=(select job from public.compose_withdrawal_race);"]).strip();assert state=='failed:0',state
 receipt['races'].append({'name':'canonical-listing-erasure-while-resume-waits','recoveryRolledBack':True,'privilegedSyntheticSourceMutation':False})
 # An output caller passes initial scope before waiting; a newer lease must
 # be rechecked after that wait, before even reserving storage.
 race_setup=setup.replace('9001','9003').replace('f1100000','f3100000').replace('f1300000','f3300000').replace('bg-photo:','bg-photo-3:').replace('@fixture.invalid','-3@fixture.invalid').replace('compose_recovery_race','compose_output_race')
 run('output-race-setup',[*PSQL,'-Atq'],race_setup)
 run('output-race-active',[*PSQL,'-Atq'],"set role service_role;update property_video_jobs set state='composing',compose_until=now()+interval'10 minutes'where id=(select job from public.compose_output_race);")
 lease=run('old-output-lease',[*PSQL,'-Atq','-c',"select compose_lease from property_video_jobs where id=(select job from public.compose_output_race);"]).strip()
 proc=subprocess.Popen([*PSQL,'-Atq'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,env=ENV,cwd=ROOT)
 proc.stdin.write("begin;set role service_role;select 1 from property_video_jobs where id=(select job from public.compose_output_race)for update;select 'LOCKED';select pg_sleep(1.5);select property_video_job_failure(job,'"+lease+"',null,'cpu_attempt_failed',false)from public.compose_output_race;select(property_video_job_resume(actor,job,0)).state from public.compose_output_race;select property_video_job_claim(job,'slot-0')->>'action'from public.compose_output_race;commit;\n");proc.stdin.close();assert proc.stdout.readline().strip()=='1';first=proc.stdout.readline().strip();assert first=='LOCKED',first
 denied=run('stale-output-after-wait',[*PSQL,'-Atq'],"set role service_role;select property_video_job_outputs_reserve(job,'"+lease+"',100,repeat('b',64),100,repeat('c',64))from public.compose_output_race;",refuses='RP409');remaining=proc.stdout.read();assert proc.wait(timeout=10)==0,remaining
 count=run('output-race-count',[*PSQL,'-Atq','-c',"select count(*)from property_video_job_outputs where job_id=(select job from public.compose_output_race);"]).strip();assert count=='0',count
 receipt['races'].append({'name':'stale-output-lease-after-job-lock','storageAdmissions':0})
 assert hashes()==receipt['sourceHashes'],'Source changed during proof';receipt['passed']=True
 print(json.dumps({'passed':True,'freshAssertions':receipt['fresh']['assertions'],'replayAssertions':receipt['replay']['assertions'],'controls':len(receipt['controls']),'races':len(receipt['races']),'receipt':str(OUT/'receipt.json')}))
finally:
 if started:run('stop',[tool('pg_ctl'),'-D',DATA,'-m','immediate','-w','stop'])
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
 if not started or not (DATA/'postmaster.pid').exists():shutil.rmtree(DATA)
 if SOCK.exists():shutil.rmtree(SOCK)
