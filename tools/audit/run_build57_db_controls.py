#!/usr/bin/env python3
"""Build 57 database controls: actual RPC fixture, exact overlay replay, the
superseded predecessor refusal and real two-session lock-order races.
Owns a socket-only synthetic PG cluster. No hosted mutation or provider calls.
"""
from datetime import datetime, timezone
import hashlib,json,os,pathlib,re,shutil,subprocess,tempfile,time
ROOT=pathlib.Path(__file__).resolve().parents[2];SQL=ROOT/'services/supabase'
TARGET=SQL/'migrations/20261010141500_build57_select_workspace_lock_order.sql'
SUPERSEDED=SQL/'migrations/20261010030225_reaudit_library_session_settlement.sql'
SUITE=SQL/'tests/build57_db_controls.sql';ASSERTIONS=66
OUT=pathlib.Path(tempfile.mkdtemp(prefix='rendprop-build57-db-',dir='/tmp'));DATA=OUT/'cluster';SOCK=OUT/'socket';SOCK.mkdir(mode=0o700)
ENV={'PATH':os.environ.get('PATH','/usr/bin:/bin'),'LC_ALL':'C','TZ':'UTC'};BIN={n:shutil.which(n)for n in['initdb','pg_ctl','psql','createdb']};assert all(BIN.values()),'Use an already installed PostgreSQL distribution'
PORT='55493';CONN=['-h',str(SOCK),'-p',PORT,'-U','postgres'];PSQL=[BIN['psql'],'-X','--no-password',*CONN,'-d','rendprop_audit','-v','ON_ERROR_STOP=1','-Atq']
SOURCES=[*sorted((SQL/'migrations').glob('*.sql')),SQL/'tests/ci-bootstrap.sql',SUITE,pathlib.Path(__file__).resolve()]
HASHES={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in SOURCES}
R={'startedAt':datetime.now(timezone.utc).isoformat(),'sourceHashes':HASHES,'commands':[],'races':{},'passed':False,'productionMutations':0,'providerCalls':0,
   'limitations':['Synthetic Auth and owned socket-only PostgreSQL; no hosted JWT, physical phone, provider or invoice evidence']}
def run(name,args,body=None,expected=0):
 p=subprocess.run(list(map(str,args)),input=body,text=True,cwd=ROOT,env=ENV,capture_output=True,timeout=120);log=OUT/(name+'.log');log.write_text(p.stdout+p.stderr)
 R['commands'].append({'name':name,'exit':p.returncode,'log':str(log),'sha256':hashlib.sha256(log.read_bytes()).hexdigest()});assert p.returncode==expected,(name,p.returncode,log.read_text()[-1800:]);print(name,p.returncode,flush=True);return log.read_text()
def q(name,body,expected=0):return run(name,PSQL,body,expected)
def definition(name,sig):return q('definition-'+name,f"select pg_get_functiondef('public.{sig}'::regprocedure);")
CATALOG="select md5(string_agg(oid::regprocedure::text||prosrc||coalesce(proacl::text,'')||proowner::text||prosecdef::text||coalesce(proconfig::text,''),'|'order by oid::regprocedure::text))from pg_proc where pronamespace='public'::regnamespace;"
def suite(phase):
 r=q('suite-'+phase,SUITE.read_text());rows=[json.loads(l)for l in r.splitlines()if l.startswith('{')and'"suite"'in l];assert rows==[{'suite':'build57_db_controls','assertions':ASSERTIONS}],rows

