#!/usr/bin/env python3
"""Real SQL and handler checks on an owned socket-only database; no real email.

Uses all current migrations, proves the historical enqueue defect, applies its
fix, and races two real connections for one invitation/seat. No credentials or
configured DB URL are accepted. Synthetic outbox rows are never drained.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib, json, os, pathlib, re, shutil, subprocess, tempfile, time

ROOT = pathlib.Path(__file__).resolve().parents[2]
SQL = ROOT / 'services/supabase'
TARGET = SQL / 'migrations/20261001142823_team_invite_delivery_confirmation.sql'
# Audited handler inventory: 12 invite/read/role cases, 8 private-sponsorship
# cases, and 1 ordinary anonymous-owner read case. Keep the entire suite;
# registering fewer tests or reporting any ignored/filtered case is a failure.
HANDLER_TESTS = 21
OUT = pathlib.Path(tempfile.mkdtemp(prefix='rendprop-team-readiness-', dir='/tmp'))
SOCK, DATA = OUT/'socket', OUT/'cluster'
SOCK.mkdir(mode=0o700)
ENV = {'PATH': os.environ.get('PATH','/usr/bin:/bin'), 'LC_ALL':'C', 'TZ':'UTC', 'NO_COLOR':'1', 'DENO_NO_PROMPT':'1'}
BIN = {name:shutil.which(name) for name in ['initdb','pg_ctl','createdb','psql','deno']}
assert all(BIN.values()), 'Use installed PostgreSQL and Deno'
ENV['DENO_DIR'] = json.loads(subprocess.check_output([BIN['deno'],'info','--no-config','--json'],text=True))['denoDir']
CONN = ['-h',str(SOCK),'-p','55449','-U','postgres']
PSQL = [BIN['psql'],'-X','--no-password',*CONN,'-d','rendprop_audit','-v','ON_ERROR_STOP=1','-Atq']
paths = [*sorted((SQL/'migrations').glob('*.sql')), SQL/'tests/ci-bootstrap.sql', SQL/'tests/team_readiness.sql', pathlib.Path(__file__).resolve(), *sorted((SQL/'functions/team').glob('*.ts')), *sorted((SQL/'functions/_shared').glob('*.ts'))]
hashes = {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
receipt = {'startedAt':datetime.now(timezone.utc).isoformat(),'sourceHashes':hashes,'commands':[],'passed':False,'productionMutations':0,'messagesSent':0,'limits':['Local SQL uses synthetic auth schema, not hosted JWT verification','Transport mocked; no provider email delivery exercised']}

def run(name,args,stdin=None,expected=0):
 p=subprocess.run(list(map(str,args)),input=stdin,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=ENV,cwd=ROOT,timeout=120)
 log=OUT/(name+'.log');log.write_text(p.stdout)
 receipt['commands'].append({'name':name,'exit':p.returncode,'log':str(log),'sha256':hashlib.sha256(log.read_bytes()).hexdigest()})
 assert p.returncode==expected, f'{name}: unexpected exit{p.returncode}: {p.stdout[-1500:]}'
 print(name,p.returncode,flush=True);return p.stdout

def query(name,text,expected=0): return run(name,PSQL,text,expected)
def race(name,commands,org):
 locker=subprocess.Popen(PSQL,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=ENV)
 try:
  locker.stdin.write(f"begin; select id from orgs where id='{org}' for update;\n\\echo LOCKED\n");locker.stdin.flush()
  assert locker.stdout.readline().strip()==org
  assert locker.stdout.readline().strip()=='LOCKED'
  def call(command):
   p=subprocess.run(PSQL,input='set role service_role;'+command,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=ENV,timeout=30)
   return {'exit':p.returncode,'output':p.stdout}
  with ThreadPoolExecutor(max_workers=2) as pool:
   pending=[pool.submit(call,c) for c in commands]
   deadline=time.monotonic()+8
   while True:
    p=subprocess.run(PSQL,input="select count(*) from pg_stat_activity where datname='rendprop_audit' and wait_event_type='Lock' and pid<>pg_backend_pid();",text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=ENV,timeout=5)
    if p.returncode==0 and p.stdout.strip()=='2':break
    assert time.monotonic()<deadline,'Both real transactions must overlap behind lock'
    time.sleep(.03)
   locker.stdin.write('commit;\n');locker.stdin.flush();locker.stdin.close();locker.wait(timeout=10)
   values=[f.result() for f in pending]
  (OUT/(name+'.json')).write_text(json.dumps(values,indent=2))
  return values
 finally:
  if locker.poll() is None:locker.kill();locker.wait()

started=False
print('EVIDENCE:',OUT,flush=True)
try:
 run('init',[BIN['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 started=True
 run('start',[BIN['pg_ctl'],'-D',DATA,'-l',OUT/'server.log','-w','-t','30','-o',f"-k {SOCK} -p 55449 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=15",'start'])
 run('create',[BIN['createdb'],'--no-password',*CONN,'rendprop_audit'])
 assert query('identity',"select current_setting('data_directory'), current_setting('listen_addresses');").strip()==str(DATA)+'|'
 query('bootstrap',(SQL/'tests/ci-bootstrap.sql').read_text())
 for p in sorted((SQL/'migrations').glob('*.sql')):
  if p!=TARGET:query('migration-'+p.stem,p.read_text())
 before=query('enqueue-before',(SQL/'tests/team_readiness.sql').read_text(),3)
 assert 'TEAM FAIL: addressed invite queues with the real profile name column' in before
 query('fix',TARGET.read_text())
 for phase in ['after','replayed']:
  if phase=='replayed':query('replay-fix',TARGET.read_text())
  result=query('team-'+phase,(SQL/'tests/team_readiness.sql').read_text())
  assert '\n34\n' in result and result.count('|t')==34
 owner,one,two=[f'd0100102-0000-4000-8000-{n:012d}' for n in [1,2,3]]
 query('race-users',"insert into auth.users(id,email,is_anonymous) values "+','.join(f"('{u}','race-{n}@fixture.invalid',false)" for n,u in enumerate([owner,one,two]))+';')
 org=query('race-org',f"select org_id from memberships where user_id='{owner}';").strip()
 query('race-plan',f"update orgs set plan='team' where id='{org}';")
 calls=[f"select create_org_invite('{owner}','{org}','race-{n}@fixture.invalid','agent','{str(n)*64}');" for n in [1,2]]
 values=race('last-seat-race',calls,org)
 assert sorted(v['exit'] for v in values)==[0,3] and any('RP402:' in v['output'] for v in values)
 token=query('race-token',f"select token_hash from org_invites where org_id='{org}' and accepted_at is null and revoked_at is null;").strip()
 values2=race('same-invite-race',[f"select accept_org_invite('{u}','{token}');" for u in [one,two]],org)
 assert sorted(v['exit'] for v in values2)==[0,3] and any('RP404:' in v['output'] for v in values2)
 assert query('race-final',f"select count(*) from memberships where org_id='{org}';select count(*) from org_invites where org_id='{org}' and accepted_at is not null;").strip()=='2\n1'
 deno=[BIN['deno'],'test','--cached-only','--no-config','--no-lock','--node-modules-dir=none','--deny-net','--deny-run','--deny-write','--allow-read','--allow-env']
 output=run('handler-after',deno+[SQL/'functions/team/handler.test.ts'])
 registrations=re.findall(r'^running (\d+) tests? from .*handler\.test\.ts$',output,re.MULTILINE)
 assert registrations==[str(HANDLER_TESTS)], 'The complete audited handler inventory must be registered'
 summaries=re.findall(r'^ok \| .*$',output,re.MULTILINE)
 assert len(summaries)==1 and re.fullmatch(rf'ok \| {HANDLER_TESTS} passed \| 0 failed \([^\r\n]+\)',summaries[0]), 'Every handler test must pass; ignored, filtered or missing cases are refused'
 passed_names=re.findall(r'^(.*?) \.\.\. ok \([^\r\n]+\)$',output,re.MULTILINE)
 assert len(passed_names)==HANDLER_TESTS and len(set(passed_names))==HANDLER_TESTS, 'Every registered handler case must report one distinct pass'
 # Inject the former false-confirmation defect into a private source copy.
 # This negative control remains executable in shallow CI after the fix commits.
 baseline=OUT/'handler-baseline';(baseline/'team').mkdir(parents=True)
 (baseline/'_shared').symlink_to(SQL/'functions/_shared',target_is_directory=True)
 original=(SQL/'functions/team/index.ts').read_text()
 anchor='emailed: emailQueued, email_queued: emailQueued'
 assert original.count(anchor)==1
 (baseline/'team/index.ts').write_text(original.replace(anchor,'emailed: Boolean(email), email_queued: Boolean(email)'))
 for name in ['codes.ts','handler.test.ts']:(baseline/'team'/name).write_bytes((SQL/'functions/team'/name).read_bytes())
 output=run('handler-false-confirmation-control',deno+['--filter','valid invite code survives enqueue failure',baseline/'team/handler.test.ts'],expected=1)
 assert re.search(r'0 passed \| 3 failed',output) and 'AssertionError' in output
 assert all(hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest for name,digest in hashes.items()),'Source changed during verification'
 receipt.update(passed=True,sqlAssertions=34,handlerTests=HANDLER_TESTS,realConnectionRaces=2,baselineSQLDetected=True,handlerFalseConfirmationDetected=True)
finally:
 if started and (DATA/'postmaster.pid').exists():run('stop',[BIN['pg_ctl'],'-D',DATA,'-m','immediate','-w','stop'])
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS: team readiness SQL, handler, before/after and two real races',flush=True)
