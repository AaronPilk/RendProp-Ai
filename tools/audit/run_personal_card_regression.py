#!/usr/bin/env python3
"""Account-card authority/CAS/public identity proof in an owned socket-only DB."""
from datetime import datetime,timezone
import hashlib,json,os,pathlib,re,shutil,subprocess,tempfile,time
ROOT=pathlib.Path(__file__).resolve().parents[2];SQL=ROOT/'services/supabase'
MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'))
TARGET=SQL/'migrations/20261005160701_personal_public_card.sql';TEST=SQL/'tests/personal_public_card.sql'
ADOPTION_MIGRATION=SQL/'migrations/20261005181812_preserve_personal_card_on_anonymous_adoption.sql'
ADOPTION_TEST=SQL/'tests/personal_card_adoption.sql'
BASE_ADOPTION_TEST=SQL/'tests/anonymous_adoption_recovery.sql'
ADOPTION_COPY="  -- Both profiles and Auth identities are already locked and verified.\n  -- Receipt-only replay returns above, before any personal-card mutation.\n  v_personal_card_disposition := case\n    when (select public_card from public.profiles where id=p_user) is not null then 'destination_preserved'\n    when (select public_card from public.profiles where id=p_anon_user) is not null then 'source_copied'\n    else 'no_source_card' end;\n  update public.profiles target set public_card=source.public_card\n    from public.profiles source where target.id=p_user and source.id=p_anon_user\n      and target.public_card is null and source.public_card is not null;\n"
ADOPTION_DECLARATION="declare v_receipt jsonb; v_count integer;"
ADOPTION_RECEIPT="    'source_cleanup_pending',true);"
OUT=pathlib.Path(tempfile.mkdtemp(prefix='rendprop-adoption-db-personal-card-',dir='/tmp'));DATA=OUT/'cluster';SOCK=OUT/'socket';SOCK.mkdir(mode=0o700)
BINS={n:shutil.which(n)for n in ['initdb','pg_ctl','createdb','psql']};assert all(BINS.values())
ENV={'PATH':os.environ.get('PATH','/usr/bin:/bin'),'LC_ALL':'C','TZ':'UTC','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=5000'}
CONN=['-h',str(SOCK),'-p','55463','-U','postgres'];PSQL=[BINS['psql'],'-X','--no-password',*CONN,'-d','rendprop_card','-v','ON_ERROR_STOP=1']
tracked=[*MIGRATIONS,TEST,ADOPTION_TEST,BASE_ADOPTION_TEST,pathlib.Path(__file__).resolve(),SQL/'tests/ci-bootstrap.sql',SQL/'functions/me/card.ts',SQL/'functions/me/card.test.ts',SQL/'functions/me/index.ts',SQL/'functions/_shared/agentcard.ts',SQL/'functions/tours/index.ts']
hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in tracked}
receipt={'startedAt':datetime.now(timezone.utc).isoformat(),'sourceHashes':hashes,'limits':['Owned socket-only Postgres','Synthetic people, teams and object metadata','No hosted DB, mail, provider, Apple or real object writes'],'passed':False};started=False
def run(name,args,expected=0,timeout=45):
 r=subprocess.run([str(x)for x in args],env=ENV,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout);(OUT/(name+'.log')).write_text(r.stdout)
 assert r.returncode==expected,(name,r.returncode,r.stdout[-3000:]);return r.stdout
def query(name,sql,expected=0):
 p=OUT/(name+'.sql');p.write_text(sql);return run(name,[*PSQL,'-At','-f',p],expected)
