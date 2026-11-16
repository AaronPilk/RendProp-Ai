#!/usr/bin/env python3
"""Actual failed-recipe supplier-slot SQL, service roles and concurrency controls.
No inherited credentials, network listener, supplier generation or hosted writes.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from fresh_schema_migrations import partition_fresh_migrations
from threading import Barrier
import argparse,hashlib,json,os,shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);args=p.parse_args()
OUT=args.evidence_dir or Path(tempfile.mkdtemp(prefix='failed-video-slots-proof-'));OUT.mkdir(parents=True,exist_ok=True)
assert shutil.disk_usage(ROOT).free>=3*1024**3,'Preserve internal3GiB reserve'
DATA=Path(tempfile.mkdtemp(prefix='failed-video-slots-owned-pg-'));SOCK=Path(tempfile.mkdtemp(prefix='failed-video-slots-sock-',dir='/tmp'));started=False
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
tool=lambda n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)
MIG=SQL/'migrations/20261015062943_property_video_failed_supplier_terminal_reconciliation.sql';FIX=SQL/'tests/property_video_failed_terminal.sql';BASE=SQL/'tests/property_video_jobs.sql'
SOURCES=[*sorted((SQL/'migrations').glob('*.sql')),SQL/'tests/ci-bootstrap.sql',BASE,FIX,Path(__file__).resolve()]
hashes=lambda:{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest()for f in SOURCES}
r={'passed':False,'scope':'actual local PostgreSQL/functions/roles; closed provider receipt fixtures only','networkCalls':0,'providerCalls':0,'sourceHashes':hashes(),'commands':[],'controls':[],'races':[]}
def run(name,cmd,body=None,refuses=None):
 c=subprocess.run([str(x)for x in cmd],input=body,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
 f=OUT/(name+'.log');f.write_text(c.stdout);f.chmod(0o600);r['commands'].append({'name':name,'exit':c.returncode,'logSHA256':hashlib.sha256(f.read_bytes()).hexdigest()})
 assert(c.returncode and refuses in c.stdout)if refuses else c.returncode==0,(name,c.stdout[-4000:]);return c.stdout
def race(name,commands):
 barrier=Barrier(len(commands))
 def call(pair):
  i,body=pair;barrier.wait(timeout=10)
  c=subprocess.run([*PSQL,'-Atq'],input='set role service_role;'+body,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
  (OUT/f'{name}-{i}.log').write_text(c.stdout);assert c.returncode==0,(name,c.stdout[-3000:]);return c.stdout
 with ThreadPoolExecutor(max_workers=len(commands))as pool:return list(pool.map(call,enumerate(commands)))
base=BASE.read_text();seed=base[base.index('insert into auth.users'):base.index('select pg_temp.ok((select bool_and')]
fixture='begin;\n'+seed+'\n'+FIX.read_text()
try:
 run('initdb',[tool('initdb'),'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[tool('pg_ctl'),'-D',DATA,'-l',OUT/'postgres.log','-w','-o',f"-k {SOCK} -p 55569 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 conn=['-h',SOCK,'-p','55569','-U','postgres'];run('createdb',[tool('createdb'),*conn,'failed_video_slots'])
 PSQL=[tool('psql'),'-X','--no-password',*conn,'-d','failed_video_slots','-v','ON_ERROR_STOP=1']
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for m in partition_fresh_migrations(sorted((SQL/'migrations').glob('*.sql')))[0]:run('apply-'+m.stem,[*PSQL,'-q','-1','-f',m])
 # The migration intentionally changes exactly two state guards, not payment,
 # global-capacity, supplier receipt, retry, or source-visibility authority.
 original=(SQL/'migrations/20261014183851_background_property_videos.sql').read_text()
 original=original[original.index('create or replace function public.property_video_cancelled_attempts()'):original.index('\ncreate or replace function public.property_video_job_audio_source')].strip()
 migrated=MIG.read_text();migrated=migrated[migrated.index('create or replace function public.property_video_cancelled_attempts()'):migrated.rindex('\ncommit;')].strip()
 assert migrated.replace("('cancelled','needs_reconciliation','failed')","('cancelled','needs_reconciliation')")==original
 for stage in ['fresh','replay']:
  if stage=='replay':run('replay-migration',[*PSQL,'-q','-1','-f',MIG])
  out=run(stage+'-actual-failed-slots',[*PSQL,'-Atq'],fixture)
  rows=[json.loads(line)for line in out.splitlines()if line.startswith('{')and'assertions'in line];assert len(rows)==1 and rows[0]['passed'];r[stage]=rows[0]
 for label,signature,anchor,replacement,oracle in [
  ('failed-scan-state','public.property_video_cancelled_attempts()',"j.state in('cancelled','needs_reconciliation','failed')","j.state in('cancelled','needs_reconciliation')",'failed known paid receipts enter metadata reconciliation'),
  ('failed-terminal-state','public.property_video_cancelled_terminal(uuid,uuid,text,text,text)',"j.state not in('cancelled','needs_reconciliation','failed')","j.state not in('cancelled','needs_reconciliation')",'Knowncancelled providerreceipt isunavailable'),
  ('foreign-paid-actor','public.property_video_cancelled_terminal(uuid,uuid,text,text,text)',"actor_id=j.actor_id and org_id=j.org_id","org_id=j.org_id",'allowed foreign actor paid reservation cannot free failed slot')]:
  definition=run('read-'+label,[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%signature]);assert definition.count(anchor)==1,(label,'exact source anchor')
  run('compile-'+label,[*PSQL,'-Atq'],definition.replace(anchor,replacement,1));run('negative-'+label,[*PSQL,'-Atq'],fixture,refuses=oracle);run('restore-'+label,[*PSQL,'-Atq'],definition)
  r['controls'].append({'name':label,'compiledActualSQL':True,'independentOracleRefused':True})
 # Persist four accepted-but-failed recipes. These are local synthetic supplier
 # receipts; no generation or status network request occurs in this driver.
 prefix=FIX.read_text().split('create temporary table before_liability',1)[0]
 out=run('race-fixture',[*PSQL,'-Atq'],'begin;\n'+seed+'\n'+prefix+"select jsonb_build_object('case',c,'waiting_job',(select id from waiting_job))from failed_cases where i=1;commit;")
 case=next(json.loads(line)for line in out.splitlines()if line.startswith('{')and'waiting_job'in line);c=case['case'];jid=c['job']['id'];attempt=c['source']['attempt_id']
 scans=race('concurrent-failed-scans',['select property_video_cancelled_attempts();']*2)
 batches=[json.loads(next(line for line in v.splitlines()if line.startswith('[')))for v in scans];attempts=[row['attempt_id']for batch in batches for row in batch]
 assert len(attempts)==len(set(attempts))==4,batches;r['races'].append({'name':'concurrent-failed-scans','requests':2,'exactlyFourDistinctPaidReceipts':True})
 statement="select property_video_cancelled_terminal('%s','%s','fixture-accepted:1','fal','fixture-model');"%(jid,attempt)
 terminals=race('same-terminal-replay',[statement]*2);assert all(v.strip().endswith('t')for v in terminals)
 assert run('one-terminal-count',[*PSQL,'-Atq','-c',"select count(*)from property_video_job_sources where provider_terminal_at is not null;"]).strip()=='1'
 r['races'].append({'name':'same-terminal-replay','requests':2,'exactlyOneSlotReleased':True,'idempotentAcknowledgements':True})
 claims=race('one-freed-slot-two-claims',["select property_video_job_claim('%s','slot-%s');"%(case['waiting_job'],i)for i in range(2)])
 actions=[json.loads(next(line for line in v.splitlines()if line.startswith('{')))['action']for v in claims];assert sorted(actions)==['dispatch','wait'],actions
 r['races'].append({'name':'one-freed-slot-two-claims','requests':2,'oneDispatchOneWait':True,'globalFourLimitPreserved':True})
 r['passed']=True
finally:
 if started:run('stop',[tool('pg_ctl'),'-D',DATA,'-m','immediate','-w','-t','30','stop'])
 r['sourceUnchanged']=r['sourceHashes']==hashes();r['passed']=r['passed']and r['sourceUnchanged'];(OUT/'receipt.json').write_text(json.dumps(r,indent=2)+'\n')
 shutil.rmtree(DATA,ignore_errors=True);shutil.rmtree(SOCK,ignore_errors=True);print(json.dumps({'passed':r['passed'],'receipt':str(OUT/'receipt.json')}),flush=True)
