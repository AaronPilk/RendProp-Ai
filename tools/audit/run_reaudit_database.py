#!/usr/bin/env python3
"""Final re-audit controls: actual SQL, destructive negative controls and locks.
Owns a socket-only synthetic PG cluster. No hosted mutation or provider calls.
"""
from datetime import datetime, timezone
import hashlib,json,os,pathlib,re,shutil,subprocess,tempfile,time
ROOT=pathlib.Path(__file__).resolve().parents[2];SQL=ROOT/'services/supabase'
TARGET=SQL/'migrations/20261010030225_reaudit_library_session_settlement.sql'
SUITES={'reaudit_library_selection':12,'reaudit_device_takeover':9,'reaudit_deleted_team_video':20}
OUT=pathlib.Path(tempfile.mkdtemp(prefix='rp-reaudit-db-',dir='/tmp'));DATA=OUT/'cluster';SOCK=OUT/'socket';SOCK.mkdir(mode=0o700)
ENV={'PATH':os.environ.get('PATH','/usr/bin:/bin'),'LC_ALL':'C','TZ':'UTC'};BIN={n:shutil.which(n)for n in['initdb','pg_ctl','psql','createdb']};assert all(BIN.values())
CONN=['-h',str(SOCK),'-p','55491','-U','postgres'];PSQL=[BIN['psql'],'-X','--no-password',*CONN,'-d','rendprop_audit','-v','ON_ERROR_STOP=1','-Atq']
SOURCES=[*sorted((SQL/'migrations').glob('*.sql')),SQL/'tests/ci-bootstrap.sql',*[SQL/'tests'/f'{n}.sql'for n in SUITES],pathlib.Path(__file__).resolve()]
HASHES={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in SOURCES}
R={'startedAt':datetime.now(timezone.utc).isoformat(),'sourceHashes':HASHES,'commands':[],'passed':False,'productionMutations':0,'providerCalls':0,'limitations':['Synthetic Auth and owned socket-only PostgreSQL; no hosted JWT, physical phone, provider or invoice evidence']}
def run(name,args,body=None,expected=0):
 p=subprocess.run(list(map(str,args)),input=body,text=True,cwd=ROOT,env=ENV,capture_output=True,timeout=120);log=OUT/(name+'.log');log.write_text(p.stdout+p.stderr)
 R['commands'].append({'name':name,'exit':p.returncode,'log':str(log),'sha256':hashlib.sha256(log.read_bytes()).hexdigest()});assert p.returncode==expected,(name,p.returncode,log.read_text()[-1800:]);print(name,p.returncode,flush=True);return log.read_text()
def q(name,body,expected=0):return run(name,PSQL,body,expected)
def definition(name,sig):return q('definition-'+name,f"select pg_get_functiondef('public.{sig}'::regprocedure);")
def suite(name,phase):
 r=q(name+'-'+phase,(SQL/'tests'/f'{name}.sql').read_text());rows=[json.loads(l)for l in r.splitlines()if l.startswith('{')and'"suite"'in l];assert rows==[{'suite':name,'assertions':SUITES[name]}],rows

def locked_race(label,locker_prefix,operation,locker_finish,expected_deadlock,expected_refusal=None):
 b=subprocess.Popen(PSQL,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=dict(ENV,PGAPPNAME='locker-'+label));a=None;prefix=[]
 try:
  b.stdin.write("begin;set local deadlock_timeout='150ms';select pg_backend_pid();"+locker_prefix+"select 'LOCKED';\n");b.stdin.flush()
  while True:
   line=b.stdout.readline();prefix.append(line)
   if line.strip()=='LOCKED':break
   assert line,'Locker must acknowledge actual row lock'
  blocker=int(prefix[0].strip())
  a=subprocess.Popen(PSQL,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=dict(ENV,PGAPPNAME='operation-'+label))
  a.stdin.write("begin;set local deadlock_timeout='5s';set local role service_role;"+operation+"commit;\n");a.stdin.close()
  observed=False;deadline=time.monotonic()+8
  while time.monotonic()<deadline:
   if a.poll()is not None:break
   observed=q(label+'-blocker',f"select exists(select 1 from pg_stat_activity where application_name='operation-{label}'and wait_event_type='Lock'and {blocker}=any(pg_blocking_pids(pid)));").strip()=='t'
   if observed:break
   time.sleep(.03)
  if expected_refusal:
   a.wait(10);assert not observed,'NOWAIT takeover must not acquire an inverse wait'
  else:assert observed,'Actual operation must overlap exact participant locker'
  b.stdin.write('set local role service_role;'+locker_finish+'commit;\n');b.stdin.close();b.wait(15);a.wait(15)
  ao=a.stdout.read()+a.stderr.read();bo=''.join(prefix)+b.stdout.read()+b.stderr.read();deadlock='deadlock detected'in ao+bo
  result={'exactBlockerObserved':observed,'operationExit':a.returncode,'lockerExit':b.returncode,'deadlock':deadlock,'operationOutput':ao,'lockerOutput':bo}
  (OUT/(label+'.json')).write_text(json.dumps(result,indent=2))
  if expected_deadlock:assert deadlock and sorted([a.returncode,b.returncode])==[0,3],result
  elif expected_refusal:assert a.returncode==3 and b.returncode==0 and expected_refusal in ao and not deadlock,result
  else:assert b.returncode==0 and a.returncode==3 and 'RP409: An account is being deleted'in ao and not deadlock,result
  return {k:v for k,v in result.items()if 'Output'not in k}
 finally:
  for p in[a,b]:
   if p is not None and p.poll()is None:p.kill();p.wait()

