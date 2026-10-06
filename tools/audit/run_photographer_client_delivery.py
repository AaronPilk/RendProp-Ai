#!/usr/bin/env python3
"""Photographer client cards, recipient authority and concurrent forwarding regressions.

Owns a disposable socket-only Postgres cluster; no external auth or network.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib,json,os,pathlib,re,shutil,subprocess,tempfile,time,uuid
ROOT=pathlib.Path(__file__).resolve().parents[2];SQL=ROOT/'services/supabase'
TARGET=SQL/'migrations/20261001222809_photographer_client_delivery.sql'
OUT=pathlib.Path(tempfile.mkdtemp(prefix='rendprop-photographer-client-',dir='/tmp'));SOCK,DATA=OUT/'socket',OUT/'cluster';SOCK.mkdir(mode=0o700)
ENV={'PATH':os.environ.get('PATH','/usr/bin:/bin'),'LC_ALL':'C','TZ':'UTC','NO_COLOR':'1','DENO_NO_PROMPT':'1'}
BIN={n:shutil.which(n)for n in ['initdb','pg_ctl','psql','createdb','deno']};assert all(BIN.values())
ENV['DENO_DIR']=json.loads(subprocess.check_output([BIN['deno'],'info','--no-config','--json'],text=True))['denoDir']
CONN=['-h',str(SOCK),'-p','55454','-U','postgres'];PSQL=[BIN['psql'],'-X','--no-password',*CONN,'-d','rendprop_audit','-v','ON_ERROR_STOP=1','-Atq']
paths=[*sorted((SQL/'migrations').glob('*.sql')),SQL/'tests/ci-bootstrap.sql',SQL/'tests/photographer_client_delivery.sql',pathlib.Path(__file__).resolve(),*[p for section in ['me','listings','leads','notify','tours','uploads','studio','ai-video','_shared']for p in sorted((SQL/'functions'/section).glob('*.ts'))if not (p.name.endswith('.test.ts')or p.name.endswith('_test.ts'))]]
hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in paths}
receipt={'startedAt':datetime.now(timezone.utc).isoformat(),'sourceHashes':hashes,'commands':[],'passed':False,'productionMutations':0,'limits':['Synthetic auth schema and transport; no real phone or cross-device interaction']}
def run(name,args,stdin=None,expected=0):
 p=subprocess.run(list(map(str,args)),input=stdin,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=ENV,cwd=ROOT,timeout=120)
 log=OUT/(name+'.log');log.write_text(p.stdout);receipt['commands'].append({'name':name,'exit':p.returncode,'log':str(log),'sha256':hashlib.sha256(log.read_bytes()).hexdigest()})
 assert p.returncode==expected,f'{name}: unexpected exit{p.returncode}: {p.stdout[-2000:]}'
 print(name,p.returncode,flush=True);return p.stdout

def query(name,sql,expected=0):return run(name,PSQL,sql,expected)
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
    assert time.monotonic()<deadline,'Both mutations must overlap behind the owned org lock';time.sleep(.03)
   locker.stdin.write('commit;\n');locker.stdin.flush();locker.stdin.close();locker.wait(timeout=10);values=[j.result()for j in jobs]
  log=OUT/(name+'.json');log.write_text(json.dumps(values,indent=2)+'\n');receipt['commands'].append({'name':name,'log':str(log),'sha256':hashlib.sha256(log.read_bytes()).hexdigest()});return values
 finally:
  if locker.poll()is None:locker.kill();locker.wait()
started=False
print('EVIDENCE:',OUT,flush=True)
try:
 run('init',[BIN['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8']);started=True
 run('start',[BIN['pg_ctl'],'-D',DATA,'-l',OUT/'server.log','-w','-t','30','-o',f"-k {SOCK} -p 55454 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=15",'start'])
 run('create',[BIN['createdb'],'--no-password',*CONN,'rendprop_audit']);assert query('identity',"select current_setting('data_directory'),current_setting('listen_addresses');").strip()==str(DATA)+'|'
 query('bootstrap',(SQL/'tests/ci-bootstrap.sql').read_text())
 for p in sorted((SQL/'migrations').glob('*.sql')):query('migration-'+p.stem,p.read_text())
 for phase in ['after','replayed']:
  if phase=='replayed':
   query('replay',TARGET.read_text())
   query('replay-current-recipient-authority',(SQL/'migrations/20261005220001_verified_notification_and_client_recipients.sql').read_text())
  result=query('client-'+phase,(SQL/'tests/photographer_client_delivery.sql').read_text());assert result.count('|t')==61,result[-2000:]
 # Real overlapping transactions, with a lock proving both entered together.
 owner,agent,lid,jid,rid,leadid=map(str,[uuid.uuid4()for _ in range(6)])
 query('race-users',f"insert into auth.users(id,email,is_anonymous)values('{owner}','race-owner@fixture.invalid',false),('{agent}','race-agent@fixture.invalid',false);")
 org=query('race-org',f"select org_id from memberships where user_id='{owner}';").strip()
 query('race-fixture',f"insert into memberships(user_id,org_id,role)values('{agent}','{org}','agent');insert into listings(id,org_id,agent_id,address)values('{lid}','{org}','{owner}','Concurrency fixture');insert into render_jobs(id,listing_id,tier,status)values('{jid}','{lid}','smooth','completed');insert into renders(id,job_id,listing_id,slug,duration_s,published_at)values('{rid}','{jid}','{lid}','concurrent-client-fixture',5,now());set role service_role;select listing_client_contact_put('{owner}','{org}','{lid}',0,true,'{{\"name\":\"Race Client\"}}','initial@fixture.invalid',true,null);")
 writers=[owner,agent]
 values=race('contact-optimistic-concurrency',[f"select listing_client_contact_put('{actor}','{org}','{lid}',1,true,'{{\"name\":\"Race Client {n}\"}}','winner{n}@fixture.invalid',true,null);"for n,actor in enumerate(writers)],org)
 assert sorted(v['exit']for v in values)==[0,3]and sum('RP409:'in v['output']for v in values)==1,values
 assert query('contact-race-row',f"select revision from listing_client_contacts where listing_id='{lid}';").strip()=='2'
 recipient=query('contact-race-recipient',f"select recipient_email from listing_client_contacts where listing_id='{lid}';").strip()
 nonce=uuid.uuid4().hex+uuid.uuid4().hex
 query('verify-race-recipient',f"set role service_role;select client_recipient_verification_request('{owner}','{org}','{lid}','{nonce}');select client_recipient_verification_consume('{nonce}');")
 query('resend-race-fixture',f"insert into leads(id,org_id,listing_id,render_id,name)values('{leadid}','{org}','{lid}','{rid}','Concurrency Buyer');update notification_outbox set state='sent',sent_at=now()where client_delivery_id in(select id from client_lead_deliveries where lead_id='{leadid}');update client_lead_deliveries set created_at=now()-interval '2 minutes'where lead_id='{leadid}';")
 values=race('different-resends-concurrency',[f"select client_lead_resend('{actor}','{org}','{leadid}','{uuid.uuid4()}','{recipient}');"for actor in writers],org)
 assert sorted(v['exit']for v in values)==[0,3]and sum('RP429:'in v['output']for v in values)==1,values
 assert query('different-resends-count',f"select count(*)from client_lead_deliveries where lead_id='{leadid}';").strip()=='2'
 query('replay-race-reset',f"update notification_outbox set state='sent',sent_at=now()where client_delivery_id in(select id from client_lead_deliveries where lead_id='{leadid}');update client_lead_deliveries set created_at=now()-interval '2 minutes'where lead_id='{leadid}';")
 request=str(uuid.uuid4())
 command=f"select client_lead_resend('{owner}','{org}','{leadid}','{request}','{recipient}');"
 values=race('same-request-concurrency',[command,command],org)
 assert all(v['exit']==0 for v in values),values
 assert query('same-request-count',f"select count(*)from client_lead_deliveries where lead_id='{leadid}'and request_id='{request}';").strip()=='1'
 assert query('immutable-recipient-count',f"select bool_and(recipient_email='{recipient}')from client_lead_deliveries where lead_id='{leadid}';").strip()=='t'
 current={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in paths}
 assert hashes==current,'Source changed during verification; rerun before using this evidence'
 receipt.update(passed=True,sqlAssertions=61,concurrencyChecks=['one optimistic-write winner','one different-resend winner','same request one delivery','recipient always from saved client'],finishedAt=datetime.now(timezone.utc).isoformat())
finally:
 if started and(DATA/'postmaster.pid').exists():run('stop',[BIN['pg_ctl'],'-D',DATA,'-m','immediate','-w','stop'])
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS: client contacts and transactional recipient delivery',flush=True)
