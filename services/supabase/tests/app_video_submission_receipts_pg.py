#!/usr/bin/env python3
"""Actual disposable PostgreSQL submission-receipt/erasure/concurrency proof.
No provider, hosted database, customer media, inherited auth or network listener.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from fresh_schema_migrations import partition_fresh_migrations
from threading import Barrier
import argparse,hashlib,json,os,shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path,required=True);a=p.parse_args();OUT=a.evidence_dir;OUT.mkdir(parents=True,exist_ok=True);OUT.chmod(0o700)
assert shutil.disk_usage(ROOT).free>=3*1024**3,'Preserve internal3GiB reserve'
DATA=Path(tempfile.mkdtemp(prefix='submission-receipt-pg-',dir='/Volumes/Rendprop Files/Builds/Active'if Path('/Volumes/Rendprop Files/Builds/Active').is_dir()else None));SOCK=Path(tempfile.mkdtemp(prefix='submission-socket-',dir='/tmp'))
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
tool=lambda n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)
CANDIDATE,=list((SQL/'migrations').glob('*_app_video_submission_receipts.sql'));FIX=SQL/'tests/app_video_submission_receipts.sql';MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'))
SOURCES=[*MIGRATIONS,FIX,SQL/'tests/ci-bootstrap.sql',Path(__file__).resolve()]
hashes=lambda:{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest()for f in SOURCES}
receipt={'passed':False,'scope':'actual disposable PostgreSQL/roles/concurrency/canonical account deletion, full current migration chain, synthetic metadata only','providerCalls':0,'hostedCalls':0,'sourceHashes':hashes(),'commands':[],'controls':[],'races':[]};started=False
def run(name,cmd,body=None,refuses=None):
 r=subprocess.run([str(x)for x in cmd],input=body,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
 path=OUT/(name+'.log');path.write_text(r.stdout);path.chmod(0o600);receipt['commands'].append({'name':name,'exit':r.returncode,'logSHA256':hashlib.sha256(r.stdout.encode()).hexdigest()})
 assert(r.returncode and refuses in r.stdout)if refuses else r.returncode==0,(name,r.stdout[-5500:]);return r.stdout
def race(name,bodies):
 barrier=Barrier(len(bodies))
 def call(pair):
  i,body=pair;barrier.wait(timeout=10);r=subprocess.run([*PSQL,'-Atq'],input='set role service_role;'+body,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
  path=OUT/f'{name}-{i}.log';path.write_text(r.stdout);path.chmod(0o600);return{'exit':r.returncode,'output':r.stdout}
 with ThreadPoolExecutor(max_workers=len(bodies))as pool:return list(pool.map(call,enumerate(bodies)))
try:
 run('initdb',[tool('initdb'),'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[tool('pg_ctl'),'-D',DATA,'-l',OUT/'postgres.log','-w','-o',f"-k {SOCK} -p 55587 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 conn=['-h',SOCK,'-p','55587','-U','postgres'];run('createdb',[tool('createdb'),*conn,'submission_receipt_proof'])
 PSQL=[tool('psql'),'-X','--no-password',*conn,'-d','submission_receipt_proof','-v','ON_ERROR_STOP=1']
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for m in partition_fresh_migrations(MIGRATIONS)[0]:run('apply-'+m.stem,[*PSQL,'-q','-1','-f',m])
 for stage in ['fresh','replay']:
  if stage=='replay':run('replay-own-migration',[*PSQL,'-q','-1','-f',CANDIDATE])
  out=run(stage+'-actual-submission',[*PSQL,'-Atq','-f',FIX]);rows=[json.loads(x)for x in out.splitlines()if x.startswith('{')and'assertions'in x];assert len(rows)==1 and rows[0]['passed'];receipt[stage]=rows[0]
 for label,signature,anchor,replacement,oracle in [
  ('held-state','public.app_video_submission_receipt_authority(uuid,uuid,text,uuid,jsonb)',"or h.state<>'succeeded'",'', 'unknown or rejected serving hold cannot authorize acceptance'),
  ('held-input','public.app_video_submission_receipt_authority(uuid,uuid,text,uuid,jsonb)','or h.input_sha256 is distinct from r.input_sha256','', 'held input hash exact'),
  ('url-identity','public.app_video_submission_receipt_authority(uuid,uuid,text,uuid,jsonb)',"if p_receipt->>'poll_url'not in(","if false and p_receipt->>'poll_url'not in(", 'malformed, foreign or fabricated receipt refused'),
  ('first-receipt','public.app_video_submission_receipt_save(uuid,uuid,text,uuid,jsonb)','if row(s.actor_id,s.org_id,s.operation_id,s.listing_id,s.receipt)is distinct from row(p_actor,p_org,p_key,p_listing,p_receipt)','if false and row(s.actor_id,s.org_id,s.operation_id,s.listing_id,s.receipt)is distinct from row(p_actor,p_org,p_key,p_listing,p_receipt)', 'original submitted_at cannot change')]:
  original=run('read-'+label,[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%signature]);assert original.count(anchor)==1,(label,'exact production anchor')
  run('compile-'+label,[*PSQL,'-Atq'],original.replace(anchor,replacement,1));run('negative-'+label,[*PSQL,'-Atq','-f',FIX],refuses=oracle);run('restore-'+label,[*PSQL,'-Atq'],original)
  receipt['controls'].append({'name':label,'compiledActualSQL':True,'unsafeMutationRejected':True})
 setup=FIX.read_text().split('-- END SYNTHETIC FIXTURE')[0].replace('set local ','set ')
 setup+="select pg_temp.acceptance(3);create table public.submission_race_scope as select vf.*,pg_temp.ref(1)ref1,pg_temp.ref(3)ref3,pg_temp.ref(103)ref103 from vf;grant select on public.submission_race_scope to service_role;commit;"
 run('race-setup',[*PSQL,'-Atq'],setup)
 statement="select app_video_submission_receipt_save(actor,org,'animate-fixture:1',listing,ref1)->>'saved'from public.submission_race_scope;"
 results=race('same-first-write',[statement,statement]);assert all(x['exit']==0 and x['output'].strip()=='true'for x in results),results
 results=race('different-first-receipts',["select app_video_submission_receipt_save(actor,org,'animate-fixture:3',listing,ref3)->>'saved'from public.submission_race_scope;","select app_video_submission_receipt_save(actor,org,'animate-fixture:3',listing,ref103)->>'saved'from public.submission_race_scope;"])
 assert sum(x['exit']==0 for x in results)==1 and any('immutable'in x['output']for x in results),results
 count=run('race-row-count',[*PSQL,'-Atq','-c',"select count(*)from app_video_submission_receipts;"]).strip();assert count=='2',count
 receipt['races']=[{'name':'same-exact-first-receipt','requests':2,'oneImmutableRow':True},{'name':'conflicting-first-receipts','oneSavedOneRefused':True}]
 proc=subprocess.Popen([*PSQL,'-Atq'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,env=ENV,cwd=ROOT)
 proc.stdin.write("begin;set role service_role;select prepare_account_deletion(actor,'fixture-uploads','fixture-renders')from public.submission_race_scope;select 'ERASURE_LOCKED';select pg_sleep(1.5);commit;\n");proc.stdin.close();lines=[]
 while True:
  line=proc.stdout.readline();assert line,'Canonical erasure failed before locking marker';lines.append(line)
  if line.strip()=='ERASURE_LOCKED':break
 run('late-write-during-canonical-erasure',[*PSQL,'-Atq'],"set role service_role;select app_video_submission_receipt_save(actor,org,'animate-fixture:1',listing,ref1)from public.submission_race_scope;",refuses='RP404:')
 lines.append(proc.stdout.read());assert proc.wait(timeout=15)==0,''.join(lines)[-2000:];(OUT/'canonical-erasure-race.log').write_text(''.join(lines));(OUT/'canonical-erasure-race.log').chmod(0o600)
 assert run('erasure-race-no-resurrection',[*PSQL,'-Atq','-c',"select count(*)from app_video_submission_receipts;"]).strip()=='0'
 receipt['races'].append({'name':'canonical-account-erasure-vs-late-save','noResurrectedReceipt':True,'actualProductionErasureFunction':True})
 assert hashes()==receipt['sourceHashes'],'Consumed SQL/fixture/driver changed during proof';receipt['passed']=True
 print(json.dumps({'passed':True,'fresh':receipt['fresh']['assertions'],'replay':receipt['replay']['assertions'],'controls':len(receipt['controls']),'races':len(receipt['races']),'receipt':str(OUT/'receipt.json')}))
finally:
 if started:run('stop',[tool('pg_ctl'),'-D',DATA,'-m','immediate','-w','stop'])
 path=OUT/'receipt.json';path.write_text(json.dumps(receipt,indent=2)+'\n');path.chmod(0o600)
 if not started or not(DATA/'postmaster.pid').exists():shutil.rmtree(DATA)
 if SOCK.exists():shutil.rmtree(SOCK)
