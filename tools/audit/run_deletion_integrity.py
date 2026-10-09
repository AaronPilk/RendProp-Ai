#!/usr/bin/env python3
"""Owned disposable PostgreSQL and optional real loopback PostgREST boundaries.

No inherited credentials, hosted DB, external services, or destructive user data.
Pass an existing reviewed PostgREST binary for HTTP proof; no installer runs here.
"""
from pathlib import Path
import argparse, base64, hashlib, hmac, importlib.util, json, os, shutil, signal
import socket, subprocess, tempfile, time, urllib.request, urllib.error, uuid, select, re

ROOT=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser()
parser.add_argument('--postgrest',type=Path)
args=parser.parse_args()
if args.postgrest: args.postgrest=args.postgrest.resolve(strict=True)
SQL=ROOT/'services/supabase'
MIGRATION=next((SQL/'migrations').glob('*_account_deletion_integrity.sql'))
FIXTURE=SQL/'tests/account_deletion_integrity.sql'
TOOLS={n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)for n in ['initdb','pg_ctl','psql','createdb']}
if not all(Path(x).is_file()for x in TOOLS.values()):raise SystemExit('Existing PostgreSQL tools required')
OUT=Path(tempfile.mkdtemp(prefix='rendprop-deletion-integrity-',dir='/tmp'));os.chmod(OUT,0o700)
DATA,SOCK=OUT/'data',OUT/'socket';SOCK.mkdir(mode=0o700)
ENV={'PATH':'/usr/bin:/bin','LC_ALL':'C','TZ':'UTC','PGOPTIONS':'-c statement_timeout=15000 -c lock_timeout=7000'}
PORT='55492';DB='deletion_integrity'
psql=[TOOLS['psql'],'-X','--no-password','-h',str(SOCK),'-p',PORT,'-U','postgres','-d',DB,'-v','ON_ERROR_STOP=1']
sources=[*sorted((SQL/'migrations').glob('*.sql')),SQL/'tests/ci-bootstrap.sql',FIXTURE,SQL/'tests/invariants.sql',SQL/'tests/invariant_astra_paid_gates.sql',ROOT/'tools/audit/run_database_regression.py',Path(__file__)]
receipt={'kind':'disposable PostgreSQL; optional actual loopback PostgREST14.5','passed':False,'commands':[],'http':[],
 'sourceHashes':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in sources},'clusterStopped':False,'networkScope':'loopback only after optional reviewed binary is supplied'}