def locked_race(label,locker_prefix,operation,locker_finish,expect):
 """locker: begin; prefix; LOCKED -> operation (service_role) must block on that exact backend -> locker finishes with the real function and commits."""
 b=subprocess.Popen(PSQL,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=dict(ENV,PGAPPNAME='locker-'+label));a=None;prefix=[]
 try:
  b.stdin.write("begin;set local deadlock_timeout='150ms';select pg_backend_pid();"+locker_prefix+"select 'LOCKED';\n");b.stdin.flush()
  while True:
   line=b.stdout.readline();prefix.append(line)
   if line.strip()=='LOCKED':break
   assert line,'Locker must acknowledge actual row lock: '+b.stderr.read()
  blocker=int(prefix[0].strip())
  a=subprocess.Popen(PSQL,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=dict(ENV,PGAPPNAME='operation-'+label))
  a.stdin.write("begin;set local deadlock_timeout='5s';set local role service_role;"+operation+"commit;\n");a.stdin.close()
  observed=False;deadline=time.monotonic()+8
  while time.monotonic()<deadline:
   if a.poll()is not None:break
   observed=q(label+'-blocker',f"select exists(select 1 from pg_stat_activity where application_name='operation-{label}'and wait_event_type='Lock'and {blocker}=any(pg_blocking_pids(pid)));").strip()=='t'
   if observed:break
   time.sleep(.03)
  assert observed,'Actual operation must overlap the exact participant locker'
  b.stdin.write('set local role service_role;'+locker_finish+'commit;\n');b.stdin.close();b.wait(15);a.wait(15)
  ao=a.stdout.read()+a.stderr.read();bo=''.join(prefix)+b.stdout.read()+b.stderr.read();deadlock='deadlock detected'in ao+bo
  result={'exactBlockerObserved':observed,'operationExit':a.returncode,'lockerExit':b.returncode,'deadlock':deadlock,'operationOutput':ao,'lockerOutput':bo}
  (OUT/(label+'.json')).write_text(json.dumps(result,indent=2))
  if expect=='deadlock':assert deadlock and sorted([a.returncode,b.returncode])==[0,3],result
  elif expect=='both-commit':assert not deadlock and a.returncode==0 and b.returncode==0,result
  else:assert not deadlock and a.returncode==3 and b.returncode==0 and expect in ao,result
  return {k:v for k,v in result.items()if 'Output'not in k}
 finally:
  for p in[a,b]:
   if p is not None and p.poll()is None:p.kill();p.wait()

OWNER,AGENT,SECOND='fb300000-0000-4000-8000-000000000001','fb300000-0000-4000-8000-000000000002','fb300000-0000-4000-8000-000000000003'
def team_fixture(label,team,first_time_agent=True):
 """Owner hosts an explicit-id Team org so the private/Team id order is chosen, not random."""
 q(label+'-seed',f"""delete from auth.users where id in('{OWNER}','{AGENT}','{SECOND}');delete from deletion_requests where user_id in('{OWNER}','{AGENT}','{SECOND}');delete from orgs where id='{team}';delete from org_invites where token_hash in(repeat('73',32),repeat('74',32));
  insert into auth.users(id,email,is_anonymous)values('{OWNER}','{label}-owner@fixture.invalid',false),('{AGENT}','{label}-agent@fixture.invalid',false),('{SECOND}','{label}-second@fixture.invalid',false);
  insert into orgs(id,name,plan,plan_source)values('{team}','{label} Team','team','manual');insert into memberships(user_id,org_id,role)values('{OWNER}','{team}','owner');update plan_entitlements set seats=8 where plan='team';
  delete from memberships where user_id='{OWNER}'and org_id<>'{team}';{"delete from user_workspace_state where user_id='"+AGENT+"';"if first_time_agent else""}
  insert into user_workspace_state(user_id,active_org_id)select '{SECOND}',org_id from memberships where user_id='{SECOND}'on conflict(user_id)do nothing;
  set role service_role;select create_org_invite('{OWNER}','{team}',null,'agent',repeat('73',32));select create_org_invite('{OWNER}','{team}',null,'agent',repeat('74',32));""")
def cleanup(label,team):q(label+'-cleanup',f"delete from auth.users where id in('{OWNER}','{AGENT}','{SECOND}');delete from deletion_requests where user_id in('{OWNER}','{AGENT}','{SECOND}');delete from orgs where id='{team}';delete from org_invites where token_hash in(repeat('73',32),repeat('74',32));")
DELETION=lambda user:f"select 1 from auth.users where id='{user}'for update;select 1 from profiles where id='{user}'for update;"
HIGH,LOW='ffffffff-ffff-4fff-8fff-ffffffffffff','00000000-0000-4000-8000-000000000001'

def switch_race(label,team,expect):
 team_fixture(label,team);q(label+'-accept',f"set role service_role;select accept_org_invite('{AGENT}',repeat('73',32));")
 private=q(label+'-private',f"select private_org_id from team_private_libraries where agent_user_id='{AGENT}'and revoked_at is null;").strip();assert re.fullmatch(r'[0-9a-f-]{36}',private)
 assert q(label+'-order',f"select '{private}'<'{team}';").strip()==('t'if team==HIGH else'f'),'fixture must pin the private/Team id order'
 assert q(label+'-owner-switch',f"set role service_role;select(select_workspace('{OWNER}','{private}')->>'active_org_id')='{private}';").strip()=='t'
 # The agent's deletion preflight has taken Auth, profile and its FIRST sorted org; the owner's switch runs against it.
 first=min(private,team)
 result=locked_race(label,DELETION(AGENT)+f"select 1 from orgs where id='{first}'for update;",f"select select_workspace('{OWNER}','{private}');",f"select prepare_account_deletion('{AGENT}','fixture-uploads','fixture-renders');",expect)
 if expect!='deadlock':
  assert q(label+'-child-purged',f"select not exists(select 1 from orgs where id='{private}');").strip()=='t','Deletion preflight must have completed'
  assert q(label+'-owner-directory',f"set role service_role;select(workspace_directory('{OWNER}',null)->>'active_org_id')=(workspace_directory('{OWNER}',null)->>'own_org_id');").strip()=='t','Owner falls back to own library after the agent is gone'
 cleanup(label,team);return result

