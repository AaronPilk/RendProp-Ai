#!/usr/bin/env python3
"""Owned local PostgreSQL package admission, exact replay and concurrency.

No credentials, providers, hosted SQL or network listener. Source changes during
execution invalidate the proof rather than silently relabelling its inputs.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier
import hashlib
import json
import os
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[3]
SQL=ROOT/'services/supabase'
MIGRATION=SQL/'migrations/20261007145527_serving_photo_partitions.sql'
FIXTURE=SQL/'tests/serving_photo_partitions.sql'
TOOLS={n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)for n in('initdb','pg_ctl','psql','createdb')}
if not all(Path(p).is_file()and os.access(p,os.X_OK)for p in TOOLS.values()):raise RuntimeError('Existing PostgreSQL tools required')
OUT=Path(tempfile.mkdtemp(prefix='rendprop-photo-partitions-pg-',dir='/tmp'))
DATA,SOCK=OUT/'data',OUT/'socket';SOCK.mkdir()
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
SOURCES=[*sorted((SQL/'migrations').glob('*.sql')),SQL/'tests/ci-bootstrap.sql',FIXTURE,Path(__file__).resolve()]
receipt={'kind':'owned local PostgreSQL; no network/providers','output':str(OUT),'commands':[],
 'sourceHashes':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in SOURCES}}

def run(name,args,sql=None,refuses=None):
 p=subprocess.run([str(a)for a in args],input=sql,env=ENV,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
 log=OUT/(name+'.log');log.write_text(p.stdout);log.chmod(0o600)
 receipt['commands'].append({'name':name,'exit':p.returncode,'log':str(log),'sha256':hashlib.sha256(log.read_bytes()).hexdigest()})
 if refuses:
  if p.returncode!=3 or refuses not in p.stdout:raise RuntimeError(f'{name}: actual SQL oracle not rejected: {p.stdout[-2000:]}')
 elif p.returncode:raise RuntimeError(f'{name}: {p.stdout[-2000:]}')
 print(name+': pass',flush=True);return p.stdout

def race(name,statements):
 barrier=Barrier(len(statements))
 def invoke(pair):
  i,statement=pair;barrier.wait(timeout=10)
  p=subprocess.run([*psql,'-Atq'],input='set role service_role;'+statement,env=ENV,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=35)
  log=OUT/f'{name}-{i}.log';log.write_text(p.stdout);log.chmod(0o600)
  receipt['commands'].append({'name':f'{name}-{i}','exit':p.returncode,'log':str(log),'sha256':hashlib.sha256(log.read_bytes()).hexdigest()})
  return p.returncode,p.stdout
 with ThreadPoolExecutor(max_workers=len(statements))as pool:return list(pool.map(invoke,enumerate(statements)))

started=False
try:
 receipt['postgresVersion']=run('version',[TOOLS['psql'],'--version']).strip()
 run('initdb',[TOOLS['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[TOOLS['pg_ctl'],'-D',DATA,'-l',OUT/'server.log','-w','-t','30','-o',f"-k {SOCK} -p 55494 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 conn=['-h',SOCK,'-p','55494','-U','postgres']
 run('createdb',[TOOLS['createdb'],*conn,'photo_package_audit'])
 psql=[TOOLS['psql'],'-X','--no-password',*conn,'-d','photo_package_audit','-v','ON_ERROR_STOP=1']
 run('bootstrap',[*psql,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for m in sorted((SQL/'migrations').glob('*.sql')):run('apply-'+m.stem,[*psql,'-q','-1','-f',m])
 receipt['fresh']=run('package-fresh',[*psql,'-Atq','-f',FIXTURE]).strip()
 run('package-migration-replay',[*psql,'-q','-f',MIGRATION])
 receipt['replay']=run('package-replay',[*psql,'-Atq','-f',FIXTURE]).strip()
 pristine=run('guard-definition',[*psql,'-Atq'],"select pg_get_functiondef('public.serving_photo_partition_guard()'::regprocedure);")
 controls=[]
 for name,anchor,oracle in [
  ('other-wallet','if spent+new.hold_cents>p.other_ai_cents then','helper cannot consume protected photo cash'),
  ('photo-count',"if(select count(*)from public.serving_photo_admissions where funding_id=p.funding_id and slice_index=p.slice_index)>=p.photo_cap",'rejected first primary cannot recycle photo admission or borrow helper wallet')
 ]:
  if pristine.count(anchor)!=1:raise RuntimeError('Unapplied guard control '+name)
  run('install-control-'+name,[*psql,'-q'],pristine.replace(anchor,'if false then'if name=='other-wallet'else'if false',1))
  run('removed-guard-'+name,[*psql,'-Atq','-f',FIXTURE],refuses='PACKAGE FAIL expected RP402: '+oracle)
  run('restore-guard-'+name,[*psql,'-q'],pristine)
  controls.append({'removed':name,'exactUnchangedOracle':oracle,'runtimeRejected':True})
 receipt['negativeControls']=controls
 u='e1000000-0000-4000-8000-000000000010';o='e2000000-0000-4000-8000-000000000010'
 run('race-fixture',[*psql,'-q'],f"""
 insert into auth.users(id,email,is_anonymous,email_confirmed_at)values('{u}','package-race@example.invalid',false,now());
 insert into orgs(id,name,plan,plan_source)values('{o}','Synthetic package race','pro','manual');
 insert into memberships(user_id,org_id,role)values('{u}','{o}','owner');
 set role service_role;
 select provision_serving_funding('{o}','retail','synthetic-photo-race',null,400,0,now()-interval '1 minute',now()-interval '1 minute'+interval '1 month',1,
 '{{"storage":0,"delivery":0,"compute":0,"email":0,"support":0,"retention":0,"uncertainty":0}}',repeat('a',64));
 select provision_serving_photo_partition(id,0,1,10,'one-gemini-1k-4096-plus-one-kontext-20261007','published-standard-20261006',repeat('b',64))from serving_funding where org_id='{o}';
 reset role;
 """)
 for name,stage,provider,model,cost in [('last-photo','photo.sky:0','gemini','gemini-3.1-flash-image','31.1296'),('last-other-wallet','coach.chat','anthropic','synthetic','6')]:
  outcomes=race(name,[f"select serving_cost_reserve('{u}','{o}','{name}-key-{i}','{stage}','{provider}','{model}',repeat('a',64),{cost},'published-standard-20261006');"for i in range(2)])
  if sorted(code for code,_ in outcomes)!=[0,3]or not any('RP402:'in output for code,output in outcomes if code==3):raise RuntimeError(name+' failed admission race')
  receipt[name]={'admitted':1,'refused':1,'exits':[code for code,_ in outcomes]}
 ledger=run('race-ledger',[*psql,'-Atq'],f"select (select count(*)from serving_photo_admissions where org_id='{o}'),(select count(*)from serving_cost_reservations where org_id='{o}'),(select sum(hold_cents)from serving_cost_reservations where org_id='{o}');").strip()
 if ledger!='1|2|37.1296':raise RuntimeError('Unexpected race ledger '+ledger)
 receipt['raceLedger']=ledger;receipt['passed']=True
finally:
 if started:run('stop',[TOOLS['pg_ctl'],'-D',DATA,'-m','fast','-w','stop'])
 receipt['sourceUnchanged']=all(hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==h for p,h in receipt['sourceHashes'].items())
 receipt['passed']=receipt.get('passed',False)and receipt['sourceUnchanged']
 target=OUT/'receipt.json';target.write_text(json.dumps(receipt,indent=2)+'\n');target.chmod(0o600)
 print(str(target),flush=True)
