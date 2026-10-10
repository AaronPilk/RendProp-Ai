#!/usr/bin/env python3
"""Real account adoption, private Team, device session and cost-retention controls.

Owns a socket-only fresh PostgreSQL cluster. No hosted SQL, user accounts,
provider calls or inherited credentials. Actual compiled defects must fail.
"""
from datetime import datetime, timezone
import hashlib,json,os,pathlib,re,shutil,subprocess,tempfile,time
ROOT=pathlib.Path(__file__).resolve().parents[2];SQL=ROOT/'services/supabase'
TARGET=SQL/'migrations/20261010000032_private_library_adoption_and_serving_safety.sql'
FOLLOWUP=SQL/'migrations/20261010030225_reaudit_library_session_settlement.sql'
FINAL_OVERLAY=SQL/'migrations/20261010042000_legacy_notification_session_retirement.sql'
HISTORICAL_DEVICE_SUITE=SQL/'tests/notification_session_fencing_pre_canonical.sql'
assert hashlib.sha256(HISTORICAL_DEVICE_SUITE.read_bytes()).hexdigest()=='dcf14b70d2d839537784c6d9417be852ea464d11596497ad5bf2eb77a2c807ae','Historical device fixture must retain its exact reviewed 27 cases'
FIXTURES={'private_library_adoption_safety':32,'notification_session_fencing':29,'ops_deleted_workspace':16}
OUT=pathlib.Path(tempfile.mkdtemp(prefix='rendprop-account-library-safety-',dir='/tmp'));OUT.chmod(0o700);DATA=OUT/'cluster';SOCK=OUT/'socket';SOCK.mkdir(mode=0o700)
ENV={'PATH':os.environ.get('PATH','/usr/bin:/bin'),'LC_ALL':'C','TZ':'UTC'};BIN={n:shutil.which(n)for n in['initdb','pg_ctl','psql','createdb']};assert all(BIN.values())
CONN=['-h',str(SOCK),'-p','55475','-U','postgres'];PSQL=[BIN['psql'],'-X','--no-password',*CONN,'-d','rendprop_audit','-v','ON_ERROR_STOP=1','-Atq']
SOURCES=[*sorted((SQL/'migrations').glob('*.sql')),SQL/'tests/ci-bootstrap.sql',HISTORICAL_DEVICE_SUITE,*[SQL/'tests'/f'{n}.sql'for n in FIXTURES],pathlib.Path(__file__).resolve()]
HASHES={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in SOURCES}
RECEIPT={'startedAt':datetime.now(timezone.utc).isoformat(),'sourceHashes':HASHES,'commands':[],'passed':False,'productionMutations':0,'providerCalls':0}
def run(name,args,body=None,expected=0):
 r=subprocess.run(list(map(str,args)),input=body,text=True,cwd=ROOT,env=ENV,capture_output=True,timeout=120);log=OUT/(name+'.log');log.write_text(r.stdout+r.stderr);log.chmod(0o600)
 RECEIPT['commands'].append({'name':name,'exit':r.returncode,'log':str(log),'sha256':hashlib.sha256(log.read_bytes()).hexdigest()});assert r.returncode==expected,(name,r.returncode,log.read_text()[-1600:]);print(name,r.returncode,flush=True);return log.read_text()
def q(name,body,expected=0):return run(name,PSQL,body,expected)
def suite(name,phase,source=None,count=None):
 r=q(name+'-'+phase,(source or SQL/'tests'/f'{name}.sql').read_text());rows=[json.loads(line)for line in r.splitlines()if line.startswith('{')and '"suite"'in line];assert rows==[{'suite':name,'assertions':FIXTURES[name]if count is None else count,**({'no_content_moved':True,'real_auth_adoption_acceptance':True}if name=='private_library_adoption_safety'else{'late_registration_refused':True,'late_delete_keeps_new_account':True}if name=='notification_session_fencing'else{'real_account_delete_used':True,'provider_liabilities_preserved':True,'prior_criterion_negative_control':True})}]