def invite_race(label,expected_deadlock):
 owner,agent=[f'fb100000-0000-4000-8000-{n:012d}'for n in[1,2]]
 q(label+'-seed',f"delete from auth.users where id in('{owner}','{agent}');insert into auth.users(id,email,is_anonymous)values('{owner}','{label}-owner@fixture.invalid',false),('{agent}','{label}-agent@fixture.invalid',false);delete from user_workspace_state where user_id='{agent}';")
 team=q(label+'-team',f"select org_id from memberships where user_id='{owner}';").strip()
 q(label+'-invite',f"update orgs set plan='team',plan_source='manual'where id='{team}';set role service_role;select create_org_invite('{owner}','{team}',null,'agent',repeat('94',32));")
 result=locked_race(label,f"select 1 from auth.users where id='{owner}'for update;select 1 from profiles where id='{owner}'for update;",f"select accept_org_invite('{agent}',repeat('94',32));",f"select prepare_account_deletion('{owner}','fixture-uploads','fixture-renders');",expected_deadlock)
 q(label+'-cleanup',f"delete from auth.users where id in('{owner}','{agent}');delete from org_invites where token_hash=repeat('94',32);")
 return result

def push_race(label,expected_deadlock):
 old,new=[f'fb200000-0000-4000-8000-{n:012d}'for n in[1,2]]
 q(label+'-seed',f"delete from auth.users where id in('{old}','{new}');insert into auth.users(id,email,is_anonymous)values('{old}','{label}-old@fixture.invalid',false),('{new}','{label}-new@fixture.invalid',false);set role service_role;select notification_register_device_session('{old}','fb210000-0000-4000-8000-000000000001',repeat('95',32),null,'sandbox');")
 result=locked_race(label,f"select 1 from auth.users where id='{old}'for update;select 1 from profiles where id='{old}'for update;",f"select notification_register_device_session('{new}','fb210000-0000-4000-8000-000000000002',repeat('95',32),null,'sandbox');",f"select prepare_account_deletion('{old}','fixture-uploads','fixture-renders');reset role;delete from auth.users where id='{old}';",expected_deadlock,None if expected_deadlock else'RP409: Device ownership is changing')
 if not expected_deadlock:
  q(label+'-retry',f"set role service_role;select notification_register_device_session('{new}','fb210000-0000-4000-8000-000000000002',repeat('95',32),null,'sandbox');")
  assert q(label+'-new-owner',f"select user_id='{new}'::uuid from notification_devices where device_token=repeat('95',32);").strip()=='t'
 q(label+'-cleanup',f"delete from auth.users where id in('{old}','{new}');")
 return result

