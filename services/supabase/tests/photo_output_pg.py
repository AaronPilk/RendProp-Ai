#!/usr/bin/env python3
"""Actual current forward SQL candidate/source bounds; no provider/hosted writes."""
from pathlib import Path
from fresh_schema_migrations import partition_fresh_migrations
import argparse,hashlib,json,os,shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
a=argparse.ArgumentParser();a.add_argument('--evidence-dir',type=Path);args=a.parse_args();OUT=args.evidence_dir or Path(tempfile.mkdtemp(prefix='photo-output-proof-'));OUT.mkdir(parents=True,exist_ok=True)
assert shutil.disk_usage(ROOT).free>=3*1024**3,'Preserve internal3GiB reserve'
DATA=Path(tempfile.mkdtemp(prefix='photo-output-owned-pg-'));SOCK=Path(tempfile.mkdtemp(prefix='photo-out-sock-',dir='/tmp'));started=False
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
tool=lambda n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)
MIG=SQL/'migrations/20261015062213_photo_output_25mib.sql';FIX=SQL/'tests/photo_output.sql';SOURCES=[*sorted((SQL/'migrations').glob('*.sql')),SQL/'tests/ci-bootstrap.sql',SQL/'tests/photo_quality_evidence.sql',FIX,Path(__file__).resolve()]
hashes=lambda:{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in SOURCES}
r={'passed':False,'networkCalls':0,'providerCalls':0,'sourceHashes':hashes(),'commands':[],'controls':[]}
def run(name,cmd,body=None,refuses=None):
 p=subprocess.run([str(x)for x in cmd],input=body,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120);f=OUT/(name+'.log');f.write_text(p.stdout);f.chmod(0o600);r['commands'].append({'name':name,'exit':p.returncode,'sha256':hashlib.sha256(f.read_bytes()).hexdigest()});assert(p.returncode and refuses in p.stdout)if refuses else p.returncode==0,(name,p.stdout[-4000:]);return p.stdout
try:
 run('initdb',[tool('initdb'),'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8']);run('start',[tool('pg_ctl'),'-D',DATA,'-l',OUT/'postgres.log','-w','-o',f"-k {SOCK} -p 55561 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 conn=['-h',SOCK,'-p','55561','-U','postgres'];run('createdb',[tool('createdb'),*conn,'photo_output']);PSQL=[tool('psql'),'-X','--no-password',*conn,'-d','photo_output','-v','ON_ERROR_STOP=1'];run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for m in partition_fresh_migrations(sorted((SQL/'migrations').glob('*.sql')))[0]:run('apply-'+m.stem,[*PSQL,'-q','-1','-f',m])
 for stage in ['fresh','replay']:
  if stage=='replay':run('replay-output-migration',[*PSQL,'-q','-1','-f',MIG])
  r[stage]=run(stage+'-actual-output-boundaries',[*PSQL,'-Atq','-f',FIX]).strip().splitlines()[-1]
 for label,signature,anchor,replacement,oracle in [
  ('candidate-cap','photo_quality_evidence_reserve(uuid,uuid,jsonb)',"then 9000000 else 26214400 end","then 9000000 else 26214401 end",'candidate next byte refuses'),
  ('source-cap','photo_quality_begin(uuid,uuid,text,uuid,text,text,uuid,jsonb,jsonb)',"(p_input->>'bytes')::bigint>9000000","(p_input->>'bytes')::bigint>9000001",'source next byte refuses')]:
  original=run('read-'+label,[*PSQL,'-Atq','-c',"select pg_get_functiondef('public.%s'::regprocedure)"%signature]);assert original.count(anchor)==1;run('compile-'+label,[*PSQL,'-Atq'],original.replace(anchor,replacement));run('negative-'+label,[*PSQL,'-Atq','-f',FIX],refuses=oracle);run('restore-'+label,[*PSQL,'-Atq'],original);r['controls'].append({'name':label,'compiledActualSQL':True,'independentOracleRefused':True})
 r['passed']=True
finally:
 if started:run('stop',[tool('pg_ctl'),'-D',DATA,'-m','immediate','-w','-t','30','stop'])
 r['sourceUnchanged']=r['sourceHashes']==hashes();r['passed']=r['passed']and r['sourceUnchanged'];(OUT/'receipt.json').write_text(json.dumps(r,indent=2)+'\n');shutil.rmtree(DATA,ignore_errors=True);shutil.rmtree(SOCK,ignore_errors=True);print(str(OUT/'receipt.json'),flush=True)
