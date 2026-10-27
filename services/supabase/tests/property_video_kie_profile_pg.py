#!/usr/bin/env python3
"""Kie Kling 3.0 native-4K property-video profile (kie-kling3-4k-steady-v1).

Real disposable PostgreSQL: catalog boundary, canonical identity file equality,
own-migration replay (route OFF and activated), FAL regressions, compiled
negative controls against the ACTUAL installed functions, the owner-approved
operator scripts (docs/handoff/KIE-ACTIVATION.sql with its required processor-
disclosure attestation and activation record, KIE-ROLLBACK.sql restoring exactly
the recorded previous selector in default and emergency modes) run exactly as an
operator runs them, the read-only verification (docs/handoff/KIE-READONLY-
VERIFY.sql) in every operator state, compiled controls against the actual
operator scripts, verification and invariant text, the whole invariant inventory
(tests/invariants.sql) on disposable copies of every operator state with red
controls for the reseller-row exception, and real concurrent races. No network,
provider, paid generation or credential is used.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from fresh_schema_migrations import partition_fresh_migrations
from threading import Barrier
import argparse,hashlib,importlib.util,json,re,shutil,subprocess,tempfile,time,os,sys,signal
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path,required=True);args=p.parse_args()
OUT=args.evidence_dir.resolve();OUT.mkdir(parents=True,exist_ok=False);OUT.chmod(0o700)
WHOLE_SECONDS=1080;DATA_PREFIX='kie-profile-owned-pg-';SOCK_PREFIX='kie-profile-sock-'

os.umask(0o077)
EXTERNAL=Path('/Volumes/Rendprop Files')
PROOF_DEADLINE=time.monotonic()+WHOLE_SECONDS

def guard():
 assert shutil.disk_usage(ROOT).free>=3*1024**3,'Preserve source3GiB reserve'
 assert shutil.disk_usage(OUT).free>=1024**3,'Preserve isolated evidence1GiB reserve'
 if sys.platform=='darwin':
  assert EXTERNAL.is_mount() and OUT.is_relative_to(EXTERNAL),'Keep local PG evidence on the mounted external volume'
 if EXTERNAL.is_mount() and OUT.is_relative_to(EXTERNAL):
  assert shutil.disk_usage(EXTERNAL).free>=8*1024**3,'Preserve external8GiB reserve'
 assert time.monotonic()<PROOF_DEADLINE,'Whole proof deadline'

guard()
ENV={'PATH':os.environ.get('PATH','/usr/bin:/bin'),'LC_ALL':'C','TZ':'UTC','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
pg_config=shutil.which('pg_config',path=ENV['PATH'])
if pg_config:
 bindir=subprocess.check_output([pg_config,'--bindir'],text=True,env=ENV,timeout=10).strip()
 assert Path(bindir).is_absolute() and Path(bindir).is_dir(),'PostgreSQL tool directory required'
 ENV['PATH']=bindir+os.pathsep+ENV['PATH']
tool=lambda name:shutil.which(name,path=ENV['PATH'])
assert all(tool(n)for n in ['initdb','pg_ctl','createdb','psql']),'Already-installed PostgreSQL tools required'
DATA=Path(tempfile.mkdtemp(prefix=DATA_PREFIX,dir=OUT));SOCK=Path(tempfile.mkdtemp(prefix=SOCK_PREFIX,dir='/tmp'));started=False

def terminate(_signal,_frame):raise SystemExit('Stopped by outer resource/wall guard')
signal.signal(signal.SIGTERM,terminate)

def execute(cmd,body=None,env=None,timeout=120,guarded=True):
 # Own a new child process group and bound both command and exceptional drain.
 if guarded:guard()
 child=subprocess.Popen([str(x)for x in cmd],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,env=env or ENV,cwd=ROOT,start_new_session=True)
 end=time.monotonic()+timeout
 try:
  while True:
   try:
    output,_=child.communicate(input=body,timeout=.5)
    return subprocess.CompletedProcess(cmd,child.returncode,output)
   except subprocess.TimeoutExpired:
    body=None
    if guarded:guard()
    assert time.monotonic()<end,'Command deadline'
 except BaseException as error:
  try:os.killpg(child.pid,signal.SIGKILL)
  except ProcessLookupError:pass
  try:output,_=child.communicate(timeout=5)
  except subprocess.TimeoutExpired as drain:
   output=drain.output or ''
   if isinstance(output,bytes):output=output.decode('utf-8','replace')
   for pipe in [child.stdin,child.stdout,child.stderr]:
    if pipe is not None:pipe.close()
   child.wait(timeout=5)
  error.proof_output=output;error.proof_returncode=child.returncode
  raise

def log_command(name,c,error=None):
 f=OUT/(name+'.log');f.write_text(c.stdout);f.chmod(0o600)
 entry={'name':name,'exit':c.returncode,'logSHA256':hashlib.sha256(f.read_bytes()).hexdigest()}
 if error is not None:entry['failure']=type(error).__name__
 r['commands'].append(entry)

def cleanup_owned():
 # A failed start reply may still leave this exact postmaster running.
 pidfile=DATA/'postmaster.pid'
 if started or pidfile.exists():
  assert DATA.is_dir() and not DATA.is_symlink() and DATA.stat().st_uid==os.getuid(),'Owned data directory identity'
  assert pidfile.is_file() and not pidfile.is_symlink(),'Owned postmaster identity required'
  lines=pidfile.read_text().splitlines();assert len(lines)>1 and int(lines[0])>1 and Path(lines[1]).resolve()==DATA.resolve(),'Owned postmaster data identity'
  state=subprocess.run(['ps','-p',lines[0],'-o','command='],capture_output=True,text=True,timeout=5)
  assert state.returncode==0 and str(DATA)in state.stdout and 'postgres'in state.stdout,'Owned postmaster process identity'
  stopped=execute([tool('pg_ctl'),'-D',DATA,'-m','immediate','-w','stop'],timeout=30,guarded=False);log_command('stop',stopped)
  assert stopped.returncode==0,'Owned cluster cleanup failed'
 assert not pidfile.exists(),'Owned postmaster remains'
 shutil.rmtree(DATA);shutil.rmtree(SOCK)
 r['ownedClusterRemoved']=not DATA.exists() and not SOCK.exists()

PORT='55781'
MIG=SQL/'migrations/20261016100000_property_video_kie_kling3_4k_profile.sql';FIX=SQL/'tests/property_video_kie_profile.sql'
BASE=SQL/'tests/property_video_jobs.sql';STEADY=SQL/'tests/property_video_steady_v2.sql';V1=SQL/'tests/property_video_quality_profile.sql'
IDENTITY=SQL/'functions/_shared/property-video-kie-identity.json'
# Read by the Deno identity test (functions/ai-video): what this schema returns.
PG_FIXTURE=SQL/'functions/ai-video/fixtures/kie-property-identity-pg.json'
ACTIVATION=ROOT/'docs/handoff/KIE-ACTIVATION.sql';ROLLBACK=ROOT/'docs/handoff/KIE-ROLLBACK.sql';VERIFY=ROOT/'docs/handoff/KIE-READONLY-VERIFY.sql';ROUTE_OFF=ROOT/'docs/handoff/KIE-ROUTE-OFF.sql'
SCOPE_MIG=SQL/'migrations/20261016110000_property_video_kie_scope_consent_drain.sql'
# The full invariant inventory and its shared acceptance contract (exact count,
# contiguous numbering, unique names, exit/footer agreement).
INVARIANTS=SQL/'tests/invariants.sql';ASTRA_GATES=SQL/'tests/invariant_astra_paid_gates.sql';CONTRACT=ROOT/'tools/audit/run_database_regression.py'
spec=importlib.util.spec_from_file_location('database_contract',CONTRACT);contract=importlib.util.module_from_spec(spec);spec.loader.exec_module(contract)
MIGRATIONS=sorted((SQL/'migrations').glob('*.sql'));assert MIG in MIGRATIONS
# Prove this migration at its own point. The v1 and steady-v2 regressions are
# valid there; the current whole-history jobs fixture belongs after LATER,
# because its trial limits describe the final schema rather than this boundary.
# Later migrations must keep the Kie fixture and all three regressions green.
OWN=[m for m in MIGRATIONS if m.name<=MIG.name];LATER=[m for m in partition_fresh_migrations(MIGRATIONS)[0] if m.name>MIG.name]
SOURCES=[*MIGRATIONS,SQL/'tests/ci-bootstrap.sql',BASE,STEADY,V1,FIX,IDENTITY,PG_FIXTURE,ACTIVATION,ROLLBACK,VERIFY,ROUTE_OFF,INVARIANTS,ASTRA_GATES,CONTRACT,Path(__file__).resolve()]
hashes=lambda:{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest()for f in SOURCES}
T0=time.monotonic()
r={'passed':False,'scope':'actual local PostgreSQL schema/functions/roles; closed receipt fixtures, no supplier calls','networkCalls':0,'providerCalls':0,'sourceHashes':hashes(),'commands':[],'regressions':{},'controls':[],'steadyControls':[],'operatorScripts':[],'activationRecord':[],'scriptControls':[],'verify':[],'verifyControls':[],'resellerInvariant':[],'races':[],'raceControls':[],'pgFixture':{'stages':{},'controls':[]}}
ROUTE='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21';PROFILE='kie-kling3-4k-steady-v1';ACTOR='f1100000-0000-4000-8000-000000000001'
KIE_ON='{"enabled":true,"profile":"kie-kling3-4k-steady-v1","vendor_content_license":"kie-terms-2025-08-01-section-3-owner-accepted"}';FAL_V2='{"enabled":true,"profile":"fal-kling3-4k-steady-v2"}'
# The activation record key and two realistic processor-disclosure identifiers.
RECORD_KEY='property_video_quality_kie_activation';DISCLOSURE='privacy-policy-2026-10-16#processors-kie';DISCLOSURE_URL='https://example.com/legal/privacy?v=2026-10-16&lang=en#processors'
CONSENT_REVISION='owned-profile-driver-r1'
PERMISSION=json.dumps({'token':'property-video-jobs-v2','disclosure_revision':CONSENT_REVISION},separators=(',',':'))
PUBLISHED_CONSENT="insert into public.app_config(key,value)values('property_video_processor_consent','"+json.dumps({'token':'property-video-jobs-v2','disclosure_revision':CONSENT_REVISION,'processors':['fal','kie'],'profiles':[PROFILE]},separators=(',',':'))+"')on conflict(key)do update set value=excluded.value;"

def run(name,cmd,body=None,refuses=None,env=None):
 try:c=execute(cmd,body,env=env,timeout=120)
 except BaseException as error:
  c=subprocess.CompletedProcess(cmd,getattr(error,'proof_returncode',None),getattr(error,'proof_output',''));log_command(name,c,error);raise
 log_command(name,c)
 assert(c.returncode!=0 and refuses in c.stdout)if refuses else c.returncode==0,(name,c.stdout[-4000:]);return c.stdout
def race(name,commands):
 # Each command is SQL fed to psql -Atq, or (argv, stdin) for an exact invocation.
 guard()
 barrier=Barrier(len(commands))
 def call(pair):
  i,body=pair;cmd,stdin=body if isinstance(body,tuple)else([*PSQL,'-Atq'],body);barrier.wait(timeout=10);start=time.monotonic()
  c=execute(cmd,stdin,timeout=30)
  (OUT/f'{name}-{i}.log').write_text(c.stdout);(OUT/f'{name}-{i}.log').chmod(0o600)
  return{'exit':c.returncode,'output':c.stdout,'elapsed':time.monotonic()-start}
 with ThreadPoolExecutor(max_workers=len(commands))as pool:return list(pool.map(call,enumerate(commands)))
def result_line(out):
 rows=[json.loads(line)for line in out.splitlines()if line.startswith('{')and'"assertions"'in line];assert len(rows)==1 and rows[0]['passed'],out[-2000:];return rows[0]
def scalar(name,query):return run(name,[*PSQL,'-Atq','-c',query]).strip()
def one_json(name,body,refuses=None):
 out=run(name,[*PSQL,'-Atq'],body,refuses);rows=[l for l in out.splitlines()if l.startswith('{')];assert len(rows)==1,(name,out[-2000:]);return json.loads(rows[0])

# Exact md5 anchors declared by the migration itself (before -> after).
PAIRS={m[0]:(m[1],m[2])for m in re.findall(r"\('(public\.[^']+)','([0-9a-f]{32})','([0-9a-f]{32})'",MIG.read_text())}
SIGNATURES=['public.property_video_quality_profile()','public.property_video_quality_freeze()','public.property_video_job_admit(uuid,jsonb,numeric,text)','public.paid_quality_processing_budget(uuid)','public.property_video_job_audio_preflight(uuid,uuid,text,text,numeric,integer)','public.background_video_delivery(uuid,uuid,uuid,text,bigint)']
assert sorted(PAIRS)==sorted(SIGNATURES),('migration anchors',PAIRS)
# The later consent migration changes exactly these three known dependencies.
# Keep the first-migration boundary pins above; the operator sees final bodies.
SCOPE_PAIRS={x[0]:(x[1],x[2])for x in re.findall(r"\('(public\.[^']+)','([0-9a-f]{32})','([0-9a-f]{32})'",SCOPE_MIG.read_text())}
assert set(SCOPE_PAIRS)=={'public.paid_quality_processing_budget(uuid)','public.property_video_quality_freeze()','public.property_video_job_admit(uuid,jsonb,numeric,text)'}
assert all(PAIRS[k][1]==v[0]for k,v in SCOPE_PAIRS.items()),'migration pin chronology'
FINAL_PINS={k:SCOPE_PAIRS[k][1]if k in SCOPE_PAIRS else v[1]for k,v in PAIRS.items()}
# The operational verifier targets the full current schema. The Kie and
# consent boundary pins above remain exact at their historical migrations.
# These five later bodies are the deliberate prompt registry (admit/budget),
# Photo Motion (freeze/audio), and registered publication (delivery) changes.
OPERATOR_FINAL_PINS={
 'public.property_video_quality_profile()':'9671b48a46a1e777bc4b968c1a669d44',
 'public.property_video_quality_freeze()':'d3739899b2177091178aa93b886d8873',
 'public.property_video_job_admit(uuid,jsonb,numeric,text)':'2929b69b330f4ab7a5aca6257e86398b',
 'public.paid_quality_processing_budget(uuid)':'720cf8958b09c01e9d1059ea3d732946',
 'public.property_video_job_audio_preflight(uuid,uuid,text,text,numeric,integer)':'2af2e6a298ecfae7c58d6845b94ab509',
 'public.background_video_delivery(uuid,uuid,uuid,text,bigint)':'0d5766730ab7c061abc8ee4f2bd10a7e'}
assert set(OPERATOR_FINAL_PINS)==set(SIGNATURES)

TARGETS=','.join("'%s'::regprocedure"%s for s in SIGNATURES);SIGS=','.join("'%s'"%s for s in SIGNATURES)
CATALOG="""with f as(select p.oid,p.oid::regprocedure::text signature,md5(p.prosrc)body,pg_get_userbyid(p.proowner)owner,p.prosecdef,p.provolatile,p.proconfig,p.proacl::text acl,l.lanname lang,pg_get_function_result(p.oid)result
 from pg_proc p join pg_language l on l.oid=p.prolang where p.pronamespace='public'::regnamespace and p.prokind in('f','p')),
 kie as(select oid from pg_proc where pronamespace='public'::regnamespace and proname='property_video_quality_identity'),
 col as(select attnum from pg_attribute where attrelid='public.property_video_jobs'::regclass and attname='quality_identity'and not attisdropped)
