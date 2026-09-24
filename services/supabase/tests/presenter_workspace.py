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
OUT = pathlib.Path(tempfile.mkdtemp(prefix='pres-', dir=ROOT / 'build'))
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

L2=uid(201); XL=uid(202); PHOTO=uid(301); PHOTO2=uid(302); VIDEO=uid(303); VIDEO2=uid(304); XPHOTO=uid(305); DRAFT=uid(401); RESULT=uid(501)
MIGRATION=SQL/'migrations/20260924174114_studio_presenter_workspace.sql'
def val(x): return 'null' if x is None else "'"+str(x).replace("'","''")+"'"
def lit(x): return val(json.dumps(x))+'::jsonb'
def rpc(actor=A,action='get',payload=None,listing=LIST,org=ORG):
 return f"set role service_role;select studio_presenter_workspace('{actor}','{org}','{listing}',{val(action)},{lit(payload or {})});"
def workspace(**kw): return json.loads(query(rpc(**kw)))
def prof(state, subject=A): return next(p for p in state['profiles'] if p['subject_user_id']==subject)
def draft(state): return next(d for d in state['drafts'] if d['id']==DRAFT)
def save_profile(rev=0,photos=None,actor=A,listing=LIST): return workspace(actor=actor,listing=listing,action='save_profile',payload={'expected_revision':rev,'display_name':'Represented Agent','reference_asset_ids':photos or [PHOTO],'subject_user_id':B})
def approve_profile(profile,rev): return workspace(action='approve_profile',payload={'profile_id':profile,'expected_revision':rev,'likeness_consent':True})
def draft_payload(profile,rev=0,pv=2,source=VIDEO): return {'draft_id':DRAFT,'expected_revision':rev,'profile_id':profile,'expected_profile_revision':pv,'title':'Property introduction','script':'Welcome to the property.','source_asset_id':source,'format':'listing_intro','resolution':'720p'}
def approve_draft_sql(profile_rev=2,rev=1,actor=A):return rpc(actor=actor,action='approve_draft',payload={'draft_id':DRAFT,'expected_revision':rev,'expected_profile_revision':profile_rev,'source_performance_consent':True})
def generate_sql(rev=2,pv=2,actor=B,action='prepare',result=None):return f"set role service_role;select studio_presenter_generation('{actor}','{ORG}','{LIST}','{DRAFT}',{rev},{pv},'{action}',{val(result)});"
def generation(**kw):return json.loads(query(generate_sql(**kw)))
started=False; completed=False
source_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((SQL/'migrations').glob('*.sql'))}
try:
 run([PG/'initdb','-D',OUT/'data','-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run([PG/'pg_ctl','-D',OUT/'data','-l',OUT/'server.log','-w','-o',f"-k '{SOCK}' -p 55473 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 query((SQL/'tests/ci-bootstrap.sql').read_text())
 for path in sorted((SQL/'migrations').glob('*.sql')):query(path.read_text())
 ok('all real migrations apply from an empty database')
 query(MIGRATION.read_text());ok('presenter migration replays safely')
 query('\n'.join(f"insert into auth.users(id,email) values('{u}','presenter-{i}@fixture.invalid');" for i,u in enumerate([A,B,C,M,X])))
 query(f"insert into orgs(id,name) values('{ORG}','Presenter fixture'),('{OTHER}','Other fixture');insert into memberships(user_id,org_id,role) values('{A}','{ORG}','agent'),('{B}','{ORG}','admin'),('{C}','{ORG}','agent'),('{M}','{ORG}','marketing'),('{X}','{OTHER}','owner');insert into listings(id,org_id,agent_id) values('{LIST}','{ORG}','{A}'),('{L2}','{ORG}','{A}'),('{XL}','{OTHER}','{X}');")
 for asset,listing,org,kind,duration in [(PHOTO,LIST,ORG,'photo',None),(PHOTO2,LIST,ORG,'photo',None),(VIDEO,LIST,ORG,'video',12),(VIDEO2,L2,ORG,'video',9),(XPHOTO,XL,OTHER,'photo',None)]:
  query(f"insert into capture_assets(id,listing_id,kind,bucket,storage_key,uploaded,sha256,bytes,duration_s) values('{asset}','{listing}','{kind}','uploads','uploads/{org}/{listing}/{asset}.{'jpg' if kind=='photo' else 'mp4'}',true,'{'a'*64}',1000,{duration or 'null'});")
 query(f"insert into capture_assets(id,listing_id,kind,bucket,storage_key,uploaded,bytes) values('{uid(306)}','{LIST}','photo','uploads','uploads/{ORG}/{LIST}/legacy.jpg',true,1000);")
 empty=workspace();ok('empty workspace returns scoped candidates and role permissions',empty['org_id']==ORG and empty['listing_id']==LIST and len(empty['reference_candidates'])==2 and len(empty['source_candidates'])==1 and empty['permissions']['can_save_profile'])
 ok('legacy uploads without verified identity are excluded from preview candidates',all(c['asset_id']!=uid(306) for c in empty['reference_candidates']) and not any(empty['truncated'].values()))
 p=prof(save_profile());PROFILE=p['id'];ok('profile subject bound to actor ignoring spoofed subject',p['subject_user_id']==A and p['revision']==1 and p['status']=='pending')
 ok('pending own profile remains private from agency',workspace(actor=B)['profiles']==[])
 error(rpc(actor=B,action='approve_profile',payload={'profile_id':PROFILE,'expected_revision':1,'likeness_consent':True}),'RP403');ok('admin cannot consent on behalf of subject')
 error(rpc(action='approve_profile',payload={'profile_id':PROFILE,'expected_revision':1}),'RP400');ok('likeness approval requires explicit attestation')
 p=prof(approve_profile(PROFILE,1));ok('subject approves exact saved profile references',p['status']=='approved' and p['revision']==2 and p['approved_revision']==2)
 reusable=prof(workspace(actor=B,listing=L2));ok('agency reuses approved workspace profile across properties',reusable['id']==PROFILE and reusable['source_listing_id']==LIST)
 media=json.loads(query(f"set role service_role;select studio_presenter_media('{B}','{ORG}','{L2}',{lit({'profile_id':PROFILE,'expected_profile_revision':2})});"))
 ok('authorized profile media resolves original listing references',media['listing_id']==L2 and media['assets'][0]['listing_id']==LIST and media['profile_revision']==2)
 for photos in [[XPHOTO],[PHOTO,PHOTO],[VIDEO]]:
  error(rpc(action='save_profile',payload={'expected_revision':2,'display_name':'Agent','reference_asset_ids':photos}),'RP4')
 ok('cross-tenant, duplicate and nonphoto references rejected')
 error(rpc(actor=X),'RP403');error(rpc(actor=M,action='save_profile',payload={'expected_revision':0,'display_name':'Marketing','reference_asset_ids':[PHOTO]}),'RP403');ok('cross-tenant and read-only roles cannot create profiles')
 d=draft(workspace(actor=B,action='save_draft',payload=draft_payload(PROFILE)));ok('agency saves shared draft bound to approved subject and exact profile',d['author_user_id']==B and d['subject_user_id']==A and d['status']=='draft' and d['revision']==1)
 ok('another active agent can review shared draft',draft(workspace(actor=C))['id']==DRAFT)
 error(approve_draft_sql(actor=B),'RP403');error(approve_draft_sql(actor=C),'RP403');ok('only profile subject may approve generation despite admin role')
 error(rpc(action='approve_draft',payload={'draft_id':DRAFT,'expected_revision':1,'expected_profile_revision':2}),'RP400');ok('draft approval requires source performer rights attestation')
 d=draft(json.loads(query(approve_draft_sql())));ok('approval bound to resulting exact draft revision',d['revision']==2 and d['approved_revision']==2 and d['approved_profile_revision']==2 and d['status']=='approved')
 g=generation();ok('server snapshot contains exact script source references and consent',g['snapshot']['script']=='Welcome to the property.' and g['snapshot']['source_performance_consent'] and g['snapshot']['draft_revision']==2 and g['reference_assets'][0]['id']==PHOTO and g['source_asset']['id']==VIDEO and g['existing_result_id'] is None)
 error(generate_sql(rev=1),'RP409');error(generate_sql(actor=M),'RP403');ok('stale and read-only generation prepare denied')
 error(generate_sql(action='claim',result=RESULT),'RP409');ok('claim cannot invent a video receipt')
 metadata={'state':'submitting','video_kind':'presenter','presenter_draft_id':DRAFT,'presenter_draft_revision':2,'presenter_profile_id':PROFILE,'presenter_profile_revision':2}
 query(f"insert into studio_creative_results(id,user_id,org_id,listing_id,kind,request_key,metadata) values('{RESULT}','{B}','{ORG}','{LIST}','video','presenter-fixture',{lit(metadata)});")
 claimed=generation(action='claim',result=RESULT);ok('claim attaches immutable scoped snapshot to existing job receipt',claimed['existing_result_id']==RESULT and json.loads(query(f"select metadata->'presenter_snapshot' from studio_creative_results where id='{RESULT}';"))==g['snapshot'])
 error(approve_draft_sql(rev=2),'RP409');ok('repeat approval cannot advance revision while reusing a prior result')
 ok('claim retry reuses one result for approved revision',generation(action='claim',result=uid(502))['existing_result_id']==RESULT and query('select count(*) from studio_creative_results;')=='1')
 query(f"update studio_creative_results set metadata=jsonb_set(metadata,'{{presenter_snapshot,script}}','\"wrong\"'::jsonb) where id='{RESULT}';")
 error(generate_sql(),'RP409');ok('mismatched existing job snapshot cannot be replayed')
 query(f"update studio_creative_results set metadata=jsonb_set(metadata,'{{presenter_snapshot}}',{lit(g['snapshot'])}) where id='{RESULT}';")
 query(f"update capture_assets set sha256='{'b'*64}' where id='{VIDEO}';")
 ok('source upload mutation removes effective approval immediately',draft(workspace())['status']=='draft')
 error(generate_sql(),'RP422');ok('changed source hash fences generation')
 query(f"update capture_assets set sha256='{'a'*64}' where id='{VIDEO}';")
 saved=draft(workspace(actor=C,action='save_draft',payload={**draft_payload(PROFILE,2),'script':'Revised by agency.'}));ok('shared editor preserves original author and removes approval',saved['revision']==3 and saved['author_user_id']==B and saved['status']=='draft' and saved['generation_result_id'] is None)
 def race_save(i):
  try:return ('ok',workspace(actor=C,action='save_draft',payload={**draft_payload(PROFILE,3),'script':'Concurrent '+str(i)}))
  except AssertionError as e:return ('error',str(e))
 with ThreadPoolExecutor(max_workers=2) as pool: outcomes=list(pool.map(race_save,[1,2]))
 ok('concurrent draft writes have exactly one CAS winner',sum(x[0]=='ok' for x in outcomes)==1 and any('RP409' in x[1] for x in outcomes if x[0]=='error'))
 query(approve_draft_sql(rev=4))
 p=prof(save_profile(2,[PHOTO2]));ok('reference change resets profile and all draft approvals',p['revision']==3 and p['status']=='pending' and draft(workspace())['revision']==6 and draft(workspace())['status']=='draft')
 error(generate_sql(rev=5),'RP409');ok('old exact approval cannot survive reference edit')
 approve_profile(PROFILE,3)
 ok('profile approval alone cannot reactivate old draft consent',draft(workspace())['status']=='draft')
 error(approve_draft_sql(rev=7,profile_rev=4),'RP409');ok('subject must save draft against new reference revision before approval')
 workspace(actor=B,action='save_draft',payload=draft_payload(PROFILE,7,pv=4));query(approve_draft_sql(rev=8,profile_rev=4))
 def revoke():
  try:return ('ok',workspace(action='revoke_profile',payload={'profile_id':PROFILE,'expected_revision':4}))
  except AssertionError as e:return ('error',str(e))
 def concurrent_approve():
  try:return ('ok',json.loads(query(approve_draft_sql(rev=9,profile_rev=4))))
  except AssertionError as e:return ('error',str(e))
 with ThreadPoolExecutor(max_workers=2) as pool:
  r1=pool.submit(revoke);r2=pool.submit(concurrent_approve);out=[r1.result(),r2.result()]
 ok('revocation races cannot leave a generation-approved draft',out[0][0]=='ok' and draft(workspace())['status']=='draft' and prof(workspace())['status']=='revoked')
 error(generate_sql(rev=draft(workspace())['revision'],pv=5),'RP422');ok('revoked profile cannot prepare or claim new work')
 # Restore explicit consent then mutate references/property/account to prove all
 # authorization checks are live, even if a caller holds old valid identifiers.
 p=prof(save_profile(5));approve_profile(PROFILE,6);dv=draft(workspace())['revision']
 workspace(actor=B,action='save_draft',payload=draft_payload(PROFILE,dv,pv=7));query(approve_draft_sql(rev=dv+1,profile_rev=7));dv+=2
 query(f"update capture_assets set sha256='{'b'*64}' where id='{PHOTO}';")
 ok('changed reference upload hides profile from agency',workspace(actor=B)['profiles']==[] and prof(workspace())['invalid_reason'] is not None)
 error(generate_sql(rev=dv,pv=7),'RP422');query(f"update capture_assets set sha256='{'a'*64}' where id='{PHOTO}';")
 query(f"update listings set deleted_at=now() where id='{LIST}';")
 ok('deleted source property invalidates reusable profile on another property',workspace(actor=B,listing=L2)['profiles']==[])
 query(f"update listings set deleted_at=null where id='{LIST}';")
 query(f"insert into deletion_requests(user_id,status) values('{A}','pending');")
 ok('subject deletion intent hides likeness from active agency',workspace(actor=B)['profiles']==[] and workspace(actor=B)['drafts']==[])
 error(generate_sql(rev=dv,pv=7),'RP422');query(f"delete from deletion_requests where user_id='{A}';")
 query(f"update auth.users set is_anonymous=true where id='{A}';")
 ok('anonymous subject cannot expose an approved identity',workspace(actor=B)['profiles']==[])
 error(rpc(),'RP403');query(f"update auth.users set is_anonymous=false where id='{A}';")
 query(f"delete from memberships where user_id='{A}' and org_id='{ORG}';")
 ok('departed subject immediately loses shared profile and approval access',workspace(actor=B)['profiles']==[] and workspace(actor=B)['drafts']==[])
 query(f"insert into memberships(user_id,org_id,role) values('{A}','{ORG}','agent');insert into deletion_requests(user_id,status) values('{B}','processing');")
 ok('author deletion intent hides shared drafts',workspace()['drafts']==[])
 query(f"delete from deletion_requests where user_id='{B}';")
 for role in ['anon','authenticated']:
  for table in ['studio_presenter_profiles','studio_presenter_drafts']:error(f'set role {role};select * from {table};','permission denied')
  error(f"set role {role};select studio_presenter_workspace('{A}','{ORG}','{LIST}','get','{{}}');",'permission denied')
  error(f"set role {role};select studio_presenter_generation('{A}','{ORG}','{LIST}','{DRAFT}',1,1);",'permission denied')
 ok('public and authenticated cannot read tables or spoof RPC actor')
 for malformed in [{'expected_revision':None},{'expected_revision':-1},{'expected_revision':2.5},{'expected_revision':2147483647}]:error(rpc(action='save_profile',payload=malformed),'RP400')
 ok('SQL mutation validates optimistic revision independent of Edge')
 for mutation in [f"delete from studio_presenter_profiles where id='{PROFILE}'",f"delete from listings where id='{LIST}'"]:
  deleted=json.loads(query(f"begin;{mutation};select json_build_array((select count(*) from studio_presenter_profiles),(select count(*) from studio_presenter_drafts),(select count(*) from studio_creative_results));rollback;"))
  ok('profile deletion removes associated private job receipt' if 'studio_presenter_profiles where' in mutation else 'source property deletion removes reusable likeness data and private job receipt',deleted==[0,0,0])
 deletion=query(f"begin;set role service_role;select prepare_account_deletion('{A}','fixture-uploads','fixture-renders');reset role;delete from auth.users where id='{A}';select json_build_array((select count(*) from studio_presenter_profiles),(select count(*) from studio_presenter_drafts),(select count(*) from studio_creative_results));rollback;").splitlines()
 ok('identity deletion cascades profiles drafts and agency-owned likeness job snapshots',json.loads(deletion[-1])==[0,0,0])
 author_delete=query(f"begin;set role service_role;select prepare_account_deletion('{B}','fixture-uploads','fixture-renders');reset role;delete from auth.users where id='{B}';select json_build_array((select count(*) from studio_presenter_profiles),(select count(*) from studio_presenter_drafts),(select count(*) from studio_creative_results));rollback;").splitlines()
 ok('agency author deletion removes drafts without deleting another persons profile',json.loads(author_delete[-1])==[1,0,0])
 query(f"insert into capture_assets(listing_id,kind,bucket,storage_key,uploaded,sha256,bytes) select '{LIST}','photo','uploads','uploads/{ORG}/{LIST}/extra-'||n||'.jpg',true,'{'a'*64}',1000 from generate_series(1,201) n;")
 capped=workspace();ok('bounded candidate response advertises truncated older media',len(capped['reference_candidates'])==200 and capped['truncated']['reference_candidates'] is True)
 completed=True
finally:
 failure=str(sys.exc_info()[1]) if sys.exc_info()[1] else None
 if started:run([PG/'pg_ctl','-D',OUT/'data','-m','fast','-w','stop'])
 receipt={'ok':completed,'passed':len(passed),'checks':passed,'productionCalls':0,'socketOnly':True,'clusterStopped':started,'output':str(OUT),'sourceSHA256':source_hashes,'error':failure}
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt,indent=2))