def race(name,actor,first,second,same_field=False):
 f1=(OUT/(name+'-first.log')).open('w');f2=(OUT/(name+'-second.log')).open('w');p2=None
 p1=subprocess.Popen(PSQL,env={**ENV,'PGAPPNAME':'card-proof-first'},text=True,stdin=subprocess.PIPE,stdout=f1,stderr=subprocess.STDOUT)
 try:
  p1.stdin.write('begin;set local role service_role;'+first+'\n\\echo CARD_LOCK_HELD\n');p1.stdin.flush();deadline=time.monotonic()+5
  while 'CARD_LOCK_HELD'not in(OUT/(name+'-first.log')).read_text():
   assert p1.poll()is None and time.monotonic()<deadline;time.sleep(.03)
  path=OUT/(name+'-second.sql');path.write_text('set role service_role;'+second)
  p2=subprocess.Popen([*PSQL,'-f',path],env={**ENV,'PGAPPNAME':'card-proof-second'},text=True,stdout=f2,stderr=subprocess.STDOUT);deadline=time.monotonic()+5;blocked=False
  while time.monotonic()<deadline:
   if query(name+'-lock-observation',"select count(*)from pg_stat_activity where application_name='card-proof-second'and wait_event_type='Lock';").strip()=='1':blocked=True;break
   assert p2.poll()is None;time.sleep(.03)
  assert blocked,name+' did not observe actual profile serialization';p1.stdin.write('commit;\n\\q\n');p1.stdin.flush();p1.wait(timeout=10);p2.wait(timeout=10)
  assert p1.returncode==0 and p2.returncode==(3 if same_field else 0),(name,p1.returncode,p2.returncode)
  if same_field:assert 'RP409'in(OUT/(name+'-second.log')).read_text()
  result=query(name+'-final',f"select public_card->>'phone'='First phone'and {'not(public_card?\'website\')' if same_field else 'public_card->>\'website\'=\'https://second.fixture.invalid\''} from profiles where id='{actor}';")
  assert result.strip()=='t',result
  return{'name':name,'observedLock':True,'sameFieldConflict':same_field,'unrelatedFieldsPreserved':not same_field}
 finally:
  for p in[p1,p2]:
   if p and p.poll()is None:p.terminate();p.wait(timeout=10)
  f1.close();f2.close()
