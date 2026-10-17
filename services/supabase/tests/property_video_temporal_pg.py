#!/usr/bin/env python3
"""Actual isolated PG proof of recorded temporal motion verdicts: migration
replay at its boundary, closed report shape, clip/lease identity, first
measurement wins, immutability/archiving, no paid-retry grant, and the
concurrent first-write race. No production connection, media, model or network.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier
import argparse,hashlib,json,os,shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);args=p.parse_args()
OUT=args.evidence_dir or Path(tempfile.mkdtemp(prefix='temporal-verdict-proof-'));OUT.mkdir(parents=True,exist_ok=True)
assert shutil.disk_usage(ROOT).free>=3*1024**3,'Preserve internal3GiB reserve'
DATA=Path(tempfile.mkdtemp(prefix='temporal-verdict-owned-pg-',dir='/Volumes/Rendprop Files/Builds/Active' if Path('/Volumes/Rendprop Files/Builds/Active').is_dir()else None));SOCK=Path(tempfile.mkdtemp(prefix='temporal-verdict-socket-',dir='/tmp'))
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
tool=lambda n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)
MIG=SQL/'migrations/20261017120000_property_video_temporal_verdict.sql';FIX=SQL/'tests/property_video_temporal.sql';BASE=SQL/'tests/property_video_jobs.sql'
MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'));SOURCES=[*MIGRATIONS,SQL/'tests/ci-bootstrap.sql',BASE,FIX,SQL/'tests/property_video_derived_retry.sql',Path(__file__).resolve()]
hashes=lambda:{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest()for f in SOURCES}
receipt={'passed':False,'scope':'disposable actual PostgreSQL/schema/roles/concurrency, synthetic receipts only','networkCalls':0,'providerCalls':0,'sourceHashes':hashes(),'commands':[],'controls':[],'races':[]}
started=False
def run(name,cmd,body=None,refuses=None):
 r=subprocess.run([str(x)for x in cmd],input=body,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
 (OUT/(name+'.log')).write_text(r.stdout);receipt['commands'].append({'name':name,'exit':r.returncode,'logSHA256':hashlib.sha256(r.stdout.encode()).hexdigest()})
 assert(r.returncode and refuses in r.stdout)if refuses else r.returncode==0,(name,r.stdout[-6000:]);return r.stdout
def race(name,bodies):
 barrier=Barrier(len(bodies))
 def call(pair):
  i,body=pair;barrier.wait(timeout=10)
  r=subprocess.run([*PSQL,'-Atq'],input='set role service_role;'+body,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
  (OUT/f'{name}-{i}.log').write_text(r.stdout);return{'exit':r.returncode,'output':r.stdout}
 with ThreadPoolExecutor(max_workers=len(bodies))as pool:return list(pool.map(call,enumerate(bodies)))
base=BASE.read_text();seed=base[base.index('insert into auth.users'):base.index('select pg_temp.ok((select bool_and')];helpers=base[base.index('create function pg_temp.paid_clip'):base.index('insert into auth.users')]
fixture='begin;\n'+FIX.read_text()[:FIX.read_text().index('create function pg_temp.recipe')]+helpers+'\n'+seed+'\n'+FIX.read_text()[FIX.read_text().index('create function pg_temp.recipe'):]
try:
 run('initdb',[tool('initdb'),'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[tool('pg_ctl'),'-D',DATA,'-l',OUT/'postgres.log','-w','-o',f"-k {SOCK} -p 55633 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 conn=['-h',SOCK,'-p','55633','-U','postgres'];run('createdb',[tool('createdb'),*conn,'temporal_verdict_proof'])
 PSQL=[tool('psql'),'-X','--no-password',*conn,'-d','temporal_verdict_proof','-v','ON_ERROR_STOP=1']
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 catalog="select md5(string_agg(oid::text||':'||prosrc||':'||coalesce(proacl::text,''),E'\\n'order by oid))||':'||(select md5(string_agg(conrelid::regclass||':'||conname||':'||pg_get_constraintdef(oid),E'\\n'order by conrelid::regclass::text,conname))from pg_constraint where connamespace='public'::regnamespace)||':'||(select md5(string_agg(tgrelid::regclass||':'||tgname,E'\\n'order by tgrelid::regclass::text,tgname))from pg_trigger where not tgisinternal)from pg_proc where pronamespace='public'::regnamespace"
 for m in MIGRATIONS:
  run('apply-'+m.stem,[*PSQL,'-q','-1','-f',m])
  if m==MIG:
   before=run('catalog-after-own',[*PSQL,'-Atq','-c',catalog])
   run('replay-at-own-boundary',[*PSQL,'-q','-1','-f',MIG])
   assert run('catalog-after-own-replay',[*PSQL,'-Atq','-c',catalog])==before,'Own replay must be a no-op on functions, constraints, grants and triggers'
   out=run('own-boundary-fixture',[*PSQL,'-Atq'],fixture);receipt['ownBoundary']=next(json.loads(x)for x in out.splitlines()if x.startswith('{')and'assertions'in x)
 head=run('catalog-head',[*PSQL,'-Atq','-c',catalog])
 run('replay-at-head',[*PSQL,'-q','-1','-f',MIG]);assert run('catalog-head-after-replay',[*PSQL,'-Atq','-c',catalog])==head,'Head replay must be a no-op';receipt['headReplay']={'noop':True}
 for stage in ['fresh','replay']:
  out=run(stage+'-actual-temporal',[*PSQL,'-Atq'],fixture);rows=[json.loads(x)for x in out.splitlines()if x.startswith('{')and'assertions'in x];assert len(rows)==1 and rows[0]['passed'];receipt[stage]=rows[0]
 # The existing paid-retry and background-job authority is untouched by the new column, trigger and RPC.
 baseline=run('existing-derived-retry',[*PSQL,'-Atq','-f',SQL/'tests/property_video_derived_retry.sql']);receipt['existingDerivedRetryRegression']=next(json.loads(x)for x in baseline.splitlines()if x.startswith('{')and'assertions'in x)
 for label,signature,anchor,replacement,oracle in [
  ('clip-identity','public.property_video_job_temporal(uuid,uuid,uuid,text,jsonb)',"or p_clip_sha256 is distinct from s.clip->>'sha256'",'','wrong clip sha refused'),
  ('first-wins','public.property_video_job_temporal(uuid,uuid,uuid,text,jsonb)',"and s.temporal#>>'{limits,sha256}'=p_report#>>'{limits,sha256}'then return s.temporal;end if;","and false then return s.temporal;end if;",'first recorded verdict wins'),
  ('immutable','public.property_video_temporal_guard()',"raise exception'RP409: A recorded temporal verdict is immutable'",'return new','direct edit of a recorded verdict refused')]:
  original=run('read-'+label,[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%signature]);assert original.count(anchor)==1,(label,'exact production anchor')
  run('compile-'+label,[*PSQL,'-Atq'],original.replace(anchor,replacement,1));run('negative-'+label,[*PSQL,'-Atq'],fixture,refuses=oracle);run('restore-'+label,[*PSQL,'-Atq'],original)
  receipt['controls'].append({'name':label,'compiledActualSQL':True,'unsafeMutationRejected':True})
 assert run('catalog-after-controls',[*PSQL,'-Atq','-c',catalog])==head,'Control restoration must preserve the head catalog'
 # Race: two first writes with different reports for the same live attempt. One record, both callers get it.
 setup=fixture[:fixture.index('-- Closed report shape and clip identity.')].replace('set local ','set ')
 setup+="reset role;create table public.temporal_race as select job,lease,attempt from rv_ids;grant select on public.temporal_race to service_role;commit;"
 run('race-setup',[*PSQL,'-Atq'],setup)
 statement=lambda reasons:"select (property_video_job_temporal(job,lease,attempt,repeat('e',64),pg_temp.report('{%s}')))->'verdict' from public.temporal_race;".replace('pg_temp.report','public.temporal_race_report')%reasons
 run('race-report-helper',[*PSQL,'-Atq'],"create or replace function public.temporal_race_report(reasons text[])returns jsonb language sql as $$select jsonb_build_object('profile','temporal-motion-v2','limits',jsonb_build_object('profile','temporal-motion-v2','sha256',repeat('1',64)),'metrics',jsonb_build_object('profile','temporal-motion-v2','fps',24),'verdict',jsonb_build_object('profile','temporal-motion-v2','pass',cardinality(reasons)=0,'reasons',to_jsonb(reasons)))$$;grant execute on function public.temporal_race_report(text[])to service_role;")
 results=race('same-attempt-first-write',[statement('vertical_bob'),statement('')]);assert all(x['exit']==0 for x in results),results
 verdicts={x['output'].strip()for x in results};assert len(verdicts)==1,('both callers must read the one recorded verdict',results)
 stored=run('race-stored',[*PSQL,'-Atq','-c',"select (temporal->'verdict')::text||':'||jsonb_array_length(temporal_history) from property_video_job_sources s join public.temporal_race r on s.job_id=r.job and s.attempt_id=r.attempt;"]).strip()
 assert stored.split(':')[-1]=='0' and stored.rsplit(':',1)[0]==next(iter(verdicts)),stored
 receipt['races'].append({'name':'same-attempt-first-write','requests':2,'oneRecord':True,'archived':0,'supplierPOSTs':0})
 assert hashes()==receipt['sourceHashes'],'Source changed during proof';receipt['passed']=True
 print(json.dumps({'passed':True,'freshAssertions':receipt['fresh']['assertions'],'replayAssertions':receipt['replay']['assertions'],'controls':len(receipt['controls']),'races':len(receipt['races']),'receipt':str(OUT/'receipt.json')}))
finally:
 if started:run('stop',[tool('pg_ctl'),'-D',DATA,'-m','immediate','-w','stop'])
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
 if not started or not (DATA/'postmaster.pid').exists():shutil.rmtree(DATA)
 if SOCK.exists():shutil.rmtree(SOCK)
