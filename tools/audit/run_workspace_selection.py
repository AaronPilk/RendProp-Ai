#!/usr/bin/env python3
"""Workspace directory/selection, membership races and request-scope regressions.

Owns a disposable socket-only Postgres cluster; no external auth or network.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib,json,os,pathlib,re,shutil,subprocess,tempfile,time
ROOT=pathlib.Path(__file__).resolve().parents[2];SQL=ROOT/'services/supabase'
TARGET=SQL/'migrations/20261001145730_workspace_selection.sql'
UPLOAD_SUPPORT=['transport.ts','gateway_contract.ts','content_type.ts']
STUDIO_SUPPORT=['handler.ts','property-music.ts','project-media.ts','context.ts']
# Exact audited registration inventory, including current trial reservation and
# service activation billing cases and the selected-workspace photo package.
# Keep file-level counts and individual pass results, not just a total that can
# hide an omitted file, an ignored/filtered case or duplicate case output.
HANDLER_INVENTORY={'me/workspaces.test.ts':9,'me/billing.test.ts':21,'listings/create.test.ts':4}
HANDLER_TESTS=sum(HANDLER_INVENTORY.values())
OUT=pathlib.Path(tempfile.mkdtemp(prefix='rendprop-workspace-selection-',dir='/tmp'));SOCK,DATA=OUT/'socket',OUT/'cluster';SOCK.mkdir(mode=0o700)
ENV={'PATH':os.environ.get('PATH','/usr/bin:/bin'),'LC_ALL':'C','TZ':'UTC','NO_COLOR':'1','DENO_NO_PROMPT':'1'}
BIN={n:shutil.which(n)for n in ['initdb','pg_ctl','psql','createdb','deno']};assert all(BIN.values())
ENV['DENO_DIR']=json.loads(subprocess.check_output([BIN['deno'],'info','--no-config','--json'],text=True))['denoDir']
CONN=['-h',str(SOCK),'-p','55453','-U','postgres'];PSQL=[BIN['psql'],'-X','--no-password',*CONN,'-d','rendprop_audit','-v','ON_ERROR_STOP=1','-Atq']
paths=[*sorted((SQL/'migrations').glob('*.sql')),SQL/'tests/ci-bootstrap.sql',SQL/'tests/workspace_selection.sql',pathlib.Path(__file__).resolve(),*sorted((SQL/'functions/me').glob('*.ts')),*sorted((SQL/'functions/listings').glob('*.ts')),*sorted((SQL/'functions/_shared').glob('*.ts')),*[SQL/'functions/studio'/name for name in STUDIO_SUPPORT],*[SQL/'functions/uploads'/name for name in UPLOAD_SUPPORT]]
hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in paths}
receipt={'startedAt':datetime.now(timezone.utc).isoformat(),'sourceHashes':hashes,'commands':[],'passed':False,'productionMutations':0,'limits':['Synthetic auth schema and transport; no real phone or cross-device interaction']}
def run(name,args,stdin=None,expected=0):
 p=subprocess.run(list(map(str,args)),input=stdin,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=ENV,cwd=ROOT,timeout=120)
 log=OUT/(name+'.log');log.write_text(p.stdout);receipt['commands'].append({'name':name,'exit':p.returncode,'log':str(log),'sha256':hashlib.sha256(log.read_bytes()).hexdigest()})
 assert p.returncode==expected,f'{name}: unexpected exit{p.returncode}: {p.stdout[-2000:]}'
 print(name,p.returncode,flush=True);return p.stdout

def query(name,sql,expected=0):return run(name,PSQL,sql,expected)
def assert_handler_inventory(output):
 registrations=list(re.finditer(r'^running (\d+) tests? from ([^\r\n]+)$',output,re.MULTILINE))
 assert len(registrations)==len(HANDLER_INVENTORY),'Every audited handler file must register exactly once'
 observed={}
 for i,registration in enumerate(registrations):
  name=pathlib.Path(registration.group(2)).resolve().relative_to(SQL/'functions').as_posix()
  assert name in HANDLER_INVENTORY and name not in observed,'Unexpected or duplicate handler file'
  observed[name]=int(registration.group(1))
  assert observed[name]==HANDLER_INVENTORY[name],f'Incomplete handler inventory for {name}'
  block=output[registration.end():registrations[i+1].start()if i+1<len(registrations)else len(output)]
  passed_names=re.findall(r'^(.*?) \.\.\. ok \([^\r\n]+\)$',block,re.MULTILINE)
  assert len(passed_names)==observed[name]and len(set(passed_names))==observed[name],f'Every case in {name} must report one distinct pass'
 assert observed==HANDLER_INVENTORY,'The complete audited handler inventory must run'
 summaries=re.findall(r'^ok \| .*$',output,re.MULTILINE)
 assert len(summaries)==1 and re.fullmatch(rf'ok \| {HANDLER_TESTS} passed \| 0 failed \([^\r\n]+\)',summaries[0]),'Ignored, filtered, missing or failed handler cases are refused'
def race(name,commands,org):
 locker=subprocess.Popen(PSQL,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=ENV)
 try:
  locker.stdin.write(f"begin;select id from orgs where id='{org}'for update;\n\\echo LOCKED\n");locker.stdin.flush();assert locker.stdout.readline().strip()==org;assert locker.stdout.readline().strip()=='LOCKED'
  def call(command):
   p=subprocess.run(PSQL,input='set role service_role;'+command,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=ENV,timeout=30);return {'exit':p.returncode,'output':p.stdout}
  with ThreadPoolExecutor(max_workers=2)as pool:
   jobs=[pool.submit(call,c)for c in commands];deadline=time.monotonic()+8
   while True:
    p=subprocess.run(PSQL,input="select count(*)from pg_stat_activity where datname='rendprop_audit'and wait_event_type='Lock'and pid<>pg_backend_pid();",text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=ENV,timeout=5)
    if p.returncode==0 and p.stdout.strip()=='2':break
    assert time.monotonic()<deadline,'Both transactions must overlap behind org lock';time.sleep(.03)
   locker.stdin.write('commit;\n');locker.stdin.flush();locker.stdin.close();locker.wait(timeout=10);values=[j.result()for j in jobs]
  (OUT/(name+'.json')).write_text(json.dumps(values,indent=2));return values
 finally:
  if locker.poll()is None:locker.kill();locker.wait()
started=False
print('EVIDENCE:',OUT,flush=True)
try:
 run('init',[BIN['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8']);started=True
 run('start',[BIN['pg_ctl'],'-D',DATA,'-l',OUT/'server.log','-w','-t','30','-o',f"-k {SOCK} -p 55453 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=15",'start'])
 run('create',[BIN['createdb'],'--no-password',*CONN,'rendprop_audit']);assert query('identity',"select current_setting('data_directory'),current_setting('listen_addresses');").strip()==str(DATA)+'|'
 query('bootstrap',(SQL/'tests/ci-bootstrap.sql').read_text())
 for p in sorted((SQL/'migrations').glob('*.sql')):query('migration-'+p.stem,p.read_text())
 for phase in ['after','replayed']:
  if phase=='replayed':query('replay',TARGET.read_text())
  result=query('workspace-'+phase,(SQL/'tests/workspace_selection.sql').read_text());assert '\n28\n'in result and result.count('|t')==28
 # SQL negative control proves membership authorization is tested semantically.
 source=TARGET.read_text();anchor="if v_role is null then raise exception 'RP403: this workspace is no longer available to this account';end if;"
 assert source.count(anchor)==1;query('install-missing-membership-control',source.replace(anchor,"if v_role is null then v_role:='agent';end if;"))
 negative=query('missing-membership-control',(SQL/'tests/workspace_selection.sql').read_text(),3);assert 'wrong denial for nonmember cannot select another account workspace' in negative
 query('restore-selection',source)
 for n in [1,2]:
  owner=f'd0100106-0000-4000-8000-{n*2:012d}';actor=f'd0100106-0000-4000-8000-{n*2+1:012d}'
  query(f'race-users-{n}',f"insert into auth.users(id,email,is_anonymous)values('{owner}','owner-{n}@fixture.invalid',false),('{actor}','actor-{n}@fixture.invalid',false);")
  org=query(f'race-org-{n}',f"select org_id from memberships where user_id='{owner}';").strip()
  query(f'race-membership-{n}',f"update orgs set plan='team'where id='{org}';insert into memberships(user_id,org_id,role)values('{actor}','{org}','agent');")
  commands=[f"select select_workspace('{actor}','{org}');",f"select remove_org_member('{org}','{owner}','{actor}');"]
  if n==2:commands.reverse()
  values=race(f'selection-removal-race-{n}',commands,org);removal=values[1 if n==1 else 0];selection=values[0 if n==1 else 1]
  assert removal['exit']==0 and (selection['exit']==0 or(selection['exit']==3 and 'RP403:'in selection['output']))
  assert query(f'removal-wins-{n}',f"select count(*)from memberships where user_id='{actor}'and org_id='{org}';select active_org_for_user('{actor}')<>'{org}';").strip()=='0\nt'
  denied=query(f'explicit-no-fallback-{n}',f"set role service_role;select workspace_directory('{actor}','{org}');",3);assert 'RP403:'in denied
 deno=[BIN['deno'],'test','--cached-only','--no-config','--no-lock','--node-modules-dir=none','--allow-read','--allow-env','--deny-net','--deny-write','--deny-run']
 output=run('handlers',deno+[SQL/'functions/me/workspaces.test.ts',SQL/'functions/me/billing.test.ts',SQL/'functions/listings/create.test.ts']);assert_handler_inventory(output)
 # Bind first create in A, lose its response, switch default to B, retry with A.
 # Removing explicit scope must create a second row and fail the handler test.
 mutant=OUT/'request-drift-control';mutant.mkdir();(mutant/'_shared').symlink_to(SQL/'functions/_shared',target_is_directory=True)
 shutil.copytree(SQL/'functions/me',mutant/'me');shutil.copytree(SQL/'functions/listings',mutant/'listings')
 # Listings property-cover and /me private-media use these unchanged Studio
 # dependencies. Preserve them so the negative control reaches its runtime
 # assertion, not a missing-module or typecheck failure.
 (mutant/'studio').mkdir()
 for name in STUDIO_SUPPORT:shutil.copy2(SQL/'functions/studio'/name,mutant/'studio'/name)
 # /me imports the logo handler, which uses the real upload transport helper.
 # Its local dependencies must also be present while Deno checks the mutant.
 # Copy them unchanged so a missing module cannot masquerade as guard detection.
 (mutant/'uploads').mkdir()
 for name in UPLOAD_SUPPORT:shutil.copy2(SQL/'functions/uploads'/name,mutant/'uploads'/name)
 path=mutant/'listings/index.ts';text=path.read_text();anchor='const org_id = explicitOrg ?? await orgForUser(user.id, preferredOrg(req));';assert text.count(anchor)==1
 path.write_text(text.replace(anchor,'const org_id = await orgForUser(user.id);'))
 output=run('request-drift-control',deno+['--filter','bound listing create and retry',mutant/'me/workspaces.test.ts'],expected=1);assert re.search(r'0 passed \| 1 failed',output)and 'AssertionError'in output
 assert all(hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest for name,digest in hashes.items()),'Source changed during verification'
 receipt.update(passed=True,sqlAssertions=28,handlerTests=HANDLER_TESTS,handlerInventory=HANDLER_INVENTORY,realConnectionRaces=2,missingMembershipDetected=True,requestDriftDetected=True)
finally:
 if started and(DATA/'postmaster.pid').exists():run('stop',[BIN['pg_ctl'],'-D',DATA,'-m','immediate','-w','stop'])
 receipt['sourceHashesAfter']={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in hashes}
 receipt['sourceBindingsMatch']=receipt['sourceHashesAfter']==hashes
 receipt['passed']=receipt['passed'] and receipt['sourceBindingsMatch']
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
assert receipt['passed'] and receipt['sourceBindingsMatch'],'Verification failed or source changed during verification'
print('PASS: explicit workspaces, membership boundaries and delayed request binding',flush=True)