def adoption_race(n,subject,finish):
 name=f'adoption-{subject}-{finish}'
 source,destination,operation=[f'ca100513-0000-4000-8000-{n*10+i:012d}'for i in(1,2,4)]
 query(name+'-seed',f"insert into auth.users(id,email,is_anonymous)values('{source}','guest-race{n}@fixture.invalid',true),('{destination}','named-race{n}@fixture.invalid',false);")
 org=query(name+'-org',f"select org_id from memberships where user_id='{source}';").strip()
 query(name+'-guest-card',f"set role service_role;select merge_personal_public_card('{source}','{{\"name\":\"Guest baseline\",\"space_type\":\"real_estate\"}}','{{\"name\":{{\"present\":false}},\"space_type\":{{\"present\":false}}}}');")
 if subject=='source-save':
  first=f"select merge_personal_public_card('{source}','{{\"name\":\"Concurrent guest\"}}','{{\"name\":{{\"present\":true,\"value\":\"Guest baseline\"}}}}');"
 elif subject=='destination-save':
  first=f"select merge_personal_public_card('{destination}','{{\"name\":\"Concurrent destination\",\"space_type\":\"venue\"}}','{{\"name\":{{\"present\":false}},\"space_type\":{{\"present\":false}}}}');"
 else:first=f"select prepare_account_deletion('{destination}','fixture-uploads','fixture-renders');"
 f1=(OUT/(name+'-first.log')).open('w');f2=(OUT/(name+'-second.log')).open('w');p2=None
 p1=subprocess.Popen(PSQL,env={**ENV,'PGAPPNAME':name+'-first'},text=True,stdin=subprocess.PIPE,stdout=f1,stderr=subprocess.STDOUT)
 try:
  p1.stdin.write('begin;set local role service_role;'+first+'\n\\echo ADOPTION_FIRST_BOUNDARY_HELD\n');p1.stdin.flush();deadline=time.monotonic()+5
  while 'ADOPTION_FIRST_BOUNDARY_HELD'not in(OUT/(name+'-first.log')).read_text():
   assert p1.poll()is None and time.monotonic()<deadline,name;time.sleep(.03)
  path=OUT/(name+'-second.sql');path.write_text(f"set role service_role;select adopt_anonymous_org('{destination}','{source}','{org}','{operation}');")
  p2=subprocess.Popen([*PSQL,'-f',path],env={**ENV,'PGAPPNAME':name+'-second'},text=True,stdout=f2,stderr=subprocess.STDOUT);deadline=time.monotonic()+5;blocked=False
  while time.monotonic()<deadline:
   if query(name+'-lock-observation',f"select count(*)from pg_stat_activity where application_name='{name}-second'and wait_event_type='Lock';").strip()=='1':blocked=True;break
   assert p2.poll()is None,name;time.sleep(.03)
  assert blocked,name+' did not hold the actual profile/Auth boundary'
  p1.stdin.write(f'{finish};\n\\q\n');p1.stdin.flush();p1.wait(timeout=10);p2.wait(timeout=10)
  refused=subject=='deletion'and finish=='commit'
  assert p1.returncode==0 and p2.returncode==(3 if refused else 0),(name,p1.returncode,p2.returncode)
  if refused:assert 'RP409: an account is being deleted'in(OUT/(name+'-second.log')).read_text()
  state=json.loads(query(name+'-final',f"select json_build_object('name',(select public_card->>'name'from profiles where id='{destination}'),'space_type',(select public_card->>'space_type'from profiles where id='{destination}'),'source_member',exists(select 1 from memberships where user_id='{source}'and org_id='{org}'),'destination_member',exists(select 1 from memberships where user_id='{destination}'and org_id='{org}'),'receipts',(select count(*)from anonymous_adoption_receipts where source_user_id='{source}'));"))
  expected_name=None if refused else 'Concurrent guest'if subject=='source-save'and finish=='commit'else 'Concurrent destination'if subject=='destination-save'and finish=='commit'else 'Guest baseline'
  expected_type=None if refused else 'venue'if subject=='destination-save'and finish=='commit'else 'real_estate'
  assert state=={'name':expected_name,'space_type':expected_type,'source_member':refused,'destination_member':not refused,'receipts':0 if refused else 1},(name,state)
  return{'name':name,'observedLock':True,'firstTransaction':finish,'refusedForDeletion':refused,'finalState':state}
 finally:
  for p in[p1,p2]:
   if p and p.poll()is None:p.terminate();p.wait(timeout=10)
  f1.close();f2.close()
