#!/usr/bin/env python3
"""C2: discarding a saved video operation the server never accepted.
Actual migrations/RPCs/triggers/roles in an owned socket-only PostgreSQL,
real concurrent sessions for discard/enqueue/admission races, held-lock
interleavings, and compiled negative controls of the real SQL.
No inherited credentials, TCP listener, network, provider, Apple or production.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from fresh_schema_migrations import partition_fresh_migrations
from threading import Barrier
import argparse,hashlib,json,os,shutil,subprocess,tempfile,time
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
TEST=SQL/'tests/property_video_abandon.sql';MIGRATION=next((SQL/'migrations').glob('*_property_video_operation_abandon.sql'))
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);args=p.parse_args()
OUT=args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-video-abandon-pg-',dir='/tmp'));OUT.mkdir(parents=True,exist_ok=True)
DATA=Path(tempfile.mkdtemp(prefix='rendprop-video-abandon-owned-pg-',dir=os.environ.get('RENDPROP_PG_DATA_ROOT','/tmp')));SOCK=Path(tempfile.mkdtemp(prefix='rendprop-video-abandon-socket-',dir='/tmp'))
TOOLS={n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)for n in ['initdb','pg_ctl','psql','createdb']}
assert all(Path(t).is_file()and os.access(t,os.X_OK)for t in TOOLS.values())
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'))
SCHEMA_MIGRATIONS,LIVE_STATE_MIGRATIONS=partition_fresh_migrations(MIGRATIONS)
SOURCES=[*MIGRATIONS,SQL/'tests/ci-bootstrap.sql',TEST,Path(__file__).resolve()]
hashes=lambda:{str(x.relative_to(ROOT)):hashlib.sha256(x.read_bytes()).hexdigest()for x in SOURCES}
receipt={'passed':False,'scope':'owned disposable PostgreSQL; actual schema/RPC/trigger/roles and concurrent sessions; no transport','networkCalls':0,'providerCalls':0,'AppleCalls':0,'sourceHashes':hashes(),'liveStateOnlyMigrations':[m.name for m in LIVE_STATE_MIGRATIONS],'commands':[],'races':[],'negativeControls':[]}
DISCARDED='RP409: This saved video request was discarded'
def run(name,argv,sql=None,expect=0):
 r=subprocess.run([str(a)for a in argv],input=sql,env=ENV,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
 (OUT/(name+'.log')).write_text(r.stdout);receipt['commands'].append({'name':name,'exit':r.returncode,'logSHA256':hashlib.sha256(r.stdout.encode()).hexdigest()})
 assert(r.returncode==0)if expect==0 else(r.returncode!=0),(name,r.returncode,r.stdout[-3000:]);return r.stdout
def race(name,statements,role='service_role'):
 barrier=Barrier(len(statements))
 def invoke(pair):
  i,statement=pair;barrier.wait(timeout=20);start=time.monotonic()
  r=subprocess.run([*PSQL,'-Atq'],input=f'set role {role};\n'+statement,env=ENV,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
  (OUT/f'{name}-{i}.log').write_text(r.stdout);return{'exit':r.returncode,'output':r.stdout,'seconds':round(time.monotonic()-start,3)}
 with ThreadPoolExecutor(max_workers=len(statements))as pool:return list(pool.map(invoke,enumerate(statements)))
def first_json(output):return json.loads(next(s for s in output.splitlines()if s.startswith('{')))
started=False
try:
 run('version',[TOOLS['psql'],'--version']);run('initdb',[TOOLS['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[TOOLS['pg_ctl'],'-D',DATA,'-l',OUT/'postgres.log','-w','-t','30','-o',f"-k {SOCK} -p 55543 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 conn=['-h',SOCK,'-p','55543','-U','postgres'];run('createdb',[TOOLS['createdb'],*conn,'property_video_abandon'])
 PSQL=[TOOLS['psql'],'-X','--no-password',*conn,'-d','property_video_abandon','-v','ON_ERROR_STOP=1']
 def psql(name,sql,expect=0):return run(name,[*PSQL,'-Atq'],sql,expect)
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for migration in SCHEMA_MIGRATIONS:run('apply-'+migration.stem,[*PSQL,'-q','-1','-f',migration])
 run('replay-'+MIGRATION.stem,[*PSQL,'-q','-1','-f',MIGRATION])  # reviewed migrations must replay cleanly
 def unit(name):
  out=run(name,[*PSQL,'-Atq','-f',TEST]);rows=[json.loads(s)for s in out.splitlines()if s.startswith('{')and'assertions'in s];assert len(rows)==1 and rows[0]['passed'];return rows[0]
 receipt['unit']=unit('actual-abandon-rpc-roles')

 # Compiled actual SQL mutants: the unchanged sequential test must name the
 # exact broken guarantee, then the restored definition must pass again.
 for control,signature,needle,replacement,expected in [
  ('no-discard-fence','public.property_video_operation_open()','if exists(select 1 from public.property_video_abandoned_operations where actor_id=new.actor_id and operation_id=new.operation_id)then','if false then','ABANDON FAIL: allowed delayed enqueue after abandonment is refused'),
  ('lookup-ignores-discard','public.property_video_operation_lookup(uuid,uuid,uuid,uuid)',"'operation_closed',r.operation_id is not null or a.operation_id is not null","'operation_closed',r.operation_id is not null",'ABANDON FAIL: lookup reports the same durable abandonment'),
  ('discard-cancels-accepted-job','public.property_video_operation_abandon(uuid,uuid,uuid,uuid)','if j.id is null and r.operation_id is null and a.operation_id is null then',"if j.id is not null then update public.property_video_jobs set state='cancelled',cancelled_at=now()where id=j.id;end if;\n if j.id is null and r.operation_id is null and a.operation_id is null then",'ABANDON FAIL: accepted job is retained, not cancelled or tombstoned')]:
  original=run('read-'+control,[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%signature]);assert original.count(needle)==1,(control,'source anchor')
  run('compile-'+control,[*PSQL,'-Atq'],original.replace(needle,replacement,1))
  mutant=run('negative-'+control,[*PSQL,'-Atq','-f',TEST],expect=1);assert expected in mutant,(control,mutant[-3000:])
  receipt['negativeControls'].append({'name':control,'rejected':True,'concreteFailure':expected,'compiledActualSQL':True})
  run('restore-'+control,[*PSQL,'-Atq'],original)
 receipt['unitAfterRestore']=unit('actual-abandon-rpc-roles-restored')

 # Commit the exact fixture section for separate concurrent sessions.
 text=TEST.read_text();seed=text[text.index('-- fixture:begin'):text.index('-- fixture:end')]
 psql('race-fixture',seed)
 ident=json.loads(psql('race-identity',"select jsonb_build_object('actor',actor,'listing',listing,'org',org)from abandon_bf;").strip());A,L,O=ident['actor'],ident['listing'],ident['org']
 def op(group,i):return 'f29%02d000-0000-4000-8000-%012d'%(group,i)
 def recipe(o):return "jsonb_set((select m from abandon_bm),'{operation_id}',to_jsonb('%s'::text))"%o
 def abandon(o):return "select property_video_operation_abandon('%s','%s','%s','%s');"%(A,L,O,o)
 def enqueue(o):return "select jsonb_build_object('job_id',(property_video_job_enqueue('%s',%s)).id);"%(A,recipe(o))
 def admit(o,quote):return "select property_video_job_admit('%s',%s,%s,'legacy');"%(A,recipe(o),quote)
 def state(o):return json.loads(psql('state-'+o,"select jsonb_build_object('jobs',(select count(*)from property_video_jobs where operation_id='%s'),'tombstones',(select count(*)from property_video_abandoned_operations where operation_id='%s'),'refusals',(select count(*)from property_video_refused_operations where operation_id='%s'),'job_id',(select id from property_video_jobs where operation_id='%s'),'job_state',(select state from property_video_jobs where operation_id='%s'));"%(o,o,o,o,o)).strip())
 def discarded(r):return r['exit']!=0 and DISCARDED in r['output']

 # 1. Discard versus direct enqueue and funded admission: one outcome only.
 for group,name,contender in[(1,'discard-versus-enqueue',lambda o:enqueue(o)),(2,'discard-versus-funded-admission',lambda o:admit(o,30))]:
  winners={'job':0,'discard':0}
  for i in range(1,17):
   # Even rounds stagger the contender by 50ms so both winners are exercised.
   o=op(group,i);result=race(f'{name}-{i}',[abandon(o),('select pg_sleep(0.05);'if i%2==0 else'')+contender(o)]);s=state(o)
   assert result[0]['exit']==0 and s['refusals']==0 and s['jobs']+s['tombstones']==1,(name,o,s,result)
   reply=first_json(result[0]['output'])
   if s['jobs']==1:
    assert result[1]['exit']==0 and reply['job_id']==s['job_id']and reply['operation_closed']is False and reply['closed_reason']is None and s['job_state']=='queued',(name,o,s,result);winners['job']+=1
   else:
    assert discarded(result[1])and reply['closed_reason']=='abandoned'and reply['job_id']is None,(name,o,s,result);winners['discard']+=1
  receipt['races'].append({'name':name,'rounds':16,'actualConcurrentRequests':2,'outcomes':winners,'exactlyOneOutcomePerOperation':True,'acceptedJobsReturnedNotCancelled':True})

 # 2. Discard versus a capacity refusal: one durable closure, correctly named.
 winners={'capacity_refused':0,'discard':0}
 for i in range(1,9):
  o=op(3,i);result=race(f'discard-versus-capacity-refusal-{i}',[abandon(o),('select pg_sleep(0.05);'if i%2==0 else'')+admit(o,9000000)]);s=state(o)
  assert result[0]['exit']==0 and s['jobs']==0 and s['refusals']+s['tombstones']==1,(o,s,result);reply=first_json(result[0]['output'])
  if s['refusals']==1:assert result[1]['exit']==0 and first_json(result[1]['output'])['operation_closed']is True and reply['closed_reason']=='capacity_refused',(o,s,result);winners['capacity_refused']+=1
  else:assert discarded(result[1])and reply['closed_reason']=='abandoned',(o,s,result);winners['discard']+=1
 receipt['races'].append({'name':'discard-versus-capacity-refusal','rounds':8,'actualConcurrentRequests':2,'outcomes':winners,'exactlyOneClosure':True})

 # 3. Lost discard replies retried concurrently: one tombstone, one answer.
 o=op(4,1);result=race('concurrent-discard-replays',[abandon(o)for _ in range(6)]);s=state(o)
 assert all(r['exit']==0 for r in result)and len({json.dumps(first_json(r['output']),sort_keys=True)for r in result})==1 and s['tombstones']==1 and s['jobs']==0,(s,result)
 receipt['races'].append({'name':'concurrent-discard-replays','actualConcurrentRequests':6,'oneTombstone':True,'identicalReplies':True})

 # 4. Deterministic held-lock interleavings in both orders.
 o=op(5,1);result=race('discard-commits-while-enqueue-waits',['begin;'+abandon(o)+'select pg_sleep(1.5);commit;','select pg_sleep(0.4);'+enqueue(o)]);s=state(o)
 assert result[0]['exit']==0 and discarded(result[1])and result[1]['seconds']>=1.2 and s['jobs']==0 and s['tombstones']==1,(s,result)
 receipt['races'].append({'name':'discard-commits-while-enqueue-waits','enqueueWaitedSeconds':result[1]['seconds'],'delayedEnqueueRefused':True})
 o=op(5,2);result=race('discard-commits-while-admission-waits',['begin;'+abandon(o)+'select pg_sleep(1.5);commit;','select pg_sleep(0.4);'+admit(o,30)]);s=state(o)
 assert result[0]['exit']==0 and discarded(result[1])and result[1]['seconds']>=1.2 and s['jobs']==0 and s['tombstones']==1 and s['refusals']==0,(s,result)
 receipt['races'].append({'name':'discard-commits-while-admission-waits','admissionWaitedSeconds':result[1]['seconds'],'delayedAdmissionRefused':True})
 for n,(name,holder)in enumerate([('enqueue-commits-while-discard-waits',enqueue),('admission-commits-while-discard-waits',lambda o:admit(o,30))],3):
  o=op(5,n);result=race(name,['begin;'+holder(o)+'select pg_sleep(1.5);commit;','select pg_sleep(0.4);'+abandon(o)]);s=state(o);reply=first_json(result[1]['output'])
  assert result[0]['exit']==0 and result[1]['exit']==0 and result[1]['seconds']>=1.2 and s['jobs']==1 and s['tombstones']==0 and reply['job_id']==s['job_id']and reply['operation_closed']is False and s['job_state']=='queued',(s,result)
  receipt['races'].append({'name':name,'discardWaitedSeconds':result[1]['seconds'],'acceptedJobReturned':True,'jobNotCancelled':True})

 # 5. Read-committed is required: an older snapshot fails closed.
 o=op(6,1);r=race('discard-repeatable-read-refused',['begin isolation level repeatable read;'+abandon(o)+'commit;'])[0]
 assert r['exit']!=0 and'RP503:'in r['output']and state(o)['tombstones']==0,r
 o=op(6,2);r=race('enqueue-serializable-refused',['begin isolation level serializable;'+enqueue(o)+'commit;'])[0]
 assert r['exit']!=0 and'RP503:'in r['output']and state(o)['jobs']==0,r
 stale=lambda o:['begin isolation level repeatable read;select count(*)from property_video_jobs;select pg_sleep(1);'+enqueue(o)+'commit;','select pg_sleep(0.3);'+abandon(o)]
 o=op(6,3);result=race('stale-snapshot-enqueue-after-discard',stale(o));s=state(o)
 assert result[1]['exit']==0 and result[0]['exit']!=0 and'RP503:'in result[0]['output']and s['jobs']==0 and s['tombstones']==1,(s,result)
 receipt['races'].append({'name':'stale-snapshot-enqueue-after-discard','repeatableReadRefused':True,'serializableRefused':True,'tombstoneOnly':True})

 # 6. Compiled race mutants prove the lock and isolation guards are load-bearing.
 def mutate(name,signature,edits):
  original=run('read-'+name,[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%signature]);mutant=original
  for needle,replacement in edits:assert mutant.count(needle)==1,(name,needle);mutant=mutant.replace(needle,replacement,1)
  run('compile-'+name,[*PSQL,'-Atq'],mutant);return original
 sig='public.property_video_operation_abandon(uuid,uuid,uuid,uuid)'
 original=mutate('no-discard-lock',sig,[("perform pg_advisory_xact_lock(hashtextextended('property-video-operation:'||p_actor||':'||p_operation,79));",''),('if j.id is null and r.operation_id is null and a.operation_id is null then','perform pg_sleep(0.6);\n if j.id is null and r.operation_id is null and a.operation_id is null then')])
 o=op(7,1);result=race('negative-no-discard-lock',[abandon(o),'select pg_sleep(0.2);'+enqueue(o)]);s=state(o)
 assert s['jobs']==1 and s['tombstones']==1,('lock mutant was not detected',s,result)
 receipt['negativeControls'].append({'name':'no-discard-lock','rejected':True,'concreteFailure':'unlocked discard tombstoned an operation that already had an accepted job','observed':s})
 run('restore-no-discard-lock',[*PSQL,'-Atq'],original)
 original=mutate('no-trigger-isolation-guard','public.property_video_operation_open()',[("if current_setting('transaction_isolation')<>'read committed'then",'if false then')])
 o=op(7,2);result=race('negative-no-trigger-isolation-guard',stale(o));s=state(o)
 assert s['jobs']==1 and s['tombstones']==1,('isolation mutant was not detected',s,result)
 receipt['negativeControls'].append({'name':'no-trigger-isolation-guard','rejected':True,'concreteFailure':'repeatable-read enqueue admitted an operation discarded after its snapshot','observed':s})
 run('restore-no-trigger-isolation-guard',[*PSQL,'-Atq'],original)
 original=mutate('no-discard-isolation-guard',sig,[("if current_setting('transaction_isolation')<>'read committed'then",'if false then')])
 o=op(7,3);result=race('negative-no-discard-isolation-guard',['begin isolation level repeatable read;select count(*)from property_video_jobs;select pg_sleep(1);'+abandon(o)+'commit;','select pg_sleep(0.3);'+enqueue(o)]);s=state(o)
 assert s['jobs']==1 and s['tombstones']==1,('discard isolation mutant was not detected',s,result)
 receipt['negativeControls'].append({'name':'no-discard-isolation-guard','rejected':True,'concreteFailure':'repeatable-read discard tombstoned an operation accepted after its snapshot','observed':s})
 run('restore-no-discard-isolation-guard',[*PSQL,'-Atq'],original)
 # The restored definitions pass the same held-lock race again.
 o=op(8,1);result=race('restored-discard-versus-late-enqueue',[abandon(o),'select pg_sleep(0.2);'+enqueue(o)]);s=state(o)
 assert s['jobs']+s['tombstones']==1,(s,result)
 assert hashes()==receipt['sourceHashes'],'Source changed during verification';receipt['passed']=True
 print(json.dumps({'passed':True,'assertions':receipt['unit']['assertions'],'races':len(receipt['races']),'negativeControls':len(receipt['negativeControls']),'receipt':str(OUT/'receipt.json')}))
finally:
 if started:run('stop',[TOOLS['pg_ctl'],'-D',DATA,'-m','immediate','-w','-t','30','stop'])
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
 if not started or receipt['passed']:shutil.rmtree(DATA)
 if SOCK.exists():shutil.rmtree(SOCK)
