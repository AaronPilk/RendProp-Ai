#!/usr/bin/env python3
"""Owned, disposable Unix-socket Postgres tests. Never uses a configured database.
All cluster files/logs stay under this checkout's ignored build/ directory.
"""
import hashlib, json, os, pathlib, shutil, subprocess, sys, tempfile, time
from concurrent.futures import ThreadPoolExecutor
ROOT = pathlib.Path(__file__).resolve().parents[3]
SQL = ROOT / 'services/supabase'
# Only an executable directory may be configured, never a DB URL/connection.
if os.environ.get('RENDPROP_TEST_PG_BIN'):
    PG=pathlib.Path(os.environ['RENDPROP_TEST_PG_BIN']).resolve()
elif pathlib.Path('/opt/homebrew/opt/postgresql@17/bin/initdb').is_file():
    PG=pathlib.Path('/opt/homebrew/opt/postgresql@17/bin')
else:
    config=shutil.which('pg_config',path='/usr/bin:/bin:/usr/local/bin')
    if not config: raise RuntimeError('Install PostgreSQL or set RENDPROP_TEST_PG_BIN to its bin directory')
    PG=pathlib.Path(subprocess.check_output([config,'--bindir'],text=True,env={'PATH':'/usr/bin:/bin'}).strip())
if not (PG/'initdb').is_file(): raise RuntimeError('Configured PostgreSQL binaries do not include initdb')
ENV = {'PATH': '/usr/bin:/bin:/opt/homebrew/bin', 'LC_ALL': 'C'}
(ROOT / 'build').mkdir(exist_ok=True)
OUT = pathlib.Path(tempfile.mkdtemp(prefix='pr-', dir=ROOT / 'build'))
SOCK = OUT / 's'; SOCK.mkdir()
if len(str(SOCK).encode())>85: raise RuntimeError('Checkout path is too long for a Unix socket; use a shorter isolated checkout')
CONN = ['-h', str(SOCK), '-p', '55473', '-U', 'postgres', '-d', 'postgres']
PSQL = [str(PG/'psql'), '-X', '--no-password', *CONN, '-v', 'ON_ERROR_STOP=1', '-Atq']
passed = []
def run(args, text=None):
    p = subprocess.run([str(a) for a in args], input=text, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=ENV, timeout=60)
    if p.returncode: raise AssertionError(p.stderr[-6000:])
    return p.stdout.strip()
def query(sql): return run(PSQL, sql)
def ok(name, check=True):
    assert check, name
    passed.append(name)
def error(sql, expected):
    try: query(sql)
    except AssertionError as e:
        assert expected in str(e), str(e)
    else: raise AssertionError('Expected failure '+expected)
def uid(n): return f'10000000-0000-4000-8000-{n:012d}'
A,B,C,M,X = [uid(i) for i in range(1,6)]
ORG='20000000-0000-4000-8000-000000000001'; OTHER='20000000-0000-4000-8000-000000000002'
LIST='30000000-0000-4000-8000-000000000001'; KEY='edit:'+LIST

def rpc(actor=A, action='get', dr=None, rr=None, msg=None, owner=A, org=ORG):
    val=lambda x:'null' if x is None else "'"+str(x).replace("'","''")+"'"
    return 'set role service_role; select public.studio_production_review('+','.join(val(x) for x in [actor,org,owner,KEY,action,dr,rr,msg,None])+');'
