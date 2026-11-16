#!/usr/bin/env python3
"""Actual private-history RLS/projection on an owned disposable PostgreSQL instance.
No credentials, TCP listener, production DB, supplier calls or persisted fixture rows.
"""
from pathlib import Path
from fresh_schema_migrations import partition_fresh_migrations
import argparse, hashlib, json, os, shutil, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);args=p.parse_args()
OUT=args.evidence_dir or Path(tempfile.mkdtemp(prefix='studio-photo-history-evidence-',dir='/tmp'));OUT.mkdir(parents=True,exist_ok=True)
DATA=Path(tempfile.mkdtemp(prefix='studio-photo-history-pg-',dir='/tmp'));SOCK=Path(tempfile.mkdtemp(prefix='studio-photo-history-sock-',dir='/tmp'))
TOOLS={n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)for n in ['initdb','pg_ctl','psql','createdb']}
assert all(Path(t).is_file()and os.access(t,os.X_OK)for t in TOOLS.values())
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'))
SCHEMA_MIGRATIONS,LIVE_STATE_MIGRATIONS=partition_fresh_migrations(MIGRATIONS)
files=[*MIGRATIONS,SQL/'tests/ci-bootstrap.sql',SQL/'tests/studio_photo_history.sql',Path(__file__).resolve(),SQL/'functions/studio/repository.ts',SQL/'functions/studio/handler.ts']
receipt={'passed':False,'scope':'Actual disposable PostgreSQL/RLS projection and repository source binding; handler transport checked separately','sourceHashes':{str(x.relative_to(ROOT)):hashlib.sha256(x.read_bytes()).hexdigest()for x in files},'liveStateOnlyMigrations':[m.name for m in LIVE_STATE_MIGRATIONS],'commands':[],'networkCalls':0}
def run(name,argv):
 r=subprocess.run([str(a)for a in argv],env=ENV,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
 (OUT/(name+'.log')).write_text(r.stdout);receipt['commands'].append({'name':name,'exit':r.returncode,'sha256':hashlib.sha256(r.stdout.encode()).hexdigest()});assert r.returncode==0,(name,r.stdout[-2500:]);return r.stdout
started=False
try:
 run('initdb',[TOOLS['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[TOOLS['pg_ctl'],'-D',DATA,'-l',OUT/'postgres.log','-w','-t','30','-o',f"-k {SOCK} -p 55538 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 conn=['-h',SOCK,'-p','55538','-U','postgres'];run('createdb',[TOOLS['createdb'],*conn,'studio_photos'])
 psql=[TOOLS['psql'],'-X','--no-password',*conn,'-d','studio_photos','-v','ON_ERROR_STOP=1']
 run('bootstrap',[*psql,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for migration in SCHEMA_MIGRATIONS:run('apply-'+migration.stem,[*psql,'-q','-1','-f',migration])
 out=run('private-photo-history',[*psql,'-Atq','-f',SQL/'tests/studio_photo_history.sql']);proof=[json.loads(s)for s in out.splitlines()if s.startswith('{')and 'assertions'in s];assert len(proof)==1 and proof[0]['passed'];receipt['unit']=proof[0];receipt['passed']=True
finally:
 if started:run('stop',[TOOLS['pg_ctl'],'-D',DATA,'-m','immediate','-w','stop'])
 shutil.rmtree(DATA,ignore_errors=True);shutil.rmtree(SOCK,ignore_errors=True)
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2));print(json.dumps({'evidence':str(OUT),**receipt},indent=2))
