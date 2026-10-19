#!/usr/bin/env python3
"""Owned local PostgreSQL proof of quarantined photo evidence authority.
No hosted databases, providers, Apple calls or inherited credentials.
"""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
import argparse,hashlib,json,os,shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
a=argparse.ArgumentParser();a.add_argument('--evidence-dir',type=Path);args=a.parse_args()
OUT=args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-photo-quality-proof-'));OUT.mkdir(parents=True,exist_ok=True)
DATA=Path(tempfile.mkdtemp(prefix='rendprop-photo-quality-owned-pg-'));SOCK=Path(tempfile.mkdtemp(prefix='rendprop-photo-quality-socket-'))
TOOLS={n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)for n in('initdb','pg_ctl','psql','createdb')}
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
MIG=SQL/'migrations/20261015031824_prospective_photo_quality_evidence.sql';FIX=SQL/'tests/photo_quality_evidence.sql'
SOURCES=[*sorted((SQL/'migrations').glob('*.sql')),SQL/'tests/ci-bootstrap.sql',FIX,Path(__file__).resolve()]
hashes=lambda:{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in SOURCES if p.exists()}
r={'passed':False,'networkCalls':0,'providerCalls':0,'sourceHashes':hashes(),'commands':[],'controls':[]};started=False

def run(name,cmd,sql=None,refuses=None):
 p=subprocess.run([str(x)for x in cmd],input=sql,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
 log=OUT/(name+'.log');log.write_text(p.stdout);log.chmod(0o600);r['commands'].append({'name':name,'exit':p.returncode,'sha256':hashlib.sha256(log.read_bytes()).hexdigest()})
 if refuses:assert p.returncode and refuses in p.stdout,(name,p.stdout[-3000:])
 else:assert not p.returncode,(name,p.stdout[-3000:])
 return p.stdout
try:
 run('initdb',[TOOLS['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[TOOLS['pg_ctl'],'-D',DATA,'-l',OUT/'postgres.log','-w','-t','30','-o',f"-k {SOCK} -p 55549 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 conn=['-h',SOCK,'-p','55549','-U','postgres'];run('createdb',[TOOLS['createdb'],*conn,'photo_quality'])
 PSQL=[TOOLS['psql'],'-X','--no-password',*conn,'-d','photo_quality','-v','ON_ERROR_STOP=1']
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for m in sorted((SQL/'migrations').glob('*.sql')):run('apply-'+m.stem,[*PSQL,'-q','-1','-f',m])
 print('Fresh migration chain compiled.',flush=True)
 run('exact-overlay-replay',[*PSQL,'-q','-1','-f',MIG]);run('exact-calibration-replay',[*PSQL,'-q','-1','-f',SQL/'migrations/20261015035100_photo_quality_existing_calibration.sql']);print('Both overlays replayed.',flush=True)
 if FIX.exists():
  out=run('actual-photo-quality-rpc-roles',[*PSQL,'-Atq','-f',FIX]);r['fixture']=out.strip();print(out.strip()[-1500:],flush=True)
 # Compile actual SQL with narrow guards removed; independent fixture must fail.
 for label,signature,anchor,replacement,oracle in [
  ('quarantine','photo_quality_private_output_guard()',"if(new.storage_key like'ai-router/%/photo-evidence/%'", "if(false and new.storage_key like'ai-router/%/photo-evidence/%'", 'pending evidence cannot bypass ordinary registry'),
  ('legacy-quarantine','photo_quality_private_output_guard()',"or exists(select 1 from public.photo_edit_evidence e where e.legacy_keys?new.storage_key)", "", 'pending evidence cannot bypass legacy pointerless fallback'),
  ('settled-qc','photo_quality_finish(uuid,uuid,uuid,jsonb)',"and r.id is not null and l.id is not null", "and true", 'passing text without settled paid QC receipt is held'),
  ('paired-crops','photo_quality_derivatives_reserve(uuid,uuid,jsonb)',"if v->'crop'is distinct from crop or", "if false or", 'quadrant crop gap is refused'),
  ('calibration-replay-isolation','photo_quality_lookup(uuid,uuid,text)',"and e.purpose='prospective'", "", 'ordinarysaved2Klookup ignorescalibrationjournal'),
  ('calibration-nonpromotion','photo_quality_private_output_guard()',"and e.purpose='prospective'", "", 'passingcalibrationcannotbypassdeliverableregistry')]:
  original=run('read-'+label,[*PSQL,'-Atq','-c',"select pg_get_functiondef('public.%s'::regprocedure)"%signature]);assert original.count(anchor)>=1,(label,'missing actual anchor')
  run('compile-removed-'+label,[*PSQL,'-Atq'],original.replace(anchor,replacement,1))
  run('negative-'+label,[*PSQL,'-Atq','-f',FIX],refuses=oracle)
  run('restore-'+label,[*PSQL,'-Atq'],original);r['controls'].append({'name':label,'compiledActualSQL':True,'sameFixtureRefused':True,'oracle':oracle})
 # Independent concurrent sessions exercise actual operation and CPU row locks.
 actor='f8200000-0000-4000-8000-000000000101';listing='f8200000-0000-4000-8000-000000000111'
 run('race-fixture',[*PSQL,'-Atq'],f"insert into auth.users(id,email,is_anonymous)values('{actor}','photo-race@fixture.invalid',false);insert into listings(id,org_id,agent_id,address)select '{listing}',org_id,'{actor}','Synthetic concurrency property'from memberships where user_id='{actor}'and role='owner'limit 1;update app_config set value=jsonb_set(value,'{{enabled}}','true')where key='photo_quality';set role service_role;select serving_operation_begin('{actor}',(select org_id from listings where id='{listing}'),'photo-quality:race','photo_edit',repeat('d',64));")
 org=run('race-org',[*PSQL,'-Atq','-c',f"select org_id from listings where id='{listing}'"]).strip()
 body=json.dumps({'sha256':'a'*64,'bytes':60000,'mime':'image/jpeg','width':1024,'height':768})
 def race(label,statement):
  barrier=Barrier(2)
  def invoke(i):
   barrier.wait(timeout=10);o=run(f'{label}-{i}',[*PSQL,'-Atq'],"set role service_role;"+statement)
   return json.loads(next(v for v in o.splitlines()if v.startswith('{')))
  with ThreadPoolExecutor(max_workers=2)as pool:return list(pool.map(invoke,range(2)))
 outcomes=race('same-operation-race',f"select photo_quality_begin('{actor}','{org}','photo-quality:race','{listing}','declutter',null,null,'{body}');")
 assert sorted(x['created']for x in outcomes)==[False,True] and len({x['check']['id']for x in outcomes})==1,outcomes
 q=outcomes[0]['check']['id'];e=outcomes[0]['evidence']['id'];r['controls'].append({'name':'same-operation-race','actualConcurrentRequests':2,'oneCheck':True,'oneGenerationOwner':True})
 output=json.dumps({'sha256':'b'*64,'bytes':8000000,'mime':'image/png','width':4096,'height':3072,'generation_stage':'photo.declutter:0','provider':'gemini','model':'gemini-3.1-flash-image'})
 run('race-paid-candidate-fixture',[*PSQL,'-Atq'],f"set role service_role;select photo_quality_evidence_receipt('{actor}','{e}','input','prepared-etag');select photo_quality_evidence_reserve('{actor}','{e}','{output}');select photo_quality_evidence_receipt('{actor}','{e}','output','candidate-etag');")
 outcomes=race('same-cpu-lease-race',f"select photo_quality_claim('{q}');")
 assert sorted(x['action']for x in outcomes)==['prepare_photo_quality','wait'],outcomes
 r['controls'].append({'name':'same-cpu-lease-race','actualConcurrentRequests':2,'onePrivateCPULease':True,'noProviderCalls':True})
 r['passed']=True
finally:
 if started:run('stop',[TOOLS['pg_ctl'],'-D',DATA,'-m','immediate','-w','-t','30','stop'])
 r['sourceUnchanged']=r['sourceHashes']==hashes();r['passed']=r['passed']and r['sourceUnchanged'];(OUT/'receipt.json').write_text(json.dumps(r,indent=2)+'\n')
 shutil.rmtree(DATA,ignore_errors=True);shutil.rmtree(SOCK,ignore_errors=True)
 print(str(OUT/'receipt.json'),flush=True)