try:
 run('init',[BINS['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[BINS['pg_ctl'],'-D',DATA,'-l',OUT/'postgres.log','-w','-t','30','-o',f"-k {SOCK} -p 55463 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=15",'start']);started=True
 run('create',[BINS['createdb'],'--no-password',*CONN,'rendprop_card'])
 assert query('identity',"select current_setting('data_directory')||'|'||current_setting('listen_addresses')||'|'||current_database();").strip()==f'{DATA}||rendprop_card'
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for p in MIGRATIONS:
  if p==ADOPTION_MIGRATION:
   adoption_before=query('adoption-before-definition',"select pg_get_functiondef('adopt_anonymous_org(uuid,uuid,uuid,uuid)'::regprocedure);")
   adoption_acl=query('adoption-before-acl',"select json_build_object('acl',proacl,'owner',proowner,'definer',prosecdef,'config',proconfig)from pg_proc where oid='adopt_anonymous_org(uuid,uuid,uuid,uuid)'::regprocedure;")
  run('apply-'+p.stem,[*PSQL,'-q','-1','-f',p])
  if p==ADOPTION_MIGRATION:
   # Bind the historical transform oracle to its own migration boundary.
   # Later reviewed migrations may legitimately change adoption lock ordering
   # or library selection; they must not erase this exact-additions proof.
   historical_after=query('adoption-historical-after-definition',"select pg_get_functiondef('adopt_anonymous_org(uuid,uuid,uuid,uuid)'::regprocedure);")
   assert historical_after.count(ADOPTION_COPY)==1
   adoption_stripped=historical_after.replace(ADOPTION_COPY,'').replace(ADOPTION_DECLARATION+' v_personal_card_disposition text;',ADOPTION_DECLARATION).replace(ADOPTION_RECEIPT.replace('true);',"true,'personal_card_disposition',v_personal_card_disposition);"),ADOPTION_RECEIPT)
   assert adoption_stripped==adoption_before,'Unrelated adoption body changed'
   assert query('adoption-historical-after-acl',"select json_build_object('acl',proacl,'owner',proowner,'definer',prosecdef,'config',proconfig)from pg_proc where oid='adopt_anonymous_org(uuid,uuid,uuid,uuid)'::regprocedure;")==adoption_acl,'Adoption ACL/owner/definer/config changed'
   run('adoption-historical-migration-replay',[*PSQL,'-q','-1','-f',ADOPTION_MIGRATION])
   assert query('adoption-historical-replayed-definition',"select pg_get_functiondef('adopt_anonymous_org(uuid,uuid,uuid,uuid)'::regprocedure);")==historical_after
 adoption_after=query('adoption-after-definition',"select pg_get_functiondef('adopt_anonymous_org(uuid,uuid,uuid,uuid)'::regprocedure);")
 assert adoption_after.count(ADOPTION_COPY)==1
 assert query('adoption-after-acl',"select json_build_object('acl',proacl,'owner',proowner,'definer',prosecdef,'config',proconfig)from pg_proc where oid='adopt_anonymous_org(uuid,uuid,uuid,uuid)'::regprocedure;")==adoption_acl,'Adoption ACL/owner/definer/config changed'
 run('adoption-migration-replay',[*PSQL,'-q','-1','-f',ADOPTION_MIGRATION])
 assert query('adoption-replayed-definition',"select pg_get_functiondef('adopt_anonymous_org(uuid,uuid,uuid,uuid)'::regprocedure);")==adoption_after,'Historical card replay changed current adoption definition'
 receipt['adoptionWriter']={'onlyThreeReviewedAdditions':True,'historicalBoundaryVerified':True,'ACLAndDefinerUnchanged':True,'exactHistoricalReplayNoOp':True,'exactReplayNoOp':True,'currentDefinitionReplayNoOp':True}
 adoption_positive=run('card-adoption-positive',[*PSQL,'-At','-f',ADOPTION_TEST]);assert 'PASS: personal card adoption SQL assertions; all fixtures rolled back.'in adoption_positive
 adoption_controls=[]
 for name,anchor,replacement,reason in[
  ('omit-reviewed-card-adoption',ADOPTION_COPY,'','guest reviewed card follows verified adoption'),
  ('overwrite-reviewed-destination','target.public_card is null and source.public_card is not null','source.public_card is not null','explicit empty destination card is preserved'),
  ('rewrite-historical-receipt',"-- Receipt-only replays do not change workspace selection or lock Auth rows.\n  v_receipt := public.adoption_receipt(p_user,p_anon_user,p_operation);\n  if v_receipt is not null then\n    if (v_receipt->>'org_id')::uuid <> p_anon_org then raise exception 'RP403: workspace binding does not match'; end if;\n    return v_receipt;","-- Receipt-only replays do not change workspace selection or lock Auth rows.\n  v_receipt := public.adoption_receipt(p_user,p_anon_user,p_operation);\n  if v_receipt is not null then\n    if (v_receipt->>'org_id')::uuid <> p_anon_org then raise exception 'RP403: workspace binding does not match'; end if;\n    return v_receipt || jsonb_build_object('personal_card_disposition','destination_preserved');",'replayed receipt keeps its historical source-copy decision'),
 ]:
  assert adoption_after.count(anchor)==1
  query(name+'-apply',adoption_after.replace(anchor,replacement))
  failed=run(name+'-negative',[*PSQL,'-At','-f',ADOPTION_TEST],3);assert 'CARD ADOPTION FAIL: '+reason in failed
  query(name+'-restore',adoption_after)
  restored=run(name+'-restored',[*PSQL,'-At','-f',ADOPTION_TEST]);assert 'PASS: personal card adoption SQL assertions; all fixtures rolled back.'in restored
  adoption_controls.append(name)
 check=re.search(r'\n(\d+)\nPASS: personal card adoption SQL',adoption_positive);assert check
 receipt['adoptionSQLAssertions']=int(check[1]);receipt['adoptionNegativeControls']=adoption_controls
 # The historical authority fixture refuses any database name except its
 # owned adoption fixture. Clone this complete schema, retaining that guard.
 run('create-adoption-compatibility-db',[BINS['createdb'],'--no-password',*CONN,'--template','rendprop_card','rendprop_adoption_audit'])
 adoption_psql=[BINS['psql'],'-X','--no-password',*CONN,'-d','rendprop_adoption_audit','-v','ON_ERROR_STOP=1']
 baseline=run('existing-adoption-positive',[*adoption_psql,'-At','-f',BASE_ADOPTION_TEST]);assert 'PASS: 35 adoption SQL assertions; all fixtures rolled back.'in baseline
 receipt['existingAdoptionSQLAssertions']=35
 positive=run('card-positive',[*PSQL,'-At','-f',TEST]);assert 'PASS: personal card SQL assertions; all fixtures rolled back.'in positive
 body=query('cas-definition',"select pg_get_functiondef('merge_personal_public_card(uuid,jsonb,jsonb)'::regprocedure);")
 guard="if (current_card?k) is distinct from (e->>'present')::boolean or\n   ((e->>'present')::boolean and current_card->k is distinct from e->'value') then"
 assert body.count(guard)==1
 query('drop-cas-apply',body.replace(guard,'if false then'))
 failed=run('drop-cas-negative',[*PSQL,'-At','-f',TEST],3);assert 'CARD FAIL: stale same-field save conflicts'in failed
 run('drop-cas-restore',[*PSQL,'-q','-1','-f',TARGET]);run('drop-cas-restored',[*PSQL,'-At','-f',TEST])
 query('ordinary-grant-apply','grant update(public_card)on profiles to authenticated;')
 failed=run('ordinary-grant-negative',[*PSQL,'-At','-f',TEST],3);assert 'CARD FAIL: personal card column cannot be directly updated'in failed
 run('ordinary-grant-restore',[*PSQL,'-q','-1','-f',TARGET]);run('ordinary-grant-restored',[*PSQL,'-At','-f',TEST])
 receipt['negativeControls']=['drop-personal-card-cas','restore-direct-public-card-grant'];races=[]
 for n,same in[(1,False),(2,True)]:
  actor=f'ca100504-0000-4000-8000-{n:012d}';query(f'race{n}-seed',f"insert into auth.users(id,email,is_anonymous)values('{actor}','race{n}@fixture.invalid',false);")
  first=f"select merge_personal_public_card('{actor}','{{\"phone\":\"First phone\"}}','{{\"phone\":{{\"present\":false}}}}');"
  second=f"select merge_personal_public_card('{actor}','{{\"{'phone'if same else 'website'}\":\"{'Second phone'if same else 'https://second.fixture.invalid'}\"}}','{{\"{'phone'if same else 'website'}\":{{\"present\":false}}}}');"
  races.append(race('same-field-first-wins'if same else 'unrelated-fields-merge',actor,first,second,same))
 receipt['races']=races
 receipt['adoptionRaces']=[adoption_race(n,subject,finish)for n,(subject,finish)in enumerate([(s,f)for s in['source-save','destination-save','deletion']for f in['commit','rollback']],1)]
 assert all(hashlib.sha256((ROOT/n).read_bytes()).hexdigest()==h for n,h in hashes.items()),'Source changed during proof'
 check=re.search(r'\n(\d+)\nPASS: personal card SQL',positive);assert check
 receipt.update(passed=True,sqlAssertions=int(check[1]))
finally:
 if started and(DATA/'postmaster.pid').exists():run('stop',[BINS['pg_ctl'],'-D',DATA,'-m','fast','-w','-t','30','stop'])
 receipt['finishedAt']=datetime.now(timezone.utc).isoformat();(OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print('Personal card evidence:',OUT,flush=True)
print('PASS: account identity, public member fallback, profile CAS mutants and actual races.',flush=True)