select jsonb_build_object(
 'target_metadata',(select jsonb_object_agg(signature,to_jsonb(f)-'oid'-'body')from f where oid in(TARGETS)),
 'target_bodies',(select jsonb_object_agg(s,md5(p.prosrc))from unnest(array[SIGS])s join pg_proc p on p.oid=s::regprocedure),
 'identity_function',(select to_jsonb(f)-'oid'from f where oid in(select oid from kie)),
 'other_functions',(select md5(string_agg((to_jsonb(f)-'oid')::text,E'\\n'order by signature))from f where oid not in(TARGETS)and oid not in(select oid from kie)),
 'other_constraints',(select md5(string_agg(conrelid::regclass||':'||conname||':'||pg_get_constraintdef(oid),E'\\n'order by conrelid::regclass::text,conname))from pg_constraint where connamespace='public'::regnamespace and conname<>'property_video_quality_profile_check'),
 'profile_constraint',(select pg_get_constraintdef(oid)from pg_constraint where conrelid='public.property_video_jobs'::regclass and conname='property_video_quality_profile_check'and contype='c'and convalidated),
 'other_columns',(select md5(string_agg(table_name||'.'||column_name||':'||ordinal_position||':'||data_type||':'||is_nullable||':'||coalesce(column_default,''),E'\\n'order by table_name,ordinal_position))from information_schema.columns where table_schema='public'and not(table_name='property_video_jobs'and column_name='quality_identity')),
 'identity_column',(select jsonb_build_object('type',format_type(atttypid,atttypmod),'notnull',attnotnull,'hasdef',atthasdef,'last',attnum=(select max(attnum)from pg_attribute where attrelid='public.property_video_jobs'::regclass and attnum>0),'comment',col_description(attrelid,attnum))from pg_attribute where attrelid='public.property_video_jobs'::regclass and attname='quality_identity'and not attisdropped),
 'triggers',(select md5(string_agg(tgrelid::regclass||':'||tgname||':'||pg_get_triggerdef(oid),E'\\n'order by tgrelid::regclass::text,tgname))from pg_trigger where not tgisinternal and tgrelid in(select oid from pg_class where relnamespace='public'::regnamespace)),
 'indexes',(select md5(string_agg(indexrelid::regclass||':'||pg_get_indexdef(indexrelid),E'\\n'order by indexrelid::regclass::text))from pg_index where indrelid in(select oid from pg_class where relnamespace='public'::regnamespace)),
 'relations',(select md5(string_agg(relname||':'||relkind::text||':'||coalesce(relacl::text,'')||':'||relrowsecurity||':'||relforcerowsecurity,E'\\n'order by relname))from pg_class where relnamespace='public'::regnamespace and relkind in('r','v','m','S','p','f')),
 'policies',(select md5(string_agg(tablename||':'||policyname||':'||permissive||':'||roles::text||':'||cmd||':'||coalesce(qual,'')||':'||coalesce(with_check,''),E'\\n'order by tablename,policyname))from pg_policies where schemaname='public'),
 'other_comments',(select md5(string_agg(classoid::regclass||':'||objoid||':'||objsubid||':'||description,E'\\n'order by classoid::regclass::text,objoid,objsubid))from pg_description where not(classoid='pg_proc'::regclass and objoid in(select oid from kie))and not(classoid='pg_class'::regclass and objoid='public.property_video_jobs'::regclass and objsubid=coalesce((select attnum from col),-1))),
 'identity_comment',(select obj_description(oid,'pg_proc')from kie),
 'profile_default',(select column_default from information_schema.columns where table_schema='public'and table_name='property_video_jobs'and column_name='quality_profile'),
 'config',(select md5(string_agg(to_jsonb(t)::text,E'\\n'order by key))from app_config t),
 'other_routes',(select md5(string_agg(to_jsonb(t)::text,E'\\n'order by id))from ai_routes t where id<>'ROUTE'),
 'kie_route',(select to_jsonb(t)-'created_at'-'updated_at'from ai_routes t where id='ROUTE'),
 'jobs',(select count(*)from property_video_jobs),
 'submit_refusal',(select md5(prosrc)from pg_proc where oid='public.property_video_submit_refusal(uuid,uuid)'::regprocedure));""".replace('TARGETS',TARGETS).replace('SIGS',SIGS).replace('ROUTE',ROUTE)
def catalog(name):return json.loads(scalar(name,CATALOG))
# Everything the operator scripts must never touch: saved jobs/sources, refusals,
# receipts/holds/ledger/allowances, every other route and every other config key.
md5_rows=lambda table,where='true':f"(select md5(coalesce(string_agg(to_jsonb(t)::text,E'\\n'order by to_jsonb(t)::text),''))from {table} t where {where})"
UNTOUCHED="jsonb_build_object("+','.join(f"'{k}',{v}"for k,v in{
 'jobs':md5_rows('property_video_jobs'),'job_sources':md5_rows('property_video_job_sources'),'refused_operations':md5_rows('property_video_refused_operations'),
 'reservations':md5_rows('app_video_cost_reservations'),'ledger':md5_rows('cost_ledger'),'allowance_receipts':md5_rows('app_video_allowance_receipts'),
 'other_routes':md5_rows('ai_routes',f"id<>'{ROUTE}'"),'other_config':md5_rows('app_config',f"key not in('property_video_quality','{RECORD_KEY}')"),'job_count':'(select count(*)from property_video_jobs)'}.items())+")"
OPS_STATE=f"select jsonb_build_object('config',(select value from app_config where key='property_video_quality'),'config_present',exists(select 1 from app_config where key='property_video_quality'),'record',(select value from app_config where key='{RECORD_KEY}'),'enabled',(select enabled from ai_routes where id='{ROUTE}'),'row',(select to_jsonb(t)-'enabled'-'updated_at'from ai_routes t where id='{ROUTE}'),'untouched',{UNTOUCHED})"
def ops_state(name):return json.loads(scalar(name,OPS_STATE))

base=BASE.read_text();seed=base[base.index('insert into auth.users'):base.index('select pg_temp.ok((select bool_and')];helpers=base[base.index('create function pg_temp.paid_clip'):base.index('insert into auth.users')]
IDENTITY_TEXT=IDENTITY.read_text();IDENTITY_JSON=json.loads(IDENTITY_TEXT);assert'$kie_identity$'not in IDENTITY_TEXT
IDENTITY_SQL='$kie_identity$'+IDENTITY_TEXT+'$kie_identity$::jsonb'
# The Deno PG fixture is the exact `psql -At` text of PG_FIXTURE_QUERY on this
# schema (route seeded OFF) with only the two row timestamps normalised. The
# driver compares it byte for byte (fresh, replay, later schema) and hands it to
# the SQL fixture as kie_pg_fixture(t, identity): t is the whole text, identity
# the exact quality_identity text inside it.
PG_FIXTURE_QUERY=f"select json_build_object('quality_identity', public.property_video_quality_identity('{PROFILE}'), 'pinned_route', (select to_jsonb(r) from public.ai_routes r where r.id='{ROUTE}'))::text;"
PG_STAMP=re.compile(r'"(created_at|updated_at)": "[^"]*"')
pg_normalise=lambda text:PG_STAMP.sub(lambda m:'"%s": "2026-10-16T00:00:00+00:00"'%m.group(1),text)
PG_FIXTURE_BYTES=PG_FIXTURE.read_bytes();PG_FIXTURE_TEXT=PG_FIXTURE_BYTES.decode('utf-8')
PG_PREFIX='{"quality_identity" : ';PG_SEP=', "pinned_route" : '
assert PG_FIXTURE_TEXT.startswith(PG_PREFIX)and PG_FIXTURE_TEXT.count(PG_SEP)==1 and PG_FIXTURE_TEXT.endswith('}\n')and pg_normalise(PG_FIXTURE_TEXT)==PG_FIXTURE_TEXT,'Deno PG fixture shape'
PG_FIXTURE_IDENTITY=PG_FIXTURE_TEXT[len(PG_PREFIX):PG_FIXTURE_TEXT.index(PG_SEP)]
assert json.loads(PG_FIXTURE_IDENTITY)==IDENTITY_JSON,'the Deno PG fixture identity is not the canonical identity JSON'
assert json.loads(PG_FIXTURE_TEXT)['pinned_route']['id']==ROUTE and json.loads(PG_FIXTURE_TEXT)['pinned_route']['enabled']is False,'the Deno PG fixture route is not the seeded pinned row'
PG_TAG='$kie_pg_fixture$'
def kie_fixture(text=PG_FIXTURE_TEXT,identity=PG_FIXTURE_IDENTITY):
 assert PG_TAG not in text+identity
 return('begin;\n'+seed+'\n'+helpers+'\ncreate temporary table kie_identity_file as select '+IDENTITY_SQL+' j;grant select on kie_identity_file to service_role;\n'
  +'create temporary table kie_pg_fixture as select '+PG_TAG+text+PG_TAG+'::text t,'+PG_TAG+identity+PG_TAG+'::text identity;grant select on kie_pg_fixture to service_role;\n'+FIX.read_text())
fixture=kie_fixture()
# After the consent migration, explicit synthetic customer permission must go
# through the actual v2 RPC. Non-Kie calls/replays retain their original API.
LATER_ADMIT_HELPER="""create function pg_temp.profile_admit(a uuid,m jsonb,q numeric,p text default'legacy')returns jsonb language plpgsql as $$begin
 if p='kie-kling3-4k-steady-v1'then return public.property_video_job_admit_v2(a,m,q,p,'"""+PERMISSION+"""'::jsonb,null);end if;
 return public.property_video_job_admit(a,m,q,p);end$$;
