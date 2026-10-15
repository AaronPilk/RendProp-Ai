#!/usr/bin/env python3
"""Actual isolated PostgreSQL source-classification guards and typed/recorded compatibility."""
from pathlib import Path
import argparse,hashlib,json,os,shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase';p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);a=p.parse_args()
OUT=a.evidence_dir or Path(tempfile.mkdtemp(prefix='studio-recorded-source-evidence-'));OUT.mkdir(parents=True,exist_ok=True)
DATA=Path(tempfile.mkdtemp(prefix='studio-recorded-source-pg-'));SOCK=Path(tempfile.mkdtemp(prefix='studio-recorded-source-sock-'))
TOOLS={n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)for n in ['initdb','pg_ctl','psql','createdb']}
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
MIG=SQL/'migrations/20261015162802_studio_recorded_source_authority.sql';BASE=SQL/'tests/property_video_websites.sql';EXTRA=SQL/'tests/studio_recorded_source.sql'
FILES=[*sorted((SQL/'migrations').glob('*.sql')),SQL/'tests/ci-bootstrap.sql',BASE,EXTRA,Path(__file__).resolve()];hashes=lambda:{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest()for f in FILES}
r={'passed':False,'scope':'Actual disposable PostgreSQL, scoped authority, exact retained output/preparation/attestation fixtures; no network/media/provider/Apple calls','sourceHashes':hashes(),'controls':[],'commands':[]};started=False
fixture=BASE.read_text();anchor='create temporary table manifest as select';assert fixture.count(anchor)==1;fixture=fixture.replace(anchor,EXTRA.read_text()+'\n'+anchor)
def run(name,args,stdin=None,okay=True):
 x=subprocess.run([str(v)for v in args],input=stdin,env=ENV,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120);(OUT/(name+'.log')).write_text(x.stdout);r['commands'].append({'name':name,'exit':x.returncode,'sha256':hashlib.sha256(x.stdout.encode()).hexdigest()});assert not okay or x.returncode==0,(name,x.stdout[-3500:]);return x
try:
 run('initdb',[TOOLS['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8']);run('start',[TOOLS['pg_ctl'],'-D',DATA,'-l',OUT/'postgres.log','-w','-t','30','-o',f"-k {SOCK} -p 55561 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 conn=['-h',SOCK,'-p','55561','-U','postgres'];run('createdb',[TOOLS['createdb'],*conn,'studio_recorded']);P=[TOOLS['psql'],'-X','--no-password',*conn,'-d','studio_recorded','-v','ON_ERROR_STOP=1'];run('bootstrap',[*P,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for m in sorted((SQL/'migrations').glob('*.sql')):run('apply-'+m.stem,[*P,'-q','-1','-f',m])
 for name in ['fresh','replay']:
  if name=='replay':run('replay-migration',[*P,'-q','-1','-f',MIG])
  x=run(name,[*P,'-Atq'],fixture+'\nrollback;');proof=[json.loads(l)for l in x.stdout.splitlines()if l.startswith('{')and 'assertions'in l];assert len(proof)==1 and proof[0]['passed'];r[name]=proof[0]
 sigs=['public.assert_recorded_render_source(uuid,uuid)','public.create_render_job(uuid,uuid,text,jsonb,text,text)','public.publish_recorded_render(uuid,boolean,numeric,numeric,jsonb,uuid)'];defs={sig:run('definition-'+str(i),[*P,'-Atq','-c',f"select pg_get_functiondef('{sig}'::regprocedure)"]).stdout for i,sig in enumerate(sigs)}
 controls=[('generic-publish',sigs[2],[(" perform public.assert_recorded_render_source(j.listing_id,j.capture_asset_id) from public.render_jobs j where j.id=p_job;"," -- omitted generic recorded source guard")],'attested unpublished photo video cannot be recorded footage before composition'),('attestation',sigs[0],[("where attested.asset_id=a.id","where false and attested.asset_id=a.id"),("from public.property_video_attestations where asset_id=a.id","from public.property_video_attestations where false and asset_id=a.id")],'attested unpublished photo video cannot be recorded footage before composition'),('output',sigs[0],[("where output.asset_id=a.id","where false and output.asset_id=a.id"),("from public.property_video_job_outputs where asset_id=a.id","from public.property_video_job_outputs where false and asset_id=a.id")],'registered output without attestation/composition cannot be recorded footage'),('preparation',sigs[0],[("where prepared.asset_id=a.id","where false and prepared.asset_id=a.id"),("from public.property_video_preparations where asset_id=a.id","from public.property_video_preparations where false and asset_id=a.id")],'prepared video-only image cannot become a paid recorded source'),('paid-worker',sigs[1],[("if v_source = 'worker' then perform public.assert_recorded_render_source(p_listing,p_asset); end if;","if false then perform public.assert_recorded_render_source(p_listing,p_asset); end if;")],'typed photo output cannot start new paid recorded work')]
 for name,sig,edits,expected in controls:
  mutated=defs[sig]
  for before,after in edits:assert mutated.count(before)==1,(name,before);mutated=mutated.replace(before,after)
  run('install-'+name,[*P,'-Atq'],mutated);x=run('fault-'+name,[*P,'-Atq'],fixture+'\nrollback;',False);assert x.returncode!=0 and expected in x.stdout,(name,x.stdout[-1800:]);r['controls'].append({'name':name,'compiledActualSQL':True,'expectedFailure':expected});run('restore-'+name,[*P,'-Atq'],defs[sig])
 assert hashes()==r['sourceHashes'],'source changed during verification';r['passed']=True
finally:
 if started:run('stop',[TOOLS['pg_ctl'],'-D',DATA,'-m','immediate','-w','stop'])
 (OUT/'receipt.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps({'passed':r['passed'],'receipt':str(OUT/'receipt.json')}));shutil.rmtree(DATA,ignore_errors=True);shutil.rmtree(SOCK,ignore_errors=True)
