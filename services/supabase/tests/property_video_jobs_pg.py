#!/usr/bin/env python3
"""Actual local migration/RPC/role tests plus consumable-assignment races.
No inherited credentials, TCP listener, Apple/R2 or production database.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier
import argparse,hashlib,json,os,shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);args=p.parse_args()
OUT=args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-property-jobs-pg-',dir='/tmp'));OUT.mkdir(parents=True,exist_ok=True)
DATA=Path(tempfile.mkdtemp(prefix='rendprop-property-jobs-owned-pg-',dir='/tmp'));SOCK=Path(tempfile.mkdtemp(prefix='rendprop-property-jobs-socket-',dir='/tmp'))
TOOLS={n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)for n in ['initdb','pg_ctl','psql','createdb']}
assert all(Path(t).is_file()and os.access(t,os.X_OK)for t in TOOLS.values())
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
SOURCES=[*sorted((SQL/'migrations').glob('*.sql')),SQL/'tests/ci-bootstrap.sql',SQL/'tests/property_video_jobs.sql',Path(__file__).resolve()]
hashes=lambda:{str(x.relative_to(ROOT)):hashlib.sha256(x.read_bytes()).hexdigest()for x in SOURCES}
receipt={'passed':False,'scope':'owned disposable PostgreSQL, actual schema/RPC/roles/races; transport/provider fixtures closed','networkCalls':0,'AppleCalls':0,'sourceHashes':hashes(),'commands':[],'races':[]}
def run(name,argv,sql=None):
 r=subprocess.run([str(a)for a in argv],input=sql,env=ENV,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
 (OUT/(name+'.log')).write_text(r.stdout);receipt['commands'].append({'name':name,'exit':r.returncode,'logSHA256':hashlib.sha256(r.stdout.encode()).hexdigest()})
 assert r.returncode==0,(name,r.stdout[-3000:]);return r.stdout
def race(name,statements,role="service_role"):
 barrier=Barrier(len(statements))
 def invoke(pair):
  i,statement=pair;barrier.wait(timeout=10)
  r=subprocess.run([*PSQL,'-Atq'],input=f'set role {role};'+statement,env=ENV,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
  (OUT/f'{name}-{i}.log').write_text(r.stdout);return {'exit':r.returncode,'output':r.stdout}
 with ThreadPoolExecutor(max_workers=len(statements))as pool:return list(pool.map(invoke,enumerate(statements)))
started=False
try:
 run('version',[TOOLS['psql'],'--version']);run('initdb',[TOOLS['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[TOOLS['pg_ctl'],'-D',DATA,'-l',OUT/'postgres.log','-w','-t','30','-o',f"-k {SOCK} -p 55537 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 conn=['-h',SOCK,'-p','55537','-U','postgres'];run('createdb',[TOOLS['createdb'],*conn,'property_sites'])
 PSQL=[TOOLS['psql'],'-X','--no-password',*conn,'-d','property_sites','-v','ON_ERROR_STOP=1']
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for migration in sorted((SQL/'migrations').glob('*.sql')):run('apply-'+migration.stem,[*PSQL,'-q','-1','-f',migration])
 for newest in sorted(set((SQL/'migrations').glob('20261014*property_video*.sql'))|set((SQL/'migrations').glob('20261014*registered_background_video_delivery.sql'))|set((SQL/'migrations').glob('20261015*property_video_structural_fallback_cpu_recovery.sql'))):run('replay-'+newest.stem,[*PSQL,'-q','-1','-f',newest])
 unit=run('actual-jobs-rpc-roles',[*PSQL,'-Atq','-f',SQL/'tests/property_video_jobs.sql']);rows=[json.loads(s)for s in unit.splitlines()if s.startswith('{')and 'assertions'in s];assert len(rows)==1 and rows[0]['passed'];receipt['unit']=rows[0]
 # Compiled actual SQL mutations retain independent failure/category oracles.
 for control,signature,needle,replacement,expected in [
  ('terminal-qc-action','public.property_video_structural_rejection(uuid,uuid)',"or p.qc->>'action'is distinct from'refuse'",'', 'unknown or hold verdict never certifies fallback'),
  ('paid-qc-receipt','public.property_video_structural_rejection(uuid,uuid)',"if q.id is null then return null;end if;",'', 'unpaid or mismatched QC verdict cannot certify fallback'),
  ('no-paid-regeneration','public.property_video_job_resume(uuid,uuid,numeric)',"set state='processing',cpu_recoveries=cpu_recoveries+1","set state='pending',cpu_recoveries=cpu_recoveries+1", 'recovery nextaction is extraction of same paidclip, not provider dispatch')]:
  original=run('read-'+control,[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%signature]);assert original.count(needle)==1,(control,'source anchor')
  run('compile-'+control,[*PSQL,'-Atq'],original.replace(needle,replacement,1))
  mutant=subprocess.run([*PSQL,'-Atq','-f',SQL/'tests/property_video_jobs.sql'],env=ENV,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
  (OUT/('negative-'+control+'.log')).write_text(mutant.stdout);assert mutant.returncode!=0 and expected in mutant.stdout,(control,mutant.stdout[-3000:])
  receipt['races'].append({'name':'negative-'+control,'rejected':True,'concreteFailure':expected,'compiledActualSQL':True})
  run('restore-'+control,[*PSQL,'-Atq'],original)
 # Compile the realSQL authority without itsduration predicate. The exact
 # same publicjob fixture must reject that mutant beforea paidshotcanstart.
 signature='public.property_video_job_audio_preflight(uuid,uuid,text,text,numeric,integer)'
 audio_original=run('read-audio-preflight-function',[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%signature]);guard='if p_duration>max_duration+.1 then';assert audio_original.count(guard)==1
 run('install-no-audio-duration-guard',[*PSQL,'-Atq'],audio_original.replace(guard,'if false then'))
 mutant=subprocess.run([*PSQL,'-Atq','-f',SQL/'tests/property_video_jobs.sql'],env=ENV,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
 (OUT/'negative-audio-duration.log').write_text(mutant.stdout);assert mutant.returncode!=0 and'20svoice on2photo10svideo refusesbefore anypaidclip'in mutant.stdout
 receipt['races'].append({'name':'negative-no-audio-duration-guard','rejected':True,'concreteFailure':'20-second voice approved for10-second video beforegeneration'})
 run('restore-audio-preflight-function',[*PSQL,'-Atq'],audio_original)
 seed=(SQL/'tests/property_video_jobs.sql').read_text();seed=seed[seed.index('insert into auth.users'):seed.index("select pg_temp.ok((select bool_and")];seed=seed.replace('grant select on bf','grant select on bf').replace('set local ','set ')
 run('race-fixtures',[*PSQL,'-Atq'],seed+"update app_config set value=jsonb_set(value,'{enabled}','true')where key='property_video_jobs';set role service_role;"+''.join("select property_video_job_enqueue((select actor from bf),jsonb_set((select m from bm),'{operation_id}',to_jsonb('f2700000-0000-4000-8000-%012d'::text)));"%i for i in range(1,11)))
 # A capacity refusal and a simultaneous accepting request share exactly one
 # operation lock: either one acceptedjob or one durableclosedrefusal, neverboth.
 op='f2700000-0000-4000-8000-000000000050';actor='f1100000-0000-4000-8000-000000000001'
 manifest="jsonb_set((select manifest from property_video_jobs order by operation_id limit 1),'{operation_id}',to_jsonb('%s'::text))"%op
 result=race('capacity-refusal-versus-enqueue',["select property_video_job_admit('%s',%s,1000000);"%(actor,manifest),"select property_video_job_enqueue('%s',%s);"%(actor,manifest)])
 counts=run('capacity-operation-count',[*PSQL,'-Atq','-c',"select(select count(*)from property_video_jobs where operation_id='%s')+(select count(*)from property_video_refused_operations where operation_id='%s');"%(op,op)]).strip();assert counts=='1',result
 receipt['races'].append({'name':'capacity-refusal-versus-enqueue','actualConcurrentRequests':2,'exactlyOneTerminalAdmissionOutcome':True})
 run('capacity-race-cleanup',[*PSQL,'-Atq'],"delete from property_video_jobs where operation_id='%s';delete from property_video_refused_operations where operation_id='%s';"%(op,op))
 jobs=run('race-jobs',[*PSQL,'-Atq','-c',"select id from property_video_jobs order by operation_id"]).strip().splitlines();assert len(jobs)==10
 def claim(j):return "select property_video_job_claim('%s','slot-0');"%j
 result=race('global-four-slot-admission',[claim(j)for j in jobs]);assert all(r['exit']==0 for r in result),result
 actions=[json.loads(next(s for s in r['output'].splitlines()if s.startswith('{')))['action']for r in result];assert actions.count('dispatch')==4 and actions.count('wait')==6,actions
 receipt['races'].append({'name':'global-four-slot-admission','actualConcurrentRequests':10,'exactlyFourAdmitted':True})
 run('race-reset',[*PSQL,'-Atq'],"update property_video_job_sources set state='pending',attempt_id=null,lease_token=null,lease_until=null,request_key=null;update property_video_jobs set state='queued';")
 result=race('one-job-two-slot-admission',[claim(jobs[0])for i in range(10)]);assert all(r['exit']==0 for r in result),result
 actions=[json.loads(next(s for s in r['output'].splitlines()if s.startswith('{')))['action']for r in result];assert actions.count('dispatch')==2 and actions.count('wait')==8,actions
 receipt['races'].append({'name':'one-job-two-slot-admission','actualConcurrentRequests':10,'exactlyTwoAdmitted':True})
 run('negative-reset',[*PSQL,'-Atq'],"update property_video_job_sources set state='pending',attempt_id=null,lease_token=null,lease_until=null,request_key=null;update property_video_jobs set state='queued';")
 sig='public.property_video_job_claim(uuid,text)';original=run('read-claim-function',[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%sig]);lock="perform pg_advisory_xact_lock(hashtextextended('property-video-global-slots',79));";assert lock in original
 mutant=original.replace(lock,'-- omitted global slot lock',1);needle="if active>=4";assert needle in mutant;mutant=mutant.replace(needle,"perform pg_sleep(0.4);\n if active>=4",1);run('install-no-slot-lock',[*PSQL,'-Atq'],mutant)
 result=race('negative-no-global-slot-lock',[claim(j)for j in jobs]);assert all(r['exit']==0 for r in result),result
 actions=[json.loads(next(s for s in r['output'].splitlines()if s.startswith('{')))['action']for r in result];assert actions.count('dispatch')>4,actions
 receipt['races'].append({'name':'negative-no-global-slot-lock','rejected':True,'overAdmitted':actions.count('dispatch'),'concreteFailure':'concurrent distinct jobs exceeded global supplier admission'})
 run('restore-claim-function',[*PSQL,'-Atq'],original)
 # Actual cancel/dispatch locks race; the winning stop prevents later grants.
 stop="select property_video_job_cancel_all('f1100000-0000-4000-8000-000000000001','f2800000-0000-4000-8000-000000000001','ai_consent_revoked');"
 result=race('cancel-all-versus-claim',[stop,claim(jobs[-1])]);assert result[0]['exit']==0,result
 assert run('cancelled-after-race',[*PSQL,'-Atq','-c',"select count(*)from property_video_jobs where state='cancelled'"]).strip()=='10'
 result=race('post-cancel-claim',[claim(jobs[-1])]);assert result[0]['exit']!=0 and'RP409:'in result[0]['output'],result
 receipt['races'].append({'name':'cancel-all-versus-claim','allActorJobsStopped':True,'futureDispatchRefused':True})
 assert hashes()==receipt['sourceHashes'],'Source changed during verification';receipt['passed']=True
 print(json.dumps({'passed':True,'assertions':receipt['unit']['assertions'],'races':len(receipt['races']),'receipt':str(OUT/'receipt.json')}))
finally:
 if started:run('stop',[TOOLS['pg_ctl'],'-D',DATA,'-m','immediate','-w','-t','30','stop'])
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
 if not started or receipt['passed']:shutil.rmtree(DATA)
 if SOCK.exists():shutil.rmtree(SOCK)