started=False;print('EVIDENCE:',OUT,flush=True)
try:
 run('init',[BIN['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[BIN['pg_ctl'],'-D',DATA,'-l',OUT/'server.log','-w','-t','30','-o',f"-k {SOCK} -p 55491 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=20",'start']);started=True
 run('create',[BIN['createdb'],'--no-password',*CONN,'rendprop_audit']);assert q('identity',"select current_setting('data_directory'),current_setting('listen_addresses');").strip()==str(DATA)+'|'
 q('bootstrap',(SQL/'tests/ci-bootstrap.sql').read_text())
 old={}
 for p in sorted((SQL/'migrations').glob('*.sql')):
  if p==TARGET:
   for name,sig in [('accept_org_invite','accept_org_invite(uuid,text)'),('workspace_directory','workspace_directory(uuid,uuid)'),('cost_ledger_settle_serving_hold','cost_ledger_settle_serving_hold()'),('notification_register_device_session','notification_register_device_session(uuid,uuid,text,text,text,text,text)')]:old[name]=definition(name,sig)
   for name,label in [('reaudit_library_selection','bound non-switcher default aligns'),('reaudit_device_takeover','late displaced A POST'),('reaudit_deleted_team_video','exact late deleted-child receipt binds')]:
    refusal=q(name+'-historical-negative',(SQL/'tests'/f'{name}.sql').read_text(),3);assert label in refusal
   R['oldFirstInviteDeletionRace']=invite_race('old-first-invite',True)
  q('migration-'+p.stem,p.read_text())
 catalog="select md5(string_agg(oid::regprocedure::text||prosrc||coalesce(proacl::text,'')||proowner::text||prosecdef::text||coalesce(proconfig::text,''),'|'order by oid::regprocedure::text))from pg_proc where pronamespace='public'::regnamespace;"
 before=q('final-catalog',catalog)
 for phase in['fresh','replay']:
  if phase=='replay':q('exact-followup-replay',TARGET.read_text());assert q('replayed-catalog',catalog)==before
  for name in SUITES:suite(name,phase)
 R['firstInviteDeletionRace']=invite_race('fixed-first-invite',False)
 new_push=definition('push-current','notification_register_device_session(uuid,uuid,text,text,text,text,text)')
 assert new_push.count('order by user_id,id\n')==1 and new_push.count('for key share nowait')==1
 q('install-push-inverse-lock-control',new_push.replace('order by user_id,id\n','order by user_id,id for update\n').replace('for key share nowait','for key share'))
 R['pushDeletionInverseLockNegative']=push_race('inverse-device-lock',True)
 q('restore-push-order',new_push);R['pushDeletionSafeRefusalAndRetry']=push_race('fixed-device-lock',False)
 # Real function mutations must fail their runtime acceptance assertions.
 for function,suite_name,label in [('workspace_directory','reaudit_library_selection','bound non-switcher default aligns'),('cost_ledger_settle_serving_hold','reaudit_deleted_team_video','exact late deleted-child receipt binds'),('notification_register_device_session','reaudit_device_takeover','late displaced A POST')]:
  sig={'workspace_directory':'workspace_directory(uuid,uuid)','cost_ledger_settle_serving_hold':'cost_ledger_settle_serving_hold()','notification_register_device_session':'notification_register_device_session(uuid,uuid,text,text,text,text,text)'}[function]
  current=definition(function+'-current',sig);q(function+'-remove-fix',old[function]);refused=q(function+'-negative',(SQL/'tests'/f'{suite_name}.sql').read_text(),3);assert label in refused;q(function+'-restore',current)
 # Unknown predecessor cannot accidentally apply a reviewed patch to new code.
 pins=re.findall(r"oid='public\.([^']+)'::regprocedure",TARGET.read_text());assert len(pins)==6
 for i,sig in enumerate(pins):
  current=definition('pin-'+str(i),sig);marker=re.search(r'AS (\$[^$]*\$)',current)[0]
  q('unknown-'+str(i)+'-install',current.replace(marker,marker+'\n-- unreviewed predecessor\n',1))
  refused=q('unknown-'+str(i)+'-refused',TARGET.read_text(),3);assert'Review changed function'in refused;q('unknown-'+str(i)+'-restore',current)
 assert q('final-restored-catalog',catalog)==before
 for name in SUITES:suite(name,'restored')
 R.update(passed=True,sqlAssertions=SUITES,exactReplay=True,predecessorsRefused=6,originalBugsReproduced=3,compiledNegativeControls=4)
finally:
 if started and(DATA/'postmaster.pid').exists():run('stop',[BIN['pg_ctl'],'-D',DATA,'-m','fast','-w','stop'])
 R['sourceHashesAfter']={n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest()for n in HASHES};R['sourceUnchanged']=R['sourceHashesAfter']==HASHES;R['passed']=R['passed']and R['sourceUnchanged'];R['finishedAt']=datetime.now(timezone.utc).isoformat();(OUT/'receipt.json').write_text(json.dumps(R,indent=2)+'\n')
assert R['passed'];print('PASS: 41 SQL assertions fresh/replay/restored, four real races, six predecessor guards and original runtime regressions',flush=True)