started=False;print('EVIDENCE:',OUT,flush=True)
try:
 run('init',[BIN['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[BIN['pg_ctl'],'-D',DATA,'-l',OUT/'server.log','-w','-t','30','-o',f"-k {SOCK} -p {PORT} -c listen_addresses='' -c shared_buffers=16MB -c max_connections=20",'start']);started=True
 run('create',[BIN['createdb'],'--no-password',*CONN,'rendprop_audit']);assert q('identity',"select current_setting('data_directory'),current_setting('listen_addresses');").strip()==str(DATA)+'|'
 q('bootstrap',(SQL/'tests/ci-bootstrap.sql').read_text())
 old=None
 for p in sorted((SQL/'migrations').glob('*.sql')):
  if p==TARGET:
   old=definition('select_workspace-predecessor','select_workspace(uuid,uuid)')
   assert q('predecessor-md5',"select md5(prosrc)from pg_proc where oid='public.select_workspace(uuid,uuid)'::regprocedure;").strip()=='922f967fa624cc026dbe6f60ad922a0e','Predecessor must be the deployed reviewed body'
   # The original defect: the owner's switch deadlocks the agent's deletion when the private id sorts first.
   R['races']['predecessorOwnerSwitchVsAgentDeletion']=switch_race('predecessor-switch',HIGH,'deadlock')
  q('migration-'+p.stem,p.read_text())
 assert old is not None
 assert q('current-md5',"select md5(prosrc)from pg_proc where oid='public.select_workspace(uuid,uuid)'::regprocedure;").strip()=='ab14c1f6454c971bef4f62a1d98c995d'
 before=q('final-catalog',CATALOG)
 q('exact-target-replay',TARGET.read_text());assert q('replayed-catalog',CATALOG)==before,'Exact replay must not change bodies or privileges'
 refused=q('superseded-reaudit-overlay-refused',SUPERSEDED.read_text(),3);assert'Review changed function select_workspace'in refused
 assert q('superseded-refusal-catalog',CATALOG)==before,'Historical replay must not overwrite the newer reviewed function'
 current=definition('select_workspace-current','select_workspace(uuid,uuid)')
 for i,sig in enumerate(['select_workspace(uuid,uuid)']):
  marker=re.search(r'AS (\$[^$]*\$)',current)[0];q('unknown-'+str(i)+'-install',current.replace(marker,marker+'\n-- unreviewed predecessor\n',1))
  mutant=q('unknown-'+str(i)+'-catalog',CATALOG);refused=q('unknown-'+str(i)+'-refused',TARGET.read_text(),3);assert'Review changed function select_workspace'in refused
  assert q('unknown-'+str(i)+'-after-refusal',CATALOG)==mutant,'Refusal must be atomic';q('unknown-'+str(i)+'-restore',current)
 assert q('restored-catalog',CATALOG)==before
 for phase in['fresh','replay']:
  if phase=='replay':q('exact-target-replay-2',TARGET.read_text());assert q('replayed-catalog-2',CATALOG)==before
  suite(phase)
 # (c)/(a) real two-session races on the current function.
 R['races']['ownerSwitchVsAgentDeletionPrivateFirst']=switch_race('fixed-switch-private-first',HIGH,'RP403: This listing library is unavailable')
 R['races']['ownerSwitchVsAgentDeletionTeamFirst']=switch_race('fixed-switch-team-first',LOW,'RP403: This listing library is unavailable')
 # First-time acceptance (no user_workspace_state row) against the owner's and the agent's own deletion preflight.
 team_fixture('first-invite-owner-deletion',HIGH)
 assert q('first-invite-no-state',f"select not exists(select 1 from user_workspace_state where user_id='{AGENT}');").strip()=='t'
 R['races']['firstInviteVsOwnerDeletion']=locked_race('first-invite-owner-deletion',DELETION(OWNER),f"select accept_org_invite('{AGENT}',repeat('73',32));",f"select prepare_account_deletion('{OWNER}','fixture-uploads','fixture-renders');",'RP409: An account is being deleted')
 cleanup('first-invite-owner-deletion',HIGH)
 team_fixture('first-invite-agent-deletion',HIGH)
 R['races']['firstInviteVsAgentDeletion']=locked_race('first-invite-agent-deletion',DELETION(AGENT),f"select accept_org_invite('{AGENT}',repeat('73',32));",f"select prepare_account_deletion('{AGENT}','fixture-uploads','fixture-renders');",'RP409: An account is being deleted')
 cleanup('first-invite-agent-deletion',HIGH)
 # First-time acceptor A against an acceptor B that already has a workspace state row and holds the Team seat locks.
 team_fixture('first-invite-with-state',HIGH)
 assert q('with-state-row',f"select exists(select 1 from user_workspace_state where user_id='{SECOND}');").strip()=='t'
 R['races']['firstInviteVsWithStateAcceptor']=locked_race('first-invite-with-state',
  f"select 1 from auth.users where id in('{SECOND}','{OWNER}')order by id for key share;select 1 from profiles where id in('{SECOND}','{OWNER}')order by id for update;select 1 from orgs where id='{HIGH}'for update;",
  f"select accept_org_invite('{AGENT}',repeat('73',32));",f"select accept_org_invite('{SECOND}',repeat('74',32));",'both-commit')
 assert q('both-bound',f"select count(*)=2 from team_private_libraries b join user_workspace_state s on s.user_id=b.agent_user_id and s.active_org_id=b.private_org_id where b.team_org_id='{HIGH}'and b.revoked_at is null and b.agent_user_id in('{AGENT}','{SECOND}')and b.private_org_id<>'{HIGH}';").strip()=='t','Both acceptors bind and activate their own private libraries'
 cleanup('first-invite-with-state',HIGH)
 # (e) Replacement registration retires the displaced session under the canonical token lock.
 A,B='fb400000-0000-4000-8000-000000000001','fb400000-0000-4000-8000-000000000002';SA,SB='fb410000-0000-4000-8000-000000000001','fb410000-0000-4000-8000-000000000002';TOKEN="repeat('96',32)"
 q('device-seed',f"delete from auth.users where id in('{A}','{B}');insert into auth.users(id,email,is_anonymous)values('{A}','device-a@fixture.invalid',false),('{B}','device-b@fixture.invalid',false);")
 digest=q('device-digest',f"select encode(sha256(convert_to({TOKEN},'UTF8')),'hex');").strip()
 R['races']['deviceTakeoverUnderTokenLock']=locked_race('device-token-lock',f"select pg_advisory_xact_lock(hashtextextended('notification-device:{digest}',72453));",
  f"select notification_register_device_session('{B}','{SB}',upper({TOKEN}),null,'production');",f"select notification_register_device_session('{A}','{SA}',{TOKEN},null,'sandbox');",'both-commit')
 assert q('device-owner',f"select user_id='{B}'and registration_session_id='{SB}'and environment='production'and device_token={TOKEN} from notification_devices where lower(device_token)={TOKEN};").strip()=='t','Serialized replacement owns the canonical token'
 assert'RP409: This device session has signed out'in q('device-late-a',f"set role service_role;select notification_register_device_session('{A}','{SA}',{TOKEN},null,'sandbox');",3)
 assert q('device-late-a-delete',f"set role service_role;select(notification_unregister_device('{A}','{SA}',{TOKEN},'production')->>'removed')::boolean;").strip()=='f'
 assert q('device-b-survives',f"select exists(select 1 from notification_devices where device_token={TOKEN} and user_id='{B}');").strip()=='t'
 q('device-cleanup',f"delete from auth.users where id in('{A}','{B}');")
 assert q('final-restored-catalog',CATALOG)==before
 suite('restored')
 R.update(passed=True,sqlAssertions={'build57_db_controls':ASSERTIONS},exactReplay=True,supersededOverlayRefusedAtomic=True,unknownPredecessorRefused=1,originalDefectReproduced=True,realRaces=len(R['races']),target=TARGET.name)
finally:
 if started and(DATA/'postmaster.pid').exists():run('stop',[BIN['pg_ctl'],'-D',DATA,'-m','fast','-w','stop'])
 R['sourceHashesAfter']={n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest()for n in HASHES};R['sourceUnchanged']=R['sourceHashesAfter']==HASHES;R['passed']=R['passed']and R['sourceUnchanged'];R['finishedAt']=datetime.now(timezone.utc).isoformat();(OUT/'receipt.json').write_text(json.dumps(R,indent=2)+'\n')
assert R['passed'];print(f'PASS: {ASSERTIONS} SQL assertions fresh/replay/restored, exact replay, superseded overlay refused, original deadlock reproduced on the predecessor and {len(R["races"])} real two-session races',flush=True)
