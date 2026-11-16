#!/usr/bin/env python3
"""Focused PG17 completion contract, reusing the exact saved-output fixture.

No migration/source mutation. A generated, hash-bound fixture inserts assertions
before attachment, proving canonical preparation alone admits the video source.
"""
from pathlib import Path
from fresh_schema_migrations import partition_fresh_migrations
import argparse, datetime, hashlib, json, os, shutil, subprocess, tempfile

ROOT=Path(__file__).resolve().parents[3]; SQL=ROOT/'services/supabase'; PG=Path('/opt/homebrew/opt/postgresql@17/bin')
os.umask(0o077)
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',required=True,type=Path);a=p.parse_args()
OUT=a.evidence_dir.resolve();OUT.mkdir(parents=True,exist_ok=False)
DATA=OUT/'owned-pg';SOCK=Path(tempfile.mkdtemp(prefix='rp-completion-',dir='/tmp'))
ENV={'PATH':str(PG)+':/usr/bin:/bin','HOME':os.environ['HOME'],'LC_ALL':'C','TZ':'UTC','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
sha=lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
base=SQL/'tests/photo_publication_saved_output.sql';extra=SQL/'tests/photo_publication_upload_completion.sql'
migrations=sorted((SQL/'migrations').glob('*.sql'))
sources=[*migrations,base,extra,Path(__file__),SQL/'tests/ci-bootstrap.sql',SQL/'tests/fresh_schema_migrations.py',
 ROOT/'services/supabase/functions/uploads/accepted-photo.ts',ROOT/'services/supabase/functions/uploads/index.ts']
hashes=lambda:{str(f.relative_to(ROOT)):sha(f)for f in sources}
r={'schema':'photo-publication-upload-completion-pg17-v1','status':'running','startedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),
 'sourceHead':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'sourceBefore':hashes(),
 'commands':[],'productionActions':False,'providerCalls':0,'syntheticPhysicalReceipts':True};started=False
def save():(OUT/'receipt.json').write_text(json.dumps(r,indent=2)+'\n')
def run(name,args,body=None):
 c=subprocess.run([str(x)for x in args],input=body,cwd=ROOT,env=ENV,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
 log=OUT/(name+'.log');log.write_text(c.stdout);r['commands'].append({'name':name,'argv':[str(x)for x in args],'exit':c.returncode,'log':str(log),'sha256':sha(log)});save()
 assert c.returncode==0,(name,c.stdout[-6000:]);return c.stdout
try:
 r['postgresVersion']=run('version',[PG/'postgres','--version']).strip();assert ' 17.11 'in r['postgresVersion']
 marker='create temp table attached as select studio_attach_photo_from_upload'
 text=base.read_text();assert text.count(marker)==1
 inventory='(select count(*)from checks)<>55'
 assert text.count(inventory)==1
 generated=OUT/'completion-fixture.sql';generated.write_text(text.replace(marker,extra.read_text()+'\n'+marker).replace(inventory,'(select count(*)from checks)<>64'));r['fixtureSHA256']=sha(generated)
 run('initdb',[PG/'initdb','-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[PG/'pg_ctl','-D',DATA,'-l',OUT/'postgres.log','-w','-t','30','-o',f"-k {SOCK} -p 55634 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=10",'start']);started=True
 conn=['-h',SOCK,'-p','55634','-U','postgres'];run('createdb',[PG/'createdb',*conn,'photo_publication_saved_output'])
 psql=[PG/'psql','-X','--no-password',*conn,'-d','photo_publication_saved_output','-v','ON_ERROR_STOP=1']
 assert run('identity',[*psql,'-Atq'],"select current_setting('data_directory')||'|'||current_setting('listen_addresses');").strip()==str(DATA)+'|'
 run('bootstrap',[*psql,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 schema,live=partition_fresh_migrations(migrations);r['excludedLiveStateOnly']=[m.name for m in live]
 seams=['20261113213000_photo_publication_saved_output_compat.sql','20261113222000_photo_publication_authenticated_read.sql',
 '20261113223202_gallery_canonical_prepared_publication.sql','20261116202000_photo_publication_native_saved_output_compat.sql']
 for m in [x for x in schema if x.name not in seams]+[SQL/'migrations'/x for x in seams]:run('apply-'+m.stem,[*psql,'-q','-1','-f',m])
 for native in [True,False]:
  for replay in [False,True]:
   name=('native'if native else'gallery')+('-repeat'if replay else'-fresh')
   output=run(name,[*psql,'-Atq','-v','native_output='+str(native).lower(),'-f',generated])
   rows=[json.loads(x)for x in output.splitlines()if x.startswith('{')and'"suite": "photo-publication-saved-output"'in x]
   assert len(rows)==1 and rows[0]['passed']and rows[0]['assertions']==64 and rows[0]['native_output']==native
   r[name]=rows[0]
 assert hashes()==r['sourceBefore'],'Consumed source changed';r['status']='passed'
except BaseException as e:r['status']='failed';r['error']=repr(e);raise
finally:
 if started:
  c=subprocess.run([str(PG/'pg_ctl'),'-D',str(DATA),'-m','immediate','-w','-t','30','stop'],env=ENV,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
  (OUT/'stop.log').write_text(c.stdout);r['stopExit']=c.returncode
  if c.returncode!=0:r['status']='failed'
 shutil.rmtree(DATA,ignore_errors=True);shutil.rmtree(SOCK,ignore_errors=True)
 r['sourceAfter']=hashes();r['sourceStable']=r['sourceAfter']==r['sourceBefore']
 if not r['sourceStable']:r['status']='failed'
 r['finishedAt']=datetime.datetime.now(datetime.timezone.utc).isoformat();save()
 print(json.dumps({'status':r['status'],'receipt':str(OUT/'receipt.json')}),flush=True)