def definition(sig):return q('definition-'+sig.split('(')[0],f"select pg_get_functiondef('public.{sig}'::regprocedure);")
def child_race(label,agent,child,expect_deadlock):
 b=subprocess.Popen(PSQL,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=dict(ENV,PGAPPNAME='safety-operation'))
 a=None;prefix=[]
 try:
  b.stdin.write(f"begin;set local deadlock_timeout='150ms';select pg_advisory_xact_lock(hashtextextended('serving:{child}',72452));select 'B_LOCKED';\n");b.stdin.flush()
  while True:
   line=b.stdout.readline();prefix.append(line)
   if line.strip()=='B_LOCKED':break
   assert line,'Operation must acknowledge the actual child lock'
  a=subprocess.Popen(PSQL,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=dict(ENV,PGAPPNAME='safety-hold'))
  a.stdin.write(f"begin;set local deadlock_timeout='150ms';set local role service_role;select serving_cost_reserve('{agent}','{child}','hold-{label}','copy.caption:0','gemini','fixture',repeat('a',64),1,'fixture-v1');rollback;\n");a.stdin.close()
  observed=False;end=time.monotonic()+8
  while time.monotonic()<end:
   if a.poll()is not None:break
   if q(label+'-lock-observation',"select exists(select 1 from pg_stat_activity where application_name='safety-hold'and wait_event_type='Lock');").strip()=='t':observed=True;break
   time.sleep(.03)
  b.stdin.write(f"set local role service_role;select serving_operation_begin('{agent}','{child}','operation-{label}','coach.chat',repeat('b',64));rollback;\n");b.stdin.close();a.wait(12);b.wait(12)
  ao=a.stdout.read()+a.stderr.read();bo=''.join(prefix)+b.stdout.read()+b.stderr.read();deadlock='deadlock detected'in ao+bo
  result={'observedChildLockWait':observed,'holdExit':a.returncode,'operationExit':b.returncode,'deadlockDetected':deadlock,'holdOutput':ao,'operationOutput':bo}
  p=OUT/(label+'.json');p.write_text(json.dumps(result,indent=2));p.chmod(0o600)
  if expect_deadlock:assert observed and deadlock and sorted([a.returncode,b.returncode])==[0,3],result
  else:assert a.returncode==b.returncode==0 and not deadlock,result
  return {k:v for k,v in result.items()if 'Output'not in k}
 finally:
  for process in [a,b]:
   if process is not None and process.poll()is None:process.kill();process.wait()
def replay_selection_race(label,agent,child,second,expect_retained):
 q(label+'-initial-selection',f"set role service_role;select public.select_workspace('{agent}','{child}');")
 b=subprocess.Popen(PSQL,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=dict(ENV,PGAPPNAME='selector-'+label))
 a=None;prefix=[]
 try:
  b.stdin.write(f"begin;select pg_backend_pid();select 1 from public.profiles where id='{agent}'for update;select 'SELECTOR_LOCKED';\n");b.stdin.flush()
  while True:
   line=b.stdout.readline();prefix.append(line)
   if line.strip()=='SELECTOR_LOCKED':break
   assert line,'Selector must acknowledge its actual profile lock'
  blocker=int(prefix[0].strip())
  a=subprocess.Popen(PSQL,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=dict(ENV,PGAPPNAME='accepted-replay-'+label))
  a.stdin.write(f"set role service_role;select public.accept_org_invite('{agent}',repeat('8f',32));\n");a.stdin.close()
  observed=False;end=time.monotonic()+8
  while time.monotonic()<end:
   observed=q(label+'-exact-blocker',f"select exists(select 1 from pg_stat_activity where application_name='accepted-replay-{label}'and wait_event_type='Lock'and {blocker}=any(pg_blocking_pids(pid)));").strip()=='t'
   if observed:break
   assert a.poll()is None,'Replay finished before actual selector overlap'
   time.sleep(.03)
  assert observed,'Actual replay must wait on the selector profile lock'
  b.stdin.write(f"update public.user_workspace_state set active_org_id='{second}'where user_id='{agent}';commit;\n");b.stdin.close();b.wait(15);a.wait(15)
  ao=a.stdout.read()+a.stderr.read();bo=''.join(prefix)+b.stdout.read()+b.stderr.read()
  retained=q(label+'-retained',f"select active_org_id='{second}'::uuid from public.user_workspace_state where user_id='{agent}';").strip()=='t'
  result={'actualProfileBlockerObserved':observed,'selectorExit':b.returncode,'replayExit':a.returncode,'newSelectionRetained':retained,'selectorOutput':bo,'replayOutput':ao}
  log=OUT/(label+'.json');log.write_text(json.dumps(result,indent=2));log.chmod(0o600)
  assert a.returncode==b.returncode==0 and retained==expect_retained,result
  return {k:v for k,v in result.items()if 'Output'not in k}
 finally:
  for process in[a,b]:
   if process is not None and process.poll()is None:process.kill();process.wait()
