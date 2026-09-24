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
OUT = pathlib.Path(tempfile.mkdtemp(prefix='pex-', dir=ROOT / 'build'))
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
MIGRATION=SQL/'migrations/20260924180853_studio_presenter_execution.sql'
try:
 run([PG/'initdb','-D',OUT/'data','-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run([PG/'pg_ctl','-D',OUT/'data','-l',OUT/'server.log','-w','-o',f"-k '{SOCK}' -p 55473 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 query((SQL/'tests/ci-bootstrap.sql').read_text())
 for path in sorted((SQL/'migrations').glob('*.sql')):query(path.read_text())
 ok('all real migrations apply from an empty database')
 query(MIGRATION.read_text());ok('execution migration replays safely')
 query((SQL/'migrations/20260924184319_studio_presenter_media_revocation.sql').read_text());ok('recursive media revocation migration replays safely')
 query('\n'.join(f"insert into auth.users(id,email) values('{u}','presenter-{i}@fixture.invalid');" for i,u in enumerate([A,B,C,M,X])))
 query(f"insert into orgs(id,name) values('{ORG}','Presenter fixture'),('{OTHER}','Other fixture');insert into memberships(user_id,org_id,role) values('{A}','{ORG}','agent'),('{B}','{ORG}','admin'),('{C}','{ORG}','agent'),('{M}','{ORG}','marketing'),('{X}','{OTHER}','owner');insert into listings(id,org_id,agent_id) values('{LIST}','{ORG}','{A}'),('{L2}','{ORG}','{A}'),('{XL}','{OTHER}','{X}');")
 for asset,listing,org,kind,duration in [(PHOTO,LIST,ORG,'photo',None),(PHOTO2,LIST,ORG,'photo',None),(VIDEO,LIST,ORG,'video',12),(VIDEO2,L2,ORG,'video',9),(XPHOTO,XL,OTHER,'photo',None)]:
  query(f"insert into capture_assets(id,listing_id,kind,bucket,storage_key,uploaded,sha256,bytes,duration_s) values('{asset}','{listing}','{kind}','uploads','uploads/{org}/{listing}/{asset}.{'jpg' if kind=='photo' else 'mp4'}',true,'{'a'*64}',1000,{duration or 'null'});")
 query(f"insert into capture_assets(id,listing_id,kind,bucket,storage_key,uploaded,bytes) values('{uid(306)}','{LIST}','photo','uploads','uploads/{ORG}/{LIST}/legacy.jpg',true,1000);")
 def exsql(action='get',payload=None,actor=B,listing=LIST,org=ORG):
  return f"set role service_role;select studio_presenter_execution('{actor}','{org}','{listing}',{val(action)},{lit(payload or {})});"
 def ex(action='get',payload=None,**kw):return json.loads(query(exsql(action,payload,**kw)))
 def wsql(job,action,payload=None):return f"set role service_role;select studio_presenter_execution_worker({val(job)},{val(action)},{lit(payload or {})});"
 def worker(job,action,payload=None):return json.loads(query(wsql(job,action,payload)))
 p=prof(save_profile());PROFILE=p['id'];approve_profile(PROFILE,1)
 workspace(actor=B,action='save_draft',payload=draft_payload(PROFILE));query(approve_draft_sql())
 identity={'draft_id':DRAFT,'expected_revision':2,'expected_profile_revision':2}
 ok('runtime has zero budget and is disabled without configuration',ex()['runtime']['available'] is False and ex()['runtime']['remaining_cents']==0)
 error(exsql('quote_prepare',identity),'RP409');ok('generation cannot quote before explicit contract and budget activation')
 query(f"insert into studio_presenter_runtime(org_id,enabled,max_job_cents,total_budget_cents) values('{ORG}',true,100,100);")
 error(exsql('quote_prepare',identity),'RP409');ok('enabled flag alone cannot bypass no-training agreement and price evidence')
 query(f"update studio_presenter_runtime set enterprise_no_training_confirmed=true,contract_reference='synthetic-test-only',price_version='fixture-v1' where org_id='{ORG}';")
 prepared=ex('quote_prepare',identity);SPEC=prepared['execution_spec']
 ok('quote preparation binds real approved snapshot without treating guide as visual prompt',prepared['snapshot']['script']=='Welcome to the property.' and SPEC['version']=='presenter-motion-v1' and SPEC['prompt']!=prepared['snapshot']['script'])
 counter=700
 def quote(**overrides):
  global counter
  counter+=1
  return ex('quote_commit',{**identity,'quote_id':uid(counter),'quote_cents':25,'price_version':'fixture-v1','execution_spec':SPEC,'probe':{'sha256':'a'*64,'bytes':1000,'duration_s':12},**overrides})['quote']
 error(exsql('quote_prepare',identity,actor=M),'RP403');error(exsql('quote_prepare',identity,actor=X),'RP403');ok('readonly and cross-tenant actors cannot quote')
 error(exsql('quote_commit',{**identity,'quote_id':uid(699),'quote_cents':25,'price_version':'fixture-v1','execution_spec':SPEC,'probe':{'sha256':'b'*64,'bytes':1000,'duration_s':12}}),'RP422');ok('server probe is bound to approved source bytes and digest')
 q1,q2=quote(),quote()
 ok('provider estimate and maximum authorized hold remain distinct',q1['quote_cents']==25 and q1['max_cost_cents']==100 and q1['expires_at'])
 def create(q,key=None):return ex('create',{'quote_id':q['id'],'idempotency_key':key or uid(int(q['id'][-12:])+1000),'cost_consent':True,'max_cost_cents':100})
 error(exsql('create',{'quote_id':q1['id'],'idempotency_key':uid(990),'cost_consent':True,'max_cost_cents':25}),'RP400');ok('estimate is not silently substituted for maximum cost consent')
 def racing_create(q):
  try:return ('ok',create(q))
  except AssertionError as e:return ('error',str(e))
 with ThreadPoolExecutor(max_workers=2) as pool:race=list(pool.map(racing_create,[q1,q2]))
 ok('concurrent jobs cannot overspend one workspace allocation',sum(v[0]=='ok' for v in race)==1 and any('RP429' in v[1] for v in race if v[0]=='error'))
 job=next(v[1]['job'] for v in race if v[0]=='ok');qid=job['quote_id'];chosen=next(q for q in [q1,q2] if q['id']==qid)
 replay=create(chosen);ok('lost creation response reuses same durable job and hold',replay['replayed'] and replay['job']['id']==job['id'] and ex()['runtime']['held_cents']==100)
 error(exsql('create',{'quote_id':qid,'idempotency_key':uid(991),'cost_consent':True,'max_cost_cents':100}),'RP409');ok('one quote cannot buy two jobs with different request IDs')
 qstale=next(q for q in [q1,q2] if q['id']!=qid)
 query(f"update studio_presenter_runtime set total_budget_cents=10000 where org_id='{ORG}';")
 error(exsql('create',{'quote_id':qstale['id'],'idempotency_key':uid(992),'cost_consent':True,'max_cost_cents':100}),'RP409');ok('runtime change automatically invalidates earlier unspent quotes')
 no_dispatch=worker(job['id'],'dispatch_claim');ok('runtime changed after reservation fails safely without dispatch',not no_dispatch['claimed'] and no_dispatch['job']['held_cents']==0)
 def fresh():return create(quote())['job']
 job=fresh();J=job['id']
 with ThreadPoolExecutor(max_workers=2) as pool:claims=list(pool.map(lambda _:worker(J,'dispatch_claim'),[1,2]))
 ok('dispatch authority is granted once across concurrent workers',sum(c['claimed'] for c in claims)==1)
 claim=next(c for c in claims if c['claimed']);TOKEN=claim['dispatch_token']
 worker(J,'ambiguous',{'dispatch_token':TOKEN})
 ok('ambiguous dispatch preserves full hold and permanently denies another POST',worker(J,'read')['job']['held_cents']==100 and not worker(J,'dispatch_claim')['claimed'])
 error(wsql(J,'dispatch_result',{'dispatch_token':uid(99),'request_id':'fixture-request','status_url':'https://fixture.invalid/status'}),'RP409');ok('unclaimed worker cannot attach provider receipt')
 refs={'dispatch_token':TOKEN,'request_id':'fixture-request','status_url':'https://fixture.invalid/status','cancel_url':'https://fixture.invalid/cancel'}
 accepted=worker(J,'dispatch_result',refs)['job'];worker(J,'dispatch_result',refs)
 ok('late confirmed request can be recovered without resubmission',accepted['state']=='queued' and accepted['held_cents']==100)
 error(wsql(J,'dispatch_result',{**refs,'request_id':'other'}),'RP409');ok('provider request identity cannot be replaced')
 cancelled=ex('cancel',{'job_id':J,'expected_revision':accepted['revision']})['job']
 ok('postdispatch cancellation is durable and not a refund',cancelled['state']=='cancel_requested' and cancelled['held_cents']==100)
 terminal=worker(J,'cancelled')['job'];ok('terminal provider status without billing keeps unknown cost held',terminal['state']=='cancelled' and terminal['held_cents']==100)
 error(wsql(J,'settle',{'charged_cents':0,'billing_reference':'not-final'}),'RP400');ok('unconfirmed cost cannot release hold')
 settled=worker(J,'settle',{'billing_final':True,'charged_cents':17,'billing_reference':'synthetic-final-invoice'})['job']
 ok('final measured charge releases maximum hold and records actual cents',settled['held_cents']==0 and settled['charged_cents']==17)
 error(wsql(J,'settle',{'billing_final':True,'charged_cents':0,'billing_reference':'synthetic-final-invoice'}),'RP409');ok('settled cost cannot be rewritten as a refund')
 worker(J,'status',{'state':'processing'});ok('late polling cannot resurrect cancelled job',worker(J,'read')['job']['state']=='cancelled')
 def to_review():
  j=fresh();c=worker(j['id'],'dispatch_claim');worker(j['id'],'dispatch_result',{'dispatch_token':c['dispatch_token'],'request_id':j['id'],'status_url':'https://fixture.invalid/status'})
  lease=worker(j['id'],'output_claim');r=worker(j['id'],'output_ready',{'lease_token':lease['lease_token'],'sha256':'c'*64,'bytes':2048,'duration_s':12})['job'];return r,lease
 review,lease=to_review();R=review['id']
 ok('generated output remains private and outside generic media before review',review['state']=='review' and query(f"select count(*) from capture_assets where presenter_job_id='{R}';")=='0' and query('select count(*) from studio_creative_results;')=='0')
 error(exsql('preview',{'job_id':R}),'RP403');ok('agency cannot preview another persons unapproved generated likeness')
 preview=ex('preview',{'job_id':R},actor=A);ok('subject alone receives private review storage capability',preview['sha256']=='c'*64 and preview['output_key'].startswith('presenter-private/'))
 error(exsql('accept',{'job_id':R,'expected_revision':review['revision'],'output_sha256':'c'*64,'output_consent':True}),'RP403')
 error(exsql('accept',{'job_id':R,'expected_revision':review['revision'],'output_sha256':'d'*64,'output_consent':True},actor=A),'RP409');ok('only subject can consent to the exact generated digest')
 approved=ex('accept',{'job_id':R,'expected_revision':review['revision'],'output_sha256':'c'*64,'output_consent':True},actor=A)['job']
 ok('accepted immutable bytes become available for authorized agency import',approved['state']=='accepted' and ex('preview',{'job_id':R})['sha256']=='c'*64)
 error(wsql(R,'output_ready',{'lease_token':lease['lease_token'],'sha256':'d'*64,'bytes':2048,'duration_s':12}),'RP409');ok('reviewed output bytes cannot be replaced by a later callback')
 importing=ex('import_prepare',{'job_id':R,'expected_revision':approved['revision']})
 ASSET=uid(5001)
 spec={'id':ASSET,'listing_id':LIST,'kind':'video','bucket':'renders','storage_key':f'renders/{ORG}/{LIST}/{ASSET}.mp4','bytes':2048,'sha256':'c'*64,'content_type':'video/mp4','content_type_declared':True,'idem_key':'presenter-'+R}
 query(f"set role service_role;select reserve_upload_assets('{B}',{lit([spec])});")
 bound=worker(R,'import_bind',{'asset_id':ASSET})['job'];ok('import uses existing quota reservation before marking exact accepted bytes',bound['import_asset_id']==ASSET and query(f"select presenter_job_id from capture_assets where id='{ASSET}';")==R)
 error(f"set role service_role;update capture_assets set sha256='{'d'*64}' where id='{ASSET}';",'RP409');ok('publication marker rejects mismatched output digest')
 for opkind in ['single','copy']:
  op=json.loads(query(f"set role service_role;select plan_upload_operation('{ASSET}','{opkind}');"));ct=uid(5100 if opkind=='single' else 5101)
  query(f"set role service_role;select claim_upload_operation('{op['id']}','{ct}');select finish_upload_operation('{op['id']}','{ct}','stored','synthetic-etag',null,'video/mp4');")
 completed_asset=json.loads(query(f"set role service_role;select settle_upload_reservation('{ASSET}',true,'{op['id']}',{lit({'sha256':'c'*64,'duration_s':12})});"))
 imported=worker(R,'import_commit')['job'];ok('confirmed native upload publishes exact bytes with generated-media disclosure',imported['state']=='imported' and imported['provenance_id'] and imported['import_storage_key']==completed_asset['storage_key'])
 query(f"set role service_role;select assert_studio_asset_quality('{ASSET}');")
 visible=query(f"set role authenticated;set request.jwt.claim.sub='{B}';select id from capture_assets where id='{ASSET}';")
 ok('accepted generated asset passes native publication guard and member RLS',visible==ASSET)
 error(f"set role service_role;update capture_assets set presenter_job_id=null where id='{ASSET}';",'RP409');ok('presenter privacy marker cannot be stripped')
 denied=query(f"set role authenticated;set request.jwt.claim.sub='{X}';select studio_presenter_asset_access('{ASSET}');")
 ok('boolean privacy predicate does not reveal access to another tenant',denied=='f')
 # Real native publish and tracked edit/reflection descendants must stop
 # issuing new capabilities after Presenter revocation, even though their rows
 # remain to satisfy downstream foreign keys.
 def native_render(asset,idem):
  created=json.loads(query(f"set role authenticated;set request.jwt.claim.sub='{B}';select to_jsonb(create_render_job('{LIST}','{asset}','smooth','{{}}',{val(idem)},'app'));"))
  published=json.loads(query(f"set role authenticated;set request.jwt.claim.sub='{B}';select to_jsonb(publish_render('{created['id']}',12,1));"))
  return created,published
 NATIVE,NATIVE_RENDER=native_render(ASSET,'presenter-native-replay')
 EDIT=uid(5201);CLIP=uid(5202);REFLECT=uid(5203)
 def add_edit(asset,duration):
  key=f'renders/{ORG}/{LIST}/{asset}.mp4';proofid=uid(int(asset[-12:])+100);resultid=uid(int(asset[-12:])+200)
  meta={'video_kind':'edit','asset_id':asset,'state':'completed','source_asset_ids':[ASSET],'disclosure':'Edited video with a reviewed AI presenter.','has_visual_ai':True}
  query(f"insert into capture_assets(id,listing_id,kind,bucket,storage_key,uploaded,sha256,bytes,duration_s) values('{asset}','{LIST}','video','renders','{key}',true,'{'e'*64}',2048,{duration});insert into media_provenance(id,org_id,listing_id,kind,disclosure,altered_key) values('{proofid}','{ORG}','{LIST}','other',{val(meta['disclosure'])},'{key}');insert into studio_creative_results(id,user_id,org_id,listing_id,kind,request_key,storage_key,bucket,provenance_id,metadata) values('{resultid}','{C}','{ORG}','{LIST}','video','fixture-edit-{asset}','{key}','renders','{proofid}',{lit(meta)});")
  return key,proofid
 EDIT_KEY,EDIT_PROOF=add_edit(EDIT,12);CLIP_KEY,_=add_edit(CLIP,4)
 EDIT_NATIVE,EDIT_RENDER=native_render(EDIT,'presenter-edited-replay')
 REFLECT_KEY=f'renders/{ORG}/{LIST}/{REFLECT}.mp4';BATCH=uid(5250)
 query(f"insert into capture_assets(id,listing_id,kind,bucket,storage_key,uploaded,sha256,bytes,duration_s) values('{REFLECT}','{LIST}','video','renders','{REFLECT_KEY}',true,'{'f'*64}',2048,12);")
 query(f"update orgs set plan='pro' where id='{ORG}';")
 erased=json.loads(query(f"set role service_role;select video_erase_reserve('{ORG}','{B}','{LIST}','{BATCH}','{CLIP}','{uid(5251)}','{'a'*64}',4);"))['job']
 ERASE_KEY=f'renders/{ORG}/{LIST}/fixture-reflection-clip.mp4';EREF={'request_id':'synthetic-reflection-job'}
 query(f"set role service_role;select video_erase_finish('{erased['id']}','completed',{lit(EREF)},'https://fixture.invalid/reflection.mp4','{ERASE_KEY}');select video_erase_apply('{ORG}','{B}','{BATCH}','{ASSET}','{REFLECT}');")
 vis=json.loads(query(f"set role service_role;select studio_presenter_media_visibility('{LIST}',array['{ASSET}'::uuid,'{EDIT}'::uuid,'{REFLECT}'::uuid],array['{NATIVE_RENDER['id']}'::uuid,'{EDIT_RENDER['id']}'::uuid],array['{EDIT_KEY}','{ERASE_KEY}','{REFLECT_KEY}']);"))
 ok('approved direct native, browser edit, and reflection descendants remain visible',all(vis['assets'].values()) and all(vis['renders'].values()) and all(vis['keys'].values()))
 revoke_prefix='begin;'+rpc(action='revoke_profile',payload={'profile_id':PROFILE,'expected_revision':2})
 revoked=query(revoke_prefix+f"select json_build_array(studio_presenter_media_access('{ASSET}'),studio_presenter_media_access('{EDIT}'),studio_presenter_media_access('{REFLECT}'),studio_presenter_render_access('{NATIVE_RENDER['id']}'),studio_presenter_render_access('{EDIT_RENDER['id']}'),studio_presenter_key_access('{LIST}','{ERASE_KEY}'));set role authenticated;set request.jwt.claim.sub='{B}';select json_build_array((select count(*) from capture_assets where id in ('{ASSET}','{EDIT}','{REFLECT}')),(select count(*) from renders where id in ('{NATIVE_RENDER['id']}','{EDIT_RENDER['id']}')),(select count(*) from media_provenance where id='{EDIT_PROOF}'));rollback;").splitlines()
 ok('revoked Presenter blocks new direct, native, edited and reflected capabilities',json.loads(revoked[-2])==[False]*6)
 ok('authenticated RLS hides retained native renders, edited capture rows and derived provenance',json.loads(revoked[-1])==[0,0,0])
 for sql in [f"set role authenticated;set request.jwt.claim.sub='{B}';select create_render_job('{LIST}','{ASSET}','smooth','{{}}','presenter-native-replay','app');",f"set role authenticated;set request.jwt.claim.sub='{B}';select publish_render('{NATIVE['id']}',12,1);",f"select video_erase_get('{ORG}','{B}','{erased['id']}');",f"select video_erase_existing('{ORG}','{B}','{uid(5251)}','{'a'*64}');",f"select video_erase_apply('{ORG}','{B}','{BATCH}','{ASSET}','{REFLECT}');"]:
  error(revoke_prefix+sql,'RP409')
 ok('native idempotent publish and reflection status/replay cannot bypass revocation')
 late=query(revoke_prefix+f"select video_erase_finish('{erased['id']}','completed',{lit(EREF)},'https://fixture.invalid/reflection.mp4','{ERASE_KEY}');rollback;").splitlines()
 redacted=json.loads(late[-1]);ok('late reflection completion preserves accounting while withholding revoked output URL',redacted['output_url'] is None and redacted['output_key'] is None and redacted['cost_ledger_id'] is not None)
 legacy=query(revoke_prefix+f"select json_build_array(studio_presenter_media_access('{VIDEO}'),studio_presenter_key_access('{LIST}','uploads/{ORG}/{LIST}/{VIDEO}.mp4'));rollback;").splitlines()
 ok('ordinary original media preserves existing read behavior',json.loads(legacy[-1])==[True,True])
 LEGACY_PROOF=uid(5350);LEGACY_KEY='renders/legacy-compliance/ordinary.jpg'
 query(f"insert into media_provenance(id,org_id,listing_id,kind,disclosure,altered_key) values('{LEGACY_PROOF}','{ORG}','{LIST}','photo_edit','Ordinary historical AI photo disclosure.','{LEGACY_KEY}');")
 audit=json.loads(query(revoke_prefix+f"select compliance_audit('{ORG}','{B}',null,null);rollback;").splitlines()[-1])
 audit_edit=next(x for x in audit['rows'] if x['id']==EDIT_PROOF)
 ok('service brokerage audit retains disclosure but redacts revoked edited media keys',audit_edit['altered_key'] is None and audit_edit['disclosure'] is not None)
 audit_legacy=next(x for x in audit['rows'] if x['id']==LEGACY_PROOF)
 ok('legacy property audit media remains intact alongside revoked Presenter redaction',audit_legacy['altered_key']==LEGACY_KEY and audit_legacy['agent_id']==A and audit_legacy['disclosure']=='Ordinary historical AI photo disclosure.')
 legacy_access=query(f"set role authenticated;set request.jwt.claim.sub='{B}';select json_build_array(studio_presenter_key_access('{LIST}','{LEGACY_KEY}'),studio_presenter_key_access('{L2}','{LEGACY_KEY}'),studio_presenter_key_access('{LIST}','renders/legacy-compliance/unknown.jpg'),(select count(*) from media_provenance where id='{LEGACY_PROOF}'));" )
 ok('legacy key authority requires an exact property record and preserves audit RLS',json.loads(legacy_access)==[True,False,False,1])
 foreign_key=f'renders/{OTHER}/{XL}/foreign.jpg'
 foreign_legacy=query(f"begin;insert into media_provenance(org_id,listing_id,kind,disclosure,altered_key) values('{ORG}','{LIST}','photo_edit','Synthetic foreign-key negative control.','{foreign_key}');set role authenticated;set request.jwt.claim.sub='{B}';select studio_presenter_key_access('{LIST}','{foreign_key}');rollback;")
 ok('recording a foreign canonical key never grants another property signing authority',foreign_legacy=='f')
 legacy_label=json.loads(query(f"set role authenticated;set request.jwt.claim.sub='{B}';select to_jsonb(set_provenance_media('{LEGACY_PROOF}',null,null,'Legacy label'));"))
 ok('ordinary recorded legacy media survives label-only audit edits',legacy_label['altered_key']==LEGACY_KEY)

 labeled=json.loads(query(revoke_prefix+f"set role authenticated;set request.jwt.claim.sub='{B}';select to_jsonb(set_provenance_media('{EDIT_PROOF}',null,null,'Updated label'));rollback;").splitlines()[-1])
 ok('label-only provenance edits cannot return revoked keys for new signed URLs',labeled['altered_key'] is None and labeled['label']=='Updated label')
 error(f"set role authenticated;set request.jwt.claim.sub='{X}';select studio_presenter_media_visibility('{LIST}',array['{ASSET}'::uuid]);",'RP404')
 same_org=json.loads(query(f"set role authenticated;set request.jwt.claim.sub='{B}';select studio_presenter_media_visibility('{L2}',array['{ASSET}'::uuid],array['{NATIVE_RENDER['id']}'::uuid],array['{EDIT_KEY}']);"))
 ok('batch visibility rejects foreign workspace and same-workspace foreign property identities',not any(same_org['assets'].values()) and not any(same_org['renders'].values()) and not any(same_org['keys'].values()))
 deletion=query(f"begin;set role service_role;select prepare_account_deletion('{C}','fixture-uploads','fixture-renders');reset role;delete from auth.users where id='{C}';"+rpc(action='revoke_profile',payload={'profile_id':PROFILE,'expected_revision':2})+f"select json_build_array((select count(*) from studio_creative_results where metadata->>'asset_id'='{EDIT}'),studio_presenter_media_access('{EDIT}'),studio_presenter_render_access('{EDIT_RENDER['id']}'),studio_presenter_key_access('{LIST}','{EDIT_KEY}'));rollback;").splitlines()
 ok('deleting edit author cannot detach retained shared media from revoked Presenter ancestry',json.loads(deletion[-1])==[0,False,False,False])
 detached=query(revoke_prefix+f"reset role;delete from video_erase_batches where id='{BATCH}';delete from studio_creative_results where metadata->>'asset_id' in ('{EDIT}','{CLIP}');delete from capture_assets where id='{CLIP}';set role service_role;select json_build_array(studio_presenter_media_access('{REFLECT}'),studio_presenter_key_access('{LIST}','{REFLECT_KEY}'),studio_presenter_media_access('{EDIT}'));rollback;").splitlines()
 ok('deleted reflection history and missing intermediate source keep durable ancestry denial',json.loads(detached[-1])==[False,False,False])
 error(revoke_prefix+f"select assert_studio_edit_quality('{REFLECT}');",'RP409')
 ok('recursive publication hook denies unmarked reflection descendants')
 # Cycles terminate in a bounded walk; they never hide a reachable revoked
 # source, and an overlarge graph fails closed without changing legacy media.
 cycle=query(revoke_prefix+f"reset role;insert into studio_presenter_media_sources(listing_id,asset_id,source_asset_id,storage_key) values('{LIST}','{ASSET}','{EDIT}','{EDIT_KEY}');set role service_role;select studio_presenter_media_access('{EDIT}');rollback;").splitlines()
 ok('cyclic ancestry cannot hide a reachable revoked Presenter',cycle[-1]=='f')
 huge=query(f"begin;insert into studio_presenter_media_sources(listing_id,asset_id,source_asset_id,storage_key) select '{LIST}','{VIDEO}',('90000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'uploads/{ORG}/{LIST}/{VIDEO}.mp4' from generate_series(1,201) n;set role service_role;select studio_presenter_media_access('{VIDEO}');rollback;")
 ok('oversized ancestry fails closed at the documented 200-identity bound',huge=='f')
 query(f"insert into render_jobs(listing_id,capture_asset_id) values('{LIST}','{ASSET}');insert into video_erase_batches(id,org_id,user_id,listing_id,provenance_id,original_asset_id) values('{uid(5600)}','{ORG}','{C}','{LIST}','{imported['provenance_id']}','{ASSET}');")
 ok('accepted output has real native and reflection NO ACTION foreign-key consumers')
 # Transaction rollback keeps an accepted fixture for multiple distinct invalidators.
 for name,mutation in [('source mutation',f"update capture_assets set sha256='{'b'*64}' where id='{VIDEO}'"),('source duration mutation',f"update capture_assets set duration_s=13 where id='{VIDEO}'"),('reference mutation',f"update capture_assets set sha256='{'b'*64}' where id='{PHOTO}'"),('profile revocation',rpc(action='revoke_profile',payload={'profile_id':PROFILE,'expected_revision':2}).strip().removesuffix(';')),('subject deletion intent',f"insert into deletion_requests(user_id,status) values('{A}','pending')"),('requester membership removal',f"delete from memberships where user_id='{B}' and org_id='{ORG}'")]:
  result=query(f"begin;{mutation};reset role;set role service_role;select json_build_array((select state from studio_presenter_jobs where id='{R}'),(select held_cents from studio_presenter_jobs where id='{R}'),(select snapshot is null from studio_presenter_jobs where id='{R}'),(select count(*) from capture_assets where id='{ASSET}'),studio_presenter_asset_access('{ASSET}'));rollback;").splitlines()
  ok(name+' immediately fences output, retains uncertain hold and cleanup tombstone',json.loads(result[-1])==['invalidated',100,True,1,False])
 removal=query(f"begin;delete from video_erase_batches where original_asset_id='{ASSET}';delete from renders where job_id in (select id from render_jobs where capture_asset_id='{ASSET}');delete from render_jobs where capture_asset_id='{ASSET}';delete from capture_assets where id='{ASSET}';select json_build_array((select state from studio_presenter_jobs where id='{R}'),(select cleanup_state from studio_presenter_jobs where id='{R}'));rollback;")
 ok('explicit deletion of imported output also invalidates its private preview',json.loads(removal)==['invalidated','pending'])
 rejected=ex('reject',{'job_id':R,'expected_revision':imported['revision']},actor=A)['job'];ok('subject rejection retains denied FK identity without refunding unknown cost',rejected['state']=='rejected' and rejected['held_cents']==100 and query(f"set role service_role;select studio_presenter_asset_access('{ASSET}');")=='f')
 error(exsql('preview',{'job_id':R},actor=A),'RP403');ok('rejected output cannot receive another preview URL')
 blocked=worker(R,'cleanup_claim');ok('cleanup waits for private write deadline to prevent write-after-delete',not blocked['claimed'])
 query(f"update studio_presenter_jobs set output_write_deadline=clock_timestamp()-interval '2 minutes' where id='{R}';")
 cleanup=worker(R,'cleanup_claim');ok('durable cleanup inventory includes private and accepted imported objects',cleanup['claimed'] and {t['bucket'] for t in cleanup['targets']}=={'uploads','renders'})
 error(wsql(R,'cleanup_done',{'cleanup_token':cleanup['cleanup_token']}),'RP409');ok('cleanup completion requires confirmed deletion evidence')
 worker(R,'cleanup_done',{'cleanup_token':cleanup['cleanup_token'],'objects_deleted':True});ok('object cleanup never silently refunds a possibly paid request',query(f"select held_cents from studio_presenter_jobs where id='{R}';")=='100')
 # Identity deletion must preserve accounting while erasing personal snapshots.
 pending=fresh();P=pending['id'];cl=worker(P,'dispatch_claim');worker(P,'ambiguous',{'dispatch_token':cl['dispatch_token']});quote_only=quote()
 for name,mutation in [('subject',f"set role service_role;select prepare_account_deletion('{A}','fixture-uploads','fixture-renders');reset role;delete from auth.users where id='{A}'"),('author',f"set role service_role;select prepare_account_deletion('{B}','fixture-uploads','fixture-renders');reset role;delete from auth.users where id='{B}'"),('profile',f"delete from studio_presenter_profiles where id='{PROFILE}'"),('source property',f"delete from listings where id='{LIST}'"),('workspace',f"delete from orgs where id='{ORG}'")]:
  data=query(f"begin;{mutation};reset role;set role service_role;select json_build_array((select held_cents from studio_presenter_jobs where id='{P}'),(select state from studio_presenter_jobs where id='{P}'),(select snapshot is null from studio_presenter_jobs where id='{P}'),(select count(*) from studio_presenter_quotes where id='{quote_only['id']}'));rollback;").splitlines()
  ok(name+' hard deletion preserves uncertain spend and deletes quote-only personal snapshot',json.loads(data[-1])==[100,'invalidated',True,0])
 for role in ['anon','authenticated']:
  for table in ['studio_presenter_jobs','studio_presenter_quotes','studio_presenter_runtime']:error(f'set role {role};select * from {table};','permission denied')
  error(f"set role {role};select studio_presenter_execution_worker('{P}','dispatch_claim');",'permission denied')
  error(exsql('get').replace('set role service_role',f'set role {role}'),'permission denied')
 ok('untrusted database roles cannot spoof actor quote cost or worker authority')
 # Stale/expired quotes and stale dispatches remain recoverable, never redispatched.
 expired=quote();query(f"update studio_presenter_quotes set created_at=statement_timestamp()-interval '10 minutes',expires_at=statement_timestamp()-interval '5 minutes' where id='{expired['id']}';")
 error(exsql('create',{'quote_id':expired['id'],'idempotency_key':uid(5555),'cost_consent':True,'max_cost_cents':100}),'RP409')
 ex();ok('expired quotes cannot reserve money and are scrubbed from durable storage',query(f"select count(*) from studio_presenter_quotes where id='{expired['id']}';")=='0')
 stale=fresh();worker(stale['id'],'dispatch_claim');query(f"update studio_presenter_jobs set dispatch_started_at=clock_timestamp()-interval '3 minutes' where id='{stale['id']}';")
 due=json.loads(query('set role service_role;select studio_presenter_execution_due(50);'))
 ok('crashed dispatch is listed as uncertain and cannot be resubmitted',any(j['id']==stale['id'] and j['state']=='uncertain' for j in due['jobs']) and not worker(stale['id'],'dispatch_claim')['claimed'])
 # Bounded state response must not fail once an agency has many estimates.
 template=quote();query(f"insert into studio_presenter_quotes(id,org_id,listing_id,actor_id,subject_user_id,draft_id,profile_id,snapshot,probe,runtime_revision,price_version,quote_cents,hold_cents,created_at,expires_at) select gen_random_uuid(),org_id,listing_id,actor_id,subject_user_id,draft_id,profile_id,snapshot,probe,runtime_revision,price_version,quote_cents,hold_cents,created_at,expires_at from studio_presenter_quotes cross join generate_series(1,101) where id='{template['id']}';")
 capped=ex();ok('quote list is bounded and reports truncation',len(capped['quotes'])==100 and capped['truncated']['quotes'])
 # An authoritative closed submission fences a delayed create, including a
 # different request key trying to reuse the same quote.
 closeq=quote();closekey=uid(5700)
 closed=ex('close_submission',{'quote_id':closeq['id'],'idempotency_key':closekey})
 ok('missing submission is closed atomically without inventing a job',closed['closed_submission']['quote_id']==closeq['id'])
 for k in [closekey,uid(5701)]:error(exsql('create',{'quote_id':closeq['id'],'idempotency_key':k,'cost_consent':True,'max_cost_cents':100}),'RP409')
 ok('closed quote cannot be submitted later under the same or another request key')
 recovered=ex('close_submission',{'quote_id':pending['quote_id'],'idempotency_key':pending['idempotency_key']})
 ok('closing lost accepted response returns the existing durable job',recovered['replayed'] and recovered['job']['id']==P)
 # A quote expires while its create statement is waiting for the shared lock.
 timed=quote();query(f"update studio_presenter_quotes set expires_at=clock_timestamp()+interval '0.25 seconds' where id='{timed['id']}';")
 blocker=subprocess.Popen(PSQL,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=ENV)
 blocker.stdin.write(f"begin;select pg_advisory_xact_lock(hashtextextended('studio-presenter:{ORG}',0));select 'locked';\n");blocker.stdin.flush()
 while blocker.stdout.readline().strip()!='locked':pass
 with ThreadPoolExecutor(max_workers=1) as pool:
  future=pool.submit(racing_create,timed)
  time.sleep(0.35)
  blocker.stdin.write('commit;\n');blocker.stdin.flush();blocker.stdin.close();blocker.wait(timeout=5)
  waited=future.result()
 ok('quote expiry uses current time after waiting for budget lock',waited[0]=='error' and 'RP409' in waited[1])
 # Spec changes cannot silently modify a previously quoted request.
 fixed=quote();committed_spec=json.loads(query(f"select execution_spec from studio_presenter_quotes where id='{fixed['id']}';"))
 version_change="create or replace function public.studio_presenter_execution_spec() returns jsonb language sql immutable as $$select '{\"version\":\"future-version\",\"prompt\":\"different\"}'::jsonb$$;"
 fixed_result=query(f"begin;{version_change}{exsql('create',{'quote_id':fixed['id'],'idempotency_key':uid(5750),'cost_consent':True,'max_cost_cents':100})}select execution_spec from studio_presenter_jobs where quote_id='{fixed['id']}';rollback;").splitlines()
 ok('creation copies exact quoted execution specification rather than a new default',json.loads(fixed_result[-1])==committed_spec)
 # Unknown accepted jobs consume shared provider capacity across workspaces.
 third=fresh();ok('third unresolved provider claim fills shared capacity',worker(third['id'],'dispatch_claim')['claimed'])
 xvideo=uid(5801);xdraft=uid(5802)
 query(f"insert into capture_assets(id,listing_id,kind,bucket,storage_key,uploaded,sha256,bytes,duration_s) values('{xvideo}','{XL}','video','uploads','uploads/{OTHER}/{XL}/{xvideo}.mp4',true,'{'a'*64}',1000,12);")
 xs=workspace(actor=X,listing=XL,org=OTHER,action='save_profile',payload={'expected_revision':0,'display_name':'Other Agent','reference_asset_ids':[XPHOTO]});xp=xs['profiles'][0]['id']
 workspace(actor=X,listing=XL,org=OTHER,action='approve_profile',payload={'profile_id':xp,'expected_revision':1,'likeness_consent':True})
 workspace(actor=X,listing=XL,org=OTHER,action='save_draft',payload={**draft_payload(xp,source=xvideo),'draft_id':xdraft})
 workspace(actor=X,listing=XL,org=OTHER,action='approve_draft',payload={'draft_id':xdraft,'expected_revision':1,'expected_profile_revision':2,'source_performance_consent':True})
 query(f"insert into studio_presenter_runtime(org_id,enabled,enterprise_no_training_confirmed,contract_reference,price_version,max_job_cents,total_budget_cents) values('{OTHER}',true,true,'synthetic-test-only','fixture-v1',100,1000);")
 xquote=ex('quote_commit',{'draft_id':xdraft,'expected_revision':2,'expected_profile_revision':2,'quote_id':uid(5803),'quote_cents':25,'price_version':'fixture-v1','execution_spec':SPEC,'probe':{'sha256':'a'*64,'bytes':1000,'duration_s':12}},actor=X,org=OTHER,listing=XL)['quote']
 xjob=ex('create',{'quote_id':xquote['id'],'idempotency_key':uid(5804),'cost_consent':True,'max_cost_cents':100},actor=X,org=OTHER,listing=XL)['job']
 cap=worker(xjob['id'],'dispatch_claim');ok('shared provider limit also fences a different organization without releasing its budget',not cap['claimed'] and cap['capacity_limited'] and cap['job']['held_cents']==100 and cap['job']['dispatch_started_at'] is None)
 for settled_id in [P,stale['id'],third['id']]:worker(settled_id,'cancelled',{'billing_final':True,'charged_cents':0,'billing_reference':'synthetic-end-of-test'})
 ok('confirmed terminal status frees capacity without duplicate submissions',worker(xjob['id'],'dispatch_claim')['claimed'])
 worker(xjob['id'],'cancelled',{'billing_final':True,'charged_cents':0,'billing_reference':'synthetic-end-of-test'})
 # Provider completion releases concurrency even when the local user cancelled;
 # output remains inaccessible and no billing/refund is inferred.
 abandoned=fresh();ac=worker(abandoned['id'],'dispatch_claim');queued=worker(abandoned['id'],'dispatch_result',{'dispatch_token':ac['dispatch_token'],'request_id':abandoned['id'],'status_url':'https://fixture.invalid/status'})['job']
 ex('cancel',{'job_id':abandoned['id'],'expected_revision':queued['revision']})
 finished=worker(abandoned['id'],'completed')['job']
 ok('completed provider after cancellation frees capacity without releasing unknown charge',finished['provider_terminal_at'] is not None and finished['state']=='cancelled' and finished['held_cents']==100 and not worker(abandoned['id'],'output_claim')['claimed'])
 ck=worker(abandoned['id'],'cleanup_claim');worker(abandoned['id'],'cleanup_done',{'cleanup_token':ck['cleanup_token'],'objects_deleted':True})
 ok('normal terminal state survives snapshot scrubbing during cleanup',worker(abandoned['id'],'read')['job']['state']=='cancelled')
 one=json.loads(query('set role service_role;select studio_presenter_execution_due(1);'))['jobs']
 two=json.loads(query('set role service_role;select studio_presenter_execution_due(1);'))['jobs']
 ok('bounded maintenance rotates fairly instead of starving later work',one and two and one[0]['id']!=two[0]['id'])
 if '--controller' in sys.argv:
  fixture=OUT/'controller-fixture.json';fixture.write_text(json.dumps({'psql':PSQL,'root':str(ROOT),'socket':str(SOCK),'ownedOutput':str(OUT)}))
  controller_env={**ENV,'PRESENTER_PG_FIXTURE':str(fixture)}
  deno=shutil.which('deno') or '/opt/homebrew/bin/deno'
  proc=subprocess.run([deno,'test','--allow-env','--allow-read',f'--allow-run={PG/"psql"}','--node-modules-dir=auto',str(SQL/'functions/studio/presenter-execution-pg.test.ts')],env=controller_env,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
  (OUT/'controller.log').write_text(proc.stdout)
  if proc.returncode:raise AssertionError(proc.stdout[-10000:])
  ok('actual execution controller runs against this disposable PostgreSQL ledger')
 completed=True
finally:
 failure=str(sys.exc_info()[1]) if sys.exc_info()[1] else None
 if started:run([PG/'pg_ctl','-D',OUT/'data','-m','fast','-w','stop'])
 receipt={'ok':completed,'passed':len(passed),'checks':passed,'productionCalls':0,'socketOnly':True,'clusterStopped':started,'output':str(OUT),'sourceSHA256':source_hashes,'error':failure}
 (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt,indent=2))