"""
later_text=FIX.read_text().replace('public.property_video_job_admit((select','pg_temp.profile_admit((select').replace('property_video_job_admit((select','pg_temp.profile_admit((select')
# The historical fixture pins four profiles. The later aerial/photo-motion
# migration deliberately expands this constraint to seven; pin that exact
# final list when replaying the same Kie behavior on the final schema.
boundary_profiles="'legacy'::text, 'fal-kling3-4k-v1'::text, 'fal-kling3-4k-steady-v2'::text, 'kie-kling3-4k-steady-v1'::text"
final_profiles=boundary_profiles+", 'photo-motion-v1-cfr24'::text, 'photo-motion-v2-cfr24'::text, 'photo-motion-v2-opening-cfr24'::text"
assert later_text.count(boundary_profiles)==1
later_text=later_text.replace(boundary_profiles,final_profiles,1).replace('saved profile constraint admits exactly four profiles','saved profile constraint admits exactly seven final profiles',1)
# The direct INSERT identity-spoof control is an internal trigger test, with
# explicit permission scoped only around that exact synthetic insert.
insert_context="select set_config('rendprop.property_video_quality_profile','kie-kling3-4k-steady-v1',true);"
assert later_text.count(insert_context)==1
later_text=later_text.replace(insert_context,"select set_config('rendprop.property_video_consent','"+PERMISSION+"',true);\n"+insert_context,1)
clear_context="select set_config('rendprop.property_video_quality_profile','',true);"
assert later_text.count(clear_context)==1
later_text=later_text.replace(clear_context,clear_context+"\nselect set_config('rendprop.property_video_consent','',true);",1)
later_fixture=fixture[:-len(FIX.read_text())]+PUBLISHED_CONSENT+LATER_ADMIT_HELPER+later_text

def pg_fixture_live(name):return pg_normalise(run(name,[*PSQL,'-Atq','-c',PG_FIXTURE_QUERY])).encode('utf-8')
steady_fixture='begin;\n'+seed+'\n'+helpers+'\n'+STEADY.read_text()
v1_fixture='begin;\n'+seed+'\n'+V1.read_text()
drift=f"update ai_routes set unit_cents=33.6 where id='{ROUTE}';";undrift=f"update ai_routes set unit_cents=33.5 where id='{ROUTE}';"
try:
 run('initdb',[tool('initdb'),'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[tool('pg_ctl'),'-D',DATA,'-l',OUT/'postgres.log','-w','-o',f"-k {SOCK} -p {PORT} -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 conn=['-h',SOCK,'-p',PORT,'-U','postgres'];run('createdb',[tool('createdb'),*conn,'kie_profile'])
 PSQL=[tool('psql'),'-X','--no-password',*conn,'-d','kie_profile','-v','ON_ERROR_STOP=1']
 assert scalar('owned-cluster-identity',"select current_setting('data_directory'),current_setting('listen_addresses')")==str(DATA)+'|'
 run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for m in OWN:
  if m==MIG:before=catalog('before-own-boundary')
  run('apply-'+m.stem,[*PSQL,'-q','-1','-f',m])
  if m==MIG:after=catalog('after-own-boundary')
 # Nothing unrelated changed: other functions (incl. bodies), constraints,
 # columns, triggers, indexes, grants/RLS, policies, comments, config, routes.
 for key in['target_metadata','other_functions','other_constraints','other_columns','triggers','indexes','relations','policies','other_comments','profile_default','config','other_routes','jobs','submit_refusal']:
  assert before[key]==after[key],('unrelated drift',key,before[key],after[key])
 # The FAL-only unaccepted-submission recovery is not touched by the Kie profile
 # (its exact installed body; the Kie capacity pause in the fixture never matches it).
 assert after['submit_refusal']=='86d81ed9057049780f6fb2d53618304a',('property_video_submit_refusal body',after['submit_refusal'])
 # The only intended deltas, each exact.
 assert all(before['target_bodies'][s]==PAIRS[s][0]and after['target_bodies'][s]==PAIRS[s][1]for s in SIGNATURES),('md5 anchors',before['target_bodies'],after['target_bodies'])
 owner=after['target_metadata']['property_video_job_admit(uuid,jsonb,numeric,text)']['owner']
 assert before['identity_function']is None and{k:v for k,v in after['identity_function'].items()if k!='body'}=={'signature':'property_video_quality_identity(text)','owner':owner,'prosecdef':False,'provolatile':'i','proconfig':['search_path=""'],'acl':'{%s=X/%s,service_role=X/%s}'%(owner,owner,owner),'lang':'sql','result':'jsonb'},after['identity_function']
 assert before['identity_comment']is None and'property-video-kie-identity.json'in after['identity_comment']
 assert before['profile_constraint']=="CHECK ((quality_profile = ANY (ARRAY['legacy'::text, 'fal-kling3-4k-v1'::text, 'fal-kling3-4k-steady-v2'::text])))"
 assert after['profile_constraint']=="CHECK ((quality_profile = ANY (ARRAY['legacy'::text, 'fal-kling3-4k-v1'::text, 'fal-kling3-4k-steady-v2'::text, 'kie-kling3-4k-steady-v1'::text])))"
 assert before['identity_column']is None and{k:v for k,v in after['identity_column'].items()if k!='comment'}=={'type':'jsonb','notnull':False,'hasdef':False,'last':True}and after['identity_column']['comment']
 # AI-router contract section 3: the reseller row is seeded OFF; only the
 # owner-approved activation (KIE-ACTIVATION.sql) enables it.
 note=after['kie_route'].pop('note');assert before['kie_route']is None and PROFILE in note and'OFF until the owner-approved activation'in note and'KIE-ACTIVATION.sql'in note,note
 assert after['kie_route']=={'id':ROUTE,'task':'video.property_reel_clip_kie','position':1,'provider':'kie','model':'kling-3.0/video','unit':'second','unit_cents':33.5,'capabilities':['i2v','1080p','5s','native4k','preserve_photo'],
  'max_latency_s':1800,'min_plan':'free','same_model_as':'kling_3_pro','privacy_tier':'trains_by_default','enabled':False,'retire_after':None,'params':{'kie_mode':'4K','sound':False}},after['kie_route']
 after['kie_route']['note']=note
 r['migrationAnchors']={s:{'before':PAIRS[s][0],'after':PAIRS[s][1]}for s in SIGNATURES};r['boundaryPreservation']={'unchanged':before|{'target_bodies':None,'identity_function':None,'identity_column':None,'kie_route':None,'profile_constraint':None,'identity_comment':None},'after':after};r['migrationCount']=len(partition_fresh_migrations(MIGRATIONS)[0]);r['laterMigrations']=[m.name for m in LATER]
 # SQL identity == the canonical JSON file the TypeScript runtime imports.
 assert scalar('identity-equals-file',f"select property_video_quality_identity('{PROFILE}')={IDENTITY_SQL} and property_video_quality_identity('{PROFILE}')::text=({IDENTITY_SQL})::text")=='t'
 assert json.loads(scalar('identity-json',f"select property_video_quality_identity('{PROFILE}')"))==IDENTITY_JSON
 assert scalar('identity-null-for-fal',"select property_video_quality_identity('legacy')is null and property_video_quality_identity('fal-kling3-4k-v1')is null and property_video_quality_identity('fal-kling3-4k-steady-v2')is null")=='t'
 r['identityFile']={'path':str(IDENTITY.relative_to(ROOT)),'sha256':hashlib.sha256(IDENTITY_TEXT.encode()).hexdigest(),'sqlEqualsFile':True}
 # Exercise historical FAL/legacy proofs at the Kie migration boundary. The
 # current jobs fixture asserts final trial limits and runs after LATER only.
 def regressions(prefix='',final_schema=False):
  checks={'v1-quality-profile':result_line(run(prefix+'regression-v1-quality-profile',[*PSQL,'-Atq'],v1_fixture)),
   'steady-v2':result_line(run(prefix+'regression-steady-v2',[*PSQL,'-Atq'],steady_fixture))}
  if final_schema:
   checks['property-video-jobs']=result_line(run(prefix+'regression-property-video-jobs',[*PSQL,'-Atq','-f',BASE]))
  return checks
 r['regressions']=regressions()
 r['regressionScope']={'kieMigrationBoundary':list(r['regressions']),'finalSchemaAfterLaterMigrations':['v1-quality-profile','steady-v2','property-video-jobs']}
 for stage in['fresh','replay']:
  if stage=='replay':
   run('replay-own-migration',[*PSQL,'-q','-1','-f',MIG])
   assert catalog('own-replay-boundary')==after,'second application is not a no-op'
  # The Deno PG fixture is byte for byte what this schema returns.
  assert pg_fixture_live(stage+'-deno-pg-fixture')==PG_FIXTURE_BYTES,(stage,'the Deno PG fixture differs from the live identity and pinned route')
  r['pgFixture']['stages'][stage]=True
  r[stage]=result_line(run(stage+'-kie-profile',[*PSQL,'-Atq'],fixture))
 # Replay after activation: the post-insert verification accepts either value of
 # enabled (activation flips only that) and still pins every other field.
 run('activate-row-for-replay',[*PSQL,'-Atq','-c',f"update ai_routes set enabled=true where id='{ROUTE}'"])
 run('replay-own-migration-row-enabled',[*PSQL,'-q','-1','-f',MIG])
 assert scalar('row-enabled-after-replay',f"select enabled from ai_routes where id='{ROUTE}'")=='t'
 run('drift-for-replay',[*PSQL,'-Atq','-c',drift])
 run('replay-own-migration-drifted-row',[*PSQL,'-q','-1','-f',MIG],refuses='Review changed pinned Kie property-video route')
 run('undrift-after-replay',[*PSQL,'-Atq','-c',undrift+f"update ai_routes set enabled=false where id='{ROUTE}';"])
 assert catalog('after-activated-replays')==after,'replay checks were not fully restored'
 r['replayAfterActivation']={'rowEnabledReplayPasses':True,'enabledPreserved':True,'driftedIdentityReplayRefused':True}
 # Compiled negative controls: mutate the INSTALLED body, prove the fixture
 # fails with the specific assertion, restore, and re-verify the exact md5.
 KIE_CONTROLS=[
  ('missing-acknowledgement','public.property_video_quality_profile()',"and c->'vendor_content_license'=public.property_video_quality_identity('kie-kling3-4k-steady-v1')->'content_license_ack'",'','Kie without acknowledgement is unavailable'),
  # With the pinned row seeded OFF, the first admission that only the route
  # check refuses is the acknowledged-selector-alone state.
  ('missing-route-identity','public.property_video_job_admit(uuid,jsonb,numeric,text)',"if not found then raise exception'RP409: The Kie property-video route changed before admission';end if;",'null;','acknowledged config alone cannot admit while the pinned row is OFF'),
  ('route-enabled-ignored','public.property_video_job_admit(uuid,jsonb,numeric,text)',"and route.enabled and",'and','acknowledged config alone cannot admit while the pinned row is OFF'),
  ('missing-167.5-minimum','public.property_video_job_admit(uuid,jsonb,numeric,text)',"if p_quality_profile='kie-kling3-4k-steady-v1'and(p_quote is null or p_quote<167.5*jsonb_array_length(p_manifest->'sources'))then raise exception'RP400: The property-video quality quote is incomplete';end if;",'null;','quote below 167.5 per source refuses'),
  ('weakened-167.5-minimum','public.property_video_job_admit(uuid,jsonb,numeric,text)',"p_quote<167.5*jsonb_array_length",'p_quote<167.4999*jsonb_array_length','quote below 167.5 per source refuses'),
  ('identity-not-frozen-at-insert','public.property_video_quality_freeze()',"new.quality_identity:=public.property_video_quality_identity(quoted);",'','Kie admission freezes exact canonical identity'),
  ('identity-mutable-on-update','public.property_video_quality_freeze()',"if new.quality_identity::text is distinct from old.quality_identity::text then raise exception'RP409: A saved video quality identity is immutable';end if;",'','saved Kie identity cannot be changed'),
  ('kie-default-deadline','public.property_video_quality_freeze()',"if quoted='kie-kling3-4k-steady-v1'then new.deadline:=new.created_at+interval'24 hours';end if;",'','Kie bounded 24h deadline'),
  ('kie-audio-30fps','public.property_video_job_audio_preflight(uuid,uuid,text,text,numeric,integer)',"if j.quality_profile='kie-kling3-4k-steady-v1'then output_fps:=24;end if;",'','Kie dissolve exact6frames24fps admits'),
  ('missing-kie-delivery-projection','public.background_video_delivery(uuid,uuid,uuid,text,bigint)',"||case when j.quality_profile='kie-kling3-4k-steady-v1'then jsonb_build_object('quality_profile',j.quality_profile)else'{}'::jsonb end",'','ready Kie master projects frozen profile'),
  ('missing-kie-paid-eligibility','public.paid_quality_processing_budget(uuid)',"or(v->>'profile'='kie-kling3-4k-steady-v1'and v->'vendor_content_license'=public.property_video_quality_identity('kie-kling3-4k-steady-v1')->'content_license_ack')",'','acknowledged Kie recognizes same ordinary paid policy'),
  ('unacknowledged-kie-paid-eligibility','public.paid_quality_processing_budget(uuid)',"'kie-kling3-4k-steady-v1'and v->'vendor_content_license'=public.property_video_quality_identity('kie-kling3-4k-steady-v1')->'content_license_ack')","'kie-kling3-4k-steady-v1')",'unacknowledged Kie does not unlock paid processing')]
 # The steady-v2 compiled controls, re-run on the Kie-patched bodies: its exact
 # anchors are preserved and every unsafe v2 mutation is still detected.
 STEADY_CONTROLS=[
  ('immutable-saved-profile','public.property_video_quality_freeze()',"if new.quality_profile is distinct from old.quality_profile",'if false','saved profile cannot be changed'),
  ('bounded-v2-deadline','public.property_video_quality_freeze()',"if quoted in('fal-kling3-4k-v1','fal-kling3-4k-steady-v2')then new.deadline","if quoted='fal-kling3-4k-v1'then new.deadline",'new profile bounded24h deadline'),
  ('complete-v2-price','public.property_video_job_admit(uuid,jsonb,numeric,text)',"if p_quality_profile in('fal-kling3-4k-v1','fal-kling3-4k-steady-v2')and(","if p_quality_profile='fal-kling3-4k-v1'and(",'underpriced profile refuses before capacity'),
  ('context-leak','public.property_video_job_admit(uuid,jsonb,numeric,text)',"perform set_config('rendprop.property_video_quality_profile',coalesce(prior,''),true);",'null;','admission context restored cannot leak to later direct enqueue'),
  ('narration-old-fps','public.property_video_job_audio_preflight(uuid,uuid,text,text,numeric,integer)',"output_fps:=case when j.quality_profile='fal-kling3-4k-steady-v2'then 24 else 30 end;","output_fps:=30;",'v2 dissolve exact6frames24fps admits'),
  ('narration-v1-overwrite','public.property_video_job_audio_preflight(uuid,uuid,text,text,numeric,integer)',"output_fps:=case when j.quality_profile='fal-kling3-4k-steady-v2'then 24 else 30 end;","output_fps:=24;",'v1 still uses8frames30fps'),
  ('missing-delivery-profile','public.background_video_delivery(uuid,uuid,uuid,text,bigint)',"case when j.quality_profile='fal-kling3-4k-steady-v2'then jsonb_build_object","case when false then jsonb_build_object",'only authoritative v2 registered master projects frozen profile'),
  ('missing-paid-v2-eligibility','public.paid_quality_processing_budget(uuid)',"v->>'profile'in('fal-kling3-4k-v1','fal-kling3-4k-steady-v2')","v->>'profile'='fal-kling3-4k-v1'",'v2 recognizes same ordinary paid policy')]
 def control(kind,label,signature,anchor,replacement,oracle,body):
  original=run(f'read-{kind}-{label}',[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%signature]);assert original.count(anchor)==1,(label,'source anchor')
  run(f'compile-{kind}-{label}',[*PSQL,'-Atq'],original.replace(anchor,replacement,1))
  run(f'negative-{kind}-{label}',[*PSQL,'-Atq'],body,refuses=oracle)
  run(f'restore-{kind}-{label}',[*PSQL,'-Atq'],original)
  assert scalar(f'restored-{kind}-{label}',"select md5(prosrc)from pg_proc where oid='%s'::regprocedure"%signature)==PAIRS[signature][1]
  return{'name':label,'function':signature,'oracle':oracle,'compiledActualSQL':True,'unsafeMutationDetected':True,'restoredExactMd5':True}
 for c in KIE_CONTROLS:r['controls'].append(control('kie',*c,fixture))
 for c in STEADY_CONTROLS:r['steadyControls'].append(control('steady',*c,steady_fixture))
 # The Deno PG fixture proof is live: one changed identity value in the fixture
 # text, in the expected job identity, or in the INSTALLED identity function
 # fails it with its own assertion; the function is then restored exactly.
 PG_ORACLE='live identity and pinned route equal the Deno PG fixture byte for byte';PG_JOB_ORACLE='admitted Kie job identity text equals the Deno PG fixture identity'
 drifted_identity=PG_FIXTURE_IDENTITY.replace('"min_short_side_px": 2160','"min_short_side_px": 1080',1);assert PG_FIXTURE_IDENTITY.count('"min_short_side_px": 2160')==1 and drifted_identity!=PG_FIXTURE_IDENTITY
 drifted_text=PG_PREFIX+drifted_identity+PG_FIXTURE_TEXT[PG_FIXTURE_TEXT.index(PG_SEP):]
 assert pg_fixture_live('pg-fixture-control-baseline')==PG_FIXTURE_BYTES and drifted_text.encode('utf-8')!=PG_FIXTURE_BYTES
 run('negative-pg-fixture-file-identity-drift',[*PSQL,'-Atq'],kie_fixture(drifted_text,drifted_identity),refuses=PG_ORACLE)
 run('negative-pg-fixture-job-identity-drift',[*PSQL,'-Atq'],kie_fixture(PG_FIXTURE_TEXT,drifted_identity),refuses=PG_JOB_ORACLE)
 identity_signature='public.property_video_quality_identity(text)'
 identity_original=run('read-pg-fixture-identity',[*PSQL,'-Atq','-c',f"select pg_get_functiondef('{identity_signature}'::regprocedure)"]);assert identity_original.count('"min_short_side_px":2160')==1
 identity_md5=scalar('md5-pg-fixture-identity',f"select md5(prosrc)from pg_proc where oid='{identity_signature}'::regprocedure")
 run('compile-pg-fixture-live-identity-drift',[*PSQL,'-Atq'],identity_original.replace('"min_short_side_px":2160','"min_short_side_px":1080',1))
 assert pg_fixture_live('pg-fixture-live-identity-drift')==drifted_text.encode('utf-8'),'one changed live identity value is exactly one changed fixture value'
 run('negative-pg-fixture-live-identity-drift',[*PSQL,'-Atq'],fixture,refuses=PG_ORACLE)
 run('restore-pg-fixture-identity',[*PSQL,'-Atq'],identity_original)
 assert scalar('restored-pg-fixture-identity',f"select md5(prosrc)from pg_proc where oid='{identity_signature}'::regprocedure")==identity_md5 and pg_fixture_live('pg-fixture-restored')==PG_FIXTURE_BYTES
 r['pgFixture']['controls']=[{'name':'fixture-identity-value-changed','oracle':PG_ORACLE,'detected':True},{'name':'expected-job-identity-value-changed','oracle':PG_JOB_ORACLE,'detected':True},
  {'name':'installed-identity-value-changed','oracle':PG_ORACLE,'liveTextEqualsDriftedFixture':True,'compiledActualSQL':True,'restoredExactMd5':True}]
 assert catalog('after-controls')==after,'a compiled control was not fully restored'
 for m in LATER:run('apply-'+m.stem,[*PSQL,'-q','-1','-f',m])
 if LATER:
  final_catalog=catalog('after-later-schema')
  assert final_catalog['target_bodies']==OPERATOR_FINAL_PINS,'operational verifier pins must match deliberate final bodies'
  assert final_catalog['target_metadata']==after['target_metadata'],'later migrations changed Kie target owner/ACL/configuration or function metadata'
  assert final_catalog['kie_route']==after['kie_route'],'later migrations changed the pinned Kie route'
  assert json.loads(scalar('after-later-selector',"select value from app_config where key='property_video_quality'"))=={'enabled':False,'profile':'fal-kling3-4k-v1'},'later migrations changed the inactive selector'
  r['operatorPinAudit']={'historicalKieBoundary':{k:v[1]for k,v in PAIRS.items()},'historicalScopeBoundary':FINAL_PINS,'currentSchema':OPERATOR_FINAL_PINS,'targetMetadataPreserved':True,'kieRouteOff':True,'selectorOff':True}
  assert pg_fixture_live('later-schema-deno-pg-fixture')==PG_FIXTURE_BYTES,'the Deno PG fixture differs from the later schema';r['pgFixture']['stages']['later']=True
  consent_probe_paid=FIX.read_text()[FIX.read_text().index("reset role;update app_config set value='{\"mode\":\"ceiling\",\"free_published_listings\":1}'where key='serving_mode';"):FIX.read_text().index('select pg_temp.ok(not org_has_internal_testing_grant')]
  no_consent='begin;'+seed+consent_probe_paid+"update app_config set value=jsonb_set(value,'{enabled}','true')where key='property_video_jobs';"+f"update ai_routes set enabled=true where id='{ROUTE}';update app_config set value='{KIE_ON}'where key='property_video_quality';set local role service_role;"+f"select property_video_job_admit('{ACTOR}',(select jsonb_set(jsonb_set(jsonb_set(m,'{{operation_id}}','\"f6a00000-0000-4000-8000-000000009999\"'),'{{sources}}',(select jsonb_agg(value order by ord)from jsonb_array_elements(m->'sources')with ordinality e(value,ord)where ord<=2)),'{{presentation,shot_labels}}','[null,null]')from bm),335,'{PROFILE}');"
  run('later-schema-legacy-without-consent-refuses',[*PSQL,'-Atq'],no_consent,refuses='RP403: Allow the listed AI processors')
  r['laterSchema']={'legacyNoConsentRefused':True,'kie':result_line(run('later-schema-kie-profile',[*PSQL,'-Atq'],later_fixture)),'regressions':regressions('later-',final_schema=True)}
  assert scalar('later-schema-prompt-registry',"select public.property_video_prompt_identity('v1')=public.property_video_quality_identity('kie-kling3-4k-steady-v1') and public.property_video_prompt_identity_registered(public.property_video_prompt_identity('v1')) and public.property_video_prompt_identity_registered(public.property_video_prompt_identity('v2')) and not public.property_video_prompt_identity_registered(jsonb_set(public.property_video_prompt_identity('v2'),'{prompt_template_sha256,push_in}',to_jsonb('unregistered'::text))) and not public.property_video_prompt_identity_registered('{}'::jsonb) and public.property_video_prompt_identity('unknown')is null")=='t','stale or unregistered Kie prompt identity was accepted'
  r['laterSchema']['promptIdentityRegistry']={'v1AndV2Exact':True,'staleAndUnknownRejected':True}

 r['pgFixture'].update({'path':str(PG_FIXTURE.relative_to(ROOT)),'sha256':hashlib.sha256(PG_FIXTURE_BYTES).hexdigest(),'query':PG_FIXTURE_QUERY,'normalised':'"(created_at|updated_at)": "[^"]*" -> 2026-10-16T00:00:00+00:00','bytesEqual':True})
 functions_before_races=catalog('functions-before-races')

 # Committed owner fixture (same closed Starter receipt) for the operator
 # scripts and the races. The pinned row is still OFF here (fresh migration).
 paid=f"set role service_role;select apply_apple_entitlement_v2((select org from bf),(select actor from bf),'race-kie-original','race-kie-transaction','com.rendprop.app.starter.monthly','starter','Production','active',now()+interval'29 days',true,'DID_RENEW',now()-interval'1 day',now()-interval'30 seconds',now()-interval'30 seconds',now()-interval'30 seconds');reset role;"
 release_seed_grant="update public.orgs set plan='free',plan_source=null,plan_expires_at=null where id=(select org from bf);"
 setup='begin;'+seed+release_seed_grant+paid+PUBLISHED_CONSENT+"update app_config set value=jsonb_set(value,'{enabled}','true')where key='property_video_jobs';create table public.kie_profile_race_fixture as select jsonb_set(jsonb_set(m,'{sources}',jsonb_build_array(m#>'{sources,0}',m#>'{sources,1}')),'{presentation,shot_labels}','[null,null]')m from bm;grant select on public.kie_profile_race_fixture to service_role;commit;"
 run('race-seed',[*PSQL,'-Atq'],setup)
 op=lambda i:'f6c00000-0000-4000-8000-%012d'%i
 def admit(i,profile=PROFILE,quote=335):
  manifest=f"jsonb_set((select m from kie_profile_race_fixture),'{{operation_id}}',to_jsonb('{op(i)}'::text))"
  return f"select property_video_job_admit_v2('{ACTOR}',{manifest},{quote},'{profile}','{PERMISSION}'::jsonb,null);"if profile==PROFILE else f"select property_video_job_admit('{ACTOR}',{manifest},{quote},'{profile}');"

 def job(i):return scalar(f'job-{i}',f"select coalesce((select jsonb_build_object('profile',quality_profile,'identity',quality_identity)::text from property_video_jobs where operation_id='{op(i)}'),'none')")
 cutover=f"update app_config set value='{FAL_V2}'where key='property_video_quality';";restore_kie=f"update app_config set value='{KIE_ON}'where key='property_video_quality';"
 frozen=lambda i:json.loads(job(i))=={'profile':PROFILE,'identity':IDENTITY_JSON}

 # Owner-approved operator scripts, run exactly as documented:
 #   psql -X -v ON_ERROR_STOP=1 -1 -v processor_disclosure=<id> -f docs/handoff/KIE-ACTIVATION.sql
 #   psql -X -v ON_ERROR_STOP=1 -1 <three fresh CAS values> [-v emergency_stop=on] -f docs/handoff/KIE-ROLLBACK.sql
 #   psql -X -v ON_ERROR_STOP=1 -1 <fresh selector/route CAS> -f docs/handoff/KIE-ROUTE-OFF.sql
 #   psql -X -v ON_ERROR_STOP=1 -f docs/handoff/KIE-READONLY-VERIFY.sql
 # Activation saves the exact previous selector (or its absence) with the
 # processor-disclosure attestation in app_config.property_video_quality_kie_activation.
 # The DEFAULT rollback restores exactly that value (never a default) and leaves
 # the pinned row ON for admitted Kie work; EMERGENCY also switches it OFF.
 MARK='KIE-ACTIVATION previous property_video_quality: '
 PRIOR='{"enabled": true, "profile": "fal-kling3-4k-steady-v2"}'  # a real pre-Kie selector, deliberately NOT the migration default
 FAL_V1_ON='{"enabled": true, "profile": "fal-kling3-4k-v1"}';FAL_V1_OFF={'enabled':False,'profile':'fal-kling3-4k-v1'}
 REQUIRED='KIE-ACTIVATION refused: -v processor_disclosure=... is required';MALFORMED='KIE-ACTIVATION refused: processor_disclosure must be 1 to 200 visible ASCII characters'
 AMBIGUOUS='KIE-ROLLBACK refused: -v previous was removed';NO_RECORD='not a current, well-formed KIE-ACTIVATION.sql record';NOTHING='KIE-ROLLBACK refused: nothing to roll back'
 psql_db=lambda db:[tool('psql'),'-X','--no-password',*conn,'-d',db,'-v','ON_ERROR_STOP=1']
 def operator_cas(name,db='kie_profile'):
  q=f"select jsonb_build_object('expected_selector_sha256',coalesce((select encode(sha256(convert_to(value::text,'UTF8')),'hex')from app_config where key='property_video_quality'),'absent'),'expected_route_enabled',(select enabled::text from ai_routes where id='{ROUTE}'),'expected_record_sha256',coalesce((select encode(sha256(convert_to(value::text,'UTF8')),'hex')from app_config where key='{RECORD_KEY}'),'absent'));"
  return json.loads(run(name+'-fresh-cas',[*psql_db(db),'-Atq','-c',q]).strip())
 def cas_args(values):return[arg for key,value in values.items()if value is not None for arg in ['-v',key+'='+value]]
 def activation(name,refuses=None,db='kie_profile',disclosure=DISCLOSURE,script=ACTIVATION,baselines=None):
  values=operator_cas(name,db)if baselines is None else baselines
  return run(name,[*psql_db(db),'-1',*cas_args(values),*(['-v','processor_disclosure='+disclosure]if disclosure is not None else[]),'-f',script],refuses=refuses)
 def rollback(name,previous=None,refuses=None,emergency=None,db='kie_profile',script=ROLLBACK,baselines=None):
  values=operator_cas(name,db)if baselines is None else baselines
  return run(name,[*psql_db(db),'-1',*cas_args(values),*(['-v','previous='+previous]if previous is not None else[]),*(['-v','emergency_stop='+emergency]if emergency is not None else[]),'-f',script],refuses=refuses)
 def route_off(name,refuses=None,db='kie_profile',script=ROUTE_OFF,baselines=None):
  values=operator_cas(name,db)if baselines is None else baselines
  values={k:v for k,v in values.items()if k!='expected_record_sha256'}
  return run(name,[*psql_db(db),'-1',*cas_args(values),'-f',script],refuses=refuses)
 def printed(out):
  values=[line.split(MARK,1)[1].strip()for line in out.splitlines()if MARK in line];assert len(values)==1,out;return values[0]
 def scalar_db(name,db,query):return run(name,[*psql_db(db),'-Atq','-c',query]).strip()
 def state_of(name,db='kie_profile'):return json.loads(scalar_db(name,db,OPS_STATE))
 def record_of(name,db='kie_profile'):return json.loads(scalar_db(name,db,f"select coalesce((select value from app_config where key='{RECORD_KEY}'),'null'::jsonb)"))
 # The activation record, exactly: every field, the attestation, the license
 # acknowledgement and the exact previous selector ({"present":false} = absent).
 RECORD_FIELDS={'profile','route_id','previous_selector','route_enabled_before','processor_disclosure','consent_disclosure_revision','vendor_content_license','activated_at','rolled_back_at','rollback_mode','route_disabled_at'}
 def expect_record(rec,previous,disclosure,before,mode=None,disabled=False):
  assert isinstance(rec,dict)and set(rec)==RECORD_FIELDS,rec
  assert rec['profile']==PROFILE and rec['route_id']==ROUTE and rec['vendor_content_license']==IDENTITY_JSON['content_license_ack']and rec['processor_disclosure']==disclosure and rec['consent_disclosure_revision']==CONSENT_REVISION and rec['route_enabled_before']is before,rec
  assert rec['previous_selector']==({'present':False}if previous is None else{'present':True,'value':previous}),rec
  assert isinstance(rec['activated_at'],str)and rec['rollback_mode']==mode and(rec['rolled_back_at']is None)==(mode is None)and(rec['route_disabled_at']is not None)==disabled,rec
  return rec
 # Every stamp is the writing transaction's now(): activation stamps the row,
 # the selector and the record together; a rollback stamps what it changed.
 STAMPS={'activated':"a.activated_at=r.updated_at and a.activated_at=c.updated_at and a.activated_at=a.row_at",
  'rolled_back':"a.rolled_back_at=a.row_at and a.rolled_back_at>a.activated_at and coalesce(c.updated_at=a.rolled_back_at,true)and a.route_disabled_at is null",
  'emergency':"a.rolled_back_at=a.row_at and a.rolled_back_at>a.activated_at and coalesce(c.updated_at=a.rolled_back_at,true)and a.route_disabled_at=a.rolled_back_at and r.updated_at=a.route_disabled_at",
  'row_off':"a.route_disabled_at=a.row_at and a.route_disabled_at=r.updated_at and a.route_disabled_at>a.rolled_back_at"}
 def stamps(name,kind,db='kie_profile'):
  assert scalar_db(name,db,f"select {STAMPS[kind]} from(select updated_at row_at,(value->>'activated_at')::timestamptz activated_at,(value->>'rolled_back_at')::timestamptz rolled_back_at,(value->>'route_disabled_at')::timestamptz route_disabled_at from app_config where key='{RECORD_KEY}')a cross join(select updated_at from ai_routes where id='{ROUTE}')r left join app_config c on c.key='property_video_quality'")=='t',(name,kind)
 # docs/handoff/KIE-READONLY-VERIFY.sql exactly as an operator runs it. Rows:
 # n|check|ok|detail (exact27 named checks and28 = all checks), then19
 # ordered item|value facts. Prior1-18 checks remain individually asserted.
 # It must change nothing; `false` names exact expected false check numbers.
 VERIFY_ITEMS=['property_video_quality','kie_route_enabled','kie_activation_record','kie_jobs_admitted','kie_jobs_draining','kie_drain_ends_by','property_video_quality_sha256','kie_activation_record_sha256','property_video_quality_hold','property_video_quality_hold_sha256','property_video_kie_test_window','property_video_kie_test_window_sha256','processor_consent_contract','kie_test_grants','kie_test_grants_can_still_create','kie_jobs_admitted_by_authority','kie_jobs_draining_by_authority','kie_unsent_clips','kie_accepted_tasks_pollable']
 VERIFY_NAMES={int(n):name.replace("''","'")for n,name in re.findall(r"select\s+(\d+), '((?:''|[^'])*)'",VERIFY.read_text())}
 VERIFY_NAMES.update({6+i:'migration: body and execution authority of '+signature+' match the final pin'for i,signature in enumerate(SIGNATURES)})
 assert sorted(VERIFY_NAMES)==list(range(1,29)),VERIFY_NAMES

 READ_ONLY_ENV={**ENV,'PGOPTIONS':ENV['PGOPTIONS']+' -c default_transaction_read_only=on'}
 def verify(name,db='kie_profile',false=(),phase=None,script=VERIFY,env=None,refuses=None,record=True):
  before=state_of('verify-before-'+name,db)
  out=run('verify-'+name,[*psql_db(db),'-AtqF','\t','-f',script],refuses=refuses,env=env)
  assert state_of('verify-after-'+name,db)==before,('the read-only verification changed state',name)
  if refuses:return out
  checks,facts={},{}
  for line in out.splitlines():
   f=line.split('\t')
   if len(f)==4 and f[0].isdigit():checks[int(f[0])]=f[1:]
   elif len(f)==2:facts[f[0]]=f[1]
  assert sorted(checks)==list(range(1,29))and all(v[1]in('t','f')and v[0]==VERIFY_NAMES[n]for n,v in checks.items())and list(facts)==VERIFY_ITEMS,(name,out[-3000:])
  failed=sorted(n for n,v in checks.items()if v[1]!='t'and n!=28)
  assert failed==sorted(false)and(checks[28][1]=='t')==(not false),(name,failed,out[-3000:])
  if phase:assert checks[18][2].startswith(phase),(name,checks[18])
  result={'state':name,'falseChecks':failed,'phase':checks[18][2],'facts':facts}
  if record:r['verify'].append(result)
  return result
 # AI-router contract section 3 in tests/invariants.sql (every kie/higgsfield row
 # OFF and trains_by_default) and its ONE exception for this pinned row: ON only
 # under the exact acknowledged selector WITH the current activation record that
 # attests the processor disclosure, or while an admitted Kie job can still be
 # granted worker scope after a default rollback (selector no longer Kie). Each
 # state runs the WHOLE inventory on a disposable copy through the shared
 # inventory contract of tools/audit/run_database_regression.py (exact count,
 # numbering, exit/footer).
 RESELLER='every kie / higgsfield row is disabled and assumes trains_by_default'
 PINNED='video.property_reel_clip_kie/kie/kling-3.0/video enabled=t tier=trains_by_default'
 ACTIVATED_NOTE='pinned Kie row ON (owner-acknowledged Kie selector, recorded activation, processor disclosure '
 def copy_of(template,db):run('copy-'+db,[tool('createdb'),*conn,'-T',template,db]);return db
 def drop(db):run('drop-'+db,[tool('dropdb'),*conn,db])
 def invariants(state,db,red=None,alone=True,drop_db=True,script=INVARIANTS):
  out=run('invariants-'+state,[*psql_db(db),'-f',script],refuses='INVARIANTS FAILED: 'if red else None)
  names,failed=contract.invariant_rows(out,r['commands'][-1]['exit']);seq=names.index(RESELLER)+1
  note=next(l for l in out.splitlines()if re.match(r'\s*%d \| '%seq,l)).split(' | ',3)[3].strip()
  if red is None:assert not failed,(state,failed,note)
  else:
   # Red exactly here (alone, unless the drift is also a params-inventory drift),
   # naming exactly the expected offending rows.
   flagged=note.split('; ')
   assert RESELLER in failed and(failed==[RESELLER]or not alone)and len(flagged)==len(red)and all(sum(f.startswith(x)for f in flagged)==1 for x in red),(state,failed,note)
  if drop_db:drop(db)
  result={'state':state,'invariants':len(names),'passed':len(names)-len(failed),'failed':failed,'resellerInvariant':seq,'resellerNote':note}
  r['resellerInvariant'].append(result);return result
 def control(state,template,change,red,alone=True):
  db=copy_of(template,'inv_'+state.replace('-','_'));run('change-'+state,[*psql_db(db),'-Atq'],change);return invariants(state,db,red,alone)
 on=f"update ai_routes set enabled=true where id='{ROUTE}';";selector=lambda v:f"update app_config set value='{v}'where key='property_video_quality';"
 record_set=lambda path,value:f"update app_config set value=jsonb_set(value,'{path}','{value}')where key='{RECORD_KEY}';"
 # (a) A separately migrated fresh database: bootstrap + every migration.
 run('createdb-inv-fresh',[tool('createdb'),*conn,'inv_fresh']);run('inv-fresh-bootstrap',[*psql_db('inv_fresh'),'-q','-f',SQL/'tests/ci-bootstrap.sql'])
 for m in partition_fresh_migrations(MIGRATIONS)[0]:run('inv-fresh-apply-'+m.stem,[*psql_db('inv_fresh'),'-q','-1','-f',m])
 fresh_inv=invariants('fresh-migrated',copy_of('inv_fresh','inv_fresh_check'))
 assert fresh_inv['resellerNote']=='all reseller rows disabled + worst-case tier',fresh_inv
 # The read-only verification: its embedded expectations are the canonical JSON
 # file and the migration's own post-patch md5 pins; on the fresh database every
 # check is true; it runs inside its own READ ONLY transaction (also under
 # default_transaction_read_only), and a write placed inside it is refused.
 vtext=VERIFY.read_text();literal=re.findall(r"^ '(\{.*\})'::jsonb as identity,$",vtext,re.M)
 assert len(literal)==1 and json.loads(literal[0])==IDENTITY_JSON,'KIE-READONLY-VERIFY.sql identity differs from the canonical JSON file'
 pins=dict(re.findall(r"\(\d, '(public\.[^']+)', '([0-9a-f]{32})',",vtext));assert pins==OPERATOR_FINAL_PINS,('verify md5 pins',pins)
 reviewed=re.findall(r"^ reviewed constant jsonb:='(\{.*\})';$",ACTIVATION.read_text(),re.M)
 assert len(reviewed)==1 and json.loads(reviewed[0])==IDENTITY_JSON,'KIE-ACTIVATION.sql reviewed identity differs from the canonical JSON file'
 v=verify('fresh-migrated','inv_fresh',phase='not activated: pinned row OFF, selector pre-Kie, no activation record')
 assert json.loads(v['facts']['property_video_quality'])==FAL_V1_OFF and v['facts']['kie_route_enabled']=='false'and v['facts']['kie_activation_record']=='none'and v['facts']['kie_jobs_admitted']=='0',v
 verify('fresh-migrated-default-read-only','inv_fresh',env=READ_ONLY_ENV)
 write_anchor="set local statement_timeout = '60s';\n";begin_anchor="begin transaction isolation level repeatable read read only;\n"
 assert vtext.count(write_anchor)==1 and vtext.count(begin_anchor)==1
 write=write_anchor+"update public.app_config set updated_at=updated_at where key='ai_router';\n"
 with_write=OUT/'KIE-READONLY-VERIFY.with-write.sql';with_write.write_text(vtext.replace(write_anchor,write,1));with_write.chmod(0o600)
 verify('write-inside-is-refused','inv_fresh',script=with_write,refuses='cannot execute UPDATE in a read-only transaction')
 not_read_only=OUT/'KIE-READONLY-VERIFY.with-write-not-read-only.sql';not_read_only.write_text(vtext.replace(write_anchor,write,1).replace(begin_anchor,'begin transaction isolation level repeatable read;\n',1));not_read_only.chmod(0o600)
 run('verify-control-write-without-read-only',[*psql_db('inv_fresh'),'-AtqF','\t','-f',not_read_only])
 r['verifyControls'].append({'name':'read-only-transaction','writeInsideRefused':True,'sameWriteRunsWithoutReadOnly':True,'defaultTransactionReadOnlyRun':True})
 # Each check is live: drift exactly one thing on a disposable copy and exactly
 # that check (and "all checks") turns false.
 def verify_control(label,change,false,template='inv_fresh',phase=None):
  db=copy_of(template,'vc_'+label.replace('-','_'));run('vc-change-'+label,[*psql_db(db),'-Atq'],change)
  v=verify('control-'+label,db,false=false,phase=phase,record=False);drop(db)
  r['verifyControls'].append({'name':label,'falseChecks':v['falseChecks'],'phase':v['phase']});return v
 definition=lambda s:run('read-def-'+s.split('(')[0],[*psql_db('inv_fresh'),'-Atq','-c',f"select pg_get_functiondef('{s}'::regprocedure)"])
 profile_def=definition('public.property_video_quality_profile()');identity_def=definition('public.property_video_quality_identity(text)')
 rp503="raise exception'RP503: Property-video quality configuration is unavailable';";assert profile_def.count(rp503)==1 and identity_def.count('"min_short_side_px":2160')==1
 verify_control('identity-drift',identity_def.replace('"min_short_side_px":2160','"min_short_side_px":1080',1),[1])
 verify_control('freeze-trigger-disabled',"alter table property_video_jobs disable trigger property_video_quality_freeze;",[4])
 verify_control('patched-body-drift',profile_def.replace(rp503,rp503.replace("exception'","exception '"),1),[6])
 # The five widened operational body pins each reject a compiled change to
 # their current installed function, without changing ownership, ACL or config.
 for number,signature in enumerate(SIGNATURES[1:],start=7):
  body=definition(signature);assert body.count('AS $function$')==1,signature
  verify_control('current-body-pin-'+str(number),body.replace('AS $function$','AS $function$/* verifier compiled drift */',1),[number])
  r['verifyControls'][-1]['compiledActualSQL']=True
 verify_control('client-execute-granted','grant execute on function public.property_video_job_admit(uuid,jsonb,numeric,text)to authenticated;',[8])
 verify_control('security-definer-removed','alter function public.property_video_quality_freeze()security invoker;',[7])
 verify_control('search-path-widened','alter function public.paid_quality_processing_budget(uuid)set search_path to public;',[9])
 # Photo Motion broadened the final profile and permission constraints. Each
 # exact pin must refuse an additional profile/revision or a weakened gate.
 verify_control('profile-constraint-widened',"alter table public.property_video_jobs drop constraint property_video_quality_profile_check;alter table public.property_video_jobs add constraint property_video_quality_profile_check check(quality_profile in('legacy','fal-kling3-4k-v1','fal-kling3-4k-steady-v2','kie-kling3-4k-steady-v1','photo-motion-v1-cfr24','photo-motion-v2-cfr24','photo-motion-v2-opening-cfr24','unreviewed'));",[5])
 verify_control('consent-revision-widened',"alter table public.property_video_jobs drop constraint property_video_jobs_consent_revision_check;alter table public.property_video_jobs add constraint property_video_jobs_consent_revision_check check(consent_revision in('property-video-jobs-v1','property-video-jobs-v2','photo-motion-v1','unreviewed'));",[21])
 verify_control('processor-consent-weakened',"alter table public.property_video_jobs drop constraint property_video_jobs_processor_consent_check;alter table public.property_video_jobs add constraint property_video_jobs_processor_consent_check check(true);",[21])
 verify_control('kie-drain-predicate-widened',"drop index public.property_video_jobs_kie_drain;create index property_video_jobs_kie_drain on public.property_video_jobs(deadline)where quality_profile='kie-kling3-4k-steady-v1';",[21])
 verify_control('pinned-row-drift',f"""update ai_routes set params='{{"kie_mode":"pro","sound":false}}'where id='{ROUTE}';""",[12])
 verify_control('fal-row-price-drift',"update ai_routes set unit_cents=43 where id='b04b57c1-12c8-44f9-9c64-e06561358f01';",[14])
 verify_control('fal-row-disabled',"update ai_routes set enabled=false where id='b04b57c1-12c8-44f9-9c64-e06561358f01';",[14])
 verify_control('second-fal-property-row',"insert into ai_routes(task,position,provider,model,unit,unit_cents,capabilities,max_latency_s,min_plan,same_model_as,privacy_tier,enabled,note)select task,2,provider,model,unit,unit_cents,capabilities,max_latency_s,min_plan,same_model_as,privacy_tier,enabled,'copy'from ai_routes where id='b04b57c1-12c8-44f9-9c64-e06561358f01';",[15])
 verify_control('broken-selector',selector('{"enabled":"true","profile":"fal-kling3-4k-v1"}'),[16,18],phase='property_video_quality is not a value the operator scripts leave')
 run('publish-owned-processor-contract-for-operator-fixtures',[*psql_db('inv_fresh'),'-Atq'],PUBLISHED_CONSENT)
 # (b) The real activation script on a fresh copy with no saved job: green
 # through the owner-acknowledged selector WITH the recorded attestation.
 out=activation('inv-activation-on-fresh-copy',db=copy_of('inv_fresh','inv_activated'));assert json.loads(printed(out))==FAL_V1_OFF,out
 expect_record(record_of('inv-activated-record','inv_activated'),FAL_V1_OFF,DISCLOSURE,False);stamps('inv-activated-stamps','activated','inv_activated')
 activated_inv=invariants('activated-no-saved-job',copy_of('inv_activated','inv_activated_check'))
 assert activated_inv['resellerNote'].startswith(ACTIVATED_NOTE+DISCLOSURE+')'),activated_inv
 verify('activated-no-saved-job','inv_activated',phase='activated: pinned row ON, exact Kie selector, activation recorded ')
 verify('activated-no-saved-job-default-read-only','inv_activated',env=READ_ONLY_ENV,phase='activated: ')
 # (c) Controls: the pinned row ON without the exact acknowledged selector, or
 # without the current activation record (the selector and the row set by hand
 # are not an activation), any other reseller row ON, or the pinned row with
 # other params or a weaker tier.
 control('pinned-on-default-selector','inv_fresh',on,[PINNED])
 control('pinned-on-kie-selector-without-acknowledgement','inv_fresh',on+selector('{"enabled":true,"profile":"kie-kling3-4k-steady-v1"}'),[PINNED])
 control('pinned-on-acknowledgement-with-extra-key','inv_fresh',on+selector('{"enabled":true,"profile":"kie-kling3-4k-steady-v1","vendor_content_license":"kie-terms-2025-08-01-section-3-owner-accepted","note":"hand edit"}'),[PINNED])
 control('manual-activation-without-record','inv_fresh',on+selector(KIE_ON),[PINNED])
 verify_control('manual-activation-without-record',on+selector(KIE_ON),[18],phase='NOT ACTIVATED BY KIE-ACTIVATION.sql')
 control('activated-record-deleted','inv_activated',f"delete from app_config where key='{RECORD_KEY}';",[PINNED])
 control('activated-record-marked-rolled-back','inv_activated',record_set('{rolled_back_at}','"2026-10-16T00:00:00Z"'),[PINNED])
 control('activated-record-disclosure-with-space','inv_activated',record_set('{processor_disclosure}','"privacy policy"'),[PINNED])
 control('activated-record-disclosure-201-characters','inv_activated',record_set('{processor_disclosure}','"'+'x'*201+'"'),[PINNED])
 control('activated-record-disclosure-not-a-string','inv_activated',record_set('{processor_disclosure}','["privacy-policy"]'),[PINNED])
 control('activated-record-other-license','inv_activated',record_set('{vendor_content_license}','"kie-terms-2025-08-01-section-3"'),[PINNED])
 control('activated-record-other-route','inv_activated',record_set('{route_id}','"b04b57c1-12c8-44f9-9c64-e06561358f01"'),[PINNED])
 control('activated-selector-restored-nothing-admitted','inv_activated',selector(PRIOR),[PINNED])
 other_kie=f"(select id from ai_routes where provider='kie'and id<>'{ROUTE}'order by id limit 1)";other_higgsfield="(select id from ai_routes where provider='higgsfield'order by id limit 1)"
 for label,other in[('kie',other_kie),('higgsfield',other_higgsfield)]:
  flagged=scalar_db(f'inv-other-{label}-row','inv_activated',f"select task||'/'||provider||'/'||model||' enabled=t'from ai_routes where id={other}")
  control(f'activated-other-{label}-row-on','inv_activated',f"update ai_routes set enabled=true where id={other};",[flagged])
 control('activated-pinned-params-drift','inv_activated',f"""update ai_routes set params='{{"kie_mode":"4K","sound":true}}'where id='{ROUTE}';""",[PINNED+' params={"sound": true, "kie_mode": "4K"}'],alone=False)
 control('activated-pinned-params-null','inv_activated',f"update ai_routes set params=null where id='{ROUTE}';",[PINNED+' params=null'],alone=False)
 # The exception is the pinned id, not its content: an identical row under
 # another id stays red while the pinned row itself is ON and accepted.
 control('activated-pinned-copy-under-another-id','inv_activated',f"insert into ai_routes(task,position,provider,model,unit,unit_cents,capabilities,max_latency_s,min_plan,same_model_as,privacy_tier,enabled,params,note)select task,2,provider,model,unit,unit_cents,capabilities,max_latency_s,min_plan,same_model_as,privacy_tier,true,params,'copy of the pinned row under another id'from ai_routes where id='{ROUTE}';",[PINNED+' params={"sound": false, "kie_mode": "4K"}'],alone=False)
 control('activated-pinned-weaker-tier','inv_activated',f"update ai_routes set privacy_tier='retained_30d'where id='{ROUTE}';",['video.property_reel_clip_kie/kie/kling-3.0/video enabled=t tier=retained_30d'])
 # (d) The activation refuses a selector KIE-ROLLBACK.sql could not restore as it
 # was, and accepts a disclosure of exactly 200 visible ASCII characters.
 db=copy_of('inv_fresh','ops_bad_selector')
 for label,value in[('string-flag','{"enabled":"true","profile":"fal-kling3-4k-v1"}'),('unknown-profile','{"enabled":true,"profile":"legacy"}'),('json-null','null'),('array','[]'),('disabled-kie','{"enabled":false,"profile":"kie-kling3-4k-steady-v1"}')]:
  run('bad-selector-'+label,[*psql_db(db),'-Atq','-c',selector(value)]);before=state_of('bad-selector-before-'+label,db)
  out=activation('activation-refuses-selector-'+label,db=db,refuses='KIE-ACTIVATION refused: property_video_quality ')
  assert MARK not in out and state_of('bad-selector-after-'+label,db)==before,(label,out)
 run('bad-selector-restored',[*psql_db(db),'-Atq','-c',selector(PRIOR)])
 activation('activation-accepts-200-character-disclosure',db=db,disclosure='x'*200);expect_record(record_of('record-200',db),json.loads(PRIOR),'x'*200,False);drop(db)
 r['activationRecord'].append({'name':'activation-refuses-unrestorable-selector','refused':['string-flag','unknown-profile','json-null','array','disabled-kie'],'nothingChanged':True,'accepts200VisibleAscii':True})

 run('ops-prior-selector',[*PSQL,'-Atq','-c',f"update app_config set value='{PRIOR}'where key='property_video_quality'"])
 fal_before=one_json('ops-admit-fal-before-activation',"set role service_role;"+admit(101,'fal-kling3-4k-steady-v2',500))
 assert fal_before['accepted']and fal_before['job']['quality_profile']=='fal-kling3-4k-steady-v2'and fal_before['job']['quality_identity']is None,fal_before
 s0=ops_state('ops-state-before');assert s0['config']==json.loads(PRIOR)and s0['enabled']is False and s0['record']is None,s0
 def cas_refusals(label,db,command):
  before=state_of(label+'-state-before',db);baseline=operator_cas(label+'-baseline',db)
  for key in ['expected_selector_sha256','expected_route_enabled','expected_record_sha256']:
   missing={**baseline,key:None}
   command(label+'-missing-'+key,db=db,baselines=missing,refuses='-v '+key+'=')
   stale={**baseline,key:('false'if baseline[key]=='true'else'true')if key=='expected_route_enabled'else(('0'if baseline[key][0]!='0'else'1')+baseline[key][1:]if baseline[key]!='absent'else'0'*64)}
   command(label+'-stale-'+key,db=db,baselines=stale,refuses='not the expected baseline'if key!='expected_route_enabled'else'changed after it was read')
   assert state_of(label+'-state-after-'+key,db)==before
  r['activationRecord'].append({'name':label,'missingFieldsRefused':3,'staleFieldsRefused':3,'freshOwnedDBCAS':True,'nothingChanged':True})
 cas_refusals('activation-cas','kie_profile',activation)
 cas_refusals('rollback-cas','inv_activated',rollback)
 run('ops-kie-before-activation',[*PSQL,'-Atq'],"set role service_role;"+admit(100),refuses='RP409:');assert job(100)=='none'
 # A drifted pinned row is never activated, and the refusal changes nothing.
 run('ops-drift',[*PSQL,'-Atq','-c',drift])
 activation('ops-activation-refuses-drifted-row',refuses='KIE-ACTIVATION refused: pinned Kie route differs from the reviewed identity')
 assert scalar('ops-drift-still-off',f"select value='{PRIOR}'::jsonb and not(select enabled from ai_routes where id='{ROUTE}')from app_config where key='property_video_quality'")=='t'
 run('ops-undrift',[*PSQL,'-Atq','-c',undrift]);assert ops_state('ops-state-after-refused-drift')==s0
 # The published processor disclosure is required and bounded: missing, empty,
 # whitespace, control, non-ASCII or over-long values refuse before any lock,
 # print no previous value and change nothing.
 BAD_DISCLOSURES=[('space','privacy policy'),('leading-space',' privacy-policy'),('tab','privacy\tpolicy'),('newline','privacy\npolicy'),('carriage-return','privacy\rpolicy'),
  ('control','privacy\x01policy'),('delete','privacy\x7fpolicy'),('no-break-space','privacy policy'),('zero-width-space','privacy​policy'),('bidi-override','privacy‮policy'),
  ('non-ascii','privacy-policé'),('201-characters','x'*201)]
 for label,bad in[('missing',None),('empty','')]:
  out=activation('ops-activation-refuses-disclosure-'+label,disclosure=bad,refuses=REQUIRED);assert MARK not in out,out
 for label,bad in BAD_DISCLOSURES:
  out=activation('ops-activation-refuses-disclosure-'+label,disclosure=bad,refuses=MALFORMED);assert MARK not in out,out
 assert ops_state('ops-state-after-refused-disclosures')==s0
 r['activationRecord'].append({'name':'processor-disclosure-required-and-bounded','refused':['missing','empty',*[x for x,_ in BAD_DISCLOSURES]],'printedNoPrevious':True,'nothingChanged':True})
 # Activation: prints the previous value first, enables only the row, sets the
 # acknowledged selector and saves the exact record; jobs, receipts, other
 # routes and config untouched.
 old_activation_cas=operator_cas('ops-activation-captured');out=activation('ops-activation',baselines=old_activation_cas);previous=printed(out);assert json.loads(previous)==json.loads(PRIOR),out
 s1=ops_state('ops-state-activated')
 assert s1['config']==json.loads(KIE_ON)and s1['enabled']is True and s1['row']==s0['row']and s1['untouched']==s0['untouched'],(s0,s1)
 expect_record(s1['record'],json.loads(PRIOR),DISCLOSURE,False);stamps('ops-activation-stamps','activated')
 activation('ops-activation-lost-reply-stale-cas',baselines=old_activation_cas,refuses='not the expected baseline');assert ops_state('ops-state-after-stale-cas')==s1
 out=activation('ops-activation-twice-refuses',disclosure='privacy-policy-other',refuses='KIE-ACTIVATION refused: property_video_quality already names the Kie profile')
 assert MARK not in out and ops_state('ops-state-after-second-activation')==s1,'a second activation must print no previous value and change nothing (record included)'
 # Activation -> Kie admissions work and freeze the canonical identity.
 kie=one_json('ops-kie-admission-after-activation',"set role service_role;"+admit(102))
 assert kie['accepted']and kie['job']['quality_profile']==PROFILE and kie['job']['quality_identity']==IDENTITY_JSON and frozen(102),kie
 s2=ops_state('ops-state-with-kie-job')
 job_inv=invariants('activated-kie-job-admitted',copy_of('kie_profile','inv_activated_job'));assert job_inv['resellerNote'].startswith(ACTIVATED_NOTE+DISCLOSURE+')'),job_inv
 v=verify('activated-kie-job-admitted',phase='activated: ');assert v['facts']['kie_jobs_admitted']=='1'and v['facts']['kie_jobs_draining']=='1',v
 # The drain branch does not cover the Kie selector itself: with the record
 # gone, the ON row is red even while that Kie job could still be granted work.
 control('activated-kie-job-record-deleted','kie_profile',f"delete from app_config where key='{RECORD_KEY}';",[PINNED])
 # Nor a hand-edited selector that still selects Kie (extra key): not exact, so
 # not the activation, and not a rollback either while a Kie job drains.
 control('activated-kie-job-selector-extra-key','kie_profile',selector('{"enabled":true,"profile":"kie-kling3-4k-steady-v1","vendor_content_license":"kie-terms-2025-08-01-section-3-owner-accepted","note":"hand edit"}'),[PINNED])
 # Rollback refuses anything that is not a pre-Kie value (the Kie value itself, a
 # non-boolean flag, malformed JSON), a value that differs from the record
 # (ambiguous), or an unknown mode, and changes nothing.
 rollback('ops-rollback-refuses-kie-value',KIE_ON,refuses='KIE-ROLLBACK refused')
 rollback('ops-rollback-refuses-string-flag','{"enabled":"true","profile":"fal-kling3-4k-v1"}',refuses='KIE-ROLLBACK refused')
 rollback('ops-rollback-refuses-malformed-json','{"enabled": true, "profile": "fal-kling3-4k-steady-v2"',refuses=AMBIGUOUS)
 rollback('ops-rollback-refuses-unknown-mode',emergency='yes',refuses='KIE-ROLLBACK refused: emergency_stop must be on or off')
 rollback('ops-rollback-refuses-mismatched-previous',FAL_V1_ON,refuses=AMBIGUOUS)
 rollback('ops-rollback-refuses-absent-when-recorded-present','absent',refuses=AMBIGUOUS)
 rollback('ops-emergency-refuses-mismatched-previous',FAL_V1_ON,emergency='on',refuses=AMBIGUOUS)
 assert ops_state('ops-state-after-refused-rollbacks')==s2
 # DEFAULT rollback uses only the saved activation record and fresh CAS:
 # exact restore of the selector only; the pinned row stays ON; the record is
 # kept and stamped; nothing else changes.
 out=rollback('ops-rollback')
 assert'KIE-ROLLBACK done (default)'in out and'1 admitted Kie job(s) can still be granted work'in out and'restoring the value saved by KIE-ACTIVATION.sql'in out,out
 s3=ops_state('ops-state-rolled-back')
 assert s3['config']==json.loads(PRIOR)and s3['enabled']is True and s3['row']==s0['row']and s3['untouched']==s2['untouched'],(s2,s3)
 assert scalar('ops-exact-restore',f"select value::text=$p${previous}$p$ from app_config where key='property_video_quality'")=='t'
 expect_record(s3['record'],json.loads(PRIOR),DISCLOSURE,False,mode='default');stamps('ops-rollback-stamps','rolled_back')
 assert{k:v for k,v in s3['record'].items()if k not in('rolled_back_at','rollback_mode')}=={k:v for k,v in s2['record'].items()if k not in('rolled_back_at','rollback_mode')},(s2['record'],s3['record'])
 out=rollback('ops-rollback-twice-refuses',refuses=NOTHING);assert ops_state('ops-state-after-second-rollback')==s3
 # New admissions use the restored profile; a stale Kie quote refuses, no job.
 fal_after=one_json('ops-admit-restored-profile',"set role service_role;"+admit(103,'fal-kling3-4k-steady-v2',500))
 assert fal_after['accepted']and fal_after['job']['quality_profile']=='fal-kling3-4k-steady-v2'and fal_after['job']['quality_identity']is None,fal_after
 run('ops-stale-kie-after-rollback',[*PSQL,'-Atq'],"set role service_role;"+admit(104),refuses='RP409:');assert job(104)=='none'
 s3a=ops_state('ops-state-after-restored-admission')
 # The already-admitted Kie job keeps its frozen profile/identity: byte-exact
 # admission replay, owner read scope, active worker scope (what every dispatch
 # needs) and, in a rolled-back probe, its next paid clip is still granted for
 # dispatch with that identity, while the pinned row stays ON and exact.
 readable=one_json('ops-kie-job-readable-after-rollback',"set role service_role;select jsonb_build_object("
  f"'replay',property_video_job_admit('{ACTOR}',jsonb_set((select m from kie_profile_race_fixture),'{{operation_id}}',to_jsonb('{op(102)}'::text)),null,'unknown')->'job',"
  f"'read',(select to_jsonb(s)from property_video_job_scope('{kie['job']['id']}','{ACTOR}',false)s),'active',(select to_jsonb(s)from property_video_job_scope('{kie['job']['id']}','{ACTOR}',true)s));")
 assert readable['replay']==kie['job']and all(readable[k]['quality_profile']==PROFILE and readable[k]['quality_identity']==IDENTITY_JSON for k in('read','active'))and frozen(102),readable
 probe=one_json('ops-kie-job-dispatchable-after-default-rollback',f"begin;set role service_role;select property_video_job_claim('{kie['job']['id']}','slot-0');rollback;")
 assert probe['action']=='dispatch'and probe['job']['id']==kie['job']['id']and probe['job']['quality_profile']==PROFILE and probe['job']['quality_identity']==IDENTITY_JSON,probe
 assert ops_state('ops-state-after-dispatch-probe')==s3a and json.loads(job(101))=={'profile':'fal-kling3-4k-steady-v2','identity':None}
 r['operatorScripts'].append({'name':'activation-then-default-rollback','invocation':'psql -X -v ON_ERROR_STOP=1 -1 -v processor_disclosure=<id> <fresh selector/route/record CAS> -f','printedPrevious':previous,'activationRefusesDriftedRow':True,'secondActivationRefusedWithoutPrintingPrevious':True,
  'recordExact':True,'kieAdmissionAfterActivation':True,'rollbackRefusesNonPreKieMalformedMismatchedOrUnknownMode':True,'exactRestoreFromRecord':True,'recordKeptAndStamped':True,'secondRollbackRefused':True,
  'pinnedRowLeftOn':True,'restoredProfileAdmits':True,'staleKieQuoteRefused':True,'admittedKieJobFrozenReplayIdenticalAndDispatchable':True,'jobsReceiptsOtherRoutesAndConfigUntouched':True})
 # While that admitted Kie job can still be granted work (or resumed, below) the
 # ON row is accepted (the drain); once it cannot (owner cancel, deadline passed,
 # the stale sweeper, an ambiguous dispatch), or with a weaker tier, it is red.
 drain=invariants('default-rollback-kie-job-draining',copy_of('kie_profile','inv_draining'))
 assert drain['resellerNote'].startswith('pinned Kie row ON (1 admitted Kie job(s) draining)'),drain
 v=verify('default-rollback-kie-job-draining',phase='draining: 1 admitted Kie job(s) can still be granted work until ');assert v['facts']['kie_jobs_draining']=='1'and json.loads(v['facts']['property_video_quality'])==json.loads(PRIOR),v
 verify('default-rollback-kie-job-draining-default-read-only',env=READ_ONLY_ENV,phase='draining: ')
 control('drain-over-owner-cancelled','kie_profile',f"set role service_role;select property_video_job_cancel('{ACTOR}','{kie['job']['id']}');",[PINNED])
 db=copy_of('kie_profile','inv_drain_deadline');run('change-drain-deadline-passed',[*psql_db(db),'-Atq','-c',f"update property_video_jobs set deadline=now()-interval'1 second'where id='{kie['job']['id']}'"])
 assert scalar_db('drain-deadline-states',db,f"select string_agg(quality_profile||':'||state,','order by operation_id)from property_video_jobs where operation_id in('{op(101)}','{op(102)}','{op(103)}')")=='fal-kling3-4k-steady-v2:queued,kie-kling3-4k-steady-v1:queued,fal-kling3-4k-steady-v2:queued'
 invariants('drain-over-deadline-passed',db,[PINNED],drop_db=False)
 verify('drain-over-deadline-passed',db,false=[18],phase='drain over: run KIE-ROUTE-OFF.sql now')
 run('drain-stale-sweeper',[*psql_db(db),'-Atq','-c',"set role service_role;select property_video_job_reconcile_stale();"])
 assert scalar_db('drain-swept-state',db,f"select state from property_video_jobs where id='{kie['job']['id']}'")=='failed'
 invariants('drain-over-swept-failed',db,[PINNED])
 # An ambiguous Kie dispatch moves the job to needs_reconciliation before its
 # deadline and without cancellation (no further dispatch; the supplier is only
 # polled): the state test alone ends the drain.
 db=copy_of('kie_profile','inv_drain_ambiguous')
 run('change-drain-ambiguous-dispatch',[*psql_db(db),'-Atq'],f"set role service_role;with c as(select property_video_job_claim('{kie['job']['id']}','slot-0')c)select property_video_job_failure('{kie['job']['id']}',(c#>>'{{source,lease_token}}')::uuid,(c#>>'{{source,attempt_id}}')::uuid,'provider_timeout',true)from c;")
 assert scalar_db('drain-ambiguous-state',db,f"select state||':'||(cancelled_at is null)||':'||(deadline>now())from property_video_jobs where id='{kie['job']['id']}'")=='needs_reconciliation:true:true'
 invariants('drain-over-ambiguous-dispatch',db,[PINNED])
 control('draining-pinned-weaker-tier','kie_profile',f"update ai_routes set privacy_tier='retained_30d'where id='{ROUTE}';",['video.property_reel_clip_kie/kie/kling-3.0/video enabled=t tier=retained_30d'])
 # A FAILED Kie job the owner can still resume before its deadline keeps the
 # drain open: here the capacity pause the worker files when a Kie vendor-account
 # refusal or a missing key stops the next clip before any hold. Its resume quote
 # and unsent clips read the pinned row, so switching the row OFF would strand it
 # (the old worker-scope-only count left this state red: control below). After
 # its deadline nothing can resume it and only the row OFF is green.
 db=copy_of('kie_profile','inv_drain_paused')
 run('change-drain-capacity-pause',[*psql_db(db),'-Atq'],f"set role service_role;with c as(select property_video_job_claim('{kie['job']['id']}','slot-0')c)select property_video_job_failure('{kie['job']['id']}',(c#>>'{{source,lease_token}}')::uuid,(c#>>'{{source,attempt_id}}')::uuid,'capacity_before_dispatch',false)from c;")
 assert scalar_db('drain-paused-state',db,f"select j.state||':'||s.state||':'||s.last_error||':'||(j.cancelled_at is null)||':'||(j.deadline>now())from property_video_jobs j join property_video_job_sources s on s.job_id=j.id and s.position=0 where j.id='{kie['job']['id']}'")=='failed:failed:capacity_before_dispatch:true:true'
 copy_of(db,'tpl_drain_paused')
 paused=invariants('default-rollback-kie-job-paused-draining',db,drop_db=False)
 assert paused['resellerNote'].startswith('pinned Kie row ON (1 admitted Kie job(s) draining)'),paused
 v=verify('default-rollback-kie-job-paused-draining',db,phase='draining: 1 admitted Kie job(s) can still be granted work until ');assert v['facts']['kie_jobs_draining']=='1',v
 resumed=[json.loads(l)for l in run('drain-paused-resume-probe',[*psql_db(db),'-Atq'],f"begin;set role service_role;select to_jsonb(property_video_job_resume('{ACTOR}','{kie['job']['id']}',335));rollback;").splitlines()if l.startswith('{')]
 assert len(resumed)==1 and resumed[0]['state']=='generating'and resumed[0]['quality_profile']==PROFILE and resumed[0]['quality_identity']==IDENTITY_JSON,resumed
 run('change-drain-paused-deadline-passed',[*psql_db(db),'-Atq','-c',f"update property_video_jobs set deadline=now()-interval'1 second'where id='{kie['job']['id']}'"])
 run('drain-paused-resume-after-deadline',[*psql_db(db),'-Atq'],f"set role service_role;select property_video_job_resume('{ACTOR}','{kie['job']['id']}',335);",refuses='RP409:')
 invariants('drain-over-paused-deadline-passed',db,[PINNED],drop_db=False)
 verify('drain-over-paused-deadline-passed',db,false=[18],phase='drain over: run KIE-ROUTE-OFF.sql now')
 out=route_off('drain-over-paused-route-off',db=db)
 assert'KIE-ROUTE-OFF done'in out and'0 admitted Kie job(s) could still be granted work or resumed'in out,out
 off=invariants('drain-over-paused-row-off',db,drop_db=False);assert off['resellerNote']=='all reseller rows disabled + worst-case tier',off
 verify('drain-over-paused-row-off',db,phase='Kie off: ');drop(db)
 # Control: the previous worker-scope-only drain test (failed excluded) turns
 # the same paused, resumable state red, so including failed is load-bearing.
 drain_states="and state in ('queued','generating','quality_review','composing','failed')";worker_scope_states="and state not in ('ready','cancelled','failed','needs_reconciliation')"
 itext_drain=INVARIANTS.read_text();assert itext_drain.count(drain_states)==1 and worker_scope_states not in itext_drain
 (OUT/ASTRA_GATES.name).write_text(ASTRA_GATES.read_text())  # \ir target next to the mutant
 narrow=OUT/'invariants.control-drain-worker-scope-only.sql';narrow.write_text(itext_drain.replace(drain_states,worker_scope_states,1));narrow.chmod(0o600)
 invariants('ic-drain-worker-scope-only-mutant',copy_of('tpl_drain_paused','ic_drain_paused_mutant'),[PINNED],script=narrow)
 drop('tpl_drain_paused')
 r['scriptControls'].append({'name':'invariant-drain-counts-resumable-failed-job','script':str(INVARIANTS.relative_to(ROOT)),'compiledFromActualScript':True,'realGreen':True,'mutantRed':True})
 r['operatorScripts'].append({'name':'paused-kie-job-keeps-drain-until-deadline','pausedState':'failed:capacity_before_dispatch','invariantsGreenWhilePaused':True,'ownerResumeAccepted':True,
  'afterDeadline':{'resumeRefused':True,'invariantRedWithRowOn':True,'verifyDrainOver':True,'dedicatedRouteOffGreen':True}})
 # Once the selector no longer names Kie, rollback refuses; the separate route-off
 # command changes only the pinned row and leaves every record/selector exact.
 rollback('ops-emergency-after-rollback-refuses',emergency='on',refuses=NOTHING)
 out=route_off('ops-route-off-keeps-restored-selector')
 assert'property_video_quality unchanged'in out and'WARNING'not in out and'KIE-ROUTE-OFF done'in out,out
 s3e=ops_state('ops-state-emergency-stop')
 assert s3e['config']==json.loads(PRIOR)and s3e['enabled']is False and s3e['row']==s0['row']and s3e['untouched']==s3a['untouched']and frozen(102),(s3a,s3e)
 expect_record(s3e['record'],json.loads(PRIOR),DISCLOSURE,False,mode='default');assert s3e['record']==s3['record'],'route-off must not rewrite any activation record'
 assert s3e['record']['rolled_back_at']==s3['record']['rolled_back_at'],(s3['record'],s3e['record'])
 out=route_off('ops-route-off-refuses-row-already-off',refuses='KIE-ROUTE-OFF refused');assert'already OFF'in out or'expected_route_enabled=true is required'in out;assert ops_state('ops-state-after-refused-emergency')==s3e
 stopped=invariants('emergency-stop',copy_of('kie_profile','inv_emergency_stop'))
 assert stopped['resellerNote']=='all reseller rows disabled + worst-case tier',stopped
 verify('emergency-stop',phase='Kie off: pinned row OFF, selector pre-Kie, activation record rolled back')
 verify('emergency-stop-default-read-only',env=READ_ONLY_ENV,phase='Kie off: ')
 r['operatorScripts'].append({'name':'dedicated-route-off-after-default-rollback','previousSupplied':False,'restoredSelectorKept':json.loads(PRIOR),'pinnedRowDisabled':True,'recordUnchangedByDedicatedRouteOff':True,'repeatRefused':True,'admittedKieJobFrozen':True,'jobsReceiptsOtherRoutesAndConfigUntouched':True})
 # Re-activation after a rollback replaces the record with the then-current
 # previous value (the owner switched the FAL profile meanwhile) and the new
 # attestation; the DEFAULT rollback without -v previous restores exactly that.
 run('ops-owner-switches-fal-profile',[*PSQL,'-Atq','-c',f"update app_config set value='{FAL_V1_ON}'where key='property_video_quality'"])
 s4p=ops_state('ops-state-before-reactivation')
 out=activation('ops-reactivation',disclosure=DISCLOSURE_URL);assert json.loads(printed(out))==json.loads(FAL_V1_ON),out
 s4=ops_state('ops-state-reactivated')
 assert s4['config']==json.loads(KIE_ON)and s4['enabled']is True and s4['untouched']==s4p['untouched'],s4
 expect_record(s4['record'],json.loads(FAL_V1_ON),DISCLOSURE_URL,False);stamps('ops-reactivation-stamps','activated')
 out=rollback('ops-rollback-from-record')
 assert'restoring the value saved by KIE-ACTIVATION.sql'in out and'WARNING'not in out and'KIE-ROLLBACK done (default)'in out,out
 s5=ops_state('ops-state-rollback-from-record')
 assert s5['config']==json.loads(FAL_V1_ON)and s5['enabled']is True and s5['untouched']==s4['untouched'],(out,s5)
 expect_record(s5['record'],json.loads(FAL_V1_ON),DISCLOSURE_URL,False,mode='default');stamps('ops-rollback-from-record-stamps','rolled_back')
 r['operatorScripts'].append({'name':'reactivation-then-default-rollback-from-record','reactivationPrintedPrevious':True,'recordReplacedWithThenCurrentPrevious':True,'newAttestationRecorded':DISCLOSURE_URL,'restored':json.loads(FAL_V1_ON),'noDefaultFallback':True,'pinnedRowLeftOn':True})
 # The key was ABSENT before activation: the record says so, activation creates
 # the key, the rollback deletes it again (never a default value); -v previous
 # must then be the word absent (any value is ambiguous).
 db=copy_of('inv_fresh','ops_absent');run('absent-delete-selector',[*psql_db(db),'-Atq','-c',"delete from app_config where key='property_video_quality'"])
 a0=state_of('absent-state-before',db);assert a0['config_present']is False and a0['record']is None,a0
 out=activation('absent-activation',db=db);assert printed(out)=='absent',out
 a1=state_of('absent-state-activated',db);assert a1['config']==json.loads(KIE_ON)and a1['enabled']is True and a1['untouched']==a0['untouched'],a1
 expect_record(a1['record'],None,DISCLOSURE,False);stamps('absent-activation-stamps','activated',db)
 copy_of(db,'tpl_absent_activated')
 absent_inv=invariants('absent-activated',copy_of(db,'inv_absent_activated'));assert absent_inv['resellerNote'].startswith(ACTIVATED_NOTE),absent_inv
 verify('absent-activated',db,phase='activated: ')
 rollback('absent-rollback-refuses-value',json.dumps(FAL_V1_OFF),db=db,refuses=AMBIGUOUS);assert state_of('absent-state-after-refusal',db)==a1
 out=rollback('absent-rollback',db=db);assert'restoring the value saved by KIE-ACTIVATION.sql'in out,out
 a2=state_of('absent-state-rolled-back',db);assert a2['config_present']is False and a2['config']is None and a2['enabled']is True and a2['untouched']==a1['untouched'],a2
 expect_record(a2['record'],None,DISCLOSURE,False,mode='default');stamps('absent-rollback-stamps','rolled_back',db)
 verify('absent-rolled-back-nothing-admitted',db,false=[18],phase='drain over: ')
 rollback('absent-emergency-refuses-value',json.dumps(FAL_V1_OFF),emergency='on',db=db,refuses=AMBIGUOUS)
 out=route_off('absent-route-off',db=db)
 a3=state_of('absent-state-stopped',db);assert a3['config_present']is False and a3['enabled']is False and a3['untouched']==a2['untouched'],a3
 expect_record(a3['record'],None,DISCLOSURE,False,mode='default');assert a3['record']==a2['record'],'route-off preserves absent-selector activation audit'
 invariants('absent-stopped',copy_of(db,'inv_absent_stopped'));verify('absent-stopped',db,phase='Kie off: ');drop(db)
 r['activationRecord'].append({'name':'selector-key-absent-before-activation','printed':'absent','recordedAbsent':True,'activationCreatedKey':True,'rollbackDeletedKey':True,'valueForAbsentRefused':True,'invariantsGreen':['activated','stopped']})
 # A missing or stale record is a hard refusal; explicit previous is retired.
 db=copy_of('inv_activated','ops_no_record');run('no-record-delete',[*psql_db(db),'-Atq','-c',f"delete from app_config where key='{RECORD_KEY}'"])
 b0=state_of('no-record-state',db)
 rollback('no-record-rollback-refuses',db=db,refuses='-v expected_record_sha256=... is required');rollback('no-record-emergency-refuses',emergency='on',db=db,refuses='-v expected_record_sha256=... is required')
 rollback('no-record-supplied-previous-refuses',json.dumps(FAL_V1_OFF),db=db,refuses=AMBIGUOUS)
 assert state_of('no-record-state-after-refusals',db)==b0;drop(db)
 db=copy_of('inv_activated','ops_stale_record');rollback('stale-record-first-rollback',db=db)
 run('stale-record-kie-by-hand',[*psql_db(db),'-Atq','-c',selector(KIE_ON)]);c0=state_of('stale-record-state',db)
 rollback('stale-record-rollback-refuses',db=db,refuses=NO_RECORD)
 rollback('stale-record-supplied-previous-refuses',PRIOR,db=db,refuses=AMBIGUOUS)
 assert state_of('stale-record-state-after-refusal',db)==c0;drop(db)
 r['activationRecord'].append({'name':'rollback-without-current-record','refusedWithoutRecord':True,'emergencyRefusedWithoutRecord':True,'suppliedPreviousAlwaysRefused':True,'noStateOrRecordInvented':True,'staleRecordNotReused':True})
 # The previous guessed-future-record rollback is intentionally unavailable.
 # Current scripts serialize on this same actual transaction advisory lock; a
 # compiled omission exposes lost serialization without inventing future CAS.
 # Actual in-flight admission/rollback/route winner races remain below.
 operator_lock=" perform pg_advisory_xact_lock(hashtextextended('rendprop:kie-operator-scripts',0));\n"
 assert ACTIVATION.read_text().count(operator_lock)==1 and ROLLBACK.read_text().count(operator_lock)==1
 def interleave(label,activation_script):
  db=copy_of('inv_fresh','race_'+label.replace('-','_'));run('race-absent-'+label,[*psql_db(db),'-Atq','-c',"delete from app_config where key='property_video_quality'"])
  baseline=operator_cas('race-'+label,db)
  holder="begin;select pg_advisory_xact_lock(hashtextextended('rendprop:kie-operator-scripts',0));select pg_sleep(.6);commit;"
  outcomes=race('operator-scripts-'+label,[holder if db=='kie_profile'else([*psql_db(db),'-Atq'],holder),([*psql_db(db),'-1',*cas_args(baseline),'-v','processor_disclosure='+DISCLOSURE,'-c','select pg_sleep(.15)','-f',activation_script],None)])
  state=state_of('race-state-'+label,db);drop(db);return outcomes,state
 outcomes,s=interleave('serialized',ACTIVATION)
 assert all(x['exit']==0 for x in outcomes)and outcomes[1]['elapsed']>=.4,outcomes
 assert s['config']==json.loads(KIE_ON)and s['enabled']is True,s;expect_record(s['record'],None,DISCLOSURE,False)
 unlocked=OUT/'KIE-ACTIVATION.control-no-operator-lock.sql';unlocked.write_text(ACTIVATION.read_text().replace(operator_lock,'',1));unlocked.chmod(0o600)
 control_outcomes,control_s=interleave('control-no-operator-lock',unlocked)
 assert all(x['exit']==0 for x in control_outcomes)and control_outcomes[1]['elapsed']<.4 and control_s['config']==json.loads(KIE_ON),('unlocked control did not expose lost serialization',control_outcomes,control_s)
 r['operatorScripts'].append({'name':'activation-respects-shared-operator-transaction-lock','actualConcurrentTransactions':2,'waitedSeconds':round(outcomes[1]['elapsed'],3),'withoutLockLosesSerialization':True,'controlSeconds':round(control_outcomes[1]['elapsed'],3),'noGuessedFutureRecord':True})

 # Compiled controls on the ACTUAL operator scripts: each removes or weakens one
 # guard in a copy of the real script; the same proof passes against the real
 # script and fails against the mutant, each on its own disposable copy.
 def script_control(label,script,anchor,replacement,template,setup,prove):
  text=script.read_text();assert text.count(anchor)==1,(label,'anchor')
  mutant=OUT/f'{script.stem}.control-{label}.sql';mutant.write_text(text.replace(anchor,replacement,1));mutant.chmod(0o600)
  outcome={}
  for kind,path in(('real',script),('mutant',mutant)):
   db=copy_of(template,f'sc_{label}_{kind}'.replace('-','_'))
   if setup:run(f'sc-setup-{label}-{kind}',[*psql_db(db),'-Atq'],setup)
   try:prove(f'sc-{label}-{kind}',db,path);outcome[kind]=True
   except AssertionError as error:
    assert 'syntax error'not in str(error).lower(),(label,'a mutant must be valid SQL, not a syntax failure',error)
    outcome[kind]=False
   drop(db)
  assert outcome=={'real':True,'mutant':False},(label,outcome)
  r['scriptControls'].append({'name':label,'script':str(script.relative_to(ROOT)),'compiledFromActualScript':True,'realPasses':True,'unsafeMutationDetected':True})
 act_text=ACTIVATION.read_text();rb_text=ROLLBACK.read_text()
 block=lambda text,start,end:text[text.index(start):text.index(end,text.index(start))+len(end)]
 required_guard=block(act_text," if coalesce(disclosure,'')='' then\n"," end if;\n")
 selector_guard=block(act_text," if present and not coalesce(jsonb_typeof(previous)='object'"," end if;\n")
 record_write=act_text[act_text.index(" if old_record_sha='absent' then\n"):act_text.index(" raise notice 'KIE-ACTIVATION done:")]
 mismatch_guard=block(rb_text," if previous_supplied then\n"," end if;\n")
 no_record_guard=block(rb_text," if not usable then\n"," end if;\n")
 nothing_guard=block(rb_text," if not present or selector->>'profile' is distinct from kie_profile then\n"," end if;\n")
 stamp_write=block(rb_text," stamped:=activation||jsonb_build_object('rolled_back_at'"," where key='property_video_quality_kie_activation';\n")
 route_off_text=ROUTE_OFF.read_text();emergency_guard=block(route_off_text," if v_present and coalesce(jsonb_typeof(v_selector)='object'"," end if;\n")
 def prove_refusal(disclosure,needle):
  def prove(name,db,script):
   before=state_of(name+'-before',db);out=activation(name,db=db,disclosure=disclosure,refuses=needle,script=script)
   assert MARK not in out and state_of(name+'-after',db)==before
  return prove
 def prove_record(previous):
  def prove(name,db,script):activation(name,db=db,script=script);expect_record(record_of(name+'-record',db),previous,DISCLOSURE,False)
  return prove
 def prove_rollback_refusal(needle,previous=None,emergency=None):
  def prove(name,db,script):
   before=state_of(name+'-before',db);rollback(name,previous,refuses=needle,emergency=emergency,db=db,script=script);assert state_of(name+'-after',db)==before
  return prove
 def prove_exact_restore(name,db,script):
  rollback(name,db=db,script=script);s=state_of(name+'-after',db);assert s['config']==FAL_V1_OFF and s['enabled']is True,s
  expect_record(s['record'],FAL_V1_OFF,DISCLOSURE,False,mode='default')
 def prove_absent_restore(name,db,script):
  rollback(name,db=db,script=script);s=state_of(name+'-after',db);assert s['config_present']is False and s['enabled']is True,s
 script_control('disclosure-required',ACTIVATION,required_guard,'','inv_fresh',None,prove_refusal(None,REQUIRED))
 script_control('disclosure-visible-ascii',ACTIVATION,"or disclosure !~ '^[!-~]+$'",'','inv_fresh',None,prove_refusal('privacy policy',MALFORMED))
 script_control('disclosure-200-characters',ACTIVATION,'length(disclosure)>200','length(disclosure)>201','inv_fresh',None,prove_refusal('x'*201,MALFORMED))
 script_control('reviewed-identity-exact',ACTIVATION,'if kie is distinct from reviewed or ','if ','inv_fresh',identity_def.replace('"min_short_side_px":2160','"min_short_side_px":1080',1),prove_refusal(DISCLOSURE,'is not the reviewed canonical identity in this script'))
 script_control('restorable-previous-selector',ACTIVATION,selector_guard,'','inv_fresh',selector('{"enabled":"true","profile":"fal-kling3-4k-v1"}'),prove_refusal(DISCLOSURE,'is not a working pre-Kie selector'))
 script_control('activation-record-saved',ACTIVATION,record_write,'','inv_fresh',None,prove_record(FAL_V1_OFF))
 script_control('absent-previous-recorded',ACTIVATION,"else jsonb_build_object('present',false) end","else jsonb_build_object('present',true,'value',previous) end",'inv_fresh',"delete from app_config where key='property_video_quality';",prove_record(None))
 script_control('rollback-mismatch-refused',ROLLBACK,mismatch_guard,'','inv_activated',None,prove_rollback_refusal(AMBIGUOUS,FAL_V1_ON))
 script_control('rollback-stale-record-refused',ROLLBACK,no_record_guard,'','inv_activated',record_set('{rolled_back_at}','\"2026-10-16T00:00:00Z\"'),prove_rollback_refusal(NO_RECORD))
 script_control('rollback-nothing-to-roll-back',ROLLBACK,nothing_guard,'','inv_activated',selector(PRIOR),prove_rollback_refusal(NOTHING))
 script_control('rollback-restores-recorded-value-not-a-default',ROLLBACK,"update public.app_config set value=target->'value',updated_at=now()","update public.app_config set value='{\"enabled\":true,\"profile\":\"fal-kling3-4k-v1\"}'::jsonb,updated_at=now()",'inv_activated',None,prove_exact_restore)
 script_control('rollback-stamps-record',ROLLBACK,stamp_write,' null;\n','inv_activated',None,prove_exact_restore)
 script_control('rollback-deletes-absent-key',ROLLBACK,"delete from public.app_config where key='property_video_quality';",'null;','tpl_absent_activated',None,prove_absent_restore)
 def prove_route_off_refusal(name,db,script):
  before=state_of(name+'-before',db);route_off(name,db=db,script=script,refuses='KIE-ROUTE-OFF refused: property_video_quality selects Kie');assert state_of(name+'-after',db)==before
 script_control('route-off-refuses-selected-kie',ROUTE_OFF,emergency_guard,'','inv_activated',None,prove_route_off_refusal)

 # The verification's identity expectation is live: one changed field in the
 # embedded literal turns the identity check false on the fresh database.
 def prove_verify(name,db,script):verify(name,db,script=script,record=False)
 script_control('verify-identity-literal',VERIFY,'"min_short_side_px":2160','"min_short_side_px":1080','inv_fresh',None,prove_verify)
 # The invariant's record requirement, its drain-only-after-rollback rule and
 # its selects-Kie test (not just the exact value) are load-bearing: the
 # invariant text without each turns its red state green. The kie_profile
 # template here has an admitted Kie job that can still be granted work.
 itext=INVARIANTS.read_text();ianchor='g.activated\n                                or (g.draining > 0 and not g.selects_kie)';assert itext.count(ianchor)==1
 (OUT/ASTRA_GATES.name).write_text(ASTRA_GATES.read_text())  # \ir target next to the mutant
 hand_kie=f"update ai_routes set enabled=true where id='{ROUTE}';delete from app_config where key='{RECORD_KEY}';"
 for label,replacement,template,change in[('record-required','g.acknowledged or g.draining > 0','inv_fresh',on+selector(KIE_ON)),
                                           ('drain-only-after-rollback','g.activated or g.draining > 0','kie_profile',selector(KIE_ON)+hand_kie),
                                           ('drain-not-while-selector-selects-kie','g.activated or (g.draining > 0 and not g.acknowledged)','kie_profile',
                                            selector('{"enabled":true,"profile":"kie-kling3-4k-steady-v1","vendor_content_license":"kie-terms-2025-08-01-section-3-owner-accepted","note":"hand edit"}'))]:
  mutant=OUT/f'invariants.control-{label}.sql';mutant.write_text(itext.replace(ianchor,replacement,1));mutant.chmod(0o600)
  outcome={}
  for kind,path in(('real',INVARIANTS),('mutant',mutant)):
   db=copy_of(template,f'ic_{label}_{kind}'.replace('-','_'))
   run(f'ic-change-{label}-{kind}',[*psql_db(db),'-Atq'],change)
   try:invariants(f'ic-{label}-{kind}',db,[PINNED],drop_db=False,script=path);outcome[kind]=True
   except AssertionError:outcome[kind]=False
   drop(db)
  assert outcome=={'real':True,'mutant':False},(label,outcome)
  r['scriptControls'].append({'name':'invariant-'+label,'script':str(INVARIANTS.relative_to(ROOT)),'compiledFromActualScript':True,'realRed':True,'mutantGreen':True})
 assert ops_state('ops-state-after-script-controls')==s5,'a script control touched the main database'

 # Lock order: the EMERGENCY rollback locks the selector row before the route
 # row, exactly as admission does, so it waits for an in-flight Kie admission and
 # cannot deadlock. Without -v previous it restores the recorded value.
 out=activation('ops-activation-before-lock-race');assert json.loads(printed(out))==json.loads(FAL_V1_ON),out
 expect_record(record_of('ops-record-before-lock-race'),json.loads(FAL_V1_ON),DISCLOSURE,True)
 inflight=lambda i:f"begin;set role service_role;select property_video_quality_profile();select pg_sleep(.6);{admit(i)}commit;"
 outcomes=race('rollback-waits-for-inflight-kie-admission',[inflight(105),([*PSQL,'-1',*cas_args(operator_cas('inflight-emergency-race')),'-v','emergency_stop=on','-c','select pg_sleep(.15)','-f',ROLLBACK],None)])
 assert all(x['exit']==0 for x in outcomes)and outcomes[1]['elapsed']>=.4 and frozen(105),outcomes
 s=ops_state('ops-state-after-lock-race');assert s['config']==json.loads(FAL_V1_ON)and s['enabled']is False,s
 expect_record(s['record'],json.loads(FAL_V1_ON),DISCLOSURE,True,mode='emergency',disabled=True);stamps('ops-emergency-stamps','emergency')
 r['operatorScripts'].append({'name':'emergency-rollback-waits-for-inflight-kie-admission','actualConcurrentTransactions':2,'rollbackWaitedSeconds':round(outcomes[1]['elapsed'],3),'restoredFromRecord':True,'recordStampedEmergency':True,'inflightKieJobFrozen':True,'noDeadlock':True})
 # The DEFAULT rollback locks only the selector row: it waits too, the in-flight
 # admission completes on Kie with its frozen identity, and the row stays ON.
 out=activation('ops-activation-before-default-lock-race');previous=printed(out);assert json.loads(previous)==json.loads(FAL_V1_ON),out
 outcomes=race('default-rollback-waits-for-inflight-kie-admission',[inflight(107),([*PSQL,'-1',*cas_args(operator_cas('inflight-default-race')),'-c','select pg_sleep(.15)','-f',ROLLBACK],None)])
 assert all(x['exit']==0 for x in outcomes)and outcomes[1]['elapsed']>=.4 and frozen(107),outcomes
 s=ops_state('ops-state-after-default-lock-race');assert s['config']==json.loads(FAL_V1_ON)and s['enabled']is True,s
 expect_record(s['record'],json.loads(FAL_V1_ON),DISCLOSURE,False,mode='default')
 r['operatorScripts'].append({'name':'default-rollback-waits-for-inflight-kie-admission','actualConcurrentTransactions':2,'rollbackWaitedSeconds':round(outcomes[1]['elapsed'],3),'savedRecordOnlyFreshCAS':True,'inflightKieJobFrozen':True,'pinnedRowLeftOn':True,'noDeadlock':True})
 # Control: the EMERGENCY rollback with the opposite lock order (route row
 # first) deadlocks against that in-flight admission, so the order is load-bearing.
 activation('ops-activation-before-lock-control');s=ops_state('ops-state-before-lock-control')
 route_lock=" select enabled into route_on from public.ai_routes where id=pinned for update;\n";lock=" -- 1. Selector first"
 assert rb_text.count(route_lock)==1 and rb_text.count(lock)==1
 reversed_rollback=OUT/'KIE-ROLLBACK.reversed-lock-order-control.sql';reversed_rollback.write_text(rb_text.replace(route_lock,'',1).replace(lock,route_lock+lock,1));reversed_rollback.chmod(0o600)
 outcomes=race('rollback-control-route-first-deadlocks',[inflight(106),([*PSQL,'-1',*cas_args(operator_cas('inflight-reversed-control')),'-v','emergency_stop=on','-c','select pg_sleep(.15)','-f',reversed_rollback],None)])
 assert outcomes[0]['exit']==0 and outcomes[1]['exit']!=0 and'deadlock detected'in outcomes[1]['output']and frozen(106),('reversed lock order did not deadlock',outcomes)
 s6=ops_state('ops-state-after-lock-control');assert s6['config']==json.loads(KIE_ON)and s6['enabled']is True and s6['record']==s['record'],s6
 r['operatorScripts'].append({'name':'control-route-first-emergency-rollback-deadlocks','compiledFromActualScript':True,'deadlockDetected':True,'abortedRollbackChangedNothing':True})

 # Real concurrent races on committed state produced by the real activation
 # script above (acknowledged selector AND pinned row enabled).
 outcomes=race('same-operation-kie',["set role service_role;"+admit(1)for _ in range(6)]);assert all(x['exit']==0 for x in outcomes),outcomes
 replies=[json.loads(next(l for l in x['output'].splitlines()if l.startswith('{')))for x in outcomes]
 assert len({x['job']['id']for x in replies})==1 and len({json.dumps(x['job'],sort_keys=True)for x in replies})==1 and all(x['job']['quality_identity']==IDENTITY_JSON for x in replies),replies
 assert scalar('one-job',f"select count(*)from property_video_jobs where operation_id='{op(1)}'")=='1'
 r['races'].append({'name':'same-operation-kie','actualConcurrentRequests':6,'exactlyOneJob':True,'identicalReplies':True,'frozenIdentity':True})
 outcomes=race('cutover-before-stale-admission',["begin;"+cutover+"select pg_sleep(.5);commit;","select pg_sleep(.1);set role service_role;"+admit(2)])
 assert outcomes[0]['exit']==0 and outcomes[1]['exit']!=0 and'RP409:'in outcomes[1]['output']and outcomes[1]['elapsed']>=.3 and job(2)=='none',outcomes
 r['races'].append({'name':'cutover-before-stale-admission','actualConcurrentTransactions':2,'staleKieQuoteRefused':True,'waitedForCutover':True,'waitSeconds':round(outcomes[1]['elapsed'],3),'noJob':True})
 run('restore-kie-after-cutover',[*PSQL,'-Atq'],restore_kie)
 outcomes=race('admission-before-cutover',["begin;set role service_role;"+admit(3)+"select pg_sleep(.5);commit;","select pg_sleep(.1);begin;"+cutover+"commit;"])
 assert all(x['exit']==0 for x in outcomes)and outcomes[1]['elapsed']>=.4 and frozen(3),outcomes
 r['races'].append({'name':'admission-before-cutover','actualConcurrentTransactions':2,'configFlipWaitedForAdmission':True,'waitSeconds':round(outcomes[1]['elapsed'],3),'frozenProfileAndIdentityRetained':True})
 run('restore-kie-after-admission',[*PSQL,'-Atq'],restore_kie)
 outcomes=race('route-drift-before-stale-admission',["begin;"+drift+"select pg_sleep(.5);commit;","select pg_sleep(.1);set role service_role;"+admit(4)])
 assert outcomes[0]['exit']==0 and outcomes[1]['exit']!=0 and'RP409: The Kie property-video route changed'in outcomes[1]['output']and outcomes[1]['elapsed']>=.3 and job(4)=='none',outcomes
 r['races'].append({'name':'route-drift-before-stale-admission','actualConcurrentTransactions':2,'staleRouteRefused':True,'waitedForRouteEdit':True,'waitSeconds':round(outcomes[1]['elapsed'],3),'noJob':True})
 run('undrift-after-stale',[*PSQL,'-Atq'],undrift)
 outcomes=race('admission-before-route-drift',["begin;set role service_role;"+admit(5)+"select pg_sleep(.5);commit;","select pg_sleep(.1);begin;"+drift+"commit;"])
 assert all(x['exit']==0 for x in outcomes)and outcomes[1]['elapsed']>=.4 and frozen(5),outcomes
 r['races'].append({'name':'admission-before-route-drift','actualConcurrentTransactions':2,'routeEditWaitedForAdmission':True,'waitSeconds':round(outcomes[1]['elapsed'],3),'frozenIdentityRetained':True})
 run('undrift-after-admission',[*PSQL,'-Atq'],undrift)
 # Race control: without FOR SHARE on the pinned row the same race admits a
 # stale quote, so the race above genuinely depends on the installed lock.
 signature='public.property_video_job_admit(uuid,jsonb,numeric,text)';anchor="for share of route;"
 original=run('read-race-control',[*PSQL,'-Atq','-c',"select pg_get_functiondef('%s'::regprocedure)"%signature]);assert original.count(anchor)==1
 md5_installed=scalar('md5-before-race-control',"select md5(prosrc)from pg_proc where oid='%s'::regprocedure"%signature)
 run('compile-race-control',[*PSQL,'-Atq'],original.replace(anchor,';',1))
 outcomes=race('race-control-unlocked-route',["begin;"+drift+"select pg_sleep(.5);commit;","select pg_sleep(.1);set role service_role;"+admit(6)])
 assert outcomes[0]['exit']==0 and outcomes[1]['exit']==0 and frozen(6),('unlocked control did not expose the stale admission',outcomes)
 run('restore-race-control',[*PSQL,'-Atq'],original);run('undrift-after-control',[*PSQL,'-Atq'],undrift)
 assert scalar('restored-race-control',"select md5(prosrc)from pg_proc where oid='%s'::regprocedure"%signature)==md5_installed
 r['raceControls'].append({'name':'route-row-lock-removed','compiledActualSQL':True,'staleAdmissionExposedWithoutLock':True,'staleAdmissionSeconds':round(outcomes[1]['elapsed'],3),'restoredExactMd5':True})
 final=catalog('final-functions');KEYS=['target_bodies','target_metadata','identity_function','other_functions','profile_constraint','identity_column','submit_refusal']
 assert{k:final[k]for k in KEYS}=={k:functions_before_races[k]for k in KEYS},'race control was not fully restored'
 assert hashes()==r['sourceHashes'],'A snapshotted SQL input changed during proof';r['passed']=True;r['runtimeSeconds']=round(time.monotonic()-T0,1)
 print(json.dumps({'passed':True,'freshAssertions':r['fresh']['assertions'],'replayAssertions':r['replay']['assertions'],'regressions':{k:v['assertions']for k,v in r['regressions'].items()},
  'laterMigrations':len(LATER),'compiledControls':len(r['controls']),'steadyControls':len(r['steadyControls']),'operatorScripts':len(r['operatorScripts']),'activationRecordProofs':len(r['activationRecord']),'scriptControls':len(r['scriptControls']),'verifyStates':len(r['verify']),'verifyControls':len(r['verifyControls']),'invariantStates':{'green':sum(not x['failed']for x in r['resellerInvariant']),'redControls':sum(bool(x['failed'])for x in r['resellerInvariant']),'inventory':r['resellerInvariant'][0]['invariants']},'races':len(r['races']),'raceControls':len(r['raceControls']),'pgFixtureStages':sorted(r['pgFixture']['stages']),'pgFixtureControls':len(r['pgFixture']['controls']),'runtimeSeconds':r['runtimeSeconds'],'receipt':str(OUT/'receipt.json')}))
finally:
 original_failure=sys.exc_info()[0]is not None;cleanup_error=None
 try:cleanup_owned()
 except BaseException as error:cleanup_error=repr(error);r['cleanupError']=cleanup_error;r['passed']=False
 r['runtime']={'platform':sys.platform,'proofDeadlineSeconds':WHOLE_SECONDS,'postgresTools':{n:tool(n)for n in ['initdb','pg_ctl','createdb','psql']}}
 (OUT/'receipt.json').write_text(json.dumps(r,indent=2)+'\n');(OUT/'receipt.json').chmod(0o600)
 if cleanup_error and not original_failure:raise RuntimeError(cleanup_error)