def review(**kw): return json.loads(query(rpc(**kw)))
def queue(actor=A, offset=0): return json.loads(query(f"set role service_role; select public.studio_production_review_queue('{actor}','{ORG}',null,{offset});"))
def edit(rev): return f"set role service_role; update studio_documents set revision={rev},payload=jsonb_build_object('listingId','{LIST}','title','revision-{rev}'),updated_at=clock_timestamp() where user_id='{A}' and org_id='{ORG}' and key='{KEY}';"
started=False
completed=False
source_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((SQL/'migrations').glob('*.sql'))}
try:
    run([PG/'initdb','-D',OUT/'data','-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
    run([PG/'pg_ctl','-D',OUT/'data','-l',OUT/'server.log','-w','-o',f"-k '{SOCK}' -p 55473 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
    query((SQL/'tests/ci-bootstrap.sql').read_text())
    for p in sorted((SQL/'migrations').glob('*.sql')): query(p.read_text())
    ok('all real migrations apply from empty schema')
    migration=SQL/'migrations/20260924153826_studio_production_reviews.sql'
    query(migration.read_text());ok('new migration replays safely')
    query('\n'.join(f"insert into auth.users(id,email) values('{u}','review-{i}@fixture.invalid');" for i,u in enumerate([A,B,C,M,X])))
    query(f"insert into orgs(id,name) values('{ORG}','Review fixture'),('{OTHER}','Other fixture'); insert into memberships(user_id,org_id,role) values('{A}','{ORG}','agent'),('{B}','{ORG}','admin'),('{C}','{ORG}','agent'),('{M}','{ORG}','marketing'),('{X}','{OTHER}','owner'); insert into listings(id,org_id,agent_id,address) values('{LIST}','{ORG}','{A}','Synthetic review property'); insert into studio_documents(user_id,org_id,key,kind,listing_id,revision,payload) values('{A}','{ORG}','{KEY}','edit','{LIST}',1,jsonb_build_object('listingId','{LIST}','approved',true));")
    result=review();ok('virtual private draft has no forged approval', result['review']['status']=='draft' and result['review']['revision']==0)
    error(rpc(actor=B),'RP404');ok('admin cannot see never-submitted draft')
    error(rpc(actor=X),'RP403');ok('cross-org reviewer rejected')
    error(rpc(actor=A,org=OTHER),'RP403');ok('wrong workspace rejected')
    error(rpc(action='approve',dr=1,rr=0),'RP403');ok('cannot approve unsubmitted draft')
    result=review(action='submit',dr=1,rr=0);ok('author submits exact saved revision',result['review']['status']=='in_review' and result['review']['revision']==1)
    ok('submitted source is available to active reviewer',review(actor=B)['document']['revision']==1)
    ok('marketing can read submitted source',review(actor=M)['document']['revision']==1)
    error(rpc(actor=M,action='comment',dr=1,rr=1,msg='no'),'RP403');ok('marketing review mutation denied')
    error(rpc(actor=C,action='approve',dr=1,rr=1),'RP403');ok('unrelated agent cannot approve')
    result=review(actor=C,action='comment',dr=1,rr=1,msg='Fix intro');ok('agent comment records actual actor and revision',result['review']['events'][-1]['author_id']==C and result['review']['events'][-1]['document_revision']==1)
    error(rpc(actor=B,action='approve',dr=1,rr=1),'RP409');ok('stale review revision rejected')
    error(rpc(actor=B,action='approve',dr=2,rr=2),'RP409');ok('stale source revision rejected')
    result=review(action='approve',dr=1,rr=2);ok('listing author may approve own submitted reel',result['review']['status']=='approved')
    q=queue(B);ok('queue returns nested DTO without source payload',len(q['reviews'])==1 and q['reviews'][0]['review']['status']=='approved' and 'document' not in q['reviews'][0] and q['next_offset'] is None)
    query(edit(2));r=review(actor=B);ok('source edit atomically invalidates approval',r['review']['status']=='draft' and r['review']['revision']==4 and r['source_revision']==2)
    ok('new revision private until resubmitted',r['document'] is None)
    ok('old comments stay tied to original revision',all(e['document_revision']==1 for e in r['review']['events']))
    error(rpc(actor=B,action='comment',dr=2,rr=4,msg='private'),'RP403');ok('reviewer cannot comment on newly private source')
    error("set role service_role; update studio_documents set payload='{}' where user_id='"+A+"' and key='"+KEY+"';",'RP409');ok('direct source content edit cannot bypass revision increase')
    review(action='submit',dr=2,rr=4)
    error(rpc(actor=C,action='request_changes',dr=2,rr=5,msg='  '),'RP400');ok('change request requires explanation')
    review(actor=C,action='request_changes',dr=2,rr=5,msg='Shorten outro');ok('agent may request changes',review()['review']['status']=='changes_requested')
    review(action='submit',dr=2,rr=6)
    # Both sessions present the exact same revision. Exactly one mutation wins.
    def concurrent_comment(n):
        try: return ('ok',review(actor=C,action='comment',dr=2,rr=7,msg='parallel-'+str(n)))
        except AssertionError as e: return ('conflict',str(e))
    with ThreadPoolExecutor(max_workers=2) as pool: responses=list(pool.map(concurrent_comment,[1,2]))
    ok('simultaneous review comments have one CAS winner',sum(x[0]=='ok' for x in responses)==1 and any('RP409' in x[1] for x in responses if x[0]=='conflict'))
    # Hold source lock, begin approval, then commit a source edit. Approval must
    # recheck the committed source revision after waiting, never approve rev 2.
    locker=subprocess.Popen(PSQL,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=ENV)
    locker.stdin.write("begin; set role service_role; select 1 from studio_documents where user_id='"+A+"' and key='"+KEY+"' for update;\\echo LOCKED\n");locker.stdin.flush()
    assert locker.stdout.readline().strip()=='1'; assert locker.stdout.readline().strip()=='LOCKED'
    with ThreadPoolExecutor(max_workers=1) as pool:
        future=pool.submit(query,rpc(actor=B,action='approve',dr=2,rr=8))
        waiting=False
        for _ in range(50):
            waiting=query("select exists(select 1 from pg_stat_activity where wait_event_type='Lock' and query like 'select public.studio_production_review(%');")=='t'
            if waiting: break
            time.sleep(.02)
        assert waiting, 'approval must demonstrably wait behind document row lock'
        locker.stdin.write(edit(3)+"commit;\n\\q\n");locker.stdin.flush();locker.wait(timeout=10)
        try: future.result();raise AssertionError('approval survived source edit')
        except AssertionError as e: assert 'RP409' in str(e)
    ok('approval blocked behind source edit rejects stale revision',review()['review']['status']=='draft')
    review(action='submit',dr=3,rr=9);review(actor=B,action='approve',dr=3,rr=10);query(edit(4));ok('edit after approval also invalidates',review()['review']['status']=='draft')
    query(f"update auth.users set is_anonymous=true where id='{C}';")
    error(rpc(actor=C),'RP403');ok('anonymous actor cannot review');query(f"update auth.users set is_anonymous=false where id='{C}';")
    query(f"insert into deletion_requests(user_id,status) values('{C}','pending');")
    error(rpc(actor=C),'RP403');ok('deletion intent fences reviewer');query(f"delete from deletion_requests where user_id='{C}';")
    query(f"insert into deletion_requests(user_id,status) values('{A}','processing');")
    error(rpc(actor=B),'RP404');ok('source author deletion intent revokes source access');ok('source deletion omitted from queue',queue(B)['reviews']==[])
    query(f"delete from deletion_requests where user_id='{A}'; update auth.users set is_anonymous=true where id='{A}';")
    error(rpc(actor=B),'RP404');ok('anonymous source author cannot expose private documents');query(f"update auth.users set is_anonymous=false where id='{A}';")
    query(f"update orgs set deleted_at=now() where id='{ORG}';")
    error(rpc(actor=B),'RP404');error(f"set role service_role;select studio_production_review_queue('{B}','{ORG}');",'RP403');ok('deleted workspace denies source and queue');query(f"update orgs set deleted_at=null where id='{ORG}';")
    query(f"delete from memberships where user_id='{A}' and org_id='{ORG}';")
    error(rpc(actor=B),'RP404');ok('removed source author revokes review access');ok('removed author removed from queue',queue(B)['reviews']==[])
    query(f"insert into memberships(user_id,org_id,role) values('{A}','{ORG}','agent'); update listings set deleted_at=now() where id='{LIST}';")
    error(rpc(actor=B),'RP404');ok('deleted property blocks review');ok('deleted property absent from queue',queue(B)['reviews']==[])
    query(f"update listings set deleted_at=null where id='{LIST}';")
    for role in ['anon','authenticated']:
        error(f"set role {role};select * from studio_production_reviews;",'permission denied')
        error(f"set role {role};select studio_production_review('{A}','{ORG}','{A}','{KEY}');",'permission denied')
        error(f"set role {role};select studio_review_named_account('{A}');",'permission denied')
    ok('public roles cannot forge RPC actor or directly change authority')
    query(f"set role service_role; insert into studio_documents(user_id,org_id,key,kind,listing_id,revision,payload) values('{A}','{ORG}','production:{LIST}','production','{LIST}',1,'{{}}');")
    ok('capture plan document kind is supported')
    # Exercise real immutable versions, restored target content and narration aliases.
    PHOTO='40000000-0000-4000-8000-000000000001'; VOICE='40000000-0000-4000-8000-000000000002'
    media_hash='a'*64
    payload={'listingId':LIST,'sources':[{'sha256':media_hash,'assetId':PHOTO,'listingId':LIST}],
      'draft':{'schema':1,'id':uid(10),'revision':0,'ratio':'9:16','title':'Submitted v5','audio':'muted',
        'clips':[{'id':'clip-1','source':{'name':'fixture.png','size':32,'lastModified':0,'sha256':media_hash,'kind':'image','width':16,'height':16,'duration':0},'start':0,'end':3,'caption':'','focusX':.5,'focusY':.5}],
        'narration':{'resultId':VOICE,'label':'Saved voice','offset':0,'volume':1,'wordCaptions':False,'words':[]}}}
    literal=lambda value:"'"+json.dumps(value).replace("'","''")+"'::jsonb"
    brief={'schema':1,'listingId':LIST,'recipe':'listing-highlight','presentation':'voiceover','targetSeconds':30,'shots':[{'id':'intro','title':'Entry','guidance':'Hold steady','required':True,'status':'captured','sourcePhotoIds':[PHOTO],'sourceVideoIds':[],'notes':''}],'notes':'Shared submission brief'}
    query(f"insert into capture_assets(id,listing_id,kind,bucket,storage_key,uploaded,sha256) values('{PHOTO}','{LIST}','photo','uploads','uploads/{ORG}/{LIST}/fixture.png',true,'{media_hash}'); insert into studio_creative_results(id,user_id,org_id,listing_id,kind,bucket,storage_key,request_key,metadata) values('{VOICE}','{A}','{ORG}','{LIST}','voice','uploads','ai-voice/{ORG}/{VOICE}.mp3','voice-fixture',jsonb_build_object('state','completed','words','[]'::jsonb)); update studio_documents set payload={literal(brief)},revision=2 where user_id='{A}' and key='production:{LIST}';")
    query(f"set role service_role; update studio_documents set revision=5,payload={literal(payload)} where user_id='{A}' and key='{KEY}';")
    submitted=review(action='submit',dr=5,rr=13)
    ok('submission freezes exact current brief',submitted['brief']==brief)
    def versions(actor=A,owner=A,rev=None,offset=0):
        return json.loads(query(f"set role service_role;select studio_production_versions_read('{actor}','{ORG}','{owner}','{KEY}',{rev if rev else 'null'},{offset});"))
    def copy_sql(actor=B,owner=A,rev=5,expected=0):
        return f"set role service_role;select studio_production_copy('{actor}','{ORG}','{owner}','{KEY}',{rev},{expected});"
    def copy(**kw): return json.loads(query(copy_sql(**kw)))
    frozen=versions(actor=B,rev=5)
    ok('submitted version returns immutable payload and brief',frozen['document']['payload']==payload and frozen['brief']==brief)
    ok('version list only includes metadata',all('payload' not in v and 'brief' not in v for v in versions(actor=B)['versions']))
    copied=copy();alias=copied['document']['payload']['draft']['narration']['resultId']
    ok('copy creates recipient private draft and fresh narration alias',copied['document']['revision']==1 and copied['preserved_version'] is None and alias!=VOICE and copied['source_version']['document_revision']==5)
    alias_row=json.loads(query(f"select json_build_object('user',user_id,'key',storage_key,'org',org_id,'listing',listing_id) from studio_creative_results where id='{alias}';"))
    ok('narration alias reuses trusted bytes with recipient ownership',alias_row=={'user':B,'key':f'ai-voice/{ORG}/{VOICE}.mp3','org':ORG,'listing':LIST})
    ok('source draft remains unchanged by copy',review()['document']['payload']==payload)
    before_count=query('select count(*) from studio_creative_results;')
    error(copy_sql(),'RP409');ok('stale target copy performs no result alias write',query('select count(*) from studio_creative_results;')==before_count)
    replaced=copy(expected=1)
    ok('copy preserves existing target atomically',replaced['document']['revision']==2 and replaced['preserved_version']['document_user_id']==B and replaced['preserved_version']['document_revision']==1)
    private=versions(actor=B,owner=B,rev=1)
    ok('preserved target snapshot contains exact previous payload',private['document']['payload']==copied['document']['payload'])
    try: versions(actor=C,owner=B,rev=1);raise AssertionError('private target history leaked')
    except AssertionError as e: assert 'RP404' in str(e)
    ok('unsubmitted recipient history stays private')
    count=query('select count(*) from studio_creative_results;')
    restored=copy(actor=B,owner=B,rev=1,expected=2)
    ok('restore makes a new revision without duplicating own narration',restored['document']['revision']==3 and restored['document']['payload']==copied['document']['payload'] and query('select count(*) from studio_creative_results;')==count)
    ok('copied draft never inherits source approval',review(actor=B,owner=B)['review']['status']=='draft')
    review(actor=B,owner=B,action='submit',dr=3,rr=0)
    propagated=copy(actor=C,owner=B,rev=3)
    ok('recipient can submit handoff and share its narration safely onward',propagated['document']['payload']['draft']['narration']['resultId'] not in [VOICE,alias])
    error(copy_sql(actor=M),'RP403');error(copy_sql(actor=X),'RP403');ok('marketing and cross-org actors cannot copy')
    query(f"delete from capture_assets where id='{PHOTO}';")
    error(copy_sql(expected=3),'RP422');query(f"insert into capture_assets(id,listing_id,kind,bucket,storage_key,uploaded,sha256) values('{PHOTO}','{LIST}','photo','uploads','uploads/{ORG}/{LIST}/fixture.png',true,'{media_hash}');")
    ok('missing original blocks copy before replacing target',review(actor=B,owner=B)['source_revision']==3)
    query(f"update studio_creative_results set metadata=jsonb_build_object('state','pending') where id='{VOICE}';")
    error(copy_sql(expected=3),'RP422');query(f"update studio_creative_results set metadata=jsonb_build_object('state','completed') where id='{VOICE}';")
    ok('unfinished narration cannot be aliased')
    query(f"update studio_creative_results set storage_key='ai-voice/{OTHER}/{VOICE}.mp3' where id='{VOICE}';")
    error(copy_sql(expected=3),'RP422');query(f"update studio_creative_results set storage_key='ai-voice/{ORG}/{VOICE}.mp3' where id='{VOICE}';")
    ok('forged cross-org narration key cannot be aliased')
    changed=json.loads(json.dumps(payload));changed['draft']['title']='Private v6';changed['draft']['narration']['resultId']=alias
    query(f"set role service_role; update studio_documents set revision=6,payload={literal(changed)} where user_id='{A}' and key='{KEY}'; update studio_documents set revision=3,payload=jsonb_build_object('notes','Private changed brief') where user_id='{A}' and key='production:{LIST}';")
    ok('new private source does not mutate earlier shared snapshot or brief',versions(actor=B,rev=5)==frozen)
    review(action='submit',dr=6,rr=15)
    error(copy_sql(rev=6,expected=3),'RP422');ok('source snapshot cannot claim another authors private narration')
    error("set role service_role; update studio_production_versions set payload='{}';",'permission denied')
    error("set role service_role; delete from studio_production_versions;",'permission denied')
    for role in ['anon','authenticated']:
        error(f"set role {role};select * from studio_production_versions;",'permission denied')
        error(f"set role {role};select studio_production_copy('{B}','{ORG}','{A}','{KEY}',5,3);",'permission denied')
    ok('immutable versions deny direct mutation and public RPC actor spoofing')
    # Versions 1/2/3 deliberately precede valid editor payload: fail closed.
    error(copy_sql(rev=1,expected=3),'RP400');ok('legacy invalid editor snapshot cannot silently replace a valid draft')
    def copy_race(_):
        try: return ('ok',copy(expected=3))
        except AssertionError as e: return ('conflict',str(e))
    count=int(query('select count(*) from studio_creative_results;'))
    with ThreadPoolExecutor(max_workers=2) as pool: outcomes=list(pool.map(copy_race,[1,2]))
    ok('concurrent copies have one CAS winner and one narration alias',sum(x[0]=='ok' for x in outcomes)==1 and any('RP409' in x[1] for x in outcomes if x[0]=='conflict') and int(query('select count(*) from studio_creative_results;'))==count+1)
    with ThreadPoolExecutor(max_workers=2) as pool:
        left=pool.submit(copy,actor=A,owner=B,rev=3,expected=6)
        right=pool.submit(copy,actor=B,owner=A,rev=5,expected=4)
        copies=[left.result(),right.result()]
    ok('reciprocal agency handoffs use deterministic locks and preserve both targets',copies[0]['document']['revision']==7 and copies[1]['document']['revision']==5 and copies[0]['preserved_version']['document_revision']==6 and copies[1]['preserved_version']['document_revision']==4)
    ok('handoff invalidates any current recipient review approval',review(actor=A)['review']['status']=='draft' and review(actor=B,owner=B)['review']['status']=='draft')
    for departing,survivor,survivor_result in [(A,B,alias),(B,A,VOICE)]:
        lines=query(f"begin;set role service_role;select prepare_account_deletion('{departing}','fixture-uploads','fixture-renders');reset role;delete from auth.users where id='{departing}';select exists(select 1 from studio_creative_results where id='{survivor_result}' and user_id='{survivor}' and storage_key='ai-voice/{ORG}/{VOICE}.mp3');rollback;").splitlines()
        deletion=json.loads(lines[0])
        ok('source deletion preserves recipient alias and shared audio' if departing==A else 'recipient deletion preserves original audio and result',lines[1]=='t' and ORG in deletion['scope']['shared_orgs'] and not any(item.get('key')==f'ai-voice/{ORG}/{VOICE}.mp3' for item in deletion['payload']['r2']))
    last=json.loads(query(f"begin;delete from memberships where org_id='{ORG}' and user_id<>'{A}';set role service_role;select prepare_account_deletion('{A}','fixture-uploads','fixture-renders');rollback;"))
    ok('final workspace deletion inventories aliased audio exactly once',sum(item.get('key')==f'ai-voice/{ORG}/{VOICE}.mp3' for item in last['payload']['r2'])==1)
    for n in range(10,61):
        lid=f'30000000-0000-4000-8000-{n:012d}'
        query(f"insert into listings(id,org_id,agent_id) values('{lid}','{ORG}','{A}'); set role service_role; insert into studio_documents(user_id,org_id,key,kind,listing_id,revision,payload) values('{A}','{ORG}','edit:{lid}','edit','{lid}',1,jsonb_build_object('listingId','{lid}'));select studio_production_review('{A}','{ORG}','{A}','edit:{lid}','submit',1,0);")
    first,second=queue(B),queue(B,50)
    ok('queue paginates 53 submitted records without duplicate or missing rows',len(first['reviews'])==50 and first['next_offset']==50 and len(second['reviews'])==3 and second['next_offset'] is None and len({(e['review']['document_user_id'],e['review']['key']) for e in first['reviews']+second['reviews']})==53)
    ok('queue never sends source payload or comment body', all('document' not in e and 'payload' not in e['review'] and e['review']['events']==[] for e in first['reviews']))
    error(f"set role service_role;select studio_production_review_queue('{A}','{ORG}',null,1);",'RP400');ok('queue offset is bounded')
    completed=True
finally:
    failure=str(sys.exc_info()[1]) if sys.exc_info()[1] else None
    if started: run([PG/'pg_ctl','-D',OUT/'data','-m','fast','-w','stop'])
    receipt={'ok':completed,'passed':len(passed),'checks':passed,'productionCalls':0,'socketOnly':True,'clusterStopped':started,'output':str(OUT),'sourceSHA256':source_hashes,'error':failure}
    (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(receipt,indent=2))