def save(p,b):p.write_bytes(b);os.chmod(p,0o600)
def run(name,argv,sql=None,expected=0,environment=None):
 p=subprocess.run([str(x)for x in argv],input=sql,text=True,env=environment or ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
 f=OUT/(name+'.log');save(f,p.stdout.encode());receipt['commands'].append({'name':name,'exit':p.returncode,'log':str(f),'sha256':hashlib.sha256(f.read_bytes()).hexdigest()})
 if p.returncode!=expected:raise RuntimeError(f'{name}: exit {p.returncode}, expected {expected}; {f}')
 print(name+': pass',flush=True);return p.stdout
def sql(name,body,expected=0):return run(name,psql+['-Atq'],body,expected)
def invariants(name):
 p=subprocess.run(psql+['-f',str(SQL/'tests/invariants.sql')],env=ENV,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
 f=OUT/(name+'.log');save(f,p.stdout.encode());receipt['commands'].append({'name':name,'exit':p.returncode,'log':str(f),'sha256':hashlib.sha256(f.read_bytes()).hexdigest()})
 spec=importlib.util.spec_from_file_location('invariant_contract',ROOT/'tools/audit/run_database_regression.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
 rows,failed=m.invariant_rows(p.stdout,p.returncode)
 if p.returncode!=0 or failed or len(rows)!=270:raise RuntimeError('All270 invariant gate failed')
 print(name+': all270 pass',flush=True)
def stop(p):
 try:os.killpg(p.pid,signal.SIGTERM)
 except ProcessLookupError:pass
 try:p.wait(timeout=2)
 except subprocess.TimeoutExpired:pass
 try:os.killpg(p.pid,signal.SIGKILL)
 except ProcessLookupError:pass
 p.wait(timeout=5)

def joined_workspace_race(name,removed_recheck=False):
 """Two actual writer sessions; an observer proves the exact blocking PID."""
 actor,joiner,lid=[str(uuid.uuid4())for _ in range(3)]
 token_hash=hashlib.sha256(uuid.uuid4().bytes).hexdigest()
 # This original post-org-lock recheck protects historical shared libraries.
 # A synthetic Pro seat cap retains that exact custody race without the new
 # private-Team participant guard serializing it earlier on owner profiles.
 sql(name+'-setup',f"""insert into auth.users(id,email,raw_user_meta_data,is_anonymous)values('{actor}','join-owner@fixture.invalid','{{}}',false),('{joiner}','join-agent@fixture.invalid','{{}}',false);update public.plan_entitlements set seats=2 where plan='pro';update public.orgs set plan='pro',plan_source='manual'where id=(select org_id from public.memberships where user_id='{actor}');insert into public.listings(id,org_id,agent_id,address)select '{lid}',org_id,'{actor}','join race custody'from public.memberships where user_id='{actor}';set role service_role;select public.create_org_invite('{actor}',(select org_id from public.memberships where user_id='{actor}'),'join-agent@fixture.invalid','agent','{token_hash}');""")
 holder=deleter=None;prefix=b''
 try:
  holder=subprocess.Popen(psql+['-Atq'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=ENV,cwd=ROOT,start_new_session=True)
  first=f"begin;set local role service_role;select id from public.orgs where id=(select org_id from public.memberships where user_id='{actor}')for update;select 'join-lock-ready:'||pg_backend_pid();\n"
  save(OUT/(name+'-holder.sql'),first.encode())
  holder.stdin.write(first.encode());holder.stdin.flush()
  deadline=time.monotonic()+10
  while b'join-lock-ready:'not in prefix:
   remaining=deadline-time.monotonic()
   if remaining<=0 or not select.select([holder.stdout],[],[],remaining)[0]:raise RuntimeError('Join holder readiness timed out')
   chunk=os.read(holder.stdout.fileno(),4096)
   if not chunk:raise RuntimeError('Join holder exited before its lock')
   prefix+=chunk
  backend=int(re.search(rb'join-lock-ready:(\d+)',prefix).group(1))
  app='deletion-join-'+uuid.uuid4().hex
  command=f"set application_name='{app}';set role service_role;select public.prepare_account_deletion('{actor}','fixture-uploads','fixture-renders');"
  save(OUT/(name+'-deletion.sql'),command.encode())
  deleter=subprocess.Popen(psql+['-Atq','-c',command],env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True)
  observed=False
  for poll in range(40):
   waiting=sql(name+f'-lock-observation-{poll:02d}',f"select exists(select 1 from pg_stat_activity a where a.application_name='{app}'and a.wait_event_type='Lock'and {backend}=any(pg_blocking_pids(a.pid))); ").strip()
   if waiting=='t':observed=True;break
   if deleter.poll()is not None:raise RuntimeError('Deletion exited before the required join wait')
   time.sleep(.025)
  if not observed:raise RuntimeError('Exact join backend blocking deletion was not observed')
  finish=f"select public.accept_org_invite('{joiner}','{token_hash}');commit;\n"
  save(OUT/(name+'-holder-commit.sql'),finish.encode())
  holder.stdin.write(finish.encode());holder.stdin.flush();holder.stdin.close();holder.stdin=None
  rest=holder.communicate(timeout=10)[0];save(OUT/(name+'-holder.log'),prefix+rest)
  if holder.returncode:raise RuntimeError('Actual invite acceptance failed')
  output=deleter.communicate(timeout=10)[0];log=OUT/(name+'-deletion.log');save(log,output)
  # psql's single -c command exits1 on a SQL error; -f/stdin with
  # ON_ERROR_STOP exits3. The exact refusal and custody oracle remain required.
  expected=0 if removed_recheck else 1
  receipt['commands'].append({'name':name+'-deletion','exit':deleter.returncode,'log':str(log),'sha256':hashlib.sha256(log.read_bytes()).hexdigest()})
  if deleter.returncode!=expected:raise RuntimeError('Join race deletion result differs')
  if not removed_recheck and b'Transfer ownership'not in output:raise RuntimeError('Join race refused for an unrelated reason')
  oracle=f"""do $o$begin if not exists(select 1 from public.memberships where user_id='{actor}'and role='owner')or not exists(select 1 from public.memberships a join public.memberships b using(org_id)where a.user_id='{actor}'and b.user_id='{joiner}'and b.role='agent')or not exists(select 1 from public.listings where id='{lid}'and agent_id='{actor}')or exists(select 1 from public.deletion_requests where user_id='{actor}')then raise exception 'FAIL deletion integrity: joined workspace retains owner listing and no deletion intent';end if;end$o$;"""
  outcome=sql(name+'-custody-oracle',oracle,3 if removed_recheck else 0)
  if removed_recheck and 'FAIL deletion integrity: joined workspace retains owner listing and no deletion intent'not in outcome:raise RuntimeError('Removed post-lock check failed for wrong reason')
  return {'exactBlockObserved':True,'actualInviteCommitted':True,'deletionExit':deleter.returncode,'custodyOracleExit':3 if removed_recheck else 0,'removedRecheck':removed_recheck}
 finally:
  for process in [deleter,holder]:
   if process is not None:
    stop(process)
    for pipe in [process.stdin,process.stdout]:
     if pipe:pipe.close()

def private_team_join_deletion_race(name):
 """Actual Team acceptance commits while deletion waits at its earliest lock."""
 actor,joiner,lid=[str(uuid.uuid4())for _ in range(3)]
 token_hash=hashlib.sha256(uuid.uuid4().bytes).hexdigest()
 sql(name+'-setup',f"insert into auth.users(id,email,is_anonymous)values('{actor}','private-owner@fixture.invalid',false),('{joiner}','private-agent@fixture.invalid',false);update public.orgs set plan='team',plan_source='manual'where id=(select org_id from public.memberships where user_id='{actor}');insert into public.listings(id,org_id,agent_id,address)select '{lid}',org_id,'{actor}','private Team custody'from public.memberships where user_id='{actor}';set role service_role;select public.create_org_invite('{actor}',(select org_id from public.memberships where user_id='{actor}'),'private-agent@fixture.invalid','agent','{token_hash}');")
 holder=deleter=None;prefix=b''
 try:
  holder=subprocess.Popen(psql+['-Atq'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=ENV,cwd=ROOT,start_new_session=True)
  first=f"begin;set local role service_role;select public.accept_org_invite('{joiner}','{token_hash}');select 'private-team-ready:'||pg_backend_pid();\n"
  save(OUT/(name+'-acceptance.sql'),first.encode());holder.stdin.write(first.encode());holder.stdin.flush()
  deadline=time.monotonic()+10
  while b'private-team-ready:'not in prefix:
   remaining=deadline-time.monotonic()
   if remaining<=0 or not select.select([holder.stdout],[],[],remaining)[0]:raise RuntimeError('Private Team acceptance readiness timed out')
   chunk=os.read(holder.stdout.fileno(),4096)
   if not chunk:raise RuntimeError('Private Team acceptance exited before holding its actual locks')
   prefix+=chunk
  backend=int(re.search(rb'private-team-ready:(\d+)',prefix).group(1));app='private-team-delete-'+uuid.uuid4().hex
  command=f"set application_name='{app}';set role service_role;select public.prepare_account_deletion('{actor}','fixture-uploads','fixture-renders');"
  save(OUT/(name+'-deletion.sql'),command.encode());deleter=subprocess.Popen(psql+['-Atq','-c',command],env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True)
  observed=False
  for poll in range(40):
   waiting=sql(name+f'-blocking-{poll:02d}',f"select exists(select 1 from pg_stat_activity a where a.application_name='{app}'and a.wait_event_type='Lock'and {backend}=any(pg_blocking_pids(a.pid))); ").strip()
   if waiting=='t':observed=True;break
   if deleter.poll()is not None:raise RuntimeError('Private Team deletion failed before its actual acceptance wait')
   time.sleep(.025)
  if not observed:raise RuntimeError('Private Team exact acceptance backend did not block deletion')
  holder.stdin.write(b'commit;\n');holder.stdin.flush();holder.stdin.close();holder.stdin=None
  rest=holder.communicate(timeout=10)[0];save(OUT/(name+'-accepted.log'),prefix+rest)
  if holder.returncode:raise RuntimeError('Private Team acceptance did not commit')
  output=deleter.communicate(timeout=10)[0];save(OUT/(name+'-deletion.log'),output)
  if deleter.returncode!=1 or b'Transfer ownership'not in output or b'deadlock detected'in output:raise RuntimeError('Private Team deletion must refuse ownership transfer, never deadlock')
  sql(name+'-custody',f"do $o$begin if not exists(select 1 from public.team_private_libraries b where b.team_owner_user_id='{actor}'and b.agent_user_id='{joiner}'and public.team_library_binding_valid(b.id))or not exists(select 1 from public.listings where id='{lid}'and agent_id='{actor}')or exists(select 1 from public.deletion_requests where user_id='{actor}')then raise exception 'FAIL deletion integrity: private Team acceptance preserves owner custody';end if;end$o$;")
  return {'actualAcceptanceHeldLocks':True,'exactBlockObserved':True,'acceptedPrivateRelation':True,'deletionRefusedTransfer':True,'noDeletionIntent':True,'noDeadlock':True}
 finally:
  for process in [deleter,holder]:
   if process is not None:
    stop(process)
    for pipe in [process.stdin,process.stdout]:
     if pipe:pipe.close()

started=False;httpd=None;http_log=None
print('EVIDENCE: '+str(OUT),flush=True)
try:
 run('initdb',[TOOLS['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[TOOLS['pg_ctl'],'-D',DATA,'-l',OUT/'postgres.log','-w','-t','30','-o',f"-k {SOCK} -p {PORT} -c listen_addresses='' -c shared_buffers=16MB -c max_connections=15",'start']);started=True
 run('createdb',[TOOLS['createdb'],'--no-password','-h',SOCK,'-p',PORT,'-U','postgres',DB])
 identity=sql('owned-identity',"select current_setting('data_directory'),current_setting('listen_addresses'),current_database();").strip()
 if identity!=str(DATA)+'||'+DB:raise RuntimeError('Owned cluster identity differs')
 run('bootstrap',psql+['-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for f in sorted((SQL/'migrations').glob('*.sql')):run('apply-'+f.stem,psql+['-q','-1','-f',f])
 for phase in ['fresh','replay']:
  if phase=='replay':run('replay-integrity',psql+['-q','-1','-f',MIGRATION])
  out=run(phase+'-fixture',psql+['-f',FIXTURE])
  if 'PASS account deletion integrity: 29 assertions'not in out or out.count('NOTICE:  ok ')!=29:raise RuntimeError('Incomplete fixture proof')
  invariants(phase+'-invariants')
 # Actual guard removal: replay the unchanged positive fixture after removing
 # only the one preflight invocation; it must now fail before claiming safety.
 mutant="""begin;do $m$declare d text;begin d:=pg_get_functiondef('public.prepare_account_deletion(uuid,text,text)'::regprocedure);execute replace(d,E'  perform public.account_deletion_integrity_preflight(p_user);\\n','');end$m$;"""
 mutated=OUT/'removed-preflight.sql';save(mutated,(mutant+'\n'+FIXTURE.read_text().replace('begin;','',1)).encode())
 bad=run('removed-preflight-rejected',psql+['-f',mutated],expected=3)
 if 'FAIL deletion integrity: former-member listing reference refuses before solo purge'not in bad:raise RuntimeError('Preflight mutation failed for unrelated reason')
 # psql disconnect rolls the mutation/fixtures back. Recheck restored schema.
 sql('restored-preflight',"select position('account_deletion_integrity_preflight' in pg_get_functiondef('public.prepare_account_deletion(uuid,text,text)'::regprocedure))>0;")
 receipt['privateTeamJoinRace']=private_team_join_deletion_race('private-team-join-deletion-race')
 receipt['joinRace']=joined_workspace_race('joined-workspace-race')
 # Remove exactly the post-org-lock invocation, preserving the early check.
 sql('remove-post-lock-recheck',"""do $m$declare d text;a text:=$a$  perform public.account_deletion_integrity_preflight(p_user);
  select coalesce(array_agg(o),'{}'::uuid[]) into solo from unnest(all_orgs) o$a$;b text:=$b$  select coalesce(array_agg(o),'{}'::uuid[]) into solo from unnest(all_orgs) o$b$;begin d:=pg_get_functiondef('public.prepare_account_deletion(uuid,text,text)'::regprocedure);if(length(d)-length(replace(d,a,'')))/length(a)<>1 then raise exception 'Post-lock mutation target differs';end if;execute replace(d,a,b);end$m$;""")
 receipt['removedJoinRecheck']=joined_workspace_race('removed-joined-workspace-recheck',True)
 run('restore-post-lock-recheck',psql+['-q','-1','-f',MIGRATION])
 # A real concurrent insertion must wait for Auth lock, then see pending intent.
 actor,owner,lid=[str(uuid.uuid4())for _ in range(3)]
 setup=f"""insert into auth.users(id,email,raw_user_meta_data)values('{actor}','race-subject@fixture.invalid','{{}}'),('{owner}','race-owner@fixture.invalid','{{}}');insert into public.listings(id,org_id,agent_id,address)select '{lid}',org_id,'{actor}','race solo'from public.memberships where user_id='{actor}';"""
 sql('race-setup',setup)
 hold=OUT/'deletion-race-hold.sql';save(hold,f"begin;set local role service_role;select public.prepare_account_deletion('{actor}','fixture-uploads','fixture-renders');select 'deletion-intent-ready';select pg_sleep(1);commit;".encode())
 p=subprocess.Popen(psql+['-Atq','-f',str(hold)],env=ENV,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 lines=[]
 while True:
  line=p.stdout.readline();lines.append(line)
  if 'deletion-intent-ready'in line:break
  if not line:raise RuntimeError('Race holder exited before confirmed intent')
 denied=sql('late-reference-race',f"set role service_role;insert into public.listings(org_id,agent_id,address)select org_id,'{actor}','late race'from public.memberships where user_id='{owner}';",3)
 if 'Account deletion is in progress'not in denied:raise RuntimeError('Concurrent insertion refused for wrong reason')
 rest=p.communicate(timeout=10)[0];save(OUT/'deletion-race-holder.log',(''.join(lines)+rest).encode())
 if p.returncode:raise RuntimeError('Race deletion failed')
 receipt['race']={'deletionCommitted':True,'lateReferenceRejected':True,'holderLog':str(OUT/'deletion-race-holder.log')}

 if args.postgrest:
  receipt['postgrestBinary']={'path':str(args.postgrest),'sha256':hashlib.sha256(args.postgrest.read_bytes()).hexdigest()}
  http_env={'PATH':'/usr/bin:/bin','LC_ALL':'C'}
  # Official macOS14.5 binary links libpq from Homebrew. Reuse only the libpq
  # belonging to these already selected local PostgreSQL tools; never inherit
  # a dynamic-library override or change a system installation.
  pq=Path(TOOLS['psql']).resolve().parent.parent/'lib/postgresql/libpq.5.dylib'
  if os.uname().sysname=='Darwin' and pq.is_file():
   http_env['DYLD_LIBRARY_PATH']=str(pq.parent)
   receipt['postgrestLibpq']={'path':str(pq),'sha256':hashlib.sha256(pq.read_bytes()).hexdigest()}
  run('postgrest-version',[args.postgrest,'--version'],environment=http_env)
  sql('postgrest-role',"create role deletion_http login noinherit;grant anon,authenticated,service_role to deletion_http;")
  owner,member,removed=[str(uuid.uuid4())for _ in range(3)];owner_listing,removed_listing,service_listing=[str(uuid.uuid4())for _ in range(3)]
  sql('http-fixtures',f"""insert into auth.users(id,email,raw_user_meta_data)values('{owner}','http-owner@fixture.invalid','{{}}'),('{member}','http-admin@fixture.invalid','{{}}'),('{removed}','http-removed@fixture.invalid','{{}}');insert into public.memberships(org_id,user_id,role)select org_id,'{member}','admin'from public.memberships where user_id='{owner}';insert into public.listings(id,org_id,agent_id,address)select '{owner_listing}',org_id,'{owner}','http owned'from public.memberships where user_id='{owner}';insert into public.listings(id,org_id,agent_id,address)select '{service_listing}',org_id,'{owner}','service fixture'from public.memberships where user_id='{owner}';insert into public.listings(id,org_id,agent_id,address)select '{removed_listing}',org_id,'{removed}','former assignee'from public.memberships where user_id='{owner}';""")
  sock=socket.socket();sock.bind(('127.0.0.1',0));http_port=sock.getsockname()[1];sock.close()
  secret='synthetic-disposable-deletion-jwt-secret-not-a-real-credential-20261007'
  config=OUT/'postgrest.conf';save(config,f'db-uri = "postgresql://deletion_http@/{DB}?host={SOCK}&port={PORT}"\ndb-schemas = "public"\ndb-anon-role = "anon"\nserver-host = "127.0.0.1"\nserver-port = {http_port}\njwt-secret = "{secret}"\ndb-pool = 3\n'.encode())
  http_log=open(OUT/'postgrest.log','wb');os.chmod(OUT/'postgrest.log',0o600)
  httpd=subprocess.Popen([str(args.postgrest),str(config)],env=http_env,cwd=OUT,stdout=http_log,stderr=subprocess.STDOUT,start_new_session=True)
  opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
  origin=f'http://127.0.0.1:{http_port}'
  for _ in range(50):
   if httpd.poll()is not None:raise RuntimeError('PostgREST exited; inspect private log')
   try:
    with opener.open(origin+'/',timeout=1):break
   except(urllib.error.URLError,urllib.error.HTTPError):time.sleep(.1)
  else:raise RuntimeError('Loopback PostgREST did not start')
  def token(role,sub):
   enc=lambda b:base64.urlsafe_b64encode(b).rstrip(b'=')
   a=enc(b'{"alg":"HS256","typ":"JWT"}')+b'.'+enc(json.dumps({'role':role,'sub':sub,'exp':int(time.time())+300}).encode())
   return(a+b'.'+enc(hmac.new(secret.encode(),a,hashlib.sha256).digest())).decode()
  def request(name,method,path,role,sub,expected,body=None,fragment=None):
   headers={'Authorization':'Bearer '+token(role,sub),'Content-Type':'application/json','Prefer':'return=representation'}
   req=urllib.request.Request(origin+path,data=json.dumps(body).encode()if body is not None else None,headers=headers,method=method)
   try:
    with opener.open(req,timeout=10)as r:status,data=r.status,r.read(1000000)
   except urllib.error.HTTPError as e:status,data=e.code,e.read(1000000)
   f=OUT/(name+'.http.json');save(f,json.dumps({'status':status,'body':data.decode()},indent=2).encode());receipt['http'].append({'name':name,'status':status,'path':path,'response':str(f),'sha256':hashlib.sha256(f.read_bytes()).hexdigest()})
   if status!=expected or(fragment and fragment not in data.decode()):raise RuntimeError(f'{name}: unexpected HTTP result; {f}')
  request('owner-hard-delete','DELETE','/listings?id=eq.'+owner_listing,'authenticated',owner,403,fragment='permission denied')
  request('admin-hard-delete','DELETE','/listings?id=eq.'+owner_listing,'authenticated',member,403,fragment='permission denied')
  request('authenticated-preflight-private','POST','/rpc/account_deletion_integrity_preflight','authenticated',owner,403,{'p_user':removed})
  request('former-member-delete-preflight','POST','/rpc/prepare_account_deletion','service_role',owner,400,{'p_user':removed,'p_upload_bucket':'fixture-uploads','p_render_bucket':'fixture-renders'},'former workspace')
  retained=sql('http-refusal-preserves-solo',f"select count(*)from public.memberships where user_id='{removed}';").strip()
  if retained!='1':raise RuntimeError('HTTP refusal lost solo workspace')
  request('owner-soft-delete','PATCH','/listings?id=eq.'+owner_listing,'authenticated',owner,200,{'deleted_at':'2026-10-07T00:00:00Z'},'deleted_at')
  queued=sql('http-soft-delete-inventory',f"select count(*)from public.privacy_cleanup_jobs where kind='listing'and source_id='{owner_listing}';").strip()
  if queued!='1':raise RuntimeError('HTTP soft delete did not queue cleanup')
  request('service-hard-delete-preserved','DELETE','/listings?id=eq.'+service_listing,'service_role',owner,200,fragment=service_listing)
  receipt['realPostgrestHTTPPassed']=True
 else:receipt['realPostgrestHTTPPassed']=False
 if any(hashlib.sha256(p.read_bytes()).hexdigest()!=receipt['sourceHashes'][str(p.relative_to(ROOT))]for p in sources):raise RuntimeError('Source changed during proof')
 receipt['passed']=True
finally:
 if httpd:stop(httpd)
 if http_log:http_log.close()
 if started:
  result=subprocess.run([TOOLS['pg_ctl'],'-D',str(DATA),'-m','immediate','-w','-t','20','stop'],env=ENV,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
  save(OUT/'stop.log',result.stdout);receipt['clusterStopped']=result.returncode==0
 save(OUT/'receipt.json',json.dumps(receipt,indent=2).encode())
 print('RECEIPT: '+str(OUT/'receipt.json'),flush=True)
