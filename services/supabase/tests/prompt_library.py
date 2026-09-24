#!/usr/bin/env python3
"""Actual prompt document RLS/constraints in an owned Unix-socket cluster only."""
import hashlib,json,os,pathlib,shutil,subprocess,sys,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
PG=pathlib.Path(os.environ.get('RENDPROP_TEST_PG_BIN','/opt/homebrew/opt/postgresql@17/bin'))
if not (PG/'initdb').is_file():
 config=shutil.which('pg_config',path='/usr/bin:/bin:/usr/local/bin')
 if not config:raise RuntimeError('Install PostgreSQL or set RENDPROP_TEST_PG_BIN')
 PG=pathlib.Path(subprocess.check_output([config,'--bindir'],text=True).strip())
ENV={'PATH':'/usr/bin:/bin','LC_ALL':'C'};(ROOT/'build').mkdir(exist_ok=True)
OUT=pathlib.Path(tempfile.mkdtemp(prefix='prm-',dir=ROOT/'build'));SOCK=OUT/'s';SOCK.mkdir()
if len(str(SOCK).encode())>85:raise RuntimeError('Use a shorter checkout path for the owned Unix socket')
PSQL=[str(PG/'psql'),'-X','--no-password','-h',str(SOCK),'-p','55474','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-Atq']
def run(args,sql=None):
 p=subprocess.run([str(a) for a in args],input=sql,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=ENV,timeout=90)
 if p.returncode:raise AssertionError(p.stderr[-6000:])
 return p.stdout.strip()
def query(sql):return run(PSQL,sql)
def error(sql,match):
 try:query(sql)
 except AssertionError as e:assert match in str(e),str(e)
 else:raise AssertionError('Expected '+match)
def lit(v):return "'"+json.dumps(v).replace("'","''")+"'::jsonb"
def uid(n):return f'10000000-0000-4000-8000-{n:012d}'
A,B=uid(1),uid(2);ORG,OTHER=uid(101),uid(102);LIST=uid(201)
checks=[]
def ok(name,test=True):assert test,name;checks.append(name)
started=complete=False
hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((SQL/'migrations').glob('*.sql'))}
try:
 run([PG/'initdb','-D',OUT/'data','-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run([PG/'pg_ctl','-D',OUT/'data','-l',OUT/'server.log','-w','-o',f"-k '{SOCK}' -p 55474 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 query((SQL/'tests/ci-bootstrap.sql').read_text())
 for p in sorted((SQL/'migrations').glob('*.sql')):query(p.read_text())
 query((SQL/'migrations/20260924184052_studio_prompt_library.sql').read_text());ok('all migrations apply and prompt schema replays')
 query(f"insert into auth.users(id,email) values('{A}','prompts-a@fixture.invalid'),('{B}','prompts-b@fixture.invalid');insert into orgs(id,name) values('{ORG}','Prompt fixture'),('{OTHER}','Other workspace');insert into memberships(user_id,org_id,role) values('{A}','{ORG}','agent'),('{B}','{ORG}','agent'),('{A}','{OTHER}','agent');insert into listings(id,org_id,agent_id) values('{LIST}','{ORG}','{A}');")
 payload={'schema':1,'entries':[{'title':'My private notes'}]}
 query(f"set role service_role;insert into studio_documents(user_id,org_id,key,kind,payload) values('{A}','{ORG}','prompts','prompts',{lit(payload)}),('{B}','{ORG}','prompts','prompts',{lit({'schema':1,'entries':[]})});")
 def read(actor):return query(f"set role authenticated;set request.jwt.claim.sub='{actor}';select user_id||':'||org_id from studio_documents where key='prompts';")
 ok('same workspace member cannot read another persons library',read(B)==B+':'+ORG)
 ok('owner reads only own personal prompt collection',read(A)==A+':'+ORG)
 query(f"set role service_role;insert into studio_documents(user_id,org_id,key,kind,payload) values('{A}','{OTHER}','prompts','prompts','{{\"schema\":1,\"entries\":[]}}');")
 scoped=query(f"set role authenticated;set request.jwt.claim.sub='{A}';select count(*) from studio_documents where key='prompts' and org_id='{ORG}';")
 ok('explicit workspace selection isolates same-user collections',scoped=='1')
 for actor in [A,B]:error(f"set role authenticated;set request.jwt.claim.sub='{actor}';update studio_documents set payload='{{}}' where key='prompts';",'permission denied')
 ok('browser cannot bypass scoped document handler writes')
 for assignment in ["listing_id='"+LIST+"'","key='prompts:"+LIST+"'","payload='{}'", "payload='"+json.dumps({'schema':1,'entries':[{}]*51})+"'"]:
  error(f"set role service_role;update studio_documents set {assignment} where user_id='{A}' and org_id='{ORG}' and key='prompts';",'studio_prompt_document_scope')
 ok('database rejects property binding malformed schema and oversized entry lists')
 updated=query(f"set role service_role;with changed as(update studio_documents set revision=2 where user_id='{A}' and org_id='{ORG}' and key='prompts' and revision=1 returning *)select count(*) from changed;")
 stale=query(f"set role service_role;with changed as(update studio_documents set revision=2 where user_id='{A}' and org_id='{ORG}' and key='prompts' and revision=1 returning *)select count(*) from changed;")
 ok('two device revision predicates cannot both overwrite the same revision',updated=='1' and stale=='0')
 query(f"delete from memberships where user_id='{A}' and org_id='{OTHER}';")
 ok('removed workspace membership loses library access',read(A)==A+':'+ORG)
 query(f"set role service_role;select prepare_account_deletion('{B}','fixture-uploads','fixture-renders');reset role;delete from auth.users where id='{B}';")
 ok('account deletion removes personal prompt content',query(f"select count(*) from studio_documents where user_id='{B}';")=='0')
 complete=True
finally:
 failure=str(sys.exc_info()[1]) if sys.exc_info()[1] else None
 if started:run([PG/'pg_ctl','-D',OUT/'data','-m','fast','-w','stop'])
 receipt={'ok':complete,'checks':checks,'passed':len(checks),'sourceSHA256':hashes,'productionCalls':0,'socketOnly':True,'clusterStopped':started,'output':str(OUT),'error':failure}
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt,indent=2))
