#!/usr/bin/env python3
"""Actual local migration/RPC/role tests plus consumable-assignment races.
No inherited credentials, TCP listener, Apple/R2 or production database.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier
import argparse,hashlib,json,os,shutil,subprocess,sys,tempfile
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
sys.path.insert(0,str(ROOT/'tools/audit'))
from run_database_regression import partition_fresh_migrations
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);args=p.parse_args()
OUT=args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-property-jobs-pg-',dir='/tmp'));OUT.mkdir(parents=True,exist_ok=True)
DATA=Path(tempfile.mkdtemp(prefix='rendprop-property-jobs-owned-pg-',dir=OUT));SOCK=Path(tempfile.mkdtemp(prefix='rendprop-property-jobs-socket-',dir='/tmp'))
TOOLS={n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)for n in ['initdb','pg_ctl','psql','createdb']}
assert all(Path(t).is_file()and os.access(t,os.X_OK)for t in TOOLS.values())
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'))
SCHEMA_MIGRATIONS,LIVE_STATE_MIGRATIONS=partition_fresh_migrations(MIGRATIONS)
SOURCES=[*MIGRATIONS,SQL/'tests/ci-bootstrap.sql',SQL/'tests/property_video_jobs.sql',ROOT/'tools/audit/run_database_regression.py',Path(__file__).resolve()]
hashes=lambda:{str(x.relative_to(ROOT)):hashlib.sha256(x.read_bytes()).hexdigest()for x in SOURCES}
receipt={'passed':False,'scope':'owned disposable PostgreSQL, actual schema/RPC/roles/races; transport/provider fixtures closed','networkCalls':0,'AppleCalls':0,'sourceHashes':hashes(),'liveStateOnlyMigrations':[str(p.relative_to(ROOT))for p in LIVE_STATE_MIGRATIONS],'commands':[],'races':[]}
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
 replay_migrations=set((SQL/'migrations').glob('20261014*property_video*.sql'))|set((SQL/'migrations').glob('20261014*registered_background_video_delivery.sql'))|set((SQL/'migrations').glob('20261015*property_video_structural_fallback_cpu_recovery.sql'))|set((SQL/'migrations').glob('20261015*property_video_cpu_retained_recovery_capacity.sql'))|set((SQL/'migrations').glob('20261015*property_video_one_quality_retry.sql'))|set((SQL/'migrations').glob('20261015*property_video_parallel_admission_fair_poll.sql'))|set((SQL/'migrations').glob('20261015*property_video_derived_quality_retry.sql'))|set((SQL/'migrations').glob('20261015*property_video_retained_result_delivery_recovery.sql'))
 for migration in SCHEMA_MIGRATIONS:
  run('apply-'+migration.stem,[*PSQL,'-q','-1','-f',migration])
  # Replay the same coherent historical chain at its final boundary, then
  # apply later migrations. Never replace current recovery wrappers at HEAD.
  if migration==max(replay_migrations):
   for historical in sorted(replay_migrations):run('replay-at-boundary-'+historical.stem,[*PSQL,'-q','-1','-f',historical])
 receipt['historicalReplayAtCoherentBoundary']={'count':len(replay_migrations),'last':max(replay_migrations).name}
 catalog="select jsonb_agg(jsonb_build_object('identity',oid::regprocedure::text,'body',prosrc,'owner',proowner,'acl',proacl::text,'config',proconfig,'security',prosecdef,'volatility',provolatile)order by oid)from pg_proc where pronamespace='public'::regnamespace;"
 current_authority=run('current-authority-before-fixture',[*PSQL,'-Atq','-c',catalog])
 unit=run('actual-jobs-rpc-roles',[*PSQL,'-Atq','-f',SQL/'tests/property_video_jobs.sql']);rows=[json.loads(s)for s in unit.splitlines()if s.startswith('{')and 'assertions'in s];assert len(rows)==1 and rows[0]['passed'];receipt['unit']=rows[0]
 # Compiled actual SQL mutations retain independent failure/category oracles.
 for control,signature,needle,replacement,expected in [
  ('serial-source-admission','public.property_video_job_claim_before_photo_motion_20261021(uuid,text)',"if active>=4", "if exists(select 1 from public.property_video_job_sources where job_id=p_job and state='processing'and clip is null)or active>=4",'accepted first shot doesnotstarve second pending admission'),
  ('poll-position-starvation','public.property_video_job_claim_before_photo_motion_20261021(uuid,text)','order by provider_status_checked_at nulls first,position for update','order by position for update','neverchecked secondreceipt polledbefore firstagain'),
  ('terminal-qc-action','public.property_video_structural_rejection(uuid,uuid)',"or p.qc->>'action'is distinct from'refuse'",'', 'unknown or hold verdict never certifies fallback'),
  ('paid-qc-receipt','public.property_video_structural_rejection(uuid,uuid)',"if q.id is null then return null;end if;",'', 'unpaid or mismatched QC verdict cannot certify fallback'),
  ('retry-null-history-grant','public.property_video_quality_history_guard()',"public.property_video_quality_retry_evidence(old.job_id,old.attempt_id)is null or",'', 'directtable absentgrant cannot append paidretryhistory'),
  ('retry-terminal-journal','public.property_video_quality_retry_evidence(uuid,uuid)',"if c.reservation_id is null then return null;end if;",'', 'missingterminaljournal cannot authorize paid retry'),
  ('no-paid-regeneration','public.property_video_job_resume(uuid,uuid,numeric)',"set state='processing',cpu_recoveries=cpu_recoveries+1","set state='pending',cpu_recoveries=cpu_recoveries+1", 'recovery nextaction is extraction of same paidclip, not provider dispatch')]:
  if control=='no-paid-regeneration':signature='public.property_video_job_resume_before_delivery_20261015(uuid,uuid,numeric)'
  original=run('read-'+control,[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%signature]);assert original.count(needle)==1,(control,'source anchor')
  run('compile-'+control,[*PSQL,'-Atq'],original.replace(needle,replacement,1))
  mutant=subprocess.run([*PSQL,'-Atq','-f',SQL/'tests/property_video_jobs.sql'],env=ENV,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
  (OUT/('negative-'+control+'.log')).write_text(mutant.stdout);assert mutant.returncode!=0 and expected in mutant.stdout,(control,mutant.stdout[-3000:])
  receipt['races'].append({'name':'negative-'+control,'rejected':True,'concreteFailure':expected,'compiledActualSQL':True})
  run('restore-'+control,[*PSQL,'-Atq'],original)
 # Compile the realSQL authority without itsduration predicate. The exact
 # same publicjob fixture must reject that mutant beforea paidshotcanstart.
 signature='public.property_video_job_audio_preflight(uuid,uuid,text,text,numeric,integer)'
 audio_original=run('read-audio-preflight-function',[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%signature]);guard="if p_duration>max_duration+(case when j.manifest->>'source_mode'='photo_motion_v1'then 0 else .1 end)then";assert audio_original.count(guard)==1
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
 run('race-reset',[*PSQL,'-Atq'],"update property_video_job_sources set state='pending',attempt_id=null,lease_token=null,lease_until=null,request_key=null,receipt=null,provider_status_checked_at=null;update property_video_jobs set state='queued';")
 result=race('one-job-two-slot-admission',[claim(jobs[0])for i in range(10)]);assert all(r['exit']==0 for r in result),result
 actions=[json.loads(next(s for s in r['output'].splitlines()if s.startswith('{')))['action']for r in result];assert actions.count('dispatch')==2 and actions.count('wait')==8,actions
 receipt['races'].append({'name':'one-job-two-slot-admission','actualConcurrentRequests':10,'exactlyTwoAdmitted':True})
 # A synthetic accepted supplier transport receipt remains immutable while
 # ten real transactions contend to fill the SECOND existing supplier slot.
 # No network/provider is involved in this scheduler test.
 run('accepted-pending-race-seed',[*PSQL,'-Atq'],"update property_video_job_sources set state='pending',attempt_id=null,lease_token=null,lease_until=null,request_key=null,receipt=null,provider_status_checked_at=null;update property_video_jobs set state='queued';set role service_role;"+claim(jobs[0])+"reset role;update property_video_job_sources set state='processing',receipt=jsonb_build_object('request_id','fixture-scheduling-accepted','model_id','fixture-model'),lease_until=null where job_id='%s'and position=0;"%jobs[0])
 result=race('accepted-first-admits-second',[claim(jobs[0])for i in range(10)]);assert all(r['exit']==0 for r in result),result
 replies=[json.loads(next(s for s in r['output'].splitlines()if s.startswith('{')))for r in result]
 assert [r['action']for r in replies].count('dispatch')==1 and [r['action']for r in replies].count('poll')==1 and [r['action']for r in replies].count('wait')==8,replies
 dispatched=next(r for r in replies if r['action']=='dispatch');assert dispatched['source']['position']==1
 snapshot=run('accepted-pending-race-snapshot',[*PSQL,'-Atq','-c',"select jsonb_build_object('active',count(*)filter(where state in('dispatching','processing','quality_review','ambiguous')),'first_receipt',max(receipt::text)filter(where position=0),'new_attempts',count(*)filter(where attempt_id is not null))from property_video_job_sources where job_id='%s';"%jobs[0]])
 v=json.loads(snapshot.strip());assert v['active']==v['new_attempts']==2 and json.loads(v['first_receipt'])['request_id']=='fixture-scheduling-accepted',v
 receipt['races'].append({'name':'accepted-first-admits-second','actualConcurrentRequests':10,'exactlyOneSecondDispatch':True,'oneAcceptedPollLease':True,'activeSources':2,'priorAcceptedReceiptRetained':True,'providerCalls':0})
 # Once both transports are accepted, concurrent status claims grant exactly
 # one lease per receipt. Holding the job/global locks avoids duplicate polls.
 run('accepted-poll-race-seed',[*PSQL,'-Atq'],"update property_video_job_sources set state='processing',receipt=jsonb_build_object('request_id','fixture-scheduling:'||position,'model_id','fixture-model'),lease_until=null,provider_status_checked_at=null where job_id='%s'and position<2;"%jobs[0])
 result=race('two-accepted-distinct-poll-leases',[claim(jobs[0])for i in range(10)]);assert all(r['exit']==0 for r in result),result
 replies=[json.loads(next(s for s in r['output'].splitlines()if s.startswith('{')))for r in result];polls=[r for r in replies if r['action']=='poll']
 assert len(polls)==2 and sorted(r['source']['position']for r in polls)==[0,1]and sum(r['action']=='wait'for r in replies)==8,replies
 assert len(set(r['source']['lease_token']for r in polls))==2
 receipt['races'].append({'name':'two-accepted-distinct-poll-leases','actualConcurrentRequests':10,'distinctPolls':[0,1],'noDuplicateReceiptLease':True,'providerCalls':0})
 run('negative-reset',[*PSQL,'-Atq'],"update property_video_job_sources set state='pending',attempt_id=null,lease_token=null,lease_until=null,request_key=null,receipt=null,provider_status_checked_at=null;update property_video_jobs set state='queued';")
 sig='public.property_video_job_claim_before_photo_motion_20261021(uuid,text)';original=run('read-claim-function',[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%sig]);lock="perform pg_advisory_xact_lock(hashtextextended('property-video-global-slots',79));";assert lock in original
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
 # Two workers observing the SAME paid terminal decision may both retry the
 # RPC after a lost reply; only one transition archives it and creates pending
 # work. Neither call generates/funds a supplier request itself.
 fixture=(SQL/'tests/property_video_jobs.sql').read_text()
 def helper(start,end):return fixture[fixture.index(start):fixture.index(end)]
 retry_seed="create temporary table bf as select '%s'::uuid actor,org_id org,listing_id listing from property_video_jobs order by operation_id limit 1;grant select on bf to service_role;create temporary table bm as select manifest m from property_video_jobs order by operation_id limit 1;grant select on bm to service_role;"%actor
 retry_seed+=helper('create function pg_temp.paid_clip','create function pg_temp.reject_claim')
 retry_seed+=helper('create function pg_temp.cpu_job','create function pg_temp.exhaust_cpu')
 retry_seed+=helper('create function pg_temp.retry_grant','set local role service_role;\ncreate temporary table retry_case')
 retry_seed+="set role service_role;create temporary table race_quality as select pg_temp.cpu_job(99)c;select pg_temp.retry_grant((select c from race_quality));select c from race_quality;"
 seeded=run('quality-retry-race-seed',[*PSQL,'-Atq'],retry_seed)
 c=json.loads(next(line for line in seeded.splitlines()if line.startswith('{')))
 job=c['job']['id'];source=c['source'];attempt=source['attempt_id'];lease=source['lease_token']
 statement="select property_video_job_quality_retry('%s','%s','%s');"%(job,lease,attempt)
 result=race('same-paid-grant-two-quality-retries',[statement,statement]);assert all(r['exit']==0 for r in result),result
 replies=[json.loads(next(line for line in r['output'].splitlines()if line.startswith('{')))for r in result]
 assert sorted(r['replay']for r in replies)==[False,True]and all(r['retry_scheduled']for r in replies),replies
 snapshot=run('quality-retry-race-snapshot',[*PSQL,'-Atq','-c',"select jsonb_build_object('state',state,'quality_retries',quality_retries,'history_count',jsonb_array_length(quality_retry_history),'prior_attempt',quality_retry_history#>>'{0,prior_source,attempt_id}','prior_receipt',quality_retry_history#>'{0,prior_source,receipt}','new_attempt',attempt_id,'new_receipt',receipt)from property_video_job_sources where job_id='%s'and position=0"%job])
 v=json.loads(snapshot.strip());assert v['state']=='pending'and v['quality_retries']==v['history_count']==1 and v['prior_attempt']==attempt and v['prior_receipt']==source['receipt']and v['new_attempt']is None and v['new_receipt']is None,v
 receipt['races'].append({'name':'same-paid-grant-two-quality-retries','actualConcurrentRequests':2,'exactlyOneTransition':True,'lostReplyAcknowledged':True,'priorPaidReceiptRetained':True,'providerCalls':0})
 assert run('current-authority-after-controls',[*PSQL,'-Atq','-c',catalog])==current_authority,'Current function authority changed during proof'
 receipt['currentRuntimeAndAuthorityPreserved']=True
 assert hashes()==receipt['sourceHashes'],'Source changed during verification';receipt['passed']=True
 print(json.dumps({'passed':True,'assertions':receipt['unit']['assertions'],'races':len(receipt['races']),'receipt':str(OUT/'receipt.json')}))
finally:
 if started:run('stop',[TOOLS['pg_ctl'],'-D',DATA,'-m','immediate','-w','-t','30','stop'])
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
 if not started or receipt['passed']:shutil.rmtree(DATA)
 if SOCK.exists():shutil.rmtree(SOCK)
