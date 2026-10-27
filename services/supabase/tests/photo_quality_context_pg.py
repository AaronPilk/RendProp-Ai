#!/usr/bin/env python3
"""Isolated actual Postgres context proof; no inherited credentials/network."""
from pathlib import Path
from fresh_schema_migrations import partition_fresh_migrations
import argparse,hashlib,json,shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);a=p.parse_args();out=a.evidence_dir or Path(tempfile.mkdtemp(prefix='photo-context-proof-'));out.mkdir(parents=True,exist_ok=True)
data=Path(tempfile.mkdtemp(prefix='photo-context-pg-'));sock=Path(tempfile.mkdtemp(prefix='photo-context-sock-'));env={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=10000'}
tool=lambda n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)
receipt={'passed':False,'networkCalls':0,'providerCalls':0,'commands':[]};started=False
def run(name,cmd,body=None,refuses=None):
 r=subprocess.run([str(x)for x in cmd],input=body,text=True,env=env,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120);f=out/(name+'.log');f.write_text(r.stdout);f.chmod(0o600);receipt['commands'].append({'name':name,'exit':r.returncode,'sha256':hashlib.sha256(f.read_bytes()).hexdigest()})
 assert (r.returncode and refuses in r.stdout)if refuses else not r.returncode,(name,r.stdout[-4000:]);return r.stdout
try:
 run('init',[tool('initdb'),'-D',data,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8']);run('start',[tool('pg_ctl'),'-D',data,'-l',out/'postgres.log','-w','-o',f"-k {sock} -p 55553 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 conn=['-h',sock,'-p','55553','-U','postgres'];run('db',[tool('createdb'),*conn,'photo_context']);psql=[tool('psql'),'-X','--no-password',*conn,'-d','photo_context','-v','ON_ERROR_STOP=1']
 run('bootstrap',[*psql,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for m in partition_fresh_migrations(sorted((SQL/'migrations').glob('*.sql')))[0]:run('apply-'+m.stem,[*psql,'-q','-1','-f',m])
 migration=SQL/'migrations/20261015041036_photo_quality_judge_context.sql';run('exact-replay',[*psql,'-q','-1','-f',migration])
 fixture=(SQL/'tests/photo_quality_context.sql').read_text();receipt['fixture']=run('context-rpc-proof',[*psql,'-Atq'],fixture).strip();print(receipt['fixture'],flush=True)
 # Existing complete evidence/payment/quarantine corpus, now supplying the new
 # server-retained context before its synthetic funded bind helper.
 baseline=(SQL/'tests/photo_quality_evidence.sql').read_text();original_baseline=baseline
 assert baseline.count("if retain_context then perform public.photo_quality_set_context(")==1
 missing=original_baseline[:original_baseline.index("select pg_temp.ok((select value->>'enabled'")]+"update app_config set value=jsonb_set(value,'{enabled}','true')where key='photo_quality';set local role service_role;select pg_temp.no($q$select pg_temp.bind(pg_temp.prepared(pg_temp.candidate(pg_temp.seed('missing-funded-context'))),true,false)$q$,'context is missing','missing context refuses binding before provider funding can be used');rollback;"
 receipt['missingContextFundedProof']=run('missing-context-funded-proof',[*psql,'-Atq'],missing).strip()
 receipt['existingCorpusWithContext']=run('existing-evidence-corpus-context',[*psql,'-Atq'],baseline).strip()[-1000:]
 for label,sig,anchor,replacement,oracle in [('body-hash','photo_quality_set_context(uuid,uuid,text,jsonb)',"if p_request_sha256 is distinct from e.request_sha256 then","if false then",'context requires admitted complete body hash'),('immutable','photo_quality_set_context(uuid,uuid,text,jsonb)',"if e.judge_context is distinct from p_context then","if false then",'changed context refused'),('before-paid','photo_quality_check_bind(uuid,uuid,uuid,uuid)',"if e.judge_context is null then","if false then",'missing context refuses binding before provider funding can be used')]:
  original=run('read-'+label,[*psql,'-Atq','-c',f"select pg_get_functiondef('public.{sig}'::regprocedure)"]);assert original.count(anchor)==1
  run('compile-'+label,[*psql,'-Atq'],original.replace(anchor,replacement,1));run('negative-'+label,[*psql,'-Atq'],missing if label=='before-paid'else fixture,refuses=oracle);run('restore-'+label,[*psql,'-Atq'],original)
 receipt['passed']=True
finally:
 if started:run('stop',[tool('pg_ctl'),'-D',data,'-m','immediate','-w','stop'])
 receipt['sourceHashes']={str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest()for f in [SQL/'migrations/20261015041036_photo_quality_judge_context.sql',SQL/'tests/photo_quality_context.sql',Path(__file__).resolve()]};(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');shutil.rmtree(data,ignore_errors=True);shutil.rmtree(sock,ignore_errors=True);print(out/'receipt.json',flush=True)