started=False;print('EVIDENCE:',OUT,flush=True)
try:
 run('init',[BIN['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[BIN['pg_ctl'],'-D',DATA,'-l',OUT/'server.log','-w','-t','30','-o',f"-k {SOCK} -p 55475 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=20",'start']);started=True
 run('create',[BIN['createdb'],'--no-password',*CONN,'rendprop_audit']);assert q('identity',"select current_setting('data_directory'),current_setting('listen_addresses');").strip()==str(DATA)+'|'
 q('bootstrap',(SQL/'tests/ci-bootstrap.sql').read_text())
 catalog="select md5(string_agg(oid::regprocedure::text||prosrc||coalesce(proacl::text,'')||proowner::text||prosecdef::text||coalesce(proconfig::text,''),'|'order by oid::regprocedure::text))from pg_proc where pronamespace='public'::regnamespace;"
 pins=re.findall(r"oid='public\.([^']+)'::regprocedure\)not in\(",TARGET.read_text());assert len(pins)==7,pins
 historical_accept=None
 for p in sorted((SQL/'migrations').glob('*.sql')):
  q('migration-'+p.stem,p.read_text())
  if p==TARGET:
   # Replay and predecessor controls belong at this migration's historical
   # schema point. Never replay its body over the later selection fix.
   historical_before=q('historical-safety-catalog',catalog)
   q('historical-safety-exact-replay',TARGET.read_text())
   assert q('historical-safety-replayed-catalog',catalog)==historical_before
   for i,sig in enumerate(pins):
    current=definition(sig);assert current.count('$function$')==2
    mutant=current.replace('AS $function$','AS $function$\n-- unreviewed fixture predecessor\n',1)
    q(f'unknown-predecessor-{i}-install',mutant)
    rejected=q(f'unknown-predecessor-{i}-refused',TARGET.read_text(),3);assert 'Review changed function'in rejected
    q(f'unknown-predecessor-{i}-restore',current)
   assert q('historical-restored-catalog',catalog)==historical_before
   historical_accept=definition('accept_org_invite(uuid,text)')
  if p==FOLLOWUP:
   historical_followup=q('historical-followup-catalog',catalog)
   q('historical-followup-exact-replay',FOLLOWUP.read_text())
   assert q('historical-followup-replayed-catalog',catalog)==historical_followup
   for name in FIXTURES:
    # Preserve the exact pre-canonical 27 cases at the old overlay's schema
    # point; final phases require all 29 current canonical-environment cases.
    suite(name,'historical-followup-replay',HISTORICAL_DEVICE_SUITE if name=='notification_session_fencing'else None,27 if name=='notification_session_fencing'else None)
   historical_final_accept=definition('accept_org_invite(uuid,text)')
   q('unknown-followup-body-install',historical_final_accept.replace('AS $function$','AS $function$\n-- unreviewed fixture predecessor\n',1))
   unknown_followup=q('unknown-followup-catalog',catalog)
   refused=q('unknown-followup-body-refused',FOLLOWUP.read_text(),3);assert 'Review changed function accept_org_invite'in refused
   assert q('unknown-followup-refusal-catalog',catalog)==unknown_followup,'Unknown predecessor refusal must be atomic'
   q('restore-historical-followup-body',historical_final_accept)
   assert q('historical-followup-restored-catalog',catalog)==historical_followup
 assert historical_accept is not None
 before=q('final-catalog',catalog)
 # Build 57 (20261010141500) supersedes select_workspace, the first differing pin of this overlay.
 refused=q('superseded-followup-refused',FOLLOWUP.read_text(),3);assert 'Review changed function select_workspace'in refused
 assert q('superseded-followup-refusal-catalog',catalog)==before,'Historical overlay must not overwrite newer reviewed functions'
 for phase in['fresh','replay']:
  if phase=='replay':q('exact-final-overlay-replay',FINAL_OVERLAY.read_text());assert q('replayed-catalog',catalog)==before,'Replay changed final bodies or privileges'
  for name in FIXTURES:suite(name,phase)
 # Actual adoption fails if the deterministic private selection is removed.
 current=definition('agent_private_library(uuid)');anchor='public.resolve_actor_owned_library(p_actor,false)';assert current.count(anchor)==1
 mutant=current.replace(anchor,"(select min(m.org_id::text)::uuid from public.memberships m join public.orgs o on o.id=m.org_id and o.deleted_at is null where m.user_id=p_actor and m.role='owner' having count(*)=1)")
 q('install-two-org-negative-control',mutant);r=q('two-org-negative-control',(SQL/'tests/private_library_adoption_safety.sql').read_text(),3);assert 'validated adopted active library wins'in r;q('restore-actor-selector',current)
 # Retiring personal content may not erase the linked financial receipt.
 current=definition('prepare_account_deletion(uuid,text,text)');anchor="update public.cost_ledger set org_id=null,job_id=null,meta='{}'::jsonb,idempotency_key=null\n    where org_id=any(solo) or job_id=any(job_ids);";assert current.count(anchor)==1
 q('install-ledger-deletion-negative-control',current.replace(anchor,'delete from public.cost_ledger where org_id=any(solo) or job_id=any(job_ids);'))
 r=q('ledger-deletion-negative-control',(SQL/'tests/ops_deleted_workspace.sql').read_text(),3);assert 'real deletion anonymizes exact ledger references'in r;q('restore-ledger-anonymization',current)
 # A session tombstone is meaningful: removing its check must admit late A.
 current=definition('notification_register_device_session(uuid,uuid,text,text,text,text,text)');anchor="if exists(select 1 from public.notification_device_session_tombstones t where t.user_id=p_user and t.session_id=p_session and t.token_sha256=digest)";assert current.count(anchor)==1
 q('install-device-resurrection-negative-control',current.replace(anchor,'if false'))
 r=q('device-resurrection-negative-control',(SQL/'tests/notification_session_fencing.sql').read_text(),3);assert 'allowed late A POST cannot resurrect after B register'in r;q('restore-session-fence',current)
 # The actual two-child-lock inversion must deadlock if its early return is lost.
 owner='f9300000-0000-4000-8000-000000000001';agent='f9300000-0000-4000-8000-000000000002'
 q('lock-race-users',f"insert into auth.users(id,email,is_anonymous)values('{owner}','lock-owner@fixture.invalid',false),('{agent}','lock-agent@fixture.invalid',false);")
 team=q('lock-race-team',f"select org_id from memberships where user_id='{owner}';").strip()
 q('lock-race-binding',f"update orgs set plan='team',plan_source='manual'where id='{team}';set role service_role;select create_org_invite('{owner}','{team}',null,'agent',repeat('8f',32));select accept_org_invite('{agent}',repeat('8f',32));")
 child=q('lock-race-child',f"select private_org_id from team_private_libraries where agent_user_id='{agent}'and revoked_at is null;").strip()
 current=definition('serving_photo_partition_guard()');anchor='if new.funding_id is null then return new;end if;';assert current.count(anchor)==1
 q('install-child-lock-negative-control',current.replace(anchor,''));negative=child_race('negative-child-lock',agent,child,True);q('restore-photo-partition-guard',current)
 positive=child_race('correct-child-lock',agent,child,False)
 # Old accepted receipt replay reads active selection before acquiring the
 # selector's profile lock. Prove its overwrite and the compiled early-read
 # mutation, then verify the final function and its supported exact replay.
 second='f9300000-0000-4000-8000-000000000099'
 q('replay-race-second-owned-library',f"insert into public.orgs(id,name)values('{second}','Replay selection fixture');insert into public.memberships(user_id,org_id,role)values('{agent}','{second}','owner');")
 final_accept=definition('accept_org_invite(uuid,text)')
 q('old-accepted-replay-install',historical_accept)
 old_replay=replay_selection_race('old-accepted-replay',agent,child,second,False)
 q('restore-final-accepted-replay',final_accept)
 new_replay=replay_selection_race('correct-accepted-replay',agent,child,second,True)
 active_read=' select active_org_id into prior_active from public.user_workspace_state where user_id=p_user;\n'
 anchor=' was_accepted:=i.accepted_at is not null;\n'
 assert final_accept.count(active_read)==final_accept.count(anchor)==1
 early=final_accept.replace(active_read,'').replace(anchor,anchor+active_read)
 q('early-read-negative-install',early)
 early_replay=replay_selection_race('early-read-accepted-replay',agent,child,second,False)
 q('restore-final-accepted-replay-after-negative',final_accept)
 q('accepted-replay-exact-final-overlay',FINAL_OVERLAY.read_text())
 replayed=replay_selection_race('exact-replayed-accepted-replay',agent,child,second,True)
 assert q('after-controls-catalog',catalog)==before
 for name in FIXTURES:suite(name,'restored')
 RECEIPT.update(passed=True,sqlAssertions=FIXTURES,historicalSqlAssertions={**FIXTURES,'notification_session_fencing':27},historicalDeviceSuite=HISTORICAL_DEVICE_SUITE.name,exactReplay=True,unknownPredecessorsRefused=len(pins)+1,compiledNegativeControls=['two-org adoption','ledger deletion','device resurrection','actual child deadlock','accepted-invite early active read'],childRaceNegative=negative,childRacePositive=positive,acceptedReplayOld=old_replay,acceptedReplayCorrect=new_replay,acceptedReplayEarlyReadNegative=early_replay,acceptedReplayAfterExactReplay=replayed,historicalSafetyReplayAtOwnSchemaPoint=True,historicalFollowupReplayAtOwnSchemaPoint=True,supersededFollowupRefusedAtomic=True,finalOverlay=FINAL_OVERLAY.name)
finally:
 if started and(DATA/'postmaster.pid').exists():run('stop',[BIN['pg_ctl'],'-D',DATA,'-m','immediate','-w','stop'])
 RECEIPT['sourceHashesAfter']={n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest()for n in HASHES};RECEIPT['sourceUnchanged']=RECEIPT['sourceHashesAfter']==HASHES;RECEIPT['passed']=RECEIPT['passed']and RECEIPT['sourceUnchanged'];RECEIPT['finishedAt']=datetime.now(timezone.utc).isoformat();(OUT/'receipt.json').write_text(json.dumps(RECEIPT,indent=2)+'\n');(OUT/'receipt.json').chmod(0o600)
assert RECEIPT['passed'];print('PASS: 77 SQL assertions fresh/replay/restored, historical 75 retained, eight predecessor controls, actual child deadlock and four accepted-replay races',flush=True)
