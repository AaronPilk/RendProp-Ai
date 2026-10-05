#!/usr/bin/env python3
"""Prospective subscription-confirmed trial policy in disposable Postgres.

Does not connect to production, buy anything, call Apple, or change existing
trial/subscription fixtures. Apple signatures/notification decisions are tested
with the existing offline synthetic-chain suite, separately from SQL adapters.
"""
from datetime import datetime, timezone
import hashlib, json, os, pathlib, re, shutil, subprocess, tempfile
ROOT=pathlib.Path(__file__).resolve().parents[2]
SQL=ROOT/'services/supabase'
TARGET=SQL/'migrations/20261001143615_subscription_confirmed_trial_start.sql'
OUT=pathlib.Path(tempfile.mkdtemp(prefix='rendprop-subscription-trial-',dir='/tmp'))
SOCK,DATA=OUT/'socket',OUT/'cluster';SOCK.mkdir(mode=0o700)
ENV={'PATH':os.environ.get('PATH','/usr/bin:/bin'),'LC_ALL':'C','TZ':'UTC','NO_COLOR':'1','DENO_NO_PROMPT':'1'}
BIN={n:shutil.which(n)for n in ['initdb','pg_ctl','psql','createdb','deno']};assert all(BIN.values())
ENV['DENO_DIR']=json.loads(subprocess.check_output([BIN['deno'],'info','--no-config','--json'],text=True))['denoDir']
CONN=['-h',str(SOCK),'-p','55451','-U','postgres']
PSQL=[BIN['psql'],'-X','--no-password',*CONN,'-d','rendprop_audit','-v','ON_ERROR_STOP=1','-Atq']
paths=[*sorted((SQL/'migrations').glob('*.sql')),SQL/'tests/ci-bootstrap.sql',SQL/'tests/invariants.sql',SQL/'tests/subscription_confirmed_trial.sql',pathlib.Path(__file__).resolve(),*sorted((SQL/'functions/me').glob('*.ts')),*sorted((SQL/'functions/apple-subscriptions').glob('*.ts')),SQL/'functions/_shared/applejws.ts',SQL/'functions/_shared/applejws.test.ts',SQL/'functions/coach/knowledge.ts',SQL/'functions/coach/knowledge_test.ts']
paths.append(SQL/'tests/invariant_astra_paid_gates.sql')
hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in paths}
receipt={'startedAt':datetime.now(timezone.utc).isoformat(),'sourceHashes':hashes,'commands':[],'passed':False,'productionMutations':0,'purchases':0,'limits':['Synthetic auth schema and transactions; not App Store offer eligibility','No real purchase, restore or StoreKit sheet tested']}
def run(name,args,stdin=None,expected=0):
 p=subprocess.run(list(map(str,args)),input=stdin,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=ENV,cwd=ROOT,timeout=120)
 log=OUT/(name+'.log');log.write_text(p.stdout);receipt['commands'].append({'name':name,'exit':p.returncode,'log':str(log),'sha256':hashlib.sha256(log.read_bytes()).hexdigest()})
 assert p.returncode==expected,f'{name}: unexpected exit{p.returncode}: {p.stdout[-1600:]}'
 print(name,p.returncode,flush=True);return p.stdout

def query(name,sql,expected=0):return run(name,PSQL,sql,expected)
started=False
print('EVIDENCE:',OUT,flush=True)
try:
 run('init',[BIN['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 started=True;run('start',[BIN['pg_ctl'],'-D',DATA,'-l',OUT/'server.log','-w','-t','30','-o',f"-k {SOCK} -p 55451 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=15",'start'])
 run('create',[BIN['createdb'],'--no-password',*CONN,'rendprop_audit'])
 assert query('identity',"select current_setting('data_directory'),current_setting('listen_addresses');").strip()==str(DATA)+'|'
 query('bootstrap',(SQL/'tests/ci-bootstrap.sql').read_text())
 for p in sorted((SQL/'migrations').glob('*.sql')):
  if p!=TARGET:query('migration-'+p.stem,p.read_text())
 query('legacy-fixtures',"insert into auth.users(id,email,is_anonymous)values('d0100104-0000-4000-8000-000000000001','legacy@fixture.invalid',false),('d0100104-0000-4000-8000-000000000002','manual@fixture.invalid',false),('d0100104-0000-4000-8000-000000000003','paid@fixture.invalid',false);update orgs set plan='pro',plan_source='manual',trial_ends_at=null where id=(select org_id from memberships where user_id='d0100104-0000-4000-8000-000000000002');update orgs set plan='pro',plan_source='apple',plan_expires_at=now()+interval '30 days',trial_ends_at=null where id=(select org_id from memberships where user_id='d0100104-0000-4000-8000-000000000003');")
 snapshot="select jsonb_agg(to_jsonb(o) order by o.id)::text from orgs o join memberships m on m.org_id=o.id where m.user_id::text like 'd0100104-%';"
 before=query('legacy-before',snapshot)
 negative=query('signup-before',(SQL/'tests/subscription_confirmed_trial.sql').read_text(),3)
 assert 'SUBSCRIPTION FAIL: named signup starts free without automatic trial' in negative
 query('policy',TARGET.read_text())
 assert query('legacy-after',snapshot)==before,'Existing grants changed'
 for label in ['after','replayed']:
  if label=='replayed':query('policy-replay',TARGET.read_text())
  result=query('signup-'+label,(SQL/'tests/subscription_confirmed_trial.sql').read_text())
  assert '\n26\n' in result and result.count('|t')==26
 assert query('legacy-after-replay',snapshot)==before,'Migration replay changed existing grants'
 # Keep the full inventory and the single owner-retained Astra budget failure.
 inv=run('all-invariants',[*PSQL[:-1],'-f',SQL/'tests/invariants.sql'],expected=3)
 failures=[line for line in inv.splitlines()if re.search(r'\|\s*f\s*\|',line)]
 assert len(failures)==1 and 'each astra ceiling clears its route' in failures[0],failures
 rows=[line for line in inv.splitlines()if re.match(r'^\s*\d+\s*\|',line)and re.search(r'\|\s*[tf]\s*\|',line)]
 kept_red="each astra ceiling clears its route's visible answer and stays under the code clamp"
 assert failures[0].split('|',3)[1].strip()==kept_red,failures
 passed_rows=sum(bool(re.search(r'\|\s*t\s*\|',line))for line in rows)
 assert rows and passed_rows+len(failures)==len(rows),rows
 deno=[BIN['deno'],'test','--cached-only','--no-config','--no-lock','--node-modules-dir=none','--allow-read','--allow-env','--deny-net','--deny-write','--deny-run']
 result=run('apple-jws-notifications-billing',deno+[SQL/'functions/_shared/applejws.test.ts',SQL/'functions/apple-subscriptions/notify.test.ts',SQL/'functions/me/billing.test.ts',SQL/'functions/coach/knowledge_test.ts'])
 summary=re.findall(r'ok \| (\d+) passed \| 0 failed',result);assert len(summary)==1 and int(summary[0])>=50
 assert all(hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest for name,digest in hashes.items()),'Source changed during verification'
 receipt.update(passed=True,sqlAssertions=26,existingGrantSnapshotsUnchanged=True,signatureNotificationBillingTests=int(summary[0]),invariants={'passed':passed_rows,'expectedFailure':1,'expectedFailureName':kept_red,'total':len(rows)})
finally:
 if started and (DATA/'postmaster.pid').exists():run('stop',[BIN['pg_ctl'],'-D',DATA,'-m','immediate','-w','stop'])
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS: prospective signup policy; existing grants unchanged; verified subscription adapters',flush=True)
