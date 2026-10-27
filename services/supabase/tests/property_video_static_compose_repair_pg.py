#!/usr/bin/env python3
"""Source-only external candidate, actual local PostgreSQL and synthetic metadata.
Consumes all current repository migrations; no live/network/provider calls.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from fresh_schema_migrations import partition_fresh_migrations
from threading import Barrier
import argparse,hashlib,json,os,shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path,required=True);a=p.parse_args();OUT=a.evidence_dir;OUT.mkdir(parents=True,exist_ok=True)
assert shutil.disk_usage(ROOT).free>=3*1024**3,'Preserve internal3GiB reserve'
DATA=Path(tempfile.mkdtemp(prefix='static-repair-pg-',dir='/Volumes/Rendprop Files/Builds/Active'if Path('/Volumes/Rendprop Files/Builds/Active').is_dir()else None));SOCK=Path(tempfile.mkdtemp(prefix='static-repair-socket-',dir='/tmp'))
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
tool=lambda n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)
CANDIDATE=SQL/'migrations/20261015193930_property_video_static_saved_photo_compose_repair.sql';FIX=SQL/'tests/property_video_static_compose_repair.sql';MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'))
SOURCES=[*MIGRATIONS,CANDIDATE,FIX,SQL/'tests/ci-bootstrap.sql',SQL/'tests/property_video_compose_recovery.sql',Path(__file__).resolve()]
hashes=lambda:{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest()for f in SOURCES}
receipt={'passed':False,'scope':'actual disposable PostgreSQL/roles/concurrency, current full migration chain, synthetic metadata only','networkCalls':0,'providerCalls':0,'sourceHashes':hashes(),'commands':[],'controls':[],'races':[]}
started=False
def run(name,cmd,body=None,refuses=None):
 r=subprocess.run([str(x)for x in cmd],input=body,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
 p=OUT/(name+'.log');p.write_text(r.stdout);p.chmod(0o600);receipt['commands'].append({'name':name,'exit':r.returncode,'logSHA256':hashlib.sha256(r.stdout.encode()).hexdigest()})
 assert(r.returncode and refuses in r.stdout)if refuses else r.returncode==0,(name,r.stdout[-6500:]);return r.stdout
def race(name,bodies):
 barrier=Barrier(len(bodies))
 def call(pair):
  i,body=pair;barrier.wait(timeout=10)
  r=subprocess.run([*PSQL,'-Atq'],input='set role service_role;'+body,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
  p=OUT/f'{name}-{i}.log';p.write_text(r.stdout);p.chmod(0o600);return{'exit':r.returncode,'output':r.stdout}
 with ThreadPoolExecutor(max_workers=len(bodies))as pool:return list(pool.map(call,enumerate(bodies)))
try:
 run('initdb',[tool('initdb'),'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[tool('pg_ctl'),'-D',DATA,'-l',OUT/'postgres.log','-w','-o',f"-k {SOCK} -p 55589 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 conn=['-h',SOCK,'-p','55589','-U','postgres'];run('createdb',[tool('createdb'),*conn,'static_repair_proof'])
 PSQL=[tool('psql'),'-X','--no-password',*conn,'-d','static_repair_proof','-v','ON_ERROR_STOP=1']
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for m in partition_fresh_migrations(MIGRATIONS)[0]:run('apply-'+m.stem,[*PSQL,'-q','-1','-f',m])
 receipt['functionMD5s']=json.loads(run('function-hashes',[*PSQL,'-Atq','-c',"select json_object_agg(p.oid::regprocedure::text,md5(p.prosrc))from pg_proc p where p.oid in('public.property_video_compose_history_guard()'::regprocedure,'public.property_video_job_claim(uuid,text)'::regprocedure,'public.property_video_job_resume(uuid,uuid,numeric)'::regprocedure)"]))
 for stage in ['fresh','replay']:
  if stage=='replay':run('replay-external-candidate',[*PSQL,'-q','-f',CANDIDATE])
  out=run(stage+'-actual-static-repair',[*PSQL,'-Atq','-f',FIX]);rows=[json.loads(x)for x in out.splitlines()if x.startswith('{')and'assertions'in x];assert len(rows)==1 and rows[0]['passed'];receipt[stage]=rows[0]
 out=run('existing-ordinary-compose-recovery',[*PSQL,'-Atq','-f',SQL/'tests/property_video_compose_recovery.sql']);receipt['ordinaryRecoveryRegression']=next(json.loads(x)for x in out.splitlines()if x.startswith('{')and'assertions'in x)
 for label,signature,anchor,replacement,oracle in [
  ('release-required','public.property_video_static_repair_available(uuid)',"or public.property_video_static_repair_release()is null",'', 'repair defaults OFF before verified image'),
  ('prefix-identity','public.property_video_static_repair_available(uuid)',"and v=(j.compose_recovery_history->0)-array['prior_compose_lease','prior_compose_attempts','recovered_at']",'', 'prior recovery source snapshot must match'),
  ('paid-identity','public.property_video_compose_snapshot(uuid)',"and meta->>'request_id'=r.provider_request_id",'', 'paid ledger request identity required'),
  ('source-authority','public.property_video_compose_snapshot(uuid)',"or public.property_photo_reference(j.actor_id,j.listing_id,s.asset_id,s.photo_provenance_id)is distinct from s.source",'', 'withdrawn source cannot repair'),
  ('output-identity','public.property_video_job_claim(uuid,text)',"output_asset_id=case when j.compose_recoveries>=1 then j.output_asset_id else gen_random_uuid()end,poster_asset_id=case when j.compose_recoveries>=1 then j.poster_asset_id else gen_random_uuid()end",'output_asset_id=case when j.compose_recoveries=1 then j.output_asset_id else gen_random_uuid()end,poster_asset_id=case when j.compose_recoveries=1 then j.poster_asset_id else gen_random_uuid()end', 'repair claim preserves exact reserved output identities')]:
  original=run('read-'+label,[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%signature]);assert original.count(anchor)==1,(label,'exact production anchor')
  run('compile-'+label,[*PSQL,'-Atq'],original.replace(anchor,replacement,1));run('negative-'+label,[*PSQL,'-Atq','-f',FIX],refuses=oracle);run('restore-'+label,[*PSQL,'-Atq'],original)
  receipt['controls'].append({'name':label,'compiledActualSQL':True,'unsafeMutationRejected':True})
 fixture=FIX.read_text();setup=fixture[:fixture.index('reset role;\ncreate temporary table snapshot')].replace('set local ','set ')
 setup+="reset role;update app_config set value=value||jsonb_build_object('enabled',true,'renderer_image_sha256',repeat('9',64))where key='property_video_static_fallback_repair';create table public.static_repair_race as select id job,(select actor from bf)actor from cj;grant select on public.static_repair_race to service_role;commit;"
 run('race-setup',[*PSQL,'-Atq'],setup)
 statement="select(property_video_job_repair_static_compose(actor,job,'fe000000-0000-4000-8000-000000000001')).state from public.static_repair_race;"
 results=race('same-operation-repair',[statement,statement]);assert all(x['exit']==0 and'generating'in x['output']for x in results),results
 count=run('repair-race-count',[*PSQL,'-Atq','-c',"select compose_recoveries||':'||jsonb_array_length(compose_recovery_history)from property_video_jobs where id=(select job from public.static_repair_race);"]).strip();assert count=='2:2',count
 receipt['races'].append({'name':'same-operation-repair','requests':2,'oneTransition':True,'supplierPOSTs':0})
 results=race('two-slot-claim',["select property_video_job_claim(job,'slot-0')->>'action'from public.static_repair_race;","select property_video_job_claim(job,'slot-1')->>'action'from public.static_repair_race;"]);assert all(x['exit']==0 for x in results)and sorted(x['output'].strip()for x in results)==['compose','wait'],results
 receipt['races'].append({'name':'two-slot-claim','oneComposeOneWait':True})
 out=run('late-uncertain-output',[*PSQL,'-Atq'],"begin;set local session_replication_role=replica;insert into capture_assets(id,listing_id,kind,bucket,storage_key,bytes,sha256,uploaded)select output_asset_id,listing_id,'video','renders','synthetic/late-uncertain.mp4',1,repeat('b',64),false from property_video_jobs where id=(select job from public.static_repair_race);set local session_replication_role=origin;update property_video_jobs set compose_until=now()where id=(select job from public.static_repair_race);set role service_role;select property_video_job_claim(job,'slot-0')#>>'{job,state}'from public.static_repair_race;commit;")
 assert'needs_reconciliation'in out,out;receipt['uncertainOutput']={'stoppedBeforeCPU':True,'syntheticPrivilegedFixtureInsertion':True}
 # A canonical listing deletion commits while the repair waits for source locks.
 withdrawal=setup.replace('9001','9002').replace('f1100000','f2100000').replace('f1300000','f2300000').replace('bg-photo:','bg-photo-2:').replace('@fixture.invalid','-2@fixture.invalid').replace('static_repair_race','static_withdrawal_race')
 run('withdrawal-setup',[*PSQL,'-Atq'],withdrawal)
 proc=subprocess.Popen([*PSQL,'-Atq'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,env=ENV,cwd=ROOT)
 proc.stdin.write("begin;select id from capture_assets where id=(select asset_id from property_video_job_sources where job_id=(select job from public.static_withdrawal_race)and position=0)for update;update listings set deleted_at=now()where id=(select listing_id from property_video_jobs where id=(select job from public.static_withdrawal_race));select 'LOCKED';select pg_sleep(1.5);commit;\n");proc.stdin.close();assert proc.stdout.readline().strip();assert proc.stdout.readline().strip()=='LOCKED'
 run('withdrawal-repair',[*PSQL,'-Atq'],"set role service_role;select(property_video_job_repair_static_compose(actor,job,'fe000000-0000-4000-8000-000000000002')).state from public.static_withdrawal_race;",refuses='RP404');remaining=proc.stdout.read();assert proc.wait(timeout=10)==0,remaining
 state=run('withdrawal-count',[*PSQL,'-Atq','-c',"select state||':'||compose_recoveries from property_video_jobs where id=(select job from public.static_withdrawal_race);"]).strip();assert state=='failed:1',state
 receipt['races'].append({'name':'canonical-listing-erasure-while-repair-waits','repairRolledBack':True,'privilegedSyntheticSourceMutation':False})
 receipt['functionMD5s']=json.loads(run('function-hashes',[*PSQL,'-Atq','-c',"select json_object_agg(p.oid::regprocedure::text,md5(p.prosrc))from pg_proc p where p.oid in('public.property_video_compose_history_guard()'::regprocedure,'public.property_video_job_claim(uuid,text)'::regprocedure,'public.property_video_job_resume(uuid,uuid,numeric)'::regprocedure)"]))
 assert hashes()==receipt['sourceHashes'],'Consumed snapshot/candidate source changed during proof';receipt['passed']=True
 print(json.dumps({'passed':True,'fresh':receipt['fresh']['assertions'],'replay':receipt['replay']['assertions'],'ordinary':receipt['ordinaryRecoveryRegression']['assertions'],'controls':len(receipt['controls']),'races':len(receipt['races']),'receipt':str(OUT/'receipt.json')}))
finally:
 if started:run('stop',[tool('pg_ctl'),'-D',DATA,'-m','immediate','-w','stop'])
 p=OUT/'receipt.json';p.write_text(json.dumps(receipt,indent=2)+'\n');p.chmod(0o600)
 if not started or not(DATA/'postmaster.pid').exists():shutil.rmtree(DATA)
 if SOCK.exists():shutil.rmtree(SOCK)
